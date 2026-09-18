import Foundation
import Network

/// A tiny in-process HTTP server bound to loopback that executes NovaCAD
/// tool calls for the OpenCode agent. The generated `.opencode/tools/*.ts`
/// forwarders POST to `http://127.0.0.1:<port>/tool/<name>`; this server
/// decodes the request, routes it through `NovaCADToolRouter` to an
/// `AIToolExecutor`, and returns the tool's string result as the HTTP body.
/// Direct port of the earlier internal project's tool bridge per the porting
/// guide.
///
/// Why a real socket instead of some IPC trick: OpenCode custom tools run in
/// a separate Bun/Node process, so the only reliable contract between them
/// and NovaCAD is HTTP over loopback. This mirrors how `opencode serve`
/// itself is driven — a local HTTP surface — keeping the whole agentic path
/// consistent.
///
/// Security: bound to `127.0.0.1` only (never a routable interface), and the
/// path space is limited to the fixed `/tool/<known-name>` routes. It
/// carries a per-launch shared secret in the `X-NovaCAD-Bridge-Token` header
/// that the generated forwarders echo, so other local processes can't drive
/// NovaCAD's drawing-editing tools even though the port is loopback-visible.
actor NovaCADToolBridge {
    private var router: NovaCADToolRouter
    private let token: String
    private var listener: NWListener?
    private var port: Int = 0

    /// Serializes access to `NWConnection` receive/state callbacks, which
    /// fire on a private queue.
    private let queue = DispatchQueue(label: "com.novacad.toolbridge")

    init(executor: AIToolExecutor, token: String = UUID().uuidString) {
        self.router = NovaCADToolRouter(executor: executor)
        self.token = token
    }

    /// The port the bridge is listening on (0 until `start()` succeeds).
    var boundPort: Int { port }
    /// The shared secret forwarders must present.
    var sharedToken: String { token }

    /// Rebinds the long-lived bridge to the current document/visibility
    /// snapshot before each turn, so tools never enumerate a stale drawing.
    func updateExecutor(_ executor: AIToolExecutor) {
        router = NovaCADToolRouter(executor: executor)
    }

    // MARK: - Lifecycle

    /// Starts listening on a free loopback port and returns it. Idempotent:
    /// if already started, returns the current port.
    @discardableResult
    func start() async throws -> Int {
        if let listener, listener.state == .ready { return port }

        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        // CRITICAL (invariant #3): force the listener onto IPv4 loopback
        // (127.0.0.1). The generated `.opencode/tools/*.ts` forwarders
        // `fetch` the bridge at the literal IPv4 address
        // `http://127.0.0.1:<port>`. By default an `NWListener` binds
        // IPv6-only (`lsof` shows `IPv6 TCP *:<port>`), so a fetch to
        // `127.0.0.1` — which Node/Bun resolves strictly to IPv4 and does
        // NOT fall back to `[::1]` — can never connect. Every tool call
        // then hangs waiting on a dead socket, the opencode turn never
        // completes, and the assistant appears stuck at "Starting… 10%".
        if let localEndpoint = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            localEndpoint.version = .v4
        }
        let newListener = try NWListener(using: params)

        let readyPort: UInt16 = try await withCheckedThrowingContinuation { continuation in
            // `stateUpdateHandler` fires on `queue`, a background serial
            // queue, so the "have we already resumed" flag must be
            // protected by a lock rather than a plain captured `var`.
            let resumed = ResumeGuard()
            newListener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if let p = newListener.port?.rawValue, resumed.markResumed() {
                        continuation.resume(returning: p)
                    }
                case .failed(let error):
                    if resumed.markResumed() {
                        continuation.resume(throwing: error)
                    }
                default:
                    break
                }
            }
            newListener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                connection.start(queue: self.queue)
                self.receive(on: connection)
            }
            newListener.start(queue: queue)
        }

        listener = newListener
        port = Int(readyPort)
        return port
    }

    /// Stops the server.
    func stop() {
        listener?.cancel()
        listener = nil
        port = 0
    }

    deinit {
        listener?.cancel()
    }

    // MARK: - Connection handling

    /// Reads a full HTTP request off the connection (accumulating across
    /// multiple TCP reads, since headers + a JSON body routinely arrive in
    /// separate packets over loopback), then processes it and writes the
    /// response. Connections are one-request (no keep-alive) for simplicity;
    /// the forwarders open a fresh fetch per tool call anyway.
    private nonisolated func receive(on connection: NWConnection, buffered: Data = Data()) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var accumulated = buffered
            if let data, !data.isEmpty { accumulated.append(data) }

            switch Self.requestCompleteness(of: accumulated) {
            case .complete:
                Task { await self.process(data: accumulated, on: connection) }
            case .incomplete:
                if isComplete || error != nil {
                    connection.cancel()
                } else {
                    self.receive(on: connection, buffered: accumulated)
                }
            case .malformed:
                Self.write(status: 400, body: "Bad Request", to: connection)
            }
        }
    }

    /// Whether `data` contains a full HTTP request (headers + declared body
    /// length, if any) yet, so `receive` knows whether to keep reading.
    private nonisolated static func requestCompleteness(of data: Data) -> RequestCompleteness {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > (64 * 1024) ? .malformed : .incomplete
        }
        guard let headerText = String(data: data.subdata(in: data.startIndex..<headerEnd.lowerBound), encoding: .utf8) else {
            return .malformed
        }
        let contentLength = headerText
            .components(separatedBy: "\r\n")
            .compactMap { line -> Int? in
                let parts = line.split(separator: ":", maxSplits: 1)
                guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" else { return nil }
                return Int(parts[1].trimmingCharacters(in: .whitespaces))
            }
            .first ?? 0
        let bodySoFar = data.distance(from: headerEnd.upperBound, to: data.endIndex)
        return bodySoFar >= contentLength ? .complete : .incomplete
    }

    private enum RequestCompleteness { case complete, incomplete, malformed }

    /// Parses the raw request, routes it, and writes an HTTP response.
    private func process(data: Data, on connection: NWConnection) async {
        guard let request = NovaCADHTTPRequest(raw: data) else {
            Self.write(status: 400, body: "Bad Request", to: connection)
            return
        }

        // Auth: the shared token must match (skip only for a health probe).
        if request.path == "/health" {
            Self.write(status: 200, body: "ok", to: connection)
            return
        }
        guard request.header("x-novacad-bridge-token") == token else {
            Self.write(status: 401, body: "Unauthorized", to: connection)
            return
        }

        // Route: POST /tool/<name>
        guard request.method == "POST", request.path.hasPrefix("/tool/") else {
            Self.write(status: 404, body: "Not Found", to: connection)
            return
        }
        let toolName = String(request.path.dropFirst("/tool/".count))

        do {
            // Bounded so one wedged tool can't hold the turn (and the main
            // actor) forever — see `NovaCADToolRouter.toolTimeout`.
            let router = self.router
            let result = try await withTimeout(seconds: NovaCADToolRouter.toolTimeout) {
                try await router.handle(tool: toolName, body: request.body)
            }
            Self.write(status: 200, body: result, to: connection)
        } catch is TimeoutError {
            Self.write(status: 422,
                       body: "NovaCAD tool '\(toolName)' timed out after \(Int(NovaCADToolRouter.toolTimeout))s. "
                           + "If this was a whole-drawing operation, narrow it (filter by layer, or use "
                           + "query_entities with offset/limit to work in pages) and try again.",
                       to: connection)
        } catch {
            // Return 422 with the message; the forwarder relays it to the
            // agent so the model can see and recover from the failure.
            Self.write(status: 422, body: error.localizedDescription, to: connection)
        }
    }

    // MARK: - Response writing

    private static func write(status: Int, body: String, to connection: NWConnection) {
        let bodyData = Data(body.utf8)
        let statusText = status == 200 ? "OK" : (status == 404 ? "Not Found" : "Error")
        var response = "HTTP/1.1 \(status) \(statusText)\r\n"
        response += "Content-Type: text/plain; charset=utf-8\r\n"
        response += "Content-Length: \(bodyData.count)\r\n"
        response += "Connection: close\r\n\r\n"
        var payload = Data(response.utf8)
        payload.append(bodyData)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

/// Decodes a tool request body + dispatches to `AIToolExecutor.execute`.
/// Pulled out of the HTTP server so the routing/argument-decoding logic can
/// be reasoned about independently of the socket layer — mirrors the earlier
/// project's tool-router split, simplified since NovaCAD's tool catalog
/// is small enough that `AIToolExecutor.execute(tool:arguments:)` already
/// does its own per-tool argument decoding (see that method) rather than
/// needing a second layer of per-argument helpers here.
struct NovaCADToolRouter: Sendable {
    let executor: AIToolExecutor

    /// Known tool names — must stay in sync with `NovaCADToolInstaller.tools`
    /// and `AIToolSchema.tools`.
    static let knownTools: Set<String> = [
        "read_drawing", "list_inserts_on_layer", "export_csv",
        "get_insert_attributes", "find_insert_at_point", "propose_attribute_edits",
        "bulk_set_attribute_on_layer",
        "analyze_aisle_network", "repair_aisle_network", "find_route_endpoints",
        "route_along_aisles", "export_travel_distances",
        "shade_aisle_network", "shade_dock_aprons",
        "get_selected_objects", "draw_polylines", "query_entities", "inspect_xrefs"
    ]

    /// Routes a tool call by name, decoding `body` (JSON object) for
    /// arguments, and returns the tool's string result. `AIToolExecutor` is
    /// `@MainActor` (it reads/writes live `RegenCoordinator`/document state),
    /// so this hops to the main actor to call it — safe and cheap for a
    /// single tool invocation despite running from the bridge's background
    /// connection-handling queue.
    func handle(tool: String, body: Data) async throws -> String {
        guard Self.knownTools.contains(tool) else {
            throw NovaCADToolError.unknownTool(tool)
        }
        let args = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
        // `propose_attribute_edits` expects its `edits` argument as an array
        // of JSON-encoded strings (see `AIToolSchema`'s own doc comment on
        // that tool) — but the Zod-declared forwarder for this tool (see
        // `NovaCADToolInstaller.tools`) sends `edits` as a single JSON
        // string (a serialized array of edit objects), matching how a
        // Zod `str(...)` argument naturally round-trips through opencode.
        // Normalize that shape here so `AIToolExecutor.execute` (shared with
        // the Anthropic tool loop, which already sends `edits` as
        // `[String]`) sees the SAME argument shape regardless of which
        // backend is calling it.
        var normalizedArgs = args
        if tool == "propose_attribute_edits", let editsString = args["edits"] as? String {
            if let data = editsString.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [Any] {
                // Each element re-encoded back to its own JSON string, since
                // that's the per-edit shape `AIToolExecutor.execute` expects.
                normalizedArgs["edits"] = parsed.compactMap { element -> String? in
                    guard let elementData = try? JSONSerialization.data(withJSONObject: element) else { return nil }
                    return String(data: elementData, encoding: .utf8)
                }
            } else {
                // Already a single edit object's JSON, or malformed — pass
                // through as a one-element array so `execute` at least gets
                // a chance to parse it (and reports a clean per-edit error
                // if it can't, rather than this layer swallowing it).
                normalizedArgs["edits"] = [editsString]
            }
        }
        let finalArgs = normalizedArgs
        return try await MainActor.run {
            try executor.execute(tool: tool, arguments: finalArgs)
        }
    }

    /// Ceiling on one tool's execution.
    ///
    /// The Anthropic path has always had `AIClient.perToolTimeout`, but THIS
    /// path (the agentic OpenCode backend, which is the default) had none: a
    /// tool that wedged blocked the main actor indefinitely, and the only
    /// thing that eventually ended the turn was the client's 150s idle
    /// watchdog — by which point the UI had been frozen the whole time.
    /// Deliberately generous, because legitimate batch work on a
    /// multi-hundred-megabyte plant layout (enumerating thousands of
    /// workstations and routing each one) genuinely takes tens of seconds.
    static let toolTimeout: TimeInterval = 120
}

enum NovaCADToolError: LocalizedError {
    case unknownTool(String)

    var errorDescription: String? {
        switch self {
        case .unknownTool(let name): return "Unknown NovaCAD tool '\(name)'."
        }
    }
}

/// A tiny lock-protected one-shot flag used to guard a `CheckedContinuation`
/// against being resumed twice when it can be reached from multiple
/// `NWListener.stateUpdateHandler` callbacks running on a background queue.
private final class ResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false

    func markResumed() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !didResume else { return false }
        didResume = true
        return true
    }
}

/// A minimal HTTP/1.1 request parser — just enough for the loopback tool
/// bridge (method, path, headers, body). Not a general-purpose HTTP
/// implementation. Named distinctly from the earlier project's `HTTPRequest`
/// in case both files are ever compiled into the same module.
struct NovaCADHTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    init?(raw: Data) {
        guard let separator = raw.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = raw.subdata(in: raw.startIndex..<separator.lowerBound)
        let bodyData = raw.subdata(in: separator.upperBound..<raw.endIndex)
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }

        self.method = String(parts[0]).uppercased()
        self.path = String(parts[1])

        var parsed: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            parsed[key] = value
        }
        self.headers = parsed
        self.body = bodyData
    }

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }
}
