import XCTest
import CoreGraphics
@testable import DWGViewer
import CADCore

final class SelectionEngineTests: XCTestCase {

    private func makeCoordinator(_ fixture: String = "basic_entities.dxf") throws -> RegenCoordinator {
        try RegenCoordinator.load(url: TestFixtures.url(fixture))
    }

    private func lineProto(_ a: Vec3, _ b: Vec3, owner: OwnerRef = .model) -> EntityPrototype {
        EntityPrototype(type: .line, layerId: 0, owner: owner, payload: .line(LinePayload(a: a, b: b)))
    }

    private func circleProto(_ center: Vec3, _ r: Double, owner: OwnerRef = .model) -> EntityPrototype {
        EntityPrototype(type: .circle, layerId: 0, owner: owner, payload: .circle(CirclePayload(center: center, radius: r)))
    }

    /// Adds an entity and applies its commit immediately, returning the new id.
    @discardableResult
    private func add(_ rc: RegenCoordinator, _ proto: EntityPrototype) -> EntityID {
        var id: EntityID!
        rc.parsed.document.transact("Draw") { tx in id = tx.add(proto) }
        _ = rc.apply(rc.parsed.document.undoStack.last!.ops)
        return id
    }

    // MARK: - Window vs Crossing produce different results (the plan's core scenario)

    func testWindowSelectsOnlyFullyEnclosedCrossingSelectsIntersecting() throws {
        let rc = try makeCoordinator()
        // Isolated coordinate region (basic_entities.dxf's own content spans
        // roughly x:[0,100], y:[0,200] — offsetting by 10,000 guarantees no
        // incidental coincidence with the fixture's pre-existing geometry, so
        // the exact result-count assertions below are unambiguous).
        let ox = 10_000.0, oy = 10_000.0
        // Fully inside a [0,50]x[0,50] box (relative to the offset).
        let insideId = add(rc, lineProto(Vec3(x: ox + 10, y: oy + 10), Vec3(x: ox + 20, y: oy + 20)))
        // Straddles the box boundary (one endpoint in, one endpoint out).
        let straddlingId = add(rc, lineProto(Vec3(x: ox + 40, y: oy + 40), Vec3(x: ox + 60, y: oy + 60)))
        // Entirely outside.
        let outsideId = add(rc, lineProto(Vec3(x: ox + 100, y: oy + 100), Vec3(x: ox + 110, y: oy + 110)))

        let rect = CGRect(x: ox, y: oy, width: 50, height: 50)
        let windowResult = SelectionEngine.rectSelect(document: rc.document, usePaperSpace: false,
                                                      rect: rect, mode: .window, visibility: VisibilityState())
        let crossingResult = SelectionEngine.rectSelect(document: rc.document, usePaperSpace: false,
                                                        rect: rect, mode: .crossing, visibility: VisibilityState())

        XCTAssertTrue(windowResult.contains(insideId))
        XCTAssertFalse(windowResult.contains(straddlingId), "Window excludes a partially-enclosed entity")
        XCTAssertFalse(windowResult.contains(outsideId))

        XCTAssertTrue(crossingResult.contains(insideId))
        XCTAssertTrue(crossingResult.contains(straddlingId), "Crossing includes a partially-enclosed entity")
        XCTAssertFalse(crossingResult.contains(outsideId))

        XCTAssertNotEqual(windowResult, crossingResult, "the plan's core scenario: different, correct counts")
        XCTAssertEqual(windowResult.count, 1)
        XCTAssertEqual(crossingResult.count, 2)
    }

    func testCrossingSelectsEntityThatOnlyPassesThroughRectWithNoEndpointInside() throws {
        let rc = try makeCoordinator()
        // A long line that passes straight through the rect with BOTH
        // endpoints outside — only a true segment/edge intersection test
        // (not an endpoint-in-rect shortcut) can find this.
        let throughId = add(rc, lineProto(Vec3(x: -100, y: 5), Vec3(x: 100, y: 5)))
        let rect = CGRect(x: 0, y: 0, width: 10, height: 10)

        let windowResult = SelectionEngine.rectSelect(document: rc.document, usePaperSpace: false,
                                                      rect: rect, mode: .window, visibility: VisibilityState())
        let crossingResult = SelectionEngine.rectSelect(document: rc.document, usePaperSpace: false,
                                                        rect: rect, mode: .crossing, visibility: VisibilityState())
        XCTAssertFalse(windowResult.contains(throughId))
        XCTAssertTrue(crossingResult.contains(throughId))
    }

    // MARK: - Circle/arc crossing

    func testCrossingSelectsCircleThatStraddlesRectBoundary() throws {
        let rc = try makeCoordinator()
        // Circle centered at (10,10) radius 8 straddles a rect from (0,0) to (5,5):
        // nearest point of circle to rect is well within reach, but circle CENTER
        // is outside the rect, and the circle is not fully enclosed either.
        let circleId = add(rc, circleProto(Vec3(x: 10, y: 10), 8))
        let rect = CGRect(x: 0, y: 0, width: 5, height: 5)

        let windowResult = SelectionEngine.rectSelect(document: rc.document, usePaperSpace: false,
                                                      rect: rect, mode: .window, visibility: VisibilityState())
        let crossingResult = SelectionEngine.rectSelect(document: rc.document, usePaperSpace: false,
                                                        rect: rect, mode: .crossing, visibility: VisibilityState())
        XCTAssertFalse(windowResult.contains(circleId))
        XCTAssertTrue(crossingResult.contains(circleId))
    }

    func testWindowSelectsCircleFullyEnclosed() throws {
        let rc = try makeCoordinator()
        let circleId = add(rc, circleProto(Vec3(x: 10, y: 10), 2))
        let rect = CGRect(x: 0, y: 0, width: 20, height: 20)
        let windowResult = SelectionEngine.rectSelect(document: rc.document, usePaperSpace: false,
                                                      rect: rect, mode: .window, visibility: VisibilityState())
        XCTAssertTrue(windowResult.contains(circleId))
    }

    // MARK: - Text

    func testCrossingSelectsTextWhoseBoxOverlapsRect() throws {
        let rc = try makeCoordinator()
        var textId: EntityID!
        rc.parsed.document.transact("Draw") { tx in
            let sid = rc.parsed.store.strings.intern("Hello")
            textId = tx.add(EntityPrototype(type: .text, layerId: 0,
                                            payload: .text(TextPayload(position: Vec3(x: 5, y: 5), height: 2, stringId: sid))))
        }
        _ = rc.apply(rc.parsed.document.undoStack.last!.ops)

        // A small rect near the text's anchor should catch it under Crossing.
        let rect = CGRect(x: 4, y: 4, width: 3, height: 3)
        let crossingResult = SelectionEngine.rectSelect(document: rc.document, usePaperSpace: false,
                                                        rect: rect, mode: .crossing, visibility: VisibilityState())
        XCTAssertTrue(crossingResult.contains(textId))

        // A rect far away should not.
        let farRect = CGRect(x: 500, y: 500, width: 3, height: 3)
        let farResult = SelectionEngine.rectSelect(document: rc.document, usePaperSpace: false,
                                                   rect: farRect, mode: .crossing, visibility: VisibilityState())
        XCTAssertFalse(farResult.contains(textId))
    }

    // MARK: - Whole-block (INSERT) selection

    func testCrossingSelectsWholeInsertWhenAnyChildIntersects() throws {
        let rc = try makeCoordinator("block_insert.dxf")
        // The INSERT places SYMBOL1 (LINE 0,0->10,0 and CIRCLE @5,5 r3) at
        // world (100,100), scale 2, rotation 45. A rect crossing just the
        // circle's world-space area should select the WHOLE insert (AutoCAD
        // block-reference selection semantics), not a loose child primitive.
        let doc = rc.document
        XCTAssertFalse(doc.inserts.isEmpty, "fixture must have loaded at least one insert")
        let insertEntityId = doc.inserts[0].entityId
        XCTAssertGreaterThanOrEqual(insertEntityId, 0, "insert must carry a stable EntityID")

        // A generous rect around the insert's approximate world position
        // (scale 2 roughly doubles the ~10-unit local geometry, rotated 45,
        // translated to (100,100) — a wide box safely covers it without
        // needing exact rotated-bbox math in the test itself).
        let rect = CGRect(x: 80, y: 80, width: 60, height: 60)
        let crossingResult = SelectionEngine.rectSelect(document: doc, usePaperSpace: false,
                                                        rect: rect, mode: .crossing, visibility: VisibilityState())
        XCTAssertTrue(crossingResult.contains(EntityID(raw: insertEntityId)),
                     "crossing a block's child geometry must select the whole INSERT's EntityID")
    }

    func testWindowFullyEnclosingInsertSelectsIt() throws {
        let rc = try makeCoordinator("block_insert.dxf")
        let doc = rc.document
        let insertEntityId = doc.inserts[0].entityId
        // A huge rect enclosing everything.
        let rect = CGRect(x: -1000, y: -1000, width: 2000, height: 2000)
        let windowResult = SelectionEngine.rectSelect(document: doc, usePaperSpace: false,
                                                      rect: rect, mode: .window, visibility: VisibilityState())
        XCTAssertTrue(windowResult.contains(EntityID(raw: insertEntityId)))
    }

    // MARK: - Visibility (locked/hidden layers excluded)

    func testHiddenLayerIsExcludedFromCrossingSelect() throws {
        let rc = try makeCoordinator()
        let id = add(rc, lineProto(Vec3(x: 0, y: 0), Vec3(x: 10, y: 10)))
        let layerId = Int(rc.parsed.store.header(id)!.layerId)

        var vis = VisibilityState()
        vis.hiddenLayerIds.insert(layerId)
        let rect = CGRect(x: -5, y: -5, width: 20, height: 20)
        let result = SelectionEngine.rectSelect(document: rc.document, usePaperSpace: false,
                                                rect: rect, mode: .crossing, visibility: vis)
        XCTAssertFalse(result.contains(id))
    }

    func testLockedLayerIsExcludedFromCrossingSelect() throws {
        let rc = try makeCoordinator()
        let id = add(rc, lineProto(Vec3(x: 0, y: 0), Vec3(x: 10, y: 10)))
        let layerId = Int(rc.parsed.store.header(id)!.layerId)

        var vis = VisibilityState()
        vis.lockedLayerIds.insert(layerId)
        let rect = CGRect(x: -5, y: -5, width: 20, height: 20)
        let result = SelectionEngine.rectSelect(document: rc.document, usePaperSpace: false,
                                                rect: rect, mode: .crossing, visibility: vis)
        XCTAssertFalse(result.contains(id), "locked layers stay visible but are never selectable")
    }

    // MARK: - Lasso

    func testLassoCrossingSelectsInsideConcavePolygon() throws {
        let rc = try makeCoordinator()
        let insideId = add(rc, lineProto(Vec3(x: 1, y: 8), Vec3(x: 2, y: 9)))       // in the L's body
        let notchId = add(rc, lineProto(Vec3(x: 7, y: 7), Vec3(x: 8, y: 8)))        // in the L's removed notch

        // L-shaped lasso polygon (same shape as SelectionGeometryTests' lShape).
        let lasso: [CGPoint] = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 5),
                                CGPoint(x: 5, y: 5), CGPoint(x: 5, y: 10), CGPoint(x: 0, y: 10)]
        let result = SelectionEngine.lassoSelect(document: rc.document, usePaperSpace: false,
                                                 polygon: lasso, mode: .crossing, visibility: VisibilityState())
        XCTAssertTrue(result.contains(insideId))
        XCTAssertFalse(result.contains(notchId), "the notch is OUTSIDE the L polygon, even though it's inside its bbox")
    }

    func testLassoWindowRequiresFullContainment() throws {
        let rc = try makeCoordinator()
        let insideId = add(rc, lineProto(Vec3(x: 1, y: 1), Vec3(x: 2, y: 2)))
        let straddlingId = add(rc, lineProto(Vec3(x: 8, y: 8), Vec3(x: 20, y: 20)))
        let triangle: [CGPoint] = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 0, y: 10)]
        let windowResult = SelectionEngine.lassoSelect(document: rc.document, usePaperSpace: false,
                                                       polygon: triangle, mode: .window, visibility: VisibilityState())
        XCTAssertTrue(windowResult.contains(insideId))
        XCTAssertFalse(windowResult.contains(straddlingId))
    }

    func testLassoWithFewerThanThreePointsSelectsNothing() throws {
        let rc = try makeCoordinator()
        _ = add(rc, lineProto(Vec3(x: 1, y: 1), Vec3(x: 2, y: 2)))
        let result = SelectionEngine.lassoSelect(document: rc.document, usePaperSpace: false,
                                                 polygon: [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)],
                                                 mode: .crossing, visibility: VisibilityState())
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Fence

    func testFenceSelectsEverythingItCrosses() throws {
        let rc = try makeCoordinator()
        let crossedId = add(rc, lineProto(Vec3(x: 0, y: -5), Vec3(x: 0, y: 5)))     // vertical, crosses x=0 at y=0
        let missedId = add(rc, lineProto(Vec3(x: 100, y: -5), Vec3(x: 100, y: 5)))  // far away

        // Horizontal fence along y=0 from x=-10 to x=10.
        let fence: [CGPoint] = [CGPoint(x: -10, y: 0), CGPoint(x: 10, y: 0)]
        let result = SelectionEngine.fenceSelect(document: rc.document, usePaperSpace: false,
                                                 fence: fence, visibility: VisibilityState())
        XCTAssertTrue(result.contains(crossedId))
        XCTAssertFalse(result.contains(missedId))
    }

    func testFenceWithMultiSegmentPath() throws {
        let rc = try makeCoordinator()
        // Fence bends at (5,0): first leg along y=0 from x=-10 to x=5,
        // second leg turns up to (5,10). A vertical line at x=5 crossing
        // y=[3,7] is only caught by the SECOND leg, not the first.
        let id = add(rc, lineProto(Vec3(x: 5, y: 3), Vec3(x: 5, y: 7)))
        let fence: [CGPoint] = [CGPoint(x: -10, y: 0), CGPoint(x: 5, y: 0), CGPoint(x: 5, y: 10)]
        let result = SelectionEngine.fenceSelect(document: rc.document, usePaperSpace: false,
                                                 fence: fence, visibility: VisibilityState())
        XCTAssertTrue(result.contains(id))
    }

    func testFenceWithFewerThanTwoPointsSelectsNothing() throws {
        let rc = try makeCoordinator()
        _ = add(rc, lineProto(Vec3(x: 0, y: 0), Vec3(x: 1, y: 1)))
        let result = SelectionEngine.fenceSelect(document: rc.document, usePaperSpace: false,
                                                 fence: [CGPoint(x: 0, y: 0)], visibility: VisibilityState())
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Tombstoned primitives excluded

    func testTombstonedPrimitiveExcludedFromCrossingSelect() throws {
        let rc = try makeCoordinator()
        let id = add(rc, lineProto(Vec3(x: 0, y: 0), Vec3(x: 10, y: 10)))
        rc.parsed.document.transact("Erase") { tx in tx.delete(id) }
        _ = rc.apply(rc.parsed.document.undoStack.last!.ops)

        let rect = CGRect(x: -5, y: -5, width: 20, height: 20)
        let result = SelectionEngine.rectSelect(document: rc.document, usePaperSpace: false,
                                                rect: rect, mode: .crossing, visibility: VisibilityState())
        XCTAssertFalse(result.contains(id))
    }

    // MARK: - Empty document / no candidates

    func testEmptyRectOnEmptyDocumentSelectsNothing() throws {
        let rc = try makeCoordinator()
        let rect = CGRect(x: 0, y: 0, width: 1, height: 1)
        let result = SelectionEngine.rectSelect(document: rc.document, usePaperSpace: false,
                                                rect: rect, mode: .crossing, visibility: VisibilityState())
        // basic_entities.dxf has content, so just confirm the API doesn't crash
        // and a genuinely empty area (far from anything) yields nothing.
        let farRect = CGRect(x: 1_000_000, y: 1_000_000, width: 1, height: 1)
        let farResult = SelectionEngine.rectSelect(document: rc.document, usePaperSpace: false,
                                                   rect: farRect, mode: .crossing, visibility: VisibilityState())
        XCTAssertTrue(farResult.isEmpty)
        _ = result
    }
}
