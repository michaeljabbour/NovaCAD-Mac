//
//  FilletChamfer.swift
//  DWGViewer / Editing
//
//  Phase 4.4 — FILLET/CHAMFER core geometry. Pure functions over
//  `Curve2`/`BulgePolyline` (via `EntityCurveBridge`), mirroring
//  `TrimExtend.swift`'s split between pure geometry (this file) and the
//  entity/document-aware glue (`FilletChamferExecutor.swift`).
//
//  Scope (per the plan's own prioritization): LINE/LINE pairs — the common
//  real-world case — are fully correct, including all 4 click-side
//  quadrant combinations, R=0 (extended-intersection corner join), and
//  parallel lines (semicircle of radius gap/2, ignoring the requested R).
//  Polyline vertex fillet/chamfer and the `P` (fillet/chamfer-ALL) keyword
//  are best-effort/deferred if time runs short — see the phase's final
//  report for exactly what shipped vs. what's stubbed. Arc/arc and
//  line/arc fillet are OUT OF SCOPE for this pass (line/line is the
//  overwhelming majority of real usage per the plan's own prioritization
//  guidance) — `fillet(line:line:...)`/`chamfer(line:line:...)` are the
//  only entry points implemented; a caller passing an arc gets nil back,
//  never a crash.
//

import Foundation
import CADCore
import simd

/// One resolved FILLET/CHAMFER result for a LINE/LINE corner: the new arc
/// (fillet) or chamfer segment to insert, plus how each of the two original
/// lines should be trimmed/extended to meet it (TRIMMODE=1) or left alone
/// (TRIMMODE=0).
struct FilletChamferResult {
    /// The new connecting geometry — an arc for FILLET, a straight segment
    /// for CHAMFER. `nil` for FILLET R=0 (a pure corner join with no
    /// connecting arc — the two lines simply meet at the corner point).
    var connector: Curve2?
    /// The two original lines, each trimmed/extended so its END nearest the
    /// corner lands exactly at its tangent/chamfer foot point (or at the
    /// shared corner point itself, for R=0). `nil` when TRIMMODE=0 (leave
    /// the original curve untouched — only the connector is added).
    var trimmedLine1: Curve2?
    var trimmedLine2: Curve2?
}

enum FilletChamfer {

    // MARK: - FILLET (line/line)

    /// Fillets two lines with radius `r`. `clickPoint1`/`clickPoint2` are
    /// the points the user clicked ON EACH LINE (used to disambiguate which
    /// of the 4 candidate corners to use — AutoCAD FILLET always fillets
    /// the corner nearest wherever the two picks landed, keeping the
    /// picked-side portions of each line). `r == 0` performs a pure corner
    /// join (extended intersection, no arc) per the plan's spec; `r < 0` is
    /// invalid and returns nil (callers should validate before calling —
    /// mirrors AutoCAD's own "radius must be positive" input validation,
    /// which happens at the command-prompt layer, not here).
    static func fillet(line1: LineSeg, line2: LineSeg, radius r: Double,
                       clickPoint1: Vec2, clickPoint2: Vec2, tol: Tolerance) -> FilletChamferResult? {
        guard r >= 0 else { return nil }
        let d1 = line1.b - line1.a, d2 = line2.b - line2.a
        guard simd_length(d1) > tol.linear, simd_length(d2) > tol.linear else { return nil }

        // Parallel lines: AutoCAD's own special case — a semicircle of
        // radius gap/2 connecting them, ignoring the requested R entirely.
        if let parallelResult = filletParallelLines(line1: line1, line2: line2, clickPoint1: clickPoint1, clickPoint2: clickPoint2, tol: tol) {
            return parallelResult
        }

        guard let corner = lineLineIntersection(line1, line2, tol: tol) else { return nil }

        if r < tol.linear {
            // R=0: pure corner join — extend/trim both lines to meet exactly
            // at their (possibly extended) intersection point.
            let t1 = trimLineTo(line1, target: corner, keepSideOf: clickPoint1)
            let t2 = trimLineTo(line2, target: corner, keepSideOf: clickPoint2)
            return FilletChamferResult(connector: nil, trimmedLine1: .segment(t1), trimmedLine2: .segment(t2))
        }

        // Candidate centers: intersections of the 4 offset-side
        // combinations. Each offset line is the ORIGINAL line's infinite
        // extension shifted by +-r; their pairwise intersections are the 4
        // candidate fillet-arc centers (one of which corresponds to each
        // combination of "which side of line1"/"which side of line2" the
        // user could have clicked).
        let sideCombinations: [(OffsetSide, OffsetSide)] = [(.left, .left), (.left, .right), (.right, .left), (.right, .right)]
        let candidates: [(center: Vec2, side1: OffsetSide, side2: OffsetSide)] = sideCombinations.compactMap { s1, s2 in
            guard let center = offsetLineIntersection(line1, line2, s1, s2, r) else { return nil }
            return (center: center, side1: s1, side2: s2)
        }

        guard !candidates.isEmpty else { return nil }

        // Pick the candidate whose feet lie on the CLICKED side of each
        // line (the foot's parameter, projected onto the line's own
        // direction from the corner, must point toward the click, not away
        // from it) — this is what correctly disambiguates all 4
        // quadrant-click combinations per the plan's test gate.
        var best: (center: Vec2, foot1: Vec2, foot2: Vec2, score: Double)? = nil
        for c in candidates {
            let foot1 = closestPointOnInfiniteLine(line1, to: c.center)
            let foot2 = closestPointOnInfiniteLine(line2, to: c.center)
            // Reject a candidate whose feet aren't actually at distance R
            // from the center (guards a degenerate offset-intersection,
            // e.g. near-parallel lines producing a far-flung center).
            guard abs(simd_length(foot1 - c.center) - r) < max(tol.linear * 10, 1e-6) else { continue }
            guard abs(simd_length(foot2 - c.center) - r) < max(tol.linear * 10, 1e-6) else { continue }
            let towardClick1 = simd_dot(clickPoint1 - corner, foot1 - corner)
            let towardClick2 = simd_dot(clickPoint2 - corner, foot2 - corner)
            guard towardClick1 > -tol.linear, towardClick2 > -tol.linear else { continue }
            // Score: prefer the candidate whose feet are CLOSEST to the
            // actual click points (handles the rare case where more than
            // one candidate satisfies the "same side" test loosely near the
            // corner itself).
            let score = simd_length(foot1 - clickPoint1) + simd_length(foot2 - clickPoint2)
            if best == nil || score < best!.score { best = (c.center, foot1, foot2, score) }
        }
        guard let chosen = best else { return nil }

        // Build the arc: sweep chosen so the arc bulges AWAY from the
        // corner (arc midpoint farther from the corner than the chord
        // midpoint) per the plan's spec — of the two possible sweeps
        // between foot1 and foot2 (CW/CCW), the away-from-corner one is
        // the one whose MIDPOINT satisfies this distance test directly;
        // computing both candidate arcs and picking the correct one avoids
        // any indirect sign reasoning about which sweep direction that is.
        guard let arc = arcBulgingAwayFromCorner(center: chosen.center, r: r, from: chosen.foot1, to: chosen.foot2, corner: corner) else {
            return nil
        }

        let t1 = trimLineTo(line1, target: chosen.foot1, keepSideOf: clickPoint1)
        let t2 = trimLineTo(line2, target: chosen.foot2, keepSideOf: clickPoint2)
        return FilletChamferResult(connector: .arc(arc), trimmedLine1: .segment(t1), trimmedLine2: .segment(t2))
    }

    /// AutoCAD's parallel-lines FILLET special case: connects the two lines
    /// with a semicircle of radius `gap/2` (the requested R is ignored
    /// entirely, matching real AutoCAD behavior) — returns nil if the lines
    /// are not parallel (within `tol.angular`), so the caller falls through
    /// to the general 4-candidate path.
    private static func filletParallelLines(line1: LineSeg, line2: LineSeg, clickPoint1: Vec2, clickPoint2: Vec2, tol: Tolerance) -> FilletChamferResult? {
        let d1 = simd_normalize(line1.b - line1.a)
        let d2 = simd_normalize(line2.b - line2.a)
        let cross = d1.x * d2.y - d1.y * d2.x
        guard abs(cross) < tol.angular * 100 else { return nil }   // not parallel

        // Perpendicular distance from line2 to line1 (using line1's own
        // direction and normal).
        let normal = Vec2(-d1.y, d1.x)
        let gap = simd_dot(line2.a - line1.a, normal)
        guard abs(gap) > tol.linear else { return nil }   // coincident lines — no meaningful semicircle
        let r = abs(gap) / 2

        // Foot on line1 nearest clickPoint1, foot on line2 nearest
        // clickPoint2 — the semicircle connects THESE two points (the
        // picked locations), diameter = gap, center = their midpoint.
        let foot1 = closestPointOnInfiniteLine(line1, to: clickPoint1)
        let foot2 = closestPointOnInfiniteLine(line2, to: clickPoint2)
        let center = (foot1 + foot2) / 2
        // corner "at infinity" doesn't apply here — use the midpoint
        // BETWEEN the two feet's own line-relative corner-less reference:
        // the semicircle must bulge AWAY from both lines (outward), i.e.
        // away from the segment foot1->foot2's own midpoint is meaningless
        // (that IS the center) — instead bulge away from line1 itself
        // (equivalently, away from line2), which `arcBulgingAwayFromCorner`
        // achieves by treating "line1's own foot, reflected through the
        // center" as the corner reference (any point strictly on line1's
        // side works, since the two candidate sweeps differ by which side
        // of the foot1-foot2 chord they bulge toward).
        let referenceOnLine1Side = foot1 - normal * r  // a point further along -normal from foot1, unambiguously on line1's outward side
        guard let arc = arcBulgingAwayFromCorner(center: center, r: r, from: foot1, to: foot2, corner: referenceOnLine1Side) else { return nil }
        let t1 = trimLineTo(line1, target: foot1, keepSideOf: clickPoint1)
        let t2 = trimLineTo(line2, target: foot2, keepSideOf: clickPoint2)
        return FilletChamferResult(connector: .arc(arc), trimmedLine1: .segment(t1), trimmedLine2: .segment(t2))
    }

    // MARK: - CHAMFER (line/line)

    /// Chamfers two lines with distances `d1`/`d2` measured from the
    /// extended corner along each line. `angleMode`: if true, `d2` is
    /// interpreted as an ANGLE in radians (from line1) rather than a
    /// distance, and the actual second distance is derived as
    /// `d1 * tan(angle)` per the plan's spec.
    static func chamfer(line1: LineSeg, line2: LineSeg, d1: Double, d2: Double, angleMode: Bool,
                        clickPoint1: Vec2, clickPoint2: Vec2, tol: Tolerance) -> FilletChamferResult? {
        guard d1 >= 0, d2 >= 0 || angleMode else { return nil }
        guard let corner = lineLineIntersection(line1, line2, tol: tol) else { return nil }

        let dir1 = simd_normalize(line1.b - line1.a)
        let dir2 = simd_normalize(line2.b - line2.a)
        // Direction AWAY from the corner along each line, on the clicked side.
        let toward1: Vec2 = simd_dot(clickPoint1 - corner, dir1) >= 0 ? dir1 : -dir1
        let toward2: Vec2 = simd_dot(clickPoint2 - corner, dir2) >= 0 ? dir2 : -dir2

        let effectiveD2: Double
        if angleMode {
            // d2 (passed in as an ANGLE in radians) -> distance along line2:
            // d2_distance = d1 * tan(angle), per the plan's exact formula.
            effectiveD2 = d1 * tan(d2)
        } else {
            effectiveD2 = d2
        }
        guard effectiveD2 >= 0, effectiveD2.isFinite else { return nil }

        let foot1 = corner + toward1 * d1
        let foot2 = corner + toward2 * effectiveD2
        guard simd_length(foot1 - corner) > tol.linear || d1 == 0 else { return nil }

        let connector: Curve2? = (d1 > tol.linear || effectiveD2 > tol.linear) ? .segment(LineSeg(a: foot1, b: foot2)) : nil
        let t1 = trimLineTo(line1, target: foot1, keepSideOf: clickPoint1)
        let t2 = trimLineTo(line2, target: foot2, keepSideOf: clickPoint2)
        return FilletChamferResult(connector: connector, trimmedLine1: .segment(t1), trimmedLine2: .segment(t2))
    }

    // MARK: - Shared line/line helpers

    /// Extended-intersection point of two infinite lines (nil if parallel).
    private static func lineLineIntersection(_ l1: LineSeg, _ l2: LineSeg, tol: Tolerance) -> Vec2? {
        let hits = Intersect.curves(.segment(l1), .segment(l2), tol: tol, extendA: true, extendB: true)
        return hits.first?.point
    }

    /// Intersection of line1 offset by `r` to `side1` and line2 offset by
    /// `r` to `side2`, as INFINITE lines (nil if the two offset lines are
    /// parallel, which happens whenever the original two lines are
    /// themselves parallel — handled separately by `filletParallelLines`).
    private static func offsetLineIntersection(_ l1: LineSeg, _ l2: LineSeg, _ side1: OffsetSide, _ side2: OffsetSide, _ r: Double) -> Vec2? {
        let o1 = Offset.segment(l1, r, side1)
        let o2 = Offset.segment(l2, r, side2)
        let d1 = o1.b - o1.a, d2 = o2.b - o2.a
        let denom = d1.x * d2.y - d1.y * d2.x
        guard abs(denom) > 1e-12 else { return nil }
        let dx = o2.a - o1.a
        let t = (dx.x * d2.y - dx.y * d2.x) / denom
        return o1.a + d1 * t
    }

    /// Closest point to `p` on the INFINITE extension of `line` (unlike
    /// `Curve2.closestPoint`, which clamps to the segment's own [0,1]).
    private static func closestPointOnInfiniteLine(_ line: LineSeg, to p: Vec2) -> Vec2 {
        let d = line.b - line.a
        let len2 = simd_length_squared(d)
        guard len2 > 0 else { return line.a }
        let t = simd_dot(p - line.a, d) / len2
        return line.a + d * t
    }

    /// Trims/extends `line` so its end NEAREST `keepSideOf` becomes exactly
    /// `target`, keeping the FAR end (the one on the opposite side from the
    /// click) unchanged — this is "shorten/extend this line to meet the
    /// fillet/chamfer at its foot," which may extend a SHORT line past its
    /// original endpoint (AutoCAD's own documented fillet behavior).
    private static func trimLineTo(_ line: LineSeg, target: Vec2, keepSideOf clickPoint: Vec2) -> LineSeg {
        let d = line.b - line.a
        let len2 = simd_length_squared(d)
        guard len2 > 0 else { return line }
        let tClick = simd_dot(clickPoint - line.a, d) / len2
        let tTarget = simd_dot(target - line.a, d) / len2
        // The endpoint on the SAME side of `target` as the click is the one
        // being kept — NOT a fixed t=0.5 midpoint heuristic (that heuristic
        // is wrong whenever `target` itself isn't near the line's own
        // midpoint, which is the common case: a fillet/chamfer foot is
        // usually much closer to one end than the other). If the click is
        // on the `line.a` side of `target` (tClick < tTarget), `line.a`
        // is the kept endpoint and `target` becomes the new `b`; otherwise
        // `line.b` is kept and `target` becomes the new `a`.
        if tClick < tTarget {
            return LineSeg(a: line.a, b: target)
        } else {
            return LineSeg(a: target, b: line.b)
        }
    }

    /// Builds the arc from `from` to `to` (both known to be at distance `r`
    /// from `center`) whose SWEEP DIRECTION is chosen so the arc rounds off
    /// `corner` — i.e., the arc's own midpoint is CLOSER to `corner` than
    /// the chord `from`-`to`'s midpoint is. This is the minor arc that
    /// replaces the sharp corner with a smooth curve (real AutoCAD FILLET
    /// behavior: for two perpendicular lines meeting at the origin with
    /// tangent feet (R,0)/(0,R), the correct fillet arc's midpoint sits at
    /// roughly (0.29R, 0.29R) — well inside the chord midpoint (0.5R,0.5R),
    /// i.e. CLOSER to the corner, not farther). An earlier version of this
    /// function picked the FARTHER-midpoint sweep instead (misreading the
    /// original spec text), which selects the major/reflex arc and inverts
    /// the fillet for every ordinary convex corner — caught by adversarial
    /// review via this exact hand-worked example, fixed here.
    /// Tries both CCW and CW sweeps between the two angles and picks
    /// whichever's midpoint satisfies the distance test — direct
    /// measurement rather than indirect sign reasoning, so this is correct
    /// regardless of which quadrant `from`/`to`/`corner` fall in.
    private static func arcBulgingAwayFromCorner(center: Vec2, r: Double, from: Vec2, to: Vec2, corner: Vec2) -> CircArc? {
        guard r > 0 else { return nil }
        let startAngle = atan2(from.y - center.y, from.x - center.x)
        let endAngle = atan2(to.y - center.y, to.x - center.x)
        var ccwSweep = endAngle - startAngle
        ccwSweep = ccwSweep.truncatingRemainder(dividingBy: 2 * .pi)
        if ccwSweep < 0 { ccwSweep += 2 * .pi }
        let cwSweep = ccwSweep - 2 * .pi   // the complementary (negative) sweep

        let chordMid = (from + to) / 2
        let chordDistToCorner = simd_length(chordMid - corner)

        func midpointDistToCorner(_ sweep: Double) -> Double {
            let arc = CircArc(center: center, r: r, startAngle: startAngle, sweep: sweep)
            let mid = Curve2.arc(arc).evaluate(abs(sweep) / 2)
            return simd_length(mid - corner)
        }

        let ccwMidDist = midpointDistToCorner(ccwSweep)
        let cwMidDist = midpointDistToCorner(cwSweep)

        // Pick whichever sweep's midpoint is CLOSER to the corner than the
        // chord's own midpoint (the "rounds off the corner" test — see the
        // doc comment above) — if both qualify (can't happen for a proper
        // minor/major-arc pair sharing the same 2 points on a circle, but
        // guarded anyway), the one with the SMALLER distance wins; if
        // NEITHER does (degenerate: from == to, zero-length chord), fall
        // back to the shorter (minor) sweep rather than returning nil.
        let ccwQualifies = ccwMidDist < chordDistToCorner
        let cwQualifies = cwMidDist < chordDistToCorner
        let chosenSweep: Double
        if ccwQualifies && !cwQualifies { chosenSweep = ccwSweep }
        else if cwQualifies && !ccwQualifies { chosenSweep = cwSweep }
        else if ccwQualifies && cwQualifies { chosenSweep = ccwMidDist <= cwMidDist ? ccwSweep : cwSweep }
        else { chosenSweep = abs(ccwSweep) <= abs(cwSweep) ? ccwSweep : cwSweep }

        return CircArc(center: center, r: r, startAngle: startAngle, sweep: chosenSweep)
    }
}
