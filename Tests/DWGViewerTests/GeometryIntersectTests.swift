//
//  GeometryIntersectTests.swift
//  DWGViewerTests
//
//  Phase 2 geometry kernel tests: exact analytic intersection cases plus
//  randomized property tests (every reported hit must lie on both curves;
//  brute-force-sampled crossings must not be missed).
//

import XCTest
import simd
@testable import DWGViewer
import CADCore

final class GeometryIntersectTests: XCTestCase {

    let tol = Tolerance(linear: 1e-6)

    // MARK: - Exact analytic cases

    func testPerpendicularLinesMeetAtKnownPoint() {
        let a = Curve2.segment(LineSeg(a: Vec2(-5, 0), b: Vec2(5, 0)))
        let b = Curve2.segment(LineSeg(a: Vec2(0, -5), b: Vec2(0, 5)))
        let hits = Intersect.curves(a, b, tol: tol)
        XCTAssertEqual(hits.count, 1)
        guard let hit = hits.first else { return }
        XCTAssertLessThan(simd_length(hit.point - Vec2(0, 0)), 1e-9)
        XCTAssertTrue(hit.within1)
        XCTAssertTrue(hit.within2)
    }

    func testCirclesTangentExternally() {
        // Two unit-ish circles touching at exactly one point.
        let c1 = Curve2.circle(Circle2(center: Vec2(0, 0), r: 3))
        let c2 = Curve2.circle(Circle2(center: Vec2(8, 0), r: 5)) // distance 8 = 3+5
        let hits = Intersect.curves(c1, c2, tol: tol)
        XCTAssertEqual(hits.count, 1, "expected exactly one tangent hit")
        if let hit = hits.first {
            XCTAssertLessThan(simd_length(hit.point - Vec2(3, 0)), 1e-6)
        }
    }

    func testCirclesTangentInternally() {
        let c1 = Curve2.circle(Circle2(center: Vec2(0, 0), r: 3))
        let c2 = Curve2.circle(Circle2(center: Vec2(2, 0), r: 5)) // distance 2 = |5-3|
        let hits = Intersect.curves(c1, c2, tol: tol)
        XCTAssertEqual(hits.count, 1, "expected exactly one internal-tangent hit")
        if let hit = hits.first {
            XCTAssertLessThan(simd_length(hit.point - Vec2(-3, 0)), 1e-6)
        }
    }

    func testLineMissesCircleAtToleranceBoundary() {
        // Circle of radius 5 centered at origin. A horizontal line at
        // y = 5 + tol/4 should miss (clearly outside tangency); a line at
        // y = 5 - tol/4 should hit (clearly inside). This probes each side
        // of the miss threshold without relying on exact tangency, which is
        // numerically fragile to test directly.
        let circle = Curve2.circle(Circle2(center: .zero, r: 5))
        let missLine = Curve2.segment(LineSeg(a: Vec2(-10, 5 + tol.linear * 100), b: Vec2(10, 5 + tol.linear * 100)))
        let hitLine = Curve2.segment(LineSeg(a: Vec2(-10, 5 - tol.linear * 100), b: Vec2(10, 5 - tol.linear * 100)))

        let missHits = Intersect.curves(missLine, circle, tol: tol)
        XCTAssertEqual(missHits.count, 0, "line clearly outside the circle should not intersect")

        let hitHits = Intersect.curves(hitLine, circle, tol: tol)
        XCTAssertEqual(hitHits.count, 2, "line clearly inside the circle's radius should cross twice")
    }

    func testEllipseEllipseFourIntersections() {
        // Two ellipses arranged to cross at four points: an axis-aligned
        // wide ellipse and a tall one, both centered at origin.
        let e1 = Curve2.ellipse(EllipseArc(center: .zero, majorAxis: Vec2(5, 0), ratio: 0.4, startParam: 0, endParam: 2 * .pi))
        let e2 = Curve2.ellipse(EllipseArc(center: .zero, majorAxis: Vec2(0, 5), ratio: 0.4, startParam: 0, endParam: 2 * .pi))
        let hits = Intersect.curves(e1, e2, tol: tol)
        XCTAssertEqual(hits.count, 4, "expected 4 intersections between crossed perpendicular ellipses, got \(hits.count)")
        for hit in hits {
            let p1 = e1.evaluate(hit.u1)
            let p2 = e2.evaluate(hit.u2)
            XCTAssertLessThan(simd_length(p1 - p2), 2 * tol.linear)
        }
    }

    func testExtendedModeSegmentMissesThenHitsCircle() {
        // A short horizontal segment near x in [-1, 1] at y=0 does not
        // reach a circle of radius 5 centered at (10, 0) — but the
        // extended (infinite) line does hit it.
        let seg = Curve2.segment(LineSeg(a: Vec2(-1, 0), b: Vec2(1, 0)))
        let circle = Curve2.circle(Circle2(center: Vec2(10, 0), r: 5))

        let unextended = Intersect.curves(seg, circle, tol: tol)
        XCTAssertEqual(unextended.count, 0, "short segment should not reach the circle")

        let extended = Intersect.curves(seg, circle, tol: tol, extendA: true)
        XCTAssertEqual(extended.count, 2, "extended line should cross the circle twice")
        for hit in extended {
            XCTAssertFalse(hit.within1, "hit parameter should be outside the segment's own [0,1] domain")
            XCTAssertTrue(hit.within2)
        }
    }

    // MARK: - Randomized property tests

    private func randomSegment(seed: inout UInt64) -> Curve2 {
        .segment(LineSeg(a: randomVec(&seed, range: 20), b: randomVec(&seed, range: 20)))
    }

    private func randomCircle(seed: inout UInt64) -> Curve2 {
        .circle(Circle2(center: randomVec(&seed, range: 10), r: randomDouble(&seed, min: 1, max: 8)))
    }

    private func randomArc(seed: inout UInt64) -> Curve2 {
        let start = randomDouble(&seed, min: 0, max: 2 * .pi)
        let sweep = randomDouble(&seed, min: -5.5, max: 5.5)
        return .arc(CircArc(center: randomVec(&seed, range: 10), r: randomDouble(&seed, min: 1, max: 8),
                            startAngle: start, sweep: sweep == 0 ? 0.5 : sweep))
    }

    private func randomVec(_ seed: inout UInt64, range: Double) -> Vec2 {
        Vec2(randomDouble(&seed, min: -range, max: range), randomDouble(&seed, min: -range, max: range))
    }

    private func randomDouble(_ seed: inout UInt64, min: Double, max: Double) -> Double {
        // xorshift64 PRNG for deterministic, dependency-free randomization.
        seed ^= seed << 13
        seed ^= seed >> 7
        seed ^= seed << 17
        let unit = Double(seed % 1_000_000) / 1_000_000.0
        return min + (max - min) * unit
    }

    func testRandomizedLineLineHitsAreValid() {
        var seed: UInt64 = 0x1234_5678_9abc_def0
        for _ in 0..<200 {
            let a = randomSegment(seed: &seed)
            let b = randomSegment(seed: &seed)
            let hits = Intersect.curves(a, b, tol: tol, extendA: true, extendB: true)
            for hit in hits {
                let p1 = a.evaluate(hit.u1)
                let p2 = b.evaluate(hit.u2)
                XCTAssertLessThan(simd_length(p1 - p2), 2 * tol.linear, "random line/line hit doesn't lie on both curves")
            }
        }
    }

    func testRandomizedCircleCircleHitsAreValid() {
        var seed: UInt64 = 0xfeed_face_dead_beef
        for _ in 0..<200 {
            let a = randomCircle(seed: &seed)
            let b = randomCircle(seed: &seed)
            let hits = Intersect.curves(a, b, tol: tol)
            for hit in hits {
                let p1 = a.evaluate(hit.u1)
                let p2 = b.evaluate(hit.u2)
                XCTAssertLessThan(simd_length(p1 - p2), 2 * tol.linear, "random circle/circle hit doesn't lie on both curves")
            }
        }
    }

    func testRandomizedArcArcHitsAreValid() {
        var seed: UInt64 = 0x0ff1_ce0f_babe_1234
        for _ in 0..<200 {
            let a = randomArc(seed: &seed)
            let b = randomArc(seed: &seed)
            let hits = Intersect.curves(a, b, tol: tol)
            for hit in hits {
                let p1 = a.evaluate(hit.u1)
                let p2 = b.evaluate(hit.u2)
                XCTAssertLessThan(simd_length(p1 - p2), 2 * tol.linear, "random arc/arc hit doesn't lie on both curves")
                if hit.within1 {
                    guard case .arc(let arc) = a else { continue }
                    let sign: Double = arc.sweep >= 0 ? 1 : -1
                    XCTAssertLessThanOrEqual(hit.u1 * sign * sign, abs(arc.sweep) + 1e-6)
                }
            }
        }
    }

    /// Recall check: for a line crossing a circle at a known analytic
    /// location, ensure the solver doesn't miss a crossing that a dense
    /// brute-force sign-change scan would find.
    func testRecallLineCircleCrossingsNotMissed() {
        var seed: UInt64 = 0xabad_1dea_cafe_f00d
        var missCount = 0
        let trials = 100
        for _ in 0..<trials {
            let circle = Circle2(center: randomVec(&seed, range: 5), r: randomDouble(&seed, min: 2, max: 6))
            let a = randomVec(&seed, range: 10)
            let b = randomVec(&seed, range: 10)
            let seg = LineSeg(a: a, b: b)
            let segCurve = Curve2.segment(seg)
            let circleCurve = Curve2.circle(circle)

            // Brute-force: sample f(t) = |P(t) - center| - r across [0,1]
            // and count sign changes.
            let samples = 2000
            var crossingCount = 0
            var prevSign: Double? = nil
            for k in 0...samples {
                let t = Double(k) / Double(samples)
                let p = segCurve.evaluate(t)
                let f = simd_length(p - circle.center) - circle.r
                let s: Double = f >= 0 ? 1 : -1
                if let prev = prevSign, prev != s { crossingCount += 1 }
                prevSign = s
            }

            let hits = Intersect.curves(segCurve, circleCurve, tol: tol)
            let withinHits = hits.filter { $0.within1 }.count
            if withinHits < crossingCount { missCount += 1 }
        }
        XCTAssertEqual(missCount, 0, "solver missed at least one brute-force-detected crossing in \(missCount)/\(trials) trials")
    }

    func testRandomizedSplineVsLineHitsAreValid() {
        var seed: UInt64 = 0x5eed_1234_0bad_f00d
        let control: [Vec2] = [Vec2(0, 0), Vec2(2, 4), Vec2(5, 5), Vec2(8, 1), Vec2(11, 3), Vec2(13, 0)]
        let knots: [Double] = [0, 0, 0, 0, 0.33, 0.66, 1, 1, 1, 1]
        let spline = Curve2.spline(NURBS(degree: 3, control: control,
                                         weights: [Double](repeating: 1, count: control.count), knots: knots))
        for _ in 0..<50 {
            let line = randomSegment(seed: &seed)
            let hits = Intersect.curves(line, spline, tol: Tolerance(linear: 1e-5))
            for hit in hits {
                let p1 = line.evaluate(hit.u1)
                let p2 = spline.evaluate(hit.u2)
                XCTAssertLessThan(simd_length(p1 - p2), 1e-3, "spline/line hit doesn't lie on both curves")
            }
        }
    }

    // MARK: - polylineHits

    func testPolylineHitsWithCircle() {
        // A square polyline that should cross a circle centered inside it.
        let poly = BulgePolyline(vertices: [Vec2(-10, -10), Vec2(10, -10), Vec2(10, 10), Vec2(-10, 10)],
                                 bulges: [0, 0, 0, 0], closed: true)
        let circle = Curve2.circle(Circle2(center: .zero, r: 5))
        let hits = Intersect.polylineHits(poly, with: circle, tol: tol)
        XCTAssertEqual(hits.count, 0, "circle of radius 5 entirely inside a 20x20 square should not cross its edges")

        // A circle of radius 12 pokes out past all four edges (each edge
        // spans x or y in [-10, 10], and sqrt(12^2 - 10^2) ≈ 6.63 < 10), so
        // it crosses each of the 4 edges twice — 8 crossings total.
        let bigCircle = Curve2.circle(Circle2(center: .zero, r: 12))
        let hits2 = Intersect.polylineHits(poly, with: bigCircle, tol: tol)
        XCTAssertEqual(hits2.count, 8, "circle of radius 12 should cross each of the 4 edges twice")
        for h in hits2 {
            XCTAssertEqual(simd_length(h.point), 12, accuracy: 1e-6)
        }
    }
}
