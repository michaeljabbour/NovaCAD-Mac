import Foundation

/// A chat message exchanged with the LLM.
struct AIMessage: Equatable, Codable, Sendable {
    enum Role: String, Codable, Sendable { case system, user, assistant }
    var role: Role
    var content: String
}

/// Streaming-style events the tool loop yields, consumed by the AI Assistant
/// panel to render a live "thinking / tool call / done" timeline. Mirrors
/// the earlier project's stream-event shape, narrowed to what NovaCAD's plain
/// (non-agentic-server) backends actually produce — every event here comes
/// from full synchronous HTTP round-trips inside `AIClient.runAnthropicToolLoop`,
/// not real token-level streaming (the same "simulated streaming via a manual
/// multi-turn loop" approach that project uses for its own Anthropic path).
enum AIStreamEvent: Equatable, Sendable {
    /// OpenCode (agentic) only: the backend created/opened a session for this
    /// turn, carrying its id — mirrors the earlier project's
    /// `AIStreamEvent.sessionStarted`.
    /// Not emitted by the Anthropic tool loop (which has no separate
    /// server-side session concept), so every OTHER provider's consumer can
    /// simply ignore this case.
    case sessionStarted(String)
    case textDelta(String)
    /// Full replacement snapshot for a streaming assistant message when the
    /// backend revises text rather than appending a suffix.
    case textSnapshot(String)
    case toolCall(AIToolCallEvent)
    /// OpenCode (agentic) only: the backend is requesting permission before
    /// running a guarded action. NovaCAD's own tool catalog has no guarded
    /// tools today (see `AIToolSchema`'s doc comment — every NovaCAD tool is
    /// either a pure read or a stage-only propose), so this is plumbed
    /// through for full port parity but never actually triggered by
    /// `NovaCADToolBridge`'s own tool set; kept so a future guarded tool
    /// doesn't require re-threading this event type.
    case permissionRequest(AIPermissionRequest)
    /// OpenCode (agentic) only: a non-fatal status/heartbeat note.
    case status(String)
    case completed(String)
    case failed(String)
}

struct AIToolCallEvent: Equatable, Sendable {
    enum Status: String, Equatable, Sendable { case pending, running, completed, failed, awaitingPermission }
    let id: String
    var name: String
    var argumentSummary: String
    var status: Status
    var resultSummary: String?
}

/// A permission request raised by the OpenCode (agentic) backend before a
/// guarded tool runs. Mirrors the earlier project's permission request —
/// ported for full parity even though no NovaCAD tool is currently guarded (see
/// `AIStreamEvent.permissionRequest`'s own doc comment).
struct AIPermissionRequest: Identifiable, Equatable, Sendable {
    let id: String
    var toolName: String
    var detail: String
}

/// Thin async wrapper over an LLM gateway — one client, three provider
/// shapes (see `AIConfig.Provider`'s own doc comment for scope). Modeled
/// directly on the earlier project's LLM client: an actor over `URLSession`,
/// OpenAI-style and Anthropic-native wire formats behind one `complete(messages:)` entry
/// point, plus a dedicated Anthropic tool-calling loop.
actor AIClient {
    private let config: AIConfig
    private let session: URLSession

    static let requestTimeout: TimeInterval = 60

    init(config: AIConfig) {
        self.config = config
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = Self.requestTimeout
        configuration.timeoutIntervalForResource = Self.requestTimeout
        configuration.waitsForConnectivity = false
        self.session = URLSession(configuration: configuration)
    }

    /// Plain chat (no tool-calling) — used for `.openAICompatible`/`.opencode`,
    /// and available for `.anthropic`/`.opencodeServer` when the caller
    /// doesn't need tools (e.g. `AISettingsView`'s Test Connection probe).
    func complete(messages: [AIMessage]) async throws -> String {
        switch config.provider {
        case .opencode:
            return try await OpenCodeCLIClient().complete(messages: messages, config: config)
        case .openAICompatible:
            return try await completeOpenAI(messages: messages)
        case .anthropic:
            return try await completeAnthropic(messages: messages, tools: nil)
        case .opencodeServer:
            return try await OpenCodeServerRegistry.shared.testConnection(config: config)
        }
    }

    private func completeOpenAI(messages: [AIMessage]) async throws -> String {
        let body = OpenAIRequest(
            model: config.model,
            messages: messages.map { OpenAIRequest.Message(role: $0.role.rawValue, content: $0.content) },
            temperature: 0.2, maxTokens: 4096)
        let response: OpenAIResponse = try await post(path: "/chat/completions", body: body)
        guard let text = response.choices?.first?.message?.content, !text.isEmpty else {
            throw AIClientError.emptyResponse
        }
        return text
    }

    private func completeAnthropic(messages: [AIMessage], tools: [AIToolSchema.Tool]?) async throws -> String {
        let system = messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n\n")
        let convo = messages.filter { $0.role != .system }.map {
            AnthropicRequest.Message(role: $0.role == .assistant ? "assistant" : "user", content: .text($0.content))
        }
        // `temperature` intentionally omitted — see the earlier project's
        // LLM client's identical note: newer Claude models 400 on it.
        let body = AnthropicRequest(model: config.model, system: system.isEmpty ? nil : system,
                                    messages: convo, maxTokens: 4096, tools: tools)
        let response: AnthropicResponse = try await post(path: "/messages", body: body)
        let text = response.textContent
        guard !text.isEmpty else { throw AIClientError.emptyResponse }
        return text
    }

    // MARK: - Anthropic tool-calling loop

    static let maxToolIterations = 12

    /// Runs the Anthropic agentic tool loop, yielding `AIStreamEvent`s as it
    /// goes: `.toolCall` for each request the model makes to `executor`
    /// (running → completed/failed), then `.completed` with the final
    /// answer. Bounded at `maxToolIterations` round-trips so a model that
    /// keeps requesting tools can never loop forever.
    func runAnthropicToolLoop(messages: [AIMessage], executor: AIToolExecutor) -> AsyncThrowingStream<AIStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.driveToolLoop(messages: messages, executor: executor, continuation: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.yield(.failed(error.localizedDescription))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func driveToolLoop(messages: [AIMessage], executor: AIToolExecutor,
                               continuation: AsyncThrowingStream<AIStreamEvent, Error>.Continuation) async throws {
        let system = messages.filter { $0.role == .system }.map(\.content).joined(separator: "\n\n")
        var wire: [AnthropicRequest.Message] = messages.filter { $0.role != .system }.map {
            AnthropicRequest.Message(role: $0.role == .assistant ? "assistant" : "user", content: .text($0.content))
        }

        for _ in 0..<Self.maxToolIterations {
            try Task.checkCancellation()
            wire = try AIContextBudget.compact(wire, model: config.model, system: system, tools: AIToolSchema.tools)
            let body = AnthropicRequest(model: config.model, system: system.isEmpty ? nil : system,
                                        messages: wire, maxTokens: 4096, tools: AIToolSchema.tools)
            let response: AnthropicResponse = try await post(path: "/messages", body: body)
            let interimText = response.textContent

            guard response.wantsToolUse, !response.toolUseBlocks.isEmpty else {
                continuation.yield(.completed(interimText))
                return
            }
            if !interimText.isEmpty { continuation.yield(.textDelta(interimText + "\n\n")) }

            wire.append(.init(role: "assistant", content: .blocks(response.echoedAssistantBlocks)))

            var resultBlocks: [AnthropicRequest.Message.Block] = []
            for block in response.toolUseBlocks {
                try Task.checkCancellation()
                let callID = block.id ?? UUID().uuidString
                let toolName = block.name ?? ""
                let argsAny = (block.input ?? [:]).mapValues { $0.anyValue }
                let summary = Self.argumentSummary(tool: toolName, arguments: argsAny)
                continuation.yield(.toolCall(AIToolCallEvent(id: callID, name: toolName, argumentSummary: summary, status: .running, resultSummary: nil)))

                let (resultText, isError) = await Self.executeTool(executor: executor, name: toolName, arguments: argsAny)
                continuation.yield(.toolCall(AIToolCallEvent(id: callID, name: toolName, argumentSummary: summary,
                                                             status: isError ? .failed : .completed,
                                                             resultSummary: String(resultText.prefix(200)))))
                resultBlocks.append(.toolResult(toolUseID: callID, content: resultText, isError: isError))
            }
            wire.append(.init(role: "user", content: .blocks(resultBlocks)))
        }

        // Iteration cap hit without a terminal answer — one final, tool-free
        // request so the model summarizes rather than leaving the turn hanging.
        wire = try AIContextBudget.compact(wire, model: config.model, system: system, tools: nil)
        let body = AnthropicRequest(model: config.model, system: system.isEmpty ? nil : system,
                                    messages: wire, maxTokens: 4096)
        let response: AnthropicResponse = try await post(path: "/messages", body: body)
        continuation.yield(.completed(response.textContent))
    }

    static let perToolTimeout: TimeInterval = 20

    private static func executeTool(executor: AIToolExecutor, name: String, arguments: [String: Any]) async -> (String, Bool) {
        do {
            let result = try await withTimeout(seconds: perToolTimeout) {
                try await MainActor.run { try executor.execute(tool: name, arguments: arguments) }
            }
            return (result, false)
        } catch is TimeoutError {
            return ("Tool '\(name)' timed out after \(Int(perToolTimeout))s.", true)
        } catch {
            return ("Tool '\(name)' failed: \(error.localizedDescription)", true)
        }
    }

    /// Short human-readable summary of a tool call's arguments, for the
    /// live tool-call timeline (mirrors the earlier project's tool-schema
    /// argument summary).
    private static func argumentSummary(tool: String, arguments: [String: Any]) -> String {
        switch tool {
        case "read_drawing":
            return (arguments["space"] as? String) ?? "active view"
        case "get_insert_attributes":
            return "entity \(arguments["insertEntityId"] ?? "?")"
        case "find_insert_at_point":
            return "(\(arguments["x"] ?? "?"), \(arguments["y"] ?? "?"))"
        case "propose_attribute_edits":
            let count = (arguments["edits"] as? [String])?.count ?? 0
            return "\(count) edit(s)"
        default:
            return ""
        }
    }

    // MARK: - Model discovery

    func listModels() async throws -> [String] {
        if config.provider == .opencode {
            return try await OpenCodeCLIClient().listModels(config: config)
        }
        let path = config.provider == .anthropic ? "/models" : "/models"
        let response: ModelsResponse = try await get(path: path)
        return (response.data ?? []).map(\.id)
    }

    // MARK: - HTTP core

    private func post<Body: Encodable, T: Decodable>(path: String, body: Body) async throws -> T {
        guard let url = URL(string: joinedURL(base: config.baseURL, path: path)) else {
            throw AIClientError.notConfigured("Invalid base URL: \(config.baseURL)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        guard (request.httpBody?.count ?? 0) <= AIContextBudget.requestBytes else {
            throw AIClientError.transport("This request is too large to send. Narrow the question; your conversation has been kept.")
        }
        try applyAuth(&request)
        return try await send(request)
    }

    private func get<T: Decodable>(path: String) async throws -> T {
        guard let url = URL(string: joinedURL(base: config.baseURL, path: path)) else {
            throw AIClientError.notConfigured("Invalid base URL: \(config.baseURL)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        try applyAuth(&request)
        return try await send(request)
    }

    private func applyAuth(_ request: inout URLRequest) throws {
        switch config.provider {
        case .anthropic:
            guard let key = config.apiKey, !key.isEmpty else {
                throw AIClientError.notConfigured("An API key is required.")
            }
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        case .openAICompatible:
            guard let key = config.apiKey, !key.isEmpty else {
                throw AIClientError.notConfigured("An API key is required.")
            }
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        case .opencode, .opencodeServer:
            break   // opencode handles its own provider auth outside this client
        }
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AIClientError.transport("No HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            let message = Self.errorMessage(from: data, status: http.statusCode)
            if http.statusCode == 401 || http.statusCode == 403 { throw AIClientError.unauthorized(message) }
            throw AIClientError.api(code: http.statusCode, message: message)
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw AIClientError.decoding(error.localizedDescription)
        }
    }

    private func joinedURL(base: String, path: String) -> String {
        let trimmedBase = base.hasSuffix("/") ? String(base.dropLast()) : base
        let trimmedPath = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return "\(trimmedBase)/\(trimmedPath)"
    }

    static func errorMessage(from data: Data, status: Int) -> String {
        if let decoded = try? JSONDecoder().decode(ErrorEnvelope.self, from: data) {
            if let detail = decoded.detail?.stringValue, !detail.isEmpty { return detail }
            if let message = decoded.error?.message, !message.isEmpty { return message }
        }
        if let text = String(data: data, encoding: .utf8), !text.isEmpty { return text }
        return "HTTP \(status)"
    }
}

// MARK: - Wire formats (OpenAI-compatible)

private struct OpenAIRequest: Encodable {
    var model: String
    var messages: [Message]
    var temperature: Double
    var maxTokens: Int
    struct Message: Encodable { var role: String; var content: String }
    enum CodingKeys: String, CodingKey { case model, messages, temperature; case maxTokens = "max_tokens" }
}

private struct OpenAIResponse: Decodable {
    var choices: [Choice]?
    struct Choice: Decodable { var message: Message? }
    struct Message: Decodable { var role: String?; var content: String? }
}

// MARK: - Wire formats (Anthropic-native)

struct AnthropicRequest: Encodable {
    var model: String
    var system: String?
    var messages: [Message]
    var maxTokens: Int
    var tools: [AIToolSchema.Tool]?

    init(model: String, system: String?, messages: [Message], maxTokens: Int, tools: [AIToolSchema.Tool]? = nil) {
        self.model = model; self.system = system; self.messages = messages
        self.maxTokens = maxTokens; self.tools = tools
    }

    struct Message: Encodable {
        var role: String
        var content: Content

        enum Content: Encodable {
            case text(String)
            case blocks([Block])
            func encode(to encoder: Encoder) throws {
                var container = encoder.singleValueContainer()
                switch self {
                case .text(let s): try container.encode(s)
                case .blocks(let b): try container.encode(b)
                }
            }
        }

        struct Block: Encodable {
            var type: String
            var text: String?
            var thinking: String?
            var signature: String?
            var data: String?
            var id: String?
            var name: String?
            var input: AIAnyEncodable?
            var toolUseID: String?
            var content: String?
            var isError: Bool?

            enum CodingKeys: String, CodingKey {
                case type, text, thinking, signature, data, id, name, input, content
                case toolUseID = "tool_use_id"
                case isError = "is_error"
            }

            static func text(_ value: String) -> Block { Block(type: "text", text: value) }
            static func thinking(_ value: String, signature: String?) -> Block {
                Block(type: "thinking", thinking: value, signature: signature)
            }
            static func redactedThinking(data: String) -> Block { Block(type: "redacted_thinking", data: data) }
            static func toolUse(id: String, name: String, input: AIAnyEncodable?) -> Block {
                Block(type: "tool_use", id: id, name: name, input: input)
            }
            static func toolResult(toolUseID: String, content: String, isError: Bool = false) -> Block {
                Block(type: "tool_result", toolUseID: toolUseID, content: content, isError: isError ? true : nil)
            }
        }
    }

    enum CodingKeys: String, CodingKey { case model, system, messages, tools; case maxTokens = "max_tokens" }
}

/// Type-erased `Encodable` wrapper so a `tool_use` block's `input` can be
/// re-encoded verbatim when echoing an assistant turn back to Anthropic.
struct AIAnyEncodable: Encodable {
    private let encodeFunc: (Encoder) throws -> Void
    init(json: Any) { encodeFunc = { encoder in try Self.encodeJSON(json, to: encoder) } }
    func encode(to encoder: Encoder) throws { try encodeFunc(encoder) }

    private static func encodeJSON(_ value: Any, to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let dict as [String: Any]: try container.encode(dict.mapValues { AIAnyCodableValue($0) })
        case let array as [Any]: try container.encode(array.map { AIAnyCodableValue($0) })
        case let string as String: try container.encode(string)
        case let bool as Bool: try container.encode(bool)
        case let int as Int: try container.encode(int)
        case let double as Double: try container.encode(double)
        default: try container.encodeNil()
        }
    }
}

private struct AIAnyCodableValue: Encodable {
    let value: Any
    init(_ value: Any) { self.value = value }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let dict as [String: Any]: try container.encode(dict.mapValues { AIAnyCodableValue($0) })
        case let array as [Any]: try container.encode(array.map { AIAnyCodableValue($0) })
        case let string as String: try container.encode(string)
        case let bool as Bool: try container.encode(bool)
        case let int as Int: try container.encode(int)
        case let double as Double: try container.encode(double)
        default: try container.encodeNil()
        }
    }
}

struct AnthropicResponse: Decodable {
    var content: [Block]?
    var stopReason: String?
    enum CodingKeys: String, CodingKey { case content; case stopReason = "stop_reason" }

    struct Block: Decodable {
        var type: String?
        var text: String?
        var thinking: String?
        var signature: String?
        var data: String?
        var id: String?
        var name: String?
        var input: [String: AIJSONValue]?
    }

    var textContent: String {
        (content ?? []).compactMap { $0.type == "text" ? $0.text : nil }.joined()
    }
    var toolUseBlocks: [Block] { (content ?? []).filter { $0.type == "tool_use" } }
    var wantsToolUse: Bool { stopReason == "tool_use" || !toolUseBlocks.isEmpty }

    var echoedAssistantBlocks: [AnthropicRequest.Message.Block] {
        (content ?? []).compactMap { block -> AnthropicRequest.Message.Block? in
            switch block.type {
            case "thinking":
                guard let thinking = block.thinking else { return nil }
                return .thinking(thinking, signature: block.signature)
            case "redacted_thinking":
                guard let data = block.data else { return nil }
                return .redactedThinking(data: data)
            case "text":
                guard let text = block.text, !text.isEmpty else { return nil }
                return .text(text)
            case "tool_use":
                let inputAny = (block.input ?? [:]).mapValues { $0.anyValue }
                return .toolUse(id: block.id ?? UUID().uuidString, name: block.name ?? "",
                                input: AIAnyEncodable(json: inputAny))
            default:
                return nil
            }
        }
    }
}

enum AIJSONValue: Decodable {
    case string(String), number(Double), bool(Bool), object([String: AIJSONValue]), array([AIJSONValue]), null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let b = try? container.decode(Bool.self) { self = .bool(b) }
        else if let d = try? container.decode(Double.self) { self = .number(d) }
        else if let s = try? container.decode(String.self) { self = .string(s) }
        else if let o = try? container.decode([String: AIJSONValue].self) { self = .object(o) }
        else if let a = try? container.decode([AIJSONValue].self) { self = .array(a) }
        else { self = .null }
    }

    var anyValue: Any {
        switch self {
        case .string(let s): return s
        case .number(let n): return n
        case .bool(let b): return b
        case .object(let o): return o.mapValues { $0.anyValue }
        case .array(let a): return a.map { $0.anyValue }
        case .null: return NSNull()
        }
    }
}

private struct ModelsResponse: Decodable {
    var data: [ModelItem]?
    struct ModelItem: Decodable { var id: String }
}

private struct ErrorEnvelope: Decodable {
    var detail: DetailValue?
    var error: ErrorBody?
    struct ErrorBody: Decodable { var message: String? }
    enum DetailValue: Decodable {
        case string(String), other
        var stringValue: String? { if case .string(let s) = self { return s }; return nil }
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let s = try? container.decode(String.self) { self = .string(s) } else { self = .other }
        }
    }
}

enum AIClientError: LocalizedError {
    case notConfigured(String)
    case unauthorized(String)
    case api(code: Int, message: String)
    case transport(String)
    case decoding(String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured(let m): return "AI assistant not configured: \(m)"
        case .unauthorized(let m): return "AI authentication failed: \(m)"
        case .api(let code, let m): return "AI service error (\(code)): \(m)"
        case .transport(let m): return "AI network error: \(m)"
        case .decoding(let m): return "Failed to parse AI response: \(m)"
        case .emptyResponse: return "The AI service returned an empty response."
        }
    }
}

/// Error thrown when an operation exceeds its allotted time budget — mirrors
/// the earlier project's timeout error.
struct TimeoutError: LocalizedError {
    let seconds: TimeInterval
    var errorDescription: String? { "The operation timed out after \(Int(seconds))s." }
}

/// Runs `operation` with a hard wall-clock timeout — mirrors the earlier
/// project's timeout helper.
func withTimeout<T: Sendable>(seconds: TimeInterval, operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TimeoutError(seconds: seconds)
        }
        guard let result = try await group.next() else { throw TimeoutError(seconds: seconds) }
        group.cancelAll()
        return result
    }
}
