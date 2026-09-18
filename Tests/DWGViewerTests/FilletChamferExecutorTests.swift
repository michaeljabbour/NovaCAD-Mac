//
//  FilletChamferExecutorTests.swift
//  DWGViewerTests
//
//  Integration-level tests: real RegenCoordinator + DXFDocument, exercising
//  FilletChamferExecutor.resolveFillet/resolveChamfer/apply end-to-end
//  through a real Transaction commit, incl. TRIMMODE on/off.
//

import XCTest
import CoreGraphics
@testable import DWGViewer
import CADCore

final class FilletChamferExecutorTests: XCTestCase {

    let tol = Tolerance(linear: 1e-6)

    private func makeCoordinator() throws -> RegenCoordinator {
        try RegenCoordinator.load(url: TestFixtures.url("basic_entities.dxf"))
    }

    @discardableResult
    private func addLine(_ rc: RegenCoordinator, _ a: CGPoint, _ b: CGPoint) -> EntityID {
        var id: EntityID!
        rc.parsed.document.transact("Line") { tx in
            id = tx.add(EntityPrototype(type: .line, layerId: 0, payload: .line(LinePayload(a: Vec3(x: Double(a.x), y: Double(a.y)), b: Vec3(x: Double(b.x), y: Double(b.y))))))
        }
        _ = rc.apply(rc.parsed.document.undoStack.last!.ops)
        return id
    }

    func testFilletEndToEndTrimModeOnAddsArcAndTrimsBothLines() throws {
        let rc = try makeCoordinator()
        // Use a location far from basic_entities.dxf's own fixture content.
        let ox: Double = 5000
        let h = addLine(rc, CGPoint(x: ox - 10, y: 0), CGPoint(x: ox + 10, y: 0))
        let v = addLine(rc, CGPoint(x: ox, y: -10), CGPoint(x: ox, y: 10))

        guard let request = FilletChamferExecutor.resolveFillet(
            id1: h, click1: CGPoint(x: ox + 5, y: 0), id2: v, click2: CGPoint(x: ox, y: 5),
            radius: 2, store: rc.parsed.store, tol: tol) else {
            return XCTFail("expected a resolved fillet request")
        }

        var connectorId: EntityID?
        rc.parsed.document.transact("Fillet") { tx in
            connectorId = FilletChamferExecutor.apply(request, trimMode: true, layerId1: 0, to: tx)
        }
        _ = rc.apply(rc.parsed.document.undoStack.last!.ops)

        guard let connectorId else { return XCTFail("expected a new connector entity") }
        guard let ch = rc.parsed.store.header(connectorId), ch.type == .arc else { return XCTFail("expected an ARC connector") }
        let arc = rc.parsed.store.arcs[Int(ch.payload)]
        XCTAssertEqual(arc.center.x, ox + 2, accuracy: 1e-6)
        XCTAssertEqual(arc.center.y, 2, accuracy: 1e-6)
        XCTAssertEqual(arc.radius, 2, accuracy: 1e-6)

        // Both original lines must be MODIFIED IN PLACE (not deleted+replaced —
        // TRIMMODE uses modifyPayload) to their tangent feet.
        XCTAssertFalse(rc.parsed.store.isDeleted(h))
        XCTAssertFalse(rc.parsed.store.isDeleted(v))
        let hLine = rc.parsed.store.lines[Int(rc.parsed.store.header(h)!.payload)]
        let vLine = rc.parsed.store.lines[Int(rc.parsed.store.header(v)!.payload)]
        XCTAssertTrue([hLine.a.x, hLine.b.x].contains { abs($0 - (ox + 2)) < 1e-6 }, "horizontal line must be trimmed to its tangent foot at ox+2")
        XCTAssertTrue([vLine.a.y, vLine.b.y].contains { abs($0 - 2) < 1e-6 }, "vertical line must be trimmed to its tangent foot at y=2")
    }

    func testFilletTrimModeOffLeavesOriginalLinesUntouched() throws {
        let rc = try makeCoordinator()
        let ox: Double = 6000
        let h = addLine(rc, CGPoint(x: ox - 10, y: 0), CGPoint(x: ox + 10, y: 0))
        let v = addLine(rc, CGPoint(x: ox, y: -10), CGPoint(x: ox, y: 10))
        guard let request = FilletChamferExecutor.resolveFillet(
            id1: h, click1: CGPoint(x: ox + 5, y: 0), id2: v, click2: CGPoint(x: ox, y: 5),
            radius: 2, store: rc.parsed.store, tol: tol) else {
            return XCTFail("expected a resolved fillet request")
        }
        let hBefore = rc.parsed.store.lines[Int(rc.parsed.store.header(h)!.payload)]
        let vBefore = rc.parsed.store.lines[Int(rc.parsed.store.header(v)!.payload)]

        rc.parsed.document.transact("Fillet") { tx in
            _ = FilletChamferExecutor.apply(request, trimMode: false, layerId1: 0, to: tx)
        }
        _ = rc.apply(rc.parsed.document.undoStack.last!.ops)

        let hAfter = rc.parsed.store.lines[Int(rc.parsed.store.header(h)!.payload)]
        let vAfter = rc.parsed.store.lines[Int(rc.parsed.store.header(v)!.payload)]
        XCTAssertEqual(hBefore.a.x, hAfter.a.x, accuracy: 1e-9, "TRIMMODE=0 must leave line 1 completely untouched")
        XCTAssertEqual(hBefore.b.x, hAfter.b.x, accuracy: 1e-9)
        XCTAssertEqual(vBefore.a.y, vAfter.a.y, accuracy: 1e-9, "TRIMMODE=0 must leave line 2 completely untouched")
        XCTAssertEqual(vBefore.b.y, vAfter.b.y, accuracy: 1e-9)
    }

    func testChamferEndToEndAddsSegmentConnector() throws {
        let rc = try makeCoordinator()
        let ox: Double = 7000
        let h = addLine(rc, CGPoint(x: ox - 10, y: 0), CGPoint(x: ox + 10, y: 0))
        let v = addLine(rc, CGPoint(x: ox, y: -10), CGPoint(x: ox, y: 10))
        guard let request = FilletChamferExecutor.resolveChamfer(
            id1: h, click1: CGPoint(x: ox + 5, y: 0), id2: v, click2: CGPoint(x: ox, y: 5),
            d1: 3, d2: 3, angleMode: false, store: rc.parsed.store, tol: tol) else {
            return XCTFail("expected a resolved chamfer request")
        }
        var connectorId: EntityID?
        rc.parsed.document.transact("Chamfer") { tx in
            connectorId = FilletChamferExecutor.apply(request, trimMode: true, layerId1: 0, to: tx)
        }
        _ = rc.apply(rc.parsed.document.undoStack.last!.ops)
        guard let connectorId, let ch = rc.parsed.store.header(connectorId), ch.type == .line else {
            return XCTFail("expected a LINE connector")
        }
        let seg = rc.parsed.store.lines[Int(ch.payload)]
        let pts = [(seg.a.x, seg.a.y), (seg.b.x, seg.b.y)]
        XCTAssertTrue(pts.contains { abs($0.0 - (ox + 3)) < 1e-6 && abs($0.1 - 0) < 1e-6 })
        XCTAssertTrue(pts.contains { abs($0.0 - ox) < 1e-6 && abs($0.1 - 3) < 1e-6 })
    }

    func testResolveFilletReturnsNilForNonLineEntities() throws {
        let rc = try makeCoordinator()
        var circleId: EntityID!
        rc.parsed.document.transact("Circle") { tx in
            circleId = tx.add(EntityPrototype(type: .circle, layerId: 0, payload: .circle(CirclePayload(center: Vec3(x: 8000, y: 0), radius: 5))))
        }
        _ = rc.apply(rc.parsed.document.undoStack.last!.ops)
        let line = addLine(rc, CGPoint(x: 8000, y: 5), CGPoint(x: 8010, y: 5))
        let request = FilletChamferExecutor.resolveFillet(id1: circleId, click1: CGPoint(x: 8005, y: 0), id2: line, click2: CGPoint(x: 8005, y: 5),
                                                          radius: 2, store: rc.parsed.store, tol: tol)
        XCTAssertNil(request, "fillet between a circle and a line is out of scope for this pass and must return nil, not crash")
    }
}
