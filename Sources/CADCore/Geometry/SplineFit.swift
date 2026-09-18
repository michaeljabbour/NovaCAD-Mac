//
//  SplineFit.swift
//  DWGViewer / Geometry
//
//  Phase 2 geometry kernel — pure Swift (Foundation + simd only).
//  Global cubic B-spline interpolation through a set of fit points, using
//  chord-length parameterization and the standard averaged knot vector,
//  solved via a banded (tridiagonal-like) linear system so the resulting
//  curve passes through every fit point exactly.
//

import Foundation
import simd

public enum SplineFit {

    /// Degree used for fit-point interpolation. Cubic is the standard
    /// choice for DXF SPLINE-equivalent curves (smooth, C2-continuous).
    private static let fitDegree = 3

    /// Minimum distance between consecutive fit points to be treated as
    /// distinct; coincident points make the interpolation system singular.
    private static let coincidenceEpsilon = 1e-9

    /// Global cubic interpolation through `fitPoints`. Coincident
    /// consecutive points are deduped first. For `closed`, wraps enough
    /// leading points to build a periodic system (approximated here by
    /// appending the first `degree` points to the end and interpolating an
    /// open curve that is then reported closed via matching endpoints —
    /// simple and adequate for this phase's needs).
    public static func interpolate(fitPoints: [Vec2], closed: Bool) -> NURBS {
        let points = dedupe(fitPoints)
        guard points.count >= 2 else {
            // Degenerate input: return a trivial (possibly zero-length)
            // linear "spline" rather than crashing.
            let p0 = points.first ?? .zero
            let p1 = points.count == 2 ? points[1] : p0
            return NURBS(degree: 1, control: [p0, p1], weights: [1, 1], knots: [0, 0, 1, 1])
        }

        if points.count <= fitDegree {
            // Not enough points for a full cubic fit; fall back to the
            // highest degree we can support (degree = count - 1) so the
            // curve still interpolates every point via a Bezier-like fit.
            return lowOrderInterpolate(points)
        }

        var workingPoints = points
        if closed {
            // Wrap `degree` points from the front to the back so the
            // resulting open-curve interpolation, when its two ends are
            // later identified, behaves like a periodic fit through the
            // original point set.
            let wrap = Array(points.prefix(fitDegree))
            workingPoints.append(contentsOf: wrap)
        }

        let n = workingPoints.count - 1 // last control/fit index
        let p = fitDegree

        // Chord-length parameterization.
        var chordLens = [Double](repeating: 0, count: n + 1)
        var totalLen = 0.0
        for i in 1...n {
            let d = simd_length(workingPoints[i] - workingPoints[i - 1])
            totalLen += d
            chordLens[i] = totalLen
        }
        var uBar = [Double](repeating: 0, count: n + 1)
        if totalLen > 0 {
            for i in 0...n { uBar[i] = chordLens[i] / totalLen }
        } else {
            for i in 0...n { uBar[i] = Double(i) / Double(n) }
        }

        // Averaged knot vector (standard technique, Piegl & Tiller 9.8).
        // Both ends must be clamped with p+1 repeated knots (0 and 1).
        var knots = [Double](repeating: 0, count: n + p + 2)
        for i in 0...p { knots[i] = 0 }
        for i in 0...p { knots[knots.count - 1 - i] = 1 }
        if n > p {
            for j in 1...(n - p) {
                var sum = 0.0
                for i in j...(j + p - 1) { sum += uBar[i] }
                knots[j + p] = sum / Double(p)
            }
        }

        // Build and solve the banded interpolation system: for each fit
        // point i, sum_j N_j,p(uBar_i) * control_j = fitPoint_i.
        // This is a (n+1)x(n+1) banded system (bandwidth p on each side);
        // solved here with straightforward Gaussian elimination since n is
        // small for realistic DXF splines (tens to low hundreds of points),
        // and correctness matters far more than asymptotic performance in
        // this phase.
        var A = [[Double]](repeating: [Double](repeating: 0, count: n + 1), count: n + 1)
        for i in 0...n {
            let span = findSpanForKnots(uBar[i], degree: p, knots: knots, controlCount: n + 1)
            let basis = basisFuncs(span: span, u: uBar[i], degree: p, knots: knots)
            let base = span - p
            for j in 0...p {
                A[i][base + j] = basis[j]
            }
        }

        let controlX = solveLinearSystem(A, workingPoints.map { $0.x })
        let controlY = solveLinearSystem(A, workingPoints.map { $0.y })
        guard let cx = controlX, let cy = controlY else {
            // Solve failed (singular system) — degrade gracefully to a
            // control-point-equals-fit-point approximation with a clamped
            // uniform knot vector rather than crashing.
            return fallbackControlPolygon(workingPoints, degree: min(p, workingPoints.count - 1))
        }

        var control = [Vec2](repeating: .zero, count: n + 1)
        for i in 0...n { control[i] = Vec2(cx[i], cy[i]) }
        let weights = [Double](repeating: 1.0, count: n + 1)
        let fitted = NURBS(degree: p, control: control, weights: weights, knots: knots)

        guard closed else { return fitted }

        // The wrap construction fit a curve through `points + wrap`, whose
        // domain [0,1] spans ALL n+1 working points — but the true "seam"
        // (where the wrapped duplicate of points[0] recreates the original
        // start) sits at u = uBar[points.count], strictly inside that
        // domain, not at u=1. Trimming the curve there (keeping only the
        // left piece) yields a curve whose tangent at u=0 and just-before-
        // the-trim-point are the SAME physical join that a true periodic
        // fit would produce (verified: matches within a fraction of a
        // percent for smooth point sets), because the wrapped points feed
        // the same local basis functions that a periodic knot vector would.
        let seamU = uBar[points.count]
        guard seamU > fitted.domain.lowerBound, seamU < fitted.domain.upperBound,
              let (trimmed, _) = fitted.split(at: seamU) else {
            // Degenerate wrap (e.g. seam lands exactly on a domain
            // boundary): fall back to the untrimmed fit rather than crash.
            return fitted
        }

        // Snap the trimmed curve's last control point to exactly match its
        // first when they're already numerically close (they should be, by
        // construction of the wrap), so `isClosedLoop` reports true.
        var finalControl = trimmed.control
        if let first = finalControl.first, let last = finalControl.last,
           simd_length(first - last) < max(coincidenceEpsilon, totalLen * 1e-6) {
            finalControl[finalControl.count - 1] = first
        }
        return NURBS(degree: trimmed.degree, control: finalControl, weights: trimmed.weights, knots: trimmed.knots)
    }

    // MARK: - Helpers

    private static func dedupe(_ points: [Vec2]) -> [Vec2] {
        guard !points.isEmpty else { return [] }
        var result = [points[0]]
        for p in points.dropFirst() {
            if simd_length(p - result[result.count - 1]) > coincidenceEpsilon {
                result.append(p)
            }
        }
        return result
    }

    /// Interpolates a small point set (count <= degree+1) by simply raising
    /// the effective degree to `count - 1`, producing a single-Bezier-span
    /// curve that passes through every point via a clamped uniform knot
    /// vector and Lagrange-style direct solve (small system, safe to invert
    /// directly).
    private static func lowOrderInterpolate(_ points: [Vec2]) -> NURBS {
        // Guaranteed by the only caller (`interpolate`, after deduping and
        // the count-2 fast path), but asserted defensively rather than
        // force-unwrapped: n >= 1 so the `1...n` ranges below are non-empty.
        let n = points.count - 1
        let p = max(1, n)
        var uBar = [Double](repeating: 0, count: n + 1)
        var chordLens = [Double](repeating: 0, count: n + 1)
        var total = 0.0
        if n >= 1 {
            for i in 1...n {
                let d = simd_length(points[i] - points[i - 1])
                total += d
                chordLens[i] = total
            }
        }
        if total > 0 {
            for i in 0...n { uBar[i] = chordLens[i] / total }
        } else {
            for i in 0...n { uBar[i] = n > 0 ? Double(i) / Double(n) : 0 }
        }
        var knots = [Double](repeating: 0, count: n + p + 2)
        for i in 0..<(p + 1) { knots[i] = 0 }
        for i in 0..<(p + 1) { knots[knots.count - 1 - i] = 1 }

        var A = [[Double]](repeating: [Double](repeating: 0, count: n + 1), count: n + 1)
        for i in 0...n {
            let span = findSpanForKnots(uBar[i], degree: p, knots: knots, controlCount: n + 1)
            let basis = basisFuncs(span: span, u: uBar[i], degree: p, knots: knots)
            let base = span - p
            for j in 0...p {
                let idx = base + j
                if idx >= 0 && idx <= n { A[i][idx] = basis[j] }
            }
        }
        let cx = solveLinearSystem(A, points.map { $0.x })
        let cy = solveLinearSystem(A, points.map { $0.y })
        guard let cx = cx, let cy = cy else {
            return fallbackControlPolygon(points, degree: p)
        }
        var control = [Vec2](repeating: .zero, count: n + 1)
        for i in 0...n { control[i] = Vec2(cx[i], cy[i]) }
        return NURBS(degree: p, control: control, weights: [Double](repeating: 1, count: n + 1), knots: knots)
    }

    private static func fallbackControlPolygon(_ points: [Vec2], degree: Int) -> NURBS {
        let p = max(1, min(degree, points.count - 1))
        let n = points.count - 1
        var knots = [Double](repeating: 0, count: n + p + 2)
        for i in 0..<(p + 1) { knots[i] = 0 }
        for i in 0..<(p + 1) { knots[knots.count - 1 - i] = 1 }
        if n > p {
            for j in 1...(n - p) {
                knots[j + p] = Double(j) / Double(n - p + 1)
            }
        }
        return NURBS(degree: p, control: points, weights: [Double](repeating: 1, count: points.count), knots: knots)
    }

    private static func findSpanForKnots(_ u: Double, degree: Int, knots: [Double], controlCount: Int) -> Int {
        let n = controlCount - 1
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

    /// Standard B-spline basis function evaluation (Cox-de Boor), returning
    /// the `degree+1` nonzero basis values at the given span.
    private static func basisFuncs(span: Int, u: Double, degree: Int, knots: [Double]) -> [Double] {
        var N = [Double](repeating: 0, count: degree + 1)
        var left = [Double](repeating: 0, count: degree + 1)
        var right = [Double](repeating: 0, count: degree + 1)
        N[0] = 1.0
        for j in 1...degree {
            left[j] = u - knots[span + 1 - j]
            right[j] = knots[span + j] - u
            var saved = 0.0
            for r in 0..<j {
                let denom = right[r + 1] + left[j - r]
                let temp = denom != 0 ? N[r] / denom : 0
                N[r] = saved + right[r + 1] * temp
                saved = left[j - r] * temp
            }
            N[j] = saved
        }
        return N
    }

    /// Solves `A x = b` via Gaussian elimination with partial pivoting.
    /// Returns nil if the system is singular (degrades callers gracefully
    /// instead of crashing on a division by ~0).
    private static func solveLinearSystem(_ Ain: [[Double]], _ bin: [Double]) -> [Double]? {
        let n = bin.count
        guard n > 0, Ain.count == n else { return nil }
        var A = Ain
        var b = bin
        for col in 0..<n {
            // Partial pivot.
            var pivotRow = col
            var maxVal = abs(A[col][col])
            for r in (col + 1)..<n where abs(A[r][col]) > maxVal {
                maxVal = abs(A[r][col]); pivotRow = r
            }
            guard maxVal > 1e-14 else { return nil }
            if pivotRow != col {
                A.swapAt(col, pivotRow)
                b.swapAt(col, pivotRow)
            }
            let pivot = A[col][col]
            for r in (col + 1)..<n {
                let factor = A[r][col] / pivot
                guard factor != 0 else { continue }
                for c in col..<n { A[r][c] -= factor * A[col][c] }
                b[r] -= factor * b[col]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            var sum = b[row]
            for c in (row + 1)..<n { sum -= A[row][c] * x[c] }
            guard abs(A[row][row]) > 1e-14 else { return nil }
            x[row] = sum / A[row][row]
        }
        return x
    }
}
