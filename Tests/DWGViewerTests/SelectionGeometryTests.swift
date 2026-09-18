import XCTest
@testable import DWGViewer
import CADCore

final class SelectionGeometryTests: XCTestCase {

    private let rect = RectRegion(minX: 0, minY: 0, maxX: 10, maxY: 10)

    // MARK: - segmentIntersectsRect (table-driven)

    private struct SegRectCase {
        let name: String
        let a: Vec2, b: Vec2
        let expected: Bool
    }

    private let segRectCases: [SegRectCase] = [
        SegRectCase(name: "both endpoints inside", a: Vec2(2, 2), b: Vec2(8, 8), expected: true),
        SegRectCase(name: "both endpoints outside, no crossing (far away)",
                    a: Vec2(20, 20), b: Vec2(30, 30), expected: false),
        SegRectCase(name: "crosses straight through (outside to outside)",
                    a: Vec2(-5, 5), b: Vec2(15, 5), expected: true),
        SegRectCase(name: "one endpoint inside, one outside",
                    a: Vec2(5, 5), b: Vec2(20, 5), expected: true),
        SegRectCase(name: "touches a single corner",
                    a: Vec2(-5, -5), b: Vec2(0, 0), expected: true),
        SegRectCase(name: "grazes an edge (collinear with bottom edge, overlapping)",
                    a: Vec2(-2, 0), b: Vec2(2, 0), expected: true),
        SegRectCase(name: "collinear with bottom edge but entirely outside its extent",
                    a: Vec2(-10, 0), b: Vec2(-5, 0), expected: false),
        SegRectCase(name: "parallel to an edge, offset outside — never crosses",
                    a: Vec2(-5, 20), b: Vec2(20, 20), expected: false),
        SegRectCase(name: "diagonal miss (stays in the quadrant beyond one corner)",
                    a: Vec2(-5, -1), b: Vec2(-1, -5), expected: false),
        SegRectCase(name: "diagonal hit through opposite corners region",
                    a: Vec2(-5, -5), b: Vec2(15, 15), expected: true),
        SegRectCase(name: "degenerate point segment inside", a: Vec2(5, 5), b: Vec2(5, 5), expected: true),
        SegRectCase(name: "degenerate point segment outside", a: Vec2(50, 50), b: Vec2(50, 50), expected: false),
        SegRectCase(name: "vertical segment crossing", a: Vec2(5, -5), b: Vec2(5, 15), expected: true),
        SegRectCase(name: "vertical segment outside", a: Vec2(50, -5), b: Vec2(50, 15), expected: false),
    ]

    func testSegmentIntersectsRectTable() {
        for c in segRectCases {
            XCTAssertEqual(SelGeom.segmentIntersectsRect(c.a, c.b, rect), c.expected,
                          "\(c.name): \(c.a) -> \(c.b)")
            // Symmetry: reversing the segment must not change the result.
            XCTAssertEqual(SelGeom.segmentIntersectsRect(c.b, c.a, rect), c.expected,
                          "\(c.name) (reversed): \(c.b) -> \(c.a)")
        }
    }

    // MARK: - segmentsIntersect (table-driven)

    private struct SegSegCase {
        let name: String
        let p1: Vec2, p2: Vec2, q1: Vec2, q2: Vec2
        let expected: Bool
    }

    private let segSegCases: [SegSegCase] = [
        SegSegCase(name: "simple X crossing", p1: Vec2(0, 0), p2: Vec2(10, 10),
                   q1: Vec2(0, 10), q2: Vec2(10, 0), expected: true),
        SegSegCase(name: "parallel, no overlap", p1: Vec2(0, 0), p2: Vec2(10, 0),
                   q1: Vec2(0, 5), q2: Vec2(10, 5), expected: false),
        SegSegCase(name: "collinear overlapping", p1: Vec2(0, 0), p2: Vec2(10, 0),
                   q1: Vec2(5, 0), q2: Vec2(15, 0), expected: true),
        SegSegCase(name: "collinear non-overlapping", p1: Vec2(0, 0), p2: Vec2(5, 0),
                   q1: Vec2(10, 0), q2: Vec2(15, 0), expected: false),
        SegSegCase(name: "collinear touching at one point", p1: Vec2(0, 0), p2: Vec2(5, 0),
                   q1: Vec2(5, 0), q2: Vec2(10, 0), expected: true),
        SegSegCase(name: "touching at shared endpoint (T junction)", p1: Vec2(0, 0), p2: Vec2(10, 0),
                   q1: Vec2(5, 0), q2: Vec2(5, 10), expected: true),
        SegSegCase(name: "disjoint, not even close", p1: Vec2(0, 0), p2: Vec2(1, 1),
                   q1: Vec2(100, 100), q2: Vec2(200, 200), expected: false),
        SegSegCase(name: "one segment fully misses the other's extent", p1: Vec2(0, 0), p2: Vec2(10, 0),
                   q1: Vec2(20, -5), q2: Vec2(20, 5), expected: false),
        SegSegCase(name: "near miss just past the endpoint", p1: Vec2(0, 0), p2: Vec2(10, 0),
                   q1: Vec2(10.001, -5), q2: Vec2(10.001, 5), expected: false),
    ]

    func testSegmentsIntersectTable() {
        for c in segSegCases {
            XCTAssertEqual(SelGeom.segmentsIntersect(c.p1, c.p2, c.q1, c.q2), c.expected, c.name)
            // Symmetry under swapping which segment is "first".
            XCTAssertEqual(SelGeom.segmentsIntersect(c.q1, c.q2, c.p1, c.p2), c.expected, "\(c.name) (swapped)")
        }
    }

    // MARK: - arcIntersectsRect (table-driven)

    private struct ArcRectCase {
        let name: String
        let center: Vec2, radius: Double, startDeg: Double, sweepDeg: Double
        let rect: RectRegion
        let expected: Bool
    }

    private func deg(_ d: Double) -> Double { d * .pi / 180 }

    private let arcRectCases: [ArcRectCase] = [
        // Quarter circle centered at origin, from 0 to 90 degrees, radius 5.
        // Its arc passes through (5,0) and (0,5) and bulges through (3.5,3.5).
        ArcRectCase(name: "rect entirely encloses the arc",
                   center: Vec2(0, 0), radius: 5, startDeg: 0, sweepDeg: 90,
                   rect: RectRegion(minX: -10, minY: -10, maxX: 10, maxY: 10), expected: true),
        ArcRectCase(name: "rect far away, no intersection",
                   center: Vec2(0, 0), radius: 5, startDeg: 0, sweepDeg: 90,
                   rect: RectRegion(minX: 100, minY: 100, maxX: 110, maxY: 110), expected: false),
        ArcRectCase(name: "one endpoint of the arc inside a small rect",
                   center: Vec2(0, 0), radius: 5, startDeg: 0, sweepDeg: 90,
                   rect: RectRegion(minX: 4, minY: -1, maxX: 6, maxY: 1), expected: true),
        ArcRectCase(name: "rect crosses the arc's bulge but no endpoint inside",
                   center: Vec2(0, 0), radius: 5, startDeg: 0, sweepDeg: 90,
                   rect: RectRegion(minX: 3, minY: 3, maxX: 4, maxY: 4), expected: true),
        ArcRectCase(name: "rect straddles the full circle's ring but on the non-swept side",
                   center: Vec2(0, 0), radius: 5, startDeg: 0, sweepDeg: 90,
                   // Same rect as the "full circle" case below (straddles
                   // the ring at ~200 degrees) — but this arc only sweeps
                   // 0-90 degrees, so that ring crossing must NOT count.
                   rect: RectRegion(minX: -5.7, minY: -2.7, maxX: -3.7, maxY: -0.7), expected: false),
        ArcRectCase(name: "full circle (sweep 360) always hit by a rect crossing its ring",
                   center: Vec2(0, 0), radius: 5, startDeg: 0, sweepDeg: 360,
                   // Straddles the ring at angle ~200 degrees (point
                   // (-4.70,-1.71) lies on the circle), on the opposite side
                   // from the swept quarter used by the other cases here —
                   // proves the FULL sweep (not just the 0-90 quarter) is
                   // actually being tested.
                   rect: RectRegion(minX: -5.7, minY: -2.7, maxX: -3.7, maxY: -0.7), expected: true),
        ArcRectCase(name: "rect exactly at the arc midpoint region",
                   center: Vec2(0, 0), radius: 5, startDeg: 0, sweepDeg: 90,
                   rect: RectRegion(minX: 3.3, minY: 3.3, maxX: 3.7, maxY: 3.7), expected: true),
        ArcRectCase(name: "circle's bbox misses rect entirely (cheap early-out)",
                   center: Vec2(0, 0), radius: 1, startDeg: 0, sweepDeg: 90,
                   rect: RectRegion(minX: 50, minY: 50, maxX: 60, maxY: 60), expected: false),
    ]

    func testArcIntersectsRectTable() {
        for c in arcRectCases {
            let got = SelGeom.arcIntersectsRect(center: c.center, radius: c.radius,
                                                startAngle: deg(c.startDeg), sweep: deg(c.sweepDeg),
                                                rect: c.rect)
            XCTAssertEqual(got, c.expected, c.name)
        }
    }

    func testArcIntersectsRectDegenerateZeroRadius() {
        let rect = RectRegion(minX: -1, minY: -1, maxX: 1, maxY: 1)
        XCTAssertTrue(SelGeom.arcIntersectsRect(center: Vec2(0, 0), radius: 0, startAngle: 0, sweep: 1, rect: rect))
        XCTAssertFalse(SelGeom.arcIntersectsRect(center: Vec2(10, 10), radius: 0, startAngle: 0, sweep: 1, rect: rect))
    }

    // MARK: - pointInPolygon (table-driven)

    private let square: [Vec2] = [Vec2(0, 0), Vec2(10, 0), Vec2(10, 10), Vec2(0, 10)]
    // Concave "L" shape.
    private let lShape: [Vec2] = [Vec2(0, 0), Vec2(10, 0), Vec2(10, 5), Vec2(5, 5), Vec2(5, 10), Vec2(0, 10)]

    private struct PointInPolyCase {
        let name: String
        let point: Vec2
        let polygon: [Vec2]
        let expected: Bool
    }

    private var pointInPolyCases: [PointInPolyCase] {
        [
            PointInPolyCase(name: "center of square", point: Vec2(5, 5), polygon: square, expected: true),
            PointInPolyCase(name: "outside square", point: Vec2(20, 20), polygon: square, expected: false),
            PointInPolyCase(name: "inside the L's notch removal area (outside the L)",
                            point: Vec2(8, 8), polygon: lShape, expected: false),
            PointInPolyCase(name: "inside the L's remaining body",
                            point: Vec2(2, 8), polygon: lShape, expected: true),
            PointInPolyCase(name: "inside the L's lower-right arm",
                            point: Vec2(8, 2), polygon: lShape, expected: true),
            PointInPolyCase(name: "degenerate polygon (2 points)", point: Vec2(1, 1),
                            polygon: [Vec2(0, 0), Vec2(1, 1)], expected: false),
        ]
    }

    func testPointInPolygonTable() {
        for c in pointInPolyCases {
            XCTAssertEqual(SelGeom.pointInPolygon(c.point, c.polygon), c.expected, c.name)
        }
    }

    // MARK: - segmentIntersectsPolygon

    func testSegmentIntersectsPolygonFullyInside() {
        XCTAssertTrue(SelGeom.segmentIntersectsPolygon(Vec2(2, 2), Vec2(8, 8), square))
    }

    func testSegmentIntersectsPolygonCrossesBoundary() {
        XCTAssertTrue(SelGeom.segmentIntersectsPolygon(Vec2(-5, 5), Vec2(15, 5), square))
    }

    func testSegmentIntersectsPolygonEntirelyOutside() {
        XCTAssertFalse(SelGeom.segmentIntersectsPolygon(Vec2(20, 20), Vec2(30, 30), square))
    }

    func testSegmentIntersectsPolygonConcaveMiss() {
        // A segment that would be "inside the bounding box" of the L but
        // actually passes only through the notched-out area.
        XCTAssertFalse(SelGeom.segmentIntersectsPolygon(Vec2(6, 6), Vec2(9, 9), lShape))
    }

    // MARK: - rectFullyContainsPolyline

    func testRectFullyContainsPolylineAllInside() {
        let rect = RectRegion(minX: 0, minY: 0, maxX: 10, maxY: 10)
        XCTAssertTrue(SelGeom.rectFullyContainsPolyline([Vec2(1, 1), Vec2(5, 5), Vec2(9, 9)], rect))
    }

    func testRectFullyContainsPolylineOneOutside() {
        let rect = RectRegion(minX: 0, minY: 0, maxX: 10, maxY: 10)
        XCTAssertFalse(SelGeom.rectFullyContainsPolyline([Vec2(1, 1), Vec2(5, 5), Vec2(20, 20)], rect))
    }

    func testRectFullyContainsPolylineEmptyIsFalse() {
        let rect = RectRegion(minX: 0, minY: 0, maxX: 10, maxY: 10)
        XCTAssertFalse(SelGeom.rectFullyContainsPolyline([], rect))
    }

    func testRectFullyContainsPolylineBoundaryTouchingCountsAsContained() {
        let rect = RectRegion(minX: 0, minY: 0, maxX: 10, maxY: 10)
        XCTAssertTrue(SelGeom.rectFullyContainsPolyline([Vec2(0, 0), Vec2(10, 10)], rect))
    }

    // MARK: - RectRegion basics

    func testRectRegionNormalizesMinMax() {
        let r = RectRegion(minX: 10, minY: 10, maxX: 0, maxY: 0)
        XCTAssertEqual(r.minX, 0); XCTAssertEqual(r.maxX, 10)
        XCTAssertEqual(r.minY, 0); XCTAssertEqual(r.maxY, 10)
    }

    func testRectRegionEdgesFormAClosedLoop() {
        let r = RectRegion(minX: 0, minY: 0, maxX: 10, maxY: 10)
        let edges = r.edges()
        XCTAssertEqual(edges.count, 4)
        // Each edge's end must equal the next edge's start (closed loop).
        for i in 0..<edges.count {
            let next = edges[(i + 1) % edges.count]
            XCTAssertEqual(edges[i].1, next.0)
        }
    }
}
