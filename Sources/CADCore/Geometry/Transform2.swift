//
//  Transform2.swift
//  DWGViewer / Geometry
//
//  Phase 4.2 — a general 2x2-linear-plus-translation affine transform,
//  shared by MOVE/COPY/ROTATE/SCALE/MIRROR. Deliberately restricted to
//  CONFORMAL transforms (translation, rotation, uniform scale, mirror) —
//  exactly what those 5 commands guarantee — so `EntityTransform`'s
//  per-type math (Editing/EntityTransform.swift) can assume angles and
//  aspect ratios are preserved except for an overall mirror flip, and
//  never has to handle a general shear/non-uniform-scale case.
//

import Foundation
import simd

/// 2D affine transform: `p' = M * p + t`, where `M` is a 2x2 linear part
/// and `t` a translation. Conformal by construction (every factory below
/// produces a pure translation/rotation/uniform-scale/mirror or composition
/// thereof) — `EntityTransform` relies on this to keep circles circular,
/// arcs' sweep magnitude unchanged, etc.
public struct Transform2: Equatable, Sendable {
    public var m11: Double, m12: Double
    public var m21: Double, m22: Double
    public var tx: Double, ty: Double

    public init(m11: Double, m12: Double, m21: Double, m22: Double, tx: Double, ty: Double) {
        self.m11 = m11
        self.m12 = m12
        self.m21 = m21
        self.m22 = m22
        self.tx = tx
        self.ty = ty
    }

    public static let identity = Transform2(m11: 1, m12: 0, m21: 0, m22: 1, tx: 0, ty: 0)

    // MARK: - Factories

    public static func translation(dx: Double, dy: Double) -> Transform2 {
        Transform2(m11: 1, m12: 0, m21: 0, m22: 1, tx: dx, ty: dy)
    }

    // Rotation by `angleRad` (CCW, radians) about `pivot`.
    public static func rotation(about pivot: Vec2, angleRad: Double) -> Transform2 {
        let c = cos(angleRad), s = sin(angleRad)
        // p' = R*(p - pivot) + pivot = R*p + (pivot - R*pivot)
        let tx = pivot.x - (c * pivot.x - s * pivot.y)
        let ty = pivot.y - (s * pivot.x + c * pivot.y)
        return Transform2(m11: c, m12: -s, m21: s, m22: c, tx: tx, ty: ty)
    }

    /// Uniform scale by `factor` about `pivot`. `factor` may be negative
    /// (a point reflection through `pivot`, still conformal — `isMirroring`
    /// correctly reports `true` in that case since det = factor*factor...
    /// NOTE: a negative uniform factor has POSITIVE determinant (factor^2 > 0)
    /// so it is NOT flagged as mirroring; it is a proper (orientation-
    /// preserving) 180-degree-rotation-equivalent scale, which is correct —
    /// AutoCAD SCALE never accepts a negative factor in the first place
    /// (`EntityTransform`/the command layer rejects factor <= 0 before this
    /// is ever constructed), so this branch only matters for direct unit
    /// testing of the factory itself.
    public static func scaling(about pivot: Vec2, factor: Double) -> Transform2 {
        let tx = pivot.x - factor * pivot.x
        let ty = pivot.y - factor * pivot.y
        return Transform2(m11: factor, m12: 0, m21: 0, m22: factor, tx: tx, ty: ty)
    }

    /// Reflection across the infinite line through `a` and `b`. Degenerate
    /// (a == b) falls back to identity — callers should reject a zero-length
    /// mirror line before this point (the command layer does).
    public static func mirror(across a: Vec2, _ b: Vec2) -> Transform2 {
        let d = b - a
        let len2 = simd_length_squared(d)
        guard len2 > 1e-18 else { return .identity }
        // Reflection matrix across a line through the origin with direction
        // (dx,dy): R = 1/len2 * [[dx^2-dy^2, 2*dx*dy], [2*dx*dy, dy^2-dx^2]].
        let dx = d.x, dy = d.y
        let m11 = (dx * dx - dy * dy) / len2
        let m12 = (2 * dx * dy) / len2
        let m21 = m12
        let m22 = (dy * dy - dx * dx) / len2
        // Translate so the line passes through the origin, reflect, translate back.
        let tx = a.x - (m11 * a.x + m12 * a.y)
        let ty = a.y - (m21 * a.x + m22 * a.y)
        return Transform2(m11: m11, m12: m12, m21: m21, m22: m22, tx: tx, ty: ty)
    }

    // MARK: - Application

    public func apply(_ p: Vec2) -> Vec2 {
        Vec2(m11 * p.x + m12 * p.y + tx, m21 * p.x + m22 * p.y + ty)
    }

    /// Applies only the linear part (no translation) — for transforming
    /// direction/axis vectors (e.g. an ellipse's major-axis vector) where
    /// translation must not apply.
    public func applyLinear(_ v: Vec2) -> Vec2 {
        Vec2(m11 * v.x + m12 * v.y, m21 * v.x + m22 * v.y)
    }

    // MARK: - Properties

    public var determinant: Double { m11 * m22 - m12 * m21 }

    /// True if this transform reverses orientation (a mirror, alone or
    /// composed with anything else) — det < 0. Zero-determinant (fully
    /// degenerate, shouldn't occur for any of the 5 commands' factories
    /// above with valid input) is NOT reported as mirroring.
    public var isMirroring: Bool { determinant < 0 }

    /// Magnitude of the uniform scale factor this transform applies,
    /// computed as sqrt(|det|) — correct for any composition of
    /// rotation/uniform-scale/mirror (all conformal), meaningless if the
    /// transform were sheared/non-uniformly scaled (never constructed here).
    public var uniformScale: Double { sqrt(abs(determinant)) }

    /// The rotation angle (radians, CCW) this transform applies to a
    /// direction vector — `atan2` of the transformed +X basis vector. For a
    /// pure rotation this recovers the exact input angle. **For a mirror
    /// transform this is DOUBLE the mirror line's own angle, not the mirror
    /// line's angle itself**: a reflection-across-θ_line matrix is
    /// `[[cos2θ,sin2θ],[sin2θ,-cos2θ]]`, so `atan2(m21,m11) = 2·θ_line`.
    /// Per-type mirror math (arc/text/mtext/insert rotation reflection —
    /// see `EntityTransform.apply`) uses this value directly as `alpha` in
    /// `θ' = alpha − θ` — do NOT re-double it there; an earlier version of
    /// that code did exactly that (`2 * alpha − θ`) and was wrong for any
    /// non-horizontal mirror line, caught by adversarial review.
    public var rotationAngle: Double { atan2(m21, m11) }

    // MARK: - Composition

    /// Composes `self` then `other` (i.e. `other.apply(self.apply(p))`) —
    /// standard left-to-right transform composition order matching how a
    /// caller reads "first do self, then do other."
    public func then(_ other: Transform2) -> Transform2 {
        Transform2(
            m11: other.m11 * m11 + other.m12 * m21,
            m12: other.m11 * m12 + other.m12 * m22,
            m21: other.m21 * m11 + other.m22 * m21,
            m22: other.m21 * m12 + other.m22 * m22,
            tx: other.m11 * tx + other.m12 * ty + other.tx,
            ty: other.m21 * tx + other.m22 * ty + other.ty
        )
    }
}
