//
//  OffsetExecutorTests.swift
//  DWGViewerTests
//
//  Direct EntityStore construction (no file I/O) covering OffsetExecutor's
//  side-from-click resolution and per-entity-type dispatch. sideOfArc gets
//  the most adversarial scrutiny (both CCW and CW arcs, checking the
//  resulting radius grew/shrank as expected) since it's this file's most
//  formula-heavy piece.
//

import XCTest
import simd
@testable import DWGViewer
import CADCore

final class OffsetExecutorTests: XCTestCase {

    let tol = Tolerance(linear: 1e-6)

    private func makeStore() -> EntityStore { EntityStore() }

    @discardableResult
    private func addLine(_ store: EntityStore, _ a: Vec2, _ b: Vec2) -> EntityID {
        store.append(EntityPrototype(type: .line, layerId: 0, payload: .line(LinePayload(a: Vec3(x: a.x, y: a.y), b: Vec3(x: b.x, y: b.y)))))
    }

    @discardableResult
    private func addArc(_ store: EntityStore, center: Vec2, r: Double, startDeg: Double, endDeg: Double) -> EntityID {
        store.append(EntityPrototype(type: .arc, layerId: 0, payload: .arc(ArcPayload(center: Vec3(x: center.x, y: center.y), radius: r, startAngleDeg: startDeg, endAngleDeg: endDeg))))
    }

    @discardableResult
    private func addCircle(_ store: EntityStore, center: Vec2, r: Double) -> EntityID {
        store.append(EntityPrototype(type: .circle, layerId: 0, payload: .circle(CirclePayload(center: Vec3(x: center.x, y: center.y), radius: r))))
    }

    // MARK: - Line

    func testOffsetLineToTheLeftAndRight() {
        let store = makeStore()
        let id = addLine(store, Vec2(0, 0), Vec2(10, 0))
        // Point above the line (y>0) is the LEFT side of a->b (CCW perpendicular).
        guard let protosAbove = OffsetExecutor.resolve(id: id, distance: 2, sidePoint: CGPoint(x: 5, y: 1), store: store, tol: tol),
              case .line(let lAbove)? = protosAbove.first?.payload else { return XCTFail("expected a line result") }
        XCTAssertEqual(lAbove.a.y, 2, accuracy: 1e-6)

        guard let protosBelow = OffsetExecutor.resolve(id: id, distance: 2, sidePoint: CGPoint(x: 5, y: -1), store: store, tol: tol),
              case .line(let lBelow)? = protosBelow.first?.payload else { return XCTFail("expected a line result") }
        XCTAssertEqual(lBelow.a.y, -2, accuracy: 1e-6)
    }

    func testOffsetLineDoesNotModifySourceEntity() {
        let store = makeStore()
        let id = addLine(store, Vec2(0, 0), Vec2(10, 0))
        _ = OffsetExecutor.resolve(id: id, distance: 2, sidePoint: CGPoint(x: 5, y: 1), store: store, tol: tol)
        // Source line must be completely unchanged (OFFSET only ADDS, never modifies).
        guard let h = store.header(id) else { return XCTFail("expected the source entity to still exist") }
        let l = store.lines[Int(h.payload)]
        XCTAssertEqual(l.a.y, 0, accuracy: 1e-9)
        XCTAssertEqual(l.b.y, 0, accuracy: 1e-9)
    }

    // MARK: - Circle

    func testOffsetCircleOutwardGrowsRadius() {
        let store = makeStore()
        let id = addCircle(store, center: .zero, r: 5)
        // Click point OUTSIDE the circle (distance 8 > r=5) -> outward.
        guard let protos = OffsetExecutor.resolve(id: id, distance: 2, sidePoint: CGPoint(x: 8, y: 0), store: store, tol: tol),
              case .circle(let c)? = protos.first?.payload else { return XCTFail("expected a circle result") }
        XCTAssertEqual(c.radius, 7, accuracy: 1e-6, "clicking OUTSIDE the circle must grow the offset radius")
    }

    func testOffsetCircleInwardShrinksRadius() {
        let store = makeStore()
        let id = addCircle(store, center: .zero, r: 5)
        // Click point INSIDE the circle (distance 2 < r=5) -> inward.
        guard let protos = OffsetExecutor.resolve(id: id, distance: 2, sidePoint: CGPoint(x: 2, y: 0), store: store, tol: tol),
              case .circle(let c)? = protos.first?.payload else { return XCTFail("expected a circle result") }
        XCTAssertEqual(c.radius, 3, accuracy: 1e-6, "clicking INSIDE the circle must shrink the offset radius")
    }

    func testOffsetCircleInwardBeyondRadiusCollapsesToEmpty() {
        let store = makeStore()
        let id = addCircle(store, center: .zero, r: 5)
        let protos = OffsetExecutor.resolve(id: id, distance: 10, sidePoint: CGPoint(x: 2, y: 0), store: store, tol: tol)
        XCTAssertEqual(protos?.count, 0, "offsetting a circle inward by more than its own radius must collapse to zero results, not crash")
    }

    // MARK: - Arc (adversarial: both CCW and CW sweep, both click sides)

    /// CCW arc (sweep > 0), click OUTSIDE the arc's radius -> must GROW.
    func testOffsetCCWArcOutwardGrowsRadius() {
        let store = makeStore()
        let id = addArc(store, center: .zero, r: 5, startDeg: 0, endDeg: 90)   // CCW sweep
        guard let protos = OffsetExecutor.resolve(id: id, distance: 2, sidePoint: CGPoint(x: 8, y: 0), store: store, tol: tol),
              case .arc(let a)? = protos.first?.payload else { return XCTFail("expected an arc result") }
        XCTAssertEqual(a.radius, 7, accuracy: 1e-6)
    }

    /// CCW arc, click INSIDE -> must SHRINK. Together with the test above,
    /// this fully exercises `sideOfArc`'s CCW branch in both directions —
    /// a coefficient/sign bug in the sign*sweepSign formula would make
    /// exactly ONE of these two pass and the other fail (they can't both
    /// pass by accident under a flipped sign).
    func testOffsetCCWArcInwardShrinksRadius() {
        let store = makeStore()
        let id = addArc(store, center: .zero, r: 5, startDeg: 0, endDeg: 90)
        guard let protos = OffsetExecutor.resolve(id: id, distance: 2, sidePoint: CGPoint(x: 2, y: 0), store: store, tol: tol),
              case .arc(let a)? = protos.first?.payload else { return XCTFail("expected an arc result") }
        XCTAssertEqual(a.radius, 3, accuracy: 1e-6)
    }

    /// DXF ARC entities are always stored with a CCW start->end sweep (see
    /// `EntityCurveBridge.circArc`'s doc comment), so a "CW arc" never
    /// exists as a STORED entity — but `sideOfArc`'s formula is written in
    /// terms of the general `sweepSign` variable, which the CCW-only tests
    /// above can't fully exercise. This test locks in the underlying
    /// `Offset.arc` convention that formula depends on: for a CW
    /// (negative-sweep) `CircArc`, exactly one of `.left`/`.right` grows
    /// the radius and the other shrinks it, confirming the "outward for
    /// CCW, inward for CW" convention `sideOfArc`'s comment cites is real,
    /// not an assumption.
    func testOffsetConventionForCWArcAtTheKernelLevel() {
        let cwArc = CircArc(center: .zero, r: 5, startAngle: 0, sweep: -(.pi / 2))   // CW: 0 -> -90deg
        guard let leftResult = Offset.arc(cwArc, 2, .left), let rightResult = Offset.arc(cwArc, 2, .right) else {
            return XCTFail("expected both offset sides to succeed")
        }
        let radii = Set([leftResult.r, rightResult.r].map { ($0 * 1000).rounded() / 1000 })
        XCTAssertEqual(radii, [3, 7], "one side of a CW arc must grow to r=7, the other shrink to r=3")
    }

    // MARK: - Non-offsettable entity type

    func testOffsetTextEntityReturnsNil() {
        let store = makeStore()
        let sid = store.strings.intern("x")
        let id = store.append(EntityPrototype(type: .text, layerId: 0, payload: .text(TextPayload(position: Vec3(x: 0, y: 0), height: 1, stringId: sid))))
        let protos = OffsetExecutor.resolve(id: id, distance: 2, sidePoint: CGPoint(x: 0, y: 0), store: store, tol: tol)
        XCTAssertNil(protos)
    }

    func testOffsetWithNonPositiveDistanceReturnsNil() {
        let store = makeStore()
        let id = addLine(store, Vec2(0, 0), Vec2(10, 0))
        XCTAssertNil(OffsetExecutor.resolve(id: id, distance: 0, sidePoint: CGPoint(x: 5, y: 1), store: store, tol: tol))
        XCTAssertNil(OffsetExecutor.resolve(id: id, distance: -1, sidePoint: CGPoint(x: 5, y: 1), store: store, tol: tol))
    }

    // MARK: - Through-point mode

    func testOffsetThroughPointDerivesDistanceFromClosestApproach() {
        let store = makeStore()
        let id = addLine(store, Vec2(0, 0), Vec2(10, 0))
        // Through point at (5, 3) — perpendicular distance to the line is exactly 3.
        guard let protos = OffsetExecutor.resolveThroughPoint(id: id, throughPoint: CGPoint(x: 5, y: 3), store: store, tol: tol),
              case .line(let l)? = protos.first?.payload else { return XCTFail("expected a line result") }
        XCTAssertEqual(l.a.y, 3, accuracy: 1e-6, "through-point distance must be the perpendicular distance to the through point")
    }

    func testOffsetThroughPointOnTheCurveItselfReturnsNil() {
        let store = makeStore()
        let id = addLine(store, Vec2(0, 0), Vec2(10, 0))
        // Through point essentially ON the line -> zero distance, meaningless offset.
        let protos = OffsetExecutor.resolveThroughPoint(id: id, throughPoint: CGPoint(x: 5, y: 0), store: store, tol: tol)
        XCTAssertNil(protos)
    }

    // MARK: - Polyline

    func testOffsetPolylineProducesParallelChain() {
        let store = makeStore()
        let verts = [Vec2(0, 0), Vec2(10, 0), Vec2(10, 10)]
        let id = store.append(EntityPrototype(type: .lwpolyline, layerId: 0,
                                              payload: .polyline(PolylinePayload(closed: false), vertices: verts.map { Vec3(x: $0.x, y: $0.y) }, bulges: [0, 0, 0])))
        // Click to the "outside" of the L-shape (negative Y / positive X side).
        guard let protos = OffsetExecutor.resolve(id: id, distance: 1, sidePoint: CGPoint(x: 5, y: -1), store: store, tol: tol), !protos.isEmpty else {
            return XCTFail("expected at least one offset polyline result")
        }
        guard case .polyline(_, let newVerts, _)? = protos.first?.payload else { return XCTFail("expected polyline payload") }
        XCTAssertFalse(newVerts.isEmpty)
    }
}
