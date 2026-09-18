import Foundation
import CoreGraphics
import CADCore

// MARK: - Grip editing (new feature)
//
// AutoCAD-style "grips": small draggable handles at an entity's defining
// points (a polyline's vertices, a line's endpoints, a circle's center +
// radius point, an arc's endpoints + midpoint). Dragging ONE grip reshapes
// just that point while every other point on the entity stays put — the
// mechanism that lets a user "extrude/extend a section" of an enclosed
// polyline without exploding it into disconnected segments (see
// `Editing/Explode.swift`'s own doc comment on why Explode+Move can't
// reproduce this: moving a whole exploded LINE moves BOTH its endpoints
// together, severing it from its neighbors).
//
// Scope (per this feature's product decision): LWPOLYLINE (straight AND
// bulged/arc segments) + LINE/CIRCLE/ARC endpoints + HATCH boundary loops.
// Every grip is addressed by a stable `GripIndex` (entity id + a small
// per-type index), so a drag can be resumed/cancelled/undone without
// re-deriving "which point is this" from scratch each frame.
//
// HATCH is in scope because a solid-fill HATCH's boundary loop is
// structurally just a closed vertex list — the same thing a closed
// LWPOLYLINE is — and it is how EVERY area-shading feature in this app
// persists its geometry: `ShadeLayer`'s "Solid Fill" style, and the AI
// Assistant's `shade_aisle_network`/`shade_dock_aprons` tools (see
// `AIProposedGeometryApplier.apply`). Before HATCH was handled here, all
// of that geometry selected, moved, rotated, scaled, mirrored, recolored
// and exploded perfectly well — but had ZERO grips, so STRETCH caught
// nothing and grip-drag never started, which reads to a user as "this
// object is not editable at all" (reported verbatim: "i would like to
// extend the length of one of the aisles ... but i am unable to do so").
// The gap was purely this file's `default: return []`, NOT anything about
// how the geometry was created: hit-testing already resolves fill runs to
// their entity id (`HitTesting`'s `fillRuns` cases), and
// `EntityTransform` already has a full `.hatch` case. Since a hatch's
// loops are the ONLY representation of its shape, moving a boundary grip
// reshapes the filled area itself — exactly the "extend this aisle"
// operation, with no explode step and no separate outline entity to keep
// in sync.
enum GripEditing {

    /// One entity's defining points, in a fixed, entity-type-specific order
    /// — index 0 for a polyline is vertex 0, index 1 is vertex 1, etc.; for
    /// a LINE, index 0 = endpoint A, 1 = endpoint B; for a CIRCLE, index 0 =
    /// center, 1 = a point on the circle at 0° (dragging it changes radius,
    /// not position); for an ARC, index 0 = start point, 1 = end point,
    /// 2 = midpoint (dragging the midpoint bows the arc through the new
    /// point, matching AutoCAD's own arc-midpoint grip behavior).
    struct GripPoint {
        var index: Int
        var position: CGPoint
    }

    /// Every entity type this feature supports has grips; every other type
    /// returns an empty array (nothing draws/hit-tests for it), matching
    /// `MarkupStore.shapeForGhost`'s own "unsupported type -> nil/empty"
    /// convention.
    static func grips(for id: EntityID, in store: EntityStore) -> [GripPoint] {
        guard let h = store.header(id), !h.flags.contains(.deleted), h.payload >= 0 else { return [] }
        let p = Int(h.payload)
        switch h.type {
        case .line:
            let l = store.lines[p]
            return [GripPoint(index: 0, position: l.a.cgPoint), GripPoint(index: 1, position: l.b.cgPoint)]
        case .lwpolyline, .polyline2d, .polyline3d:
            let pl = store.polylines[p]
            var result: [GripPoint] = []
            result.reserveCapacity(Int(pl.vertsCount))
            for i in 0..<Int(pl.vertsCount) {
                result.append(GripPoint(index: i, position: store.vertexArena[Int(pl.vertsStart) + i].cgPoint))
            }
            return result
        case .circle:
            let c = store.circles[p]
            let onCircle = CGPoint(x: c.center.cgPoint.x + CGFloat(c.radius), y: c.center.cgPoint.y)
            return [GripPoint(index: 0, position: c.center.cgPoint), GripPoint(index: 1, position: onCircle)]
        case .arc:
            let a = store.arcs[p]
            let start = pointOnArc(a, angleDeg: a.startAngleDeg)
            let end = pointOnArc(a, angleDeg: a.endAngleDeg)
            let midAngle = midArcAngleDeg(start: a.startAngleDeg, end: a.endAngleDeg)
            let mid = pointOnArc(a, angleDeg: midAngle)
            return [GripPoint(index: 0, position: start), GripPoint(index: 1, position: end),
                   GripPoint(index: 2, position: mid)]
        case .hatch:
            // One grip per boundary-loop vertex, indexed by a FLATTENED
            // running counter across every loop in `loopRangeStart`'s order
            // — the same order `EntityPayloadCopy.hatch(_, loops:)` presents
            // them in, which is what makes a flat `Int` grip index round-trip
            // correctly through `moveGrip` (see `hatchLoopIndex` below).
            let hp = store.hatches[p]
            var result: [GripPoint] = []
            var flat = 0
            for r in Int(hp.loopRangeStart)..<Int(hp.loopRangeStart + hp.loopRangeCount) {
                let range = store.hatchLoopRanges[r]
                for i in 0..<Int(range.vertCount) {
                    result.append(GripPoint(index: flat,
                                            position: store.vertexArena[Int(range.vertStart) + i].cgPoint))
                    flat += 1
                }
            }
            return result
        default:
            return []
        }
    }

    /// True for every entity type `grips(for:in:)` supports — lets callers
    /// (hover/selection UI) cheaply decide whether to even attempt grip
    /// display without extracting the full point list.
    static func isGripEditable(_ type: DXFEntityType) -> Bool {
        switch type {
        case .line, .lwpolyline, .polyline2d, .polyline3d, .circle, .arc, .hatch: return true
        default: return false
        }
    }

    /// Resolves a FLATTENED hatch grip index (as handed out by
    /// `grips(for:in:)`'s `.hatch` case) into the (loop, vertex-within-loop)
    /// pair `EntityPayloadCopy.hatch(_, loops:)` is addressed by. Kept as one
    /// shared helper so the grip-emitting, preview, and commit paths can
    /// never drift out of agreement about what index N means — the classic
    /// way a "drag vertex A, watch vertex B move" bug gets introduced.
    /// Returns nil for an out-of-range index.
    static func hatchLoopIndex(_ flat: Int, loops: [[Vec3]]) -> (loop: Int, vertex: Int)? {
        guard flat >= 0 else { return nil }
        var remaining = flat
        for (l, loop) in loops.enumerated() {
            if remaining < loop.count { return (l, remaining) }
            remaining -= loop.count
        }
        return nil
    }

    /// Every boundary loop of hatch `id`, in `loopRangeStart` order — the
    /// read-side counterpart to `hatchLoopIndex`, used by the preview paths
    /// (which need the whole shape, not just one point) and by ghost
    /// reconstruction. Returns an empty array for a non-hatch/unresolved id.
    static func hatchLoops(of id: EntityID, in store: EntityStore) -> [[CGPoint]] {
        guard let h = store.header(id), !h.flags.contains(.deleted), h.payload >= 0,
              h.type == .hatch else { return [] }
        let hp = store.hatches[Int(h.payload)]
        var loops: [[CGPoint]] = []
        for r in Int(hp.loopRangeStart)..<Int(hp.loopRangeStart + hp.loopRangeCount) {
            let range = store.hatchLoopRanges[r]
            let start = Int(range.vertStart)
            loops.append((0..<Int(range.vertCount)).map { store.vertexArena[start + $0].cgPoint })
        }
        return loops
    }

    private static func pointOnArc(_ a: ArcPayload, angleDeg: Double) -> CGPoint {
        let rad = angleDeg * .pi / 180
        return CGPoint(x: a.center.cgPoint.x + CGFloat(a.radius * cos(rad)),
                       y: a.center.cgPoint.y + CGFloat(a.radius * sin(rad)))
    }

    /// The angle of the point midway along the arc's CCW sweep from `start`
    /// to `end` (matching `ArcPayload`'s own "CCW sweep" convention, per its
    /// doc comment) — NOT simply `(start+end)/2`, which is wrong whenever
    /// the sweep crosses 0°/360°.
    private static func midArcAngleDeg(start: Double, end: Double) -> Double {
        var sweep = end - start
        while sweep < 0 { sweep += 360 }
        while sweep > 360 { sweep -= 360 }
        return start + sweep / 2
    }

    // MARK: - Hover/click hit-testing

    /// One grip on ONE entity, found by `nearestGrip` — same
    /// entity+index+position shape as `GripPoint`, but scoped to a single
    /// candidate entity rather than "all grips of one entity" (`grips(for:)`
    /// itself stays entity-scoped since that's what rendering needs; this
    /// wraps it with the entity id for hover/click hit-testing across a
    /// caller-supplied candidate set, mirroring `CaughtGrip`'s shape below).
    struct HitGrip {
        var entityId: EntityID
        var gripIndex: Int
        var position: CGPoint
    }

    /// Finds the closest grip (across every grip-editable entity in
    /// `candidateIds`) to `worldPoint`, within `tolerance` — the shared
    /// hit-test behind both hover-highlight and click-to-begin-drag. A
    /// `tolerance`-bounded nearest search (not "first in iteration order
    /// within tolerance") so that with two grips close together the
    /// genuinely closer one always wins, matching `Osnap.snap`'s own
    /// nearest-not-first convention.
    static func nearestGrip(candidateIds: [EntityID], in store: EntityStore, to worldPoint: CGPoint,
                            tolerance: CGFloat) -> HitGrip? {
        var best: HitGrip? = nil
        var bestDist: CGFloat = .greatestFiniteMagnitude
        for id in candidateIds {
            for grip in grips(for: id, in: store) {
                let dist = hypot(worldPoint.x - grip.position.x, worldPoint.y - grip.position.y)
                if dist <= tolerance, dist < bestDist {
                    bestDist = dist
                    best = HitGrip(entityId: id, gripIndex: grip.index, position: grip.position)
                }
            }
        }
        return best
    }

    // MARK: - Single-grip drag (reshape one point, keep everything else)

    /// Moves ONE grip of entity `id` to `newPosition`, leaving every other
    /// defining point exactly where it was. This is the core "drag a
    /// vertex" mutation — the whole reason grips exist instead of just
    /// reusing `EntityPayloadCopy.translate` (which moves every point
    /// together). No-op (silently) for an id/index combination that doesn't
    /// resolve, matching this codebase's established "return false /
    /// silently skip" convention for a stale target (see `BlockEditor
    /// .setAttribute`) rather than throwing.
    static func moveGrip(_ id: EntityID, index: Int, to newPosition: CGPoint, in tx: Transaction) {
        tx.modifyPayload(id) { copy in
            let z: Double
            switch copy {
            case .line(let p): z = index == 0 ? p.a.z : p.b.z
            case .polyline(_, let verts, _): z = index < verts.count ? verts[index].z : 0
            case .hatch(_, let loops):
                // Preserve the dragged boundary vertex's own elevation, same
                // as the polyline case above — a hatch loop parsed from a
                // real drawing can sit on a non-zero Z.
                if let (l, v) = hatchLoopIndex(index, loops: loops) { z = loops[l][v].z } else { z = 0 }
            default: z = 0
            }
            let newPoint = Vec3(newPosition, z: z)
            switch copy {
            case .line(var p):
                if index == 0 { p.a = newPoint } else if index == 1 { p.b = newPoint }
                copy = .line(p)
            case .polyline(let p, var verts, let bulges):
                guard index >= 0, index < verts.count else { return }
                verts[index] = newPoint
                copy = .polyline(p, vertices: verts, bulges: bulges)
            case .circle(var p):
                if index == 0 {
                    p.center = newPoint
                } else if index == 1 {
                    // Dragging the "on-circle" grip changes the RADIUS,
                    // keeping the center fixed — matches AutoCAD's own
                    // circle-quadrant-grip behavior.
                    let dx = Double(newPosition.x) - p.center.x, dy = Double(newPosition.y) - p.center.y
                    p.radius = max(1e-9, (dx * dx + dy * dy).squareRoot())
                }
                copy = .circle(p)
            case .arc(var p):
                switch index {
                case 0: p.startAngleDeg = angleDeg(from: p.center.cgPoint, to: newPosition)
                case 1: p.endAngleDeg = angleDeg(from: p.center.cgPoint, to: newPosition)
                case 2:
                    // Dragging the midpoint grip re-radii the arc through
                    // the new point (keeping both endpoint ANGLES fixed) —
                    // matches AutoCAD's arc-midpoint-grip "reshape" behavior
                    // (bowing the arc in/out) rather than moving an endpoint.
                    let dx = Double(newPosition.x) - p.center.x, dy = Double(newPosition.y) - p.center.y
                    p.radius = max(1e-9, (dx * dx + dy * dy).squareRoot())
                default: break
                }
                copy = .arc(p)
            case .hatch(let p, var loops):
                // A hatch's boundary loops ARE its shape (there is no
                // separate outline entity), so moving one loop vertex
                // directly reshapes the filled area — this is what makes
                // "extend this shaded aisle" work by dragging its corner,
                // with every other corner staying put.
                guard let (l, v) = hatchLoopIndex(index, loops: loops) else { return }
                loops[l][v] = newPoint
                copy = .hatch(p, loops: loops)
            default:
                break
            }
        }
    }

    private static func angleDeg(from center: CGPoint, to point: CGPoint) -> Double {
        atan2(Double(point.y - center.y), Double(point.x - center.x)) * 180 / .pi
    }

    // MARK: - ADDVERTEX (insert a new vertex into a polyline edge)

    /// Inserts a new vertex at `at` into polyline `id`'s edge between
    /// vertices `afterIndex` and `afterIndex + 1` (wrapping to 0 for a
    /// closed polyline's last edge) — the mechanism behind both the
    /// double-click-on-an-edge gesture and the "Add Vertex" context-menu
    /// command. The new vertex's bulge and its predecessor's bulge are both
    /// reset to 0 (straight) rather than trying to preserve an arc
    /// segment's curvature split at an arbitrary new point — an edge with a
    /// bulge that gets a vertex inserted becomes two straight segments;
    /// re-adding curvature is a separate, explicit action (not attempted
    /// here, matching this feature's "insert a point to drag" scope, not "
    /// intelligently preserve arc shape while doing it").
    /// No-op for a non-polyline id or an out-of-range `afterIndex`.
    /// Also handles HATCH, whose boundary loop takes a new vertex the same
    /// way (no bulge array to keep in step) — so a shaded area can gain a
    /// corner and then be reshaped into an L/notch, not just have its
    /// existing corners dragged.
    static func addVertex(_ id: EntityID, afterIndex: Int, at newPoint: CGPoint, in tx: Transaction) {
        tx.modifyPayload(id) { copy in
            switch copy {
            case .polyline(let p, var verts, var bulges):
                guard afterIndex >= 0, afterIndex < verts.count else { return }
                let insertAt = afterIndex + 1
                verts.insert(Vec3(newPoint, z: verts[afterIndex].z), at: insertAt)
                bulges.insert(0, at: min(insertAt, bulges.count))
                if afterIndex < bulges.count { bulges[afterIndex] = 0 }
                copy = .polyline(p, vertices: verts, bulges: bulges)
            case .hatch(let p, var loops):
                guard let (l, v) = hatchLoopIndex(afterIndex, loops: loops) else { return }
                loops[l].insert(Vec3(newPoint, z: loops[l][v].z), at: v + 1)
                copy = .hatch(p, loops: loops)
            default:
                return
            }
        }
    }

    /// Finds the closest point ON the polyline's boundary (any straight
    /// edge; bulged/arc edges are treated as their CHORD for this purpose —
    /// good enough for "where should double-clicking near this curved edge
    /// insert a point," not used for anything geometry-critical) to
    /// `worldPoint`, within `tolerance`, returning the edge's starting
    /// vertex index (i.e. the `afterIndex` to pass to `addVertex`) and the
    /// snapped point. Returns nil if `worldPoint` isn't close enough to any
    /// edge, or `id` isn't a polyline with >= 2 vertices.
    /// A HATCH's boundary loops are treated the same way (always closed, so
    /// every loop's last->first edge is a candidate too), with the returned
    /// `afterIndex` in the same FLATTENED index space `grips(for:in:)` and
    /// `addVertex` use.
    static func nearestEdge(of id: EntityID, in store: EntityStore, to worldPoint: CGPoint,
                            tolerance: CGFloat) -> (afterIndex: Int, point: CGPoint)? {
        guard let h = store.header(id), !h.flags.contains(.deleted), h.payload >= 0 else { return nil }
        if h.type == .hatch {
            var best: (Int, CGPoint, CGFloat)? = nil
            var flat = 0
            for loop in hatchLoops(of: id, in: store) {
                let n = loop.count
                guard n >= 2 else { flat += n; continue }
                for i in 0..<n {       // closed: includes the wrap-around edge
                    let (closest, dist) = closestPointOnSegment(worldPoint, loop[i], loop[(i + 1) % n])
                    if best == nil || dist < best!.2 { best = (flat + i, closest, dist) }
                }
                flat += n
            }
            guard let (index, point, dist) = best, dist <= tolerance else { return nil }
            return (index, point)
        }
        guard h.type == .lwpolyline || h.type == .polyline2d || h.type == .polyline3d else { return nil }
        let pl = store.polylines[Int(h.payload)]
        let n = Int(pl.vertsCount)
        guard n >= 2 else { return nil }
        let segmentCount = pl.closed ? n : n - 1
        var best: (Int, CGPoint, CGFloat)? = nil
        for i in 0..<segmentCount {
            let a = store.vertexArena[Int(pl.vertsStart) + i].cgPoint
            let b = store.vertexArena[Int(pl.vertsStart) + (i + 1) % n].cgPoint
            let (closest, dist) = closestPointOnSegment(worldPoint, a, b)
            if best == nil || dist < best!.2 { best = (i, closest, dist) }
        }
        guard let (index, point, dist) = best, dist <= tolerance else { return nil }
        return (index, point)
    }

    private static func closestPointOnSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> (CGPoint, CGFloat) {
        let abx = b.x - a.x, aby = b.y - a.y
        let lengthSq = abx * abx + aby * aby
        guard lengthSq > 1e-12 else { return (a, hypot(p.x - a.x, p.y - a.y)) }
        var t = ((p.x - a.x) * abx + (p.y - a.y) * aby) / lengthSq
        t = min(max(t, 0), 1)
        let closest = CGPoint(x: a.x + t * abx, y: a.y + t * aby)
        return (closest, hypot(p.x - closest.x, p.y - closest.y))
    }

    // MARK: - Live drag preview (pure geometry, no store mutation)

    /// A best-effort `DrawnEntity.Shape` preview of entity `id` as it WOULD
    /// look if grip `index` were moved to `candidatePosition` — the ghost
    /// drawn while the user is still dragging (before the drop commits via
    /// `moveGrip`). Deliberately duplicates `moveGrip`'s per-type math
    /// against a plain in-memory snapshot rather than running it through a
    /// real (and then rolled-back) `Transaction`, matching this codebase's
    /// existing ghost-preview convention (`ContentView.moveGhostEntities`/
    /// `modifyGhostEntities` also recompute geometry directly rather than
    /// speculatively mutating the store). Returns nil for a non-grip-
    /// editable/unresolved id, mirroring `grips(for:in:)`'s own convention.
    static func previewShape(for id: EntityID, in store: EntityStore, gripIndex: Int,
                             candidatePosition: CGPoint) -> DrawnEntity.Shape? {
        guard let h = store.header(id), !h.flags.contains(.deleted), h.payload >= 0 else { return nil }
        let p = Int(h.payload)
        switch h.type {
        case .line:
            let l = store.lines[p]
            var a = l.a.cgPoint, b = l.b.cgPoint
            if gripIndex == 0 { a = candidatePosition } else if gripIndex == 1 { b = candidatePosition }
            return .line(a: a, b: b)
        case .lwpolyline, .polyline2d, .polyline3d:
            let pl = store.polylines[p]
            var pts = (0..<Int(pl.vertsCount)).map { store.vertexArena[Int(pl.vertsStart) + $0].cgPoint }
            guard gripIndex >= 0, gripIndex < pts.count else { return nil }
            pts[gripIndex] = candidatePosition
            return .polyline(pts: pts, closed: pl.closed)
        case .circle:
            let c = store.circles[p]
            let center = c.center.cgPoint
            if gripIndex == 0 {
                return .circle(center: candidatePosition, radius: CGFloat(c.radius))
            } else {
                let dx = candidatePosition.x - center.x, dy = candidatePosition.y - center.y
                return .circle(center: center, radius: max(1e-9, hypot(dx, dy)))
            }
        case .arc:
            let a = store.arcs[p]
            let center = a.center.cgPoint
            var start = a.startAngleDeg, end = a.endAngleDeg, radius = CGFloat(a.radius)
            switch gripIndex {
            case 0: start = angleDeg(from: center, to: candidatePosition)
            case 1: end = angleDeg(from: center, to: candidatePosition)
            case 2:
                let dx = candidatePosition.x - center.x, dy = candidatePosition.y - center.y
                radius = max(1e-9, hypot(dx, dy))
            default: return nil
            }
            return .arc(center: center, radius: radius, startDeg: start, endDeg: end)
        case .hatch:
            // Previewed as its boundary loop drawn as a CLOSED POLYLINE
            // outline — `DrawnEntity.Shape` has no filled-area case, and an
            // outline is the right ghost anyway (it shows the new boundary
            // without obscuring what's underneath, matching how every other
            // ghost in this app is an unfilled wireframe). Only the loop
            // CONTAINING the dragged grip is previewed, since that's the only
            // loop whose shape changes.
            let loops = hatchLoops(of: id, in: store)
            let asVecs = loops.map { $0.map { Vec3($0) } }
            guard let (l, v) = hatchLoopIndex(gripIndex, loops: asVecs) else { return nil }
            var pts = loops[l]
            pts[v] = candidatePosition
            return .polyline(pts: pts, closed: true)
        default:
            return nil
        }
    }

    // MARK: - STRETCH (crossing-window vertex selection + move)

    /// One grip caught by a STRETCH crossing window: which entity, which
    /// grip index, and its pre-move position (so the move can be computed
    /// as `position + delta` without re-reading the store mid-drag).
    struct CaughtGrip: Equatable {
        var entityId: EntityID
        var gripIndex: Int
        var position: CGPoint
    }

    /// Collects every grip of every grip-editable entity in `ids` whose
    /// position falls INSIDE `crossingWindow` — the AutoCAD STRETCH
    /// selection rule: a crossing (not window) selection catches individual
    /// VERTICES, not whole entities, which is what lets STRETCH "extrude a
    /// section" of a shape while the rest of it (whose vertices are outside
    /// the window) stays fixed. `ids` is typically the crossing-window's own
    /// whole-entity selection result (`SelectionEngine`'s existing crossing
    /// logic) — this function re-examines each of THOSE entities' individual
    /// grips against the same window, rather than duplicating crossing-
    /// window entity discovery itself.
    static func caughtGrips(ids: Set<EntityID>, in store: EntityStore,
                            crossingWindow: CGRect) -> [CaughtGrip] {
        var result: [CaughtGrip] = []
        for id in ids {
            for grip in grips(for: id, in: store) where crossingWindow.contains(grip.position) {
                result.append(CaughtGrip(entityId: id, gripIndex: grip.index, position: grip.position))
            }
        }
        return result
    }

    /// Live STRETCH ghost preview: a best-effort `DrawnEntity.Shape` for
    /// entity `id` as it WOULD look with every grip index in
    /// `caughtIndices` shifted by `delta`, leaving every other point fixed
    /// — the multi-point generalization of `previewShape` above (which only
    /// handles ONE moved grip), needed because a crossing-window STRETCH
    /// typically catches SEVERAL of an entity's vertices at once (e.g. both
    /// corners of a polyline's right edge). Same "pure geometry, no store
    /// mutation, duplicates the real math against a snapshot" rationale as
    /// `previewShape`'s own doc comment.
    static func previewStretchShape(for id: EntityID, in store: EntityStore, caughtIndices: Set<Int>,
                                    delta: CGVector) -> DrawnEntity.Shape? {
        guard let h = store.header(id), !h.flags.contains(.deleted), h.payload >= 0 else { return nil }
        guard !caughtIndices.isEmpty else { return nil }
        let p = Int(h.payload)
        func shift(_ pt: CGPoint) -> CGPoint { CGPoint(x: pt.x + delta.dx, y: pt.y + delta.dy) }
        switch h.type {
        case .line:
            let l = store.lines[p]
            var a = l.a.cgPoint, b = l.b.cgPoint
            if caughtIndices.contains(0) { a = shift(a) }
            if caughtIndices.contains(1) { b = shift(b) }
            return .line(a: a, b: b)
        case .lwpolyline, .polyline2d, .polyline3d:
            let pl = store.polylines[p]
            var pts = (0..<Int(pl.vertsCount)).map { store.vertexArena[Int(pl.vertsStart) + $0].cgPoint }
            for i in caughtIndices where i >= 0 && i < pts.count { pts[i] = shift(pts[i]) }
            return .polyline(pts: pts, closed: pl.closed)
        case .circle:
            let c = store.circles[p]
            let origCenter = c.center.cgPoint
            var center = origCenter
            var radius = CGFloat(c.radius)
            if caughtIndices.contains(0) { center = shift(origCenter) }
            if caughtIndices.contains(1) {
                let onCircle = CGPoint(x: origCenter.x + CGFloat(c.radius), y: origCenter.y)
                let shifted = shift(onCircle)
                let dx = shifted.x - center.x, dy = shifted.y - center.y
                radius = max(1e-9, hypot(dx, dy))
            }
            return .circle(center: center, radius: radius)
        case .arc:
            let a = store.arcs[p]
            let origCenter = a.center.cgPoint
            var start = a.startAngleDeg, end = a.endAngleDeg, radius = CGFloat(a.radius)
            if caughtIndices.contains(0) {
                let orig = pointOnArc(a, angleDeg: a.startAngleDeg)
                start = angleDeg(from: origCenter, to: shift(orig))
            }
            if caughtIndices.contains(1) {
                let orig = pointOnArc(a, angleDeg: a.endAngleDeg)
                end = angleDeg(from: origCenter, to: shift(orig))
            }
            if caughtIndices.contains(2) {
                let midAngle = midArcAngleDeg(start: a.startAngleDeg, end: a.endAngleDeg)
                let orig = pointOnArc(a, angleDeg: midAngle)
                let shifted = shift(orig)
                let dx = shifted.x - origCenter.x, dy = shifted.y - origCenter.y
                radius = max(1e-9, hypot(dx, dy))
            }
            return .arc(center: origCenter, radius: radius, startDeg: start, endDeg: end)
        case .hatch:
            // Multi-vertex generalization of `previewShape`'s `.hatch` case.
            // A crossing-window STRETCH typically catches SEVERAL vertices of
            // the same loop (e.g. both corners of an aisle ribbon's end cap —
            // precisely the "extend this aisle" gesture), so every caught
            // index in a given loop is shifted together. Previews the loop
            // with the LOWEST caught index, since `DrawnEntity.Shape` can
            // carry only one path; the COMMIT (`applyStretch` -> `moveGrip`)
            // is unaffected and correctly moves grips across all loops.
            let loops = hatchLoops(of: id, in: store)
            let asVecs = loops.map { $0.map { Vec3($0) } }
            var shiftedByLoop: [Int: [CGPoint]] = [:]
            for flat in caughtIndices.sorted() {
                guard let (l, v) = hatchLoopIndex(flat, loops: asVecs) else { continue }
                var pts = shiftedByLoop[l] ?? loops[l]
                pts[v] = shift(pts[v])
                shiftedByLoop[l] = pts
            }
            guard let firstLoop = shiftedByLoop.keys.min(), let pts = shiftedByLoop[firstLoop] else { return nil }
            return .polyline(pts: pts, closed: true)
        default:
            return nil
        }
    }

    /// Applies `delta` to every caught grip, one `moveGrip` call per grip —
    /// grips on the SAME entity are independent indices into that entity's
    /// own vertex/point list, so multiple caught grips per entity (e.g. two
    /// adjacent vertices of a polyline both inside the crossing window) each
    /// move correctly without interfering with each other (unlike
    /// `EntityTransform`'s whole-payload transform, which would move every
    /// point together regardless of which the user actually caught).
    static func applyStretch(_ caught: [CaughtGrip], delta: CGVector, in tx: Transaction) {
        for grip in caught {
            let newPosition = CGPoint(x: grip.position.x + delta.dx, y: grip.position.y + delta.dy)
            moveGrip(grip.entityId, index: grip.gripIndex, to: newPosition, in: tx)
        }
    }
}
