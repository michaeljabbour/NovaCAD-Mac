import Foundation

/// Byte budgets are deliberately conservative: geometry JSON tokenizes much
/// less efficiently than prose. These limits apply before any provider call.
enum AIContextBudget {
    static let toolBytes = 16_384
    static let transcriptBytes = 24_576
    static let requestBytes = 131_072

    static func clipped(_ text: String, bytes: Int) -> String {
        guard text.utf8.count > bytes else { return text }
        return String(decoding: text.utf8.prefix(max(0, bytes - 6)), as: UTF8.self) + "…"
    }

    /// Keep the visible transcript intact; send only recent complete user turns.
    static func recentMessages(_ messages: [AIMessage]) -> [AIMessage] {
        let system = messages.filter { $0.role == .system }
        let conversation = messages.filter { $0.role != .system }
        var turns: [[AIMessage]] = []
        for message in conversation {
            if message.role == .user || turns.isEmpty { turns.append([]) }
            turns[turns.count - 1].append(message)
        }
        var remaining = transcriptBytes
        var kept: [AIMessage] = []
        for turn in turns.reversed() {
            let size = turn.reduce(0) { $0 + $1.content.utf8.count }
            if size <= remaining {
                kept.insert(contentsOf: turn, at: 0)
                remaining -= size
            } else if kept.isEmpty {
                // An unusually large pasted question still leaves room for tools.
                kept = turn.map { AIMessage(role: $0.role, content: clipped($0.content, bytes: transcriptBytes / max(1, turn.count))) }
                break
            } else { break }
        }
        return system + kept
    }

    /// Preserve valid JSON and call/result pairing. An unexpectedly large tool
    /// reply becomes an explicit error, never a silently truncated success.
    static func checkedToolResult(_ text: String) throws -> String {
        guard text.utf8.count <= toolBytes else {
            throw AIClientError.transport("Tool result exceeded the response budget. Use query_entities with filters, countOnly, and offset/limit; use native export tools for complete datasets. Any staged proposal remains available for review.")
        }
        return text
    }

    /// Drop only complete OLD tool exchanges, retaining the current result and
    /// original question. The UI transcript and staged edits are unaffected.
    static func compact(_ messages: [AnthropicRequest.Message], model: String,
                        system: String?, tools: [AIToolSchema.Tool]?) throws -> [AnthropicRequest.Message] {
        var result = messages
        func encodedSize() throws -> Int {
            try JSONEncoder().encode(AnthropicRequest(model: model, system: system,
                messages: result, maxTokens: 4096, tools: tools)).count
        }
        while try encodedSize() > requestBytes {
            let exchanges = result.indices.filter { i in
                guard i + 1 < result.count, result[i].role == "assistant",
                      case .blocks(let calls) = result[i].content,
                      calls.contains(where: { $0.type == "tool_use" }),
                      case .blocks(let replies) = result[i + 1].content else { return false }
                return replies.contains { $0.type == "tool_result" }
            }
            guard exchanges.count > 1, let first = exchanges.first else {
                throw AIClientError.transport("This request is too large to send. Narrow the question or request a smaller set of objects. Your conversation has been kept.")
            }
            result.removeSubrange(first...first + 1)
        }
        return result
    }
}
