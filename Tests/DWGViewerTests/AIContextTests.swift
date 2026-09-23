import XCTest
import CADCore
@testable import DWGViewer

final class AIContextTests: XCTestCase {
    func testMarkdownEmphasisLinksListsHeadingsAndCode() {
        let blocks = AIMarkdown.blocks("## Findings\n\n- **Kitchen** and [plan](https://example.com)\n1. Confirm scale\n\n```swift\nlet x = \"**literal**\"\n```")
        XCTAssertEqual(blocks.count, 4)
        XCTAssertTrue(blocks[0].isHeading)
        XCTAssertEqual(blocks[1].marker, "•")
        XCTAssertEqual(blocks[2].marker, "1.")
        XCTAssertTrue(blocks[3].isCode)
        XCTAssertTrue(blocks[3].text.contains("**literal**"))
        let inline = AIMarkdown.inline(blocks[1].text)
        XCTAssertEqual(String(inline.characters), "Kitchen and plan")
        XCTAssertTrue(inline.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        XCTAssertTrue(inline.runs.contains { $0.link?.absoluteString == "https://example.com" })
    }

    func testUnfinishedMarkdownRemainsVisibleDuringStreaming() {
        XCTAssertEqual(AIMarkdown.blocks("```\npartial code").first?.text, "partial code")
        XCTAssertFalse(String(AIMarkdown.inline("**unfinished").characters).isEmpty)
    }

    func testRecentTranscriptKeepsNewestQuestionAndWholePriorTurns() {
        var messages = [AIMessage(role: .system, content: "Instructions")]
        for i in 0..<20 {
            messages.append(.init(role: .user, content: "Question \(i)"))
            messages.append(.init(role: .assistant, content: String(repeating: "é", count: 2500)))
        }
        messages.append(.init(role: .user, content: "Measure between the kitchens"))
        let bounded = AIContextBudget.recentMessages(messages)
        XCTAssertEqual(bounded.first, messages.first)
        XCTAssertEqual(bounded.last, messages.last)
        XCTAssertEqual(bounded[1].role, .user)
        XCTAssertLessThan(bounded.count, messages.count)
        XCTAssertLessThanOrEqual(bounded.dropFirst().reduce(0) { $0 + $1.content.utf8.count }, AIContextBudget.transcriptBytes)
        XCTAssertEqual(messages.count, 42) // UI history is not mutated.
    }

    func testUnicodeAndHugeUserInputStayWithinByteBudget() {
        let text = String(repeating: "👩🏽‍💻厨房", count: 10000)
        XCTAssertLessThanOrEqual(AIContextBudget.clipped(text, bytes: 768).utf8.count, 768)
        let bounded = AIContextBudget.recentMessages([.init(role: .user, content: text)])
        XCTAssertLessThanOrEqual(bounded[0].content.utf8.count, AIContextBudget.transcriptBytes)
        XCTAssertThrowsError(try AIContextBudget.checkedToolResult(text))
    }

    func testToolLoopCompactionPreservesLatestCallResultPairsAndQuestion() throws {
        var messages: [AnthropicRequest.Message] = [.init(role: "user", content: .text("Find kitchens"))]
        for i in 0..<12 {
            messages.append(.init(role: "assistant", content: .blocks([
                .thinking("Reasoning", signature: "signed"),
                .toolUse(id: "call\(i)", name: "query_entities", input: AIAnyEncodable(json: [:]))])))
            messages.append(.init(role: "user", content: .blocks([
                .toolResult(toolUseID: "call\(i)", content: String(repeating: "x", count: 16000))])))
        }
        let bounded = try AIContextBudget.compact(messages, model: "test", system: "Instructions", tools: AIToolSchema.tools)
        let data = try JSONEncoder().encode(AnthropicRequest(model: "test", system: "Instructions", messages: bounded, maxTokens: 4096, tools: AIToolSchema.tools))
        XCTAssertLessThanOrEqual(data.count, AIContextBudget.requestBytes)
        XCTAssertLessThan(bounded.count, messages.count)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("Find kitchens"))
        for i in stride(from: 1, to: bounded.count, by: 2) {
            guard case .blocks(let calls) = bounded[i].content,
                  case .blocks(let replies) = bounded[i + 1].content else { return XCTFail("Lost tool pairing") }
            XCTAssertEqual(calls.last?.id, replies.first?.toolUseID)
            XCTAssertEqual(calls.first?.signature, "signed")
        }
        guard case .blocks(let last) = bounded.last?.content else { return XCTFail() }
        XCTAssertEqual(last.first?.toolUseID, "call11")
    }

    func testUncompactableRequestFailsBeforeNetwork() {
        XCTAssertThrowsError(try AIContextBudget.compact([
            .init(role: "user", content: .text(String(repeating: "x", count: 200000)))
        ], model: "test", system: nil, tools: nil))
    }

    @MainActor func testDefaultSpaceFollowsLiveViewAndOtherSheetQueryDoesNotNavigate() throws {
        let regen = try RegenCoordinator.loadPackage(url: TestFixtures.url("multiple_layouts.dxf"))
        regen.selectPaperLayout(0x1B)
        var space = SpaceID.paper
        let executor = AIToolExecutor(regen: regen, visibility: VisibilityState(), spaceProvider: { space })
        let overview = try object(executor.execute(tool: "read_drawing", arguments: [:]))
        XCTAssertEqual(overview["space"] as? String, "paper")
        let workspace = try XCTUnwrap(overview["workspace"] as? [String: Any])
        XCTAssertEqual(workspace["activeSheet"] as? String, "Construction")
        XCTAssertEqual(workspace["paperSheetCount"] as? Int, 2)
        let revision = regen.revision
        let before = regen.document
        let other = try object(executor.execute(tool: "query_entities", arguments: ["sheetName": "Furniture"]))
        XCTAssertEqual(other["sheetName"] as? String, "Furniture")
        XCTAssertEqual(regen.parsed.activePaperLayoutID, 0x1B)
        XCTAssertEqual(regen.revision, revision)
        XCTAssertEqual(regen.document.paperGroups.count, before.paperGroups.count)
        space = .model
        let model = try object(executor.execute(tool: "read_drawing", arguments: [:]))
        XCTAssertEqual(model["space"] as? String, "model")
        XCTAssertThrowsError(try executor.execute(tool: "query_entities", arguments: ["space": "paper", "sheetName": "missing"]))
    }

    @MainActor func testLargeTextQueryPagesWithoutSkippingMatchesOrBreakingJSON() throws {
        let parsed = EditableParsedDocument()
        parsed.layers = [DXFLayer(id: 0, name: "0")]
        parsed.document.transact("Fixture") { tx in
            for i in 0..<80 {
                let string = parsed.store.strings.intern("Kitchen \(i) " + String(repeating: "厨房", count: 300))
                _ = tx.add(EntityPrototype(type: .text, layerId: 0, owner: .model,
                    payload: .text(TextPayload(position: Vec3(x: Double(i), y: 0), height: 1, stringId: string))))
            }
        }
        let regen = RegenCoordinator(parsed: parsed, document: Regenerator.build(from: parsed, parseSeconds: 0) { _ in })
        let executor = AIToolExecutor(regen: regen, visibility: VisibilityState())
        var offset = 0
        var ids = Set<Int>()
        repeat {
            let text = try executor.execute(tool: "query_entities", arguments: ["textContains": "Kitchen", "limit": 2000, "offset": offset])
            XCTAssertLessThanOrEqual(text.utf8.count, AIContextBudget.toolBytes)
            let result = try object(text)
            XCTAssertEqual(result["totalMatched"] as? Int, 80)
            let rows = try XCTUnwrap(result["rows"] as? [[String: Any]])
            XCTAssertFalse(rows.isEmpty)
            for row in rows {
                XCTAssertTrue(ids.insert(try XCTUnwrap(row["entityId"] as? Int)).inserted)
                XCTAssertEqual(row["textTruncated"] as? Bool, true)
            }
            guard let next = result["nextOffset"] as? Int else { break }
            XCTAssertGreaterThan(next, offset)
            offset = next
        } while offset < 80
        XCTAssertEqual(ids.count, 80)
        let summary = try executor.execute(tool: "read_drawing", arguments: [:])
        XCTAssertLessThanOrEqual(summary.utf8.count, AIContextBudget.toolBytes)
        let counts = try object(executor.execute(tool: "query_entities", arguments: ["countOnly": true]))
        XCTAssertNil(counts["nextOffset"])
    }

    private func object(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    /// Opt-in local smoke: private drawings never become repository fixtures.
    @MainActor func testOptInLargeDrawingOverviewAndCrossSheetSearch() throws {
        guard let path = ProcessInfo.processInfo.environment["NOVACAD_AI_SAMPLE"] else {
            throw XCTSkip("Set NOVACAD_AI_SAMPLE to a local drawing for the large-file smoke")
        }
        let regen = try RegenCoordinator.loadPackage(url: URL(fileURLWithPath: path))
        let first = try XCTUnwrap(regen.navigationPaperLayouts.first)
        regen.selectPaperLayout(first.id)
        let executor = AIToolExecutor(regen: regen, visibility: VisibilityState(), spaceProvider: { .paper })
        let overview = try executor.execute(tool: "read_drawing", arguments: [:])
        XCTAssertLessThanOrEqual(overview.utf8.count, AIContextBudget.toolBytes)
        let revision = regen.revision
        var matches = 0
        for sheet in regen.navigationPaperLayouts.prefix(6) {
            let text = try executor.execute(tool: "query_entities", arguments: [
                "space": "paper", "sheetName": sheet.name, "textContains": "Kitchen"
            ])
            XCTAssertLessThanOrEqual(text.utf8.count, AIContextBudget.toolBytes)
            let result = try object(text)
            XCTAssertEqual(result["sheetName"] as? String, sheet.name)
            matches += result["totalMatched"] as? Int ?? 0
            XCTAssertEqual(regen.parsed.activePaperLayoutID, first.id)
            XCTAssertEqual(regen.revision, revision)
        }
        if ProcessInfo.processInfo.environment["NOVACAD_AI_EXPECT_KITCHENS"] == "1" {
            XCTAssertGreaterThan(matches, 0, "The sample should contain searchable kitchen labels")
        }
    }
}
