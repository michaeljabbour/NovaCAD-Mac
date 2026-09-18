import XCTest
import CoreGraphics
@testable import DWGViewer

final class SelectionPromptTests: XCTestCase {

    private func id(_ raw: Int32) -> EntityID { EntityID(raw: raw) }

    private func makePrompt(preselected: Set<EntityID> = [],
                            pickAddIsZero: Bool = false,
                            allSelectable: Set<EntityID> = [],
                            previous: Set<EntityID> = [],
                            lastCreated: Set<EntityID> = [],
                            rectResult: Set<EntityID> = [],
                            lassoResult: Set<EntityID> = [],
                            fenceResult: Set<EntityID> = []) -> SelectionPrompt {
        SelectionPrompt(preselected: preselected, pickAddIsZero: pickAddIsZero,
                        allSelectable: { allSelectable },
                        previousSelection: { previous },
                        lastCreated: { lastCreated },
                        rectSelect: { _, _ in rectResult },
                        lassoSelect: { _, _ in lassoResult },
                        fenceSelect: { _ in fenceResult })
    }

    // MARK: - PICKFIRST noun-verb

    func testNonEmptyPreselectionIsImmediatelyDone() {
        let prompt = makePrompt(preselected: [id(1), id(2)])
        XCTAssertEqual(prompt.result, .done([id(1), id(2)]))
        XCTAssertEqual(prompt.promptText, "", "a done prompt has no prompt text to show")
    }

    func testEmptyPreselectionStartsPending() {
        let prompt = makePrompt(preselected: [])
        XCTAssertEqual(prompt.result, .pending)
        XCTAssertEqual(prompt.promptText, "Select objects:")
    }

    // MARK: - Click accumulation

    func testSinglePickAccumulates() {
        var prompt = makePrompt()
        let result = prompt.handle(.pick(id(5), worldPoint: .zero, shiftHeld: false))
        XCTAssertEqual(result, .pending)
        XCTAssertEqual(prompt.accumulated, [id(5)])
        XCTAssertEqual(prompt.promptText, "Select objects: (1 found)")
    }

    func testMultiplePicksAccumulate() {
        var prompt = makePrompt()
        _ = prompt.handle(.pick(id(1), worldPoint: .zero, shiftHeld: false))
        _ = prompt.handle(.pick(id(2), worldPoint: .zero, shiftHeld: false))
        XCTAssertEqual(prompt.accumulated, [id(1), id(2)])
    }

    func testPickingEmptySpaceIsNoOp() {
        var prompt = makePrompt()
        _ = prompt.handle(.pick(id(1), worldPoint: .zero, shiftHeld: false))
        _ = prompt.handle(.pick(nil, worldPoint: .zero, shiftHeld: false))
        XCTAssertEqual(prompt.accumulated, [id(1)], "clicking empty space must not clear progress")
    }

    func testShiftClickRemovesFromAccumulated() {
        var prompt = makePrompt()
        _ = prompt.handle(.pick(id(1), worldPoint: .zero, shiftHeld: false))
        _ = prompt.handle(.pick(id(2), worldPoint: .zero, shiftHeld: false))
        _ = prompt.handle(.pick(id(1), worldPoint: .zero, shiftHeld: true))
        XCTAssertEqual(prompt.accumulated, [id(2)])
    }

    func testPickAddZeroReplacesRatherThanAccumulates() {
        var prompt = makePrompt(pickAddIsZero: true)
        _ = prompt.handle(.pick(id(1), worldPoint: .zero, shiftHeld: false))
        _ = prompt.handle(.pick(id(2), worldPoint: .zero, shiftHeld: false))
        XCTAssertEqual(prompt.accumulated, [id(2)], "PICKADD=0: each new pick REPLACES, not adds")
    }

    func testPickAddZeroWithShiftStillAccumulates() {
        var prompt = makePrompt(pickAddIsZero: true)
        _ = prompt.handle(.pick(id(1), worldPoint: .zero, shiftHeld: false))
        _ = prompt.handle(.pick(id(2), worldPoint: .zero, shiftHeld: true))
        XCTAssertEqual(prompt.accumulated, [id(1), id(2)], "Shift overrides PICKADD=0's replace behavior")
    }

    // MARK: - finish / cancel

    func testFinishTransitionsToDoneWithAccumulated() {
        var prompt = makePrompt()
        _ = prompt.handle(.pick(id(1), worldPoint: .zero, shiftHeld: false))
        let result = prompt.handle(.finish)
        XCTAssertEqual(result, .done([id(1)]))
    }

    func testFinishWithNothingAccumulatedIsDoneWithEmptySet() {
        var prompt = makePrompt()
        let result = prompt.handle(.finish)
        XCTAssertEqual(result, .done([]))
    }

    func testCancelDiscardsAccumulated() {
        var prompt = makePrompt()
        _ = prompt.handle(.pick(id(1), worldPoint: .zero, shiftHeld: false))
        let result = prompt.handle(.cancel)
        XCTAssertEqual(result, .cancelled)
    }

    func testEventsAfterDoneAreNoOps() {
        var prompt = makePrompt()
        _ = prompt.handle(.finish)
        let before = prompt.accumulated
        _ = prompt.handle(.pick(id(99), worldPoint: .zero, shiftHeld: false))
        XCTAssertEqual(prompt.accumulated, before, "handle(_:) after .done must be a no-op")
    }

    func testEventsAfterCancelledAreNoOps() {
        var prompt = makePrompt()
        _ = prompt.handle(.cancel)
        let result = prompt.handle(.pick(id(1), worldPoint: .zero, shiftHeld: false))
        XCTAssertEqual(result, .cancelled)
    }

    // MARK: - Box select (Window/Crossing) via commandToken-free drag

    func testBoxCompleteAddsHitsToAccumulated() {
        var prompt = makePrompt(rectResult: [id(1), id(2), id(3)])
        let result = prompt.handle(.boxComplete(CGRect(x: 0, y: 0, width: 10, height: 10), mode: .crossing, shiftHeld: false))
        XCTAssertEqual(result, .pending)
        XCTAssertEqual(prompt.accumulated, [id(1), id(2), id(3)])
    }

    /// Shift on a BATCH acquisition (box/lasso/fence) means "add to the
    /// existing set," matching `ContentView.handleBoxSelect`'s existing
    /// `shiftDown ? selection.union(hits) : hits` — NOT a per-item toggle
    /// (that would be ambiguous/surprising for a multi-hundred-entity
    /// crossing-select), and not an unconditional remove either.
    func testBoxCompleteWithShiftUnionsWithExisting() {
        var prompt = makePrompt(rectResult: [id(2), id(3)])
        _ = prompt.handle(.pick(id(1), worldPoint: .zero, shiftHeld: false))
        _ = prompt.handle(.boxComplete(CGRect(x: 0, y: 0, width: 10, height: 10), mode: .window, shiftHeld: true))
        XCTAssertEqual(prompt.accumulated, [id(1), id(2), id(3)])
    }

    /// R (Remove mode) DOES cause a batch acquisition to subtract, unlike
    /// Shift — the two are independent knobs (Shift = "add regardless of
    /// PICKADD," R/A = ambient ADD-vs-REMOVE mode for un-shifted picks).
    func testBoxCompleteInRemoveModeSubtracts() {
        var prompt = makePrompt(rectResult: [id(1), id(2)])
        _ = prompt.handle(.pick(id(1), worldPoint: .zero, shiftHeld: false))
        _ = prompt.handle(.pick(id(2), worldPoint: .zero, shiftHeld: false))
        _ = prompt.handle(.commandToken("R"))
        _ = prompt.handle(.boxComplete(CGRect(x: 0, y: 0, width: 10, height: 10), mode: .window, shiftHeld: false))
        XCTAssertTrue(prompt.accumulated.isEmpty)
    }

    // MARK: - Lasso / fence

    func testLassoCompleteAddsHits() {
        var prompt = makePrompt(lassoResult: [id(7)])
        _ = prompt.handle(.lassoComplete([CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1)],
                                         mode: .crossing, shiftHeld: false))
        XCTAssertEqual(prompt.accumulated, [id(7)])
    }

    func testFenceCompleteAddsHits() {
        var prompt = makePrompt(fenceResult: [id(8), id(9)])
        _ = prompt.handle(.fenceComplete([CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0)]))
        XCTAssertEqual(prompt.accumulated, [id(8), id(9)])
    }

    // MARK: - Command-bar tokens: ALL / P / L

    func testAllTokenSelectsAllSelectable() {
        var prompt = makePrompt(allSelectable: [id(1), id(2), id(3)])
        _ = prompt.handle(.commandToken("ALL"))
        XCTAssertEqual(prompt.accumulated, [id(1), id(2), id(3)])
    }

    func testPreviousTokenSelectsPreviousSelection() {
        var prompt = makePrompt(previous: [id(4), id(5)])
        _ = prompt.handle(.commandToken("P"))
        XCTAssertEqual(prompt.accumulated, [id(4), id(5)])
    }

    func testLastTokenSelectsLastCreated() {
        var prompt = makePrompt(lastCreated: [id(6)])
        _ = prompt.handle(.commandToken("L"))
        XCTAssertEqual(prompt.accumulated, [id(6)])
    }

    func testTokensAreCaseInsensitiveAtCallSiteConvention() {
        // The type itself uppercases in handleCommandToken; verify lowercase
        // input still resolves (ContentView is documented to uppercase
        // before calling, but the type should be defensive too).
        var prompt = makePrompt(allSelectable: [id(1)])
        _ = prompt.handle(.commandToken("all"))
        XCTAssertEqual(prompt.accumulated, [id(1)])
    }

    func testUnrecognizedTokenIsIgnored() {
        var prompt = makePrompt()
        _ = prompt.handle(.pick(id(1), worldPoint: .zero, shiftHeld: false))
        _ = prompt.handle(.commandToken("ZZZ"))
        XCTAssertEqual(prompt.accumulated, [id(1)])
    }

    // MARK: - Remove/Add mode (R/A tokens)

    func testRTokenSwitchesToRemoveMode() {
        var prompt = makePrompt()
        _ = prompt.handle(.pick(id(1), worldPoint: .zero, shiftHeld: false))
        _ = prompt.handle(.pick(id(2), worldPoint: .zero, shiftHeld: false))
        _ = prompt.handle(.commandToken("R"))
        _ = prompt.handle(.pick(id(1), worldPoint: .zero, shiftHeld: false))
        XCTAssertEqual(prompt.accumulated, [id(2)], "in Remove mode, a plain pick REMOVES")
    }

    func testATokenSwitchesBackToAddMode() {
        var prompt = makePrompt()
        _ = prompt.handle(.commandToken("R"))
        _ = prompt.handle(.commandToken("A"))
        _ = prompt.handle(.pick(id(1), worldPoint: .zero, shiftHeld: false))
        XCTAssertEqual(prompt.accumulated, [id(1)], "back in Add mode, a plain pick ADDS")
    }

    func testRemoveModeReflectedInPromptText() {
        var prompt = makePrompt()
        _ = prompt.handle(.commandToken("R"))
        XCTAssertTrue(prompt.promptText.contains("Remove mode"))
    }

    // MARK: - U (undo last acquisition step)

    func testUndoLastAcquisitionStepReversesOnePick() {
        var prompt = makePrompt()
        _ = prompt.handle(.pick(id(1), worldPoint: .zero, shiftHeld: false))
        _ = prompt.handle(.pick(id(2), worldPoint: .zero, shiftHeld: false))
        _ = prompt.handle(.commandToken("U"))
        XCTAssertEqual(prompt.accumulated, [id(1)], "U undoes only the MOST RECENT acquisition step")
    }

    func testUndoLastAcquisitionStepReversesAWholeBoxSelect() {
        var prompt = makePrompt(rectResult: [id(1), id(2), id(3)])
        _ = prompt.handle(.pick(id(9), worldPoint: .zero, shiftHeld: false))
        _ = prompt.handle(.boxComplete(CGRect(x: 0, y: 0, width: 10, height: 10), mode: .crossing, shiftHeld: false))
        XCTAssertEqual(prompt.accumulated, [id(1), id(2), id(3), id(9)])
        _ = prompt.handle(.commandToken("U"))
        XCTAssertEqual(prompt.accumulated, [id(9)], "U undoes the WHOLE box-select as one step, not one id at a time")
    }

    func testUndoWithNoHistoryIsNoOp() {
        var prompt = makePrompt()
        _ = prompt.handle(.commandToken("U"))
        XCTAssertTrue(prompt.accumulated.isEmpty)
    }

    func testMultipleUndosWalkBackThroughHistory() {
        var prompt = makePrompt()
        _ = prompt.handle(.pick(id(1), worldPoint: .zero, shiftHeld: false))
        _ = prompt.handle(.pick(id(2), worldPoint: .zero, shiftHeld: false))
        _ = prompt.handle(.pick(id(3), worldPoint: .zero, shiftHeld: false))
        _ = prompt.handle(.commandToken("U"))
        XCTAssertEqual(prompt.accumulated, [id(1), id(2)])
        _ = prompt.handle(.commandToken("U"))
        XCTAssertEqual(prompt.accumulated, [id(1)])
        _ = prompt.handle(.commandToken("U"))
        XCTAssertTrue(prompt.accumulated.isEmpty)
    }

    // MARK: - Explicit W/C two-point rect

    func testExplicitWindowTokenThenTwoPicksProducesWindowRect() {
        var capturedMode: SelectionMode?
        var prompt = SelectionPrompt(preselected: [], allSelectable: { [] },
                                     rectSelect: { _, mode in capturedMode = mode; return [self.id(1)] })
        _ = prompt.handle(.commandToken("W"))
        XCTAssertEqual(prompt.promptText, "Select objects: specify first corner")
        _ = prompt.handle(.pick(nil, worldPoint: CGPoint(x: 0, y: 0), shiftHeld: false))
        XCTAssertEqual(prompt.promptText, "Select objects: specify opposite corner")
        _ = prompt.handle(.pick(nil, worldPoint: CGPoint(x: 10, y: 10), shiftHeld: false))
        XCTAssertEqual(capturedMode, .window)
        XCTAssertEqual(prompt.accumulated, [id(1)])
    }

    func testExplicitCrossingTokenForcesCrossingRegardlessOfDragDirection() {
        var capturedMode: SelectionMode?
        var prompt = SelectionPrompt(preselected: [], allSelectable: { [] },
                                     rectSelect: { _, mode in capturedMode = mode; return [] })
        _ = prompt.handle(.commandToken("C"))
        // Second corner is to the LEFT of the first (would normally be a
        // "Window" drag direction by the L->R/R->L convention) — but an
        // explicit C token always forces Crossing regardless.
        _ = prompt.handle(.pick(nil, worldPoint: CGPoint(x: 10, y: 10), shiftHeld: false))
        _ = prompt.handle(.pick(nil, worldPoint: CGPoint(x: 0, y: 0), shiftHeld: false))
        XCTAssertEqual(capturedMode, .crossing)
    }

    func testExplicitWindowRectRespectsCornerOrder() {
        var capturedRect: CGRect?
        var prompt = SelectionPrompt(preselected: [], allSelectable: { [] },
                                     rectSelect: { rect, _ in capturedRect = rect; return [] })
        _ = prompt.handle(.commandToken("W"))
        _ = prompt.handle(.pick(nil, worldPoint: CGPoint(x: 10, y: 10), shiftHeld: false))
        _ = prompt.handle(.pick(nil, worldPoint: CGPoint(x: 0, y: 0), shiftHeld: false))
        XCTAssertEqual(capturedRect, CGRect(x: 0, y: 0, width: 10, height: 10))
    }

    // MARK: - promptText

    func testPromptTextShowsFoundCount() {
        var prompt = makePrompt()
        _ = prompt.handle(.pick(id(1), worldPoint: .zero, shiftHeld: false))
        _ = prompt.handle(.pick(id(2), worldPoint: .zero, shiftHeld: false))
        XCTAssertEqual(prompt.promptText, "Select objects: (2 found)")
    }

    func testFenceAwaitingPromptText() {
        var prompt = makePrompt()
        _ = prompt.handle(.commandToken("F"))
        XCTAssertTrue(prompt.promptText.contains("FENCE"))
    }
}
