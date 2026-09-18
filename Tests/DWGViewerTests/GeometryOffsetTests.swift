//
//  GeometryOffsetTests.swift
//  DWGViewerTests
//
//  Phase 2 geometry kernel tests: primitive offsets and the full polyline
//  offset join/trim/chain pipeline.
//

import XCTest
import simd
@testable import DWGViewer
import CADCore

final class GeometryOffsetTests: XCTestCase {

    let tol = Tolerance(linear: 1e-6)

    // MARK: - Rectangle offset (closed, all-segment BulgePolyline)

    func rectangle(minX: Double = 0, minY: Double = 0, maxX: Double = 20, maxY: Double = 10) -> BulgePolyline {
        BulgePolyline(vertices: [Vec2(minX, minY), Vec2(maxX, minY), Vec2(maxX, maxY), Vec2(minX, maxY)],
                     bulges: [0, 0, 0, 0], closed: true)
    }

    func testRectangleOffsetOutward() {
        let rect = rectangle()
        let results = Offset.polyline(rect, distance: 2, side: .left, tol: tol)
        XCTAssertFalse(results.isEmpty, "outward offset of a rectangle should produce at least one loop")
        guard let result = results.first else { return }
        XCTAssertEqual(result.segmentCount, 4, "rectangle offset should retain 4 corners")
        // Every segment midpoint should be at distance 2 from the nearest
        // original edge.
        for i in 0..<result.segmentCount {
            let seg = result.segmentCurve(i)
            let mid = seg.evaluate((seg.paramDomain.lowerBound + seg.paramDomain.upperBound) / 2)
            let dist = distanceToPolyline(mid, rect)
            XCTAssertEqual(dist, 2, accuracy: 1e-3, "offset segment not at correct distance from original")
        }
    }

    func testRectangleOffsetInward() {
        let rect = rectangle()
        let results = Offset.polyline(rect, distance: 2, side: .right, tol: tol)
        XCTAssertFalse(results.isEmpty, "inward offset of a rectangle should produce at least one loop")
        guard let result = results.first else { return }
        XCTAssertEqual(result.segmentCount, 4)
        for i in 0..<result.segmentCount {
            let seg = result.segmentCurve(i)
            let mid = seg.evaluate((seg.paramDomain.lowerBound + seg.paramDomain.upperBound) / 2)
            let dist = distanceToPolyline(mid, rect)
            XCTAssertEqual(dist, 2, accuracy: 1e-3)
        }
    }

    // MARK: - L-shaped concave polyline requiring self-intersection trim

    func lShape() -> BulgePolyline {
        // An L-shape (concave at one corner), traversed CCW.
        let verts: [Vec2] = [
            Vec2(0, 0), Vec2(10, 0), Vec2(10, 4), Vec2(4, 4), Vec2(4, 10), Vec2(0, 10)
        ]
        return BulgePolyline(vertices: verts, bulges: [Double](repeating: 0, count: verts.count), closed: true)
    }

    func testLShapeInwardOffsetRequiringTrim() {
        let shape = lShape()
        // Offset inward (right side for a CCW polyline) by an amount large
        // enough to force self-intersection trimming near the concave
        // corner at (4,4).
        let d = 3.0
        let results = Offset.polyline(shape, distance: d, side: .right, tol: tol)
        XCTAssertFalse(results.isEmpty, "L-shape inward offset should still produce output")

        for result in results {
            // No self-intersections: check all pairwise segment
            // intersections among the result's own segments are only at
            // shared endpoints (adjacent segments).
            let n = result.segmentCount
            for i in 0..<n {
                for j in (i + 1)..<n {
                    let segI = result.segmentCurve(i)
                    let segJ = result.segmentCurve(j)
                    let adjacent = (j == i + 1) || (i == 0 && j == n - 1)
                    let hits = Intersect.curves(segI, segJ, tol: tol)
                    let interiorHits = hits.filter { hit in
                        let onInteriorI = hit.u1 > 0.02 && hit.u1 < 0.98
                        let onInteriorJ = hit.u2 > 0.02 && hit.u2 < 0.98
                        return hit.within1 && hit.within2 && (onInteriorI || onInteriorJ || !adjacent)
                    }
                    if !adjacent {
                        XCTAssertTrue(interiorHits.isEmpty, "result has a self-intersection between non-adjacent segments \(i),\(j)")
                    }
                }
            }
            // Every point should be at distance d from the original shape
            // (within tolerance).
            for i in 0..<result.segmentCount {
                let seg = result.segmentCurve(i)
                let mid = seg.evaluate((seg.paramDomain.lowerBound + seg.paramDomain.upperBound) / 2)
                let dist = distanceToPolyline(mid, shape)
                XCTAssertEqual(dist, d, accuracy: 1e-2, "offset atom not at correct distance from original L-shape")
            }
        }
    }

    // MARK: - Polyline with a bulge, offset both ways

    func testBulgePolylineOffsetBothWaysChangesRadius() {
        // A simple two-segment polyline: a straight segment then an arc
        // (via bulge = 1, a semicircle) back — open polyline.
        let verts: [Vec2] = [Vec2(0, 0), Vec2(10, 0)]
        let bulges: [Double] = [1.0, 0.0]
        let poly = BulgePolyline(vertices: verts, bulges: bulges, closed: false)

        guard case .arc(let originalArc) = poly.segmentCurve(0) else {
            XCTFail("expected first segment to be an arc")
            return
        }

        let d = 1.5
        let outward = Offset.polyline(poly, distance: d, side: .left, tol: tol)
        let inward = Offset.polyline(poly, distance: d, side: .right, tol: tol)

        XCTAssertFalse(outward.isEmpty)
        XCTAssertFalse(inward.isEmpty)

        if let outResult = outward.first, outResult.segmentCount > 0,
           case .arc(let outArc) = outResult.segmentCurve(0) {
            XCTAssertEqual(abs(abs(outArc.r) - abs(originalArc.r)), d, accuracy: 1e-2,
                          "outward-offset arc radius should differ from original by exactly d")
        }
        if let inResult = inward.first, inResult.segmentCount > 0,
           case .arc(let inArc) = inResult.segmentCurve(0) {
            XCTAssertEqual(abs(abs(inArc.r) - abs(originalArc.r)), d, accuracy: 1e-2,
                          "inward-offset arc radius should differ from original by exactly d")
        }
    }

    // MARK: - Circle offset inward past its own radius

    func testCircleOffsetInwardPastRadiusReturnsNil() {
        let c = Circle2(center: .zero, r: 5)
        let result = Offset.circle(c, 6, outward: false)
        XCTAssertNil(result, "offsetting a circle inward by more than its radius should return nil")

        let okResult = Offset.circle(c, 3, outward: false)
        XCTAssertNotNil(okResult)
        XCTAssertEqual(okResult?.r ?? -1, 2, accuracy: 1e-9)
    }

    func testArcOffsetCollapseReturnsNil() {
        // Offsetting an arc "outward on the concave side" past its own
        // radius should collapse to nil.
        let a = CircArc(center: .zero, r: 3, startAngle: 0, sweep: .pi / 2)
        let collapsed = Offset.arc(a, 5, .right)
        XCTAssertNil(collapsed)

        let ok = Offset.arc(a, 1, .left)
        XCTAssertNotNil(ok)
    }

    // MARK: - SplineFit.interpolate

    func testSplineFitInterpolatesThroughFitPoints() {
        let points: [Vec2] = [Vec2(0, 0), Vec2(2, 3), Vec2(5, 4), Vec2(8, 1), Vec2(11, 2), Vec2(14, 0)]
        let n = SplineFit.interpolate(fitPoints: points, closed: false)
        XCTAssertTrue(n.isValid)
        let curve = Curve2.spline(n)
        let domain = n.domain
        // Chord-length parameterization means fit point i sits at uBar_i;
        // recompute those to check interpolation exactly.
        var chordLens = [Double](repeating: 0, count: points.count)
        var total = 0.0
        for i in 1..<points.count {
            total += simd_length(points[i] - points[i - 1])
            chordLens[i] = total
        }
        for i in 0..<points.count {
            let u = domain.lowerBound + (domain.upperBound - domain.lowerBound) * (chordLens[i] / total)
            let p = curve.evaluate(u)
            XCTAssertLessThan(simd_length(p - points[i]), 1e-9, "fit point \(i) not reproduced exactly")
        }
    }

    func testSplineFitClosedC1ContinuityAtSeam() {
        let points: [Vec2] = [Vec2(5, 0), Vec2(3.5, 3.5), Vec2(0, 5), Vec2(-3.5, 3.5), Vec2(-5, 0), Vec2(-3.5, -3.5), Vec2(0, -5), Vec2(3.5, -3.5)]
        let n = SplineFit.interpolate(fitPoints: points, closed: true)
        XCTAssertTrue(n.isValid)
        guard n.isValid else { return }
        let curve = Curve2.spline(n)
        let domain = n.domain
        let startTangent = curve.tangent(domain.lowerBound)
        let endTangent = curve.tangent(domain.upperBound)
        // Loose tolerance: check the tangent directions at the seam aren't
        // wildly discontinuous (dot product close to 1, i.e. small angle).
        let dot = simd_dot(startTangent, endTangent)
        XCTAssertGreaterThan(dot, 0.7, "seam tangent directions should be roughly continuous for a closed fit")
    }

    func testSplineFitDedupesCoincidentPoints() {
        let points: [Vec2] = [Vec2(0, 0), Vec2(0, 0), Vec2(1, 1), Vec2(2, 0)]
        let n = SplineFit.interpolate(fitPoints: points, closed: false)
        XCTAssertTrue(n.isValid, "deduping coincident points should still produce a valid spline")
    }

    // MARK: - Offset.spline sanity

    func testOffsetSplineStaysApproximatelyParallel() {
        let control: [Vec2] = [Vec2(0, 0), Vec2(2, 4), Vec2(5, 5), Vec2(8, 1), Vec2(11, 3), Vec2(13, 0)]
        let knots: [Double] = [0, 0, 0, 0, 0.33, 0.66, 1, 1, 1, 1]
        let n = NURBS(degree: 3, control: control, weights: [Double](repeating: 1, count: control.count), knots: knots)
        let offsetN = Offset.spline(n, 1.0, .left, tol: Tolerance(linear: 1e-4))
        XCTAssertTrue(offsetN.isValid)
        guard offsetN.isValid else { return }
        let original = Curve2.spline(n)
        let offsetCurve = Curve2.spline(offsetN)
        let domain = original.paramDomain
        for k in 0...10 {
            let u = domain.lowerBound + (domain.upperBound - domain.lowerBound) * Double(k) / 10.0
            let p = original.evaluate(u)
            let (_, _, dist) = offsetCurve.closestPoint(to: p, tol: Tolerance(linear: 1e-4))
            XCTAssertEqual(dist, 1.0, accuracy: 0.15, "offset spline should stay roughly 1.0 away from the original")
        }
    }

    // MARK: - Helpers

    private func distanceToPolyline(_ p: Vec2, _ poly: BulgePolyline) -> Double {
        var best = Double.infinity
        for i in 0..<poly.segmentCount {
            let seg = poly.segmentCurve(i)
            let (_, _, dist) = seg.closestPoint(to: p, tol: tol)
            best = min(best, dist)
        }
        return best
    }
}
