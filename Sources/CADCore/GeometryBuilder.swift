import Foundation
import CoreGraphics

/// Expands raw entities (block inserts included) into flat, render-ready groups.
///
/// AutoCAD semantics implemented here:
///  - Entities on layer "0" inside a block inherit the INSERT's layer.
///  - Color BYLAYER resolves against the entity's effective layer; BYBLOCK
///    resolves against the parent INSERT's effective color (recursively).
///  - Linetype BYLAYER/BYBLOCK resolve the same way.
///  - Content reached through an INSERT of an xref block is tagged with that
///    xref's id so the whole reference can be shown/hidden as a unit.
public enum GeometryBuilder {

    private struct Ctx {
        var t = CGAffineTransform.identity
        var scale: CGFloat = 1            // uniform scale magnitude of t
        var scaleX: CGFloat = 1           // per-axis magnitudes (non-uniform detection)
        var scaleY: CGFloat = 1
        var rotationDegrees: Double = 0   // rotation component of t
        var mirrored = false              // determinant < 0

        var isNonUniform: Bool {
            abs(scaleX - scaleY) > 0.001 * max(scaleX, scaleY)
        }
        var subLayer: Int32? = nil        // layer that replaces layer "0"
        var byBlockColor = ResolvedColor.foreground
        var byBlockLinetype: Int16 = 0
        var xrefId: Int16 = -1
        var insertId: Int32 = -1          // owning top-level block reference
        var depth = 0
        /// The STABLE DXF handle to stamp on geometry emitted under this
        /// context. For top-level (model-space) geometry it's the entity's own
        /// handle (set per-entity in `emitGeometry`). For block-expanded
        /// content it's the OWNING top-level INSERT's handle (set when entering
        /// the outermost real insert), so every primitive of one placed block
        /// instance shares that instance's stable identity — matching
        /// `insertId`'s "clicking any part selects the whole block" semantics.
        var handle: UInt64 = 0
    }

    private struct GroupKey: Hashable {
        var layerId: Int32
        var color: ResolvedColor
        var linetypeId: Int16
        var xrefId: Int16
    }

    private final class Accumulator {
        let strokes = StrokeStore()

        // Current run assembly (world space).
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

        func endRun(closed: Bool, kind: EntityKind, insertId: Int32, handle: UInt64 = 0) {
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
                handle: handle))
            runStart = -1
        }

        func addArc(center: CGPoint, radius: CGFloat,
                    startDeg: Double, endDeg: Double, full: Bool, insertId: Int32, handle: UInt64 = 0) {
            strokes.arcs.append(StrokeStore.Arc(
                center: center, radius: radius,
                startAngleDeg: startDeg, endAngleDeg: endDeg, isFullCircle: full,
                insertId: insertId, handle: handle))
            addBoundsPoint(CGPoint(x: center.x - radius, y: center.y - radius))
            addBoundsPoint(CGPoint(x: center.x + radius, y: center.y + radius))
        }

        func addFillRun(_ pts: [CGPoint], kind: EntityKind, insertId: Int32, handle: UInt64 = 0) {
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
                handle: handle))
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

    public static func build(from raw: inout RawParseOutput,
                      parseSeconds: Double,
                      progress: (Double) -> Void) -> DXFDocument {
        let t0 = Date()

        // ---- Identify xrefs and route modern model/paper-space blocks ----
        var model = raw.model
        var paper = raw.paper
        var xrefs: [XrefInfo] = []
        var xrefIdByBlock: [String: Int16] = [:]

        var insertCounts: [String: Int] = [:]
        func countInserts(_ ents: [RawEntity]) {
            for e in ents {
                if case .insert(let ins) = e.geom { insertCounts[ins.name, default: 0] += 1 }
            }
        }
        countInserts(model); countInserts(paper)
        for (_, b) in raw.blocks { countInserts(b.entities) }

        for (name, b) in raw.blocks.sorted(by: { $0.key < $1.key }) {
            let upper = name.uppercased()
            if upper.hasPrefix("*MODEL_SPACE") || upper == "$MODEL_SPACE" {
                model.append(contentsOf: b.entities)
                b.entities = []
            } else if upper.hasPrefix("*PAPER_SPACE") {
                paper.append(contentsOf: b.entities)
                b.entities = []
            } else if b.isXref {
                let id = Int16(xrefs.count)
                xrefIdByBlock[name] = id
                xrefs.append(XrefInfo(id: Int(id), blockName: name,
                                      path: b.xrefPath.isEmpty ? name : b.xrefPath,
                                      sourcePath: "", loadedPath: "",
                                      isResolved: b.wasResolved || !b.entities.isEmpty,
                                      entityCount: b.entities.count,
                                      insertCount: insertCounts[name] ?? 0))
            }
        }

        // Blocks with real geometry that are never INSERTed anywhere still render:
        // layout DXFs exported from xref-composed DWGs frequently carry the whole
        // plant inside such definitions (the placement INSERTs are lost in export,
        // leaving model space nearly empty — this file: 8.7K reachable vs 2.3M
        // total). Xref-flagged blocks keep their xref id so the panel toggle works.
        // Extent pollution from faraway base points is handled by the robust
        // percentile fit, not by hiding content.
        for (name, b) in raw.blocks.sorted(by: { $0.key < $1.key }) {
            guard !b.entities.isEmpty, insertCounts[name] == nil,
                  !b.isXrefDependent else { continue }
            let upper = name.uppercased()
            guard !upper.hasPrefix("*"), !upper.hasPrefix("$") else { continue }
            var ins = InsertRaw()
            ins.name = name
            ins.x = b.base.x; ins.y = b.base.y   // cancel the base offset
            ins.isSyntheticRoot = true
            model.append(RawEntity(geom: .insert(ins)))
        }

        var inserts: [InsertInstance] = []

        // ---- Expansion ----
        var accs: [GroupKey: Accumulator] = [:]
        var expandedCount = 0
        var truncated = false
        var layerCounts = [Int](repeating: 0, count: raw.layers.count)

        func layerColor(_ id: Int32) -> ResolvedColor {
            let i = Int(id)
            return i < raw.layers.count ? raw.layers[i].color : .foreground
        }
        func layerLinetype(_ id: Int32) -> Int16 {
            let i = Int(id)
            return i < raw.layers.count ? Int16(raw.layers[i].linetypeId) : 0
        }

        func resolve(_ e: RawEntity, _ ctx: Ctx)
            -> (layer: Int32, color: ResolvedColor, ltype: Int16) {
            let layer: Int32 = (e.layerId == 0 && ctx.subLayer != nil) ? ctx.subLayer! : e.layerId
            var color: ResolvedColor
            if e.trueColor != RawEntity.noTrueColor {
                color = .rgb(e.trueColor)
            } else if e.aci == 0 {
                color = ctx.byBlockColor
            } else if e.aci == 256 {
                color = layerColor(layer)
            } else if e.aci == 7 {
                color = .foreground
            } else {
                color = .rgb(ACIPalette.rgb(forACI: Int(e.aci)))
            }
            var lt: Int16
            switch e.linetypeId {
            case -1: lt = layerLinetype(layer)
            case -2: lt = ctx.byBlockLinetype
            default: lt = e.linetypeId
            }
            if lt < 0 || Int(lt) >= raw.linetypes.count { lt = 0 }
            return (layer, color, lt)
        }

        func acc(for key: GroupKey) -> Accumulator {
            if let a = accs[key] { return a }
            let a = Accumulator()
            accs[key] = a
            return a
        }

        func walk(_ entities: [RawEntity], _ ctx: Ctx) {
            guard ctx.depth <= 32 else { return }
            // Tracks the `insertId` most recently registered by an INSERT
            // seen at THIS level of `entities`, for back-linking any
            // standalone `ATTRIB`s that immediately follow it in the SAME
            // list (`e.followsInsertAttributes`) — the `INSERT[66=1] …
            // ATTRIB* … SEQEND` pattern (see `InsertRaw.attributesFollow`'s
            // doc comment). Reset per `walk` call (i.e. per entities list —
            // an INSERT's attributes never reach across a nested block
            // boundary since block content is a DIFFERENT `entities` array).
            var lastInsertIdForAttribs: Int32 = -1
            for e in entities {
                if expandedCount >= maxExpandedEntities { truncated = true; return }

                if case .insert(let ins) = e.geom {
                    guard let block = raw.blocks[ins.name] else { continue }
                    let (layer, color, ltype) = resolve(e, ctx)
                    let childXref = xrefIdByBlock[ins.name] ?? ctx.xrefId

                    // AutoCAD selection semantics: clicking any part of an inserted
                    // block selects the whole block reference. Register the OUTERMOST
                    // real insert; nested content inherits its id. Synthetic orphan
                    // roots stay id -1 so their loose contents select individually.
                    var childInsertId = ctx.insertId
                    if ctx.insertId == -1 && !ins.isSyntheticRoot {
                        childInsertId = Int32(inserts.count)
                        var pos = CGPoint(x: ins.x, y: ins.y)
                        if e.mirrorOCS { pos.x = -pos.x }
                        inserts.append(InsertInstance(
                            name: ins.name,
                            position: pos.applying(ctx.t),
                            scaleX: ins.sx, scaleY: ins.sy,
                            rotationDegrees: ins.rotationDegrees,
                            layerId: layer, xrefId: childXref,
                            displayNameOverride: ins.displayNameOverride))
                    }
                    lastInsertIdForAttribs = childInsertId

                    for row in 0..<max(1, ins.rows) {
                        for col in 0..<max(1, ins.cols) {
                            if expandedCount >= maxExpandedEntities { truncated = true; return }
                            var bt = CGAffineTransform.identity
                            bt = bt.translatedBy(x: ins.x, y: ins.y)
                            bt = bt.rotated(by: ins.rotationDegrees * .pi / 180)
                            // MINSERT array offsets follow the insert's rotated frame
                            // and are not scaled by 41/42.
                            bt = bt.translatedBy(x: Double(col) * ins.colSpacing,
                                                 y: Double(row) * ins.rowSpacing)
                            bt = bt.scaledBy(x: ins.sx, y: ins.sy)
                            bt = bt.translatedBy(x: -block.base.x, y: -block.base.y)
                            if e.mirrorOCS {
                                // OCS -> WCS for extrusion (0,0,-1): the whole placed
                                // insert mirrors, insertion point included (AAA: OCS
                                // X axis maps to WCS (-1,0,0)).
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
                            // Stable identity for block-expanded content: the
                            // OWNING top-level INSERT's handle (inherited by
                            // nested blocks). Only set when entering the
                            // outermost real insert (ctx.handle still 0); nested
                            // inserts keep the ancestor's handle.
                            if ctx.handle == 0 { child.handle = e.handle }
                            walk(block.entities, child)
                        }
                    }
                    continue
                }

                var e2 = e
                var ctx2 = ctx
                if e.mirrorOCS {
                    ctx2.t = CGAffineTransform(scaleX: -1, y: 1).concatenating(ctx.t)
                    ctx2.mirrored.toggle()
                    e2.mirrorOCS = false
                }
                // Back-link a standalone ATTRIB to the INSERT it immediately
                // followed (see `lastInsertIdForAttribs` above) — this is
                // the ONLY place that insertId comes from for such an entity;
                // `ctx.insertId` here is whatever insert (if any) CONTAINS
                // this entities list, which for model/paper-space-level
                // ATTRIBs is -1 (they aren't inside a block at all — they're
                // siblings of the INSERT in ENTITIES). Only applies when no
                // insertId is already active (never overrides real nesting).
                if e.followsInsertAttributes, ctx2.insertId == -1, lastInsertIdForAttribs != -1 {
                    ctx2.insertId = lastInsertIdForAttribs
                }
                emitGeometry(e2, ctx2)
            }
        }

        func emitGeometry(_ e: RawEntity, _ ctx: Ctx) {
            let (layer, color, ltype) = resolve(e, ctx)
            let key = GroupKey(layerId: layer, color: color, linetypeId: ltype, xrefId: ctx.xrefId)
            let a = acc(for: key)
            let t = ctx.t
            // Effective stable handle: block-expanded content carries its
            // owning INSERT's handle (ctx.handle); top-level geometry uses its
            // own handle.
            let h: UInt64 = ctx.handle != 0 ? ctx.handle : e.handle
            expandedCount += 1
            a.count += 1
            if Int(layer) < layerCounts.count { layerCounts[Int(layer)] += 1 }

            @inline(__always) func tp(_ x: Double, _ y: Double) -> CGPoint {
                let p = CGPoint(x: x, y: y).applying(t)
                a.addBoundsPoint(p)
                return p
            }

            switch e.geom {
            case .line(let x1, let y1, let x2, let y2):
                a.beginRun()
                a.addRunPoint(tp(x1, y1))
                a.addRunPoint(tp(x2, y2))
                a.endRun(closed: false, kind: e.kind, insertId: ctx.insertId, handle: h)

            case .circle(let cx, let cy, let r):
                if ctx.isNonUniform {
                    // Non-uniform scale turns circles into ellipses — tessellate in
                    // local space; tp() handles the distortion exactly.
                    a.beginRun()
                    for k in 0...48 {
                        let ang = Double(k) / 48 * 2 * .pi
                        a.addRunPoint(tp(cx + r * cos(ang), cy + r * sin(ang)))
                    }
                    a.endRun(closed: true, kind: e.kind, insertId: ctx.insertId, handle: h)
                    break
                }
                let c = tp(cx, cy)
                a.addArc(center: c, radius: CGFloat(r) * ctx.scale,
                         startDeg: 0, endDeg: 360, full: true, insertId: ctx.insertId, handle: h)

            case .arc(let cx, let cy, let r, let a1, let a2):
                if ctx.isNonUniform {
                    var sweep = a2 - a1
                    while sweep <= 0 { sweep += 360 }
                    let steps = max(6, min(64, safeInt(sweep / 6)))
                    a.beginRun()
                    for k in 0...steps {
                        let ang = (a1 + sweep * Double(k) / Double(steps)) * .pi / 180
                        a.addRunPoint(tp(cx + r * cos(ang), cy + r * sin(ang)))
                    }
                    a.endRun(closed: false, kind: e.kind, insertId: ctx.insertId, handle: h)
                    break
                }
                let c = tp(cx, cy)
                var s = a1, en = a2
                if ctx.mirrored {
                    // Reflection flips sweep direction. rotationDegrees (atan2 of the
                    // matrix) already absorbs the mirror's 180°, so only negate here:
                    // for L = Rot(φ)·MirX, angle(L·unit(θ)) = (φ+180) - θ = rotAdd - θ.
                    s = -a2; en = -a1
                }
                s += ctx.rotationDegrees; en += ctx.rotationDegrees
                a.addArc(center: c, radius: CGFloat(r) * ctx.scale,
                         startDeg: s, endDeg: en, full: false, insertId: ctx.insertId, handle: h)

            case .polyline(let verts, let closed):
                guard verts.count > 1 else { break }
                a.beginRun()
                for (k, v) in verts.enumerated() {
                    a.addRunPoint(tp(v.x, v.y))
                    if v.bulge != 0 {
                        let isLast = k == verts.count - 1
                        if !isLast || closed {
                            let nv = verts[(k + 1) % verts.count]
                            // Bulge stays unmodified: the intermediate points are
                            // computed in local space and tp()/t handles mirroring.
                            var mids: [CGPoint] = []
                            appendBulgeArc(from: CGPoint(x: v.x, y: v.y),
                                           to: CGPoint(x: nv.x, y: nv.y),
                                           bulge: v.bulge,
                                           into: &mids)
                            for m in mids {
                                a.addRunPoint(m.applying(t))
                            }
                        }
                    }
                }
                // A closed polyline with a bulge on its final segment already ends
                // on the arc back toward the start; closing the run is still right.
                a.endRun(closed: closed, kind: e.kind, insertId: ctx.insertId, handle: h)

            case .solidFill(let pts):
                guard pts.count >= 3 else { break }
                let world = pts.map { tp($0.x, $0.y) }
                a.fill.move(to: world[0])
                for p in world.dropFirst() { a.fill.addLine(to: p) }
                a.fill.closeSubpath()
                a.addFillRun(world, kind: e.kind, insertId: ctx.insertId, handle: h)

            case .hatch(let loops, let solid):
                let target = solid ? a.fill : a.patternFill
                for loop in loops {
                    guard loop.count >= 3 else { continue }
                    let world = loop.map { tp($0.x, $0.y) }
                    target.move(to: world[0])
                    for p in world.dropFirst() { target.addLine(to: p) }
                    target.closeSubpath()
                    a.addFillRun(world, kind: .hatch, insertId: ctx.insertId, handle: h)
                }
                // Pattern hatches also get their boundary stroked so they read
                // as regions even at low alpha.
                if !solid {
                    for loop in loops {
                        guard loop.count >= 3 else { continue }
                        a.beginRun()
                        for p in loop { a.addRunPoint(tp(p.x, p.y)) }
                        a.endRun(closed: true, kind: .hatch, insertId: ctx.insertId, handle: h)
                    }
                }

            case .point(let x, let y):
                a.points.append(tp(x, y))
                a.strokes.pointInsertIds.append(ctx.insertId)

            case .text(let tr):
                var item = TextItem(position: .zero,
                                    height: CGFloat(tr.height) * ctx.scale,
                                    rotationDegrees: tr.rotationDegrees + ctx.rotationDegrees,
                                    widthFactor: CGFloat(tr.widthFactor),
                                    text: tr.text,
                                    hAlign: tr.hAlign, vAlign: tr.vAlign,
                                    mirroredX: ctx.mirrored,
                                    kind: e.kind, insertId: ctx.insertId, tag: tr.tag)
                // TEXT with non-default justification anchors at the second point.
                let anchor: CGPoint
                if tr.hAlign == 0 && tr.vAlign == 0 { anchor = tr.p1 }
                else { anchor = tr.p2 ?? tr.p1 }
                item.position = tp(anchor.x, anchor.y)
                if ctx.mirrored {
                    // Emulate MIRRTEXT=0 (AutoCAD default): mirrored text stays
                    // readable. Mirrored baseline direction is rotAdd - θ (rotAdd
                    // absorbs the mirror's 180°); flipping 180° back makes it read
                    // left-to-right, and the horizontal anchor swaps sides.
                    item.rotationDegrees = ctx.rotationDegrees - 180 - tr.rotationDegrees
                    if item.hAlign == 0 { item.hAlign = 2 }
                    else if item.hAlign == 2 { item.hAlign = 0 }
                    item.mirroredX = false
                }
                a.texts.append(item)
                // Rough bounds contribution for fit-to-view.
                a.addBoundsPoint(item.position)

            case .insert:
                break // handled in walk()
            }
        }

        let top = Ctx()
        walk(model, top)
        var modelAccs = accs
        accs = [:]
        let modelInsertCount = inserts.count   // paper-space inserts follow
        progress(0.6)
        walk(paper, top)
        var paperAccs = accs
        accs = [:]
        // Raw entity arrays are no longer needed; free them before path finalize.
        model = []; paper = []
        raw.model = []; raw.paper = []
        progress(0.85)

        func finalize(_ dict: inout [GroupKey: Accumulator]) -> ([RenderGroup], CGRect) {
            var groups: [RenderGroup] = []
            var total = CGRect.null
            // Consume entries as we go so accumulator paths are released promptly —
            // never hold two full copies of multi-GB path data. Nothing mutates the
            // paths after this point, so no defensive .copy() either.
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
            // Fully deterministic order (selection refs index into this array,
            // so ties must not fall back to dictionary iteration order).
            groups.sort {
                if $0.layerId != $1.layerId { return $0.layerId < $1.layerId }
                let c0 = String(describing: $0.color), c1 = String(describing: $1.color)
                if c0 != c1 { return c0 < c1 }
                if $0.linetypeId != $1.linetypeId { return $0.linetypeId < $1.linetypeId }
                return $0.xrefId < $1.xrefId
            }
            return (groups, total.isNull ? .zero : total)
        }

        let (modelGroups, modelBounds) = finalize(&modelAccs)
        let (paperGroups, paperBounds) = finalize(&paperAccs)

        // Robust fit rect: percentile band of geometry-center density, so stray
        // faraway content can't hijack the initial view.
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
            // If the percentile band isn't meaningfully tighter, keep true extents.
            if r.width * r.height > full.width * full.height * 0.5 { return full }
            return r.intersection(full).isNull ? full : r
        }

        let modelFit = robustFit(modelGroups, full: modelBounds)
        let paperFit = robustFit(paperGroups, full: paperBounds)

        var layers = raw.layers
        for i in layers.indices { layers[i].entityCount = layerCounts[i] }

        // Scale linetype dash lengths by the drawing's global LTSCALE.
        let linetypes = raw.linetypes.map {
            DXFLinetype(name: $0.name, dashes: $0.dashes.map { d in d * raw.ltScale })
        }

        var stats = ParseStats()
        stats.totalEntities = expandedCount
        stats.parseSeconds = parseSeconds
        stats.buildSeconds = Date().timeIntervalSince(t0)
        stats.truncated = truncated
        stats.skippedTypes = raw.skippedTypes

        let unitsLabel: String = [1: "in", 2: "ft", 3: "mi", 4: "mm", 5: "cm",
                                  6: "m", 7: "km", 8: "µin", 9: "mil", 10: "yd"][raw.insUnits] ?? ""

        let doc = DXFDocument(layers: layers, linetypes: linetypes, xrefs: xrefs,
                           modelGroups: modelGroups, paperGroups: paperGroups,
                           modelBounds: modelBounds, paperBounds: paperBounds,
                           modelFitBounds: modelFit, paperFitBounds: paperFit,
                           inserts: inserts, modelInsertCount: modelInsertCount,
                           unitsLabel: unitsLabel, stats: stats)
        doc.insUnits = raw.insUnits

        // ---- Capture stampable block symbols (bounded) ----
        // Most-inserted blocks first, so the stamp picker leads with the
        // symbols the drawing actually uses. Skip xref-dependent and anonymous
        // blocks; cap per-block and total geometry so huge files stay cheap.
        let candidates = insertCounts
            .filter { $0.value > 0 }
            .sorted { $0.value > $1.value }
            .map(\.key)
        var stamps: [String: [DrawnEntity]] = [:]
        var names: [String] = []
        var totalPrims = 0
        for name in candidates {
            if names.count >= 250 || totalPrims >= 40_000 { break }
            guard let block = raw.blocks[name], !block.isXref, !block.isXrefDependent
            else { continue }
            let upper = name.uppercased()
            if upper.hasPrefix("*") || upper.hasPrefix("$") { continue }
            var geo: [DrawnEntity] = []
            captureStamp(block.entities,
                         CGAffineTransform(translationX: -block.base.x, y: -block.base.y),
                         blocks: raw.blocks, depth: 0, into: &geo)
            guard !geo.isEmpty else { continue }
            stamps[name] = geo
            names.append(name)
            totalPrims += geo.count
        }
        doc.blockStamps = stamps
        doc.stampableBlockNames = names
        return doc
    }

    /// Collects a block's line/arc/circle/polyline geometry (local coordinates)
    /// as markup shapes, recursing into nested inserts. Bounded by depth and a
    /// 200-primitive cap so a stamp stays a lightweight symbol.
    private static func captureStamp(_ entities: [RawEntity], _ t: CGAffineTransform,
                                     blocks: [String: BlockDef], depth: Int,
                                     into out: inout [DrawnEntity]) {
        guard depth <= 3, out.count < 200 else { return }
        let det = t.a * t.d - t.b * t.c
        let scale = sqrt(abs(det))
        let mirrored = det < 0
        let rotDeg = atan2(t.b, t.a) * 180 / .pi
        func p(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x, y: y).applying(t) }
        for e in entities {
            if out.count >= 200 { return }
            switch e.geom {
            case .line(let x1, let y1, let x2, let y2):
                out.append(DrawnEntity(shape: .line(a: p(x1, y1), b: p(x2, y2))))
            case .circle(let cx, let cy, let r):
                out.append(DrawnEntity(shape: .circle(center: p(cx, cy), radius: r * scale)))
            case .arc(let cx, let cy, let r, let a1, let a2):
                // A reflected transform reverses the sweep direction (same rule
                // the main renderer applies).
                var s = a1, e2 = a2
                if mirrored { s = -a2; e2 = -a1 }
                out.append(DrawnEntity(shape: .arc(center: p(cx, cy), radius: r * scale,
                                                   startDeg: s + rotDeg, endDeg: e2 + rotDeg)))
            case .polyline(let verts, let closed):
                guard verts.count > 1 else { continue }
                out.append(DrawnEntity(shape: .polyline(pts: verts.map { p($0.x, $0.y) },
                                                        closed: closed)))
            case .solidFill(let pts):
                guard pts.count >= 3 else { continue }
                out.append(DrawnEntity(shape: .polyline(pts: pts.map { p($0.x, $0.y) },
                                                        closed: true)))
            case .insert(let ins):
                guard let sub = blocks[ins.name], !sub.isXref else { continue }
                var bt = CGAffineTransform.identity
                bt = bt.translatedBy(x: ins.x, y: ins.y)
                bt = bt.rotated(by: ins.rotationDegrees * .pi / 180)
                bt = bt.scaledBy(x: ins.sx, y: ins.sy)
                bt = bt.translatedBy(x: -sub.base.x, y: -sub.base.y)
                captureStamp(sub.entities, bt.concatenating(t), blocks: blocks,
                             depth: depth + 1, into: &out)
            default:
                break   // skip text/hatch/point in stamps
            }
        }
    }
}
