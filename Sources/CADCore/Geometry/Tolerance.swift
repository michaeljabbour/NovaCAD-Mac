//
//  Tolerance.swift
//  DWGViewer / Geometry
//
//  Phase 2 geometry kernel — pure Swift (Foundation + simd only).
//  Shared numeric-tolerance bundle threaded through every curve/intersection/
//  offset routine so callers don't hard-code magic epsilons at call sites.
//

import Foundation
import simd

/// 2D point/vector type used throughout the geometry kernel.
public typealias Vec2 = SIMD2<Double>

/// A bundle of numeric tolerances used across the geometry kernel.
///
/// All three fields are drawing-unit / radian thresholds, not percentages —
/// callers are expected to derive `linear` from the drawing's own extents via
/// `forExtents(diagonal:)` so behavior scales sensibly across a drawing that
/// spans millimeters vs. one that spans kilometers.
public struct Tolerance {
    /// Point-coincidence threshold, in drawing units.
    public var linear: Double

    /// Angular coincidence threshold, in radians.
    /// 1e-9 rad is far tighter than any visually-meaningful angular gap.
    public var angular: Double = 1e-9

    /// Newton-iteration convergence threshold on a curve parameter.
    public var parametric: Double = 1e-12

    public init(linear: Double, angular: Double = 1e-9, parametric: Double = 1e-12) {
        self.linear = linear
        self.angular = angular
        self.parametric = parametric
    }

    /// Lower clamp on `linear` — below this, floating-point noise in
    /// double-precision coordinate math dominates the tolerance itself.
    private static let minLinear = 1e-9

    /// Upper clamp on `linear` — beyond this, snapping/intersection would
    /// merge features that are visibly distinct even on huge drawings.
    private static let maxLinear = 1e-4

    /// Derives a sensible `linear` tolerance from a drawing's bounding-box
    /// diagonal, clamped to a sane absolute range.
    public static func forExtents(diagonal: Double) -> Tolerance {
        let raw = diagonal * 1e-9
        let clamped = min(max(raw, minLinear), maxLinear)
        return Tolerance(linear: clamped)
    }
}
