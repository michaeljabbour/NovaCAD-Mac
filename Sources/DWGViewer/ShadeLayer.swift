import Foundation
import CADCore
import CoreGraphics

// MARK: - "Shade Layer" — fill/hatch every closed shape on a layer
//
// AutoCAD has no single command that does exactly this (its own HATCH
// command targets one boundary pick at a time), but it's a natural, common
// plant-layout workflow: shade every closed shape on a given layer (station
// footprints, aisle cells, etc.) at once. Implemented as REAL, PERSISTENT
// HATCH (solid style) or LINE (crosshatch style) entities placed on a
// dedicated, auto-created `NOVACAD-SHADE-<layer>` layer — never on the
// source layer itself, and never mutating the source shapes:
//   - Toggle on/off later via that shade layer's own eye icon in the Layers
//     panel (exactly like any other layer) — no separate on/off mechanism
//     needed.
//   - Recolor later via the same Layer Properties color editing this file's
//     sibling feature (`ContentView.setLayerColor`) provides, since shade
//     entities are BYLAYER (ACI 256) by construction.
//   - Delete via ordinary select + Delete, or by deleting the shade layer's
//     contents; survives save/reopen as ordinary DXF HATCH/LINE entities.
//   - Fully undoable — `apply(_:style:in:tx:)` only ever calls `tx.add`/
//     `tx.delete`, no `registerSideEffect` needed (unlike the layer-color
//     edit, this touches the ordinary EntityStore, which `Transaction`
//     already covers).
//
// Candidate shape detection deliberately reuses `RegionTool.makeRegion`'s
// exact "closed LWPOLYLINE/POLYLINE2D, CIRCLE, or full-sweep ELLIPSE" scope
// (see that file's header comment for why arbitrary multi-curve boundary
// tracing is out of scope) — this is the same "genuinely hard, lower-value
// on its own" boundary-detection problem HATCH shares with REGION, and the
// same fallback scope applies here. Nested/overlapping shapes on the same
// layer are shaded INDEPENDENTLY (no containment/hole analysis) — a shape
// fully inside another simply draws on top of it, per this feature's
// explicit product scope decision.
enum ShadeStyle {
    case solid
    case crosshatch
}

enum ShadeLayer {

    static let namePrefix = "NOVACAD-SHADE-"

    static func shadeLayerName(for sourceLayerName: String) -> String {
        namePrefix + sourceLayerName
    }

    /// Global safety cap on crosshatch LINE entities emitted by one
    /// invocation — protects against a layer with many large closed shapes
    /// producing an unreasonable entity-count explosion. Solid fills have
    /// no equivalent risk (one HATCH entity per shape, regardless of size).
    private static let maxCrosshatchSegments = 20_000

    struct Result {
        var shapesShaded: Int
        var crosshatchTruncated: Bool
    }

    /// Applies `style` to every closed-shape candidate currently on
    /// `layerId`, replacing any shade content a PRIOR call already left on
    /// that layer's dedicated shade layer (idempotent re-shading — running
    /// "Shade Layer" again, even with a different style, doesn't stack
    /// duplicates on top of the old run). Returns 0-shape result if
    /// `layerId` doesn't resolve or has no eligible shapes.
    @discardableResult
    static func apply(toLayer layerId: Int32, style: ShadeStyle,
                      in parsed: EditableParsedDocument, tx: Transaction) -> Result {
        let store = parsed.store
        guard layerId >= 0, Int(layerId) < parsed.layers.count else {
            return Result(shapesShaded: 0, crosshatchTruncated: false)
        }
        let sourceLayer = parsed.layers[Int(layerId)]
        let shadeName = shadeLayerName(for: sourceLayer.name)

        // Preserve a previously-customized shade-layer color across a
        // re-shade (e.g. the user adjusted it via Layer Properties after an
        // earlier Shade Layer run); default to the source layer's own color
        // the FIRST time this layer is shaded.
        let existingShadeId = parsed.layerIdByName[shadeName]
        let defaultColor = existingShadeId.map { parsed.layers[Int($0)].color } ?? sourceLayer.color
        let shadeLayerId = MarkupStore.ensureLayer(named: shadeName, in: parsed, defaultColor: defaultColor)

        // Idempotency: clear any entities a PRIOR run already placed on the
        // shade layer before regenerating fresh geometry, so re-running
        // (even with a different style/after the source shapes moved)
        // never stacks duplicate fills/lines on top of stale ones.
        for i in store.headers.indices {
            let h = store.headers[i]
            guard !h.flags.contains(.deleted), h.layerId == shadeLayerId,
                  h.owner.isModel || h.owner.isPaper else { continue }
            tx.delete(EntityID(raw: Int32(i)))
        }

        // Snapshot candidates BEFORE adding anything (appends below grow
        // `store.headers`, and iterating a moving target would visit the
        // shade entities we're currently creating).
        var candidates: [(loop: [Vec3], owner: OwnerRef)] = []
        let headerCount = store.headers.count
        for i in 0..<headerCount {
            let h = store.headers[i]
            guard !h.flags.contains(.deleted), h.layerId == layerId, h.payload >= 0,
                  h.owner.isModel || h.owner.isPaper else { continue }
            guard let loop = closedLoop(for: h, store: store) else { continue }
            candidates.append((loop, h.owner))
        }
        guard !candidates.isEmpty else { return Result(shapesShaded: 0, crosshatchTruncated: false) }

        var truncated = false
        var segmentBudget = maxCrosshatchSegments

        for (loop, owner) in candidates {
            switch style {
            case .solid:
                let payload = HatchPayload(isSolid: true, angle: 0, scale: 1, origin: centroid(of: loop))
                let proto = EntityPrototype(type: .hatch, layerId: shadeLayerId, aci: 256,
                                           owner: owner, payload: .hatch(payload, loops: [loop]))
                tx.add(proto)

            case .crosshatch:
                guard segmentBudget > 0 else { truncated = true; continue }
                let segments = crosshatchSegments(for: loop, angleDeg: 45)
                let toAdd = segments.prefix(segmentBudget)
                if segments.count > toAdd.count { truncated = true }
                segmentBudget -= toAdd.count
                for (a, b) in toAdd {
                    let proto = EntityPrototype(type: .line, layerId: shadeLayerId, aci: 256,
                                               owner: owner, payload: .line(LinePayload(a: a, b: b)))
                    tx.add(proto)
                }
            }
        }
        return Result(shapesShaded: candidates.count, crosshatchTruncated: truncated)
    }

    // MARK: - Closed-loop extraction
    //
    // Mirrors `RegionTool.makeRegion`'s exact candidate scope (closed
    // LWPOLYLINE/POLYLINE2D with bulge-arc expansion, CIRCLE, full-sweep
    // ELLIPSE), but returns the tessellated boundary LOOP itself (world
    // points) rather than just an area/perimeter summary — top-level
    // model/paper entities' payload coordinates are already world-space
    // (no block transform to undo), so no context/transform-stack walk
    // (unlike `Regenerator`'s block-instance expansion) is needed here.

    /// Generates a diagonal-line hatch pattern for one closed `loop`, at
    /// `angleDeg` and `density` (bigger `density` = more, closer-spaced
    /// lines — a straight multiplier over the shape's own diagonal-derived
    /// base spacing, `1.0` matching `ShadeLayer`'s original always-1.0
    /// crosshatch spacing exactly, so nothing here changes `apply(...)`'s
    /// own "Shade Layer" bulk-crosshatch behavior). Not `private` (unlike
    /// most of this file's helpers) — `Regenerator`'s `.hatch` render case
    /// reuses this EXACT algorithm for a `HatchPayload` whose
    /// `patternNameId` names `HatchTool.diagonalPatternName` (the
    /// Properties panel's "Diagonal Lines" fill-style choice — see that
    /// enum's own doc comment), rather than re-deriving a second polygon-
    /// scanline hatch-fill implementation.
    static func crosshatchSegments(for loop: [Vec3], angleDeg: Double, density: Double = 1.0) -> [(Vec3, Vec3)] {
        crosshatchSegmentsImpl(for: loop, angleDeg: angleDeg, density: max(density, 0.01))
    }

    // Not `private` (unlike this file's other helpers) — `HatchTool`'s
    // single-entity "Fill / Hatch…" command (Properties panel) reuses this
    // EXACT boundary extraction (closed LWPOLYLINE/POLYLINE2D with bulge-arc
    // expansion, CIRCLE, full-sweep ELLIPSE) rather than re-deriving its own,
    // slightly-different notion of "what counts as a fillable closed shape."
    static func closedLoop(for h: EntityHeader, store: EntityStore) -> [Vec3]? {
        switch h.type {
        case .lwpolyline, .polyline2d:
            let p = store.polylines[Int(h.payload)]
            guard p.closed, p.vertsCount >= 3 else { return nil }
            let vStart = Int(p.vertsStart), bStart = Int(p.bulgesStart), vCount = Int(p.vertsCount)
            var pts: [CGPoint] = []
            for k in 0..<vCount {
                let v = store.vertexArena[vStart + k]
                let bulge = store.scalarArena[bStart + k]
                pts.append(v.cgPoint)
                if bulge != 0 {
                    let nv = store.vertexArena[vStart + (k + 1) % vCount]
                    appendBulgeArc(from: v.cgPoint, to: nv.cgPoint, bulge: bulge, into: &pts)
                }
            }
            guard pts.count >= 3 else { return nil }
            return pts.map { Vec3($0) }

        case .circle:
            let c = store.circles[Int(h.payload)]
            guard c.radius > 0 else { return nil }
            let steps = 64
            return (0..<steps).map { k -> Vec3 in
                let ang = 2 * Double.pi * Double(k) / Double(steps)
                return Vec3(x: c.center.x + c.radius * cos(ang), y: c.center.y + c.radius * sin(ang))
            }

        case .ellipse:
            let e = store.ellipses[Int(h.payload)]
            let sweep = abs(e.endParam - e.startParam)
            // Full sweep only — an elliptical ARC has no well-defined
            // enclosed area (matches `RegionTool.makeRegion`'s own guard).
            guard sweep >= 2 * .pi - 1e-6 else { return nil }
            let majorLen = e.majorAxisEndpoint.length
            guard majorLen > 0 else { return nil }
            let minorLen = majorLen * e.ratio
            let rot = atan2(e.majorAxisEndpoint.y, e.majorAxisEndpoint.x)
            let steps = 64
            var pts: [Vec3] = []
            pts.reserveCapacity(steps)
            for k in 0..<steps {
                let ang = 2 * Double.pi * Double(k) / Double(steps)
                let ex = majorLen * cos(ang), ey = minorLen * sin(ang)
                pts.append(Vec3(x: e.center.x + ex * cos(rot) - ey * sin(rot),
                                y: e.center.y + ex * sin(rot) + ey * cos(rot)))
            }
            return pts

        default:
            return nil
        }
    }

    private static func centroid(of loop: [Vec3]) -> Vec3 {
        guard !loop.isEmpty else { return Vec3(x: 0, y: 0) }
        var sx = 0.0, sy = 0.0
        for p in loop { sx += p.x; sy += p.y }
        return Vec3(x: sx / Double(loop.count), y: sy / Double(loop.count))
    }

    // MARK: - Crosshatch pattern-line generation (ANSI31-like diagonal fill)
    //
    // Standard polygon-hatch-fill algorithm: rotate the loop into a frame
    // where hatch lines are horizontal, sweep evenly-spaced rows across the
    // rotated bounding box, intersect each row with every polygon edge, and
    // pair up the crossings under the even-odd rule to get the "inside"
    // sub-segments for that row — correct for non-convex polygons (a row
    // can yield more than one segment). Spacing is proportional to the
    // shape's own diagonal (there's no universal absolute spacing that
    // looks right across arbitrary drawing units) and clamped so a single
    // very large shape doesn't emit an unreasonable number of lines.
    private static func crosshatchSegmentsImpl(for loop: [Vec3], angleDeg: Double, density: Double) -> [(Vec3, Vec3)] {
        guard loop.count >= 3 else { return [] }
        let angle = angleDeg * .pi / 180
        let ca = cos(angle), sa = sin(angle)
        // Rotate a world point by -angle into the local frame (so lines
        // drawn at `angleDeg` in world space become horizontal locally).
        func toLocal(_ p: Vec3) -> CGPoint {
            CGPoint(x: p.x * ca + p.y * sa, y: -p.x * sa + p.y * ca)
        }
        // Rotate a local-frame point back by +angle into world space.
        func toWorld(_ p: CGPoint) -> Vec3 {
            Vec3(x: p.x * ca - p.y * sa, y: p.x * sa + p.y * ca)
        }

        let local = loop.map(toLocal)
        let minY = local.map(\.y).min() ?? 0
        let maxY = local.map(\.y).max() ?? 0
        let minX = local.map(\.x).min() ?? 0
        let maxX = local.map(\.x).max() ?? 0
        let diag = hypot(maxX - minX, maxY - minY)
        guard diag > 1e-9 else { return [] }

        // `density` divides the base spacing — higher density = smaller
        // spacing = more lines (matching the Properties panel's "Hatch
        // Density" slider: sliding right packs lines tighter). `1.0` yields
        // EXACTLY `ShadeLayer.apply(...)`'s original `diag / 14` spacing —
        // the one caller that predates this parameter — so bulk "Shade
        // Layer" crosshatching is byte-for-byte unaffected.
        let maxLinesPerShape = min(200, max(10, Int(40 * density)))
        var spacing = diag / 14 / density
        if spacing > 0, (maxY - minY) / spacing > Double(maxLinesPerShape) {
            spacing = (maxY - minY) / Double(maxLinesPerShape)
        }
        guard spacing > 1e-9 else { return [] }

        var segments: [(Vec3, Vec3)] = []
        var y = minY + spacing / 2
        while y <= maxY {
            var xs: [Double] = []
            for i in 0..<local.count {
                let p1 = local[i], p2 = local[(i + 1) % local.count]
                let y1 = p1.y, y2 = p2.y
                if (y1 <= y && y2 > y) || (y2 <= y && y1 > y) {
                    let t = (y - y1) / (y2 - y1)
                    xs.append(p1.x + t * (p2.x - p1.x))
                }
            }
            xs.sort()
            var i = 0
            while i + 1 < xs.count {
                let a = CGPoint(x: xs[i], y: y)
                let b = CGPoint(x: xs[i + 1], y: y)
                segments.append((toWorld(a), toWorld(b)))
                i += 2
            }
            y += spacing
        }
        return segments
    }
}
