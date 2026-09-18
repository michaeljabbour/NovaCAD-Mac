import XCTest
@testable import DWGViewer

@MainActor
final class CommandLineStateTests: XCTestCase {

    func testOnTextChangedPopulatesSuggestions() {
        let s = CommandLineState()
        s.text = "L"
        s.onTextChanged()
        XCTAssertTrue(s.suggestions.contains { $0.name == "LINE" })
    }

    func testGhostCompletesCanonicalNamePrefix() {
        let s = CommandLineState()
        s.text = "LIN"
        s.onTextChanged()
        XCTAssertEqual(s.ghost, "E", "LIN + ghost should complete to LINE")
    }

    func testGhostOffersFullNameEvenWhenQueryIsAlreadyAValidAlias() {
        // "L" is itself a complete, valid alias for LINE (typing it and
        // pressing Enter already runs Draw Line) — but the ghost still
        // completes toward the full canonical name as a helpful hint, since
        // "LINE".hasPrefix("L") holds. Accepting the ghost or not both still
        // resolve to the same command either way.
        let s = CommandLineState()
        s.text = "L"
        s.onTextChanged()
        XCTAssertEqual(s.ghost, "INE")
    }

    func testGhostEmptyWhenQueryEqualsCanonicalNameExactly() {
        let s = CommandLineState()
        s.text = "LINE"
        s.onTextChanged()
        XCTAssertEqual(s.ghost, "")
    }

    func testGhostEmptyWhenNoMatches() {
        let s = CommandLineState()
        s.text = "ZZZZ"
        s.onTextChanged()
        XCTAssertEqual(s.ghost, "")
        XCTAssertTrue(s.suggestions.isEmpty)
    }

    func testAcceptGhostAppendsAndClears() {
        let s = CommandLineState()
        s.text = "LIN"
        s.onTextChanged()
        XCTAssertEqual(s.ghost, "E")
        s.acceptGhost()
        XCTAssertEqual(s.text, "LINE")
        XCTAssertEqual(s.ghost, "")
    }

    func testAcceptGhostNoOpWhenEmpty() {
        let s = CommandLineState()
        s.text = "LINE"
        s.onTextChanged()
        s.acceptGhost()
        XCTAssertEqual(s.text, "LINE")
    }

    func testRecordSubmittedPushesHistoryAndSetsLastCommand() {
        let s = CommandLineState()
        s.recordSubmitted("LINE")
        s.recordSubmitted("CIRCLE")
        XCTAssertEqual(s.history, ["LINE", "CIRCLE"])
        XCTAssertEqual(s.lastCommand, "CIRCLE")
    }

    func testRecordSubmittedIgnoresBlank() {
        let s = CommandLineState()
        s.recordSubmitted("   ")
        XCTAssertTrue(s.history.isEmpty)
        XCTAssertNil(s.lastCommand)
    }

    func testHistoryCapsAt100DroppingOldest() {
        let s = CommandLineState()
        for i in 0..<105 { s.recordSubmitted("CMD\(i)") }
        XCTAssertEqual(s.history.count, 100)
        XCTAssertEqual(s.history.first, "CMD5")
        XCTAssertEqual(s.history.last, "CMD104")
    }

    func testRecallHistoryOlderThenNewer() {
        let s = CommandLineState()
        s.recordSubmitted("LINE")
        s.recordSubmitted("CIRCLE")
        s.recordSubmitted("ARC")

        s.recallHistory(direction: -1)   // older -> ARC (most recent)
        XCTAssertEqual(s.text, "ARC")
        s.recallHistory(direction: -1)   // older -> CIRCLE
        XCTAssertEqual(s.text, "CIRCLE")
        s.recallHistory(direction: -1)   // older -> LINE
        XCTAssertEqual(s.text, "LINE")
        s.recallHistory(direction: -1)   // clamp at oldest, stays LINE
        XCTAssertEqual(s.text, "LINE")

        s.recallHistory(direction: 1)    // newer -> CIRCLE
        XCTAssertEqual(s.text, "CIRCLE")
        s.recallHistory(direction: 1)    // newer -> ARC
        XCTAssertEqual(s.text, "ARC")
        s.recallHistory(direction: 1)    // clamp at newest, stays ARC
        XCTAssertEqual(s.text, "ARC")
    }

    func testRecallHistoryNoOpWhenEmpty() {
        let s = CommandLineState()
        s.recallHistory(direction: -1)
        XCTAssertEqual(s.text, "")
    }

    func testRecordSubmittedResetsHistoryCursor() {
        let s = CommandLineState()
        s.recordSubmitted("LINE")
        s.recordSubmitted("CIRCLE")
        s.recallHistory(direction: -1)
        XCTAssertEqual(s.text, "CIRCLE")
        s.recordSubmitted("ARC")
        // Cursor reset: recalling "older" again should start from the most
        // recent entry (ARC), not continue from wherever the old cursor was.
        s.recallHistory(direction: -1)
        XCTAssertEqual(s.text, "ARC")
    }
}
