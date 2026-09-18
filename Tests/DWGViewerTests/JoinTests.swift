import XCTest
@testable import DWGViewer
import CADCore
import simd

/// Tests for `Join.swift` — the pure chaining/collinearity geometry behind
/// the JOIN command. UI wiring (selection acquisition, commit) is exercised
/// via `JoinExecutor` + the app; this covers the geometry, which is where
/// correctness matters.
final class JoinTests: XCTestCase {

    private let tol = Tolerance(linear: 1e-6)
    private func id(_ n: Int32) -> EntityID { EntityID(raw: n) }
    private func seg(_ ax: Double, _ ay: Double, _ bx: Double, _ by: Double) -> Curve2 {
        .segment(LineSeg(a: Vec2(ax, ay), b: Vec2(bx, by)))
    }

    func testTwoCollinearLinesMergeIntoOneLine() {
        let inputs = [
            JoinInput(sourceId: id(1), curve: seg(0, 0, 5, 0)),
            JoinInput(sourceId: id(2), curve: seg(5, 0, 10, 0)),
        ]
        let results = Join.join(inputs, tol: tol)
        XCTAssertEqual(results.count, 1)
        guard case .line(let a, let b) = results[0].shape else { return XCTFail("expected .line") }
        XCTAssertEqual(a, Vec2(0, 0))
        XCTAssertEqual(b, Vec2(10, 0))
        XCTAssertEqual(Set(results[0].sourceIds), [id(1), id(2)])
    }

    func testCollinearLinesMergeRegardlessOfInputOrderAndDirection() {
        // Second segment is reversed (10,0)->(5,0); should still merge.
        let inputs = [
            JoinInput(sourceId: id(2), curve: seg(10, 0, 5, 0)),
            JoinInput(sourceId: id(1), curve: seg(0, 0, 5, 0)),
        ]
        let results = Join.join(inputs, tol: tol)
        XCTAssertEqual(results.count, 1)
        guard case .line(let a, let b) = results[0].shape else { return XCTFail("expected .line") }
        // Endpoints are the two far ends, in whichever order the chain grew.
        XCTAssertTrue((a == Vec2(0, 0) && b == Vec2(10, 0)) || (a == Vec2(10, 0) && b == Vec2(0, 0)))
    }

    func testTwoPerpendicularSegmentsBecomeAPolyline() {
        let inputs = [
            JoinInput(sourceId: id(1), curve: seg(0, 0, 10, 0)),
            JoinInput(sourceId: id(2), curve: seg(10, 0, 10, 10)),
        ]
        let results = Join.join(inputs, tol: tol)
        XCTAssertEqual(results.count, 1)
        guard case .polyline(let verts, let bulges, let closed) = results[0].shape else { return XCTFail("expected .polyline") }
        XCTAssertFalse(closed)
        XCTAssertEqual(verts, [Vec2(0, 0), Vec2(10, 0), Vec2(10, 10)])
        XCTAssertEqual(bulges, [0, 0, 0])
    }

    func testAContiguousLoopBecomesAClosedPolyline() {
        // Square, four segments, endpoints meeting back at the start.
        let inputs = [
            JoinInput(sourceId: id(1), curve: seg(0, 0, 10, 0)),
            JoinInput(sourceId: id(2), curve: seg(10, 0, 10, 10)),
            JoinInput(sourceId: id(3), curve: seg(10, 10, 0, 10)),
            JoinInput(sourceId: id(4), curve: seg(0, 10, 0, 0)),
        ]
        let results = Join.join(inputs, tol: tol)
        XCTAssertEqual(results.count, 1)
        guard case .polyline(let verts, _, let closed) = results[0].shape else { return XCTFail("expected .polyline") }
        XCTAssertTrue(closed, "a chain whose ends meet must be a CLOSED polyline")
        XCTAssertEqual(verts.count, 4, "closed polyline drops the duplicated closing vertex")
    }

    func testNonTouchingSegmentsDoNotJoin() {
        let inputs = [
            JoinInput(sourceId: id(1), curve: seg(0, 0, 5, 0)),
            JoinInput(sourceId: id(2), curve: seg(100, 100, 105, 100)),
        ]
        XCTAssertTrue(Join.join(inputs, tol: tol).isEmpty, "disjoint segments have nothing to join")
    }

    func testSingleCurveProducesNoResult() {
        let inputs = [JoinInput(sourceId: id(1), curve: seg(0, 0, 5, 0))]
        XCTAssertTrue(Join.join(inputs, tol: tol).isEmpty)
    }

    func testTwoContiguousArcsMergeIntoOneArc() {
        // Two 45-degree arcs on the same unit circle, contiguous 0->45->90.
        let a1 = CircArc(center: Vec2(0, 0), r: 10, startAngle: 0, sweep: .pi / 4)
        let a2 = CircArc(center: Vec2(0, 0), r: 10, startAngle: .pi / 4, sweep: .pi / 4)
        let inputs = [
            JoinInput(sourceId: id(1), curve: .arc(a1)),
            JoinInput(sourceId: id(2), curve: .arc(a2)),
        ]
        let results = Join.join(inputs, tol: tol)
        XCTAssertEqual(results.count, 1)
        guard case .arc(let merged) = results[0].shape else { return XCTFail("expected .arc") }
        XCTAssertEqual(merged.r, 10, accuracy: 1e-9)
        XCTAssertEqual(merged.sweep, .pi / 2, accuracy: 1e-9, "45+45 = 90 degree merged sweep")
    }

    func testLineMeetingArcBecomesPolylineWithBulge() {
        // A line ending at (10,0), then a 90-degree arc from (10,0).
        let arc = CircArc(center: Vec2(10, 10), r: 10, startAngle: -.pi / 2, sweep: .pi / 2)
        let inputs = [
            JoinInput(sourceId: id(1), curve: seg(0, 0, 10, 0)),
            JoinInput(sourceId: id(2), curve: .arc(arc)),
        ]
        let results = Join.join(inputs, tol: tol)
        XCTAssertEqual(results.count, 1)
        guard case .polyline(let verts, let bulges, _) = results[0].shape else { return XCTFail("expected .polyline") }
        XCTAssertEqual(verts.first, Vec2(0, 0))
        XCTAssertEqual(bulges.first, 0, "first (straight) segment has zero bulge")
        XCTAssertNotEqual(bulges[1], 0, accuracy: 0, "the arc segment carries a non-zero bulge")
    }

    func testTwoSeparateChainsProduceTwoResults() {
        let inputs = [
            JoinInput(sourceId: id(1), curve: seg(0, 0, 5, 0)),
            JoinInput(sourceId: id(2), curve: seg(5, 0, 10, 0)),
            JoinInput(sourceId: id(3), curve: seg(100, 0, 105, 0)),
            JoinInput(sourceId: id(4), curve: seg(105, 0, 110, 0)),
        ]
        let results = Join.join(inputs, tol: tol)
        XCTAssertEqual(results.count, 2, "two disjoint contiguous runs → two joined results")
    }

    // MARK: - JoinExecutor (store round-trip)

    private func lineProto(_ ax: Double, _ ay: Double, _ bx: Double, _ by: Double) -> EntityPrototype {
        EntityPrototype(type: .line, layerId: 3, payload: .line(LinePayload(a: Vec3(x: ax, y: ay), b: Vec3(x: bx, y: by))))
    }

    func testExecutorMergesTwoCollinearLinesIntoOneLineOnSameLayer() throws {
        let doc = EditableDocument()
        let id1 = doc.store.append(lineProto(0, 0, 5, 0))
        let id2 = doc.store.append(lineProto(5, 0, 10, 0))
        let req = try XCTUnwrap(JoinExecutor.resolveJoin(ids: [id1, id2], store: doc.store, tol: tol))
        var created: [EntityID] = []
        doc.transact("Join") { tx in created = JoinExecutor.apply(req, to: tx) }
        // Both sources gone, exactly one new entity, on the inherited layer.
        XCTAssertTrue(doc.store.isDeleted(id1) || doc.store.isDeleted(id2))
        XCTAssertEqual(created.count, 1)
        let h = try XCTUnwrap(doc.store.header(created[0]))
        XCTAssertEqual(h.type, .line)
        XCTAssertEqual(h.layerId, 3, "merged entity inherits the source layer")
    }

    func testExecutorMergesPerpendicularSegmentsIntoAPolyline() throws {
        let doc = EditableDocument()
        let id1 = doc.store.append(lineProto(0, 0, 10, 0))
        let id2 = doc.store.append(lineProto(10, 0, 10, 10))
        let req = try XCTUnwrap(JoinExecutor.resolveJoin(ids: [id1, id2], store: doc.store, tol: tol))
        var created: [EntityID] = []
        doc.transact("Join") { tx in created = JoinExecutor.apply(req, to: tx) }
        XCTAssertEqual(created.count, 1)
        let h = try XCTUnwrap(doc.store.header(created[0]))
        XCTAssertEqual(h.type, .lwpolyline)
    }

    func testExecutorJoinIsUndoable() throws {
        let doc = EditableDocument()
        let id1 = doc.store.append(lineProto(0, 0, 5, 0))
        let id2 = doc.store.append(lineProto(5, 0, 10, 0))
        let req = try XCTUnwrap(JoinExecutor.resolveJoin(ids: [id1, id2], store: doc.store, tol: tol))
        doc.transact("Join") { tx in JoinExecutor.apply(req, to: tx) }
        doc.undo()
        XCTAssertFalse(doc.store.isDeleted(id1), "undo restores the first source line")
        XCTAssertFalse(doc.store.isDeleted(id2), "undo restores the second source line")
    }

    func testExecutorReturnsNilWhenNothingJoins() {
        let doc = EditableDocument()
        let id1 = doc.store.append(lineProto(0, 0, 5, 0))
        let id2 = doc.store.append(lineProto(100, 100, 105, 100))
        XCTAssertNil(JoinExecutor.resolveJoin(ids: [id1, id2], store: doc.store, tol: tol))
    }
}
