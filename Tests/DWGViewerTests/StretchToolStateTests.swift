import XCTest
@testable import DWGViewer
import CADCore

/// Tests for `StretchToolState`'s pure state-machine logic (acquisition
/// de-duplication, prompt text) — the UI wiring (crossing-window drag
/// hit-testing, ghost preview) lives in ContentView/DXFCanvasView and is
/// exercised manually; this covers the underlying data structure, which is
/// where correctness actually matters (double-counting a re-crossed grip
/// would silently double-apply the stretch delta to it).
final class StretchToolStateTests: XCTestCase {

    func testAddCaughtDeduplicatesTheSameEntityAndGripIndex() {
        var state = StretchToolState()
        let id = EntityID(raw: 1)
        state.addCaught([GripEditing.CaughtGrip(entityId: id, gripIndex: 0, position: CGPoint(x: 0, y: 0))])
        // Re-crossing the SAME vertex in a second drag must not duplicate it.
        state.addCaught([GripEditing.CaughtGrip(entityId: id, gripIndex: 0, position: CGPoint(x: 0, y: 0))])
        XCTAssertEqual(state.caught.count, 1)
    }

    func testAddCaughtKeepsDistinctGripIndicesOnTheSameEntity() {
        var state = StretchToolState()
        let id = EntityID(raw: 1)
        state.addCaught([GripEditing.CaughtGrip(entityId: id, gripIndex: 0, position: CGPoint(x: 0, y: 0)),
                         GripEditing.CaughtGrip(entityId: id, gripIndex: 1, position: CGPoint(x: 10, y: 0))])
        XCTAssertEqual(state.caught.count, 2)
    }

    func testAddCaughtAcrossMultipleEntitiesAccumulates() {
        var state = StretchToolState()
        let id1 = EntityID(raw: 1), id2 = EntityID(raw: 2)
        state.addCaught([GripEditing.CaughtGrip(entityId: id1, gripIndex: 0, position: .zero)])
        state.addCaught([GripEditing.CaughtGrip(entityId: id2, gripIndex: 0, position: .zero)])
        XCTAssertEqual(state.caught.count, 2)
    }

    func testIsActiveTrueForEveryNonIdlePhase() {
        var state = StretchToolState()
        XCTAssertFalse(state.isActive)
        state.phase = .selecting
        XCTAssertTrue(state.isActive)
        state.phase = .pickingBase
        XCTAssertTrue(state.isActive)
        state.phase = .pickingDestination
        XCTAssertTrue(state.isActive)
    }

    func testPromptTextReflectsCaughtCountWhileSelecting() {
        var state = StretchToolState()
        state.phase = .selecting
        XCTAssertTrue(state.prompt.contains("select objects"))
        state.addCaught([GripEditing.CaughtGrip(entityId: EntityID(raw: 1), gripIndex: 0, position: .zero)])
        XCTAssertTrue(state.prompt.contains("1 point"))
    }
}
