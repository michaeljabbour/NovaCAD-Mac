//
//  EntityCurveBridgeTests.swift
//  DWGViewerTests
//
//  Direct EntityStore construction (no file I/O) covering the
//  EntityStore <-> Curve2 bridge that TRIM/EXTEND/FILLET/CHAMFER/OFFSET all
//  depend on. Arc angle conversion gets the most scrutiny here since a
//  plausible-but-wrong sign/direction error would silently corrupt every
//  downstream trim/extend/fillet result without any single symmetric
//  round-trip test being able to catch it (see the module-level adversarial-
//  review note in the phase's final report).
//

import XCTest
import simd
@testable import DWGViewer
import CADCore

final class EntityCurveBridgeTests: XCTestCase {

    private func makeStore() -> EntityStore { EntityStore() }

    @discardableResult
    private func addLine(_ store: EntityStore, _ a: Vec2, _ b: Vec2) -> EntityID {
        store.append(EntityPrototype(type: .line, layerId: 0,
                                     payload: .line(LinePayload(a: Vec3(x: a.x, y: a.y), b: Vec3(x: b.x, y: b.y)))))
    }

    @discardableResult
    private func addArc(_ store: EntityStore, center: Vec2, r: Double, startDeg: Double, endDeg: Double) -> EntityID {
        store.append(EntityPrototype(type: .arc, layerId: 0,
                                     payload: .arc(ArcPayload(center: Vec3(x: center.x, y: center.y), radius: r,
                                                              startAngleDeg: startDeg, endAngleDeg: endDeg))))
    }

    @discardableResult
    private func addCircle(_ store: EntityStore, center: Vec2, r: Double) -> EntityID {
        store.append(EntityPrototype(type: .circle, layerId: 0,
                                     payload: .circle(CirclePayload(center: Vec3(x: center.x, y: center.y), radius: r))))
    }

    @discardableResult
    private func addPolyline(_ store: EntityStore, _ verts: [Vec2], _ bulges: [Double], closed: Bool) -> EntityID {
        store.append(EntityPrototype(type: .lwpolyline, layerId: 0,
                                     payload: .polyline(PolylinePayload(closed: closed),
                                                        vertices: verts.map { Vec3(x: $0.x, y: $0.y) }, bulges: bulges)))
    }

    // MARK: - Line

    func testLineBridgesToSegment() {
        let store = makeStore()
        let id = addLine(store, Vec2(0, 0), Vec2(10, 0))
        let curves = EntityCurveBridge.curves(for: id, in: store)
        XCTAssertEqual(curves.count, 1)
        guard case .segment(let s) = curves[0].curve else { return XCTFail("expected segment") }
        XCTAssertEqual(s.a, Vec2(0, 0)); XCTAssertEqual(s.b, Vec2(10, 0))
        XCTAssertNil(curves[0].polySegmentIndex)
    }

    // MARK: - Arc angle conversion — the load-bearing, easy-to-get-subtly-wrong case

    /// A quarter arc from 0deg to 90deg (CCW) must sweep exactly +90deg
    /// (+pi/2), not -90 (a sign error) and not 270 (a "always take the long
    /// way" error) — three plausible-but-wrong alternatives a coefficient
    /// bug could produce, all individually distinguishable by this one case.
    func testArcQuarterSweepCCW() {
        let store = makeStore()
        let id = addArc(store, center: .zero, r: 5, startDeg: 0, endDeg: 90)
        let curves = EntityCurveBridge.curves(for: id, in: store)
        guard case .arc(let a) = curves[0].curve else { return XCTFail("expected arc") }
        XCTAssertEqual(a.startAngle, 0, accuracy: 1e-9)
        XCTAssertEqual(a.sweep, .pi / 2, accuracy: 1e-9, "90deg CCW arc must have sweep = +pi/2, not -pi/2 or 3pi/2")
        // Evaluate at the midpoint parameter and check it actually lands at 45deg.
        let mid = Curve2.arc(a).evaluate(a.sweep / 2)
        XCTAssertEqual(mid.x, 5 * cos(.pi / 4), accuracy: 1e-9)
        XCTAssertEqual(mid.y, 5 * sin(.pi / 4), accuracy: 1e-9)
    }

    /// An arc crossing the 0/360 boundary (start=350, end=10) must sweep
    /// +20deg through 360/0, NOT -340deg and not treat it as a backwards arc.
    func testArcCrossingZeroBoundarySweepsShortWayForward() {
        let store = makeStore()
        let id = addArc(store, center: .zero, r: 1, startDeg: 350, endDeg: 10)
        let curves = EntityCurveBridge.curves(for: id, in: store)
        guard case .arc(let a) = curves[0].curve else { return XCTFail("expected arc") }
        XCTAssertEqual(a.sweep, 20 * .pi / 180, accuracy: 1e-9)
    }

    /// startDeg == endDeg (raw) is DXF's convention for a FULL circle
    /// authored as an ARC (some tools do this) — must become a near-2*pi
    /// sweep, not a degenerate zero-sweep arc that would vanish from every
    /// intersection/trim search.
    func testArcWithEqualStartEndBecomesFullSweepNotDegenerate() {
        let store = makeStore()
        let id = addArc(store, center: .zero, r: 3, startDeg: 45, endDeg: 45)
        let curves = EntityCurveBridge.curves(for: id, in: store)
        guard case .arc(let a) = curves[0].curve else { return XCTFail("expected arc") }
        XCTAssertEqual(a.sweep, 2 * .pi, accuracy: 1e-9)
    }

    /// Round-trip: bridge an arc in, convert back to a payload via
    /// `standalonePayload`, and confirm the re-derived start/end degrees
    /// match the original within tolerance — catches an end-to-end sign
    /// error that a one-directional test could miss.
    func testArcRoundTripsThroughStandalonePayload() {
        let store = makeStore()
        let id = addArc(store, center: Vec2(2, 3), r: 7, startDeg: 30, endDeg: 200)
        let curves = EntityCurveBridge.curves(for: id, in: store)
        guard case .arc(let a) = curves[0].curve else { return XCTFail("expected arc") }
        guard case .arc(let payload)? = EntityCurveBridge.standalonePayload(for: .arc(a)) else { return XCTFail("expected arc payload") }
        XCTAssertEqual(payload.startAngleDeg, 30, accuracy: 1e-6)
        XCTAssertEqual(payload.endAngleDeg, 200, accuracy: 1e-6)
        XCTAssertEqual(payload.center.x, 2, accuracy: 1e-9)
        XCTAssertEqual(payload.radius, 7, accuracy: 1e-9)
    }

    /// A CW-swept CircArc (negative sweep — as EXTEND/FILLET math might
    /// produce internally before writing back) must still round-trip to
    /// correct CCW-convention DXF start/end degrees.
    func testNegativeSweepArcRoundTripsToCorrectCCWDegrees() {
        // Build a CircArc directly (not via the bridge) representing a CW arc
        // from 90deg to 0deg (i.e. physically the same arc as CCW 0->90, but
        // constructed with a negative sweep the way a reversed() curve would).
        let arc = CircArc(center: .zero, r: 4, startAngle: .pi / 2, sweep: -(.pi / 2))
        guard case .arc(let payload)? = EntityCurveBridge.standalonePayload(for: .arc(arc)) else { return XCTFail("expected arc payload") }
        // Physically this arc spans exactly the same points as CCW 0->90;
        // DXF's convention demands start < end going CCW, so the payload's
        // startAngleDeg must be 0 and endAngleDeg 90 (swapped from the
        // CircArc's own start/end), not 90/0 (which would encode the wrong,
        // reflex 270-degree arc when read back as CCW).
        XCTAssertEqual(payload.startAngleDeg, 0, accuracy: 1e-6)
        XCTAssertEqual(payload.endAngleDeg, 90, accuracy: 1e-6)
    }

    // MARK: - Circle

    func testCircleBridgesToCircle() {
        let store = makeStore()
        let id = addCircle(store, center: Vec2(1, 1), r: 2)
        let curves = EntityCurveBridge.curves(for: id, in: store)
        guard case .circle(let c) = curves[0].curve else { return XCTFail("expected circle") }
        XCTAssertEqual(c.center, Vec2(1, 1)); XCTAssertEqual(c.r, 2)
    }

    // MARK: - Polyline (bulge preservation)

    func testPolylineBridgesEverySegmentWithCorrectIndex() {
        let store = makeStore()
        // Square: 4 straight segments, no bulges, closed.
        let verts = [Vec2(0, 0), Vec2(10, 0), Vec2(10, 10), Vec2(0, 10)]
        let id = addPolyline(store, verts, [0, 0, 0, 0], closed: true)
        let curves = EntityCurveBridge.curves(for: id, in: store)
        XCTAssertEqual(curves.count, 4)
        for (i, ec) in curves.enumerated() {
            XCTAssertEqual(ec.polySegmentIndex, i)
            guard case .segment = ec.curve else { return XCTFail("expected segment at \(i)") }
        }
    }

    func testPolylineWithBulgeProducesArcSegment() {
        let store = makeStore()
        // Semicircle bulge (bulge = 1.0 => 180deg sweep) from (0,0) to (10,0).
        let verts = [Vec2(0, 0), Vec2(10, 0)]
        let id = addPolyline(store, verts, [1.0, 0.0], closed: false)
        let curves = EntityCurveBridge.curves(for: id, in: store)
        XCTAssertEqual(curves.count, 1)
        guard case .arc(let a) = curves[0].curve else { return XCTFail("expected arc from bulge") }
        XCTAssertEqual(abs(a.sweep), .pi, accuracy: 1e-6)
    }

    func testFullPolylineRoundTripsVerticesAndBulges() {
        let store = makeStore()
        let verts = [Vec2(0, 0), Vec2(10, 0), Vec2(10, 10)]
        let bulges = [0.5, 0.0, -0.5]
        let id = addPolyline(store, verts, bulges, closed: true)
        guard let poly = EntityCurveBridge.fullPolyline(for: id, in: store) else { return XCTFail("expected polyline") }
        XCTAssertEqual(poly.vertices, verts)
        XCTAssertEqual(poly.bulges, bulges)
        XCTAssertTrue(poly.closed)
    }

    // MARK: - Non-curve entities yield nothing

    func testTextEntityYieldsNoCurves() {
        let store = makeStore()
        let sid = store.strings.intern("hello")
        let id = store.append(EntityPrototype(type: .text, layerId: 0,
                                              payload: .text(TextPayload(position: Vec3(x: 0, y: 0), height: 1, stringId: sid))))
        XCTAssertTrue(EntityCurveBridge.curves(for: id, in: store).isEmpty)
    }

    func testDeletedEntityYieldsNoCurves() {
        let store = makeStore()
        let id = addLine(store, .zero, Vec2(1, 1))
        store.markDeleted(id)
        XCTAssertTrue(EntityCurveBridge.curves(for: id, in: store).isEmpty)
    }

    // MARK: - Spline

    func testSplineBridgesToValidNURBS() {
        let store = makeStore()
        let control = [Vec2(0, 0), Vec2(1, 2), Vec2(2, 2), Vec2(3, 0)]
        let n = SplineFit.interpolate(fitPoints: control, closed: false)
        let payload = EntityCurveBridge.splinePayload(for: n)
        let id = store.append(EntityPrototype(type: .spline, layerId: 0, payload: payload))
        let curves = EntityCurveBridge.curves(for: id, in: store)
        XCTAssertEqual(curves.count, 1)
        guard case .spline(let bridged) = curves[0].curve else { return XCTFail("expected spline") }
        XCTAssertTrue(bridged.isValid)
        XCTAssertEqual(bridged.control.count, n.control.count)
    }
}
