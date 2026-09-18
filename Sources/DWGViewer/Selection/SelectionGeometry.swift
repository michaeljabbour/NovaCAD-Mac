//
//  SelectionGeometry.swift
//  DWGViewer / Selection
//
//  Phase 4.1 — pure geometric predicates behind window/crossing/lasso/fence
//  selection: does a curve's geometry lie fully inside a rectangle (Window),
//  or does it merely touch/cross the rectangle's boundary (Crossing)? Same
//  predicates serve lasso/fence selection, which reduce to "does this curve
//  cross ANY edge of an arbitrary polygon/polyline" rather than a rectangle's
//  4 edges specifically.
//
//  Pure (no CoreGraphics, no EntityStore) and table-driven-tested — every
//  function here is a closed-form geometric test over `Vec2`/`AABB` inputs,
//  independent of how the caller obtained them (SelectionEngine bridges
//  EntityStore records to these via CurveBridge/Curve2 decomposition).
//

import Foundation
import CADCore
import simd

enum SelGeom {

    // MARK: - Segment / rectangle

    /// True if the closed segment `a->b` has at least one endpoint inside
    /// `rect` (inclusive of the boundary) OR crosses `rect`'s boundary at
    /// all — i.e., "Crossing" selection's per-segment test. Implemented via
    /// Liang-Barsky clipping (fast, branch-light, no trig): the segment
    /// intersects the (possibly degenerate) rectangle iff the clipped
    /// parameter interval [tEnter, tExit] is non-empty.
    static func segmentIntersectsRect(_ a: Vec2, _ b: Vec2, _ rect: RectRegion) -> Bool {
        // Degenerate point "segment": just an inside-rect test.
        if a == b { return rect.contains(a) }

        let d = b - a
        var t0 = 0.0, t1 = 1.0

        // Clip against each of the 4 half-planes in turn; if the interval
        // ever becomes empty, the segment cannot cross the rect.
        func clip(_ p: Double, _ q: Double) -> Bool {
            if p == 0 {
                // Parallel to this boundary pair — segment is entirely
                // outside if q < 0 (i.e. on the wrong side).
                return q >= 0
            }
            let r = q / p
            if p < 0 {
                if r > t1 { return false }
                if r > t0 { t0 = r }
            } else {
                if r < t0 { return false }
                if r < t1 { t1 = r }
            }
            return true
        }

        guard clip(-d.x, a.x - rect.minX),
              clip(d.x, rect.maxX - a.x),
              clip(-d.y, a.y - rect.minY),
              clip(d.y, rect.maxY - a.y)
        else { return false }

        return t0 <= t1
    }

    // MARK: - Segment / segment

    /// True if closed segments `p1->p2` and `q1->q2` intersect (including
    /// touching at an endpoint), via the standard cross-product parametric
    /// test. Collinear-overlapping segments are treated as intersecting iff
    /// their parameter ranges actually overlap (not just the infinite lines).
    static func segmentsIntersect(_ p1: Vec2, _ p2: Vec2, _ q1: Vec2, _ q2: Vec2) -> Bool {
        let r = p2 - p1
        let s = q2 - q1
        let rxs = cross(r, s)
        let qmp = q1 - p1
        let qmpxr = cross(qmp, r)

        if abs(rxs) < 1e-12 {
            // Parallel. Intersect only if also collinear AND overlapping.
            guard abs(qmpxr) < 1e-12 else { return false }
            let rr = simd_dot(r, r)
            guard rr > 0 else {
                // p1 == p2 (degenerate): true iff that point lies on q1->q2.
                return pointOnSegment(p1, q1, q2)
            }
            let t0 = simd_dot(qmp, r) / rr
            let t1 = t0 + simd_dot(s, r) / rr
            let lo = min(t0, t1), hi = max(t0, t1)
            return hi >= 0 && lo <= 1
        }

        let t = cross(qmp, s) / rxs
        let u = qmpxr / rxs
        return t >= -1e-12 && t <= 1 + 1e-12 && u >= -1e-12 && u <= 1 + 1e-12
    }

    private static func pointOnSegment(_ p: Vec2, _ a: Vec2, _ b: Vec2) -> Bool {
        let ab = b - a
        let len2 = simd_length_squared(ab)
        guard len2 > 0 else { return simd_length(p - a) < 1e-9 }
        let t = simd_dot(p - a, ab) / len2
        guard t >= -1e-9, t <= 1 + 1e-9 else { return false }
        let closest = a + ab * t
        return simd_length(p - closest) < 1e-9
    }

    private static func cross(_ a: Vec2, _ b: Vec2) -> Double { a.x * b.y - a.y * b.x }

    // MARK: - Arc / rectangle

    /// True if a circular arc (center/radius/CCW start->end sweep in
    /// radians, matching `CircArc`'s convention) intersects `rect` under
    /// Crossing semantics: either endpoint lies inside the rect, OR the
    /// arc's circle crosses one of the rect's 4 edges at a point actually
    /// within the swept range, OR (residual case a coarse edge-crossing
    /// test can miss: an arc that bulges entirely through the rect without
    /// either endpoint inside and without crossing an edge — geometrically
    /// impossible for a convex rect unless the arc's swept portion passes
    /// through the interior without crossing the boundary, which can't
    /// actually happen for a simple closed rect boundary, but the
    /// arc-midpoint-in-rect check is kept as a cheap defensive residual
    /// consistent with the plan's spec) the arc's midpoint lies inside.
    static func arcIntersectsRect(center: Vec2, radius: Double, startAngle: Double, sweep: Double,
                                  rect: RectRegion) -> Bool {
        guard radius > 0 else { return rect.contains(center) }

        let sign: Double = sweep >= 0 ? 1 : -1
        let totalSweep = abs(sweep)
        func pointAt(_ u: Double) -> Vec2 {
            let angle = startAngle + sign * u
            return center + Vec2(cos(angle), sin(angle)) * radius
        }

        // 1. Endpoints inside the rect.
        let startPt = pointAt(0)
        let endPt = pointAt(totalSweep)
        if rect.contains(startPt) || rect.contains(endPt) { return true }

        // 2. Early-out: the circle doesn't even reach the rect.
        let circleBBox = RectRegion(minX: center.x - radius, minY: center.y - radius,
                                    maxX: center.x + radius, maxY: center.y + radius)
        guard circleBBox.intersects(rect) else { return false }
        // Also reject if the rect is entirely outside the circle's ring
        // (all 4 rect corners closer than radius AND all farther than
        // radius would both mean no crossing — but a rect can still
        // straddle the circle without any corner being exactly on it, so
        // this is only a cheap reject when the WHOLE rect is strictly
        // inside the circle's disk with no boundary crossing possible for
        // a non-full circle; skip this optimization's complexity and rely
        // on the per-edge test below, which is exact regardless).

        // 3. Per-edge circle/segment intersection, filtered to the swept range.
        for (ea, eb) in rect.edges() {
            for hit in circleSegmentIntersections(center: center, radius: radius, a: ea, b: eb) {
                let rel = angleOnArc(hit, center: center, startAngle: startAngle, sweep: sweep)
                if let rel, rel >= -1e-9, rel <= totalSweep + 1e-9 { return true }
            }
        }

        // 4. Residual: arc's own midpoint inside the rect (defensive; see
        // doc comment — kept for parity with the plan's specified algorithm
        // shape even though per-edge crossing above is exact for a convex
        // rect and a circular arc).
        if rect.contains(pointAt(totalSweep / 2)) { return true }

        return false
    }

    /// Intersection points of a circle with a segment (0, 1, or 2 points).
    private static func circleSegmentIntersections(center: Vec2, radius: Double, a: Vec2, b: Vec2) -> [Vec2] {
        let d = b - a
        let f = a - center
        let aCoef = simd_dot(d, d)
        guard aCoef > 1e-18 else { return [] }
        let bCoef = 2 * simd_dot(f, d)
        let cCoef = simd_dot(f, f) - radius * radius
        let disc = bCoef * bCoef - 4 * aCoef * cCoef
        guard disc >= 0 else { return [] }
        let sqrtDisc = sqrt(disc)
        let t1 = (-bCoef - sqrtDisc) / (2 * aCoef)
        let t2 = (-bCoef + sqrtDisc) / (2 * aCoef)
        var pts: [Vec2] = []
        if t1 >= -1e-9, t1 <= 1 + 1e-9 { pts.append(a + d * t1) }
        if abs(t2 - t1) > 1e-12, t2 >= -1e-9, t2 <= 1 + 1e-9 { pts.append(a + d * t2) }
        return pts
    }

    /// The angular distance (radians, always >= 0, in the sweep's own
    /// direction) from `startAngle` to the angle of `point` relative to
    /// `center`, or nil if `point` is at the center itself (undefined
    /// angle). Does NOT wrap/clamp to the sweep range — callers compare the
    /// result against `[0, abs(sweep)]` themselves.
    private static func angleOnArc(_ point: Vec2, center: Vec2, startAngle: Double, sweep: Double) -> Double? {
        let d = point - center
        guard simd_length(d) > 1e-12 else { return nil }
        let angle = atan2(d.y, d.x)
        let sign: Double = sweep >= 0 ? 1 : -1
        var rel = (angle - startAngle) * sign
        rel = rel.truncatingRemainder(dividingBy: 2 * .pi)
        if rel < 0 { rel += 2 * .pi }
        return rel
    }

    // MARK: - Point / polygon

    /// Even-odd point-in-polygon test (ray casting). `polygon` need not be
    /// explicitly closed (the last->first edge is always tested).
    static func pointInPolygon(_ p: Vec2, _ polygon: [Vec2]) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let pi = polygon[i], pj = polygon[j]
            if (pi.y > p.y) != (pj.y > p.y),
               p.x < (pj.x - pi.x) * (p.y - pi.y) / (pj.y - pi.y) + pi.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    // MARK: - Segment / polygon

    /// True if segment `a->b` crosses any edge of `polygon` (implicitly
    /// closed — last->first edge included) OR either endpoint lies inside
    /// it. The general-purpose crossing test lasso/fence selection use in
    /// place of `segmentIntersectsRect`'s 4-edge special case.
    static func segmentIntersectsPolygon(_ a: Vec2, _ b: Vec2, _ polygon: [Vec2]) -> Bool {
        guard polygon.count >= 2 else { return false }
        if pointInPolygon(a, polygon) || pointInPolygon(b, polygon) { return true }
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            if segmentsIntersect(a, b, polygon[j], polygon[i]) { return true }
            j = i
        }
        return false
    }

    // MARK: - Full containment (Window selection)

    /// True if every vertex of `polyline` lies inside-or-on `rect` — the
    /// necessary condition for a straight-segment polyline to be fully
    /// enclosed (sufficient too, since a convex rectangle's boundary can't
    /// be crossed by a segment whose both endpoints are inside it without
    /// ALSO putting at least one of those endpoints outside — i.e. segments
    /// between contained vertices never bulge outside a convex region).
    /// Callers with bulge/arc segments must additionally verify each arc
    /// segment individually (e.g. via `arcIntersectsRect`'s endpoint checks
    /// plus a containment variant, or by decomposing to `Curve2` and
    /// checking the arc's own bbox is within `rect`) — this function alone
    /// is exact only for straight-edge polylines.
    static func rectFullyContainsPolyline(_ vertices: [Vec2], _ rect: RectRegion) -> Bool {
        guard !vertices.isEmpty else { return false }
        return vertices.allSatisfy { rect.contains($0) }
    }
}

// MARK: - RectRegion

/// A plain axis-aligned rectangle over `Vec2`, independent of CoreGraphics —
/// `Selection/SelectionEngine.swift` bridges `CGRect` to this at its API
/// boundary so `SelGeom` itself has zero CoreGraphics dependency, matching
/// `Geometry/`'s existing convention (CurveBridge.swift is the only
/// CoreGraphics-touching file there).
struct RectRegion: Equatable {
    var minX: Double, minY: Double, maxX: Double, maxY: Double

    init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.minX = min(minX, maxX); self.maxX = max(minX, maxX)
        self.minY = min(minY, maxY); self.maxY = max(minY, maxY)
    }

    init(a: Vec2, b: Vec2) {
        self.init(minX: a.x, minY: a.y, maxX: b.x, maxY: b.y)
    }

    func contains(_ p: Vec2) -> Bool {
        p.x >= minX && p.x <= maxX && p.y >= minY && p.y <= maxY
    }

    func intersects(_ o: RectRegion) -> Bool {
        minX <= o.maxX && maxX >= o.minX && minY <= o.maxY && maxY >= o.minY
    }

    /// The 4 boundary edges, in a consistent (here: CCW starting at the
    /// bottom edge) winding order — winding direction doesn't matter for
    /// any predicate in this file, but a fixed order keeps tests predictable.
    func edges() -> [(Vec2, Vec2)] {
        let bl = Vec2(minX, minY), br = Vec2(maxX, minY)
        let tr = Vec2(maxX, maxY), tl = Vec2(minX, maxY)
        return [(bl, br), (br, tr), (tr, tl), (tl, bl)]
    }
}
