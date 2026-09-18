import XCTest
@testable import DWGViewer

/// Covers the two AI Assistant reliability complaints:
///
///  1. **Repeated messages / repeated blocks.** `AIAssistantSession.apply`
///     used to reconcile streamed text against `history.last`, which silently
///     failed whenever a tool-call row landed between the prose and the
///     final `.completed` event — the normal OpenCode ordering — and appended
///     the whole reply a second time. It also had no guard against a backend
///     emitting `.completed` more than once per turn, which several
///     `OpenCodeServerClient` code paths genuinely can.
///  2. **Stalls / crashes with no recovery.** There was no way to tell a
///     healthy long turn from a wedged one, and the only reset also wiped the
///     transcript.
@MainActor
final class AIAssistantHealthTests: XCTestCase {

    private func makeSession() -> AIAssistantSession { AIAssistantSession() }

    private func assistantTexts(_ session: AIAssistantSession) -> [String] {
        session.history.filter { $0.role == .assistant }.map(\.text)
    }

    // MARK: - Duplicate suppression

    func testCompletedAfterMatchingStreamDoesNotDuplicate() {
        let session = makeSession()
        session.beginTurnForTesting()
        session.apply(.textDelta("Hello "))
        session.apply(.textDelta("world"))
        session.apply(.completed("Hello world"))
        XCTAssertEqual(assistantTexts(session), ["Hello world"])
    }

    /// The exact regression: text, then a TOOL ROW, then `.completed`. The
    /// old `history.last` check saw `.toolCall` and appended a full copy.
    func testCompletedAfterToolCallDoesNotDuplicateEarlierProse() {
        let session = makeSession()
        session.beginTurnForTesting()
        let reply = "The aisle network has disconnected components and needs repair before routing."
        session.apply(.textDelta(reply))
        session.apply(.toolCall(AIToolCallEvent(id: "t1", name: "analyze_aisle_network",
                                                argumentSummary: "layer=AISLE",
                                                status: .completed, resultSummary: "analysis complete")))
        session.apply(.completed(reply))
        XCTAssertEqual(assistantTexts(session), [reply],
                       "the reply must appear exactly once even with a tool row after it")
    }

    /// A backend that emits `.completed` twice (idle watchdog racing the
    /// completion poller) must still yield one bubble.
    func testRepeatedCompletedEventsAreIgnored() {
        let session = makeSession()
        session.beginTurnForTesting()
        session.apply(.textDelta("Done."))
        session.apply(.completed("Done."))
        session.apply(.completed("Done."))
        session.apply(.completed("Done."))
        XCTAssertEqual(assistantTexts(session), ["Done."])
    }

    func testCompletedExtendsPartialStreamInsteadOfReplacing() {
        let session = makeSession()
        session.beginTurnForTesting()
        session.apply(.textDelta("Partial"))
        session.apply(.completed("Partial answer with more detail."))
        XCTAssertEqual(assistantTexts(session), ["Partial answer with more detail."])
    }

    /// A snapshot arriving after a tool row must REPLACE the turn's bubble,
    /// not start a second one containing the same prose.
    func testSnapshotAfterToolCallReplacesRatherThanDuplicates() {
        let session = makeSession()
        session.beginTurnForTesting()
        session.apply(.textDelta("Checking"))
        session.apply(.toolCall(AIToolCallEvent(id: "t1", name: "read_drawing", argumentSummary: "",
                                                status: .running, resultSummary: nil)))
        session.apply(.textDelta(" the layers"))
        session.apply(.textSnapshot("Checking the layers — found 12."))
        XCTAssertEqual(assistantTexts(session).count, 2,
                       "prose before and after a tool row are separate bubbles")
        XCTAssertEqual(assistantTexts(session).last, "Checking the layers — found 12.")
    }

    /// The model-driven half: an agent that restates a whole earlier block
    /// verbatim after another tool call.
    func testVerbatimRestatementOfRecentBlockIsSuppressed() {
        let session = makeSession()
        session.beginTurnForTesting()
        let block = "Travel from Marketplace MP-3 to Station STN-101 is 312 ft one way and 624 ft round trip."
        session.apply(.textDelta(block))
        session.apply(.toolCall(AIToolCallEvent(id: "t1", name: "export_travel_distances",
                                                argumentSummary: "", status: .completed,
                                                resultSummary: "ok")))
        session.apply(.completed(block))
        XCTAssertEqual(assistantTexts(session), [block])
    }

    /// Short replies must NEVER be suppressed — two legitimate "Done." turns
    /// are not a bug.
    func testShortRepliesAreNotSuppressed() {
        let session = makeSession()
        session.beginTurnForTesting()
        session.apply(.completed("Done."))
        session.beginTurnForTesting()
        session.apply(.completed("Done."))
        XCTAssertEqual(assistantTexts(session), ["Done.", "Done."])
    }

    func testDistinctProseInSameTurnIsKept() {
        let session = makeSession()
        session.beginTurnForTesting()
        session.apply(.textDelta("First, I checked the aisle layer and found it fragmented."))
        session.apply(.toolCall(AIToolCallEvent(id: "t1", name: "repair_aisle_network",
                                                argumentSummary: "", status: .completed, resultSummary: "ok")))
        session.apply(.completed("After repair the network is connected and routing succeeded."))
        XCTAssertEqual(assistantTexts(session).count, 2, "genuinely different prose must both survive")
    }

    // MARK: - Health / stall detection

    func testHealthStartsIdleAndBecomesWorkingOnTurnStart() {
        let session = makeSession()
        XCTAssertEqual(session.health, .idle)
        session.beginTurnForTesting()
        guard case .working = session.health else {
            return XCTFail("expected .working, got \(session.health)")
        }
    }

    func testFailureIsSurfacedInHealth() {
        let session = makeSession()
        session.beginTurnForTesting()
        session.apply(.failed("connection dropped"))
        guard case .failed(let message) = session.health else {
            return XCTFail("expected .failed, got \(session.health)")
        }
        XCTAssertEqual(message, "connection dropped")
    }

    func testStreamActivityClearsAStall() {
        let session = makeSession()
        session.beginTurnForTesting()
        session.forceStallForTesting()
        guard case .stalled = session.health else { return XCTFail("expected .stalled") }
        XCTAssertTrue(session.recoverySuggested)

        session.apply(.textDelta("still alive"))
        guard case .working = session.health else {
            return XCTFail("an event should clear the stall, got \(session.health)")
        }
        XCTAssertFalse(session.recoverySuggested)
    }

    // MARK: - Reset preserves the conversation

    func testResetAssistantKeepsTranscriptAndStagedWork() {
        let session = makeSession()
        session.history.append(AIChatEntry(role: .user, text: "how far is dock 4?", toolCall: nil))
        session.history.append(AIChatEntry(role: .assistant, text: "312 ft one way.", toolCall: nil))
        session.stagedEdits = [AIProposedEdit(insertEntityId: 1, attributeTag: "ROUTE",
                                              oldValue: "A", newValue: "B", willCreate: false)]
        let userTurns = session.history.filter { $0.role == .user }.count

        session.resetAssistant()

        XCTAssertEqual(session.history.filter { $0.role == .user }.count, userTurns,
                       "the user's turns must survive a reset")
        XCTAssertTrue(session.history.contains { $0.text.contains("Assistant reset") },
                      "the reset should be visible in the transcript")
        XCTAssertEqual(session.stagedEdits.count, 1, "staged work must survive a reset")
        XCTAssertFalse(session.isThinking)
        XCTAssertEqual(session.health, .idle)
        XCTAssertNil(session.errorMessage)
    }

    /// The distinction that motivated the feature: Clear wipes, Reset does not.
    func testClearConversationStillWipesWhileResetDoesNot() {
        let session = makeSession()
        session.history.append(AIChatEntry(role: .user, text: "hello", toolCall: nil))
        session.resetAssistant()
        XCTAssertFalse(session.history.isEmpty)

        session.clearConversation()
        XCTAssertTrue(session.history.isEmpty)
        XCTAssertEqual(session.health, .idle)
    }

    /// Regression: `clearConversation` after a FAILED turn must leave
    /// `health == .idle`, not a stale `.failed`.
    ///
    /// `endTurn()` (called by `clearConversation`, mirroring what `send`'s
    /// own `defer` does at the close of every real turn) reads
    /// `errorMessage` — still set from the failed turn at that point — and
    /// sets `health = .failed(error)`. `clearConversation` then clears
    /// `errorMessage`, but that does NOT retroactively fix `health`, which
    /// stays `.failed` until something else (the next `send()`) happens to
    /// overwrite it. The status pill therefore kept showing "failed" on a
    /// conversation the user had just cleared. `resetAssistant` already
    /// gets this right (explicit `health = .idle` after both `endTurn()`
    /// and `errorMessage = nil`); `clearConversation` must match it.
    ///
    /// `testClearConversationStillWipesWhileResetDoesNot` above doesn't
    /// catch this because it never puts the session into a failed state
    /// first — a fresh session is already `.idle`, so a bug that only fails
    /// to CORRECT a stale `.failed` passes that test trivially.
    func testClearConversationResetsHealthAfterAFailedTurn() {
        let session = makeSession()
        session.beginTurnForTesting()
        session.apply(.failed("The AI gateway is currently unavailable."))
        XCTAssertEqual(session.health, .failed("The AI gateway is currently unavailable."),
                       "sanity: the failed turn actually left health/.failed set, matching what a real send() would leave behind for clearConversation to inherit")
        XCTAssertNotNil(session.errorMessage)

        session.clearConversation()

        XCTAssertEqual(session.health, .idle,
                       "clearConversation must correct health to .idle, not leave the stale .failed from the turn it just cleared")
        XCTAssertNil(session.errorMessage)
        XCTAssertTrue(session.history.isEmpty)
    }
}
