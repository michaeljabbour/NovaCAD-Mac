//
//  OffsetExecutor.swift
//  DWGViewer / Editing
//
//  Phase 4.5 — the OFFSET command: distance (persisted OFFSETDIST) or
//  through-point mode, side determined by which side of the curve the user
//  clicked, dispatches to the Phase 2 `Offset` kernel per entity type, and
//  adds the result(s) as new entities (OFFSET never modifies the source —
//  it always creates a parallel copy, matching AutoCAD). Comparatively
//  thin relative to TRIM/EXTEND/FILLET/CHAMFER: almost all the actual
//  geometry work already exists in `Offset.swift`; this file is mostly
//  "which entity type is this, which `Offset` function do I call, how do I
//  turn the result back into an `EntityPrototype`."
//

import Foundation
import CADCore
import CoreGraphics
import simd

enum OffsetExecutor {

    /// Resolves one OFFSET operation for `id`, offsetting by `distance`
    /// (always positive — the SIDE, not the sign of `distance`, encodes
    /// direction) toward whichever side `sidePoint` is on. Returns the new
    /// entity prototype(s) to add (a polyline offset can legitimately
    /// produce more than one resulting loop/chain if self-intersection
    /// trimming splits it, or ZERO if the offset collapses entirely, e.g.
    /// offsetting a circle inward by more than its own radius) — never
    /// modifies the source entity. Returns nil for entity types OFFSET
    /// doesn't support (text, hatch, insert, etc. — matching AutoCAD's own
    /// "that object cannot be offset").
    static func resolve(id: EntityID, distance: Double, sidePoint: CGPoint, store: EntityStore, tol: Tolerance) -> [EntityPrototype]? {
        guard distance > 0 else { return nil }
        guard let h = store.header(id), !h.flags.contains(.deleted), h.payload >= 0 else { return nil }
        let p = Vec2(sidePoint)

        switch h.type {
        case .line:
            let l = store.lines[Int(h.payload)]
            let seg = LineSeg(a: Vec2(l.a.x, l.a.y), b: Vec2(l.b.x, l.b.y))
            let side = sideOfLine(seg, point: p)
            let offset = Offset.segment(seg, distance, side)
            return [protoFrom(.segment(offset), layerId: h.layerId)]

        case .arc:
            let a = store.arcs[Int(h.payload)]
            guard let arc = EntityCurveBridge.circArc(fromDegreesStart: a.startAngleDeg, end: a.endAngleDeg, center: Vec2(a.center.x, a.center.y), r: a.radius) else { return nil }
            let side = sideOfArc(arc, point: p)
            guard let offsetArc = Offset.arc(arc, distance, side) else { return [] }   // inward offset collapsed the arc — legitimately zero results
            return [protoFrom(.arc(offsetArc), layerId: h.layerId)]

        case .circle:
            let c = store.circles[Int(h.payload)]
            let circle = Circle2(center: Vec2(c.center.x, c.center.y), r: c.radius)
            let outward = simd_length(p - circle.center) >= circle.r
            guard let offsetCircle = Offset.circle(circle, distance, outward: outward) else { return [] }
            return [protoFrom(.circle(offsetCircle), layerId: h.layerId)]

        case .ellipse:
            let e = store.ellipses[Int(h.payload)]
            let major = Vec2(e.majorAxisEndpoint.x, e.majorAxisEndpoint.y)
            let ellipse = EllipseArc(center: Vec2(e.center.x, e.center.y), majorAxis: major, ratio: e.ratio, startParam: e.startParam, endParam: e.endParam)
            let side = sideOfCurve(.ellipse(ellipse), point: p, tol: tol)
            let poly = Offset.ellipse(ellipse, distance, side, tol: tol)
            return [EntityCurveBridge.polylinePayload(for: poly)].map { EntityPrototype(type: .lwpolyline, layerId: h.layerId, payload: $0) }

        case .spline:
            let s = store.splines[Int(h.payload)]
            guard let nurbs = splineFrom(s, in: store) else { return nil }
            let side = sideOfCurve(.spline(nurbs), point: p, tol: tol)
            let offsetSpline = Offset.spline(nurbs, distance, side, tol: tol)
            guard offsetSpline.isValid else { return [] }
            return [EntityPrototype(type: .spline, layerId: h.layerId, payload: EntityCurveBridge.splinePayload(for: offsetSpline))]

        case .lwpolyline, .polyline2d:
            guard let poly = EntityCurveBridge.fullPolyline(for: id, in: store) else { return nil }
            let side = sideOfPolyline(poly, point: p)
            let results = Offset.polyline(poly, distance: distance, side: side, tol: tol)
            return results.map { EntityCurveBridge.polylinePayload(for: $0) }.map { EntityPrototype(type: .lwpolyline, layerId: h.layerId, payload: $0) }

        default:
            return nil   // OFFSET doesn't support this entity type
        }
    }

    /// Through-point mode: the offset distance is DERIVED as the closest
    /// distance from `throughPoint` to the object's own curve (for a
    /// polyline, the closest distance to any of its segments), and the
    /// side is naturally implied by `throughPoint` itself (it's both the
    /// distance source AND the side indicator, matching AutoCAD's "OFFSET,
    /// T, click object, click through point" gesture — one click serves
    /// both roles instead of two).
    static func resolveThroughPoint(id: EntityID, throughPoint: CGPoint, store: EntityStore, tol: Tolerance) -> [EntityPrototype]? {
        guard let curves = distanceMeasurementCurves(id: id, store: store), !curves.isEmpty else { return nil }
        let p = Vec2(throughPoint)
        var minDist = Double.infinity
        for curve in curves {
            let (_, _, dist) = curve.closestPoint(to: p, tol: tol)
            minDist = min(minDist, dist)
        }
        guard minDist.isFinite, minDist > tol.linear else { return nil }   // through-point exactly ON the curve — zero-distance offset is meaningless
        return resolve(id: id, distance: minDist, sidePoint: throughPoint, store: store, tol: tol)
    }

    /// Every curve piece of `id`'s geometry (one per polyline segment, or
    /// the single curve for any other type) — used ONLY to measure the
    /// through-point distance; `resolve(id:distance:sidePoint:...)` still
    /// does the real per-type dispatch afterward.
    private static func distanceMeasurementCurves(id: EntityID, store: EntityStore) -> [Curve2]? {
        let ecs = EntityCurveBridge.curves(for: id, in: store)
        guard !ecs.isEmpty else { return nil }
        return ecs.map { $0.curve }
    }

    // MARK: - Side determination

    /// Which side of a line `point` is on: `.left` is the CCW-perpendicular
    /// side of a->b (matching `Offset.segment`'s own convention).
    private static func sideOfLine(_ line: LineSeg, point: Vec2) -> OffsetSide {
        let d = line.b - line.a
        let cross = d.x * (point.y - line.a.y) - d.y * (point.x - line.a.x)
        return cross >= 0 ? .left : .right
    }

    /// Which side of an arc `point` is on: outside (farther from center
    /// than the arc's own radius) maps to whichever `OffsetSide` GROWS the
    /// radius for this arc's own sweep sign (matching `Offset.arc`'s
    /// documented "left = outward for CCW, inward for CW" convention).
    private static func sideOfArc(_ arc: CircArc, point: Vec2) -> OffsetSide {
        let outward = simd_length(point - arc.center) >= arc.r
        let sweepSign: Double = arc.sweep >= 0 ? 1 : -1
        // Offset.arc: newR = r + sign*sweepSign*d, where sign is +1 for
        // .left. Outward (newR > r) requires sign*sweepSign > 0, i.e.
        // sign = sweepSign (as a +-1 value) -> .left when sweepSign > 0,
        // .right when sweepSign < 0. Inward is the opposite.
        if outward {
            return sweepSign > 0 ? .left : .right
        } else {
            return sweepSign > 0 ? .right : .left
        }
    }

    /// Generic side-of-curve test via closest-point tangent/normal — used
    /// for ellipse/spline, where there's no simpler closed-form side test.
    private static func sideOfCurve(_ curve: Curve2, point: Vec2, tol: Tolerance) -> OffsetSide {
        let (u, closest, _) = curve.closestPoint(to: point, tol: tol)
        let tangent = curve.tangent(u)
        let toPoint = point - closest
        let cross = tangent.x * toPoint.y - tangent.y * toPoint.x
        return cross >= 0 ? .left : .right
    }

    /// Side-of-polyline test: nearest segment's own side test wins (a
    /// reasonable, simple approximation — the click point is always near
    /// ONE particular segment/arc of the polyline in practice, and that
    /// segment's local left/right is what the user actually means).
    private static func sideOfPolyline(_ poly: BulgePolyline, point: Vec2) -> OffsetSide {
        let localTol = Tolerance(linear: 1e-9)
        var best: (side: OffsetSide, dist: Double)? = nil
        for i in 0..<poly.segmentCount {
            let seg = poly.segmentCurve(i)
            let (u, closest, dist) = seg.closestPoint(to: point, tol: localTol)
            guard best == nil || dist < best!.dist else { continue }
            let tangent = seg.tangent(u)
            let toPoint = point - closest
            let cross = tangent.x * toPoint.y - tangent.y * toPoint.x
            best = (cross >= 0 ? .left : .right, dist)
        }
        return best?.side ?? .left
    }

    // MARK: - Helpers

    private static func protoFrom(_ curve: Curve2, layerId: Int32) -> EntityPrototype {
        let payload = EntityCurveBridge.standalonePayload(for: curve) ?? .unknown
        return EntityPrototype(type: connectorType(curve), layerId: layerId, payload: payload)
    }

    private static func connectorType(_ curve: Curve2) -> DXFEntityType {
        switch curve {
        case .segment: return .line
        case .arc: return .arc
        case .circle: return .circle
        case .ellipse: return .ellipse
        case .spline: return .spline
        }
    }

    private static func splineFrom(_ s: SplinePayload, in store: EntityStore) -> NURBS? {
        guard s.controlCount > 0 else { return nil }
        let control = (0..<Int(s.controlCount)).map { i -> Vec2 in
            let v = store.vertexArena[Int(s.controlStart) + i]
            return Vec2(v.x, v.y)
        }
        let knots = Array(store.scalarArena[Int(s.knotStart)..<Int(s.knotStart + s.knotCount)])
        let weights = s.weightCount > 0
            ? Array(store.scalarArena[Int(s.weightStart)..<Int(s.weightStart + s.weightCount)])
            : [Double](repeating: 1.0, count: control.count)
        let n = NURBS(degree: Int(s.degree), control: control, weights: weights, knots: knots)
        return n.isValid ? n : nil
    }
}

import simd
