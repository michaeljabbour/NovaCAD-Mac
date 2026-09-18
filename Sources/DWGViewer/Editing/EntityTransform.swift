//
//  EntityTransform.swift
//  DWGViewer / Editing
//
//  Phase 4.2 — applies a conformal `Transform2` (translation/rotation-about/
//  scaling-about/mirror-across, or any composition thereof) to an
//  `EntityPayloadCopy`, per DXF-type rules. This is the single shared engine
//  behind MOVE/COPY/ROTATE/SCALE/MIRROR: MOVE is `.translation`, ROTATE is
//  `.rotation(about:angleRad:)`, SCALE is `.scaling(about:factor:)` (uniform
//  only — the command layer rejects non-uniform/negative-or-zero factors
//  before ever constructing the transform), MIRROR is `.mirror(across:_:)`.
//  COPY applies whichever of the above the user picked (a plain COPY with no
//  rotation/scale is `.translation`), then `Transaction.add`s the result
//  instead of overwriting the original via `Transaction.modifyPayload`.
//
//  `EntityPayloadCopy.translate(dx:dy:)` (EntityStore.swift) already covers
//  pure translation for every payload case generically (every world-space
//  point moves by the same delta, correct for MOVE/COPY-without-rotation).
//  This file's `apply(_:to:mirrtext:)` is is the generalization that ALSO
//  handles rotation/non-1.0 uniform scale/mirroring correctly, including the
//  per-type special cases the plan calls out explicitly:
//    - circle: radius *= transform.uniformScale (center transforms as a point)
//    - arc mirror: swaps reflected start/end angles (θ' = α − θ, where α is
//      `Transform2.rotationAngle` — already 2x the mirror line's own angle
//      for a reflection matrix, see the arc case's inline comment) to stay CCW
//    - polyline mirror: negates every bulge (arc sense flips under a
//      reflection; magnitude is preserved by the endpoint-distance change)
//    - ellipse: majorAxis maps as a vector (not a point) from the ALREADY-
//      transformed center; mirror swaps/negates start/end params
//    - spline: control points map as points (affine-invariant NURBS
//      property — weights/knots are untouched)
//    - text: anchor maps as a point, height *= uniformScale, rotation +=
//      transform.rotationAngle (or the MIRRTEXT re-normalization/backwards
//      branch below when transform.isMirroring)
//    - insert: position maps as a point, scale.x *= -1 on a mirror (the
//      standard DXF encoding for a mirrored block reference), rotation
//      composes with the transform's rotation the same way as text
//

import Foundation
import CADCore
import simd

enum EntityTransform {

    /// Applies `t` to `copy` in place, per DXF-type rules. `mirrtext`
    /// (mirrors the $MIRRTEXT header variable / MIRRTEXT sysvar) only
    /// matters when `t.isMirroring`: `false` (AutoCAD default) re-normalizes
    /// text rotation/alignment so mirrored text stays readable; `true`
    /// renders it genuinely backwards (see `TextPayload.isBackwards`).
    static func apply(_ t: Transform2, to copy: inout EntityPayloadCopy, mirrtext: Bool) {
        func tp(_ v: Vec3) -> Vec3 {
            let p = t.apply(Vec2(v.x, v.y))
            return Vec3(x: p.x, y: p.y, z: v.z)
        }

        switch copy {
        case .line(var p):
            p.a = tp(p.a); p.b = tp(p.b)
            copy = .line(p)

        case .point(var p):
            p.p = tp(p.p)
            copy = .point(p)

        case .circle(var p):
            p.center = tp(p.center)
            p.radius *= t.uniformScale
            copy = .circle(p)

        case .arc(var p):
            let newCenter = tp(p.center)
            let newRadius = p.radius * t.uniformScale
            if t.isMirroring {
                // Reflecting a CCW arc reverses its traversal sense. To stay
                // CCW (this kernel's universal convention — see Curve.swift/
                // CircArc's doc comment), swap start/end AND reflect each
                // through the mirror line's angle θ_line: θ' = 2·θ_line − θ.
                // IMPORTANT: `t.rotationAngle` (`atan2(m21, m11)`) for a
                // mirror transform's matrix is ALREADY `2·θ_line`, not
                // `θ_line` — a mirror-across-θ_line matrix is
                // [[cos2θ,sin2θ],[sin2θ,-cos2θ]], so atan2(sin2θ, cos2θ) = 2θ.
                // The reflection formula in terms of the ALREADY-doubled
                // `alpha` is therefore `θ' = alpha − θ`, not `2·alpha − θ`
                // (an adversarial review caught this exact double-counting
                // bug, confirmed by two independent numeric re-derivations —
                // the earlier `2 * alpha - θ` formula only coincidentally
                // matched for a horizontal mirror line, where alpha = 0).
                let alpha = t.rotationAngle
                let newStart = alpha - p.endAngleDeg * .pi / 180
                let newEnd = alpha - p.startAngleDeg * .pi / 180
                p.startAngleDeg = newStart * 180 / .pi
                p.endAngleDeg = newEnd * 180 / .pi
            } else {
                let rot = t.rotationAngle * 180 / .pi
                p.startAngleDeg += rot
                p.endAngleDeg += rot
            }
            p.center = newCenter
            p.radius = newRadius
            copy = .arc(p)

        case .ellipse(var p):
            let newCenter = tp(p.center)
            let newMajor = t.applyLinear(Vec2(p.majorAxisEndpoint.x, p.majorAxisEndpoint.y))
            p.center = newCenter
            p.majorAxisEndpoint = Vec3(x: newMajor.x, y: newMajor.y, z: p.majorAxisEndpoint.z)
            if t.isMirroring {
                // Unlike Curve2.reversed() (which keeps majorAxis FIXED and
                // encodes reversal purely via a negative `ratio`), here
                // majorAxisEndpoint is ALREADY being remapped through the
                // mirror above — so the minor-axis vector perp(newMajor)*ratio
                // needs newMajor's post-mirror direction, not a sign flip on
                // ratio. Direct derivation (point-mapping identity
                // M(center + major*cos(u) + minor*sin(u)) must equal
                // newCenter + newMajor*cos(u') + newMinor*sin(u') for
                // u' = -u, using minor = perp(major)*ratio and the fact that
                // for a reflection M, M(perp(v)) = -perp(M(v))): newMinor =
                // -M(minor) = -M(perp(major)*ratio) = -(-perp(M(major)))*ratio
                // = perp(newMajor)*ratio — i.e. `ratio`'s sign is UNCHANGED,
                // only params remap. u' = -u reverses traversal order, so to
                // keep startParam <= endParam, start'=-end, end'=-start.
                // Verified against a from-scratch point-evaluation
                // cross-check (not merely re-deriving the same formula) in
                // EntityTransformTests.
                let newStart = -p.endParam
                let newEnd = -p.startParam
                p.startParam = newStart
                p.endParam = newEnd
            }
            // Non-mirroring rotation/scale: majorAxisEndpoint already carries
            // the rotation (via applyLinear) and scale (via its length
            // changing proportionally) — startParam/endParam are angles
            // measured relative to the axis itself, so they need no
            // adjustment when the transform preserves orientation.
            copy = .ellipse(p)

        case .polyline(var p, var verts, var bulges):
            for i in verts.indices { verts[i] = tp(verts[i]) }
            if t.isMirroring {
                // A reflected arc segment sweeps the opposite sense; bulge's
                // sign encodes sweep direction (positive = CCW), so every
                // bulge negates. Magnitude (curvature relative to the new,
                // transform-scaled chord length) needs no separate scaling:
                // bulge is a dimensionless ratio (tan(sweep/4)) purely a
                // function of the sweep ANGLE, which mirroring/rotating/
                // uniformly scaling never changes in magnitude, only sign
                // under a mirror. Verified by bulge->arc->bulge round-trip
                // in EntityTransformTests.
                for i in bulges.indices { bulges[i] = -bulges[i] }
            }
            // constantWidth is a linear dimension (drawing units), so it
            // scales with the transform like any other length; closed/
            // elevation carry no coordinate data needing transformation
            // (elevation is a Z-plane constant, untouched by a 2D
            // transform, matching `translate(dx:dy:)`'s existing behavior).
            p.constantWidth *= t.uniformScale
            copy = .polyline(p, vertices: verts, bulges: bulges)

        case .spline(let p, var control, let knots, let weights):
            // Control points map as points (affine invariance of B-splines —
            // transforming every control point by an affine map is
            // equivalent to transforming the curve itself); degree/knots/
            // weights/closed are purely structural and untouched, exactly
            // like `translate(dx:dy:)`'s existing spline case.
            for i in control.indices { control[i] = tp(control[i]) }
            copy = .spline(p, control: control, knots: knots, weights: weights)

        case .text(var p):
            p.position = tp(p.position)
            p.alignPosition = tp(p.alignPosition)
            p.height *= t.uniformScale
            applyTextRotationAndMirror(&p, t, mirrtext: mirrtext)
            copy = .text(p)

        case .mtext(var p):
            p.insertion = tp(p.insertion)
            p.height *= t.uniformScale
            if p.refWidth > 0 { p.refWidth *= t.uniformScale }
            if t.isMirroring {
                // See the arc case above for why this is `alpha - θ`, not
                // `2 * alpha - θ`: `t.rotationAngle` is already 2x the
                // mirror line's angle for a reflection transform.
                let alpha = t.rotationAngle * 180 / .pi
                p.rotationDeg = alpha - p.rotationDeg
            } else {
                p.rotationDeg += t.rotationAngle * 180 / .pi
            }
            copy = .mtext(p)

        case .insert(var p):
            p.position = tp(p.position)
            if t.isMirroring {
                // Standard DXF encoding for a mirrored block reference:
                // negate the X scale and reflect rotation through the
                // mirror's axis angle, exactly like the text/mtext branches
                // above — this is what makes the render path's existing
                // ctx.mirrored (extrusion/scale-sign-driven) block-content
                // handling activate correctly for a block MIRRORed as a
                // whole, without needing any renderer changes.
                // See the arc case above for why this is `alpha - θ`, not
                // `2 * alpha - θ`: `t.rotationAngle` is already 2x the
                // mirror line's angle for a reflection transform.
                let alpha = t.rotationAngle * 180 / .pi
                p.scale.x *= -1
                p.rotationDeg = alpha - p.rotationDeg
            } else {
                p.rotationDeg += t.rotationAngle * 180 / .pi
                p.scale.x *= t.uniformScale
                p.scale.y *= t.uniformScale
                p.scale.z *= t.uniformScale
            }
            copy = .insert(p)

        case .hatch(var p, var loops):
            p.origin = tp(p.origin)
            for i in loops.indices { for j in loops[i].indices { loops[i][j] = tp(loops[i][j]) } }
            if t.isMirroring {
                // A reflected hatch boundary loop's winding sense flips;
                // reversing point order keeps the loop's winding consistent
                // with its original orientation for the even-odd fill rule
                // used at render time (order doesn't affect the outline
                // shape itself, only traversal direction).
                for i in loops.indices { loops[i].reverse() }
            }
            p.angle += t.rotationAngle * 180 / .pi
            p.scale *= t.uniformScale
            copy = .hatch(p, loops: loops)

        case .image(var p):
            p.origin = tp(p.origin)
            p.uVector = Vec3(t.applyLinear(Vec2(p.uVector.x, p.uVector.y)), z: p.uVector.z)
            p.vVector = Vec3(t.applyLinear(Vec2(p.vVector.x, p.vVector.y)), z: p.vVector.z)
            copy = .image(p)

        case .viewport(var p):
            p.centerPaper = tp(p.centerPaper)
            copy = .viewport(p)

        case .dimension(var p):
            p.defPoint = tp(p.defPoint)
            copy = .dimension(p)

        case .unknown:
            break
        }
    }

    /// Text rotation/alignment under a transform. Non-mirroring: rotation
    /// simply accumulates the transform's rotation angle (matches arc/mtext/
    /// insert's non-mirror branches). Mirroring: reflects rotation through
    /// the mirror axis angle α (θ' = α − θ, same formula as arc/mtext/
    /// insert — see `EntityTransform.apply`'s arc case for why α, which is
    /// `Transform2.rotationAngle`, is not doubled again here), then branches
    /// on MIRRTEXT:
    ///   - MIRRTEXT=0 (AutoCAD default, `mirrtext == false`): re-normalize so
    ///     the glyphs stay upright/readable — AutoCAD's actual behavior is
    ///     to flip the alignment (left<->right) rather than the rotation
    ///     itself when the net effect would otherwise be upside-down/
    ///     backwards text; this mirrors the EXISTING render-time
    ///     block-content handling in Regenerator.swift's `ctx.mirrored`
    ///     branch (hAlign 0<->2 swap, rotation renormalized), so a MIRRORed
    ///     standalone TEXT entity with MIRRTEXT=0 looks pixel-identical to
    ///     the pre-existing "TEXT inside a mirrored block" rendering.
    ///   - MIRRTEXT=1: keep the reflected rotation as-is and set
    ///     `isBackwards`, which the renderer (CGRenderCore.swift) honors via
    ///     an x-flip — genuinely mirrored, backwards-reading glyphs.
    private static func applyTextRotationAndMirror(_ p: inout TextPayload, _ t: Transform2, mirrtext: Bool) {
        guard t.isMirroring else {
            p.rotationDeg += t.rotationAngle * 180 / .pi
            return
        }
        // See EntityTransform.apply's arc case for why this is `alpha - θ`,
        // not `2 * alpha - θ`: `t.rotationAngle` is already 2x the mirror
        // line's angle for a reflection transform.
        let alpha = t.rotationAngle * 180 / .pi
        let reflectedRotation = alpha - p.rotationDeg
        if mirrtext {
            p.rotationDeg = reflectedRotation
            p.isBackwards.toggle()
        } else {
            // Re-normalize: undo the reflection's effect on readability by
            // rotating another 180 degrees and swapping horizontal
            // alignment — the exact transformation Regenerator.swift's
            // mirrored-block-content branch already applies at render time
            // for INSERT-driven mirroring, reproduced here so a direct
            // MIRROR of a standalone TEXT entity persists the same visual
            // result into the entity's OWN payload instead of relying on a
            // parent INSERT's extrusion.
            p.rotationDeg = reflectedRotation + 180
            if p.hAlign == 0 { p.hAlign = 2 }
            else if p.hAlign == 2 { p.hAlign = 0 }
        }
    }
}

private extension Vec3 {
    init(_ v2: Vec2, z: Double) { self.init(x: v2.x, y: v2.y, z: z) }
}
