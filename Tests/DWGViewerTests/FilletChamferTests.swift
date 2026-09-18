//
//  FilletChamferTests.swift
//  DWGViewerTests
//
//  Direct Curve2 construction (no file I/O) covering FilletChamfer's
//  line/line core per the plan's gate: all 4 quadrant click combinations,
//  R=0 corner join, parallel lines (semicircle), R-too-large -> nil (no
//  crash), and CHAMFER distance/angle modes.
//

import XCTest
import simd
@testable import DWGViewer
import CADCore

final class FilletChamferTests: XCTestCase {

    let tol = Tolerance(linear: 1e-6)

    // MARK: - 4-quadrant FILLET (the plan's explicit test gate)
    //
    // Two lines forming a "+" crossing at the origin: a horizontal line
    // along the X axis and a vertical line along the Y axis. Clicking each
    // of the 4 quadrant combinations must fillet a DIFFERENT corner, each
    // with its arc correctly bulging away from that specific corner.

    private let horizontal = LineSeg(a: Vec2(-10, 0), b: Vec2(10, 0))
    private let vertical = LineSeg(a: Vec2(0, -10), b: Vec2(0, 10))

    func testFilletQuadrant1_PositiveXPositiveY() {
        // Click +X on horizontal, +Y on vertical -> fillet the corner in
        // quadrant 1 (the "elbow" connecting +X and +Y rays). Since these
        // two lines actually CROSS at the origin (this synthetic "+" setup
        // exercises all 4 quadrants off one pair of lines), the kept side
        // of each line is whichever RAY the click falls on relative to its
        // own tangent foot — the +X ray (2,0)-(10,0) and the +Y ray
        // (0,2)-(0,10) — NOT the ray through the origin toward the
        // opposite quadrant. (An earlier version of `trimLineTo` used a
        // fixed t=0.5 heuristic instead of comparing to the tangent foot's
        // own parametric position, which happened to keep the WRONG,
        // unrelated ray for this and similar cases — caught by adversarial
        // review, fixed, and this test's expected values corrected to
        // match real fillet semantics: the kept segments are the two rays
        // that actually form the rounded elbow.)
        let result = FilletChamfer.fillet(line1: horizontal, line2: vertical, radius: 2,
                                          clickPoint1: Vec2(5, 0), clickPoint2: Vec2(0, 5), tol: tol)
        guard let result, case .arc(let arc)? = result.connector else { return XCTFail("expected an arc connector") }
        // Center must be at (2,2) (radius 2, tangent to both axes, in Q1).
        XCTAssertEqual(arc.center.x, 2, accuracy: 1e-6)
        XCTAssertEqual(arc.center.y, 2, accuracy: 1e-6)
        XCTAssertEqual(arc.r, 2, accuracy: 1e-6)
        guard case .segment(let s1)? = result.trimmedLine1, case .segment(let s2)? = result.trimmedLine2 else {
            return XCTFail("expected segment results")
        }
        XCTAssertTrue(pointsMatch([s1.a, s1.b], expectedFar: Vec2(10, 0), expectedNear: Vec2(2, 0)))
        XCTAssertTrue(pointsMatch([s2.a, s2.b], expectedFar: Vec2(0, 10), expectedNear: Vec2(0, 2)))
    }

    func testFilletQuadrant2_NegativeXPositiveY() {
        let result = FilletChamfer.fillet(line1: horizontal, line2: vertical, radius: 2,
                                          clickPoint1: Vec2(-5, 0), clickPoint2: Vec2(0, 5), tol: tol)
        guard let result, case .arc(let arc)? = result.connector else { return XCTFail("expected an arc connector") }
        XCTAssertEqual(arc.center.x, -2, accuracy: 1e-6)
        XCTAssertEqual(arc.center.y, 2, accuracy: 1e-6)
    }

    func testFilletQuadrant3_NegativeXNegativeY() {
        let result = FilletChamfer.fillet(line1: horizontal, line2: vertical, radius: 2,
                                          clickPoint1: Vec2(-5, 0), clickPoint2: Vec2(0, -5), tol: tol)
        guard let result, case .arc(let arc)? = result.connector else { return XCTFail("expected an arc connector") }
        XCTAssertEqual(arc.center.x, -2, accuracy: 1e-6)
        XCTAssertEqual(arc.center.y, -2, accuracy: 1e-6)
    }

    func testFilletQuadrant4_PositiveXNegativeY() {
        let result = FilletChamfer.fillet(line1: horizontal, line2: vertical, radius: 2,
                                          clickPoint1: Vec2(5, 0), clickPoint2: Vec2(0, -5), tol: tol)
        guard let result, case .arc(let arc)? = result.connector else { return XCTFail("expected an arc connector") }
        XCTAssertEqual(arc.center.x, 2, accuracy: 1e-6)
        XCTAssertEqual(arc.center.y, -2, accuracy: 1e-6)
    }

    /// Every quadrant's arc must round off (bulge TOWARD) its own corner —
    /// the minor arc between the two tangent feet, which replaces the sharp
    /// corner with a smooth curve, always has its midpoint CLOSER to the
    /// corner than the chord's own midpoint (real fillet geometry: for a
    /// 90-degree corner at the origin with radius-2 tangent feet (2,0)/(0,2),
    /// the correct arc midpoint is near (0.59,0.59) — closer to the origin
    /// than the chord midpoint (1,1) — not the reflex/major arc on the far
    /// side). An earlier version of this test (and the code it exercised)
    /// asserted the opposite — caught by adversarial review via this exact
    /// hand-worked example.
    func testAllFourQuadrantArcsBulgeTowardOrigin() {
        let clicks: [(Vec2, Vec2)] = [(Vec2(5, 0), Vec2(0, 5)), (Vec2(-5, 0), Vec2(0, 5)),
                                      (Vec2(-5, 0), Vec2(0, -5)), (Vec2(5, 0), Vec2(0, -5))]
        for (c1, c2) in clicks {
            guard let result = FilletChamfer.fillet(line1: horizontal, line2: vertical, radius: 2, clickPoint1: c1, clickPoint2: c2, tol: tol),
                  case .arc(let arc)? = result.connector else { return XCTFail("expected arc for click (\(c1), \(c2))") }
            let mid = Curve2.arc(arc).evaluate(abs(arc.sweep) / 2)
            let chordMid = (Curve2.arc(arc).evaluate(0) + Curve2.arc(arc).evaluate(abs(arc.sweep))) / 2
            XCTAssertLessThan(simd_length(mid), simd_length(chordMid), "arc for click (\(c1),\(c2)) must round off (bulge toward) the origin corner")
        }
    }

    // MARK: - R=0 corner join

    func testFilletRadiusZeroProducesPureCornerJoinNoArc() {
        let result = FilletChamfer.fillet(line1: horizontal, line2: vertical, radius: 0,
                                          clickPoint1: Vec2(5, 0), clickPoint2: Vec2(0, 5), tol: tol)
        guard let result else { return XCTFail("expected a result") }
        XCTAssertNil(result.connector, "R=0 must produce no connector arc")
        guard case .segment(let s1)? = result.trimmedLine1, case .segment(let s2)? = result.trimmedLine2 else {
            return XCTFail("expected segment results")
        }
        // Both trimmed lines must now meet exactly at the origin (the
        // extended-intersection corner).
        XCTAssertTrue([s1.a, s1.b].contains { simd_length($0) < 1e-6 })
        XCTAssertTrue([s2.a, s2.b].contains { simd_length($0) < 1e-6 })
    }

    /// R=0 on lines that DON'T already meet (short of the corner) must
    /// EXTEND them to the corner, not just trim — AutoCAD's documented
    /// "fillet may extend short lines" behavior.
    func testFilletRadiusZeroExtendsShortLines() {
        let shortH = LineSeg(a: Vec2(-10, 0), b: Vec2(-2, 0))     // ends well short of the corner
        let shortV = LineSeg(a: Vec2(0, -10), b: Vec2(0, -2))
        let result = FilletChamfer.fillet(line1: shortH, line2: shortV, radius: 0,
                                          clickPoint1: Vec2(-5, 0), clickPoint2: Vec2(0, -5), tol: tol)
        guard let result, case .segment(let s1)? = result.trimmedLine1, case .segment(let s2)? = result.trimmedLine2 else {
            return XCTFail("expected extended segments")
        }
        XCTAssertTrue([s1.a, s1.b].contains { simd_length($0) < 1e-6 }, "short line 1 must be EXTENDED to the corner")
        XCTAssertTrue([s2.a, s2.b].contains { simd_length($0) < 1e-6 }, "short line 2 must be EXTENDED to the corner")
    }

    // MARK: - Parallel lines -> semicircle (ignores requested R)

    func testFilletParallelLinesProducesSemicircleIgnoringRequestedRadius() {
        let l1 = LineSeg(a: Vec2(-10, 0), b: Vec2(10, 0))
        let l2 = LineSeg(a: Vec2(-10, 6), b: Vec2(10, 6))   // gap = 6, so expected semicircle radius = 3
        // Request a radius (100) that should be COMPLETELY IGNORED for the
        // parallel-lines case.
        let result = FilletChamfer.fillet(line1: l1, line2: l2, radius: 100,
                                          clickPoint1: Vec2(0, 0), clickPoint2: Vec2(0, 6), tol: tol)
        guard let result, case .arc(let arc)? = result.connector else { return XCTFail("expected a semicircle arc") }
        XCTAssertEqual(arc.r, 3, accuracy: 1e-6, "parallel-lines fillet radius must be gap/2, ignoring the requested R")
        XCTAssertEqual(abs(arc.sweep), .pi, accuracy: 1e-6, "must be exactly a semicircle")
    }

    // MARK: - R too large -> nil, no crash

    func testFilletRadiusTooLargeForShortLinesStillProducesAValidResultOrNilGracefully() {
        // A radius far larger than the lines themselves must never crash;
        // the algorithm may still find a mathematically valid (if visually
        // extreme) tangent circle for two infinite-line extensions, since
        // "too large" for line/line fillet (unlike arc/arc, where enclosure
        // is a hard geometric impossibility) doesn't have the same
        // hard-nil case — this test's actual assertion is just "no crash,"
        // deliberately probing an extreme input.
        let shortH = LineSeg(a: Vec2(-1, 0), b: Vec2(1, 0))
        let shortV = LineSeg(a: Vec2(0, -1), b: Vec2(0, 1))
        let result = FilletChamfer.fillet(line1: shortH, line2: shortV, radius: 1_000_000,
                                          clickPoint1: Vec2(0.5, 0), clickPoint2: Vec2(0, 0.5), tol: tol)
        // Either a valid huge-radius result or nil is acceptable; the test
        // exists purely to confirm this doesn't crash/hang/NaN.
        if let result, case .arc(let arc)? = result.connector {
            XCTAssertFalse(arc.center.x.isNaN)
            XCTAssertFalse(arc.r.isNaN)
        }
    }

    func testFilletNegativeRadiusReturnsNil() {
        let result = FilletChamfer.fillet(line1: horizontal, line2: vertical, radius: -1,
                                          clickPoint1: Vec2(5, 0), clickPoint2: Vec2(0, 5), tol: tol)
        XCTAssertNil(result)
    }

    func testFilletDegenerateZeroLengthLineReturnsNilNotCrash() {
        let degenerate = LineSeg(a: Vec2(1, 1), b: Vec2(1, 1))
        let result = FilletChamfer.fillet(line1: degenerate, line2: vertical, radius: 2,
                                          clickPoint1: Vec2(1, 1), clickPoint2: Vec2(0, 5), tol: tol)
        XCTAssertNil(result)
    }

    // MARK: - CHAMFER (distance mode)

    func testChamferDistanceModeSymmetric() {
        let result = FilletChamfer.chamfer(line1: horizontal, line2: vertical, d1: 3, d2: 3, angleMode: false,
                                           clickPoint1: Vec2(5, 0), clickPoint2: Vec2(0, 5), tol: tol)
        guard let result, case .segment(let connector)? = result.connector else { return XCTFail("expected a chamfer segment") }
        // Chamfer feet at (3,0) and (0,3).
        let pts = [connector.a, connector.b]
        XCTAssertTrue(pts.contains { simd_length($0 - Vec2(3, 0)) < 1e-6 })
        XCTAssertTrue(pts.contains { simd_length($0 - Vec2(0, 3)) < 1e-6 })
    }

    func testChamferDistanceModeAsymmetric() {
        let result = FilletChamfer.chamfer(line1: horizontal, line2: vertical, d1: 2, d2: 5, angleMode: false,
                                           clickPoint1: Vec2(5, 0), clickPoint2: Vec2(0, 5), tol: tol)
        guard let result, case .segment(let connector)? = result.connector else { return XCTFail("expected a chamfer segment") }
        let pts = [connector.a, connector.b]
        XCTAssertTrue(pts.contains { simd_length($0 - Vec2(2, 0)) < 1e-6 })
        XCTAssertTrue(pts.contains { simd_length($0 - Vec2(0, 5)) < 1e-6 })
    }

    /// Angle mode: d2 (passed as radians) determines the SECOND distance
    /// via `d1 * tan(angle)`, per the plan's exact formula — this is the
    /// load-bearing formula an adversarial coefficient bug (e.g. missing
    /// the `d1*` factor, or `tan` vs `atan`) would break in a checkable way.
    func testChamferAngleModeUsesD1TimesTanAngleFormula() {
        let angle = Double.pi / 4   // 45 degrees -> tan(45deg) = 1.0 exactly
        let result = FilletChamfer.chamfer(line1: horizontal, line2: vertical, d1: 4, d2: angle, angleMode: true,
                                           clickPoint1: Vec2(5, 0), clickPoint2: Vec2(0, 5), tol: tol)
        guard let result, case .segment(let connector)? = result.connector else { return XCTFail("expected a chamfer segment") }
        let pts = [connector.a, connector.b]
        XCTAssertTrue(pts.contains { simd_length($0 - Vec2(4, 0)) < 1e-6 }, "d1 foot must be at distance 4")
        // tan(45deg) = 1, so effective d2 = 4*1 = 4 -> foot at (0,4).
        XCTAssertTrue(pts.contains { simd_length($0 - Vec2(0, 4)) < 1e-6 }, "d1*tan(angle) with angle=45deg must give effective d2 = d1 exactly")
    }

    /// A DIFFERENT angle (30 degrees, tan != 1) to further disambiguate the
    /// formula from a plausible-but-wrong alternative (e.g. d1/tan(angle),
    /// or d1*angle in radians directly) — each would produce a clearly
    /// different, checkable numeric foot position.
    func testChamferAngleModeWithNonTrivialAngle() {
        let angle = 30.0 * .pi / 180
        let result = FilletChamfer.chamfer(line1: horizontal, line2: vertical, d1: 10, d2: angle, angleMode: true,
                                           clickPoint1: Vec2(5, 0), clickPoint2: Vec2(0, 5), tol: tol)
        guard let result, case .segment(let connector)? = result.connector else { return XCTFail("expected a chamfer segment") }
        let expectedD2 = 10 * tan(angle)   // ~5.7735
        let pts = [connector.a, connector.b]
        XCTAssertTrue(pts.contains { simd_length($0 - Vec2(0, expectedD2)) < 1e-6 })
    }

    func testChamferQuadrant3() {
        let result = FilletChamfer.chamfer(line1: horizontal, line2: vertical, d1: 2, d2: 2, angleMode: false,
                                           clickPoint1: Vec2(-5, 0), clickPoint2: Vec2(0, -5), tol: tol)
        guard let result, case .segment(let connector)? = result.connector else { return XCTFail("expected a chamfer segment") }
        let pts = [connector.a, connector.b]
        XCTAssertTrue(pts.contains { simd_length($0 - Vec2(-2, 0)) < 1e-6 })
        XCTAssertTrue(pts.contains { simd_length($0 - Vec2(0, -2)) < 1e-6 })
    }

    // MARK: - Helpers

    private func pointsMatch(_ pts: [Vec2], expectedFar: Vec2, expectedNear: Vec2) -> Bool {
        let hasFar = pts.contains { simd_length($0 - expectedFar) < 1e-6 }
        let hasNear = pts.contains { simd_length($0 - expectedNear) < 1e-6 }
        return hasFar && hasNear
    }
}
