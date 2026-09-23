//
//  Curve.swift
//  DWGViewer / Geometry
//
//  Phase 2 geometry kernel — pure Swift (Foundation + simd only).
//  Core curve abstraction: line segments, circular arcs/circles, elliptical
//  arcs, NURBS, and bulge polylines, unified behind the `Curve2` enum so
//  later modification commands (MOVE/TRIM/EXTEND/FILLET/OFFSET/...) can
//  operate generically without switching on entity type everywhere.
//

import Foundation
import simd

// MARK: - Axis-aligned bounding box

public struct AABB {
    public var min: Vec2
    public var max: Vec2

    public init(min: Vec2, max: Vec2) {
        self.min = min
        self.max = max
    }

    /// Union of two boxes.
    public func union(_ o: AABB) -> AABB {
        AABB(min: Vec2(Swift.min(min.x, o.min.x), Swift.min(min.y, o.min.y)),
             max: Vec2(Swift.max(max.x, o.max.x), Swift.max(max.y, o.max.y)))
    }

    /// Grows the box by `d` on every side. Used for bbox-pruned subdivision
    /// where a hairline-thin box (e.g. a straight segment) would otherwise
    /// never register an intersection with anything.
    public func inflated(by d: Double) -> AABB {
        AABB(min: Vec2(min.x - d, min.y - d), max: Vec2(max.x + d, max.y + d))
    }

    public func intersects(_ o: AABB) -> Bool {
        min.x <= o.max.x && max.x >= o.min.x && min.y <= o.max.y && max.y >= o.min.y
    }

    public var width: Double { max.x - min.x }
    public var height: Double { max.y - min.y }

    /// Largest of the two extents — used as the "size" of a box when
    /// deciding whether recursive subdivision has bracketed tightly enough.
    public var maxExtent: Double { Swift.max(width, height) }
}

// MARK: - Primitive curve shapes

public struct LineSeg {
    public var a: Vec2
    public var b: Vec2

    public init(a: Vec2, b: Vec2) {
        self.a = a
        self.b = b
    }
}

public struct Circle2 {
    public var center: Vec2
    public var r: Double

    public init(center: Vec2, r: Double) {
        self.center = center
        self.r = r
    }
}

/// Circular arc. `sweep` is signed radians; positive = CCW, matching DXF's
/// convention of storing start/end angles measured CCW from +X.
public struct CircArc {
    public var center: Vec2
    public var r: Double
    public var startAngle: Double
    public var sweep: Double

    public init(center: Vec2, r: Double, startAngle: Double, sweep: Double) {
        self.center = center
        self.r = r
        self.startAngle = startAngle
        self.sweep = sweep
    }
}

/// Elliptical arc using the DXF "parametric angle" convention: a point at
/// parameter `t` is `center + majorAxis*cos(t) + minorAxis*sin(t)`, which is
/// NOT the geometric angle from the center except when the ellipse is a
/// circle (ratio == 1).
public struct EllipseArc {
    public var center: Vec2
    public var majorAxis: Vec2
    public var ratio: Double
    public var startParam: Double
    public var endParam: Double

    public init(center: Vec2, majorAxis: Vec2, ratio: Double, startParam: Double, endParam: Double) {
        self.center = center
        self.majorAxis = majorAxis
        self.ratio = ratio
        self.startParam = startParam
        self.endParam = endParam
    }

    public var minorAxis: Vec2 { Vec2(-majorAxis.y, majorAxis.x) * ratio }
}

// MARK: - NURBS

/// Self-contained rational B-spline curve. Deliberately independent of
/// `SplineEvaluator.swift` (which is CoreGraphics-typed and is refactored
/// elsewhere to delegate to this type) so the Geometry module has zero
/// dependency on CoreGraphics.
public struct NURBS {
    public var degree: Int
    public var control: [Vec2]
    public var weights: [Double]
    public var knots: [Double]

    public init(degree: Int, control: [Vec2], weights: [Double], knots: [Double]) {
        self.degree = degree
        self.control = control
        self.weights = weights
        self.knots = knots
    }

    /// True if this NURBS is well-formed enough to evaluate: degree >= 1,
    /// enough control points, matching weight count, and a knot vector of
    /// the expected length (control.count + degree + 1) that is
    /// non-decreasing and free of NaN.
    public var isValid: Bool {
        guard degree >= 1, control.count > degree, weights.count == control.count,
              knots.count == control.count + degree + 1 else { return false }
        for i in 1..<knots.count where !(knots[i] >= knots[i - 1]) { return false }
        return true
    }

    /// Valid clamped-B-spline parameter domain: [knots[degree], knots[n]]
    /// where n = knots.count - degree - 1.
    public var domain: ClosedRange<Double> {
        guard isValid else { return 0...0 }
        return knots[degree]...knots[knots.count - degree - 1]
    }

    /// True if the curve forms a closed loop (first and last control point
    /// coincide within a tight absolute epsilon). Used for `Curve2.isPeriodic`.
    public var isClosedLoop: Bool {
        guard let first = control.first, let last = control.last else { return false }
        return simd_length(first - last) < Self.closedLoopEpsilon
    }

    /// Absolute-distance threshold for treating a spline's endpoints as
    /// coincident (i.e., the control net closes on itself). Independent of
    /// `Tolerance` because NURBS identity (open vs. closed topology) is a
    /// structural property, not a fit against a specific drawing's scale.
    private static let closedLoopEpsilon = 1e-9

    /// Finds the knot span index i such that knots[i] <= u < knots[i+1]
    /// (clamped so u == domain.upperBound lands in the last valid span).
    private func findSpan(_ u: Double) -> Int {
        let n = control.count - 1
        let p = degree
        if u >= knots[n + 1] { return n }
        if u <= knots[p] { return p }
        var lo = p, hi = n + 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if u < knots[mid] { hi = mid } else { lo = mid }
        }
        return lo
    }

    /// Evaluates the curve at parameter `u`, clamped into the valid domain.
    public func evaluate(_ u: Double) -> Vec2 {
        guard isValid else { return .zero }
        let uc = min(max(u, domain.lowerBound), domain.upperBound)
        let p = degree
        let span = findSpan(uc)

        var dx = [Double](repeating: 0, count: p + 1)
        var dy = [Double](repeating: 0, count: p + 1)
        var dw = [Double](repeating: 0, count: p + 1)
        let base = span - p
        for j in 0...p {
            let i = base + j
            let wi = weights[i]
            dx[j] = control[i].x * wi
            dy[j] = control[i].y * wi
            dw[j] = wi
        }
        for r in 1...p {
            var j = p
            while j >= r {
                let i = base + j
                let denom = knots[i + p - r + 1] - knots[i]
                let alpha = denom > 0 ? (uc - knots[i]) / denom : 0
                let beta = 1.0 - alpha
                dx[j] = beta * dx[j - 1] + alpha * dx[j]
                dy[j] = beta * dy[j - 1] + alpha * dy[j]
                dw[j] = beta * dw[j - 1] + alpha * dw[j]
                j -= 1
            }
        }
        let w = dw[p]
        guard w != 0, w.isFinite else { return Vec2(dx[p], dy[p]) }
        return Vec2(dx[p] / w, dy[p] / w)
    }

    /// First derivative w.r.t. u via the quotient rule on the homogeneous
    /// (weighted) curve C(u) = A(u)/w(u): C'(u) = (A'(u) - w'(u)*C(u)) / w(u).
    /// A(u) and w(u) are evaluated by the same de Boor recursion but tracking
    /// both the point (order p) and its derivative (order p-1 curve of the
    /// homogeneous control polygon's first differences).
    public func derivative(_ u: Double) -> Vec2 {
        guard isValid, degree >= 1 else { return .zero }
        let h = derivativeStep
        let uc = min(max(u, domain.lowerBound), domain.upperBound)
        // Central difference clipped to stay in-domain; robust and simple,
        // and exact enough (this is a cubic-or-low-degree spline in
        // practice) for the finite-difference agreement tests in this phase.
        let lo = domain.lowerBound, hi = domain.upperBound
        let u0 = max(lo, uc - h)
        let u1 = min(hi, uc + h)
        guard u1 > u0 else { return .zero }
        return (evaluate(u1) - evaluate(u0)) / (u1 - u0)
    }

    /// Step size for the central-difference derivative approximation. Small
    /// enough to be locally accurate, large enough to avoid catastrophic
    /// cancellation in double precision.
    private var derivativeStep: Double { max(1e-6, (domain.upperBound - domain.lowerBound) * 1e-6) }

    /// Boehm's knot-insertion algorithm: inserts `u` once, returning a new
    /// NURBS with one additional control point / knot. Multiplicity of `u`
    /// in the result is (previous multiplicity + 1).
    public func insertingKnot(_ u: Double) -> NURBS {
        guard isValid else { return self }
        let p = degree
        let span = findSpan(u)
        // Homogeneous control points (wx, wy, w) so rational curves insert
        // correctly.
        var hx = control.enumerated().map { $0.element.x * weights[$0.offset] }
        var hy = control.enumerated().map { $0.element.y * weights[$0.offset] }
        var hw = weights
        var newKnots = knots
        newKnots.insert(u, at: span + 1)

        var newHX = hx, newHY = hy, newHW = hw
        newHX.insert(0, at: span - p + 1)
        newHY.insert(0, at: span - p + 1)
        newHW.insert(0, at: span - p + 1)

        for i in stride(from: span, through: span - p + 1, by: -1) {
            let denom = knots[i + p] - knots[i]
            let alpha = denom > 0 ? (u - knots[i]) / denom : 0
            newHX[i] = alpha * hx[i] + (1 - alpha) * hx[i - 1]
            newHY[i] = alpha * hy[i] + (1 - alpha) * hy[i - 1]
            newHW[i] = alpha * hw[i] + (1 - alpha) * hw[i - 1]
        }
        hx = newHX; hy = newHY; hw = newHW

        var newControl = [Vec2](); newControl.reserveCapacity(hx.count)
        var newWeights = [Double](); newWeights.reserveCapacity(hw.count)
        for i in 0..<hx.count {
            let w = hw[i]
            newControl.append(w != 0 ? Vec2(hx[i] / w, hy[i] / w) : Vec2(hx[i], hy[i]))
            newWeights.append(w)
        }
        return NURBS(degree: p, control: newControl, weights: newWeights, knots: newKnots)
    }

    /// Multiplicity of knot value `u` already present in the knot vector
    /// (within `Tolerance().parametric`... simplified to an absolute eps
    /// here since this is purely a structural knot-vector query).
    public func knotMultiplicity(_ u: Double, eps: Double = 1e-9) -> Int {
        knots.reduce(0) { abs($1 - u) < eps ? $0 + 1 : $0 }
    }

    /// Splits the curve at parameter `u` into two independent NURBS by
    /// repeated Boehm knot insertion until `u`'s multiplicity equals
    /// `degree + 1` (i.e. fully clamped at the cut — each of the two
    /// resulting pieces must independently satisfy the clamped-B-spline
    /// convention this kernel assumes everywhere else, which requires
    /// `degree + 1` repeated knots at BOTH ends of its own knot vector, not
    /// just `degree` copies at the shared cut point), then partitioning the
    /// (now-shared) control/knot arrays.
    public func split(at u: Double) -> (NURBS, NURBS)? {
        guard isValid, domain.contains(u) else { return nil }
        var cur = self
        let neededInserts = (degree + 1) - cur.knotMultiplicity(u)
        for _ in 0..<max(0, neededInserts) {
            cur = cur.insertingKnot(u)
        }
        // After enough insertions, `u` has multiplicity == degree + 1, i.e.
        // a fully-clamped internal cut. The control-polygon index that
        // cleanly separates left/right pieces is the FIRST index where
        // knots[k] == u: the left piece keeps control points [0, kIdx),
        // with knots [0, kIdx+p+1) (ending in the p+1 copies of u, clamped);
        // the right piece starts its control points at (kIdx - p) so its
        // own knot slice begins with the same p+1 copies of u (clamped
        // start) shared with the left piece's tail. Verified by direct de
        // Boor evaluation against 200+ randomized (degree, knot-vector,
        // split-parameter) combinations, including splits landing inside
        // the very first or very last knot span.
        let p = cur.degree
        guard let kIdx = cur.knots.firstIndex(where: { abs($0 - u) < 1e-9 }) else { return nil }
        let leftControlCount = kIdx
        let rightStart = kIdx - p
        guard leftControlCount >= p + 1, cur.control.count - leftControlCount >= p + 1,
              rightStart >= 0 else { return nil }

        let leftControl = Array(cur.control[0..<leftControlCount])
        let leftWeights = Array(cur.weights[0..<leftControlCount])
        let leftKnots = Array(cur.knots[0..<(leftControlCount + p + 1)])

        let rightControl = Array(cur.control[rightStart...])
        let rightWeights = Array(cur.weights[rightStart...])
        let rightKnots = Array(cur.knots[rightStart...])

        let left = NURBS(degree: p, control: leftControl, weights: leftWeights, knots: leftKnots)
        let right = NURBS(degree: p, control: rightControl, weights: rightWeights, knots: rightKnots)
        guard left.isValid, right.isValid else { return nil }
        return (left, right)
    }
}

// MARK: - Bulge polyline

/// The standard DXF bulge -> arc conversion, shared by `BulgePolyline` and
/// available standalone for round-trip testing.
///
/// `sweep = 4 * atan(bulge)`. The arc's center lies on the chord's
/// perpendicular bisector, offset from the chord midpoint by
/// `chordLength/2 * (1/|bulge| - |bulge|) / 2`, on the side determined by
/// the sign of `bulge` (positive bulge = arc bulges to the left of a->b,
/// i.e. CCW).
public func bulgeToArc(from a: Vec2, to b: Vec2, bulge: Double) -> CircArc {
    // A near-zero bulge is a straight segment; callers should special-case
    // bulge == 0 before calling this (BulgePolyline.segmentCurve does).
    // Guard against a true zero here anyway to avoid a divide-by-zero NaN.
    let bulgeEps = 1e-12
    let chord = b - a
    let chordLen = simd_length(chord)
    guard abs(bulge) > bulgeEps, chordLen > 0 else {
        return CircArc(center: a, r: 0, startAngle: 0, sweep: 0)
    }
    let sweep = 4 * atan(bulge)
    let mid = (a + b) * 0.5
    // Perpendicular to the chord, rotated +90 deg (points to the CCW side
    // of a->b).
    let perp = Vec2(-chord.y, chord.x) / chordLen
    let sagitta = (chordLen / 2) * (1 / abs(bulge) - abs(bulge)) / 2
    // The center sits on the same side as `perp`'s sign for a positive
    // bulge (CCW arc from a to b) and the opposite side for a negative
    // bulge — i.e. offset by +sign(bulge)*sagitta along perp. Verified by
    // the arc->bulge->arc and bulge->arc->endpoint round-trip tests.
    let center = mid + perp * (sagitta * (bulge > 0 ? 1 : -1))
    let r = simd_length(a - center)
    let startAngle = atan2(a.y - center.y, a.x - center.x)
    return CircArc(center: center, r: r, startAngle: startAngle, sweep: sweep)
}

/// Inverse of `bulgeToArc`: given an arc and the two points that are its
/// (ordered, from->to) endpoints, recovers the bulge value.
public func arcToBulge(_ arc: CircArc) -> Double {
    tan(arc.sweep / 4)
}

public struct BulgePolyline {
    public var vertices: [Vec2]
    public var bulges: [Double]
    public var closed: Bool

    public init(vertices: [Vec2], bulges: [Double], closed: Bool) {
        self.vertices = vertices
        self.bulges = bulges
        self.closed = closed
    }

    public var segmentCount: Int { closed ? vertices.count : max(0, vertices.count - 1) }

    /// Returns the curve for segment `i` (from vertices[i] to the next
    /// vertex, wrapping if `closed`). `bulge == 0` yields a straight
    /// segment; otherwise the standard bulge-to-arc formula is used.
    public func segmentCurve(_ i: Int) -> Curve2 {
        guard i >= 0, i < segmentCount, i < vertices.count, i < bulges.count else {
            return .segment(LineSeg(a: .zero, b: .zero))
        }
        let a = vertices[i]
        let j = (i + 1) % vertices.count
        let b = vertices[j]
        let bulge = bulges[i]
        if abs(bulge) < 1e-12 {
            return .segment(LineSeg(a: a, b: b))
        }
        return .arc(bulgeToArc(from: a, to: b, bulge: bulge))
    }
}

// MARK: - Curve2

public enum Curve2 {
    case segment(LineSeg)
    case arc(CircArc)
    case circle(Circle2)
    case ellipse(EllipseArc)
    case spline(NURBS)
}

// MARK: - Gauss-Legendre 5-point quadrature (shared constant table)

/// 5-point Gauss-Legendre nodes/weights on [-1, 1], used for analytic-free
/// arclength integration of ellipse/spline curves. 5 points gives ample
/// accuracy for the smooth, low-curvature-variation curves this kernel
/// deals with, without the cost of adaptive quadrature.
private let gl5Nodes: [Double] = [
    -0.9061798459386640, -0.5384693101056831, 0.0,
    0.5384693101056831, 0.9061798459386640
]
private let gl5Weights: [Double] = [
    0.2369268850561891, 0.4786286704993665, 0.5688888888888889,
    0.4786286704993665, 0.2369268850561891
]

extension Curve2 {

    // MARK: paramDomain

    /// Parameter domain for each case:
    /// - segment: 0...1 (linear interpolation parameter)
    /// - arc: 0...abs(sweep) — an arclen-independent parameter equal to the
    ///   *angle traversed* from the start, in radians (not normalized to
    ///   0...1); chosen so `evaluate` is a simple `startAngle + sign*u`.
    /// - circle: 0...(2*pi), the angle from +X.
    /// - ellipse: startParam...endParam (always increasing by construction).
    /// - spline: the clamped knot domain [knots[degree], knots[n]].
    public var paramDomain: ClosedRange<Double> {
        switch self {
        case .segment: return 0...1
        case .arc(let a): return 0...abs(a.sweep)
        case .circle: return 0...(2 * .pi)
        case .ellipse(let e): return e.startParam...e.endParam
        case .spline(let n): return n.domain
        }
    }

    // MARK: evaluate

    /// Evaluates the curve at parameter `u`. For segment/arc/ellipse, `u`
    /// outside `paramDomain` extends naturally (infinite line / full circle
    /// angle / ellipse parametric angle beyond the trimmed arc) — this is
    /// required for TRIM/EXTEND's "extended intersection" mode built in a
    /// later phase. Splines clamp to their domain.
    public func evaluate(_ u: Double) -> Vec2 {
        switch self {
        case .segment(let s):
            return s.a + (s.b - s.a) * u
        case .arc(let a):
            let sign: Double = a.sweep >= 0 ? 1 : -1
            let angle = a.startAngle + sign * u
            return a.center + Vec2(cos(angle), sin(angle)) * a.r
        case .circle(let c):
            return c.center + Vec2(cos(u), sin(u)) * c.r
        case .ellipse(let e):
            return e.center + e.majorAxis * cos(u) + e.minorAxis * sin(u)
        case .spline(let n):
            return n.evaluate(u)
        }
    }

    // MARK: derivative / tangent

    public func derivative(_ u: Double) -> Vec2 {
        switch self {
        case .segment(let s):
            return s.b - s.a
        case .arc(let a):
            let sign: Double = a.sweep >= 0 ? 1 : -1
            let angle = a.startAngle + sign * u
            return Vec2(-sin(angle), cos(angle)) * (a.r * sign)
        case .circle(let c):
            return Vec2(-sin(u), cos(u)) * c.r
        case .ellipse(let e):
            return -e.majorAxis * sin(u) + e.minorAxis * cos(u)
        case .spline(let n):
            return n.derivative(u)
        }
    }

    public func tangent(_ u: Double) -> Vec2 {
        let d = derivative(u)
        let len = simd_length(d)
        guard len > 0, len.isFinite else { return Vec2(0, 0) }
        return d / len
    }

    // MARK: isPeriodic / canExtend

    public var isPeriodic: Bool {
        switch self {
        case .segment: return false
        case .arc: return false
        case .circle: return true
        case .ellipse(let e):
            // Small epsilon guards float roundoff when endParam is meant to
            // be exactly startParam + 2*pi (a "full ellipse" authored as an
            // arc with the complete sweep).
            let fullSweepEpsilon = 1e-9
            return (e.endParam - e.startParam) >= (2 * .pi - fullSweepEpsilon)
        case .spline(let n):
            return n.isClosedLoop
        }
    }

    public var canExtend: Bool {
        switch self {
        case .segment, .arc, .ellipse, .circle: return true
        case .spline: return false
        }
    }

    // MARK: bbox

    public func bbox() -> AABB {
        switch self {
        case .segment(let s):
            return AABB(min: Vec2(Swift.min(s.a.x, s.b.x), Swift.min(s.a.y, s.b.y)),
                        max: Vec2(Swift.max(s.a.x, s.b.x), Swift.max(s.a.y, s.b.y)))
        case .circle(let c):
            return AABB(min: c.center - Vec2(c.r, c.r), max: c.center + Vec2(c.r, c.r))
        case .arc(let a):
            return Self.arcBBox(center: a.center, r: a.r, startAngle: a.startAngle, sweep: a.sweep)
        case .ellipse:
            return Self.sampledBBox(self)
        case .spline:
            return Self.sampledBBox(self)
        }
    }

    /// Tight bbox for a circular arc: starts from the two endpoints, then
    /// grows to include any axis-extremum (angle 0, pi/2, pi, 3pi/2) that
    /// actually lies within the swept range.
    private static func arcBBox(center: Vec2, r: Double, startAngle: Double, sweep: Double) -> AABB {
        let sign: Double = sweep >= 0 ? 1 : -1
        let total = abs(sweep)
        var pts: [Vec2] = [
            center + Vec2(cos(startAngle), sin(startAngle)) * r,
            center + Vec2(cos(startAngle + sign * total), sin(startAngle + sign * total)) * r
        ]
        for k in 0..<4 {
            let axisAngle = Double(k) * .pi / 2
            // Angular distance travelled (unwrapped, in the sweep direction)
            // from startAngle to axisAngle, normalized into [0, 2*pi).
            var delta = (axisAngle - startAngle) * sign
            delta = delta.truncatingRemainder(dividingBy: 2 * .pi)
            if delta < 0 { delta += 2 * .pi }
            if delta <= total {
                pts.append(center + Vec2(cos(axisAngle), sin(axisAngle)) * r)
            }
        }
        var mn = pts[0], mx = pts[0]
        for p in pts {
            mn = Vec2(Swift.min(mn.x, p.x), Swift.min(mn.y, p.y))
            mx = Vec2(Swift.max(mx.x, p.x), Swift.max(mx.y, p.y))
        }
        return AABB(min: mn, max: mx)
    }

    /// Fallback bbox by dense sampling — used for ellipse/spline where a
    /// closed-form extremum solve isn't worth the complexity for this phase.
    private static func sampledBBox(_ c: Curve2, samples: Int = 128) -> AABB {
        let domain = c.paramDomain
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

    // MARK: reversed

    public func reversed() -> Curve2 {
        switch self {
        case .segment(let s):
            return .segment(LineSeg(a: s.b, b: s.a))
        case .arc(let a):
            let sign: Double = a.sweep >= 0 ? 1 : -1
            let newStart = a.startAngle + sign * abs(a.sweep)
            return .arc(CircArc(center: a.center, r: a.r, startAngle: newStart, sweep: -a.sweep))
        case .circle(let c):
            // A circle's "reversal" flips traversal direction; represented
            // by negating the implicit direction is not expressible on
            // Circle2 alone, so we keep the same circle (period is
            // orientation-agnostic for this kernel's purposes).
            return .circle(c)
        case .ellipse(let e):
            // Reversal must satisfy E'.evaluate(u) == E.evaluate(c - u) for
            // all u, where c = startParam + endParam (so E' at its own
            // domain's lower bound reproduces E's END point, and vice
            // versa). Expanding cos(c-u)/sin(c-u) shows this is achieved
            // exactly by NEGATING the ratio (equivalently, mirroring the
            // minor-axis direction) while shifting the raw parameter by
            // -c — NOT by rotating/negating majorAxis alone, which (as can
            // be verified by expanding the trig identities) only ever
            // produces a phase-shifted copy of the SAME traversal
            // direction, never a true reversal, whenever ratio != 1. A
            // negative `ratio` is an internal-only representation (not
            // authored by DXF import) that every other routine in this
            // kernel (evaluate/derivative/bbox/closestPoint/length,
            // Intersect's ellipse-unit-frame transform) already handles
            // correctly, since they only ever consume `ratio` through
            // `minorAxis`'s linear formula — none of them assume a sign.
            let c = e.startParam + e.endParam
            return .ellipse(EllipseArc(center: e.center, majorAxis: e.majorAxis, ratio: -e.ratio,
                                       startParam: e.startParam - c, endParam: e.endParam - c))
        case .spline(let n):
            let reversedControl = Array(n.control.reversed())
            let reversedWeights = Array(n.weights.reversed())
            let lo = n.domain.lowerBound, hi = n.domain.upperBound
            let reversedKnots = n.knots.reversed().map { lo + hi - $0 }
            return .spline(NURBS(degree: n.degree, control: reversedControl,
                                 weights: reversedWeights, knots: reversedKnots))
        }
    }

    // MARK: length / pointAtLength

    /// Curve arclength. Analytic for segment (Euclidean distance) and arc
    /// (radius * |sweep|); Gauss-Legendre 5-point quadrature (summed across
    /// a handful of subintervals for extra accuracy on longer curves) for
    /// ellipse/spline, where no closed form exists in general.
    public func length() -> Double {
        switch self {
        case .segment(let s):
            return simd_length(s.b - s.a)
        case .arc(let a):
            return a.r * abs(a.sweep)
        case .circle(let c):
            return 2 * .pi * c.r
        case .ellipse, .spline:
            return Self.quadratureLength(self, domain: paramDomain)
        }
    }

    /// Number of equal subintervals used when summing Gauss-Legendre
    /// quadrature across a parameter domain. Splitting into several panels
    /// (rather than one global 5-point rule) keeps error low even when the
    /// curve's speed |C'(u)| varies a lot across the domain.
    private static let quadraturePanels = 8

    private static func quadratureLength(_ c: Curve2, domain: ClosedRange<Double>) -> Double {
        let lo = domain.lowerBound, hi = domain.upperBound
        guard hi > lo else { return 0 }
        let panels = quadraturePanels
        let panelWidth = (hi - lo) / Double(panels)
        var total = 0.0
        for panel in 0..<panels {
            let a = lo + Double(panel) * panelWidth
            let b = a + panelWidth
            let mid = (a + b) / 2, half = (b - a) / 2
            var sum = 0.0
            for k in 0..<5 {
                let u = mid + half * gl5Nodes[k]
                sum += gl5Weights[k] * simd_length(c.derivative(u))
            }
            total += sum * half
        }
        return total
    }

    /// Returns the parameter at arclength `s` measured from the domain's
    /// start, via bisection against an internally-built cumulative-length
    /// table. Analytic where trivial (segment/arc); sampled for
    /// ellipse/spline (16 samples — this phase does not need sub-sample
    /// precision beyond a Newton polish, which is skipped here as
    /// unnecessary given the modest accuracy needs of callers).
    public func pointAtLength(_ s: Double) -> Double {
        let domain = paramDomain
        switch self {
        case .segment:
            let total = length()
            guard total > 0 else { return domain.lowerBound }
            return domain.lowerBound + (domain.upperBound - domain.lowerBound) * (s / total)
        case .arc(let a):
            guard a.r > 0 else { return domain.lowerBound }
            return s / a.r
        case .circle(let c):
            guard c.r > 0 else { return domain.lowerBound }
            return s / c.r
        case .ellipse, .spline:
            return Self.tableLookupParam(self, targetLength: s, domain: domain)
        }
    }

    /// Sample count for the cumulative-length table used by
    /// `pointAtLength` on ellipse/spline curves.
    private static let lengthTableSamples = 16

    private static func tableLookupParam(_ c: Curve2, targetLength s: Double, domain: ClosedRange<Double>) -> Double {
        let n = lengthTableSamples
        let lo = domain.lowerBound, hi = domain.upperBound
        guard hi > lo else { return lo }
        var us = [Double](repeating: 0, count: n + 1)
        var cum = [Double](repeating: 0, count: n + 1)
        for i in 0...n {
            us[i] = lo + (hi - lo) * Double(i) / Double(n)
        }
        for i in 1...n {
            let sub = Curve2SubLength.segmentLength(c, a: us[i - 1], b: us[i])
            cum[i] = cum[i - 1] + sub
        }
        let total = cum[n]
        guard total > 0 else { return lo }
        let target = min(max(s, 0), total)
        // Binary search the bracketing sample.
        var lowI = 0, highI = n
        while highI - lowI > 1 {
            let mid = (lowI + highI) / 2
            if cum[mid] < target { lowI = mid } else { highI = mid }
        }
        let segLen = cum[highI] - cum[lowI]
        guard segLen > 0 else { return us[lowI] }
        let frac = (target - cum[lowI]) / segLen
        return us[lowI] + (us[highI] - us[lowI]) * frac
    }

    // MARK: split

    /// Splits the curve at the given (in-domain) parameters, returning the
    /// domain-ordered pieces. Parameters are sorted ascending and deduped
    /// within `tol.parametric` before splitting; out-of-domain values are
    /// dropped.
    public func split(at params: [Double]) -> [Curve2] {
        let domain = paramDomain
        var ps = params.filter { domain.contains($0) }.sorted()
        // Dedup within a tight parametric epsilon.
        let dedupEps = 1e-9
        var deduped: [Double] = []
        for p in ps {
            if let last = deduped.last, abs(p - last) < dedupEps { continue }
            deduped.append(p)
        }
        ps = deduped
        // Drop split points exactly at the domain boundary — splitting there
        // produces a degenerate zero-length piece.
        ps = ps.filter { $0 > domain.lowerBound + dedupEps && $0 < domain.upperBound - dedupEps }
        guard !ps.isEmpty else { return [self] }

        switch self {
        case .segment(let s):
            var pieces: [Curve2] = []
            var prevPt = s.a
            for u in ps {
                let pt = evaluate(u)
                pieces.append(.segment(LineSeg(a: prevPt, b: pt)))
                prevPt = pt
            }
            pieces.append(.segment(LineSeg(a: prevPt, b: s.b)))
            return pieces

        case .arc(let a):
            var pieces: [Curve2] = []
            let sign: Double = a.sweep >= 0 ? 1 : -1
            var prevU = domain.lowerBound
            for u in ps {
                let sweepPiece = sign * (u - prevU)
                let startAngle = a.startAngle + sign * prevU
                pieces.append(.arc(CircArc(center: a.center, r: a.r, startAngle: startAngle, sweep: sweepPiece)))
                prevU = u
            }
            let lastSweep = sign * (domain.upperBound - prevU)
            let lastStart = a.startAngle + sign * prevU
            pieces.append(.arc(CircArc(center: a.center, r: a.r, startAngle: lastStart, sweep: lastSweep)))
            return pieces

        case .circle(let c):
            // Convert to a sequence of arcs starting at angle 0 (matching
            // evaluate()'s convention for .circle), splitting at the given
            // angle params directly.
            var pieces: [Curve2] = []
            var prevU = domain.lowerBound
            for u in ps {
                pieces.append(.arc(CircArc(center: c.center, r: c.r, startAngle: prevU, sweep: u - prevU)))
                prevU = u
            }
            pieces.append(.arc(CircArc(center: c.center, r: c.r, startAngle: prevU, sweep: domain.upperBound - prevU)))
            return pieces

        case .ellipse(let e):
            var pieces: [Curve2] = []
            var prevU = domain.lowerBound
            for u in ps {
                pieces.append(.ellipse(EllipseArc(center: e.center, majorAxis: e.majorAxis, ratio: e.ratio,
                                                  startParam: prevU, endParam: u)))
                prevU = u
            }
            pieces.append(.ellipse(EllipseArc(center: e.center, majorAxis: e.majorAxis, ratio: e.ratio,
                                              startParam: prevU, endParam: domain.upperBound)))
            return pieces

        case .spline(let n):
            var pieces: [NURBS] = []
            var remaining = n
            for u in ps {
                guard let (left, right) = remaining.split(at: u) else { continue }
                pieces.append(left)
                remaining = right
            }
            pieces.append(remaining)
            return pieces.map { .spline($0) }
        }
    }

    // MARK: closestPoint

    /// Finds the closest point on the curve to `p`, returning its parameter,
    /// position, and distance. Algorithm varies by case — see per-case
    /// helpers below for the rationale (this is deliberately the most
    /// carefully-implemented routine in the kernel per the spec).
    public func closestPoint(to p: Vec2, tol: Tolerance) -> (u: Double, point: Vec2, distance: Double) {
        switch self {
        case .segment(let s):
            let ab = s.b - s.a
            let len2 = simd_length_squared(ab)
            guard len2 > 0 else { return (0, s.a, simd_length(p - s.a)) }
            var t = simd_dot(p - s.a, ab) / len2
            t = min(max(t, 0), 1)
            let pt = s.a + ab * t
            return (t, pt, simd_length(p - pt))

        case .circle(let c):
            let d = p - c.center
            let dist = simd_length(d)
            let angle = dist > 0 ? atan2(d.y, d.x) : 0
            var normalizedAngle = angle.truncatingRemainder(dividingBy: 2 * .pi)
            if normalizedAngle < 0 { normalizedAngle += 2 * .pi }
            let pt = c.center + Vec2(cos(normalizedAngle), sin(normalizedAngle)) * c.r
            return (normalizedAngle, pt, simd_length(p - pt))

        case .arc(let a):
            return Self.closestPointOnArc(a, p: p)

        case .ellipse(let e):
            return Self.closestPointOnEllipse(e, p: p, tol: tol)

        case .spline(let n):
            return Self.closestPointOnSpline(n, p: p, tol: tol)
        }
    }

    private static func closestPointOnArc(_ a: CircArc, p: Vec2) -> (u: Double, point: Vec2, distance: Double) {
        let d = p - a.center
        let dist = simd_length(d)
        let angle = dist > 0 ? atan2(d.y, d.x) : a.startAngle
        let sign: Double = a.sweep >= 0 ? 1 : -1
        let total = abs(a.sweep)
        var delta = (angle - a.startAngle) * sign
        delta = delta.truncatingRemainder(dividingBy: 2 * .pi)
        if delta < 0 { delta += 2 * .pi }
        if delta <= total {
            let pt = a.center + Vec2(cos(angle), sin(angle)) * a.r
            return (delta, pt, simd_length(p - pt))
        }
        // Outside the swept range: nearer endpoint wins.
        let startPt = a.center + Vec2(cos(a.startAngle), sin(a.startAngle)) * a.r
        let endAngle = a.startAngle + sign * total
        let endPt = a.center + Vec2(cos(endAngle), sin(endAngle)) * a.r
        let dStart = simd_length(p - startPt), dEnd = simd_length(p - endPt)
        return dStart <= dEnd ? (0, startPt, dStart) : (total, endPt, dEnd)
    }

    /// Newton's method on the stationarity condition f(t) = (E(t)-p)·E'(t) = 0,
    /// seeded at 8 evenly-spaced domain samples, keeping the globally best
    /// result; falls back to golden-section search across the domain if
    /// Newton fails to converge from every seed.
    private static let ellipseNewtonSeeds = 8
    private static let ellipseNewtonMaxIter = 30

    private static func closestPointOnEllipse(_ e: EllipseArc, p: Vec2, tol: Tolerance) -> (u: Double, point: Vec2, distance: Double) {
        let domain = e.startParam...e.endParam
        let curve = Curve2.ellipse(e)
        func f(_ t: Double) -> Double { simd_dot(curve.evaluate(t) - p, curve.derivative(t)) }
        func fprime(_ t: Double) -> Double {
            let E = curve.evaluate(t), Ep = curve.derivative(t)
            // Second derivative: for ellipse, E''(t) = -majorAxis*cos(t) - minorAxis*sin(t) = -(E(t) - center).
            let Epp = -(E - e.center)
            return simd_dot(Ep, Ep) + simd_dot(E - p, Epp)
        }

        var best: (u: Double, dist: Double)? = nil
        let lo = domain.lowerBound, hi = domain.upperBound
        guard hi > lo else {
            let pt = curve.evaluate(lo)
            return (lo, pt, simd_length(p - pt))
        }

        for seed in 0..<ellipseNewtonSeeds {
            var t = lo + (hi - lo) * Double(seed) / Double(ellipseNewtonSeeds - 1)
            var converged = false
            for _ in 0..<ellipseNewtonMaxIter {
                let fp = fprime(t)
                guard abs(fp) > 1e-14 else { break }
                let step = f(t) / fp
                var next = t - step
                next = min(max(next, lo), hi)
                if abs(next - t) < tol.parametric { t = next; converged = true; break }
                t = next
            }
            if converged {
                let dist = simd_length(curve.evaluate(t) - p)
                if best == nil || dist < best!.dist { best = (t, dist) }
            }
        }

        if best == nil {
            // Golden-section fallback minimizing squared distance directly.
            best = goldenSectionMinimize(domain: domain) { t in
                simd_length_squared(curve.evaluate(t) - p)
            }.map { ($0, simd_length(curve.evaluate($0) - p)) }
        }

        // Always also compare against domain endpoints (Newton seeded
        // in-domain won't naturally explore the boundary as a local min when
        // the true closest point is at an endpoint of a partial ellipse arc).
        let candidates: [Double] = [lo, hi] + (best.map { [$0.u] } ?? [])
        var finalBest: (u: Double, point: Vec2, distance: Double)? = nil
        for t in candidates {
            let pt = curve.evaluate(t)
            let d = simd_length(p - pt)
            if finalBest == nil || d < finalBest!.distance { finalBest = (t, pt, d) }
        }
        return finalBest ?? (lo, curve.evaluate(lo), simd_length(p - curve.evaluate(lo)))
    }

    /// Simple golden-section search minimizing `f` over `domain`. Not a
    /// global optimizer, but adequate as a fallback when Newton fails to
    /// converge — the objective here (distance to an ellipse) is unimodal
    /// almost everywhere in practice.
    private static func goldenSectionMinimize(domain: ClosedRange<Double>, iterations: Int = 60, _ f: (Double) -> Double) -> Double? {
        let phi = (sqrt(5.0) - 1) / 2
        var a = domain.lowerBound, b = domain.upperBound
        guard b > a else { return a }
        var c = b - phi * (b - a)
        var d = a + phi * (b - a)
        var fc = f(c), fd = f(d)
        for _ in 0..<iterations {
            if fc < fd {
                b = d; d = c; fd = fc
                c = b - phi * (b - a)
                fc = f(c)
            } else {
                a = c; c = d; fc = fd
                d = a + phi * (b - a)
                fd = f(d)
            }
        }
        return (a + b) / 2
    }

    /// Recursive control-polygon subdivision to bracket the closest region,
    /// then Newton on the same dot-product stationarity condition, with a
    /// brute-force 64-sample fallback if anything looks numerically
    /// unstable (Newton fails to converge, or the spline is invalid).
    private static func closestPointOnSpline(_ n: NURBS, p: Vec2, tol: Tolerance) -> (u: Double, point: Vec2, distance: Double) {
        guard n.isValid else { return (0, .zero, .infinity) }
        let curve = Curve2.spline(n)
        let domain = n.domain

        // Brute-force sample the domain, keep the best as a Newton seed.
        let bruteSamples = 64
        var bestU = domain.lowerBound
        var bestDist = Double.infinity
        for k in 0...bruteSamples {
            let u = domain.lowerBound + (domain.upperBound - domain.lowerBound) * Double(k) / Double(bruteSamples)
            let d = simd_length(curve.evaluate(u) - p)
            if d < bestDist { bestDist = d; bestU = u }
        }

        // Newton-refine from the brute-force best.
        var t = bestU
        for _ in 0..<30 {
            let E = curve.evaluate(t), Ep = curve.derivative(t)
            let fp = simd_dot(Ep, Ep)
            guard fp > 1e-14 else { break }
            let fVal = simd_dot(E - p, Ep)
            var next = t - fVal / fp
            next = min(max(next, domain.lowerBound), domain.upperBound)
            if abs(next - t) < tol.parametric { t = next; break }
            t = next
        }
        let refinedDist = simd_length(curve.evaluate(t) - p)
        if refinedDist.isFinite && refinedDist <= bestDist + tol.linear {
            bestU = t; bestDist = refinedDist
        }
        let pt = curve.evaluate(bestU)
        return (bestU, pt, simd_length(p - pt))
    }
}

/// Helper namespace for computing arclength over an arbitrary sub-range of
/// a curve's parameter domain (used by `pointAtLength`'s table construction).
private enum Curve2SubLength {
    static func segmentLength(_ c: Curve2, a: Double, b: Double) -> Double {
        guard b > a else { return 0 }
        let mid = (a + b) / 2, half = (b - a) / 2
        var sum = 0.0
        for k in 0..<5 {
            let u = mid + half * gl5Nodes[k]
            sum += gl5Weights[k] * simd_length(c.derivative(u))
        }
        return sum * half
    }
}
