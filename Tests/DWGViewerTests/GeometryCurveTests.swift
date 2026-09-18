//
//  GeometryCurveTests.swift
//  DWGViewerTests
//
//  Phase 2 geometry kernel tests: Curve2 evaluation, derivatives,
//  closestPoint, split/reversed round trips, bulge<->arc conversion, and
//  NURBS split correctness.
//

import XCTest
import simd
@testable import DWGViewer
import CADCore

final class GeometryCurveTests: XCTestCase {

    let tol = Tolerance(linear: 1e-6)

    // MARK: - Fixture curves

    func sampleSegment() -> Curve2 { .segment(LineSeg(a: Vec2(1, 2), b: Vec2(9, -4))) }

    func sampleArc() -> Curve2 {
        .arc(CircArc(center: Vec2(3, 4), r: 5, startAngle: 0.3, sweep: 2.1))
    }

    func sampleCircle() -> Curve2 { .circle(Circle2(center: Vec2(-2, 5), r: 7)) }

    func sampleEllipse() -> Curve2 {
        .ellipse(EllipseArc(center: Vec2(1, 1), majorAxis: Vec2(6, 2), ratio: 0.5,
                            startParam: 0.2, endParam: 4.5))
    }

    func sampleFullEllipse() -> Curve2 {
        .ellipse(EllipseArc(center: Vec2(0, 0), majorAxis: Vec2(4, 0), ratio: 0.5,
                            startParam: 0, endParam: 2 * .pi))
    }

    func sampleSpline() -> Curve2 {
        // A clamped cubic B-spline with 6 control points.
        let control: [Vec2] = [
            Vec2(0, 0), Vec2(2, 4), Vec2(5, 5), Vec2(8, 1), Vec2(11, 3), Vec2(13, 0)
        ]
        let degree = 3
        // n+1 = 6 control points, need count = 6+3+1 = 10 knots, clamped.
        let knots: [Double] = [0, 0, 0, 0, 0.33, 0.66, 1, 1, 1, 1]
        return .spline(NURBS(degree: degree, control: control,
                             weights: [Double](repeating: 1, count: control.count), knots: knots))
    }

    func sampleRationalSpline() -> Curve2 {
        // A rational NURBS with non-uniform weights (e.g. approximating a
        // circle-like bulge) to exercise the quotient-rule derivative path.
        let control: [Vec2] = [Vec2(1, 0), Vec2(1, 1), Vec2(-1, 1), Vec2(-1, 0)]
        let weights: [Double] = [1, 0.7071067811865476, 0.7071067811865476, 1]
        let knots: [Double] = [0, 0, 0, 0.5, 1, 1, 1]
        return .spline(NURBS(degree: 2, control: control, weights: weights, knots: knots))
    }

    var allCurves: [(String, Curve2)] {
        [("segment", sampleSegment()), ("arc", sampleArc()), ("circle", sampleCircle()),
         ("ellipse", sampleEllipse()), ("spline", sampleSpline()), ("rationalSpline", sampleRationalSpline())]
    }

    // MARK: - Finite-difference derivative agreement

    func testTangentMatchesFiniteDifference() {
        for (name, c) in allCurves {
            let domain = c.paramDomain
            let span = domain.upperBound - domain.lowerBound
            guard span > 0 else { continue }
            let h = span * 1e-6
            for k in 1..<20 {
                let u = domain.lowerBound + span * Double(k) / 20.0
                let lo = max(domain.lowerBound, u - h)
                let hi = min(domain.upperBound, u + h)
                guard hi > lo else { continue }
                let fd = (c.evaluate(hi) - c.evaluate(lo)) / (hi - lo)
                let analytic = c.derivative(u)
                let fdLen = simd_length(fd)
                let analyticLen = simd_length(analytic)
                guard fdLen > 1e-9, analyticLen > 1e-9 else { continue }
                let fdTangent = fd / fdLen
                let analyticTangent = analytic / analyticLen
                let diff = simd_length(fdTangent - analyticTangent)
                XCTAssertLessThan(diff, 1e-4, "\(name) tangent mismatch at u=\(u): fd=\(fdTangent) analytic=\(analyticTangent)")
            }
        }
    }

    // MARK: - closestPoint vs brute-force scan

    func testClosestPointAgreesWithBruteForce() {
        let testPoints: [Vec2] = [Vec2(0, 0), Vec2(5, 5), Vec2(-3, 2), Vec2(10, -10), Vec2(2, 2)]
        let bruteSamples = 10_000
        for (name, c) in allCurves {
            let domain = c.paramDomain
            let span = domain.upperBound - domain.lowerBound
            guard span > 0 else { continue }
            for p in testPoints {
                var bestDist = Double.infinity
                for k in 0...bruteSamples {
                    let u = domain.lowerBound + span * Double(k) / Double(bruteSamples)
                    let d = simd_length(c.evaluate(u) - p)
                    if d < bestDist { bestDist = d }
                }
                let (_, _, dist) = c.closestPoint(to: p, tol: tol)
                // Allow slack proportional to sample resolution: the brute
                // force scan itself has discretization error of about
                // span/bruteSamples in parameter space.
                let slack = max(tol.linear * 50, bestDist * 0.01 + 1e-4)
                XCTAssertLessThanOrEqual(dist, bestDist + slack,
                    "\(name): closestPoint dist \(dist) exceeds brute-force best \(bestDist) for point \(p)")
            }
        }
    }

    // MARK: - split then re-evaluate

    func testSplitReproducesOriginalPoints() {
        for (name, c) in allCurves {
            let domain = c.paramDomain
            let span = domain.upperBound - domain.lowerBound
            guard span > 0.01 else { continue }
            let splitParams = [domain.lowerBound + span * 0.3, domain.lowerBound + span * 0.7]
            let pieces = c.split(at: splitParams)
            guard pieces.count == 3 else {
                XCTFail("\(name): expected 3 pieces, got \(pieces.count)")
                continue
            }
            // Check split points reproduce original curve points.
            for sp in splitParams {
                let originalPt = c.evaluate(sp)
                // Find which piece boundary corresponds to sp: it should be
                // an endpoint of two adjacent pieces.
                var foundMatch = false
                for piece in pieces {
                    let pd = piece.paramDomain
                    let startPt = piece.evaluate(pd.lowerBound)
                    let endPt = piece.evaluate(pd.upperBound)
                    if simd_length(startPt - originalPt) < 1e-6 || simd_length(endPt - originalPt) < 1e-6 {
                        foundMatch = true
                    }
                }
                XCTAssertTrue(foundMatch, "\(name): split point \(sp) not reproduced by any piece boundary")
            }
            // Check random interior parameters within the first piece still
            // agree between the piece and (an appropriately re-mapped) view
            // of the original curve, by comparing world-space points at a
            // few fractional positions along each piece against evaluate on
            // the original curve using the piece's own u mapped back.
            // Since pieces re-parameterize locally (e.g. segment/arc/ellipse
            // restart at 0), we validate by sampling each piece's own domain
            // and checking the point lies on the original curve via
            // closestPoint distance ~ 0.
            for piece in pieces {
                let pd = piece.paramDomain
                let mid = (pd.lowerBound + pd.upperBound) / 2
                let pt = piece.evaluate(mid)
                let (_, _, dist) = c.closestPoint(to: pt, tol: tol)
                XCTAssertLessThan(dist, 1e-4, "\(name): split piece midpoint not on original curve (dist \(dist))")
            }
        }
    }

    // MARK: - reversed round trip

    func testReversedRoundTrip() {
        for (name, c) in allCurves {
            let domain = c.paramDomain
            let r = c.reversed()
            let rr = r.reversed()
            let span = domain.upperBound - domain.lowerBound
            guard span > 0 else { continue }
            for k in 0...10 {
                let u = domain.lowerBound + span * Double(k) / 10.0
                let original = c.evaluate(u)
                let (_, _, dist) = rr.closestPoint(to: original, tol: tol)
                XCTAssertLessThan(dist, 1e-4, "\(name): reversed().reversed() doesn't reproduce original at u=\(u)")
            }
            // Endpoints should swap (for non-periodic cases).
            if !c.isPeriodic {
                let origStart = c.evaluate(domain.lowerBound)
                let origEnd = c.evaluate(domain.upperBound)
                let revDomain = r.paramDomain
                let revStart = r.evaluate(revDomain.lowerBound)
                let revEnd = r.evaluate(revDomain.upperBound)
                XCTAssertLessThan(simd_length(origStart - revEnd), 1e-6, "\(name): reversed end should equal original start")
                XCTAssertLessThan(simd_length(origEnd - revStart), 1e-6, "\(name): reversed start should equal original end")
            }
        }
    }

    // MARK: - bulgeToArc round trip

    func testBulgeArcRoundTrip() {
        let cases: [(Vec2, Vec2, Double)] = [
            (Vec2(0, 0), Vec2(10, 0), 1.0),      // semicircle
            (Vec2(0, 0), Vec2(10, 0), 0.5),
            (Vec2(0, 0), Vec2(10, 0), -0.5),
            (Vec2(2, 3), Vec2(-4, 8), 0.2),
            (Vec2(2, 3), Vec2(-4, 8), -0.9),
        ]
        for (a, b, bulge) in cases {
            let arc = bulgeToArc(from: a, to: b, bulge: bulge)
            // Endpoints must match input points.
            let startPt = Curve2.arc(arc).evaluate(0)
            let endPt = Curve2.arc(arc).evaluate(abs(arc.sweep))
            XCTAssertLessThan(simd_length(startPt - a), 1e-6, "bulge \(bulge): start mismatch")
            XCTAssertLessThan(simd_length(endPt - b), 1e-6, "bulge \(bulge): end mismatch")
            // Round trip bulge -> arc -> bulge.
            let recoveredBulge = arcToBulge(arc)
            XCTAssertEqual(recoveredBulge, bulge, accuracy: 1e-6, "bulge round trip mismatch")
        }
    }

    func testArcToBulgeToArcRoundTrip() {
        let arcs: [CircArc] = [
            CircArc(center: Vec2(0, 0), r: 5, startAngle: 0, sweep: .pi),
            CircArc(center: Vec2(3, -2), r: 2, startAngle: 0.4, sweep: -1.2),
            CircArc(center: Vec2(-1, 1), r: 8, startAngle: 1.0, sweep: 2.8),
        ]
        for arc in arcs {
            let a = Curve2.arc(arc).evaluate(0)
            let b = Curve2.arc(arc).evaluate(abs(arc.sweep))
            let bulge = arcToBulge(arc)
            let rebuilt = bulgeToArc(from: a, to: b, bulge: bulge)
            XCTAssertEqual(rebuilt.r, arc.r, accuracy: 1e-6)
            let rebuiltStart = Curve2.arc(rebuilt).evaluate(0)
            let rebuiltEnd = Curve2.arc(rebuilt).evaluate(abs(rebuilt.sweep))
            XCTAssertLessThan(simd_length(rebuiltStart - a), 1e-6)
            XCTAssertLessThan(simd_length(rebuiltEnd - b), 1e-6)
        }
    }

    // MARK: - NURBS split correctness

    func testNURBSSplitCorrectness() {
        guard case .spline(let n) = sampleSpline() else { XCTFail(); return }
        let domain = n.domain
        let splitU = domain.lowerBound + (domain.upperBound - domain.lowerBound) * 0.42
        guard let (left, right) = n.split(at: splitU) else {
            XCTFail("split failed")
            return
        }
        XCTAssertTrue(left.isValid, "left piece invalid")
        XCTAssertTrue(right.isValid, "right piece invalid")

        // Evaluate the original at several parameters in the left range and
        // compare against the left piece; same for right.
        let leftTestParams = stride(from: domain.lowerBound, to: splitU, by: (splitU - domain.lowerBound) / 5).map { $0 }
        for u in leftTestParams {
            let orig = n.evaluate(u)
            let leftPt = left.evaluate(u)
            XCTAssertLessThan(simd_length(orig - leftPt), 1e-9, "left piece mismatch at u=\(u)")
        }
        let rightTestParams = stride(from: splitU, through: domain.upperBound, by: (domain.upperBound - splitU) / 5).map { $0 }
        for u in rightTestParams {
            let orig = n.evaluate(u)
            let rightPt = right.evaluate(u)
            XCTAssertLessThan(simd_length(orig - rightPt), 1e-9, "right piece mismatch at u=\(u)")
        }
        // The junction point must agree exactly (within tolerance).
        XCTAssertLessThan(simd_length(left.evaluate(splitU) - right.evaluate(splitU)), 1e-9)
        XCTAssertLessThan(simd_length(left.evaluate(splitU) - n.evaluate(splitU)), 1e-9)
    }

    func testCurve2SplineSplitViaEnum() {
        let c = sampleSpline()
        let domain = c.paramDomain
        let splitU = domain.lowerBound + (domain.upperBound - domain.lowerBound) * 0.6
        let pieces = c.split(at: [splitU])
        XCTAssertEqual(pieces.count, 2)
        for piece in pieces {
            guard case .spline(let n) = piece else { XCTFail(); continue }
            XCTAssertTrue(n.isValid)
        }
    }

    // MARK: - length / pointAtLength sanity

    func testSegmentLengthAndPointAtLength() {
        let s = LineSeg(a: Vec2(0, 0), b: Vec2(3, 4))
        let c = Curve2.segment(s)
        XCTAssertEqual(c.length(), 5.0, accuracy: 1e-9)
        let u = c.pointAtLength(2.5)
        XCTAssertEqual(u, 0.5, accuracy: 1e-9)
    }

    func testArcLengthAndPointAtLength() {
        let a = CircArc(center: .zero, r: 2, startAngle: 0, sweep: .pi)
        let c = Curve2.arc(a)
        XCTAssertEqual(c.length(), 2 * .pi, accuracy: 1e-9)
        let u = c.pointAtLength(.pi)
        XCTAssertEqual(u, .pi / 2, accuracy: 1e-9)
    }

    func testCircleIsPeriodic() {
        XCTAssertTrue(sampleCircle().isPeriodic)
        XCTAssertFalse(sampleArc().isPeriodic)
        XCTAssertTrue(sampleFullEllipse().isPeriodic)
        XCTAssertFalse(sampleEllipse().isPeriodic)
    }

    func testCanExtend() {
        XCTAssertTrue(sampleSegment().canExtend)
        XCTAssertTrue(sampleArc().canExtend)
        XCTAssertTrue(sampleCircle().canExtend)
        XCTAssertTrue(sampleEllipse().canExtend)
        XCTAssertFalse(sampleSpline().canExtend)
    }

    // MARK: - out-of-domain evaluate does not crash and extends naturally

    func testOutOfDomainEvaluateExtendsNaturally() {
        let seg = sampleSegment()
        let beyond = seg.evaluate(1.5)
        guard case .segment(let s) = seg else { XCTFail(); return }
        let expected = s.a + (s.b - s.a) * 1.5
        XCTAssertLessThan(simd_length(beyond - expected), 1e-9)

        let arc = sampleArc()
        _ = arc.evaluate(-0.5) // should not crash
        _ = arc.evaluate(100)

        let ellipse = sampleEllipse()
        _ = ellipse.evaluate(ellipse.paramDomain.upperBound + 10)
    }

    // MARK: - Tolerance.forExtents

    func testToleranceForExtents() {
        let t1 = Tolerance.forExtents(diagonal: 1000)
        XCTAssertGreaterThanOrEqual(t1.linear, 1e-9)
        XCTAssertLessThanOrEqual(t1.linear, 1e-4)

        let tHuge = Tolerance.forExtents(diagonal: 1e20)
        XCTAssertEqual(tHuge.linear, 1e-4, accuracy: 1e-12)

        let tTiny = Tolerance.forExtents(diagonal: 1e-20)
        XCTAssertEqual(tTiny.linear, 1e-9, accuracy: 1e-15)
    }
}
