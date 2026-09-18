//
//  SplineEvaluator.swift
//  DWGViewer
//
//  Tessellates DXF SPLINE entities (NURBS curves) into polyline points
//  for rendering. Pure Swift; depends only on Foundation and CoreGraphics.
//
//  Refactored (Phase 2 geometry kernel) to delegate the actual de Boor
//  evaluation to Geometry/Curve.swift's `NURBS` type, rather than
//  duplicating the recursion here a second time. This file now only
//  handles: input validation/fallback (preserving the exact historical
//  behavior for malformed input), CGPoint <-> Vec2 bridging, and sampling
//  the shared parameter domain at evenly-spaced points. The public
//  signature and behavior are unchanged — this is a drop-in refactor.
//

import Foundation
import CoreGraphics

public enum SplineEvaluator {

    /// Tessellates a NURBS curve into `samples` points (inclusive of both ends).
    /// - Parameters:
    ///   - controlPoints: the control net (DXF codes 10/20), count n+1
    ///   - knots: knot vector (DXF code 40 repeated), count should be n+degree+2;
    ///     if the count is wrong or knots are non-monotonic, falls back to
    ///     returning the control points themselves (degenerate but visible).
    ///   - weights: optional rational weights (DXF code 41); nil or count
    ///     mismatch means all weights are treated as 1.0
    ///   - degree: curve degree (DXF code 71), clamped to 1...15
    ///   - samples: number of output points, clamped to 2...512
    public static func tessellate(controlPoints: [CGPoint],
                           knots: [Double],
                           weights: [Double]?,
                           degree: Int,
                           samples: Int) -> [CGPoint] {
        // --- Guards -------------------------------------------------------
        // Preserved exactly from the pre-refactor implementation so
        // malformed-input behavior (returning the raw control points) is
        // unchanged for callers.
        let pointCount = controlPoints.count
        guard pointCount >= 2 else { return controlPoints }

        var p = min(max(degree, 1), 15)
        if p >= pointCount { p = pointCount - 1 }
        guard p >= 1 else { return controlPoints }

        // A valid clamped knot vector has (n+1) + degree + 1 entries.
        guard knots.count == pointCount + p + 1 else { return controlPoints }

        // Knots must be non-decreasing (this check also rejects NaNs).
        for i in 1..<knots.count where !(knots[i] >= knots[i - 1]) {
            return controlPoints
        }

        // Valid parameter domain of a clamped B-spline.
        let tStart = knots[p]
        let tEnd = knots[knots.count - 1 - p]
        guard tEnd > tStart else { return controlPoints }

        // Rational weights: use only if the count matches exactly.
        let effectiveWeights: [Double]
        if let w = weights, w.count == pointCount {
            effectiveWeights = w
        } else {
            effectiveWeights = [Double](repeating: 1.0, count: pointCount)
        }

        let sampleCount = min(max(samples, 2), 512)

        // --- Evaluation via the shared geometry kernel ---------------------
        let control = controlPoints.map { Vec2($0) }
        let nurbs = NURBS(degree: p, control: control, weights: effectiveWeights, knots: knots)
        guard nurbs.isValid else { return controlPoints }

        var result = [CGPoint]()
        result.reserveCapacity(sampleCount)
        let step = (tEnd - tStart) / Double(sampleCount - 1)
        for s in 0..<sampleCount {
            // Force the exact end knot for the last sample so the curve
            // terminates exactly at the last control point (matches the
            // pre-refactor behavior bit-for-bit rather than relying on
            // floating-point step accumulation to land exactly on tEnd).
            let t = (s == sampleCount - 1) ? tEnd : tStart + Double(s) * step
            result.append(nurbs.evaluate(t).cgPoint)
        }
        return result
    }
}
