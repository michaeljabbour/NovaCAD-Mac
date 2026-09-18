import XCTest
@testable import DWGViewer

/// Regression tests for the opencode-server startup/validation hardening:
///
/// 1. `ProcessOutputTail` keeps the tail of `opencode serve` stderr, so a
///    crash-on-boot can be reported with the server's own last output
///    instead of the generic "took too long to start" message.
/// 2. A non-empty model WITHOUT a `provider/model` prefix must fail fast
///    with an actionable error instead of being silently dropped from the
///    request — dropping it made the turn run against the server's DEFAULT
///    model while "Test Connection" still reported success.
/// 3. The chat turn's server-acquisition timeout must exceed the server's
///    own startup timeout. The old 20s value was below the documented 45s
///    startup budget, so a legitimately cold server start was always aborted
///    with the misleading "assistant went quiet" message.
final class OpenCodeServerStartupTests: XCTestCase {

    // MARK: - ProcessOutputTail

    func testOutputTailKeepsOnlyTheMostRecentBytes() {
        let tail = OpenCodeServerClient.ProcessOutputTail(limit: 16)
        tail.append(Data("0123456789".utf8))
        tail.append(Data("abcdefghij".utf8))
        XCTAssertEqual(tail.tailString(), "456789abcdefghij")
    }

    func testOutputTailDecodesUTF8AndHandlesEmpty() {
        let tail = OpenCodeServerClient.ProcessOutputTail(limit: 64)
        XCTAssertEqual(tail.tailString(), "")
        tail.append(Data())
        XCTAssertEqual(tail.tailString(), "")
        tail.append(Data("boom: bad config\n".utf8))
        XCTAssertEqual(tail.tailString(), "boom: bad config\n")
    }

    func testOutputTailIsBoundedUnderConcurrentAppends() {
        let tail = OpenCodeServerClient.ProcessOutputTail(limit: 256)
        DispatchQueue.concurrentPerform(iterations: 64) { i in
            tail.append(Data(String(repeating: "\(i % 10)", count: 64).utf8))
        }
        XCTAssertFalse(tail.tailString().isEmpty)
        XCTAssertLessThanOrEqual(tail.tailString().utf8.count, 256)
    }

    func testOutputTailSurvivesTruncationSplittingAMultibyteCharacter() {
        // "é" is 0xC3 0xA9. Limit 2, appended as [C3] then [A9, 63]: the
        // buffer trims to the last two bytes, [A9, 63], which tears the
        // sequence. The tail must still decode (U+FFFD replaces the torn
        // byte) instead of blanking out via a nil `String(data:encoding:)`.
        let tail = OpenCodeServerClient.ProcessOutputTail(limit: 2)
        tail.append(Data([0xC3]))
        tail.append(Data([0xA9, 0x63]))
        XCTAssertEqual(tail.tailString(), "\u{FFFD}c")
    }

    // MARK: - Dead-child fast-fail (end-to-end through waitForHealth)

    func testServerThatExitsDuringStartupFailsFastWithDiagnostic() async {
        // /usr/bin/false ignores its arguments and exits 1 immediately, so
        // this drives the REAL startServer + waitForHealth path exactly like
        // a fork/plugin/config crash would. Before the liveness check, this
        // burned the whole 45s startup budget and reported "took too long".
        let client = OpenCodeServerClient()
        let config = AIConfig.opencodeServerDefaults(model: "", binaryPath: "/usr/bin/false")
        let started = Date()
        do {
            _ = try await client.testConnection(config: config)
            XCTFail("expected the dead server to fail the connection probe")
        } catch {
            let elapsed = Date().timeIntervalSince(started)
            XCTAssertLessThan(elapsed, 10,
                              "waitForHealth must fail as soon as the child dies, not poll the full startup budget")
            let description = error.localizedDescription
            XCTAssertTrue(description.contains("exited during startup")
                          || description.contains("Failed to launch"),
                          "expected a startup-exit diagnostic, got: \(description)")
        }
    }

    // MARK: - Startup-exit diagnostics

    func testStartupExitMessageIncludesStatusAndTail() {
        let message = OpenCodeServerClient.startupExitMessage(
            status: 1, reason: .exit, stderrTail: "Error: ConfigInvalidError: bad plugin\n")
        XCTAssertTrue(message.contains("status 1"), message)
        XCTAssertTrue(message.contains("ConfigInvalidError"), message)
    }

    func testStartupExitMessageHandlesSignalAndEmptyTail() {
        let message = OpenCodeServerClient.startupExitMessage(
            status: 0, reason: .uncaughtSignal, stderrTail: "   ")
        XCTAssertTrue(message.contains("signal"), message)
        XCTAssertFalse(message.contains("Last output"), message)
    }

    func testStartupExitMessageClipsVeryLongTail() {
        let message = OpenCodeServerClient.startupExitMessage(
            status: 2, reason: .exit, stderrTail: String(repeating: "x", count: 5_000))
        XCTAssertLessThan(message.count, 1_000)
        XCTAssertTrue(message.contains("…"))
    }

    // MARK: - Model validation

    func testModelValidationAllowsEmptyAndWellFormedStrings() {
        XCTAssertNil(OpenCodeServerClient.modelValidationError(for: ""))
        XCTAssertNil(OpenCodeServerClient.modelValidationError(for: "   "))
        XCTAssertNil(OpenCodeServerClient.modelValidationError(for: "example/model-id"))
        XCTAssertNil(OpenCodeServerClient.modelValidationError(for: " openai/gpt-4o "))
    }

    func testModelValidationRejectsMissingProviderPrefix() {
        for malformed in ["claude-sonnet-4-5", "/gpt-4o", "openai/", " / "] {
            let message = OpenCodeServerClient.modelValidationError(for: malformed)
            XCTAssertNotNil(message, "expected rejection for \(malformed)")
            XCTAssertTrue(message?.contains("provider/model") == true, message ?? "")
            XCTAssertTrue(message?.contains(malformed.trimmingCharacters(in: .whitespaces)) == true,
                          "error should quote the offending value: \(message ?? "")")
        }
    }

    // MARK: - Timeout relationship

    func testChatAcquireTimeoutOutlastsServerStartupTimeout() {
        XCTAssertGreaterThan(
            AIAssistantSession.serverAcquireTimeoutForTesting,
            OpenCodeServerClient.startupTimeoutForTesting,
            "A cold server start still within its documented startup budget must not be "
                + "aborted by the chat path's acquire timeout (this produced the misleading "
                + "\"went quiet\" message)")
    }
}
