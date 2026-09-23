import Foundation
import CADCore
import CoreGraphics

/// Produces the exact same `DXFDocument`/`RenderGroup`/`StrokeStore` shape as
/// `GeometryBuilder.build`, but from an `EntityStore` (+ the block/layer/
/// linetype bookkeeping `EntityStoreParser` produces) instead of a
/// `RawParseOutput`. This is the "same output, new data source" half of
/// Phase 1.3 — every load-bearing behavior of `GeometryBuilder` (transform-
/// stack recursion, layer-0-in-block inheritance, BYLAYER/BYBLOCK/true-color
/// resolution, orphan-block synthetic roots, MINSERT array math, GroupKey
/// grouping + deterministic sort, the `maxExpandedEntities` cap) is
/// reproduced exactly; the one addition is that every emitted primitive
/// carries the `EntityID` of the entity it came from.
///
/// `GeometryBuilder.build` itself is untouched and still used by the
/// existing `RawParseOutput` path (DXFParser.parse / PackageLoader) — this
/// is an additive parallel path, not a replacement.
enum Regenerator {

    private struct Ctx {
        var t = CGAffineTransform.identity
        var scale: CGFloat = 1
        var scaleX: CGFloat = 1
        var scaleY: CGFloat = 1
        var rotationDegrees: Double = 0
        var mirrored = false

        var isNonUniform: Bool {
            abs(scaleX - scaleY) > 0.001 * max(scaleX, scaleY)
        }
        var subLayer: Int32? = nil
        var byBlockColor = ResolvedColor.foreground
        var byBlockLinetype: Int16 = 0
        var xrefId: Int16 = -1
        var insertId: Int32 = -1
        var depth = 0
    }

    /// Not `private` (unlike most of `Regenerator`'s internals) because
    /// Phase 1.6's `EmittedPrimitive` — consumed by `RegenCoordinator` in a
    /// different file — carries one as a stored property.
    struct GroupKey: Hashable {
        var layerId: Int32
        var color: ResolvedColor
        var linetypeId: Int16
        var xrefId: Int16
    }

    /// Not `private` for the same reason as `GroupKey` above — `RegenCoordinator`
    /// (a different file) touches `EmittedPrimitive.accumulator` directly.
    final class Accumulator {
        let strokes = StrokeStore()

        private var runStart = -1
        private var rMinX = CGFloat.infinity, rMinY = CGFloat.infinity
        private var rMaxX = -CGFloat.infinity, rMaxY = -CGFloat.infinity

        func beginRun() {
            runStart = strokes.points.count
            rMinX = .infinity; rMinY = .infinity
            rMaxX = -.infinity; rMaxY = -.infinity
        }

        func addRunPoint(_ p: CGPoint) {
            strokes.points.append(p)
            if p.x < rMinX { rMinX = p.x }
            if p.y < rMinY { rMinY = p.y }
            if p.x > rMaxX { rMaxX = p.x }
            if p.y > rMaxY { rMaxY = p.y }
            addBoundsPoint(p)
        }

        func endRun(closed: Bool, kind: EntityKind, insertId: Int32, entityId: Int32, lineweight: Int16 = -1,
                    strokeAlpha: CGFloat = 1) {
            let count = strokes.points.count - runStart
            if count < 2 {
                strokes.points.removeLast(max(0, count))
                runStart = -1
                return
            }
            strokes.runs.append(StrokeStore.Run(
                start: Int32(runStart), count: Int32(count), closed: closed,
                kind: kind, insertId: insertId,
                bounds: CGRect(x: rMinX, y: rMinY,
                               width: rMaxX - rMinX, height: rMaxY - rMinY),
                entityId: entityId, lineweight: lineweight, strokeAlpha: strokeAlpha))
            runStart = -1
        }

        func addArc(center: CGPoint, radius: CGFloat,
                    startDeg: Double, endDeg: Double, full: Bool, insertId: Int32, entityId: Int32,
                    lineweight: Int16 = -1) {
            strokes.arcs.append(StrokeStore.Arc(
                center: center, radius: radius,
                startAngleDeg: startDeg, endAngleDeg: endDeg, isFullCircle: full,
                insertId: insertId, entityId: entityId, lineweight: lineweight))
            addBoundsPoint(CGPoint(x: center.x - radius, y: center.y - radius))
            addBoundsPoint(CGPoint(x: center.x + radius, y: center.y + radius))
        }

        func addFillRun(_ pts: [CGPoint], kind: EntityKind, insertId: Int32, entityId: Int32,
                       fillAlpha: CGFloat = 1) {
            guard pts.count >= 3 else { return }
            var minX = CGFloat.infinity, minY = CGFloat.infinity
            var maxX = -CGFloat.infinity, maxY = -CGFloat.infinity
            for p in pts {
                if p.x < minX { minX = p.x }
                if p.y < minY { minY = p.y }
                if p.x > maxX { maxX = p.x }
                if p.y > maxY { maxY = p.y }
            }
            strokes.fillRuns.append(StrokeStore.Run(
                start: Int32(strokes.fillPoints.count), count: Int32(pts.count),
                closed: true, kind: kind, insertId: insertId,
                bounds: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY),
                entityId: entityId, fillAlpha: fillAlpha))
            strokes.fillPoints.append(contentsOf: pts)
        }

        let fill = CGMutablePath()
        let patternFill = CGMutablePath()
        var points: [CGPoint] = []
        var texts: [TextItem] = []
        var count = 0
        var minX = CGFloat.infinity, minY = CGFloat.infinity
        var maxX = -CGFloat.infinity, maxY = -CGFloat.infinity

        func addBoundsPoint(_ p: CGPoint) {
            guard abs(p.x) < 1e12, abs(p.y) < 1e12 else { return }
            if p.x < minX { minX = p.x }
            if p.y < minY { minY = p.y }
            if p.x > maxX { maxX = p.x }
            if p.y > maxY { maxY = p.y }
        }

        var bounds: CGRect {
            guard maxX >= minX, maxY >= minY else { return .null }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
    }

    static let maxExpandedEntities = 8_000_000

    /// One entity's worth of interpreted DXF semantics, read out of
    /// `EntityStore` — the store-backed equivalent of a `RawEntity`, without
    /// materializing a persistent array (`walk` reads directly from the
    /// store's typed payload arrays entity-by-entity).
    private struct StoreEntityView {
        var id: EntityID
        var kind: EntityKind
        var layerId: Int32
        var aci: Int16
        var trueColor: UInt32
        var linetypeId: Int16
        var mirrorOCS: Bool
    }

    /// The per-entity geometry-emission body, extracted verbatim from
    /// `build`'s local `emitGeometry` closure so it has exactly ONE
    /// implementation shared by the full-document build path AND Phase 1.6's
    /// incremental single-entity delta emission (`emitSingleTopLevel`) — no
    /// behavior can drift between "regenerate everything" and "regenerate
    /// just what changed" because they call the same code. Takes `ctx`/`e`/
    /// `h` (already resolved by the caller) and an `Accumulator` to append
    /// into; does NOT touch `expandedCount`/`layerCounts` bookkeeping, which
    /// stays local to `build` (the incremental path has its own, simpler
    /// counters — see `RegenCoordinator`).
    private static func emitPrimitive(_ e: StoreEntityView, _ h: EntityHeader, _ ctx: Ctx,
                                      store: EntityStore, into a: Accumulator) {
        let t = ctx.t
        let entityId = e.id.raw

        @inline(__always) func tp(_ x: Double, _ y: Double) -> CGPoint {
            let p = CGPoint(x: x, y: y).applying(t)
            a.addBoundsPoint(p)
            return p
        }

        guard h.payload >= 0 else { return }
        // An invisible entity (DXF group 60=1, or an ATTRIB with group-70
        // bit 1) is retained in the store so Data Extraction /
        // `BlockEditor.attributes(of:)` can read its data, but must NOT be
        // drawn — the renderer skips it here. (Historically such entities
        // never reached the store at all because the parser dropped them;
        // now that invisible ATTRIBs are kept for their data, the "don't
        // draw" responsibility moves here. See `EntityStoreParser`'s
        // TEXT/ATTRIB case and `finish(keepIfInvisible:)`.)
        if h.flags.contains(.invisible) { return }
        let pIdx = Int(h.payload)

        switch h.type {
        case .line:
            let l = store.lines[pIdx]
            a.beginRun()
            a.addRunPoint(tp(l.a.x, l.a.y))
            a.addRunPoint(tp(l.b.x, l.b.y))
            a.endRun(closed: false, kind: e.kind, insertId: ctx.insertId, entityId: entityId, lineweight: h.lineweight)

        case .circle:
            let c = store.circles[pIdx]
            if ctx.isNonUniform {
                a.beginRun()
                for k in 0...48 {
                    let ang = Double(k) / 48 * 2 * .pi
                    a.addRunPoint(tp(c.center.x + c.radius * cos(ang), c.center.y + c.radius * sin(ang)))
                }
                a.endRun(closed: true, kind: e.kind, insertId: ctx.insertId, entityId: entityId, lineweight: h.lineweight)
                break
            }
            let center = tp(c.center.x, c.center.y)
            a.addArc(center: center, radius: CGFloat(c.radius) * ctx.scale,
                     startDeg: 0, endDeg: 360, full: true, insertId: ctx.insertId, entityId: entityId,
                     lineweight: h.lineweight)

        case .arc:
            let arc = store.arcs[pIdx]
            if ctx.isNonUniform {
                var sweep = arc.endAngleDeg - arc.startAngleDeg
                while sweep <= 0 { sweep += 360 }
                let steps = max(6, min(64, safeInt(sweep / 6)))
                a.beginRun()
                for k in 0...steps {
                    let ang = (arc.startAngleDeg + sweep * Double(k) / Double(steps)) * .pi / 180
                    a.addRunPoint(tp(arc.center.x + arc.radius * cos(ang), arc.center.y + arc.radius * sin(ang)))
                }
                a.endRun(closed: false, kind: e.kind, insertId: ctx.insertId, entityId: entityId, lineweight: h.lineweight)
                break
            }
            let center = tp(arc.center.x, arc.center.y)
            var s = arc.startAngleDeg, en = arc.endAngleDeg
            if ctx.mirrored {
                s = -arc.endAngleDeg; en = -arc.startAngleDeg
            }
            s += ctx.rotationDegrees; en += ctx.rotationDegrees
            a.addArc(center: center, radius: CGFloat(arc.radius) * ctx.scale,
                     startDeg: s, endDeg: en, full: false, insertId: ctx.insertId, entityId: entityId,
                     lineweight: h.lineweight)

        case .lwpolyline, .polyline2d, .polyline3d, .leader:
            // LEADER is stored as a (non-closed, no-bulge) polyline-shaped
            // payload — see EntityStoreParser — so it reuses this case
            // exactly; `e.kind` (set from `h.type` in `view(_:)`) keeps it
            // labeled `.leader` downstream for hit-testing/properties.
            let p = store.polylines[pIdx]
            let vCount = Int(p.vertsCount)
            guard vCount > 1 else { break }
            let vStart = Int(p.vertsStart), bStart = Int(p.bulgesStart)
            // Auto-detect "closed" for a polyline whose stored `closed` flag
            // is false but whose first/last vertices coincide (or are
            // extremely close) — e.g. drawn by tracing back to the start
            // point without invoking an explicit Close action, or produced
            // by some other CAD tool/import path that never set DXF group
            // 70 bit 0 despite the geometry visually being a closed loop.
            // Deliberately excludes `.leader` (never meaningfully "closed")
            // and requires >= 3 vertices (a 2-point "loop" is degenerate).
            // This only affects RENDERING/hit-testing/properties display —
            // it does NOT rewrite `p.closed` in the store, so it's a
            // read-time reconciliation, not a silent data mutation; see
            // `HitTesting.swift`'s "Closed" property row, which reads
            // `run.closed` (this resolved value), not the raw payload flag.
            var effectiveClosed = p.closed
            if !effectiveClosed, e.kind != .leader, vCount >= 3 {
                let first = store.vertexArena[vStart]
                let last = store.vertexArena[vStart + vCount - 1]
                let dx = last.x - first.x, dy = last.y - first.y, dz = last.z - first.z
                if dx * dx + dy * dy + dz * dz < 1e-12 { effectiveClosed = true }
            }
            a.beginRun()
            for k in 0..<vCount {
                let v = store.vertexArena[vStart + k]
                let bulge = store.scalarArena[bStart + k]
                a.addRunPoint(tp(v.x, v.y))
                if bulge != 0 {
                    let isLast = k == vCount - 1
                    if !isLast || effectiveClosed {
                        let nv = store.vertexArena[vStart + (k + 1) % vCount]
                        var mids: [CGPoint] = []
                        appendBulgeArc(from: CGPoint(x: v.x, y: v.y),
                                       to: CGPoint(x: nv.x, y: nv.y),
                                       bulge: bulge, into: &mids)
                        for m in mids { a.addRunPoint(m.applying(t)) }
                    }
                }
            }
            a.endRun(closed: effectiveClosed, kind: e.kind, insertId: ctx.insertId, entityId: entityId, lineweight: h.lineweight)

        case .spline:
            let p = store.splines[pIdx]
            let cCount = Int(p.controlCount)
            guard cCount >= 2 else { break }
            let cStart = Int(p.controlStart)
            let control = (cStart..<(cStart + cCount)).map { store.vertexArena[$0].cgPoint }
            let knots = p.knotCount > 0
                ? Array(store.scalarArena[Int(p.knotStart)..<Int(p.knotStart + p.knotCount)]) : []
            let weights = p.weightCount > 0
                ? Array(store.scalarArena[Int(p.weightStart)..<Int(p.weightStart + p.weightCount)]) : []
            // Matches DXFParser's SPLINE handling exactly: tessellate
            // when control+knots form a valid clamped B-spline (always
            // true for AutoCAD-authored SPLINEs); the legacy fit-point
            // fallback isn't representable from a stored SplinePayload
            // (fit points aren't retained) and is not exercised by any
            // fixture or the verified 731MB file (every SPLINE there has
            // valid control+knots) — falls back to the raw control
            // polygon instead, same as the parser's final `else`.
            var pts: [CGPoint]
            if knots.count == control.count + Int(p.degree) + 1 {
                let samples = min(72, max(8, control.count * 3))
                pts = SplineEvaluator.tessellate(controlPoints: control, knots: knots,
                                                 weights: weights.count == control.count ? weights : nil,
                                                 degree: Int(p.degree), samples: samples)
            } else {
                pts = control
            }
            guard pts.count > 1 else { break }
            a.beginRun()
            for pt in pts { a.addRunPoint(tp(pt.x, pt.y)) }
            a.endRun(closed: p.closed, kind: e.kind, insertId: ctx.insertId, entityId: entityId)

        case .ellipse:
            let el = store.ellipses[pIdx]
            let majorLen = el.majorAxisEndpoint.length
            guard majorLen > 0 else { break }
            let minorLen = majorLen * el.ratio
            let rot = atan2(el.majorAxisEndpoint.y, el.majorAxisEndpoint.x)
            let start = el.startParam, end = el.endParam
            let sweep = end > start ? end - start : end + 2 * .pi - start
            let steps = max(16, min(96, safeInt(sweep / 0.08)))
            var pts: [CGPoint] = []
            pts.reserveCapacity(steps + 1)
            for k in 0...steps {
                let ang = start + sweep * Double(k) / Double(steps)
                let ex = majorLen * cos(ang), ey = minorLen * sin(ang)
                pts.append(CGPoint(x: el.center.x + ex * cos(rot) - ey * sin(rot),
                                   y: el.center.y + ex * sin(rot) + ey * cos(rot)))
            }
            let isFull = abs(sweep - 2 * .pi) < 1e-6
            a.beginRun()
            for pt in pts { a.addRunPoint(tp(pt.x, pt.y)) }
            a.endRun(closed: isFull, kind: e.kind, insertId: ctx.insertId, entityId: entityId)

        case .solid, .face3d:
            let p = store.polylines[pIdx]
            let vCount = Int(p.vertsCount)
            // SOLID/TRACE always have >= 3 verts; a 3DFACE with per-edge
            // invisibility stores each visible edge as its own 2-vertex
            // OPEN polyline fragment (see EntityStoreParser) — allow that
            // shape through instead of requiring a closed >= 3-gon.
            guard vCount >= 2 else { break }
            let vStart = Int(p.vertsStart)
            let world = (0..<vCount).map { tp(store.vertexArena[vStart + $0].x, store.vertexArena[vStart + $0].y) }
            if h.type == .solid {
                guard vCount >= 3 else { break }
                a.fill.move(to: world[0])
                for pt in world.dropFirst() { a.fill.addLine(to: pt) }
                a.fill.closeSubpath()
                a.addFillRun(world, kind: e.kind, insertId: ctx.insertId, entityId: entityId)
            } else {
                // 3DFACE: stroked outline, not a fill (matches DXFParser:
                // `.polyline(..., closed:)` goes to `runs`, never
                // `fillRuns`) — closed for the fully-visible 4/3-vertex
                // face, open for a per-edge-invisible fragment.
                a.beginRun()
                for pt in world { a.addRunPoint(pt) }
                a.endRun(closed: p.closed, kind: e.kind, insertId: ctx.insertId, entityId: entityId)
            }

        case .hatch:
            let hp = store.hatches[pIdx]
            // This hatch's OWN transparency (independent of its layer's —
            // see `HatchPayload.transparency`'s own doc comment), baked into
            // its `fillRuns`/(for a pattern hatch's diagonal lines) `runs`
            // entries since the merged `a.fill` CGPath below has no
            // per-entity granularity left by render time.
            let ownAlpha = CGFloat(1 - min(max(hp.transparency, 0), 100) / 100)
            var worldLoops: [[CGPoint]] = []
            for r in Int(hp.loopRangeStart)..<Int(hp.loopRangeStart + hp.loopRangeCount) {
                let range = store.hatchLoopRanges[r]
                let count = Int(range.vertCount)
                guard count >= 3 else { continue }
                let start = Int(range.vertStart)
                let world = (0..<count).map { tp(store.vertexArena[start + $0].x, store.vertexArena[start + $0].y) }
                worldLoops.append(world)
                if hp.isSolid {
                    a.fill.move(to: world[0])
                    for pt in world.dropFirst() { a.fill.addLine(to: pt) }
                    a.fill.closeSubpath()
                    a.addFillRun(world, kind: .hatch, insertId: ctx.insertId, entityId: entityId, fillAlpha: ownAlpha)
                }
            }
            if !hp.isSolid {
                // Boundary outline, same as before — a non-solid hatch's
                // interior is painted ONLY by the diagonal-line pattern
                // below (no translucent fill approximation): the
                // Properties panel's "Hatch Density"/"Fill Transparency"
                // controls apply directly and exactly to those lines,
                // rather than a second, separately-alpha'd fill layer a
                // user's transparency slider wouldn't visibly affect.
                for world in worldLoops {
                    a.beginRun()
                    for pt in world { a.addRunPoint(pt) }
                    a.endRun(closed: true, kind: .hatch, insertId: ctx.insertId, entityId: entityId)
                }
                // Diagonal-line fill pattern ("Hatch Type: Diagonal Lines" —
                // see `HatchStyle`'s own doc comment). `hp.scale` doubles as
                // the Properties panel's "Hatch Density" — real AutoCAD
                // HPSCALE semantics (a BIGGER scale means a BIGGER pattern,
                // i.e. MORE SPACE between lines), so density here is its
                // reciprocal: a bigger `scale` means fewer/more-spread-out
                // lines, matching `ShadeLayer.crosshatchSegments`' own
                // "bigger density = more, closer lines" contract exactly.
                let density = hp.scale > 0 ? 1 / hp.scale : 1
                for world in worldLoops {
                    let worldVec3 = world.map { Vec3($0) }
                    let segments = ShadeLayer.crosshatchSegments(for: worldVec3, angleDeg: hp.angle, density: density)
                    for (p1, p2) in segments {
                        a.beginRun()
                        a.addRunPoint(p1.cgPoint)
                        a.addRunPoint(p2.cgPoint)
                        a.endRun(closed: false, kind: .hatch, insertId: ctx.insertId, entityId: entityId,
                                strokeAlpha: ownAlpha)
                    }
                }
            }

        case .point:
            let p = store.points[pIdx]
            a.points.append(tp(p.p.x, p.p.y))
            a.strokes.pointInsertIds.append(ctx.insertId)
            a.strokes.pointEntityIds.append(entityId)

        case .text, .attrib, .mtext:
            let position: Vec3
            let height: Double
            var rotation: Double
            let widthFactor: Double
            let text: String
            var hAlign = 0, vAlign = 0
            var anchor: CGPoint
            // MIRRTEXT=1 (Phase 4.2 MIRROR command): TextPayload.isBackwards
            // marks a TEXT/ATTRIB entity that was mirrored in place with its
            // glyphs deliberately kept backwards (see EntityTransform.text's
            // MIRRTEXT branch) — MTEXT carries no such flag (always false).
            var isBackwards = false

            if h.type == .mtext {
                let mp = store.mtexts[pIdx]
                position = mp.insertion; height = mp.height; rotation = mp.rotationDeg
                widthFactor = 1
                text = store.strings.string(for: mp.stringId)
                let attach = Int(mp.attachPoint)
                hAlign = (attach - 1) % 3
                vAlign = [3, 2, 1][min(max((attach - 1) / 3, 0), 2)]
                anchor = position.cgPoint
            } else {
                let tp2 = store.texts[pIdx]
                position = tp2.position; height = tp2.height; rotation = tp2.rotationDeg
                widthFactor = tp2.widthFactor
                text = store.strings.string(for: tp2.stringId)
                hAlign = Int(tp2.hAlign); vAlign = Int(tp2.vAlign)
                isBackwards = tp2.isBackwards
                // alignPosition always defaults to `position` when code
                // 11/21 was absent at parse time (see EntityStoreParser),
                // so this matches DXFParser's `tr.p2 ?? tr.p1` exactly.
                anchor = (hAlign == 0 && vAlign == 0) ? position.cgPoint : tp2.alignPosition.cgPoint
            }

            // A block-mirrored instance (ctx.mirrored) AND an entity that is
            // itself individually backwards (isBackwards, from a direct
            // MIRRTEXT=1 MIRROR command) compound via XOR: mirroring an
            // already-backwards text a second time (e.g. its owning INSERT
            // also has negative extrusion) cancels back to forward-reading,
            // exactly as two x-flips should.
            let netMirroredX = ctx.mirrored != isBackwards

            var item = TextItem(position: .zero,
                                height: CGFloat(height) * ctx.scale,
                                rotationDegrees: rotation + ctx.rotationDegrees,
                                widthFactor: CGFloat(widthFactor),
                                text: text,
                                hAlign: hAlign, vAlign: vAlign,
                                mirroredX: netMirroredX,
                                kind: e.kind, insertId: ctx.insertId, entityId: entityId)
            item.position = tp(anchor.x, anchor.y)
            if ctx.mirrored, !isBackwards {
                // Existing MIRRTEXT=0-equivalent behavior for block-mirrored
                // (extrusion Z<0) text content: re-normalize so it stays
                // readable rather than rendering backwards. Skipped when
                // THIS entity is independently marked isBackwards — that
                // case already resolved to `netMirroredX` above and must
                // render via the actual x-flip, not this re-normalization.
                item.rotationDegrees = ctx.rotationDegrees - 180 - rotation
                if item.hAlign == 0 { item.hAlign = 2 }
                else if item.hAlign == 2 { item.hAlign = 0 }
                item.mirroredX = false
            }
            a.texts.append(item)
            a.addBoundsPoint(item.position)

        case .insert, .dimension:
            break // handled by the caller's walk over INSERT/DIMENSION (insert-like expansion), not renderable geometry itself

        default:
            break
        }
    }

    /// Builds a `StoreEntityView` for slot `id`, or nil if deleted /
    /// unsupported-for-rendering. Extracted from `build`'s local `view`
    /// closure (which now just calls this) so Phase 1.6's incremental path
    /// resolves entity kind identically to a full rebuild.
    private static func viewOf(_ id: EntityID, store: EntityStore) -> StoreEntityView? {
        guard let h = store.header(id), !h.flags.contains(.deleted) else { return nil }
        let kind: EntityKind
        switch h.type {
        case .line: kind = .line
        case .point: kind = .point
        case .circle: kind = .circle
        case .arc: kind = .arc
        case .ellipse: kind = .ellipse
        case .lwpolyline, .polyline2d, .polyline3d: kind = .polyline
        case .spline: kind = .spline
        case .solid: kind = .solid
        case .face3d: kind = .face3d
        case .hatch: kind = .hatch
        case .text: kind = .text
        case .mtext: kind = .mtext
        case .attrib: kind = .attrib
        case .leader: kind = .leader
        case .insert, .dimension: kind = .other
        default: return nil
        }
        return StoreEntityView(id: id, kind: kind, layerId: h.layerId, aci: h.aci,
                               trueColor: h.trueColor, linetypeId: h.linetypeId,
                               mirrorOCS: h.flags.contains(.mirrorOCS))
    }

    /// Resolves an entity's effective (layer, color, linetype) under `ctx`.
    /// Thin wrapper over `PropertyResolver.resolve` (Phase 6.2 extraction) —
    /// this function's OWN inheritance decision tree used to live here
    /// inline; it is now a shared, `EntityHeader`-native implementation in
    /// PropertyResolver.swift that both this file and `Editing/Explode.swift`
    /// call, so the load-bearing BYLAYER/BYBLOCK/layer-0-in-block logic
    /// exists exactly once. This wrapper's only remaining job is converting
    /// the resolver's native (aci/trueColor) pair into the `ResolvedColor`
    /// paint value this file's render path needs (eagerly looking up a
    /// BYLAYER color's actual layer paint, which the native resolver
    /// deliberately leaves dynamic since EXPLODE needs to preserve BYLAYER
    /// AS BYLAYER rather than bake it).
    private static func resolveAppearance(_ e: StoreEntityView, _ ctx: Ctx, parsed: EditableParsedDocument)
        -> (layer: Int32, color: ResolvedColor, ltype: Int16) {
        func layerColor(_ id: Int32) -> ResolvedColor {
            let i = Int(id)
            return i < parsed.layers.count ? parsed.layers[i].color : .foreground
        }
        func layerLinetype(_ id: Int32) -> Int16 {
            let i = Int(id)
            return i < parsed.layers.count ? Int16(parsed.layers[i].linetypeId) : 0
        }
        let blockCtx = PropertyResolver.BlockContext(
            subLayer: ctx.subLayer,
            byBlockAci: nativeAci(for: ctx.byBlockColor),
            byBlockTrueColor: nativeTrueColor(for: ctx.byBlockColor),
            byBlockLinetypeId: ctx.byBlockLinetype)
        let resolved = PropertyResolver.resolve(layerId: e.layerId, aci: e.aci, trueColor: e.trueColor,
                                                linetypeId: e.linetypeId, in: blockCtx)
        var color: ResolvedColor
        if resolved.trueColor != 0xFF00_0000 {
            color = .rgb(resolved.trueColor)
        } else if resolved.aci == 256 {
            color = layerColor(resolved.layerId)
        } else if resolved.aci == 7 {
            color = .foreground
        } else {
            color = .rgb(ACIPalette.rgb(forACI: Int(resolved.aci)))
        }
        var lt = resolved.linetypeId
        if lt == -1 { lt = layerLinetype(resolved.layerId) }
        if lt < 0 || Int(lt) >= parsed.linetypes.count { lt = 0 }
        return (resolved.layerId, color, lt)
    }

    /// `Ctx.byBlockColor`/`byBlockLinetype` are stored as the ALREADY-fully-
    /// resolved `ResolvedColor` (a render-only type with no ACI/true-color
    /// distinction) — these two helpers reconstruct a native (aci,
    /// trueColor) pair equivalent enough to feed back into
    /// `PropertyResolver.BlockContext` without changing `Ctx`'s own stored
    /// representation (which `emitInsertSubtree`/other call sites still
    /// depend on). `.foreground` maps to ACI 7 (matches `Ctx()`'s default);
    /// `.rgb` maps to an explicit true color so the wrapper's `trueColor !=
    /// sentinel` branch fires and paints exactly that RGB, same as before
    /// this refactor when `color = ctx.byBlockColor` was assigned directly.
    private static func nativeAci(for color: ResolvedColor) -> Int16 {
        // Always 7 (foreground): when `color` is `.rgb`, `nativeTrueColor`
        // below supplies a non-sentinel true color, which the resolver's
        // `trueColor != sentinel` branch checks FIRST and takes priority
        // over this `aci` value regardless of what it is — so this only
        // actually matters for the `.foreground` case, where 7 is correct.
        return 7
    }
    private static func nativeTrueColor(for color: ResolvedColor) -> UInt32 {
        if case .rgb(let v) = color { return v }
        return 0xFF00_0000
    }

    // MARK: - Phase 1.6: incremental single-entity / insert-subtree emission
    //
    // These entry points let `RegenCoordinator` append freshly emitted
    // geometry for a small set of touched entities WITHOUT re-walking the
    // whole document, by calling exactly the same `emitPrimitive`/
    // `resolveAppearance`/`viewOf` logic `build` uses for a full regen.
    // Scope: entities directly owned by `.model`/`.paper` (top-level, no
    // parent transform), OR a top-level INSERT's full block-content subtree.
    // Entities living INSIDE a block definition are out of scope here (their
    // render impact fans out through every place that block is inserted) —
    // callers editing block content should mark the block dirty and go
    // through `RegenCoordinator.regenerateDirtyBlocks`, which performs a
    // bounded incremental patch or a full rebuild depending on fan-out.

    /// Emits geometry for one top-level (`.model`/`.paper`-owned) entity, as
    /// grouped `EmittedPrimitive`s ready for `groupPrimitives`. Empty for a
    /// deleted, unsupported, or non-renderable (INSERT/DIMENSION spawn no
    /// primitives of their own — see `emitInsertSubtree`) entity.
    static func emitSingleTopLevel(id: EntityID, store: EntityStore,
                                   parsed: EditableParsedDocument) -> [EmittedPrimitive] {
        guard let h = store.header(id), !h.flags.contains(.deleted) else { return [] }
        guard h.owner.isModel || h.owner.isPaper else { return [] }
        guard viewOf(id, store: store) != nil else { return [] }
        // INSERT/DIMENSION have no geometry of their own — their content is
        // the referenced block's subtree, handled by `emitInsertSubtree`.
        guard h.type != .insert, h.type != .dimension else { return [] }
        return emitOneEntity(id: id, h: h, baseCtx: Ctx(), store: store, parsed: parsed)
    }

    /// Emits geometry for one entity owned by an ORPHAN-ROOT block (a block
    /// with real geometry that nothing ever INSERTs — see the load-bearing
    /// synthetic-root behavior in `build`'s `walkSyntheticRoot`/
    /// `GeometryBuilder`). Because an orphan root is rendered at exactly ONE
    /// place (there is no INSERT to instance it more than once), a member
    /// entity's render-space placement is unambiguous: translate by
    /// `-rootBase`, same as `walkSyntheticRoot` sets up, optionally under
    /// `xrefId` if the orphan root's block is itself xref-flagged. This is
    /// what makes editing this file's real content (which lives almost
    /// entirely in orphan-root blocks, per its "nearly empty model space"
    /// architecture) cheap — see `RegenCoordinator.emitDelta`, which routes
    /// a block-owned entity here when the owning block is confirmed to be an
    /// orphan root, falling back to `regenerateDirtyBlocks`'s full/bounded
    /// rebuild for entities inside a NORMALLY-inserted block (those can fan
    /// out to many placements, which this single-placement fast path can't
    /// represent).
    static func emitOrphanRootMember(id: EntityID, rootBase: CGPoint, xrefId: Int16,
                                     store: EntityStore, parsed: EditableParsedDocument) -> [EmittedPrimitive] {
        guard let h = store.header(id), !h.flags.contains(.deleted) else { return [] }
        guard viewOf(id, store: store) != nil else { return [] }
        guard h.type != .insert, h.type != .dimension else { return [] }
        var ctx = Ctx()
        ctx.t = CGAffineTransform(translationX: -Double(rootBase.x), y: -Double(rootBase.y))
        ctx.xrefId = xrefId
        return emitOneEntity(id: id, h: h, baseCtx: ctx, store: store, parsed: parsed)
    }

    /// Shared tail of `emitSingleTopLevel`/`emitOrphanRootMember`: applies
    /// mirrorOCS the same way `build`'s `walk` does for a leaf entity, then
    /// resolves appearance and emits.
    private static func emitOneEntity(id: EntityID, h: EntityHeader, baseCtx: Ctx,
                                      store: EntityStore, parsed: EditableParsedDocument) -> [EmittedPrimitive] {
        var ev = viewOf(id, store: store)!
        var ctx = baseCtx
        if ev.mirrorOCS {
            ctx.t = CGAffineTransform(scaleX: -1, y: 1).concatenating(baseCtx.t)
            ctx.mirrored = true
            ev.mirrorOCS = false
        }
        let (layer, color, ltype) = resolveAppearance(ev, ctx, parsed: parsed)
        let key = GroupKey(layerId: layer, color: color, linetypeId: ltype, xrefId: ctx.xrefId)
        let acc = Accumulator()
        emitPrimitive(ev, h, ctx, store: store, into: acc)
        return [EmittedPrimitive(key: key, accumulator: acc)]
    }

    /// One (GroupKey, Accumulator) pairing produced by incremental emission —
    /// `groupPrimitives` merges same-key entries (multiple touched entities
    /// can share a GroupKey) and finalizes them into `RenderGroup`s exactly
    /// like `build`'s `finalize` does.
    struct EmittedPrimitive {
        var key: GroupKey
        var accumulator: Accumulator
    }

    /// Merges `EmittedPrimitive`s sharing a `GroupKey` into finished
    /// `RenderGroup`s — the incremental-path equivalent of `build`'s local
    /// `finalize`, minus the sort (delta groups are appended in whatever
    /// order the caller emits them; sort order across the WHOLE array only
    /// matters for the initial full build's deterministic layer-by-layer
    /// z-order, which delta groups already lose the instant they're
    /// tombstoned/appended piecemeal — see RegenCoordinator's doc comment).
    static func groupPrimitives(_ prims: [EmittedPrimitive]) -> [RenderGroup] {
        var byKey: [GroupKey: Accumulator] = [:]
        var order: [GroupKey] = []
        for p in prims {
            if let existing = byKey[p.key] {
                // Merge p.accumulator's content into the existing one so two
                // touched entities sharing (layer,color,linetype,xref) land
                // in ONE delta group, not two — keeps delta-group growth
                // proportional to distinct appearances touched, not entities.
                merge(p.accumulator, into: existing)
            } else {
                byKey[p.key] = p.accumulator
                order.append(p.key)
            }
        }
        return order.map { key in
            let a = byKey[key]!
            let b = a.bounds
            return RenderGroup(layerId: Int(key.layerId), color: key.color,
                               linetypeId: Int(key.linetypeId), xrefId: Int(key.xrefId),
                               strokes: a.strokes, fillPath: a.fill, patternFillPath: a.patternFill,
                               points: a.points, texts: a.texts,
                               bounds: b.isNull ? .zero : b, entityCount: a.count)
        }
    }

    /// Appends `src`'s accumulated geometry onto `dst` in place, re-basing
    /// every point/run/arc/fill-run index by `dst`'s current point counts —
    /// used when two touched entities land in the same delta `GroupKey`.
    private static func merge(_ src: Accumulator, into dst: Accumulator) {
        let pointBase = Int32(dst.strokes.points.count)
        dst.strokes.points.append(contentsOf: src.strokes.points)
        for var run in src.strokes.runs {
            run.start += pointBase
            dst.strokes.runs.append(run)
        }
        dst.strokes.arcs.append(contentsOf: src.strokes.arcs)
        dst.strokes.pointInsertIds.append(contentsOf: src.strokes.pointInsertIds)
        dst.strokes.pointEntityIds.append(contentsOf: src.strokes.pointEntityIds)
        let fillBase = Int32(dst.strokes.fillPoints.count)
        dst.strokes.fillPoints.append(contentsOf: src.strokes.fillPoints)
        for var run in src.strokes.fillRuns {
            run.start += fillBase
            dst.strokes.fillRuns.append(run)
        }
        dst.points.append(contentsOf: src.points)
        dst.texts.append(contentsOf: src.texts)
        dst.count += src.count
        if !src.fill.isEmpty { dst.fill.addPath(src.fill) }
        if !src.patternFill.isEmpty { dst.patternFill.addPath(src.patternFill) }
        dst.addBoundsPoint(CGPoint(x: src.bounds.minX, y: src.bounds.minY))
        dst.addBoundsPoint(CGPoint(x: src.bounds.maxX, y: src.bounds.maxY))
    }

    struct InsertSubtreeResult {
        var modelPrimitives: [EmittedPrimitive] = []
        var paperPrimitives: [EmittedPrimitive] = []
        /// One `InsertInstance` per successfully-expanded top-level insert
        /// in `ids` (same order, but SPARSE — an id that didn't resolve to
        /// a real, non-empty block is simply absent) — the caller
        /// (`RegenCoordinator`) is responsible for appending these to
        /// `document.inserts` and knows the array's length, which is
        /// exactly the index this function needs to stamp into each
        /// emitted primitive's `insertId` field; see `newInstances`'
        /// parameter-passing convention below for how that circular
        /// dependency (need the future index before emission, but the
        /// future index depends on appending) is resolved: the CALLER
        /// reserves indices up front (`document.inserts.count + n`) and
        /// passes them in via `startingIndex`.
        var instances: [(entityID: EntityID, instance: InsertInstance)] = []
    }

    /// Re-walks the full block-content subtree of each top-level INSERT in
    /// `ids` (MINSERT array expansion, nested INSERTs, mirrorOCS, orphan-root
    /// N/A here since these are always real INSERT entities) — the
    /// incremental-path equivalent of `build`'s `walk` for exactly the
    /// INSERT case, reusing `emitPrimitive`/`resolveAppearance` per leaf
    /// entity. Used by `RegenCoordinator.regenerateDirtyBlocks` (after a
    /// block redefinition) and `RegenCoordinator.apply` (for a freshly
    /// ADDED top-level insert — see that call site's own doc comment for
    /// the "click-selects-the-whole-insert" gap this closes).
    ///
    /// `startingIndex`: the index `document.inserts.count` will have BEFORE
    /// the caller appends this call's `instances` — needed so this
    /// function can stamp the CORRECT future `document.inserts` index into
    /// each top-level insert's own emitted primitives' `insertId` field at
    /// emission time (matching `build`'s own `childInsertId =
    /// Int32(inserts.count)` timing exactly, just with the count supplied
    /// by the caller instead of a local array this function doesn't own).
    static func emitInsertSubtree(ids: [EntityID], startingIndex: Int32, store: EntityStore,
                                  parsed: EditableParsedDocument) -> InsertSubtreeResult {
        var result = InsertSubtreeResult()
        var nextIndex = startingIndex
        for id in ids {
            guard let h = store.header(id), !h.flags.contains(.deleted), h.type == .insert,
                  h.payload >= 0 else { continue }
            let ip = store.inserts[Int(h.payload)]
            let name = store.strings.string(for: ip.blockNameId)
            guard let block = parsed.blocks[name], block.entityCount > 0 else { continue }
            guard let ev = viewOf(id, store: store) else { continue }
            let ctx = Ctx()
            // The insert itself emits no geometry — only its (layer, color,
            // linetype) feed BYBLOCK resolution for its children below.
            let (layer, color, ltype) = resolveAppearance(ev, ctx, parsed: parsed)
            let insertIndex = nextIndex
            nextIndex += 1
            var pos = CGPoint(x: ip.position.x, y: ip.position.y)
            if h.flags.contains(.mirrorOCS) { pos.x = -pos.x }
            result.instances.append((entityID: id, instance: InsertInstance(
                name: name, position: pos, scaleX: CGFloat(ip.scale.x), scaleY: CGFloat(ip.scale.y),
                rotationDegrees: ip.rotationDeg, layerId: layer, xrefId: ctx.xrefId, entityId: id.raw)))
            let rows = max(1, Int(ip.rows)), cols = max(1, Int(ip.cols))
            var prims: [EmittedPrimitive] = []
            for row in 0..<rows {
                for col in 0..<cols {
                    var bt = CGAffineTransform.identity
                    bt = bt.translatedBy(x: ip.position.x, y: ip.position.y)
                    bt = bt.rotated(by: ip.rotationDeg * .pi / 180)
                    bt = bt.translatedBy(x: Double(col) * ip.colSpacing, y: Double(row) * ip.rowSpacing)
                    bt = bt.scaledBy(x: ip.scale.x, y: ip.scale.y)
                    bt = bt.translatedBy(x: -Double(block.base.x), y: -Double(block.base.y))
                    if h.flags.contains(.mirrorOCS) {
                        bt = bt.concatenating(CGAffineTransform(scaleX: -1, y: 1))
                    }
                    let combined = bt
                    var child = ctx
                    child.t = combined
                    let det = combined.a * combined.d - combined.b * combined.c
                    child.scale = sqrt(abs(det))
                    child.scaleX = hypot(combined.a, combined.b)
                    child.scaleY = hypot(combined.c, combined.d)
                    child.mirrored = det < 0
                    child.rotationDegrees = atan2(combined.b, combined.a) * 180 / .pi
                    child.subLayer = layer
                    child.byBlockColor = color
                    child.byBlockLinetype = ltype
                    child.xrefId = ctx.xrefId
                    child.insertId = insertIndex
                    child.depth = 1
                    walkBlockRange(start: block.entityStart, count: block.entityCount, ctx: child,
                                   store: store, parsed: parsed, into: &prims)
                }
            }
            if h.owner.isModel { result.modelPrimitives.append(contentsOf: prims) }
            else if h.owner.isPaper { result.paperPrimitives.append(contentsOf: prims) }
        }
        return result
    }

    /// Recursive block-range walk shared by `emitInsertSubtree` — mirrors
    /// `build`'s local `walk(.blockRange(...))` case for nested INSERTs.
    private static func walkBlockRange(start: Int32, count: Int32, ctx: Ctx,
                                       store: EntityStore, parsed: EditableParsedDocument,
                                       into prims: inout [EmittedPrimitive]) {
        guard ctx.depth <= 32, count > 0 else { return }
        for i in Int(start)..<Int(start + count) {
            let id = EntityID(raw: Int32(i))
            guard let h = store.header(id), !h.flags.contains(.deleted) else { continue }

            if h.type == .insert || h.type == .dimension {
                let blockNameId: Int32
                let position: Vec3
                let scale: Vec3
                let rotationDeg: Double
                let cols: Int32, rows: Int32, colSpacing: Double, rowSpacing: Double
                if h.type == .insert {
                    let ip = store.inserts[Int(h.payload)]
                    blockNameId = ip.blockNameId; position = ip.position; scale = ip.scale
                    rotationDeg = ip.rotationDeg; cols = ip.cols; rows = ip.rows
                    colSpacing = ip.colSpacing; rowSpacing = ip.rowSpacing
                } else {
                    let dp = store.dimensions[Int(h.payload)]
                    blockNameId = dp.blockNameId; position = Vec3(x: 0, y: 0); scale = Vec3(x: 1, y: 1, z: 1)
                    rotationDeg = 0; cols = 1; rows = 1; colSpacing = 0; rowSpacing = 0
                }
                let name = store.strings.string(for: blockNameId)
                guard let block = parsed.blocks[name], block.entityCount > 0 else { continue }
                guard let ev = viewOf(id, store: store) else { continue }
                let (layer, color, ltype) = resolveAppearance(ev, ctx, parsed: parsed)
                let rr = max(1, Int(rows)), cc = max(1, Int(cols))
                for row in 0..<rr {
                    for col in 0..<cc {
                        var bt = CGAffineTransform.identity
                        bt = bt.translatedBy(x: position.x, y: position.y)
                        bt = bt.rotated(by: rotationDeg * .pi / 180)
                        bt = bt.translatedBy(x: Double(col) * colSpacing, y: Double(row) * rowSpacing)
                        bt = bt.scaledBy(x: scale.x, y: scale.y)
                        bt = bt.translatedBy(x: -Double(block.base.x), y: -Double(block.base.y))
                        if h.flags.contains(.mirrorOCS) {
                            bt = bt.concatenating(CGAffineTransform(scaleX: -1, y: 1))
                        }
                        let combined = bt.concatenating(ctx.t)
                        var child = ctx
                        child.t = combined
                        let det = combined.a * combined.d - combined.b * combined.c
                        child.scale = sqrt(abs(det))
                        child.scaleX = hypot(combined.a, combined.b)
                        child.scaleY = hypot(combined.c, combined.d)
                        child.mirrored = det < 0
                        child.rotationDegrees = atan2(combined.b, combined.a) * 180 / .pi
                        child.subLayer = layer
                        child.byBlockColor = color
                        child.byBlockLinetype = ltype
                        child.depth = ctx.depth + 1
                        walkBlockRange(start: block.entityStart, count: block.entityCount, ctx: child,
                                      store: store, parsed: parsed, into: &prims)
                    }
                }
                continue
            }

            guard var ev = viewOf(id, store: store) else { continue }
            var ctx2 = ctx
            if ev.mirrorOCS {
                ctx2.t = CGAffineTransform(scaleX: -1, y: 1).concatenating(ctx.t)
                ctx2.mirrored.toggle()
                ev.mirrorOCS = false
            }
            let (layer, color, ltype) = resolveAppearance(ev, ctx2, parsed: parsed)
            let key = GroupKey(layerId: layer, color: color, linetypeId: ltype, xrefId: ctx2.xrefId)
            let acc = Accumulator()
            emitPrimitive(ev, h, ctx2, store: store, into: acc)
            prims.append(EmittedPrimitive(key: key, accumulator: acc))
        }
    }

    // Keep the closure-mutated flag opaque to Swift's local flow analysis.
    @inline(never) private static func expansionNeedsRebalance(_ truncated: Bool) -> Bool { truncated }

    static func build(from parsed: EditableParsedDocument,
                      parseSeconds: Double,
                      progress: (Double) -> Void) -> DXFDocument {
        let t0 = Date()
        let store = parsed.store

        let sheetSupport = SheetRenderSupport(parsed)
        var renderingPaper = false
        var modelImages: [RasterPlacement] = []
        var paperImages: [RasterPlacement] = []
        var viewports: [PaperViewport] = []
        let paperLayout = parsed.paperLayouts.first { $0.id == parsed.activePaperLayoutID }

        // ---- Identify xrefs and route modern model/paper-space blocks ----
        // (Same rules as GeometryBuilder: *MODEL_SPACE/*PAPER_SPACE block
        // content is treated as if it were emitted directly to model/paper
        // space, since the eager parser already appended it under
        // OwnerRef.block(index) like any other block.)
        var xrefs: [XrefInfo] = []
        var xrefIdByBlock: [String: Int16] = [:]

        var insertCounts: [String: Int] = [:]
        for h in store.headers where h.type == .insert && !h.flags.contains(.deleted) {
            let ip = store.inserts[Int(h.payload)]
            let name = store.strings.string(for: ip.blockNameId)
            insertCounts[name, default: 0] += 1
        }

        // *MODEL_SPACE/*PAPER_SPACE block content routes to model/paper.
        // Track which block names those are so `walk` can special-case them.
        var modelSpaceBlockNames: Set<String> = []
        var paperSpaceBlockNames: Set<String> = []

        for (name, b) in parsed.blocks.sorted(by: { $0.key < $1.key }) {
            let upper = name.uppercased()
            if upper.hasPrefix("*MODEL_SPACE") || upper == "$MODEL_SPACE" {
                modelSpaceBlockNames.insert(name)
            } else if upper.hasPrefix("*PAPER_SPACE") {
                paperSpaceBlockNames.insert(name)
            } else if b.isXref {
                let id = Int16(xrefs.count)
                xrefIdByBlock[name] = id
                xrefs.append(XrefInfo(id: Int(id), blockName: name,
                                      path: b.xrefPath.isEmpty ? name : b.xrefPath,
                                      sourcePath: b.xrefSourcePath,
                                      loadedPath: b.xrefLoadedPath,
                                      isResolved: b.wasResolved || b.entityCount > 0,
                                      entityCount: Int(b.entityCount),
                                      insertCount: insertCounts[name] ?? 0))
            }
        }

        // ---- Orphan-block synthetic roots (load-bearing; see GeometryBuilder) ----
        // A block with real geometry that nothing INSERTs anywhere still
        // renders, as a synthetic top-level insert at its own base point.
        var syntheticRoots: [(name: String, base: CGPoint)] = []
        for (name, b) in parsed.blocks.sorted(by: { $0.key < $1.key }) {
            guard b.entityCount > 0, insertCounts[name] == nil, !b.isXrefDependent else { continue }
            let upper = name.uppercased()
            guard !upper.hasPrefix("*"), !upper.hasPrefix("$") else { continue }
            syntheticRoots.append((name, b.base))
        }

        var inserts: [InsertInstance] = []

        // ---- Expansion ----
        var accs: [GroupKey: Accumulator] = [:]
        var expandedCount = 0
        var truncated = false
        var layerCounts = [Int](repeating: 0, count: parsed.layers.count)
        // Block indices currently OPEN on the recursion path (see `walk`'s
        // cycle guard). A single mutable set (add-on-enter / remove-on-exit)
        // rather than a per-Ctx copy — the walk is single-threaded DFS, so the
        // set always holds exactly the current ancestor chain, and this avoids
        // copying a Set at every one of millions of expansion steps.
        var activeBlockIndices = Set<Int32>()

        // Every INSERT that owns at least one ATTRIB child, precomputed in ONE
        // linear pass over the headers. The walk below needs this per-INSERT
        // ("does this nested insert carry its own attribute VALUES, and
        // therefore deserve its own selectable `InsertInstance`?" — see that
        // call site's doc comment). `EntityStore.children(of:)` is itself a
        // FULL linear scan of every header, so calling it once per INSERT
        // inside the walk would be O(inserts x entities) — on the real
        // reference file (3.4M entities, ~14.8k INSERTs) that is tens of
        // billions of header reads, i.e. a hang. This flips it to O(entities)
        // once, then O(1) membership tests during the walk.
        var attributeOwningInserts = Set<Int32>()
        // Keyed by parent INSERT `EntityID.raw`, ATTRIB children only, in
        // the same single pass — the O(1) replacement for calling
        // `store.children(of: id)` per INSERT below (see that call site's
        // own doc comment, and `EntityStore.childrenByParent()`'s doc
        // comment, for the full "stuck at 51%"-class performance
        // rationale: an UNGUARDED `children(of:)` call here would be a
        // second O(inserts x entities) hang, this time in the RENDER walk
        // rather than xref merge, the moment the merge-side one was fixed).
        var attribChildrenByParent: [Int32: [EntityID]] = [:]
        for i in store.headers.indices {
            let ah = store.headers[i]
            guard ah.type == .attrib, !ah.flags.contains(.deleted),
                  let parent = ah.owner.parentEntityID else { continue }
            attributeOwningInserts.insert(parent.raw)
            attribChildrenByParent[parent.raw, default: []].append(EntityID(raw: Int32(i)))
        }

        // ---- Fair-share expansion budgeting ----
        //
        // A drawing can legitimately contain FAR more nested-instance geometry
        // than the `maxExpandedEntities` render budget — a real production
        // overall layout has 37 top-level station INSERTs, and expanding just
        // the FIRST one's deeply nested (14-level) xref tree exceeds 50M
        // primitives on its own. A plain depth-first walk therefore spends the
        // ENTIRE budget inside station #1 and truncates the other 36 stations
        // (plus paper space and markup) to nothing — the "blank canvas after
        // loading" symptom.
        //
        // The model-space walk is therefore run in up to TWO passes (see
        // where `walk(.space(.model), …)` is invoked below):
        //   Pass 1 — global budget only, NO per-insert cap. If the whole
        //     drawing fits (`truncated` stays false), that IS the drawing and
        //     we keep it. A normal file — even one with tens of thousands of
        //     top-level inserts, like a 731 MB production layout — always
        //     lands here, so its rendering is byte-for-byte unchanged.
        //   Pass 2 — only if pass 1 overran the budget: discard it and re-walk
        //     giving each top-level model INSERT an EQUAL share of the budget
        //     (the remaining budget divided among the remaining inserts), so
        //     every station is represented rather than just the first.
        //
        // `expansionCeiling` is the phase-scoped global cap (model, then a
        // fresh slice for orphan roots + paper). `currentInsertCap` is the
        // running cap for the top-level insert currently being expanded (pass
        // 2 only). `directReserve` keeps a little headroom below the model
        // ceiling so top-level DIRECT model entities (ordinary geometry AND
        // freshly drawn markup, which sort LAST in the store) still render
        // after the inserts.
        var expansionCeiling = maxExpandedEntities
        var applyInsertFairness = false
        var processedTopInserts = 0
        var topModelInsertsForFairness = 0
        let directReserve = 200_000
        let insertCeiling = max(maxExpandedEntities - directReserve, maxExpandedEntities / 2)
        var currentInsertCap = maxExpandedEntities

        func layerColor(_ id: Int32) -> ResolvedColor {
            let i = Int(id)
            return i < parsed.layers.count ? parsed.layers[i].color : .foreground
        }
        func layerLinetype(_ id: Int32) -> Int16 {
            let i = Int(id)
            return i < parsed.layers.count ? Int16(parsed.layers[i].linetypeId) : 0
        }

        // Phase 6.2: delegates to `PropertyResolver` (see `resolveAppearance`
        // above for the full rationale) — identical behavior to the
        // pre-refactor inline logic, verified via the real-731MB-file
        // `--compare` 0-pixel-diff check required before this commit.
        func resolve(_ e: StoreEntityView, _ ctx: Ctx)
            -> (layer: Int32, color: ResolvedColor, ltype: Int16) {
            let blockCtx = PropertyResolver.BlockContext(
                subLayer: ctx.subLayer,
                byBlockAci: nativeAci(for: ctx.byBlockColor),
                byBlockTrueColor: nativeTrueColor(for: ctx.byBlockColor),
                byBlockLinetypeId: ctx.byBlockLinetype)
            let resolved = PropertyResolver.resolve(layerId: e.layerId, aci: e.aci, trueColor: e.trueColor,
                                                    linetypeId: e.linetypeId, in: blockCtx)
            var color: ResolvedColor
            if resolved.trueColor != 0xFF00_0000 {
                color = .rgb(resolved.trueColor)
            } else if resolved.aci == 256 {
                color = layerColor(resolved.layerId)
            } else if resolved.aci == 7 {
                color = .foreground
            } else {
                color = .rgb(ACIPalette.rgb(forACI: Int(resolved.aci)))
            }
            var lt = resolved.linetypeId
            if lt == -1 { lt = layerLinetype(resolved.layerId) }
            if lt < 0 || Int(lt) >= parsed.linetypes.count { lt = 0 }
            return (resolved.layerId, color, lt)
        }

        func acc(for key: GroupKey) -> Accumulator {
            if let a = accs[key] { return a }
            let a = Accumulator()
            accs[key] = a
            return a
        }

        /// Builds a `StoreEntityView` for slot `id`, or nil if deleted /
        /// unsupported-for-rendering (`.unknown`, discarded types never
        /// stored). Mirrors `commonProps`' fields exactly.
        func view(_ id: EntityID) -> StoreEntityView? {
            guard let h = store.header(id), !h.flags.contains(.deleted) else { return nil }
            let kind: EntityKind
            switch h.type {
            case .line: kind = .line
            case .point: kind = .point
            case .circle: kind = .circle
            case .arc: kind = .arc
            case .ellipse: kind = .ellipse
            case .lwpolyline, .polyline2d, .polyline3d:
                // Distinguish SOLID/TRACE/3DFACE stored as PolylinePayload
                // via type on the header (they use .solid/.face3d directly
                // below instead of .lwpolyline, so this branch is genuinely
                // just polylines).
                kind = .polyline
            case .spline: kind = .spline
            case .solid: kind = .solid
            case .face3d: kind = .face3d
            case .hatch: kind = .hatch
            case .text: kind = .text
            case .mtext: kind = .mtext
            case .attrib: kind = .attrib
            case .leader: kind = .leader
            case .insert, .dimension, .image, .viewport: kind = .other
            default: return nil
            }
            return StoreEntityView(id: id, kind: kind, layerId: h.layerId, aci: h.aci,
                                   trueColor: h.trueColor, linetypeId: h.linetypeId,
                                   mirrorOCS: h.flags.contains(.mirrorOCS))
        }

        /// Iterates entity ids for a "space": `.model`/`.paper` per-entity, a
        /// block's contiguous range, or the synthesized set of *MODEL_SPACE/
        /// *PAPER_SPACE block ranges unioned with true model/paper entities.
        enum EntitySource {
            case space(SpaceID)
            case blockRange(start: Int32, count: Int32)
        }

        func forEach(_ source: EntitySource, _ body: (EntityID) -> Void) {
            switch source {
            case .blockRange(let start, let count):
                guard count > 0 else { return }
                for i in Int(start)..<Int(start + count) { body(EntityID(raw: Int32(i))) }
            case .space(let space):
                for i in store.headers.indices {
                    let h = store.headers[i]
                    guard !h.flags.contains(.deleted) else { continue }
                    let matches: Bool
                    switch space {
                    case .model: matches = h.owner.isModel
                    case .paper:
                        matches = h.owner.isPaper && (paperLayout?.contains(EntityID(raw: Int32(i)), in: store) ?? true)
                    }
                    guard matches else { continue }
                    body(EntityID(raw: Int32(i)))
                }
                // *MODEL_SPACE/*PAPER_SPACE block content is emitted as if it
                // were directly in that space (GeometryBuilder folds these
                // blocks' entities into `model`/`paper` up front; here we
                // just walk their ranges in the same pass instead).
                let names = space == .model ? modelSpaceBlockNames : paperSpaceBlockNames
                for name in names.sorted() {
                    if space == .paper, let paperLayout, !paperLayout.blockNames.contains(name) { continue }
                    guard let b = parsed.blocks[name] else { continue }
                    for i in Int(b.entityStart)..<Int(b.entityStart + b.entityCount) {
                        body(EntityID(raw: Int32(i)))
                    }
                }
            }
        }

        // DIMENSION entities are retained as an insert-like reference to
        // their anonymous dimension block (matching DXFParser: `case
        // "DIMENSION": ... return ([.insert(ins)], .other)` — position (0,0),
        // scale (1,1), rotation 0, no array). Reading both `.insert` and
        // `.dimension` through this common shape means `walk` below expands
        // either exactly the same way.
        struct InsertLike {
            var blockNameId: Int32
            var position: Vec3
            var scale: Vec3
            var rotationDeg: Double
            var cols: Int32
            var rows: Int32
            var colSpacing: Double
            var rowSpacing: Double
        }
        func insertLike(_ h: EntityHeader) -> InsertLike? {
            switch h.type {
            case .insert:
                let ip = store.inserts[Int(h.payload)]
                return InsertLike(blockNameId: ip.blockNameId, position: ip.position, scale: ip.scale,
                                  rotationDeg: ip.rotationDeg, cols: ip.cols, rows: ip.rows,
                                  colSpacing: ip.colSpacing, rowSpacing: ip.rowSpacing)
            case .dimension:
                let dp = store.dimensions[Int(h.payload)]
                return InsertLike(blockNameId: dp.blockNameId, position: Vec3(x: 0, y: 0), scale: Vec3(x: 1, y: 1, z: 1),
                                  rotationDeg: 0, cols: 1, rows: 1, colSpacing: 0, rowSpacing: 0)
            default:
                return nil
            }
        }

        func walk(_ source: EntitySource, _ ctx: Ctx) {
            guard ctx.depth <= 32 else { return }
            forEach(source) { id in
                if expandedCount >= expansionCeiling { truncated = true; return }
                // Fair-share: once INSIDE a top-level insert's subtree
                // (depth > 0), stop when that insert has used its slice, then
                // let the outer loop move on to the next top-level insert.
                if applyInsertFairness, ctx.depth > 0, expandedCount >= currentInsertCap {
                    truncated = true; return
                }
                guard let h = store.header(id), !h.flags.contains(.deleted) else { return }

                if let ip = insertLike(h) {
                    let name = store.strings.string(for: ip.blockNameId)
                    guard let block = parsed.blocks[name], block.entityCount > 0 else { return }
                    // Pass 2 only: starting a new top-level model INSERT — give
                    // it an equal share of the budget still unspent, i.e. the
                    // remaining budget divided among the inserts not yet
                    // started (this one included). Inserts that come in under
                    // their share hand the surplus to those still to come.
                    if applyInsertFairness, ctx.depth == 0 {
                        let remaining = max(1, topModelInsertsForFairness - processedTopInserts)
                        let budgetLeft = max(0, insertCeiling - expandedCount)
                        currentInsertCap = expandedCount + budgetLeft / remaining
                        processedTopInserts += 1
                    }
                    // Cycle guard: a block already OPEN on the current
                    // expansion path is a cyclic reference — an xref that
                    // (transitively) re-references an ancestor (A→B→A), or a
                    // block that INSERTs itself. That is legal to STORE but
                    // impossible to fully expand; recursing would only bottom
                    // out at the depth-32 cap, and along the way multiply the
                    // same geometry into tens of millions of exactly-
                    // overlapping phantom primitives. A real production
                    // overall layout hit exactly this: ONE top-level station's
                    // cyclic xref subtree consumed a whole 50M-primitive budget
                    // by itself, truncating every OTHER station (and paper
                    // space, and markup) to nothing — the "blank canvas after
                    // loading" symptom. Skipping re-entry (as AutoCAD does for
                    // circular xrefs) both bounds the work and renders the
                    // drawing correctly, since the ancestor's geometry is
                    // already being drawn one level up.
                    if block.blockIndex >= 0, activeBlockIndices.contains(block.blockIndex) { return }
                    guard let ev = view(id) else { return }
                    let (layer, color, ltype) = resolve(ev, ctx)
                    let childXref = xrefIdByBlock[name] ?? ctx.xrefId

                    // An INSERT gets its OWN `InsertInstance` (so a click on
                    // any of its primitives resolves to IT, per
                    // `HitTesting.wrap`'s `insertId >= 0 ? .insert(insertId)`
                    // rule) when it is either:
                    //
                    //  * top-level (`ctx.insertId == -1`) — the long-standing
                    //    "click selects the whole insert" behavior, or
                    //  * NESTED BUT ATTRIBUTE-BEARING — it owns ATTRIB
                    //    children of its own.
                    //
                    // The second case fixes a real reported bug: on converted
                    // plant layouts, hundreds of individually-attributed
                    // workstation INSERTs (each with its own STATIONNO/
                    // PART_DESC/etc. values) sit nested inside ONE big
                    // container block. Because only the OUTERMOST insert used
                    // to get an `InsertInstance`, every nested workstation
                    // inherited the container's `insertId`, so clicking ANY of
                    // them resolved to the SAME container `EntityID` — and
                    // every attribute-reading call site (`BlockEditor
                    // .attributes(of:)`, the properties panel, the attribute
                    // editor, Data Extraction) is keyed on that resolved id,
                    // so they ALL displayed one identical set of values ("the
                    // same value keeps reappearing on other objects"). On the
                    // real reference file, 642 distinct attributed
                    // workstations collapsed onto a single container this way.
                    //
                    // Nested inserts WITHOUT attributes deliberately keep
                    // inheriting the ancestor's `insertId` — that preserves
                    // "clicking a plain nested block selects the whole
                    // top-level block" for ordinary (non-attributed) nesting,
                    // so this only adds selection granularity exactly where
                    // there is per-instance DATA that would otherwise be
                    // unreachable/wrong.
                    var childInsertId = ctx.insertId
                    // O(1) membership test against the set precomputed ONCE
                    // above — NEVER `store.children(of: id)` here, which is
                    // itself a full linear scan of every header and would
                    // make this walk O(inserts x entities) (~50 BILLION
                    // header reads on the reference file: 14.8k inserts x
                    // 3.4M entities), i.e. an apparent hang on load. See
                    // `attributeOwningInserts`' own doc comment.
                    let ownsAttributes = attributeOwningInserts.contains(id.raw)
                    if ctx.insertId == -1 || ownsAttributes {
                        childInsertId = Int32(inserts.count)
                        var pos = CGPoint(x: ip.position.x, y: ip.position.y)
                        if h.flags.contains(.mirrorOCS) { pos.x = -pos.x }
                        inserts.append(InsertInstance(
                            name: name,
                            position: pos.applying(ctx.t),
                            scaleX: CGFloat(ip.scale.x), scaleY: CGFloat(ip.scale.y),
                            rotationDegrees: ip.rotationDeg,
                            layerId: layer, xrefId: childXref,
                            entityId: id.raw))
                    }

                    // This INSERT's own ATTRIB children (its per-instance
                    // attribute VALUES — e.g. a workstation's actual "NAME"
                    // text, distinct from the block DEFINITION's static
                    // ATTDEF template) are owned via `OwnerRef.parentEntity`
                    // (see `EntityStoreParser`'s `lastInsertId`/TEXT-ATTRIB
                    // case), NOT via `.model`/`.paper`/a block range — so
                    // NEITHER `.space(...)` nor `.blockRange(...)` in
                    // `EntitySource` above ever visits them; without this,
                    // they're parsed and data-extractable but structurally
                    // invisible to this whole walk, i.e. correctly LINKED
                    // but never DRAWN. A real ATTRIB's group 10/20/30 are
                    // already absolute world coordinates (not block-local,
                    // unlike the block definition's own geometry) — matching
                    // how AutoCAD itself stores them — so these are emitted
                    // using `ctx` AS-IS (the INSERT's own placement
                    // transform), never the block-internal `child` transform
                    // built below for the block's definition geometry.
                    //
                    // O(1) lookup against the map precomputed ONCE above —
                    // NEVER `store.children(of: id)` here (see
                    // `attribChildrenByParent`'s own doc comment: this is
                    // called once per INSERT in the walk, so a linear scan
                    // here would be the render-side twin of the xref-merge
                    // "stuck at 51%" hang).
                    for attribId in attribChildrenByParent[id.raw] ?? [] {
                        if expandedCount >= expansionCeiling { truncated = true; return }
                        guard let ah = store.header(attribId), !ah.flags.contains(.deleted),
                              ah.type == .attrib, !ah.flags.contains(.invisible) else { continue }
                        guard let aev = view(attribId) else { continue }
                        var actx = ctx
                        actx.insertId = childInsertId
                        emitGeometry(aev, ah, actx)
                    }

                    if block.blockIndex >= 0 { activeBlockIndices.insert(block.blockIndex) }
                    defer { if block.blockIndex >= 0 { activeBlockIndices.remove(block.blockIndex) } }
                    let rows = max(1, Int(ip.rows)), cols = max(1, Int(ip.cols))
                    for row in 0..<rows {
                        for col in 0..<cols {
                            if expandedCount >= expansionCeiling { truncated = true; return }
                            if applyInsertFairness, expandedCount >= currentInsertCap {
                                truncated = true; return
                            }
                            var bt = CGAffineTransform.identity
                            bt = bt.translatedBy(x: ip.position.x, y: ip.position.y)
                            bt = bt.rotated(by: ip.rotationDeg * .pi / 180)
                            bt = bt.translatedBy(x: Double(col) * ip.colSpacing,
                                                 y: Double(row) * ip.rowSpacing)
                            bt = bt.scaledBy(x: ip.scale.x, y: ip.scale.y)
                            bt = bt.translatedBy(x: -Double(block.base.x), y: -Double(block.base.y))
                            if h.flags.contains(.mirrorOCS) {
                                bt = bt.concatenating(CGAffineTransform(scaleX: -1, y: 1))
                            }
                            let combined = bt.concatenating(ctx.t)
                            var child = ctx
                            child.t = combined
                            let det = combined.a * combined.d - combined.b * combined.c
                            child.scale = sqrt(abs(det))
                            child.scaleX = hypot(combined.a, combined.b)
                            child.scaleY = hypot(combined.c, combined.d)
                            child.mirrored = det < 0
                            child.rotationDegrees = atan2(combined.b, combined.a) * 180 / .pi
                            child.subLayer = layer
                            child.byBlockColor = color
                            child.byBlockLinetype = ltype
                            child.xrefId = childXref
                            child.insertId = childInsertId
                            child.depth = ctx.depth + 1
                            walk(.blockRange(start: block.entityStart, count: block.entityCount), child)
                        }
                    }
                    return
                }

                guard let ev = view(id) else { return }
                var ev2 = ev
                var ctx2 = ctx
                if ev.mirrorOCS {
                    ctx2.t = CGAffineTransform(scaleX: -1, y: 1).concatenating(ctx.t)
                    ctx2.mirrored.toggle()
                    ev2.mirrorOCS = false
                }
                emitGeometry(ev2, h, ctx2)
            }
        }

        // Synthetic orphan-root inserts walk exactly like a real INSERT at
        // depth 0, EXCEPT: they never register an InsertInstance (their
        // contents stay individually selectable — GeometryBuilder's
        // `isSyntheticRoot` -> `childInsertId` stays -1 rule), and their
        // emitted content's `entityId` is the source entity's OWN id inside
        // the block, not a synthetic insert's id (there is no insert entity
        // to attribute it to).
        func walkSyntheticRoot(_ name: String, base: CGPoint) {
            guard let block = parsed.blocks[name], block.entityCount > 0 else { return }
            var ctx = Ctx()
            ctx.t = CGAffineTransform(translationX: -Double(base.x), y: -Double(base.y))
            ctx.subLayer = nil
            // A synthetic root is still content "reached through" this block,
            // so an xref-flagged block still gets its xref id (matches
            // GeometryBuilder: synthetic roots are ordinary INSERT RawEntitys
            // fed through the same `walk`, which always looks up
            // `xrefIdByBlock[ins.name] ?? ctx.xrefId`).
            ctx.xrefId = xrefIdByBlock[name] ?? -1
            walk(.blockRange(start: block.entityStart, count: block.entityCount), ctx)
        }

        func emitGeometry(_ e: StoreEntityView, _ h: EntityHeader, _ ctx: Ctx) {
            let (layer, color, ltype) = resolve(e, ctx)
            if h.type == .image || h.type == .viewport {
                guard !h.flags.contains(.invisible) else { return }
                if h.type == .image, let image = sheetSupport.raster(store.images[Int(h.payload)], transform: ctx.t,
                                                                    layer: Int(layer), xref: Int(ctx.xrefId)) {
                    if renderingPaper { paperImages.append(image) } else { modelImages.append(image) }
                    expandedCount += 1
                } else if h.type == .viewport && renderingPaper,
                          let viewport = sheetSupport.viewport(store.viewports[Int(h.payload)], transform: ctx.t, layer: Int(layer)) {
                    viewports.append(viewport)
                }
                return
            }
            let key = GroupKey(layerId: layer, color: color, linetypeId: ltype, xrefId: ctx.xrefId)
            let a = acc(for: key)
            expandedCount += 1
            a.count += 1
            if Int(layer) < layerCounts.count { layerCounts[Int(layer)] += 1 }
            emitPrimitive(e, h, ctx, store: store, into: a)
        }

        // Pass 1: expand model space against the global budget only (no
        // per-insert cap). A normal drawing fits here and is kept as-is.
        expansionCeiling = maxExpandedEntities
        applyInsertFairness = false
        walk(.space(.model), Ctx())

        // Pass 2: only if pass 1 overran the budget. Count the top-level
        // model inserts, throw away pass 1's partial expansion, and re-walk
        // giving each top-level insert an equal share (see the fairness block
        // above) so every station is represented, not just the first few.
        // NOTE: `truncated` IS mutated by `walk` above (line ~1121 et al.). The
        // Swift compiler's flow analysis incorrectly concludes otherwise for
        // this closure-heavy mutation pattern; the `_ = walkDone` dance is a
        // minimal silence for that false-positive warning.
        if expansionNeedsRebalance(truncated) {
            var topModelInserts = 0
            forEach(.space(.model)) { id in
                if let h = store.header(id), !h.flags.contains(.deleted), insertLike(h) != nil { topModelInserts += 1 }
            }
            accs = [:]
            modelImages.removeAll(keepingCapacity: true)
            inserts.removeAll(keepingCapacity: true)
            activeBlockIndices.removeAll(keepingCapacity: true)
            for i in layerCounts.indices { layerCounts[i] = 0 }
            expandedCount = 0
            truncated = false
            processedTopInserts = 0
            topModelInsertsForFairness = topModelInserts
            expansionCeiling = maxExpandedEntities
            applyInsertFairness = true
            walk(.space(.model), Ctx())
        }
        // Orphan roots and paper space are NOT subject to the per-insert
        // fair-share (they're a different, usually small population). Their
        // ceiling is the NORMAL global budget (`maxExpandedEntities`) — so a
        // drawing whose content lives mostly in orphan blocks (a real "MR
        // LAYOUT" file expands only ~8K entities via model INSERTs but ~3.4M
        // via synthetic roots) still renders in full — RAISED to give a fresh
        // slice above whatever the model walk already spent ONLY when the
        // model walk itself ran hot (an over-budget drawing whose pass-2
        // fair-share filled the budget), so paper/orphans aren't starved
        // there either. `max(...)` is essential: basing this purely on
        // `expandedCount + slice` silently truncated orphan-heavy files whose
        // model walk spent almost nothing.
        applyInsertFairness = false
        expansionCeiling = max(maxExpandedEntities, expandedCount + min(maxExpandedEntities, 3_000_000))
        for root in syntheticRoots { walkSyntheticRoot(root.name, base: root.base) }
        var modelAccs = accs
        accs = [:]
        let modelInsertCount = inserts.count
        progress(0.6)
        renderingPaper = true
        walk(.space(.paper), Ctx())
        var paperAccs = accs
        accs = [:]
        progress(0.85)

        func finalize(_ dict: inout [GroupKey: Accumulator]) -> ([RenderGroup], CGRect) {
            var groups: [RenderGroup] = []
            var total = CGRect.null
            for key in Array(dict.keys) {
                guard let a = dict.removeValue(forKey: key) else { continue }
                let b = a.bounds
                if !b.isNull { total = total.union(b) }
                groups.append(RenderGroup(layerId: Int(key.layerId),
                                          color: key.color,
                                          linetypeId: Int(key.linetypeId),
                                          xrefId: Int(key.xrefId),
                                          strokes: a.strokes,
                                          fillPath: a.fill,
                                          patternFillPath: a.patternFill,
                                          points: a.points,
                                          texts: a.texts,
                                          bounds: b.isNull ? .zero : b,
                                          entityCount: a.count))
            }
            groups.sort {
                if $0.layerId != $1.layerId { return $0.layerId < $1.layerId }
                let c0 = String(describing: $0.color), c1 = String(describing: $1.color)
                if c0 != c1 { return c0 < c1 }
                if $0.linetypeId != $1.linetypeId { return $0.linetypeId < $1.linetypeId }
                return $0.xrefId < $1.xrefId
            }
            return (groups, total.isNull ? .zero : total)
        }

        let (modelGroups, rawModelBounds) = finalize(&modelAccs)
        let (paperGroups, rawPaperBounds) = finalize(&paperAccs)
        let modelBounds = modelImages.reduce(modelGroups.isEmpty ? CGRect.null : rawModelBounds) { $0.union($1.bounds) }
        let paperBounds = viewports.reduce(paperImages.reduce(paperGroups.isEmpty ? CGRect.null : rawPaperBounds) { $0.union($1.bounds) }) { $0.union($1.bounds) }

        func robustFit(_ groups: [RenderGroup], full: CGRect) -> CGRect {
            var count = 0
            for g in groups {
                count += g.strokes.runs.count + g.strokes.arcs.count + g.texts.count
            }
            guard count >= 64 else { return full }
            let step = max(1, count / 250_000)
            var xs: [CGFloat] = [], ys: [CGFloat] = []
            xs.reserveCapacity(count / step + 8)
            ys.reserveCapacity(count / step + 8)
            var i = 0
            for g in groups {
                for run in g.strokes.runs {
                    if i % step == 0 { xs.append(run.bounds.midX); ys.append(run.bounds.midY) }
                    i += 1
                }
                for arc in g.strokes.arcs {
                    if i % step == 0 { xs.append(arc.center.x); ys.append(arc.center.y) }
                    i += 1
                }
                for t in g.texts {
                    if i % step == 0 { xs.append(t.position.x); ys.append(t.position.y) }
                    i += 1
                }
            }
            guard xs.count >= 64 else { return full }
            xs.sort(); ys.sort()
            let lo = Int(Double(xs.count) * 0.02)
            let hi = min(xs.count - 1, Int(Double(xs.count) * 0.98))
            var r = CGRect(x: xs[lo], y: ys[lo],
                           width: max(xs[hi] - xs[lo], 1e-9),
                           height: max(ys[hi] - ys[lo], 1e-9))
            r = r.insetBy(dx: -r.width * 0.06, dy: -r.height * 0.06)
            if r.width * r.height > full.width * full.height * 0.5 { return full }
            return r.intersection(full).isNull ? full : r
        }

        let modelFit = modelImages.isEmpty ? robustFit(modelGroups, full: modelBounds.isNull ? .zero : modelBounds) : modelBounds
        let paperFit = paperImages.isEmpty && viewports.isEmpty ? robustFit(paperGroups, full: paperBounds.isNull ? .zero : paperBounds) : paperBounds

        var layers = parsed.layers
        for i in layers.indices { layers[i].entityCount = layerCounts[i] }

        let linetypes = parsed.linetypes.map {
            DXFLinetype(name: $0.name, dashes: $0.dashes.map { d in d * parsed.ltScale })
        }

        var stats = ParseStats()
        stats.totalEntities = expandedCount
        stats.parseSeconds = parseSeconds
        stats.buildSeconds = Date().timeIntervalSince(t0)
        stats.truncated = truncated
        stats.skippedTypes = parsed.skippedTypes

        let unitsLabel: String = [1: "in", 2: "ft", 3: "mi", 4: "mm", 5: "cm",
                                  6: "m", 7: "km", 8: "µin", 9: "mil", 10: "yd"][parsed.insUnits] ?? ""

        let doc = DXFDocument(layers: layers, linetypes: linetypes, xrefs: xrefs,
                           modelGroups: modelGroups, paperGroups: paperGroups,
                           modelBounds: modelBounds.isNull ? .zero : modelBounds, paperBounds: paperBounds.isNull ? .zero : paperBounds,
                           modelFitBounds: modelFit, paperFitBounds: paperFit,
                           inserts: inserts, modelInsertCount: modelInsertCount,
                           unitsLabel: unitsLabel, stats: stats)
        doc.insUnits = parsed.insUnits
        doc.modelImages = modelImages; doc.paperImages = paperImages; doc.paperViewports = viewports
        doc.renderingWarnings = sheetSupport.warnings.sorted()
        doc.renderingWarnings += parsed.skippedTypes.sorted { $0.key < $1.key }.map { "\($0.value) unsupported \($0.key) entities omitted from display and export." }

        // ---- Capture stampable block symbols (bounded) ----
        let candidates = insertCounts
            .filter { $0.value > 0 }
            .sorted { $0.value > $1.value }
            .map(\.key)
        var stamps: [String: [DrawnEntity]] = [:]
        var names: [String] = []
        var totalPrims = 0
        for name in candidates {
            if names.count >= 250 || totalPrims >= 40_000 { break }
            guard let block = parsed.blocks[name], !block.isXref, !block.isXrefDependent
            else { continue }
            let upper = name.uppercased()
            if upper.hasPrefix("*") || upper.hasPrefix("$") { continue }
            var geo: [DrawnEntity] = []
            captureStamp(store: store, blocks: parsed.blocks,
                        start: block.entityStart, count: block.entityCount,
                        t: CGAffineTransform(translationX: -Double(block.base.x), y: -Double(block.base.y)),
                        depth: 0, into: &geo)
            guard !geo.isEmpty else { continue }
            stamps[name] = geo
            names.append(name)
            totalPrims += geo.count
        }
        doc.blockStamps = stamps
        doc.stampableBlockNames = names
        return doc
    }

    /// Store-backed equivalent of `GeometryBuilder.captureStamp`.
    private static func captureStamp(store: EntityStore, blocks: [String: EditableBlockDef],
                                     start: Int32, count: Int32, t: CGAffineTransform,
                                     depth: Int, into out: inout [DrawnEntity]) {
        guard depth <= 3, out.count < 200, count > 0 else { return }
        let det = t.a * t.d - t.b * t.c
        let scale = sqrt(abs(det))
        let mirrored = det < 0
        let rotDeg = atan2(t.b, t.a) * 180 / .pi
        func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: y).applying(t) }

        for i in Int(start)..<Int(start + count) {
            if out.count >= 200 { return }
            let id = EntityID(raw: Int32(i))
            guard let h = store.header(id), !h.flags.contains(.deleted), h.payload >= 0 else { continue }
            let pIdx = Int(h.payload)
            switch h.type {
            case .line:
                let l = store.lines[pIdx]
                out.append(DrawnEntity(shape: .line(a: p(l.a.x, l.a.y), b: p(l.b.x, l.b.y))))
            case .circle:
                let c = store.circles[pIdx]
                out.append(DrawnEntity(shape: .circle(center: p(c.center.x, c.center.y), radius: c.radius * scale)))
            case .arc:
                let arc = store.arcs[pIdx]
                var s = arc.startAngleDeg, e2 = arc.endAngleDeg
                if mirrored { s = -arc.endAngleDeg; e2 = -arc.startAngleDeg }
                out.append(DrawnEntity(shape: .arc(center: p(arc.center.x, arc.center.y), radius: arc.radius * scale,
                                                   startDeg: s + rotDeg, endDeg: e2 + rotDeg)))
            case .lwpolyline, .polyline2d, .polyline3d, .leader:
                // GeometryBuilder.captureStamp keys on RawGeom (LEADER
                // produces `.polyline`), so it captures LEADER shapes too —
                // matched here by including `.leader` in this case.
                let poly = store.polylines[pIdx]
                let vCount = Int(poly.vertsCount)
                guard vCount > 1 else { continue }
                let vStart = Int(poly.vertsStart)
                let pts = (0..<vCount).map { p(store.vertexArena[vStart + $0].x, store.vertexArena[vStart + $0].y) }
                out.append(DrawnEntity(shape: .polyline(pts: pts, closed: poly.closed)))
            case .solid:
                let poly = store.polylines[pIdx]
                let vCount = Int(poly.vertsCount)
                guard vCount >= 3 else { continue }
                let vStart = Int(poly.vertsStart)
                let pts = (0..<vCount).map { p(store.vertexArena[vStart + $0].x, store.vertexArena[vStart + $0].y) }
                out.append(DrawnEntity(shape: .polyline(pts: pts, closed: true)))
            case .insert:
                let ip = store.inserts[pIdx]
                let name = store.strings.string(for: ip.blockNameId)
                guard let sub = blocks[name], !sub.isXref else { continue }
                var bt = CGAffineTransform.identity
                bt = bt.translatedBy(x: ip.position.x, y: ip.position.y)
                bt = bt.rotated(by: ip.rotationDeg * .pi / 180)
                bt = bt.scaledBy(x: ip.scale.x, y: ip.scale.y)
                bt = bt.translatedBy(x: -Double(sub.base.x), y: -Double(sub.base.y))
                captureStamp(store: store, blocks: blocks, start: sub.entityStart, count: sub.entityCount,
                            t: bt.concatenating(t), depth: depth + 1, into: &out)
            default:
                break   // skip text/hatch/point in stamps, same as GeometryBuilder
            }
        }
    }
}
