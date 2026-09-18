import XCTest
import CoreGraphics
@testable import DWGViewer

final class ModifyToolStateTests: XCTestCase {

    private func id(_ raw: Int32) -> EntityID { EntityID(raw: raw) }

    // MARK: - begin(_:preselection:) — PICKFIRST vs interactive

    func testBeginWithNonEmptyPreselectionSkipsSelectingPhase() {
        let state = ModifyToolState.begin(.rotate, preselection: [id(1), id(2)])
        XCTAssertEqual(state.objectIDs, [id(1), id(2)])
        XCTAssertNotEqual(state.phase, .selecting, "PICKFIRST: non-empty preselection skips the Select objects: prompt")
        XCTAssertEqual(state.phase, .pickBase)
    }

    func testBeginWithEmptyPreselectionStartsSelecting() {
        let state = ModifyToolState.begin(.copy, preselection: [])
        XCTAssertTrue(state.objectIDs.isEmpty)
        XCTAssertEqual(state.phase, .selecting)
    }

    func testBeginSetsCorrectCommand() {
        for cmd: ModifyCommand in [.copy, .rotate, .scale, .mirror] {
            let state = ModifyToolState.begin(cmd, preselection: [id(1)])
            XCTAssertEqual(state.command, cmd)
        }
    }

    // MARK: - withAcquiredObjects

    func testWithAcquiredObjectsTransitionsFromSelectingToPickBase() {
        var state = ModifyToolState.begin(.mirror, preselection: [])
        XCTAssertEqual(state.phase, .selecting)
        state.withAcquiredObjects([id(5), id(6)])
        XCTAssertEqual(state.objectIDs, [id(5), id(6)])
        XCTAssertEqual(state.phase, .pickBase)
    }

    // MARK: - isActive / hasAcquiredObjects

    func testIdleStateIsNotActive() {
        let state = ModifyToolState(command: .rotate)
        XCTAssertFalse(state.isActive)
    }

    func testNonIdleStateIsActive() {
        let state = ModifyToolState.begin(.scale, preselection: [id(1)])
        XCTAssertTrue(state.isActive)
    }

    func testHasAcquiredObjectsReflectsObjectIDs() {
        var state = ModifyToolState(command: .copy)
        XCTAssertFalse(state.hasAcquiredObjects)
        state.objectIDs = [id(1)]
        XCTAssertTrue(state.hasAcquiredObjects)
    }

    // MARK: - prompt text varies by command/phase

    func testIdlePromptIsEmpty() {
        let state = ModifyToolState(command: .rotate)
        XCTAssertEqual(state.prompt, "")
    }

    func testSelectingPromptMentionsSelectObjects() {
        let state = ModifyToolState.begin(.copy, preselection: [])
        XCTAssertTrue(state.prompt.contains("Select objects"))
    }

    func testMirrorPickBasePromptMentionsMirrorLine() {
        let state = ModifyToolState.begin(.mirror, preselection: [id(1)])
        XCTAssertTrue(state.prompt.lowercased().contains("mirror line"))
    }

    func testRotatePickBasePromptMentionsBasePoint() {
        let state = ModifyToolState.begin(.rotate, preselection: [id(1)])
        XCTAssertTrue(state.prompt.lowercased().contains("base point"))
    }

    func testDistinctCommandsProduceDistinctPromptText() {
        let rotate = ModifyToolState.begin(.rotate, preselection: [id(1)])
        let scale = ModifyToolState.begin(.scale, preselection: [id(1)])
        let mirror = ModifyToolState.begin(.mirror, preselection: [id(1)])
        let copy = ModifyToolState.begin(.copy, preselection: [id(1)])
        // All 4 are in .pickBase but must read differently (command name at least).
        XCTAssertTrue(rotate.prompt.hasPrefix("Rotate"))
        XCTAssertTrue(scale.prompt.hasPrefix("Scale"))
        XCTAssertTrue(mirror.prompt.hasPrefix("Mirror"))
        XCTAssertTrue(copy.prompt.hasPrefix("Copy"))
    }

    func testPickDestinationPromptMentionsEnterEscToFinish() {
        var state = ModifyToolState.begin(.copy, preselection: [id(1)])
        state.phase = .pickDestination
        XCTAssertTrue(state.prompt.contains("Enter") || state.prompt.contains("Esc"))
    }

    // MARK: - Command.displayName

    func testDisplayNamesAreHumanReadable() {
        XCTAssertEqual(ModifyCommand.copy.displayName, "Copy")
        XCTAssertEqual(ModifyCommand.rotate.displayName, "Rotate")
        XCTAssertEqual(ModifyCommand.scale.displayName, "Scale")
        XCTAssertEqual(ModifyCommand.mirror.displayName, "Mirror")
        XCTAssertEqual(ModifyCommand.move.displayName, "Move")
    }

    // MARK: - Equatable

    func testEquatableComparesAllFields() {
        var a = ModifyToolState.begin(.rotate, preselection: [id(1)])
        var b = ModifyToolState.begin(.rotate, preselection: [id(1)])
        XCTAssertEqual(a, b)
        a.hover = CGPoint(x: 1, y: 1)
        XCTAssertNotEqual(a, b)
        b.hover = CGPoint(x: 1, y: 1)
        XCTAssertEqual(a, b)
    }
}
