import XCTest
@testable import DWGViewer
import CADCore

/// Tests for the OpenCode (agentic) server backend port — capability config,
/// the server client's pure translation helpers, the tool installer, and the
/// SSE `BusEvent` decoding. Ported from an earlier project's OpenCode
/// server tests per `Resources/Specs/
/// AI_ASSISTANT_PORTING_GUIDE.md`, adapted to NovaCAD's own `AIConfig`/
/// `AIMessage`/`AIToolCallEvent` types. Exercises the logic layer only — no
/// live `opencode serve` process is spawned.
final class OpenCodeServerTests: XCTestCase {

    // MARK: - AIConfig

    func testOpencodeServerSupportsTools() {
        XCTAssertTrue(AIConfig.Provider.opencodeServer.supportsTools)
    }

    func testOpencodeServerProviderRawValueIsStable() {
        // The persisted raw value must not change or saved configs break.
        XCTAssertEqual(AIConfig.Provider.opencodeServer.rawValue, "opencode_server")
    }

    func testOpencodeServerDefaultsRoundTripsThroughSaveAndLoad() throws {
        AIConfig.clear()
        defer { AIConfig.clear() }
        let config = AIConfig.opencodeServerDefaults(model: "anthropic/claude-sonnet-4-5",
                                                      binaryPath: "/usr/local/bin/opencode",
                                                      agent: "build", port: 5599)
        config.save()
        let loaded = try XCTUnwrap(AIConfig.load())
        XCTAssertEqual(loaded.provider, .opencodeServer)
        XCTAssertEqual(loaded.model, "anthropic/claude-sonnet-4-5")
        XCTAssertEqual(loaded.opencodeBinaryPath, "/usr/local/bin/opencode")
        XCTAssertEqual(loaded.opencodeAgent, "build")
        XCTAssertEqual(loaded.opencodeServerPort, 5599)
        XCTAssertTrue(loaded.opencodeToolsEnabled)
    }

    /// Regression coverage: a config persisted by a PRE-OpenCode-Server
    /// NovaCAD build has no `opencodeAgent`/`opencodeServerPort`/
    /// `opencodeToolsEnabled` keys at all. A naive synthesized `Decodable`
    /// would fail to decode that blob entirely, silently reverting the user
    /// to "not configured" after an update — `AIConfig`'s custom
    /// `init(from:)` must tolerate the missing keys.
    func testDecodingAPreExistingConfigWithoutNewerFieldsStillSucceeds() throws {
        let legacyJSON = """
        {"baseURL":"https://api.anthropic.com/v1","apiKey":"sk-test","model":"claude-sonnet-4-5","provider":"anthropic","opencodeBinaryPath":null}
        """
        let decoded = try JSONDecoder().decode(AIConfig.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(decoded.provider, .anthropic)
        XCTAssertEqual(decoded.model, "claude-sonnet-4-5")
        XCTAssertNil(decoded.opencodeAgent)
        XCTAssertNil(decoded.opencodeServerPort)
        XCTAssertTrue(decoded.opencodeToolsEnabled, "missing key must default to true, not fail to decode")
    }

    // MARK: - splitSystemAndPrompt

    func testSplitSystemAndPromptSeparatesSystemChannel() {
        let messages = [
            AIMessage(role: .system, content: "You are NovaCAD's assistant."),
            AIMessage(role: .user, content: "What layers are on this drawing?"),
            AIMessage(role: .assistant, content: "Sure."),
            AIMessage(role: .user, content: "Thanks")
        ]
        let (system, prompt) = OpenCodeServerClient.splitSystemAndPrompt(messages)
        XCTAssertEqual(system, "You are NovaCAD's assistant.")
        XCTAssertTrue(prompt.contains("[User]\nWhat layers are on this drawing?"))
        XCTAssertTrue(prompt.contains("[Assistant]\nSure."))
        XCTAssertFalse(prompt.contains("You are NovaCAD's assistant."), "System text should not leak into the prompt body")
    }

    func testSplitSystemAndPromptNilSystemWhenNoneProvided() {
        let (system, prompt) = OpenCodeServerClient.splitSystemAndPrompt([
            AIMessage(role: .user, content: "hi")
        ])
        XCTAssertNil(system)
        XCTAssertTrue(prompt.contains("hi"))
    }

    // MARK: - newestUserTurn (the "assistant repeats itself" fix)
    //
    // This server reuses ONE session across turns so it keeps its own memory
    // (including tool results). Because `splitSystemAndPrompt` flattens the
    // caller's whole transcript into a single `[User]`/`[Assistant]`-headed
    // prompt string, replaying it on a reused session fed the model its own
    // previous answers back as fresh prompt text every turn — which reliably
    // made it restate/re-summarize what it had already said and re-run tools
    // it had already run (reported as "the ai assistant is also repeating
    // itself"). On a REUSED session only the newest user turn is sent; on a
    // genuinely fresh one the full transcript still goes, so nothing is lost.

    func testNewestUserTurnReturnsOnlyTheLatestUserMessageUnwrapped() {
        let messages = [
            AIMessage(role: .system, content: "You are NovaCAD's assistant."),
            AIMessage(role: .user, content: "Shade the aisles"),
            AIMessage(role: .assistant, content: "Staged 42 ribbons on AISLE-SHADED."),
            AIMessage(role: .user, content: "Now extend the west aisle")
        ]
        let newest = OpenCodeServerClient.newestUserTurn(messages)
        XCTAssertEqual(newest, "Now extend the west aisle")
        XCTAssertFalse(newest?.contains("[User]") ?? true, "no transcript header on a single-turn prompt")
        XCTAssertFalse(newest?.contains("Staged 42 ribbons") ?? true,
                       "the assistant's OWN prior reply must never be echoed back as new prompt text")
        XCTAssertFalse(newest?.contains("Shade the aisles") ?? true,
                       "earlier user turns live in the server's session memory, not the prompt")
    }

    func testNewestUserTurnPrefersTheLastUserMessageNotTheLastMessage() {
        // Defensive: if a trailing assistant message is present, the prompt
        // must still be the user's words, never the assistant's.
        let newest = OpenCodeServerClient.newestUserTurn([
            AIMessage(role: .user, content: "real question"),
            AIMessage(role: .assistant, content: "assistant chatter")
        ])
        XCTAssertEqual(newest, "real question")
    }

    func testNewestUserTurnIsNilWithNoUsableUserMessage() {
        // Nil signals the caller to fall back to the full flattened
        // transcript rather than posting an empty prompt.
        XCTAssertNil(OpenCodeServerClient.newestUserTurn([
            AIMessage(role: .system, content: "system only")
        ]))
        XCTAssertNil(OpenCodeServerClient.newestUserTurn([
            AIMessage(role: .user, content: "   \n  ")
        ]), "whitespace-only input must not become the prompt")
    }

    func testNewestUserTurnTrimsSurroundingWhitespace() {
        XCTAssertEqual(OpenCodeServerClient.newestUserTurn([
            AIMessage(role: .user, content: "  extend the aisle\n")
        ]), "extend the aisle")
    }

    // MARK: - providerModel(from:)
    //
    // Regression coverage for a real bug (confirmed against a live
    // `opencode serve` instance's OpenAPI /doc): the server's schema requires
    // `model` as a {providerID, modelID} object. Sending a flat
    // "provider/model" config string directly produces "opencode server
    // returned status 400: ...expected object, received string" on every message.

    func testProviderModelSplitsProviderAndModelID() {
        let result = OpenCodeServerClient.providerModel(from: "anthropic/claude-sonnet-4-5")
        XCTAssertEqual(result?.providerID, "anthropic")
        XCTAssertEqual(result?.modelID, "claude-sonnet-4-5")
    }

    func testProviderModelHandlesModelIDContainingSlashes() {
        // Some model ids are themselves slash-delimited; only the FIRST
        // slash should separate provider from model.
        let result = OpenCodeServerClient.providerModel(from: "anthropic/claude-3/opus")
        XCTAssertEqual(result?.providerID, "anthropic")
        XCTAssertEqual(result?.modelID, "claude-3/opus")
    }

    func testProviderModelReturnsNilForMissingSlash() {
        XCTAssertNil(OpenCodeServerClient.providerModel(from: "just-a-model-name"))
    }

    func testProviderModelReturnsNilForEmptyString() {
        XCTAssertNil(OpenCodeServerClient.providerModel(from: ""))
        XCTAssertNil(OpenCodeServerClient.providerModel(from: "   "))
    }

    func testProviderModelReturnsNilWhenEitherHalfIsEmpty() {
        XCTAssertNil(OpenCodeServerClient.providerModel(from: "/model-only"))
        XCTAssertNil(OpenCodeServerClient.providerModel(from: "provider-only/"))
    }

    // MARK: - Text delta computation

    func testDeltaReturnsOnlyNewSuffixForStreamingText() {
        XCTAssertEqual(OpenCodeServerClient.delta(previous: "Hello", current: "Hello, world"), ", world")
    }

    func testDeltaReturnsFullStringWhenNotAPrefix() {
        // If the backend resends a divergent snapshot, emit the whole thing.
        XCTAssertEqual(OpenCodeServerClient.delta(previous: "abc", current: "xyz"), "xyz")
    }

    // MARK: - Argument summarization

    func testSummarizeProducesCompactSingleLine() {
        let summary = OpenCodeServerClient.summarize(#"{"insertEntityId":42,"attributeTag":"NAME"}"#)
        XCTAssertTrue(summary.contains("attributeTag: NAME"))
        XCTAssertTrue(summary.contains("insertEntityId:"))
        XCTAssertFalse(summary.contains("\n"))
    }

    func testSummarizeHandlesNonJSONGracefully() {
        XCTAssertEqual(OpenCodeServerClient.summarize("not json"), "")
        XCTAssertEqual(OpenCodeServerClient.summarize(nil), "")
    }

    // MARK: - Tool installer

    func testToolInstallerWritesForwardersAndBridgeClient() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("NovaCADToolTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let toolsDir = try NovaCADToolInstaller.install(bridgePort: 7777, token: "tok-test", workspace: workspace)

        // The bridge helper lives in .opencode/ (ABOVE tools/), never inside
        // tools/ — otherwise opencode registers it as a schema-less phantom
        // tool and crashes the turn.
        let opencodeDir = workspace.appendingPathComponent(".opencode", isDirectory: true)
        let bridgeURL = opencodeDir.appendingPathComponent("_novacad_bridge.ts")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bridgeURL.path),
                      "bridge helper must be in .opencode/")
        XCTAssertFalse(FileManager.default.fileExists(atPath: toolsDir.appendingPathComponent("_novacad_bridge.ts").path),
                       "bridge helper must NOT be inside tools/")
        let bridge = try String(contentsOf: bridgeURL, encoding: .utf8)
        XCTAssertTrue(bridge.contains("http://127.0.0.1:7777"))
        XCTAssertTrue(bridge.contains("export async function callBridge"))

        // Every declared tool has a forwarder that calls the bridge with its name.
        for spec in NovaCADToolInstaller.tools {
            let file = toolsDir.appendingPathComponent("\(spec.name).ts")
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "missing \(spec.name).ts")
            let source = try String(contentsOf: file, encoding: .utf8)
            XCTAssertTrue(source.contains("callBridge(\"\(spec.name)\""))
            XCTAssertTrue(source.contains("import { callBridge } from \"../_novacad_bridge\""))
            XCTAssertTrue(source.contains("import { tool } from \"@opencode-ai/plugin\""))
            XCTAssertTrue(source.contains("export default tool("))
            XCTAssertTrue(source.contains("tool.schema"))
        }
    }

    func testToolInstallerIncludesEveryDrawingTool() {
        let names = Set(NovaCADToolInstaller.tools.map(\.name))
        XCTAssertEqual(names, ["read_drawing", "get_insert_attributes", "find_insert_at_point",
                              "propose_attribute_edits", "bulk_set_attribute_on_layer",
                              "list_inserts_on_layer", "export_csv",
                              "analyze_aisle_network", "repair_aisle_network",
                              "find_route_endpoints", "route_along_aisles", "export_travel_distances",
                              "shade_aisle_network", "shade_dock_aprons",
                              "get_selected_objects", "draw_polylines", "query_entities", "inspect_xrefs",
                              "inspect_geometry", "propose_geometry_edits", "propose_explode_block"])
    }

    /// Guards the exact three-way drift this codebase's own comments warn
    /// about (`AIToolSchema.tools`, `NovaCADToolInstaller.tools`, and
    /// `NovaCADToolRouter.knownTools` must all name the SAME tools, since
    /// `AIToolExecutor.execute(tool:arguments:)` is the single dispatch
    /// point both backends funnel through) — this test would have caught
    /// forgetting to update any one of the three when the aisle/dock tool
    /// catalog was added.
    func testAllThreeToolCatalogsStayInSync() {
        let schemaNames = Set(AIToolSchema.tools.map(\.name))
        let installerNames = Set(NovaCADToolInstaller.tools.map(\.name))
        let routerNames = NovaCADToolRouter.knownTools
        XCTAssertEqual(schemaNames, installerNames,
                      "AIToolSchema.tools and NovaCADToolInstaller.tools must declare the same tools")
        XCTAssertEqual(schemaNames, routerNames,
                      "AIToolSchema.tools and NovaCADToolRouter.knownTools must declare the same tools")
    }

    // MARK: - opencode.json (built-in tool disabling)
    //
    // Regression coverage for a real bug: a user's turn hung indefinitely
    // after opencode's built-in INTERACTIVE `question` tool was called — no
    // NovaCAD UI exists to answer it, so the turn never completed until the
    // idle watchdog killed it. Their first message worked fine (no
    // clarification needed); every later message the agent wanted to ask
    // about silently hung, which reads like "the assistant stopped replying"
    // rather than a tool problem.

    func testWrittenConfigDisablesTheInteractiveQuestionTool() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("NovaCADConfigTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        OpenCodeServerClient.writeToolsConfig(workspace: workspace)
        let data = try Data(contentsOf: workspace.appendingPathComponent("opencode.json"))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let tools = try XCTUnwrap(json["tools"] as? [String: Bool])

        XCTAssertEqual(tools["question"], false,
                       "the interactive question tool must be disabled — NovaCAD has no UI to answer it")
        // Every coding tool must still be disabled too (invariant #14) —
        // confirms the refactor into a shared config dict didn't drop any.
        for name in ["bash", "edit", "write", "read", "grep", "glob", "list",
                    "patch", "webfetch", "todowrite", "todoread", "task"] {
            XCTAssertEqual(tools[name], false, "\(name) must remain disabled")
        }
    }

    func testRefreshToolsConfigIfChangedIsANoOpWhenAlreadyCurrent() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("NovaCADConfigTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        OpenCodeServerClient.writeToolsConfig(workspace: workspace)
        let url = workspace.appendingPathComponent("opencode.json")
        let before = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date

        Thread.sleep(forTimeInterval: 0.05)
        let changed = OpenCodeServerClient.refreshToolsConfigIfChanged(workspace: workspace)
        let after = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date

        XCTAssertFalse(changed, "an already-current config must not be reported as changed")
        XCTAssertEqual(before, after, "an already-current config must not be rewritten")
    }

    func testRefreshToolsConfigIfChangedRewritesAStaleConfig() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("NovaCADConfigTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        // Simulates a server that has been running since BEFORE the
        // question-tool fix shipped — its on-disk config predates the fix.
        let staleConfig: [String: Any] = ["$schema": "https://opencode.ai/config.json",
                                          "tools": ["bash": false]]
        let staleData = try JSONSerialization.data(withJSONObject: staleConfig, options: [.sortedKeys])
        try staleData.write(to: workspace.appendingPathComponent("opencode.json"))

        let changed = OpenCodeServerClient.refreshToolsConfigIfChanged(workspace: workspace)
        XCTAssertTrue(changed, "a config missing the question-tool fix must be reported as changed")

        let data = try Data(contentsOf: workspace.appendingPathComponent("opencode.json"))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let tools = try XCTUnwrap(json["tools"] as? [String: Bool])
        XCTAssertEqual(tools["question"], false, "the rewritten config must include the question-tool fix")
    }

    func testRefreshToolsConfigIfChangedWritesFreshWhenNoFileExists() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("NovaCADConfigTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        XCTAssertFalse(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("opencode.json").path))
        let changed = OpenCodeServerClient.refreshToolsConfigIfChanged(workspace: workspace)
        XCTAssertTrue(changed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: workspace.appendingPathComponent("opencode.json").path))
    }

    func testToolInstallerIsIdempotent() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("NovaCADToolTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let dir = try NovaCADToolInstaller.install(bridgePort: 8000, token: "tok-test", workspace: workspace)
        let file = dir.appendingPathComponent("read_drawing.ts")
        let firstModified = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date

        Thread.sleep(forTimeInterval: 0.05)
        _ = try NovaCADToolInstaller.install(bridgePort: 8000, token: "tok-test", workspace: workspace)
        let secondModified = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date

        XCTAssertEqual(firstModified, secondModified, "Identical reinstall should not churn file mtime")
    }

    func testToolInstallerUninstallRemovesDirectory() throws {
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("NovaCADToolTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        _ = try NovaCADToolInstaller.install(bridgePort: 8100, token: "tok-test", workspace: workspace)
        try NovaCADToolInstaller.uninstall(workspace: workspace)
        let toolsDir = workspace.appendingPathComponent(".opencode/tools")
        XCTAssertFalse(FileManager.default.fileExists(atPath: toolsDir.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: workspace.appendingPathComponent(".opencode/_novacad_bridge.ts").path))
    }

    func testJSStringEscapesQuotesAndNewlines() {
        let escaped = NovaCADToolInstaller.jsString("a \"quote\"\nand newline")
        XCTAssertEqual(escaped, "\"a \\\"quote\\\"\\nand newline\"")
    }

    // MARK: - BusEvent decoding (message.updated / message.part.updated)

    func testMessageUpdatedEventDecodesAssistantRole() throws {
        let json = """
        {"type":"message.updated","properties":{"info":{"id":"msg_abc","sessionID":"ses_1","role":"assistant"}}}
        """
        let event = try JSONDecoder().decode(BusEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.type, "message.updated")
        XCTAssertEqual(event.properties?.info?.id, "msg_abc")
        XCTAssertEqual(event.properties?.info?.role, "assistant")
    }

    func testMessageUpdatedEventDecodesUserRole() throws {
        let json = """
        {"type":"message.updated","properties":{"info":{"id":"msg_user1","sessionID":"ses_1","role":"user"}}}
        """
        let event = try JSONDecoder().decode(BusEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.properties?.info?.role, "user")
    }

    /// Regression: in a TOOL-CALLING turn the session holds multiple
    /// assistant messages — an earlier one that only invokes the tool (no
    /// user-facing text) and a newer one with the real answer. Extracting
    /// text must return the NEWEST assistant message's text.
    func testAssistantTextFromListPrefersNewestMessageAfterToolLoop() throws {
        let json = """
        [
          {"info":{"id":"msg_1","role":"user"},"parts":[{"type":"text","text":"hi"}]},
          {"info":{"id":"msg_2","role":"assistant"},"parts":[{"type":"step-start"},{"type":"tool","tool":"read_drawing","state":{"status":"completed"}},{"type":"step-finish"}]},
          {"info":{"id":"msg_3","role":"assistant"},"parts":[{"type":"text","text":"Here is the answer after the tool ran."},{"type":"step-finish"}]}
        ]
        """
        let text = OpenCodeServerClient.assistantText(fromMessageListJSON: Data(json.utf8))
        XCTAssertEqual(text, "Here is the answer after the tool ran.",
                       "Must return the newest assistant message's text, not the earlier tool-only step")
    }

    func testMessagePartUpdatedEventDecodesMessageID() throws {
        let json = """
        {"type":"message.part.updated","properties":{"part":{"id":"prt_1","sessionID":"ses_1","messageID":"msg_abc","type":"text","text":"hello"}}}
        """
        let event = try JSONDecoder().decode(BusEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.properties?.part?.messageID, "msg_abc")
        XCTAssertEqual(event.properties?.part?.text, "hello")
    }

    /// Regression: opencode v1.2.x streams the assistant reply token-by-token
    /// as `message.part.delta` events (a top-level `field`+`delta` pair on
    /// `properties`, NOT nested in `part`).
    func testMessagePartDeltaEventDecodesTextDelta() throws {
        let json = """
        {"type":"message.part.delta","properties":{"sessionID":"ses_1","messageID":"msg_asst1","partID":"prt_1","field":"text","delta":"O"}}
        """
        let event = try JSONDecoder().decode(BusEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.type, "message.part.delta")
        XCTAssertEqual(event.properties?.sessionID, "ses_1")
        XCTAssertEqual(event.properties?.messageID, "msg_asst1")
        XCTAssertEqual(event.properties?.field, "text")
        XCTAssertEqual(event.properties?.delta, "O")
    }

    /// Regression: `session.error` carries a NESTED error object, not a
    /// string. Decoding it as a flat String silently produced nil.
    func testSessionErrorEventDecodesNestedMessage() throws {
        let json = """
        {"type":"session.error","properties":{"sessionID":"ses_1","error":{"name":"UnknownError","data":{"message":"Model not found: anthropic/xyz."}}}}
        """
        let event = try JSONDecoder().decode(BusEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.type, "session.error")
        XCTAssertEqual(event.properties?.error, "Model not found: anthropic/xyz.")
    }

    func testSessionErrorEventFallsBackToReasonThenName() throws {
        let reasonJSON = """
        {"type":"session.error","properties":{"sessionID":"ses_1","error":{"name":"AI_APICallError","data":{"reason":"TARGET_READ_TIMEOUT"}}}}
        """
        let reasonEvent = try JSONDecoder().decode(BusEvent.self, from: Data(reasonJSON.utf8))
        XCTAssertEqual(reasonEvent.properties?.error, "TARGET_READ_TIMEOUT")

        let nameJSON = """
        {"type":"session.error","properties":{"sessionID":"ses_1","error":{"name":"GatewayTimeout"}}}
        """
        let nameEvent = try JSONDecoder().decode(BusEvent.self, from: Data(nameJSON.utf8))
        XCTAssertEqual(nameEvent.properties?.error, "GatewayTimeout")
    }

    func testSessionErrorEventStillDecodesPlainStringForm() throws {
        let json = """
        {"type":"session.error","properties":{"sessionID":"ses_1","error":"boom"}}
        """
        let event = try JSONDecoder().decode(BusEvent.self, from: Data(json.utf8))
        XCTAssertEqual(event.properties?.error, "boom")
    }

    /// End-to-end reproduction (via decoding only, no network): the user's
    /// own message part update must NOT be treated as assistant text, only
    /// the assistant message's own text parts should be.
    func testUserMessagePartCanBeDistinguishedFromAssistantMessagePart() throws {
        let userMessageUpdated = try JSONDecoder().decode(BusEvent.self, from: Data("""
        {"type":"message.updated","properties":{"info":{"id":"msg_user1","sessionID":"ses_1","role":"user"}}}
        """.utf8))
        let userTextPart = try JSONDecoder().decode(BusEvent.self, from: Data("""
        {"type":"message.part.updated","properties":{"part":{"id":"prt_1","sessionID":"ses_1","messageID":"msg_user1","type":"text","text":"Say BANANA"}}}
        """.utf8))
        let assistantMessageUpdated = try JSONDecoder().decode(BusEvent.self, from: Data("""
        {"type":"message.updated","properties":{"info":{"id":"msg_asst1","sessionID":"ses_1","role":"assistant"}}}
        """.utf8))
        let assistantTextPart = try JSONDecoder().decode(BusEvent.self, from: Data("""
        {"type":"message.part.updated","properties":{"part":{"id":"prt_2","sessionID":"ses_1","messageID":"msg_asst1","type":"text","text":"BANANA"}}}
        """.utf8))

        var assistantMessageID: String?
        if userMessageUpdated.properties?.info?.role == "assistant" {
            assistantMessageID = userMessageUpdated.properties?.info?.id
        }
        XCTAssertNil(assistantMessageID, "A user message.updated event must never set the assistant messageID")

        XCTAssertNotEqual(userTextPart.properties?.part?.messageID, assistantMessageID,
                          "The user's own text part must not match the (still-nil) assistant messageID")

        if assistantMessageUpdated.properties?.info?.role == "assistant" {
            assistantMessageID = assistantMessageUpdated.properties?.info?.id
        }
        XCTAssertEqual(assistantMessageID, "msg_asst1")
        XCTAssertEqual(assistantTextPart.properties?.part?.messageID, assistantMessageID,
                       "The assistant's own text part must match the tracked assistant messageID")
    }

    // MARK: - ConnectionSignal (SSE-connect-before-prompt-POST race, closed)
    //
    // `OpenCodeServerClient.sendStreaming` fires the prompt POST and the
    // `/event` SSE GET concurrently; without an explicit rendezvous, the
    // prompt could be posted before the SSE listener was actually connected,
    // silently losing that turn's events (SSE has no backlog/replay).
    // `ConnectionSignal` is the rendezvous that closes this race — exercised
    // here as a pure concurrency primitive, with no live server involved.

    func testWaitUntilConnectedReturnsImmediatelyAfterSignal() async throws {
        let signal = OpenCodeServerClient.ConnectionSignal()
        await signal.signal()
        try await signal.waitUntilConnected()
    }

    func testWaitUntilConnectedBlocksUntilSignalIsCalled() async throws {
        let signal = OpenCodeServerClient.ConnectionSignal()
        let waiterStarted = expectation(description: "waiter task started")
        let waiterFinished = expectation(description: "waiter task finished")

        let waiter = Task {
            waiterStarted.fulfill()
            try await signal.waitUntilConnected()
            waiterFinished.fulfill()
        }

        await fulfillment(of: [waiterStarted], timeout: 1)
        try await Task.sleep(nanoseconds: 50_000_000)
        await signal.signal()

        await fulfillment(of: [waiterFinished], timeout: 1)
        _ = try await waiter.value
    }

    func testWaitUntilConnectedThrowsAfterFail() async {
        let signal = OpenCodeServerClient.ConnectionSignal()
        struct DummyError: Error {}
        await signal.fail(DummyError())

        do {
            try await signal.waitUntilConnected()
            XCTFail("expected waitUntilConnected() to throw after fail(_:)")
        } catch {
            XCTAssertTrue(error is DummyError)
        }
    }

    func testMultipleWaitersAllResumeOnSignal() async throws {
        let signal = OpenCodeServerClient.ConnectionSignal()
        async let first: Void = signal.waitUntilConnected()
        async let second: Void = signal.waitUntilConnected()
        async let third: Void = signal.waitUntilConnected()

        try await Task.sleep(nanoseconds: 50_000_000)
        await signal.signal()

        _ = try await (first, second, third)
    }

    func testSignalAfterFailIsANoOp() async {
        let signal = OpenCodeServerClient.ConnectionSignal()
        struct DummyError: Error {}
        await signal.fail(DummyError())
        await signal.signal() // must not override the already-failed state

        do {
            try await signal.waitUntilConnected()
            XCTFail("expected the original failure to still be reported")
        } catch {
            XCTAssertTrue(error is DummyError)
        }
    }

    // MARK: - Orphaned server cleanup

    func testOrphanedServerPIDsFindsProcessParentedToLaunchd() {
        let output = """
          1234     1  /usr/local/bin/opencode serve --hostname 127.0.0.1 --port 50114
        """
        XCTAssertEqual(OpenCodeServerClient.orphanedServerPIDs(fromPSOutput: output), [1234])
    }

    func testOrphanedServerPIDsIgnoresProcessStillParentedToALiveApp() {
        // PPID 82777 (a live NovaCAD instance, not launchd) — must NOT be swept.
        let output = """
          44138 82777  /usr/local/bin/opencode serve --hostname 127.0.0.1 --port 53251
        """
        XCTAssertTrue(OpenCodeServerClient.orphanedServerPIDs(fromPSOutput: output).isEmpty)
    }

    func testOrphanedServerPIDsIgnoresUnrelatedProcesses() {
        let output = """
          100     1  /usr/bin/some-other-daemon --flag
          200     1  /usr/local/bin/opencode --version
          300     1  -bash
        """
        XCTAssertTrue(OpenCodeServerClient.orphanedServerPIDs(fromPSOutput: output).isEmpty)
    }

    func testOrphanedServerPIDsFindsMultipleOrphansAndSkipsLiveOnes() {
        let output = """
          22624     1  /usr/local/bin/opencode serve --hostname 127.0.0.1 --port 60862
          25858     1  /usr/local/bin/opencode serve --hostname 127.0.0.1 --port 60998
          44138 82777  /usr/local/bin/opencode serve --hostname 127.0.0.1 --port 53251
          88074     1  /usr/local/bin/opencode serve --hostname 127.0.0.1 --port 50114
        """
        XCTAssertEqual(
            Set(OpenCodeServerClient.orphanedServerPIDs(fromPSOutput: output)),
            Set([22624, 25858, 88074])
        )
    }

    func testOrphanedServerPIDsHandlesEmptyOutput() {
        XCTAssertTrue(OpenCodeServerClient.orphanedServerPIDs(fromPSOutput: "").isEmpty)
    }

    func testOrphanedServerPIDsIgnoresMalformedLines() {
        let output = """
          not-a-pid  1  /usr/local/bin/opencode serve --hostname 127.0.0.1 --port 1
          1234  not-a-ppid  /usr/local/bin/opencode serve --hostname 127.0.0.1 --port 2
        """
        XCTAssertTrue(OpenCodeServerClient.orphanedServerPIDs(fromPSOutput: output).isEmpty)
    }

    func testTerminateManagedServerProcessSynchronouslyIsANoOpWithNoRunningServer() {
        // A fresh client (no `ensureServer` call yet) has no managed PID.
        // Must not crash / must not signal an arbitrary PID.
        OpenCodeServerClient.terminateManagedServerProcessSynchronously()
    }

    // MARK: - Concurrent ensureServer callers join one attempt (not a race)
    //
    // Regression coverage for the recurring "The opencode server did not
    // become healthy in time" error: `ensureServer` awaits twice
    // (resolveBinary, then startServer's health wait) before ever assigning
    // `self.server`, so a second caller arriving during that window would
    // ALSO see `server == nil` and spawn its own competing `opencode serve`
    // process. These tests use a config with a bogus (nonexistent) binary
    // path, so `resolveBinary` fails fast with NO real process ever spawned —
    // purely exercising the concurrency-safety of `ensureServer` itself.

    func testConcurrentEnsureServerCallersJoinASingleStartupAttempt() async {
        let client = OpenCodeServerClient()
        let config = AIConfig.opencodeServerDefaults(binaryPath: "/nonexistent/opencode-binary-for-testing")

        async let first: Void = { _ = try? await client.listModels(config: config) }()
        async let second: Void = { _ = try? await client.listModels(config: config) }()
        async let third: Void = { _ = try? await client.listModels(config: config) }()
        _ = await (first, second, third)

        let attempts = await client.startAttemptCountForTesting
        XCTAssertEqual(attempts, 1, "Concurrent ensureServer callers must collapse into a single startup attempt, not race independent ones")
    }

    func testSequentialEnsureServerCallsEachAttemptIndependentlyAfterFailure() async {
        let client = OpenCodeServerClient()
        let config = AIConfig.opencodeServerDefaults(binaryPath: "/nonexistent/opencode-binary-for-testing")

        _ = try? await client.listModels(config: config)
        _ = try? await client.listModels(config: config)

        let attempts = await client.startAttemptCountForTesting
        XCTAssertEqual(attempts, 2, "Sequential (non-overlapping) calls must each retry independently")
    }

    // MARK: - Conversation session persistence

    func testResetConversationSessionIsANoOpWithNoLiveServer() async {
        let client = OpenCodeServerClient()
        await client.resetConversationSession()
    }

    func testResetConversationSessionIsIdempotent() async {
        let client = OpenCodeServerClient()
        await client.resetConversationSession()
        await client.resetConversationSession()
    }

    // MARK: - NovaCADToolRouter argument normalization
    //
    // `propose_attribute_edits`'s Zod forwarder sends `edits` as a single
    // JSON string (a serialized array), while `AIToolExecutor.execute`
    // (shared with the Anthropic tool loop) expects `edits` as an array of
    // per-edit JSON strings. `NovaCADToolRouter.handle` must normalize
    // between these two shapes.

    @MainActor
    func testRouterUnknownToolThrows() async {
        let rc = try! RegenCoordinatorTestHelper.emptyCoordinator()
        let executor = AIToolExecutor(regen: rc, visibility: VisibilityState())
        let router = NovaCADToolRouter(executor: executor)
        do {
            _ = try await router.handle(tool: "delete_everything", body: Data())
            XCTFail("expected unknownTool to throw")
        } catch {
            XCTAssertTrue(error is NovaCADToolError)
        }
    }

    @MainActor
    func testRouterNormalizesEditsJSONStringIntoPerEditStrings() async throws {
        let rc = try RegenCoordinatorTestHelper.emptyCoordinator()
        let executor = AIToolExecutor(regen: rc, visibility: VisibilityState())
        let router = NovaCADToolRouter(executor: executor)

        // The Zod forwarder's shape: `edits` as ONE JSON string containing an array.
        let body = #"{"edits":"[{\"insertEntityId\":1,\"attributeTag\":\"NAME\",\"newValue\":\"X\"}]"}"#
        let result = try await router.handle(tool: "propose_attribute_edits", body: Data(body.utf8))
        // No INSERT with entityId 1 exists in an empty document, so the edit
        // is rejected — but the important thing is the router successfully
        // PARSED and forwarded it as a per-edit array rather than choking on
        // the outer JSON-string-of-an-array shape (a parse failure would
        // instead report "0 edit(s)" AND a rejected-count, or throw).
        XCTAssertFalse(result.isEmpty)
    }
}

/// Minimal helper for constructing an empty `RegenCoordinator` for tests that
/// only need a valid, harmless target for `AIToolExecutor` — no entities,
/// just a live document/store. Kept file-local since only this test file
/// needs a "totally empty" coordinator (other AI tests use a populated
/// fixture via `AIAssistantTests`'s own `makeCoordinator`).
private enum RegenCoordinatorTestHelper {
    @MainActor
    static func emptyCoordinator() throws -> RegenCoordinator {
        let parsed = EditableParsedDocument()
        parsed.layers.append(DXFLayer(id: 0, name: "0"))
        parsed.layerIdByName["0"] = 0
        parsed.linetypes.append(DXFLinetype(name: "CONTINUOUS", dashes: []))
        parsed.linetypeIdByName["CONTINUOUS"] = 0
        let doc = Regenerator.build(from: parsed, parseSeconds: 0) { _ in }
        return RegenCoordinator(parsed: parsed, document: doc)
    }
}
