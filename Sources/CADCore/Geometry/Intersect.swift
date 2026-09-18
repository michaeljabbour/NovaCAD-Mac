//
//  Intersect.swift
//  DWGViewer / Geometry
//
//  Phase 2 geometry kernel — pure Swift (Foundation + simd only).
//  Curve/curve intersection dispatch, canonicalized by unordered case pair
//  so each geometric combination is implemented exactly once.
//

import Foundation
import simd

/// A single intersection between two curves.
public struct CurveHit {
    public var u1: Double
    public var u2: Double
    public var point: Vec2
    /// True if `u1`/`u2` lies within that curve's OWN (un-extended)
    /// paramDomain, regardless of whether extension was requested.
    public var within1: Bool
    public var within2: Bool

    public init(u1: Double, u2: Double, point: Vec2, within1: Bool, within2: Bool) {
        self.u1 = u1
        self.u2 = u2
        self.point = point
        self.within1 = within1
        self.within2 = within2
    }
}

public enum Intersect {

    /// Maximum recursion depth for bbox-pruned numeric subdivision
    /// (ellipse/spline generic solver). Bounds worst-case cost on
    /// pathological inputs; 40 levels of bisection is already far beyond
    /// double-precision's useful resolution over any realistic drawing
    /// extent.
    private static let maxSubdivisionDepth = 40

    /// Stop subdividing once both sub-curve bboxes are smaller than this
    /// multiple of the linear tolerance — small enough that a single
    /// Newton pass from the bracket reliably converges.
    private static let subdivisionBBoxFactor = 8.0

    /// Cap on 2D Newton iterations for the generic numeric solver.
    private static let genericNewtonMaxIter = 24

    /// Finds all intersections between two curves.
    public static func curves(_ a: Curve2, _ b: Curve2, tol: Tolerance,
                       extendA: Bool = false, extendB: Bool = false) -> [CurveHit] {
        let effA = extendA && a.canExtend
        let effB = extendB && b.canExtend

        switch (a, b) {
        case (.segment(let s1), .segment(let s2)):
            return lineLine(s1, s2, tol: tol, extendA: effA, extendB: effB)

        case (.segment(let s), .circle(let c)):
            return lineCircleLike(s, center: c.center, r: c.r, otherDomain: b.paramDomain,
                                  isArc: false, arc: nil, tol: tol, extendA: effA, extendB: effB, swapped: false)
        case (.circle(let c), .segment(let s)):
            return lineCircleLike(s, center: c.center, r: c.r, otherDomain: a.paramDomain,
                                  isArc: false, arc: nil, tol: tol, extendA: effB, extendB: effA, swapped: true)

        case (.segment(let s), .arc(let arc)):
            return lineCircleLike(s, center: arc.center, r: arc.r, otherDomain: b.paramDomain,
                                  isArc: true, arc: arc, tol: tol, extendA: effA, extendB: effB, swapped: false)
        case (.arc(let arc), .segment(let s)):
            return lineCircleLike(s, center: arc.center, r: arc.r, otherDomain: a.paramDomain,
                                  isArc: true, arc: arc, tol: tol, extendA: effB, extendB: effA, swapped: true)

        case (.circle(let c1), .circle(let c2)):
            return circleCircle(c1: c1.center, r1: c1.r, c2: c2.center, r2: c2.r,
                                domain1: a.paramDomain, domain2: b.paramDomain,
                                arc1: nil, arc2: nil, tol: tol, extendA: effA, extendB: effB)
        case (.circle(let c1), .arc(let arc2)):
            return circleCircle(c1: c1.center, r1: c1.r, c2: arc2.center, r2: arc2.r,
                                domain1: a.paramDomain, domain2: b.paramDomain,
                                arc1: nil, arc2: arc2, tol: tol, extendA: effA, extendB: effB)
        case (.arc(let arc1), .circle(let c2)):
            return circleCircle(c1: arc1.center, r1: arc1.r, c2: c2.center, r2: c2.r,
                                domain1: a.paramDomain, domain2: b.paramDomain,
                                arc1: arc1, arc2: nil, tol: tol, extendA: effA, extendB: effB)
        case (.arc(let arc1), .arc(let arc2)):
            return circleCircle(c1: arc1.center, r1: arc1.r, c2: arc2.center, r2: arc2.r,
                                domain1: a.paramDomain, domain2: b.paramDomain,
                                arc1: arc1, arc2: arc2, tol: tol, extendA: effA, extendB: effB)

        case (.segment(let s), .ellipse(let e)):
            return lineEllipse(s, e, tol: tol, extendA: effA, extendB: effB, swapped: false)
        case (.ellipse(let e), .segment(let s)):
            return lineEllipse(s, e, tol: tol, extendA: effB, extendB: effA, swapped: true)

        case (.circle(let c), .ellipse(let e)):
            return circleEllipse(center: c.center, r: c.r, circleDomain: a.paramDomain, arc: nil,
                                 e, tol: tol, extendA: effA, extendB: effB, swapped: false)
        case (.ellipse(let e), .circle(let c)):
            return circleEllipse(center: c.center, r: c.r, circleDomain: b.paramDomain, arc: nil,
                                 e, tol: tol, extendA: effB, extendB: effA, swapped: true)
        case (.arc(let arc), .ellipse(let e)):
            return circleEllipse(center: arc.center, r: arc.r, circleDomain: a.paramDomain, arc: arc,
                                 e, tol: tol, extendA: effA, extendB: effB, swapped: false)
        case (.ellipse(let e), .arc(let arc)):
            return circleEllipse(center: arc.center, r: arc.r, circleDomain: b.paramDomain, arc: arc,
                                 e, tol: tol, extendA: effB, extendB: effA, swapped: true)

        // Ellipse/ellipse and anything-with-spline: generic numeric solver.
        default:
            return generic(a, b, tol: tol, extendA: effA, extendB: effB)
        }
    }

    /// Intersects a `BulgePolyline` (per-segment) against another curve.
    public static func polylineHits(_ p: BulgePolyline, with other: Curve2, tol: Tolerance) -> [(segIndex: Int, localU: Double, otherU: Double, point: Vec2)] {
        var results: [(segIndex: Int, localU: Double, otherU: Double, point: Vec2)] = []
        for i in 0..<p.segmentCount {
            let seg = p.segmentCurve(i)
            let hits = curves(seg, other, tol: tol, extendA: false, extendB: false)
            for h in hits where h.within1 && h.within2 {
                results.append((segIndex: i, localU: h.u1, otherU: h.u2, point: h.point))
            }
        }
        return results
    }

    // MARK: - Domain containment helper

    private static func inOwnDomain(_ u: Double, _ domain: ClosedRange<Double>, tol: Tolerance) -> Bool {
        u >= domain.lowerBound - tol.parametric && u <= domain.upperBound + tol.parametric
    }

    // MARK: - Line / Line

    private static func lineLine(_ s1: LineSeg, _ s2: LineSeg, tol: Tolerance, extendA: Bool, extendB: Bool) -> [CurveHit] {
        let d1 = s1.b - s1.a
        let d2 = s2.b - s2.a
        let denom = d1.x * d2.y - d1.y * d2.x
        let len1 = simd_length(d1), len2 = simd_length(d2)
        guard len1 > 0, len2 > 0 else { return [] }

        // Parallel test via cross product normalized by the segment lengths
        // (so it behaves like a sine of the angle between them), compared
        // against the angular tolerance.
        let sinAngle = abs(denom) / (len1 * len2)
        let isParallel = sinAngle < tol.angular

        if !isParallel {
            let dx = s2.a - s1.a
            let t = (dx.x * d2.y - dx.y * d2.x) / denom
            let u = (dx.x * d1.y - dx.y * d1.x) / denom
            let domain1 = (0.0)...1.0
            let domain2 = (0.0)...1.0
            let within1 = inOwnDomain(t, domain1, tol: tol)
            let within2 = inOwnDomain(u, domain2, tol: tol)
            guard (within1 || extendA), (within2 || extendB) else { return [] }
            let point = s1.a + d1 * t
            return [CurveHit(u1: t, u2: u, point: point, within1: within1, within2: within2)]
        }

        // Parallel: check collinearity via the cross product of (b-a) and (p-a).
        let cross = d1.x * (s2.a.y - s1.a.y) - d1.y * (s2.a.x - s1.a.x)
        let collinearThreshold = tol.linear * len1
        guard abs(cross) < max(collinearThreshold, 1e-300) else { return [] }

        // Collinear: project s2's endpoints onto s1's parametrization and
        // check for overlap; emit endpoint-projected hits for the later
        // TRIM/EXTEND phase's collinear-overlap handling.
        let len1sq = len1 * len1
        let t0 = simd_dot(s2.a - s1.a, d1) / len1sq
        let t1 = simd_dot(s2.b - s1.a, d1) / len1sq
        let tLo = min(t0, t1), tHi = max(t0, t1)
        let domainLo = 0.0, domainHi = 1.0
        let overlapLo = max(tLo, extendA ? -Double.infinity : domainLo)
        let overlapHi = min(tHi, extendA ? Double.infinity : domainHi)
        guard overlapHi >= overlapLo - tol.linear / max(len1, 1e-300) else { return [] }

        var hits: [CurveHit] = []
        for t in [overlapLo, overlapHi] {
            let point = s1.a + d1 * t
            // Map back to s2's parametrization.
            let len2sq = len2 * len2
            let u = simd_dot(point - s2.a, d2) / len2sq
            let within1 = inOwnDomain(t, domainLo...domainHi, tol: tol)
            let within2 = inOwnDomain(u, 0.0...1.0, tol: tol)
            guard (within1 || extendA), (within2 || extendB) else { continue }
            hits.append(CurveHit(u1: t, u2: u, point: point, within1: within1, within2: within2))
        }
        // Dedup (overlapLo == overlapHi for a single touch point).
        if hits.count == 2 && simd_length(hits[0].point - hits[1].point) < tol.linear {
            hits.removeLast()
        }
        return hits
    }

    // MARK: - Line / Circle or Line / Arc

    private static func lineCircleLike(_ s: LineSeg, center: Vec2, r: Double, otherDomain: ClosedRange<Double>,
                                       isArc: Bool, arc: CircArc?, tol: Tolerance,
                                       extendA: Bool, extendB: Bool, swapped: Bool) -> [CurveHit] {
        let d = s.b - s.a
        let len2 = simd_length_squared(d)
        guard len2 > 0, r > 0 else { return [] }
        let f = s.a - center
        // |s.a + t*d - center|^2 = r^2  =>  quadratic in t.
        let A = len2
        let B = 2 * simd_dot(f, d)
        let C = simd_length_squared(f) - r * r
        var disc = B * B - 4 * A * C
        // Clamp near-zero discriminants to exactly zero within tolerance so
        // tangency reports a single hit instead of two near-duplicates or none.
        let discTolerance = 4 * A * A * (tol.linear * tol.linear) * 4
        if abs(disc) < discTolerance { disc = 0 }
        guard disc >= 0 else { return [] }

        let sqrtDisc = sqrt(disc)
        var ts: [Double] = disc == 0 ? [-B / (2 * A)] : [(-B - sqrtDisc) / (2 * A), (-B + sqrtDisc) / (2 * A)]
        ts.sort()

        var hits: [CurveHit] = []
        for t in ts {
            let within1 = inOwnDomain(t, 0.0...1.0, tol: tol)
            guard within1 || extendA else { continue }
            let point = s.a + d * t
            let angle = atan2(point.y - center.y, point.x - center.x)
            let (u2, within2) = mapAngleToOtherDomain(angle: angle, isArc: isArc, arc: arc, otherDomain: otherDomain, tol: tol)
            guard within2 || extendB else { continue }
            let hit = swapped
                ? CurveHit(u1: u2, u2: t, point: point, within1: within2, within2: within1)
                : CurveHit(u1: t, u2: u2, point: point, within1: within1, within2: within2)
            hits.append(hit)
        }
        return dedupHits(hits, tol: tol)
    }

    /// Maps a world-space angle to the other curve's own parameter (arc's
    /// swept parameter, or the raw angle for a circle), plus whether that
    /// angle lies within the un-extended sweep.
    private static func mapAngleToOtherDomain(angle: Double, isArc: Bool, arc: CircArc?, otherDomain: ClosedRange<Double>, tol: Tolerance) -> (Double, Bool) {
        guard isArc, let arc = arc else {
            // Circle: parameter is the normalized angle in [0, 2*pi).
            var a = angle.truncatingRemainder(dividingBy: 2 * .pi)
            if a < 0 { a += 2 * .pi }
            return (a, true) // circle is periodic; always "within".
        }
        let sign: Double = arc.sweep >= 0 ? 1 : -1
        var delta = (angle - arc.startAngle) * sign
        delta = delta.truncatingRemainder(dividingBy: 2 * .pi)
        if delta < 0 { delta += 2 * .pi }
        let within = delta <= abs(arc.sweep) + tol.parametric
        return (delta, within)
    }

    // MARK: - Circle / Circle or Arc / Arc

    private static func circleCircle(c1: Vec2, r1: Double, c2: Vec2, r2: Double,
                                     domain1: ClosedRange<Double>, domain2: ClosedRange<Double>,
                                     arc1: CircArc?, arc2: CircArc?, tol: Tolerance,
                                     extendA: Bool, extendB: Bool) -> [CurveHit] {
        guard r1 > 0, r2 > 0 else { return [] }
        let dvec = c2 - c1
        let d = simd_length(dvec)
        guard d > 1e-300 else { return [] } // concentric: no well-defined finite intersection set

        // Tangent cases (external / internal) collapse to a single point.
        let isExternalTangent = abs(d - (r1 + r2)) < tol.linear
        let isInternalTangent = abs(d - abs(r1 - r2)) < tol.linear
        if isExternalTangent || isInternalTangent {
            let dirUnit = dvec / d
            // External tangency: the tangent point is always straight out
            // from c1 towards c2, at distance r1 (both circles bulge away
            // from each other). Internal tangency: one circle sits inside
            // the other, so the tangent point is on the far side of the
            // SMALLER circle from the larger one's center — i.e. behind c1
            // (negative dirUnit) when c1 is the smaller circle (r1 <= r2),
            // or ahead of c1 (positive dirUnit) when c1 is the larger one.
            let sign: Double = isExternalTangent ? 1 : (r1 <= r2 ? -1 : 1)
            let point = c1 + dirUnit * (r1 * sign)
            return emitCircleHits([point], c1: c1, c2: c2, arc1: arc1, arc2: arc2,
                                  domain1: domain1, domain2: domain2, tol: tol, extendA: extendA, extendB: extendB)
        }

        guard d < r1 + r2, d > abs(r1 - r2) else { return [] }

        // Radical-line construction.
        let a = (d * d - r2 * r2 + r1 * r1) / (2 * d)
        let hSq = r1 * r1 - a * a
        guard hSq >= 0 else { return [] }
        let h = sqrt(hSq)
        let dirUnit = dvec / d
        let mid = c1 + dirUnit * a
        let perp = Vec2(-dirUnit.y, dirUnit.x)
        let p1 = mid + perp * h
        let p2 = mid - perp * h
        return emitCircleHits(h > 1e-12 ? [p1, p2] : [p1], c1: c1, c2: c2, arc1: arc1, arc2: arc2,
                              domain1: domain1, domain2: domain2, tol: tol, extendA: extendA, extendB: extendB)
    }

    private static func emitCircleHits(_ points: [Vec2], c1: Vec2, c2: Vec2, arc1: CircArc?, arc2: CircArc?,
                                       domain1: ClosedRange<Double>, domain2: ClosedRange<Double>,
                                       tol: Tolerance, extendA: Bool, extendB: Bool) -> [CurveHit] {
        var hits: [CurveHit] = []
        for point in points {
            let angle1 = atan2(point.y - c1.y, point.x - c1.x)
            let angle2 = atan2(point.y - c2.y, point.x - c2.x)
            let (u1, within1) = mapAngleToOtherDomain(angle: angle1, isArc: arc1 != nil, arc: arc1, otherDomain: domain1, tol: tol)
            let (u2, within2) = mapAngleToOtherDomain(angle: angle2, isArc: arc2 != nil, arc: arc2, otherDomain: domain2, tol: tol)
            guard (within1 || extendA), (within2 || extendB) else { continue }
            hits.append(CurveHit(u1: u1, u2: u2, point: point, within1: within1, within2: within2))
        }
        return hits
    }

    // MARK: - Line / Ellipse

    /// Transforms `p` into the ellipse's local unit-circle frame: rotate by
    /// -axisAngle, scale y by 1/ratio, translate by -center (applied in the
    /// order that maps the ellipse to the unit circle centered at origin).
    private static func toEllipseUnitFrame(_ p: Vec2, _ e: EllipseArc) -> Vec2 {
        let majorLen = simd_length(e.majorAxis)
        guard majorLen > 0 else { return .zero }
        let axisAngle = atan2(e.majorAxis.y, e.majorAxis.x)
        let rel = p - e.center
        let cosA = cos(-axisAngle), sinA = sin(-axisAngle)
        let rotated = Vec2(rel.x * cosA - rel.y * sinA, rel.x * sinA + rel.y * cosA)
        let scaled = Vec2(rotated.x / majorLen, rotated.y / (majorLen * e.ratio))
        return scaled
    }

    private static func fromEllipseUnitFrame(_ p: Vec2, _ e: EllipseArc) -> Vec2 {
        let majorLen = simd_length(e.majorAxis)
        let axisAngle = atan2(e.majorAxis.y, e.majorAxis.x)
        let unscaled = Vec2(p.x * majorLen, p.y * majorLen * e.ratio)
        let cosA = cos(axisAngle), sinA = sin(axisAngle)
        let rotated = Vec2(unscaled.x * cosA - unscaled.y * sinA, unscaled.x * sinA + unscaled.y * cosA)
        return rotated + e.center
    }

    /// Ellipse parametric angle at a point already known to lie on the
    /// ellipse: the unit-frame point is (cos t, sin t) directly.
    private static func ellipseParamOf(unitFramePoint: Vec2) -> Double {
        atan2(unitFramePoint.y, unitFramePoint.x)
    }

    private static func mapAngleToEllipseDomain(_ t: Double, _ e: EllipseArc, tol: Tolerance) -> (Double, Bool) {
        var delta = t - e.startParam
        let span = e.endParam - e.startParam
        delta = delta.truncatingRemainder(dividingBy: 2 * .pi)
        if delta < 0 { delta += 2 * .pi }
        let within = delta <= span + tol.parametric
        return (e.startParam + delta, within)
    }

    private static func lineEllipse(_ s: LineSeg, _ e: EllipseArc, tol: Tolerance, extendA: Bool, extendB: Bool, swapped: Bool) -> [CurveHit] {
        // Transform the segment endpoints into the ellipse's unit-circle
        // frame, solve as line/unit-circle, map roots back.
        let a0 = toEllipseUnitFrame(s.a, e)
        let b0 = toEllipseUnitFrame(s.b, e)
        let d = b0 - a0
        let len2 = simd_length_squared(d)
        guard len2 > 0 else { return [] }
        let A = len2
        let B = 2 * simd_dot(a0, d)
        let C = simd_length_squared(a0) - 1
        var disc = B * B - 4 * A * C
        // Tolerance in the unit frame is approximate; scale by ellipse size
        // roughly via majorAxis length so tangency detection stays sane.
        let majorLen = max(simd_length(e.majorAxis), 1e-300)
        let discTolerance = 4 * A * A * pow(tol.linear / majorLen, 2) * 4
        if abs(disc) < discTolerance { disc = 0 }
        guard disc >= 0 else { return [] }
        let sqrtDisc = sqrt(disc)
        var ts: [Double] = disc == 0 ? [-B / (2 * A)] : [(-B - sqrtDisc) / (2 * A), (-B + sqrtDisc) / (2 * A)]
        ts.sort()

        var hits: [CurveHit] = []
        for t in ts {
            let within1 = inOwnDomain(t, 0.0...1.0, tol: tol)
            guard within1 || extendA else { continue }
            let unitPoint = a0 + d * t
            let worldPoint = fromEllipseUnitFrame(unitPoint, e)
            let rawAngle = ellipseParamOf(unitFramePoint: unitPoint)
            let (u2, within2) = mapAngleToEllipseDomain(rawAngle, e, tol: tol)
            guard within2 || extendB else { continue }
            let hit = swapped
                ? CurveHit(u1: u2, u2: t, point: worldPoint, within1: within2, within2: within1)
                : CurveHit(u1: t, u2: u2, point: worldPoint, within1: within1, within2: within2)
            hits.append(hit)
        }
        return dedupHits(hits, tol: tol)
    }

    // MARK: - Circle / Ellipse (or Arc / Ellipse)

    private static func circleEllipse(center: Vec2, r: Double, circleDomain: ClosedRange<Double>, arc: CircArc?,
                                      _ e: EllipseArc, tol: Tolerance, extendA: Bool, extendB: Bool, swapped: Bool) -> [CurveHit] {
        // Transform the circle into the ellipse's unit-circle frame: this
        // turns into circle/circle in general (an ellipse's unit frame is
        // an anisotropic scale, so a circle maps to another ellipse) unless
        // we instead solve directly. To keep this exact and simple, solve
        // circle/unit-circle by transforming the *circle's center* into the
        // ellipse frame and noting the "circle" becomes an ellipse there
        // too UNLESS we transform differently: instead, sample+Newton via
        // the generic solver for correctness, since an anisotropic scale
        // does not preserve circularity of the first circle.
        //
        // This is simpler and still exact: fall back to the generic
        // bbox-pruned + Newton solver used for ellipse/ellipse and
        // anything-with-spline, which is fully general.
        let circleCurve: Curve2 = arc != nil ? .arc(arc!) : .circle(Circle2(center: center, r: r))
        let ellipseCurve = Curve2.ellipse(e)
        let hits = generic(circleCurve, ellipseCurve, tol: tol, extendA: extendA, extendB: extendB)
        guard swapped else { return hits }
        return hits.map { CurveHit(u1: $0.u2, u2: $0.u1, point: $0.point, within1: $0.within2, within2: $0.within1) }
    }

    // MARK: - Generic numeric solver (ellipse/ellipse, anything-with-spline)

    /// Generic bbox-pruned recursive-subdivision + 2D-Newton solver.
    /// Splines/polylines are never extended (canExtend is false for
    /// splines); the extendA/extendB flags are effectively ignored — a
    /// no-op — whenever the curve on that side is a spline, since there is
    /// no wider domain to extend into.
    private static func generic(_ a: Curve2, _ b: Curve2, tol: Tolerance, extendA: Bool, extendB: Bool) -> [CurveHit] {
        let domainA = effectiveDomain(a, extend: extendA)
        let domainB = effectiveDomain(b, extend: extendB)
        guard domainA.upperBound > domainA.lowerBound, domainB.upperBound > domainB.lowerBound else { return [] }

        var seeds: [(Double, Double)] = []
        subdivide(a, domainA, b, domainB, depth: 0, tol: tol, into: &seeds)

        var hits: [CurveHit] = []
        for (u0, v0) in seeds {
            if let refined = newtonRefine(a, u0, b, v0, domainA: domainA, domainB: domainB, tol: tol) {
                hits.append(refined)
            }
        }

        // Deduplicate hits that are within tol.linear in space AND
        // tol.parametric in both u1 and u2 of each other, then compute
        // within1/within2 against the curves' OWN un-extended domains.
        let trueDomainA = a.paramDomain, trueDomainB = b.paramDomain
        var finalHits: [CurveHit] = []
        for h in hits {
            let within1 = inOwnDomain(h.u1, trueDomainA, tol: tol)
            let within2 = inOwnDomain(h.u2, trueDomainB, tol: tol)
            let hit = CurveHit(u1: h.u1, u2: h.u2, point: h.point, within1: within1, within2: within2)
            if !finalHits.contains(where: {
                simd_length($0.point - hit.point) < tol.linear
                    && abs($0.u1 - hit.u1) < max(tol.parametric, 1e-7)
                    && abs($0.u2 - hit.u2) < max(tol.parametric, 1e-7)
            }) {
                finalHits.append(hit)
            }
        }
        return finalHits
    }

    /// The domain to search: widened to the full periodic range if
    /// extension was requested and the curve supports it (splines never
    /// extend — `canExtend` is false for them, so `extend` has no effect).
    private static func effectiveDomain(_ c: Curve2, extend: Bool) -> ClosedRange<Double> {
        guard extend, c.canExtend else { return c.paramDomain }
        switch c {
        case .segment:
            // Infinite line: represented with a very wide but finite
            // parameter range so subdivision terminates. 1e6 domain-units
            // in either direction on the 0...1 chord parametrization is far
            // beyond any realistic drawing extent while staying finite.
            let wideLineExtent = 1e6
            return (-wideLineExtent)...(wideLineExtent)
        case .arc:
            return 0...(2 * .pi)
        case .ellipse:
            return 0...(2 * .pi) // full ellipse in the same parametric-angle convention, shifted to start at 0
        case .circle:
            return c.paramDomain // already full period
        case .spline:
            return c.paramDomain
        }
    }

    private static func subdivide(_ a: Curve2, _ domainA: ClosedRange<Double>,
                                  _ b: Curve2, _ domainB: ClosedRange<Double>,
                                  depth: Int, tol: Tolerance, into seeds: inout [(Double, Double)]) {
        let bboxA = sampledBBox(a, domainA).inflated(by: tol.linear)
        let bboxB = sampledBBox(b, domainB).inflated(by: tol.linear)
        guard bboxA.intersects(bboxB) else { return }

        let smallEnough = bboxA.maxExtent < subdivisionBBoxFactor * tol.linear
            && bboxB.maxExtent < subdivisionBBoxFactor * tol.linear
        if smallEnough || depth > maxSubdivisionDepth {
            seeds.append(((domainA.lowerBound + domainA.upperBound) / 2, (domainB.lowerBound + domainB.upperBound) / 2))
            return
        }

        let midA = (domainA.lowerBound + domainA.upperBound) / 2
        let midB = (domainB.lowerBound + domainB.upperBound) / 2
        // Whichever domain is relatively larger drives the split so we
        // don't endlessly bisect an already-tight side.
        let splitA = (domainA.upperBound - domainA.lowerBound) >= (domainB.upperBound - domainB.lowerBound)

        if splitA {
            subdivide(a, domainA.lowerBound...midA, b, domainB, depth: depth + 1, tol: tol, into: &seeds)
            subdivide(a, midA...domainA.upperBound, b, domainB, depth: depth + 1, tol: tol, into: &seeds)
        } else {
            subdivide(a, domainA, b, domainB.lowerBound...midB, depth: depth + 1, tol: tol, into: &seeds)
            subdivide(a, domainA, b, midB...domainB.upperBound, depth: depth + 1, tol: tol, into: &seeds)
        }
    }

    /// bbox over an explicit (possibly extended) sub-domain — separate from
    /// `Curve2.bbox()` (which always uses the curve's own paramDomain).
    private static func sampledBBox(_ c: Curve2, _ domain: ClosedRange<Double>, samples: Int = 12) -> AABB {
        guard domain.upperBound > domain.lowerBound else {
            let p = c.evaluate(domain.lowerBound)
            return AABB(min: p, max: p)
        }
        var mn = c.evaluate(domain.lowerBound)
        var mx = mn
        for k in 0...samples {
            let u = domain.lowerBound + (domain.upperBound - domain.lowerBound) * Double(k) / Double(samples)
            let p = c.evaluate(u)
            mn = Vec2(Swift.min(mn.x, p.x), Swift.min(mn.y, p.y))
            mx = Vec2(Swift.max(mx.x, p.x), Swift.max(mx.y, p.y))
        }
        return AABB(min: mn, max: mx)
    }

    /// 2D Newton on F(u,v) = a(u) - b(v) = 0, Jacobian = [a'(u), -b'(v)].
    /// Falls back to gradient descent minimizing |F|^2 if the Jacobian is
    /// near-singular, accepting the result only if |F| < tol.linear.
    private static func newtonRefine(_ a: Curve2, _ u0: Double, _ b: Curve2, _ v0: Double,
                                     domainA: ClosedRange<Double>, domainB: ClosedRange<Double>,
                                     tol: Tolerance) -> CurveHit? {
        var u = u0, v = v0
        var convergedByNewton = false
        for _ in 0..<genericNewtonMaxIter {
            let F = a.evaluate(u) - b.evaluate(v)
            if simd_length(F) < tol.linear { convergedByNewton = true; break }
            let da = a.derivative(u)
            let db = b.derivative(v)
            // Jacobian columns: d F / d u = da, d F / d v = -db.
            // Solve J * [du, dv]^T = -F  where J = [da, -db] (2x2).
            let det = da.x * (-db.y) - (-db.x) * da.y
            if abs(det) < 1e-14 {
                // Near-singular Jacobian: gradient descent on |F|^2.
                let grad = Vec2(2 * simd_dot(F, da), -2 * simd_dot(F, db))
                let gradLenSq = simd_length_squared(grad)
                guard gradLenSq > 1e-300 else { break }
                let stepSize = 1e-3
                u -= stepSize * grad.x
                v -= stepSize * grad.y
            } else {
                // Cramer's rule for J * [du, dv] = -F.
                let rhsX = -F.x, rhsY = -F.y
                let du = (rhsX * (-db.y) - (-db.x) * rhsY) / det
                let dv = (da.x * rhsY - rhsX * da.y) / det
                u += du
                v += dv
            }
            u = clampExtending(u, domainA)
            v = clampExtending(v, domainB)
        }
        let F = a.evaluate(u) - b.evaluate(v)
        let residual = simd_length(F)
        guard residual < tol.linear else { return nil }
        _ = convergedByNewton
        let point = (a.evaluate(u) + b.evaluate(v)) / 2
        // within1/within2 are filled in by the caller against the TRUE
        // (un-extended) domain; here we just need something valid to return.
        return CurveHit(u1: u, u2: v, point: point, within1: true, within2: true)
    }

    /// Clamps a Newton-iterate parameter to a generous margin around the
    /// (possibly extended) search domain, preventing runaway divergence
    /// while still allowing convergence near the domain's edges.
    private static func clampExtending(_ u: Double, _ domain: ClosedRange<Double>) -> Double {
        let span = max(domain.upperBound - domain.lowerBound, 1e-9)
        let margin = span * 0.05
        return min(max(u, domain.lowerBound - margin), domain.upperBound + margin)
    }

    // MARK: - Dedup helper (analytic cases)

    private static func dedupHits(_ hits: [CurveHit], tol: Tolerance) -> [CurveHit] {
        var result: [CurveHit] = []
        for h in hits {
            if !result.contains(where: { simd_length($0.point - h.point) < tol.linear }) {
                result.append(h)
            }
        }
        return result
    }
}
