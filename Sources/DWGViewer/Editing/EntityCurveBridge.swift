//
//  EntityCurveBridge.swift
//  DWGViewer / Editing
//
//  Phase 4.3/4.4/4.5 — bridges `EntityStore` geometry to the pure Phase-2
//  `Curve2` kernel (Geometry/Curve.swift) and back. `Geometry/CurveBridge.swift`
//  deliberately stayed minimal (CGPoint<->Vec2 conversion only) — "not wired
//  into any existing app code by this phase; that integration belongs to
//  later modification-command work" (its own doc comment). This file is that
//  later work: TRIM/EXTEND/FILLET/CHAMFER/OFFSET all need to go from "an
//  EntityID's current geometry" to one or more `Curve2`s to feed
//  `Intersect.curves`/`Offset`, then back to `EntityPayloadCopy`/
//  `EntityPrototype` to commit a result via `Transaction.replace`/
//  `modifyPayload`. Lives in `Editing/` (not `Geometry/`) since it depends on
//  `EntityStore` types, which the pure geometry kernel must not import.
//

import Foundation
import CADCore
import simd

/// One curve decomposed from an entity, tagged with enough context to turn a
/// parameter-space edit back into a payload edit:
///  - `polySegmentIndex`/`polyVertexCount` are non-nil only when `source` is a
///    polyline — TRIM/EXTEND on a polyline segment needs to know which
///    segment (for rebuilding the vertex/bulge arrays) and how many vertices
///    the whole polyline has (for closed-polyline "rotate the gap to the
///    ends" logic).
struct EntityCurve {
    let id: EntityID
    let curve: Curve2
    /// Non-nil iff this curve came from one segment of a polyline; the index
    /// into that polyline's segment list (0-based, matching
    /// `BulgePolyline.segmentCurve(_:)`'s own indexing).
    let polySegmentIndex: Int?
}

enum EntityCurveBridge {

    /// Decomposes `id`'s CURRENT geometry into zero or more `Curve2`s.
    /// LINE/CIRCLE/ARC/ELLIPSE/SPLINE each yield exactly one curve;
    /// LWPOLYLINE/POLYLINE2D yield one curve per segment (each tagged with
    /// its `polySegmentIndex`); every other entity type (INSERT, TEXT, HATCH,
    /// POLYLINE3D, unsupported/unknown) yields nothing — TRIM/EXTEND/FILLET/
    /// CHAMFER/OFFSET silently skip non-curve entities exactly like AutoCAD's
    /// own "objects that are not valid boundaries/edges are filtered out."
    static func curves(for id: EntityID, in store: EntityStore) -> [EntityCurve] {
        guard let h = store.header(id), !h.flags.contains(.deleted), h.payload >= 0 else { return [] }
        let p = Int(h.payload)
        switch h.type {
        case .line:
            let l = store.lines[p]
            return [EntityCurve(id: id, curve: .segment(LineSeg(a: Vec2(l.a.x, l.a.y), b: Vec2(l.b.x, l.b.y))), polySegmentIndex: nil)]

        case .circle:
            let c = store.circles[p]
            return [EntityCurve(id: id, curve: .circle(Circle2(center: Vec2(c.center.x, c.center.y), r: c.radius)), polySegmentIndex: nil)]

        case .arc:
            let a = store.arcs[p]
            guard let arc = circArc(fromDegreesStart: a.startAngleDeg, end: a.endAngleDeg, center: Vec2(a.center.x, a.center.y), r: a.radius) else { return [] }
            return [EntityCurve(id: id, curve: .arc(arc), polySegmentIndex: nil)]

        case .ellipse:
            let e = store.ellipses[p]
            let major = Vec2(e.majorAxisEndpoint.x, e.majorAxisEndpoint.y)
            let ea = EllipseArc(center: Vec2(e.center.x, e.center.y), majorAxis: major, ratio: e.ratio,
                                startParam: e.startParam, endParam: e.endParam)
            return [EntityCurve(id: id, curve: .ellipse(ea), polySegmentIndex: nil)]

        case .spline:
            let s = store.splines[p]
            guard let nurbs = nurbs(from: s, in: store) else { return [] }
            return [EntityCurve(id: id, curve: .spline(nurbs), polySegmentIndex: nil)]

        case .lwpolyline, .polyline2d:
            let poly = bulgePolyline(from: store.polylines[p], in: store)
            var result: [EntityCurve] = []
            for i in 0..<poly.segmentCount {
                result.append(EntityCurve(id: id, curve: poly.segmentCurve(i), polySegmentIndex: i))
            }
            return result

        default:
            // POLYLINE3D (genuinely 3D — this kernel is 2D-only), INSERT,
            // TEXT/MTEXT, HATCH, IMAGE, VIEWPORT, DIMENSION, SOLID/TRACE/
            // FACE3D, unknown: not valid TRIM/EXTEND/FILLET/CHAMFER/OFFSET
            // targets or boundaries. AutoCAD itself rejects most of these
            // ("that object cannot be trimmed/extended") — silently
            // returning [] here has the same effect at the call sites
            // (candidate is skipped, never crashes).
            return []
        }
    }

    /// Convenience: the curves for `id` restricted to whichever single
    /// segment index `wantSegment` names (nil = every segment, i.e. the same
    /// as `curves(for:in:)` for a non-polyline). Used when a caller already
    /// knows (from a prior hit test) which polyline segment the user
    /// actually clicked, so it doesn't have to re-decompose the whole
    /// polyline and re-search for the matching segment.
    static func curve(for id: EntityID, segment wantSegment: Int?, in store: EntityStore) -> EntityCurve? {
        let all = curves(for: id, in: store)
        guard let wantSegment else { return all.first }
        return all.first { $0.polySegmentIndex == wantSegment }
    }

    /// Full `BulgePolyline` for a polyline-typed entity (nil for anything
    /// else) — TRIM/EXTEND's polyline path needs the WHOLE vertex/bulge
    /// array (not just one segment's `Curve2`) to rebuild it after a partial
    /// removal or vertex fillet/chamfer.
    static func fullPolyline(for id: EntityID, in store: EntityStore) -> BulgePolyline? {
        guard let h = store.header(id), !h.flags.contains(.deleted), h.payload >= 0,
              h.type == .lwpolyline || h.type == .polyline2d else { return nil }
        return bulgePolyline(from: store.polylines[Int(h.payload)], in: store)
    }

    // MARK: - Payload construction (Curve2 -> EntityPrototype/EntityPayloadCopy)

    /// Builds a payload for a standalone (non-polyline) curve — used by
    /// TRIM/EXTEND/FILLET/CHAMFER when a piece of a LINE/ARC/CIRCLE/ELLIPSE
    /// survives as its own new entity via `Transaction.replace`. Circles that
    /// get a piece removed become arcs (DXF has no "partial circle" entity);
    /// a full-sweep arc conceptually promotes back to `.circle` for anything
    /// that re-derives geometry from it, but this kernel always represents a
    /// "circle with a bite taken out" as `.arc`, matching AutoCAD's own TRIM
    /// behavior (TRIM a circle -> you get an ARC entity, not a circle).
    /// Returns nil for curve shapes this function doesn't build a payload for
    /// (spline pieces go through `splinePayload` instead, since NURBS needs
    /// its own control/knot/weight arrays).
    static func standalonePayload(for curve: Curve2) -> EntityPayloadCopy? {
        switch curve {
        case .segment(let s):
            return .line(LinePayload(a: Vec3(x: s.a.x, y: s.a.y), b: Vec3(x: s.b.x, y: s.b.y)))
        case .arc(let a):
            guard a.r > 0, abs(a.sweep) > 1e-12 else { return nil }
            let sign: Double = a.sweep >= 0 ? 1 : -1
            let startDeg = a.startAngle * 180 / .pi
            let endDeg = (a.startAngle + a.sweep) * 180 / .pi
            // DXF ARC is always stored as a CCW sweep from start to end; a
            // negative-sweep CircArc (CW) needs its start/end swapped so the
            // stored angles still read CCW start->end.
            let (finalStart, finalEnd) = sign >= 0 ? (startDeg, endDeg) : (endDeg, startDeg)
            return .arc(ArcPayload(center: Vec3(x: a.center.x, y: a.center.y), radius: a.r,
                                   startAngleDeg: normalizeDeg(finalStart), endAngleDeg: normalizeDeg(finalEnd, allowFull: true, reference: finalStart)))
        case .circle(let c):
            return .circle(CirclePayload(center: Vec3(x: c.center.x, y: c.center.y), radius: c.r))
        case .ellipse(let e):
            return .ellipse(EllipsePayload(center: Vec3(x: e.center.x, y: e.center.y),
                                           majorAxisEndpoint: Vec3(x: e.majorAxis.x, y: e.majorAxis.y),
                                           ratio: e.ratio, startParam: e.startParam, endParam: e.endParam))
        case .spline:
            return nil // use splinePayload(for:) — needs the full NURBS, not just endpoints
        }
    }

    /// Builds a spline payload from a `NURBS` (control points, knots,
    /// weights — non-rational splines store an EMPTY weights array, matching
    /// `EntityStoreParser`'s own convention, not an all-1.0 array, so a
    /// round-tripped un-weighted spline looks identical to a freshly parsed
    /// one).
    static func splinePayload(for nurbs: NURBS) -> EntityPayloadCopy {
        let isRational = nurbs.weights.contains { abs($0 - 1.0) > 1e-9 }
        let control = nurbs.control.map { Vec3(x: $0.x, y: $0.y) }
        return .spline(SplinePayload(degree: Int32(nurbs.degree), closed: nurbs.isClosedLoop),
                       control: control, knots: nurbs.knots, weights: isRational ? nurbs.weights : [])
    }

    /// Builds a polyline payload from a `BulgePolyline`.
    static func polylinePayload(for poly: BulgePolyline, elevation: Double = 0, constantWidth: Double = 0) -> EntityPayloadCopy {
        let verts = poly.vertices.map { Vec3(x: $0.x, y: $0.y, z: elevation) }
        return .polyline(PolylinePayload(closed: poly.closed, constantWidth: constantWidth, elevation: elevation, is3D: false),
                         vertices: verts, bulges: poly.bulges)
    }

    // MARK: - Internal conversions

    /// Converts DXF's start/end-angle-in-degrees ARC convention (always CCW
    /// from start to end) to a `CircArc` (`sweep` positive = CCW). A
    /// degenerate arc (r <= 0, or start==end after normalization, which DXF
    /// never actually produces for a real ARC but a corrupt/edited one
    /// theoretically could) returns nil rather than a zero-sweep arc that
    /// would silently vanish in every downstream curve/intersect routine.
    static func circArc(fromDegreesStart startDeg: Double, end endDeg: Double, center: Vec2, r: Double) -> CircArc? {
        guard r > 0 else { return nil }
        let startRad = startDeg * .pi / 180
        var sweep = (endDeg - startDeg) * .pi / 180
        sweep = sweep.truncatingRemainder(dividingBy: 2 * .pi)
        if sweep <= 1e-12 { sweep += 2 * .pi }   // 0 or negative raw delta => full-circle-minus-epsilon sweep, matches DXF's CCW convention
        return CircArc(center: center, r: r, startAngle: startRad, sweep: sweep)
    }

    /// Normalizes an angle in degrees to [0, 360). `allowFull`/`reference`
    /// let the END angle stay numerically ordered relative to a just-computed
    /// START angle when the true sweep is a hair under a full circle (e.g.
    /// 359.9999 degrees) — without this, naive `mod 360` could snap the end
    /// angle back down near the start angle and silently collapse the arc's
    /// visible sweep to ~0. Ordinary (non-full-sweep) cases are unaffected:
    /// `reference` only matters when the raw end, after normalization, would
    /// otherwise land at or before `reference`.
    private static func normalizeDeg(_ deg: Double, allowFull: Bool = false, reference: Double = 0) -> Double {
        var v = deg.truncatingRemainder(dividingBy: 360)
        if v < 0 { v += 360 }
        if allowFull, v <= reference { v += 360 }
        return v
    }

    private static func nurbs(from s: SplinePayload, in store: EntityStore) -> NURBS? {
        guard s.controlCount > 0 else { return nil }
        let control = (0..<Int(s.controlCount)).map { i -> Vec2 in
            let v = store.vertexArena[Int(s.controlStart) + i]
            return Vec2(v.x, v.y)
        }
        let knots = s.knotCount > 0
            ? Array(store.scalarArena[Int(s.knotStart)..<Int(s.knotStart + s.knotCount)])
            : defaultClampedKnots(degree: Int(s.degree), controlCount: control.count)
        let weights = s.weightCount > 0
            ? Array(store.scalarArena[Int(s.weightStart)..<Int(s.weightStart + s.weightCount)])
            : [Double](repeating: 1.0, count: control.count)
        let n = NURBS(degree: Int(s.degree), control: control, weights: weights, knots: knots)
        return n.isValid ? n : nil
    }

    /// Synthesizes a standard clamped-uniform knot vector when a spline
    /// payload's own knot array is empty/malformed — defensive fallback so a
    /// hand-authored or degenerate SPLINE doesn't just vanish from every
    /// TRIM/EXTEND/OFFSET candidate list; matches the shape
    /// `SplineFit`'s own fallback paths already produce.
    private static func defaultClampedKnots(degree: Int, controlCount: Int) -> [Double] {
        let n = controlCount - 1
        let p = max(1, degree)
        guard n >= p else { return [] }
        var knots = [Double](repeating: 0, count: n + p + 2)
        for i in 0...p { knots[i] = 0 }
        for i in 0...p { knots[knots.count - 1 - i] = 1 }
        if n > p {
            for j in 1...(n - p) {
                knots[j + p] = Double(j) / Double(n - p + 1)
            }
        }
        return knots
    }

    private static func bulgePolyline(from p: PolylinePayload, in store: EntityStore) -> BulgePolyline {
        let verts = (0..<Int(p.vertsCount)).map { i -> Vec2 in
            let v = store.vertexArena[Int(p.vertsStart) + i]
            return Vec2(v.x, v.y)
        }
        let bulges = (0..<Int(p.vertsCount)).map { store.scalarArena[Int(p.bulgesStart) + $0] }
        return BulgePolyline(vertices: verts, bulges: bulges, closed: p.closed)
    }
}
