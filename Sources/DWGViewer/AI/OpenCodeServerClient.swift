import Foundation

// MARK: - OpenCode (agentic) backend — ported from an earlier internal project
//
// This file is a faithful port of that project's OpenCode server client, per
// `Resources/Specs/AI_ASSISTANT_PORTING_GUIDE.md` §3 ("Core engine — copy
// mostly as-is") and its 14 numbered invariants (§8) — the distilled fixes
// from a long "assistant stuck at 10% / spins forever / message disappeared"
// debugging saga there. Every one of those invariants is preserved here
// VERBATIM (same `nonisolated` HTTP helpers, same URLSession config, same
// SSE-consumption state machine, same idle watchdog / completion-polling
// logic) — only the message/event/tool-call TYPES differ, swapped for
// NovaCAD's own `AIMessage`/`AIStreamEvent`/`AIToolCallEvent`/
// `AIPermissionRequest` (see `AIClient.swift`) instead of that project's
// equivalents.
//
// Deliberately NOT ported: that project's AI-gateway-environment provider-
// config writing (`writeProviderConfig`'s provider-specific block,
// `noteEnvironmentChanged`) — NovaCAD has no equivalent internal gateway to
// switch between dev/prod environments for. Model selection instead happens
// per-request via `AIConfig.model` (a plain `"provider/model"` string, e.g.
// `"example/model"`), exactly the same mechanism the earlier project ALSO
// already uses per-request (`providerModel(from:)` in `postPromptAsync`) —
// so nothing is lost, only the extra gateway-specific environment-switch
// layer on top of it. `opencode.json` is still written (this file's
// `writeToolsConfig`) to disable opencode's built-in coding tools (invariant
// #14), just without a provider-specific `baseURL` override.
//
// Drives the local `opencode` binary as a managed HTTP server (`opencode
// serve`) and talks to its OpenAPI/SSE surface: durable sessions, streamed
// responses (text deltas + tool-call steps), and round-tripped tool calls
// that NovaCAD executes via `NovaCADToolBridge`/`AIToolExecutor` and can gate
// with permissions (not currently used by any NovaCAD tool — see
// `AIStreamEvent.permissionRequest`'s own doc comment).
actor OpenCodeServerClient {
    private static let candidateBinaryPaths = [
        "/usr/local/bin/opencode",
        "/opt/homebrew/bin/opencode",
        "/usr/bin/opencode"
    ]
    /// How long to wait for `opencode serve`'s `/global/health` endpoint to
    /// report healthy after spawning the process. 45s gives slower machines/
    /// cold npm caches enough headroom; combined with eager
    /// `AIAssistantSession.warmUpServer()` (called when the AI panel
    /// appears, well before the user's first message), this cost is usually
    /// paid in the background rather than blocking a real chat turn.
    private static let startupTimeout: TimeInterval = 45
    private static let requestTimeout: TimeInterval = 300

    /// Test-facing mirror of `startupTimeout`. `AIAssistantSession` bounds a
    /// turn's server ACQUISITION separately, and that bound must stay ABOVE
    /// this startup budget (see `OpenCodeServerStartupTests`).
    static var startupTimeoutForTesting: TimeInterval { startupTimeout }
    /// Custom URLSession configured with extended timeouts so transient
    /// network glitches (e.g. macOS App Nap, brief sleep) don't kill the SSE
    /// stream or prompt POST.
    private nonisolated static let session: URLSession = {
        // Use `.ephemeral` and DISABLE `waitsForConnectivity`.
        //
        // ROOT-CAUSE FIX for "assistant stuck at 10% / server never becomes
        // healthy" (invariant #2): this client only ever talks to
        // `http://127.0.0.1:<port>` (the local `opencode serve`). With
        // `waitsForConnectivity = true` on a `.default` session, URLSession
        // consults the system connectivity/route monitor before dialing —
        // and under a VPN/proxy that monitor can decide there is
        // "no satisfactory connectivity" and then WAIT (up to
        // `timeoutIntervalForResource`) instead of just attempting the
        // loopback connection. The very first `waitForHealth` GET then hangs
        // indefinitely, never connecting and never timing out. Loopback is
        // always reachable, so waiting on the connectivity monitor is never
        // correct here; turning it off makes the request dial 127.0.0.1
        // immediately. `.ephemeral` also avoids inheriting shared
        // cookie/cache/proxy state.
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = requestTimeout
        cfg.timeoutIntervalForResource = requestTimeout
        cfg.waitsForConnectivity = false
        // Never route loopback traffic through a configured HTTP/S proxy.
        cfg.connectionProxyDictionary = [:]
        return URLSession(configuration: cfg)
    }()

    /// Idle watchdog: if no relevant event arrives for our session within this
    /// window after the last activity, the turn is considered complete.
    private static let idleTurnTimeout: TimeInterval = 90

    /// Running server handle, lazily started on first use and reused thereafter.
    private var server: ServerHandle? {
        didSet { Self.managedPID.set(server?.process.processIdentifier) }
    }

    /// The in-flight server-startup task, if one is currently running.
    ///
    /// **Invariant #6: self-clears, not via a caller's `defer`.** `ensureServer`
    /// `await`s twice (`resolveBinary`, then `startServer`'s ~5-45s health
    /// wait) before ever assigning `self.server`. Because this type is an
    /// `actor`, those `await`s each release exclusive access — so if a SECOND
    /// caller invokes `ensureServer` while the first is still mid-startup, it
    /// ALSO sees `server == nil` and spawns its OWN competing `opencode serve`
    /// process. Both processes then race to become healthy on separate ports;
    /// whichever loses hits `waitForHealth`'s deadline and throws
    /// `startupTimedOut` — even though a server WOULD have come up fine if
    /// only one had been started.
    ///
    /// The fix: the FIRST caller records its startup `Task` here; any
    /// concurrent caller that arrives while it's set simply `await`s that
    /// SAME task's result instead of starting its own process. The startup
    /// Task CLEARS this itself (via `finishStartup`), not via a `defer` on the
    /// first caller's stack — otherwise a caller cancelled by a
    /// `withTimeout` (Test Connection, or the chat turn watchdog) could
    /// strand a live task that every later caller `await`s forever.
    private var inFlightStartup: Task<ServerHandle, Error>?

    /// Test-only instrumentation: counts how many times `ensureServer` actually
    /// attempted to resolve+start a server (as opposed to joining an in-flight
    /// attempt or reusing a live one). `internal` (not `private`) so tests can
    /// assert concurrent callers collapse into ONE attempt rather than racing.
    private(set) var startAttemptCountForTesting = 0

    /// Whether the *currently running* server was started after NovaCAD's
    /// tool forwarders were installed. opencode scans `.opencode/tools/` and
    /// builds its tool registry ONCE at server bootstrap — it does not
    /// rescan per turn. So a server that started before the forwarders were
    /// written will never expose the NovaCAD tools, no matter how many turns
    /// run. When the forwarders are (re)installed we flip this to false so
    /// the next turn restarts the server, forcing a fresh scan that picks
    /// them up.
    private var serverHasCurrentTools = false

    // MARK: - Lifecycle

    /// Ensures a server is running for this config, returning its handle.
    /// Idempotent: subsequent calls reuse the live server. Concurrency-safe
    /// per invariant #6 above.
    private func ensureServer(config: AIConfig) async throws -> ServerHandle {
        // `opencode.json` (which built-in tools are disabled) is read by the
        // server ONCE at bootstrap, and the server outlives individual turns.
        // So a config change — e.g. newly disabling the interactive
        // `question` tool that used to hang every clarifying turn — would
        // otherwise not take effect until the process happened to restart for
        // some unrelated reason. Refresh it here and terminate a live server
        // whose config is now stale, so the fix applies on the very next turn
        // rather than mysteriously "not working" for a whole session.
        if Self.refreshToolsConfigIfChanged(), let server, server.isAlive {
            server.process.terminate()
            self.server = nil
            conversationSessionID = nil
        }
        if let server, server.isAlive { return server }

        if let inFlightStartup {
            return try await inFlightStartup.value
        }

        startAttemptCountForTesting += 1
        let startupTask = Task<ServerHandle, Error> { [weak self] in
            guard let self else { throw OpenCodeServerError.launchFailed("client deallocated") }
            do {
                let binary = try await self.resolveBinary(override: config.opencodeBinaryPath)
                let handle = try await self.startServer(binary: binary, config: config)
                await self.finishStartup(with: handle, error: nil)
                return handle
            } catch {
                await self.finishStartup(with: nil, error: error)
                throw error
            }
        }
        inFlightStartup = startupTask
        return try await startupTask.value
    }

    /// Called by the startup Task when it finishes (success or failure) to
    /// record the live server and clear the in-flight reference.
    private func finishStartup(with handle: ServerHandle?, error: Error?) {
        if let handle { server = handle }
        inFlightStartup = nil
    }

    /// Signals that the NovaCAD tool forwarders have just been (re)installed
    /// on disk. If a server is already running, it was bootstrapped *before*
    /// these tools existed and will not expose them, so we terminate it — the
    /// next `ensureServer` starts a fresh process that scans the current
    /// `.opencode/tools/` at bootstrap. Called by `AIAssistantSession`'s
    /// `prepareToolBridge()` right after `NovaCADToolInstaller.install(...)`.
    ///
    /// `signature` lets callers avoid needless restarts: if the running
    /// server already reflects this exact toolset (port + token), it's a no-op.
    func noteToolsInstalled(signature: String) {
        if serverToolsSignature == signature, serverHasCurrentTools { return }
        serverToolsSignature = signature
        if let server, server.isAlive {
            server.process.terminate()
        }
        self.server = nil
        serverHasCurrentTools = true
        conversationSessionID = nil
    }

    /// The tool signature (bridge port + token) baked into the forwarders the
    /// running server was started with, so `noteToolsInstalled` can skip a
    /// redundant restart when nothing changed.
    private var serverToolsSignature: String?

    /// Signals that the NovaCAD tool forwarders were removed (tools
    /// disabled). If a server that had tools is live, restart it so it no
    /// longer offers them.
    func noteToolsUninstalled() {
        guard serverHasCurrentTools || serverToolsSignature != nil else { return }
        serverToolsSignature = nil
        serverHasCurrentTools = false
        if let server, server.isAlive {
            server.process.terminate()
        }
        self.server = nil
        conversationSessionID = nil
    }

    /// Starts `opencode serve` on a loopback port and waits until
    /// `/global/health` reports healthy.
    private func startServer(binary: String, config: AIConfig) async throws -> ServerHandle {
        let port = config.opencodeServerPort ?? Self.freeLoopbackPort()
        let password = Self.randomPassword()

        // Writes the workspace `opencode.json` (disabled built-in tools —
        // invariant #14) before launch; the server reads it at bootstrap.
        Self.writeToolsConfig()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["serve", "--hostname", "127.0.0.1", "--port", String(port)]
        process.currentDirectoryURL = OpenCodeWorkspace.directory
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Self.augmentedPath(env["PATH"])
        env["OPENCODE_SERVER_PASSWORD"] = password
        env["OPENCODE_SERVER_USERNAME"] = "novacad"
        process.environment = env
        // Discard the server's own stdout (it only carries the "listening
        // on ..." banner — leaving a Pipe open but unread would BLOCK the
        // child once the pipe buffer fills) and route stderr through a
        // bounded tail buffer while still draining it on a background queue. Two
        // reasons for the drain: a full stderr pipe would make the child die
        // on SIGPIPE during long agentic turns ("AI connection keeps
        // dropping"), and a crash-on-boot is otherwise indistinguishable
        // from a slow start — the tail buffer is what lets `waitForHealth`
        // report the server's own last words.
        let errPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errPipe
        let stderrTail = ProcessOutputTail()
        Self.drainStderr(errPipe.fileHandleForReading, into: stderrTail)

        do {
            try process.run()
        } catch {
            throw OpenCodeServerError.launchFailed(error.localizedDescription)
        }

        let handle = ServerHandle(process: process,
                                  baseURL: URL(string: "http://127.0.0.1:\(port)")!,
                                  username: "novacad",
                                  password: password,
                                  stderrTail: stderrTail)

        // Record a stable server identity so the conversation session id can
        // be persisted and restored across relaunches when connecting to the
        // SAME server binary + port combination.
        serverIdentity = "\(binary):\(port)"

        do {
            try await waitForHealth(handle)
        } catch {
            process.terminate()
            throw error
        }
        return handle
    }

    /// Terminates the managed server, if any.
    func shutdown() {
        server?.process.terminate()
        server = nil
    }

    /// Drains `handle` until EOF on a background queue, appending every chunk
    /// to `tail`. Returns immediately; the reading loop ends when the child
    /// exits and closes the pipe.
    private static func drainStderr(_ handle: FileHandle, into tail: ProcessOutputTail) {
        DispatchQueue.global(qos: .background).async {
            while autoreleasepool(invoking: {
                let chunk = handle.readData(ofLength: 4096)
                guard !chunk.isEmpty else { return false }
                tail.append(chunk)
                return true
            }) {}
        }
    }

    deinit {
        server?.process.terminate()
    }

    // MARK: - Orphan cleanup (connection reliability)
    //
    // NovaCAD spawns `opencode serve` as a plain child `Process()` with no
    // process-group/session binding to its parent, so macOS does NOT
    // propagate a SIGTERM to it when NovaCAD quits (`shutdown()` only runs on
    // a clean, in-process quit path). A force-quit, crash, or `kill -9` on
    // NovaCAD therefore reparents the `opencode serve` child to `launchd`
    // (PPID 1) and leaves it running forever. `sweepOrphanedServers()` is a
    // static, actor-independent best-effort cleanup: it finds any
    // `opencode serve --hostname 127.0.0.1` process whose parent is no longer
    // a live NovaCAD process (PPID 1) and terminates it. Called once at app
    // launch.
    private static let managedPID = PIDBox()

    private final class PIDBox: @unchecked Sendable {
        private let lock = NSLock()
        private var pid: Int32?
        func set(_ newPID: Int32?) {
            lock.lock(); defer { lock.unlock() }
            pid = newPID
        }
        func get() -> Int32? {
            lock.lock(); defer { lock.unlock() }
            return pid
        }
    }

    /// A bounded, thread-safe buffer holding the most recent bytes written to
    /// a child process's stderr. Popped by `waitForHealth` when `opencode
    /// serve` dies before becoming healthy, so the user sees the server's own
    /// error (bad plugin, invalid config, port collision, …) rather than a
    /// generic "took too long to start".
    final class ProcessOutputTail: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private let limit: Int

        init(limit: Int = 8_192) { self.limit = limit }

        func append(_ chunk: Data) {
            guard !chunk.isEmpty else { return }
            lock.lock(); defer { lock.unlock() }
            data.append(chunk)
            if data.count > limit { data.removeFirst(data.count - limit) }
        }

        func tailString() -> String {
            lock.lock(); defer { lock.unlock() }
            // `String(decoding:as:)` replaces a torn multibyte sequence at
            // the truncation boundary with U+FFFD; `String(data:encoding:)`
            // would instead return nil (→ empty diagnostics) for the WHOLE
            // tail exactly when the buffer is fullest.
            return String(decoding: data, as: UTF8.self)
        }
    }

    /// Synchronously sends SIGTERM to the currently-managed `opencode serve`
    /// process, if any. Safe to call from `NSApplicationDelegate
    /// .applicationWillTerminate(_:)`, which does not reliably support
    /// `await`ing actor-isolated cleanup before the process exits.
    static func terminateManagedServerProcessSynchronously() {
        guard let pid = managedPID.get() else { return }
        Foundation.kill(pid, SIGTERM)
    }

    static func sweepOrphanedServers() {
        let listTask = Process()
        listTask.executableURL = URL(fileURLWithPath: "/bin/ps")
        listTask.arguments = ["-axo", "pid=,ppid=,command="]
        let pipe = Pipe()
        listTask.standardOutput = pipe
        listTask.standardError = Pipe()
        do {
            try listTask.run()
        } catch {
            return
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        listTask.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8) else { return }

        for pid in Self.orphanedServerPIDs(fromPSOutput: output) {
            Foundation.kill(pid, SIGTERM)
        }
    }

    /// Pure parsing step for `sweepOrphanedServers()`, split out so it's
    /// unit-testable without spawning a real `ps` process. Given raw
    /// `ps -axo pid=,ppid=,command=` output, returns the PIDs of every
    /// `opencode serve --hostname 127.0.0.1 ...` process whose parent is `1`
    /// (launchd) — i.e. reparented orphans.
    nonisolated static func orphanedServerPIDs(fromPSOutput output: String) -> [Int32] {
        var pids: [Int32] = []
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.contains("opencode serve"), trimmed.contains("--hostname 127.0.0.1") else { continue }
            let fields = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3,
                  let pid = Int32(fields[0]),
                  let ppid = Int32(fields[1]) else { continue }
            guard ppid == 1 else { continue }
            pids.append(pid)
        }
        return pids
    }

    // MARK: - Public API (text-in/text-out compatibility)

    /// Runs one turn and returns the final assistant text, matching the shape
    /// of the other backends. Internally drains a streamed turn.
    func complete(messages: [AIMessage], config: AIConfig) async throws -> String {
        var finalText = ""
        let stream = try await sendStreaming(messages: messages, config: config)
        for try await event in stream {
            switch event {
            case .textDelta(let delta): finalText += delta
            case .textSnapshot(let text): finalText = text
            case .completed(let text): finalText = text
            case .failed(let message): throw OpenCodeServerError.turnFailed(message)
            default: break
            }
        }
        guard !finalText.isEmpty else { throw OpenCodeServerError.emptyResponse }
        return finalText
    }

    /// Verifies the server + selected model + auth by round-tripping a
    /// trivial prompt, with **all NovaCAD tools disabled for this turn**.
    /// This is what AI Settings' "Test Connection" button uses.
    ///
    /// Why tools must be off here: a connection probe runs *without* bringing
    /// up the tool bridge (no `prepareToolBridge`), so if the model attempted
    /// a tool call the request would hit a dead bridge port. Disabling tools
    /// makes the probe test exactly what it should: connectivity.
    func testConnection(config: AIConfig) async throws -> String {
        var finalText = ""
        let messages: [AIMessage] = [
            .init(role: .system, content: "You are a connectivity probe. Reply with exactly: OK"),
            .init(role: .user, content: "Reply with OK.")
        ]
        let stream = try await sendStreaming(messages: messages, config: config, disableTools: true)
        for try await event in stream {
            switch event {
            case .textDelta(let delta): finalText += delta
            case .textSnapshot(let text): finalText = text
            case .completed(let text): finalText = text
            case .failed(let message): throw OpenCodeServerError.turnFailed(message)
            default: break
            }
        }
        guard !finalText.isEmpty else { throw OpenCodeServerError.emptyResponse }
        return finalText
    }

    /// Lists model ids known to the local opencode install via the server's
    /// `/config/providers` endpoint (invariant #8: NEVER via a direct-gateway
    /// client with an empty baseURL).
    func listModels(config: AIConfig) async throws -> [String] {
        let handle = try await ensureServer(config: config)
        let data = try await get(handle, path: "/config/providers")
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let providers = root["providers"] as? [[String: Any]] else {
            return []
        }
        var ids: [String] = []
        for provider in providers {
            let providerID = provider["id"] as? String
            if let models = provider["models"] as? [String: Any] {
                for modelID in models.keys {
                    ids.append(providerID.map { "\($0)/\(modelID)" } ?? modelID)
                }
            }
        }
        return ids.sorted()
    }

    // MARK: - Streaming turn

    /// Sends a prompt and returns an async stream of provider-agnostic events
    /// (text deltas, tool calls, permission requests, completion).
    /// - Parameter disableTools: when `true`, every NovaCAD-installed tool is
    ///   switched off for this turn (used by the connection probe).
    func sendStreaming(messages: [AIMessage],
                       config: AIConfig,
                       disableTools: Bool = false) async throws -> AsyncThrowingStream<AIStreamEvent, Error> {
        // A malformed non-empty model must fail BEFORE any server startup or
        // session work — `postPromptAsync` enforces the same rule defensively,
        // but checking here keeps the error instant even on a cold start.
        if let invalid = Self.modelValidationError(for: config.model) {
            throw OpenCodeServerError.turnFailed(invalid)
        }
        let handle = try await ensureServer(config: config)
        // Reuse one opencode session across conversational turns so the
        // server retains ITS OWN memory — crucially the results of tool
        // calls. Probes (`disableTools`) always use a throwaway session so
        // they never pollute or depend on the conversation.
        let sessionID: String
        let sessionIsFresh: Bool
        if disableTools {
            sessionID = try await createSession(handle)
            sessionIsFresh = true
        } else {
            let existing = conversationSessionID
            sessionID = try await ensureConversationSession(handle)
            // A session we were ALREADY using (and that still exists server
            // side) already remembers every earlier turn.
            sessionIsFresh = (existing != sessionID)
        }
        let (system, prompt) = Self.splitSystemAndPrompt(messages)
        // THE REPETITION FIX: this server deliberately reuses one session so
        // it keeps its own memory of the conversation, INCLUDING tool results
        // (see `ensureConversationSession`). But `splitSystemAndPrompt`
        // flattens the caller's whole transcript into ONE prompt string with
        // `[User]`/`[Assistant]` headers — so on a reused session the model
        // received its own previous answers back as fresh prompt text on every
        // single turn, which reliably made it restate/re-summarize what it had
        // already said and re-run tools it had already run ("the AI Assistant
        // is also repeating itself"). On a reused session, send ONLY the newest
        // user turn and let the server's own memory supply the history; on a
        // genuinely FRESH session (first turn, or the session was reset by a
        // server restart / tools (re)install / Clear Conversation) send the
        // full transcript so nothing is lost.
        let promptText = sessionIsFresh ? prompt : Self.newestUserTurn(messages) ?? prompt

        return AsyncThrowingStream { continuation in
            // The SSE reader is an unstructured task shared with
            // `onTermination` so it can be cancelled on every exit path.
            let eventsBox = TaskBox()
            // `/event` is a plain SSE stream with NO replay/backlog: any
            // event opencode emits before this client's GET request is
            // actually connected is lost forever to this listener. Merely
            // *starting* `eventsTask` below does NOT establish that
            // ordering — Swift's concurrency scheduler is free to run the
            // prompt POST's network call before the events GET's connection
            // completes, and when that race is lost the entire turn's
            // events (including the final completion) silently vanish.
            // `ConnectionSignal` is an explicit rendezvous: `consumeEvents`
            // resolves it the instant the SSE response headers arrive, and
            // `postPromptAsync` below is held until that happens.
            let connectionSignal = ConnectionSignal()
            let task = Task {
                let eventsTask = Task {
                    try await self.consumeEvents(handle,
                                                 sessionID: sessionID,
                                                 into: continuation,
                                                 connected: connectionSignal)
                }
                await eventsBox.set(eventsTask)
                do {
                    continuation.yield(.sessionStarted(sessionID))
                    try await connectionSignal.waitUntilConnected()
                    try await self.postPromptAsync(handle,
                                                   sessionID: sessionID,
                                                   system: system,
                                                   prompt: promptText,
                                                   config: config,
                                                   disableTools: disableTools)
                    try await eventsTask.value
                } catch {
                    eventsTask.cancel()
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                Task { await eventsBox.cancel() }
            }
        }
    }

    /// Responds to a pending permission request (allow/deny). No NovaCAD tool
    /// is currently guarded (see `AIStreamEvent.permissionRequest`'s own doc
    /// comment) but this is ported for full parity with the earlier project.
    func respondToPermission(_ request: AIPermissionRequest,
                             sessionID: String,
                             allow: Bool,
                             remember: Bool = false,
                             config: AIConfig) async throws {
        let handle = try await ensureServer(config: config)
        let body: [String: Any] = ["response": allow ? "allow" : "deny", "remember": remember]
        _ = try await post(handle, path: "/session/\(sessionID)/permissions/\(request.id)", json: body)
    }

    // MARK: - Session + prompt

    private func createSession(_ handle: ServerHandle) async throws -> String {
        let data = try await post(handle, path: "/session", json: ["title": "NovaCAD AI"])
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["id"] as? String else {
            throw OpenCodeServerError.badResponse("session create returned no id")
        }
        return id
    }

    /// The long-lived conversation session id, reused across turns so
    /// opencode keeps its own working memory. Persisted to UserDefaults keyed
    /// by the server's identity hash, so the session survives an app relaunch.
    private var conversationSessionID: String?
    private var serverIdentity: String?

    private func ensureConversationSession(_ handle: ServerHandle) async throws -> String {
        if let id = conversationSessionID, await sessionExists(handle, id: id) {
            return id
        }
        if let identity = serverIdentity,
           let persisted = UserDefaults.standard.string(forKey: "novacad.opencode.session.\(identity)"),
           await sessionExists(handle, id: persisted) {
            conversationSessionID = persisted
            return persisted
        }
        let id = try await createSession(handle)
        conversationSessionID = id
        if let identity = serverIdentity {
            UserDefaults.standard.set(id, forKey: "novacad.opencode.session.\(identity)")
        }
        return id
    }

    private func sessionExists(_ handle: ServerHandle, id: String) async -> Bool {
        (try? await get(handle, path: "session/\(id)/message")) != nil
    }

    /// Forgets the reusable conversation session, so the next turn starts a
    /// new one. Used when the user clears the conversation or the server
    /// restarts.
    func resetConversationSession() {
        conversationSessionID = nil
        if let identity = serverIdentity {
            UserDefaults.standard.removeObject(forKey: "novacad.opencode.session.\(identity)")
        }
    }

    /// The desired `<workspace>/opencode.json` contents, disabling opencode's
    /// built-in coding tools (invariant #14): NovaCAD's AI Assistant is a
    /// drawing assistant, not a coding agent — the model must use ONLY
    /// NovaCAD's own tools (see `NovaCADToolInstaller.tools`) and answer in
    /// text. Left enabled, the model could reach for `bash`/`edit`/etc.
    /// instead. opencode disables a tool when its entry is `false`.
    ///
    /// `question` (and its aliases) are disabled for a DIFFERENT and more
    /// severe reason than the coding tools: `question` is opencode's
    /// INTERACTIVE "ask the user a clarifying question and wait for their
    /// choice" tool, which only functions in a client that renders its
    /// choices and posts an answer back. NovaCAD's tool bridge exposes no
    /// such UI, so a `question` call is never answered and the turn hangs
    /// indefinitely — the user sees a permanently spinning "Thinking…" with a
    /// raw `question(questions: (...))` fragment where the reply should be,
    /// until the idle watchdog eventually kills the turn.
    ///
    /// This bit a real user, and its shape is worth remembering: their FIRST
    /// message (a simple request needing no clarification) answered fine, and
    /// then every later message the agent wanted to ask about silently hung —
    /// which reads like "the assistant stopped replying" rather than like a
    /// tool problem. With the tool disabled the model asks its clarifying
    /// question as ordinary TEXT instead, which is the correct behavior for a
    /// chat panel anyway.
    private static var toolsConfigDict: [String: Any] {
        [
            "$schema": "https://opencode.ai/config.json",
            "tools": [
                "bash": false,
                "edit": false,
                "write": false,
                "read": false,
                "grep": false,
                "glob": false,
                "list": false,
                "patch": false,
                "webfetch": false,
                "todowrite": false,
                "todoread": false,
                "task": false,
                // Interactive/blocking tools NovaCAD has no UI to answer —
                // see this property's doc comment. Aliases are listed too
                // since opencode has used more than one name for this
                // capability across versions, and disabling an unknown tool
                // name is harmless.
                "question": false,
                "ask": false,
                "elicit": false
            ]
        ]
    }

    private static var toolsConfigData: Data? {
        try? JSONSerialization.data(withJSONObject: toolsConfigDict, options: [.prettyPrinted, .sortedKeys])
    }

    /// Unconditionally (re)writes `opencode.json` — used right before
    /// launching a fresh `opencode serve` process, which reads it once at
    /// bootstrap. `workspace` defaults to the real shared workspace; tests
    /// pass a temp directory (mirroring `NovaCADToolInstaller.install
    /// (workspace:)`'s identical testability pattern).
    static func writeToolsConfig(workspace: URL = OpenCodeWorkspace.directory) {
        guard let data = toolsConfigData else { return }
        writeToolsConfigData(data, workspace: workspace)
    }

    /// Writes the tools config, creating the workspace directory if needed.
    private static func writeToolsConfigData(_ data: Data, workspace: URL) {
        let url = workspace.appendingPathComponent("opencode.json")
        try? FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    /// Rewrites `opencode.json` only if the desired content differs from
    /// what's currently on disk, returning whether a change was made. Called
    /// from `ensureServer` on every turn (cheap: a small JSON compare, not a
    /// network call) so a config edit shipped in a NEW app build — like
    /// disabling the interactive `question` tool that used to hang every
    /// clarifying turn — takes effect for a user who already has a long-lived
    /// `opencode serve` process running from BEFORE that build was installed,
    /// rather than silently doing nothing until they happen to quit and
    /// relaunch NovaCAD.
    @discardableResult
    static func refreshToolsConfigIfChanged(workspace: URL = OpenCodeWorkspace.directory) -> Bool {
        guard let desired = toolsConfigData else { return false }
        let url = workspace.appendingPathComponent("opencode.json")
        let existing = try? Data(contentsOf: url)
        guard existing != desired else { return false }
        writeToolsConfigData(desired, workspace: workspace)
        return true
    }

    private func postPromptAsync(_ handle: ServerHandle,
                                 sessionID: String,
                                 system: String?,
                                 prompt: String,
                                 config: AIConfig,
                                 disableTools: Bool = false) async throws {
        var body: [String: Any] = [
            "parts": [["type": "text", "text": prompt]]
        ]
        if let system, !system.isEmpty { body["system"] = system }
        // The server's schema requires `model` as a {providerID, modelID}
        // object — sending a flat "provider/model" config string directly
        // produces a 400 "expected object, received string" error.
        //
        // A non-empty model that ISN'T `provider/model` must fail loudly:
        // silently omitting `model` (the old behavior) made the server run
        // its DEFAULT model while everything — including Test Connection —
        // still reported success, so a typo'd model was undetectable.
        if let invalid = Self.modelValidationError(for: config.model) {
            throw OpenCodeServerError.turnFailed(invalid)
        }
        if let model = Self.providerModel(from: config.model) {
            body["model"] = ["providerID": model.providerID, "modelID": model.modelID]
        }
        if let agent = config.opencodeAgent?.trimmingCharacters(in: .whitespacesAndNewlines),
           !agent.isEmpty {
            body["agent"] = agent
        }
        // The prompt API accepts a `tools` map of { toolName: enabled }. For
        // the connection probe we switch every NovaCAD-installed tool OFF, so
        // the turn can't attempt a tool call (the bridge isn't running during
        // a probe).
        if disableTools {
            let disabled = NovaCADToolInstaller.tools.reduce(into: [String: Bool]()) { map, spec in
                map[spec.name] = false
            }
            if !disabled.isEmpty { body["tools"] = disabled }
        }
        _ = try await post(handle, path: "/session/\(sessionID)/prompt_async", json: body)
    }

    // MARK: - SSE consumption

    /// Consumes the `/event` SSE stream and translates opencode bus events for
    /// `sessionID` into NovaCAD `AIStreamEvent`s until the turn completes.
    ///
    /// An idle watchdog runs alongside the SSE reader: if no new activity
    /// arrives within `idleTurnTimeout`, the turn is finished with whatever
    /// text accumulated. This guarantees the UI never stays stuck
    /// "Thinking…" forever.
    private func consumeEvents(_ handle: ServerHandle,
                               sessionID: String,
                               into continuation: AsyncThrowingStream<AIStreamEvent, Error>.Continuation,
                               connected: ConnectionSignal) async throws {
        var request = URLRequest(url: handle.baseURL.appendingPathComponent("event"))
        request.timeoutInterval = Self.requestTimeout
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        handle.authorize(&request)

        let (bytes, response) = try await Self.session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let error = OpenCodeServerError.badResponse("event stream HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
            await connected.fail(error)
            throw error
        }
        // The SSE connection is live and receiving as of here — safe for the
        // caller to fire the prompt POST now without losing any of its events.
        await connected.signal()

        var accumulatedText = ""
        var toolCalls: [String: AIToolCallEvent] = [:]
        // The assistant's own messageID for this turn, learned from the
        // `message.updated` event the server emits when it creates the
        // assistant's message. Until this is known, no text-part update is
        // treated as assistant output — otherwise the *user's own* prompt
        // gets echoed back as a `message.part.updated`/`type: "text"` event
        // too and would be misread as the assistant's reply.
        var assistantMessageID: String?
        var completionPoller: Task<Void, Never>?
        // The most recent `session.error` message seen for this turn.
        var sessionError: String?

        let activity = ActivityClock()
        let watchdog = Task { [continuation, weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000) // check every 5s
                if Task.isCancelled { return }
                if await activity.secondsSinceLast() >= Self.idleTurnTimeout {
                    var finalText = await activity.accumulatedText
                    if finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       let self,
                       let fetched = try? await self.fetchAssistantText(handle, sessionID: sessionID, assistantMessageID: nil),
                       !fetched.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        finalText = fetched
                    }
                    continuation.yield(.completed(finalText))
                    continuation.finish()
                    return
                }
            }
        }
        defer {
            watchdog.cancel()
            completionPoller?.cancel()
        }
        await activity.record(text: accumulatedText)

        for try await line in bytes.lines {
            try Task.checkCancellation()
            // SSE payload lines are prefixed with "data: ".
            guard line.hasPrefix("data:") else { continue }
            let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            guard let data = payload.data(using: .utf8),
                  let event = try? JSONDecoder().decode(BusEvent.self, from: data) else { continue }

            if let evSession = event.properties?.sessionID, evSession != sessionID { continue }
            await activity.record(text: accumulatedText)

            switch event.type {
            case "message.updated":
                if let info = event.properties?.info, info.role == "assistant", let id = info.id {
                    assistantMessageID = id
                    if completionPoller == nil {
                        completionPoller = Task { [weak self, continuation, activity] in
                            await self?.pollForCompletion(handle,
                                                          sessionID: sessionID,
                                                          assistantMessageID: id,
                                                          activity: activity,
                                                          into: continuation)
                        }
                    }
                }

            case "message.part.delta":
                guard let props = event.properties,
                      (props.field ?? "text") == "text",
                      let delta = props.delta, !delta.isEmpty,
                      let assistantMessageID else { break }
                if let messageID = props.messageID, messageID != assistantMessageID { break }
                accumulatedText += delta
                await activity.record(text: accumulatedText)
                continuation.yield(.textDelta(delta))

            case "message.part.updated":
                guard let part = event.properties?.part else { break }
                switch part.type {
                case "text":
                    guard let messageID = part.messageID, messageID == assistantMessageID else { break }
                    if let text = part.text {
                        let isAppendOnly = text.hasPrefix(accumulatedText)
                        let delta = Self.delta(previous: accumulatedText, current: text)
                        if !delta.isEmpty {
                            accumulatedText = text
                            await activity.record(text: accumulatedText)
                            // A divergent snapshot is not an append-only
                            // delta. Let the final completion reconciliation
                            // replace it rather than duplicating the whole
                            // assistant message in the current bubble.
                            if isAppendOnly {
                                continuation.yield(.textDelta(delta))
                            } else {
                                continuation.yield(.textSnapshot(text))
                            }
                        }
                    }
                case "tool", "tool-invocation", "tool_use":
                    if let call = Self.toolCall(from: part) {
                        toolCalls[call.id] = call
                        continuation.yield(.toolCall(call))
                    }
                default:
                    break
                }

            case "permission.updated", "permission.requested":
                if let perm = event.properties, let id = perm.permissionID {
                    continuation.yield(.permissionRequest(
                        AIPermissionRequest(id: id,
                                            toolName: perm.toolName ?? "action",
                                            detail: perm.title ?? "Permission requested")))
                }

            case "session.idle", "message.completed", "session.completed":
                let finalText = await Self.resolveFinalText(self, handle: handle, sessionID: sessionID,
                                                            assistantMessageID: assistantMessageID,
                                                            streamed: accumulatedText)
                if finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   let sessionError {
                    continuation.yield(.failed(sessionError))
                } else {
                    continuation.yield(.completed(finalText))
                }
                continuation.finish()
                return

            case "session.status":
                // This opencode build signals turn completion by transitioning
                // the session out of `busy`. BUT a tool-calling turn goes
                // busy → (tool step) → briefly NON-BUSY → busy → final answer
                // → non-busy. Finishing on the FIRST non-busy cuts the turn
                // off between the tool step and the model's follow-up
                // generation. Only treat a non-busy status as terminal once
                // the newest assistant message is actually COMPLETE.
                if let status = event.properties?.status, !status.isBusy, assistantMessageID != nil {
                    let done = await self.latestAssistantTurnComplete(handle, sessionID: sessionID)
                    if !done {
                        break
                    }
                    let finalText = await Self.resolveFinalText(self, handle: handle, sessionID: sessionID,
                                                                assistantMessageID: assistantMessageID,
                                                                streamed: accumulatedText)
                    if finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       let sessionError {
                        continuation.yield(.failed(sessionError))
                    } else {
                        continuation.yield(.completed(finalText))
                    }
                    continuation.finish()
                    return
                }

            case "session.error":
                let message = event.properties?.error ?? "opencode session error"
                sessionError = message
                continuation.yield(.failed(message))
                continuation.finish()
                return

            default:
                break
            }
        }
        // Stream ended without an explicit completion event.
        continuation.yield(.completed(accumulatedText))
        continuation.finish()
    }

    // MARK: - Idle watchdog

    /// Holds a reference to the SSE-reader task so `AsyncThrowingStream`'s
    /// `onTermination` handler can cancel it from a non-async context.
    private actor TaskBox {
        private var task: Task<Void, Error>?
        func set(_ task: Task<Void, Error>) { self.task = task }
        func cancel() { task?.cancel() }
    }

    /// One-shot rendezvous closing the SSE-connect-before-prompt-POST race
    /// (see `sendStreaming`'s doc comment). `internal` (not `private`) so
    /// tests can exercise this concurrency primitive directly as a pure unit.
    actor ConnectionSignal {
        private enum State {
            case pending
            case connected
            case failed(Error)
        }
        private var state: State = .pending
        private var waiters: [CheckedContinuation<Void, Error>] = []

        func signal() {
            guard case .pending = state else { return }
            state = .connected
            for waiter in waiters { waiter.resume() }
            waiters.removeAll()
        }

        func fail(_ error: Error) {
            guard case .pending = state else { return }
            state = .failed(error)
            for waiter in waiters { waiter.resume(throwing: error) }
            waiters.removeAll()
        }

        func waitUntilConnected() async throws {
            switch state {
            case .connected: return
            case .failed(let error): throw error
            case .pending:
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    waiters.append(continuation)
                }
            }
        }
    }

    /// Thread-safe clock tracking the time of the last relevant SSE event
    /// and the latest accumulated assistant text, so the idle watchdog can
    /// decide when a turn has stalled and finish it gracefully.
    private actor ActivityClock {
        private var last = Date()
        private(set) var accumulatedText = ""

        func record(text: String) {
            last = Date()
            accumulatedText = text
        }

        func secondsSinceLast() -> TimeInterval {
            Date().timeIntervalSince(last)
        }
    }

    // MARK: - Translation helpers

    /// opencode's `run` prompt is a single string, but the server's message
    /// endpoint supports a dedicated `system` field, so NovaCAD separates the
    /// system instructions from the flattened user/assistant transcript.
    nonisolated static func splitSystemAndPrompt(_ messages: [AIMessage]) -> (system: String?, prompt: String) {
        let systemParts = messages.filter { $0.role == .system }.map(\.content)
        let convo = messages.filter { $0.role != .system }.map { message -> String in
            switch message.role {
            case .system: return message.content
            case .user: return "[User]\n\(message.content)"
            case .assistant: return "[Assistant]\n\(message.content)"
            }
        }
        let system = systemParts.isEmpty ? nil : systemParts.joined(separator: "\n\n")
        let prompt = convo.joined(separator: "\n\n")
        return (system, prompt)
    }

    /// The newest USER message's content, unwrapped and with no `[User]`
    /// header — what to prompt with on a REUSED session, whose server-side
    /// memory already holds every earlier turn. Returns nil when there is no
    /// user message at all (in which case the caller falls back to the full
    /// flattened transcript rather than sending an empty prompt). Deliberately
    /// takes the LAST user message rather than the last message overall: the
    /// trailing entry could be an assistant turn (`AIAssistantSession` appends
    /// the new user input to `history` before building the transcript, but a
    /// future caller ordering shouldn't silently prompt with the assistant's
    /// own words).
    nonisolated static func newestUserTurn(_ messages: [AIMessage]) -> String? {
        guard let last = messages.last(where: { $0.role == .user }) else { return nil }
        let text = last.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Splits `"provider/model"` (e.g. `"anthropic/claude-sonnet-4-5"`) into
    /// the `{providerID, modelID}` pair the server's
    /// `/session/:id/prompt_async` schema requires. Returns nil for an
    /// empty/malformed string so the request simply omits `model` and falls
    /// back to the server's configured default.
    nonisolated static func providerModel(from configModel: String) -> (providerID: String, modelID: String)? {
        let trimmed = configModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let slash = trimmed.firstIndex(of: "/") else { return nil }
        let providerID = String(trimmed[trimmed.startIndex..<slash])
        let modelID = String(trimmed[trimmed.index(after: slash)...])
        guard !providerID.isEmpty, !modelID.isEmpty else { return nil }
        return (providerID, modelID)
    }

    /// The error to fail a turn with when `configModel` is malformed, or nil
    /// when it is acceptable. Empty is acceptable — it means "use the
    /// server's default model" (`.opencodeServer`'s own default). Anything
    /// else must be `provider/model`; see `postPromptAsync` for why a broken
    /// value must never be silently dropped.
    nonisolated static func modelValidationError(for configModel: String) -> String? {
        let trimmed = configModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard providerModel(from: trimmed) == nil else { return nil }
        return "Invalid model \"\(trimmed)\". Use provider/model (e.g. "
            + "\"anthropic/claude-sonnet-4-5\"), or leave the Model field "
            + "blank to use the server's default."
    }

    nonisolated static func toolCall(from part: BusEvent.Part) -> AIToolCallEvent? {
        guard let id = part.id ?? part.callID else { return nil }
        let name = part.tool ?? part.name ?? "tool"
        let status: AIToolCallEvent.Status
        switch (part.state?.status ?? part.status)?.lowercased() {
        case "completed", "success", "done": status = .completed
        case "error", "failed": status = .failed
        case "running", "in_progress": status = .running
        case "pending": status = .pending
        default: status = .running
        }
        let argsJSON = part.state?.inputJSONString ?? part.inputJSONString
        return AIToolCallEvent(id: id,
                               name: name,
                               argumentSummary: Self.summarize(argsJSON),
                               status: status,
                               resultSummary: part.state?.output ?? part.output)
    }

    /// Produces a compact, single-line summary of a JSON argument blob.
    nonisolated static func summarize(_ json: String?) -> String {
        guard let json, let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ""
        }
        return obj.keys.sorted().prefix(3).compactMap { key in
            guard let value = obj[key] else { return nil }
            let str = "\(value)"
            let clipped = str.count > 40 ? String(str.prefix(40)) + "…" : str
            return "\(key): \(clipped)"
        }.joined(separator: " · ")
    }

    nonisolated static func delta(previous: String, current: String) -> String {
        if current.hasPrefix(previous) { return String(current.dropFirst(previous.count)) }
        return current
    }

    /// Whether the newest assistant message of the session represents a
    /// truly finished turn. A non-busy `session.status` can fire between a
    /// tool step and the model's follow-up generation, when the newest
    /// assistant message exists but is uncompleted — in which case the turn
    /// is NOT done and we must keep waiting. Fails open (returns true) if the
    /// shape can't be read, so a parsing quirk can never hang the turn
    /// forever.
    private func latestAssistantTurnComplete(_ handle: ServerHandle, sessionID: String) async -> Bool {
        guard let data = try? await get(handle, path: "session/\(sessionID)/message"),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return true
        }
        for entry in arr.reversed() {
            let info = (entry["info"] as? [String: Any]) ?? entry
            guard (info["role"] as? String) == "assistant" else { continue }
            if let time = info["time"] as? [String: Any], time["completed"] != nil { return true }
            if info["error"] != nil { return true }
            let parts = (entry["parts"] as? [[String: Any]]) ?? (info["parts"] as? [[String: Any]]) ?? []
            let hasText = parts.contains {
                ($0["type"] as? String) == "text" && !(($0["text"] as? String) ?? "").isEmpty
            }
            return hasText
        }
        return true
    }

    private static func resolveFinalText(_ client: OpenCodeServerClient,
                                         handle: ServerHandle,
                                         sessionID: String,
                                         assistantMessageID: String?,
                                         streamed: String) async -> String {
        // ALWAYS reconcile against the persisted messages, even when we
        // streamed some text. A TOOL-CALLING turn produces MULTIPLE
        // assistant messages — an early one that only makes the tool call,
        // then a later one with the real answer after the tool result.
        let streamedTrimmed = streamed.trimmingCharacters(in: .whitespacesAndNewlines)
        if let fetched = try? await client.fetchAssistantText(handle,
                                                              sessionID: sessionID,
                                                              assistantMessageID: assistantMessageID),
           !fetched.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if fetched.count >= streamed.count { return fetched }
            return streamedTrimmed.isEmpty ? fetched : streamed
        }
        return streamed
    }

    /// Polls the persisted assistant message until the turn is finished (a
    /// `step-finish` part appears) or an error is recorded, then yields the
    /// final text and finishes the stream. Bounded by `idleTurnTimeout`.
    private func pollForCompletion(_ handle: ServerHandle,
                                   sessionID: String,
                                   assistantMessageID: String,
                                   activity: ActivityClock,
                                   into continuation: AsyncThrowingStream<AIStreamEvent, Error>.Continuation) async {
        let deadline = Date().addingTimeInterval(Self.idleTurnTimeout)
        var lastNewestText = ""
        var stableTextCount = 0
        // Bound how long we wait for the model's post-tool follow-up answer.
        // Some backends end a turn right after tool-calls with an EMPTY,
        // never-completed assistant message. If the follow-up produces no
        // text within this window after the tool step finished, finish the
        // turn with the tool output we DO have.
        let emptyFollowUpDeadline = Date().addingTimeInterval(15)
        while !Task.isCancelled, Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000_000) // poll every 1s
            if Task.isCancelled { return }
            guard let data = try? await get(handle, path: "session/\(sessionID)/message/\(assistantMessageID)") else { continue }
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let info = obj["info"] as? [String: Any],
               let err = info["error"] as? [String: Any],
               let message = (err["message"] as? String) ?? (err["data"] as? [String: Any])?["message"] as? String {
                continuation.yield(.failed(message))
                continuation.finish()
                return
            }
            let info = obj["info"] as? [String: Any]
            let finishReason = (info?["finishReason"] as? String) ?? (info?["finish"] as? String)
            let parts = obj["parts"] as? [[String: Any]] ?? []
            let calledTools = parts.contains { ($0["type"] as? String) == "tool" }
            let text = parts
                .filter { ($0["type"] as? String) == "text" }
                .compactMap { $0["text"] as? String }
                .joined()

            if finishReason == "tool-calls" || (finishReason == nil && calledTools) {
                if let (newestText, newestDone) = try? await newestAssistantTextAndDone(handle, sessionID: sessionID) {
                    if newestDone, !newestText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        continuation.yield(.completed(newestText))
                        continuation.finish()
                        return
                    }
                    if !newestText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        stableTextCount = (lastNewestText == newestText) ? stableTextCount + 1 : 0
                        lastNewestText = newestText
                        if stableTextCount >= 2 {  // ~2s of unchanged text ⇒ done
                            continuation.yield(.completed(newestText))
                            continuation.finish()
                            return
                        }
                    } else if Date() > emptyFollowUpDeadline {
                        // Only fire the empty-follow-up fallback if the SSE
                        // stream ALSO has no text (the REST poll can lag the
                        // live delta stream).
                        let streamedSoFar = await activity.accumulatedText
                        if streamedSoFar.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            let toolSummary = await self.toolResultSummary(handle, sessionID: sessionID)
                            let fallback = toolSummary.isEmpty
                                ? "The tools ran successfully, but the model didn't produce a final written answer. Try rephrasing your question, or ask me to summarize what the tool returned."
                                : "The model ran its tools but didn't write a final summary. Here's what the tools returned:\n\n\(toolSummary)"
                            continuation.yield(.completed(fallback))
                            continuation.finish()
                            return
                        }
                    }
                }
                continue // keep polling; the answer message isn't ready yet
            }

            let isFinished = parts.contains { ($0["type"] as? String) == "step-finish" }
            if isFinished {
                let finalText: String
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   let newest = try? await fetchAssistantText(handle, sessionID: sessionID,
                                                              assistantMessageID: assistantMessageID),
                   !newest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    finalText = newest
                } else {
                    finalText = text
                }
                continuation.yield(.completed(finalText))
                continuation.finish()
                return
            }
        }
    }

    /// Extracts a readable summary of the tool outputs from a session's
    /// assistant messages. Used as a graceful fallback when the model ran
    /// its tools but never produced a final written answer.
    private func toolResultSummary(_ handle: ServerHandle, sessionID: String) async -> String {
        guard let data = try? await get(handle, path: "session/\(sessionID)/message"),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return ""
        }
        var lines: [String] = []
        for entry in arr {
            let parts = (entry["parts"] as? [[String: Any]]) ?? []
            for p in parts where (p["type"] as? String) == "tool" {
                let name = p["tool"] as? String ?? "tool"
                let state = p["state"] as? [String: Any]
                let output = (state?["output"] as? String)
                    ?? (state?["result"] as? String)
                    ?? ((state?["metadata"] as? [String: Any])?["output"] as? String)
                    ?? ""
                if !output.isEmpty {
                    lines.append("**\(name)**:\n\(output.prefix(1500))")
                }
            }
        }
        return lines.joined(separator: "\n\n")
    }

    /// Returns the newest assistant message's concatenated text plus whether
    /// that message is complete. Used by the tool-loop completion path to
    /// wait for the FINAL answer message before finishing the turn.
    private func newestAssistantTextAndDone(_ handle: ServerHandle, sessionID: String) async throws -> (text: String, done: Bool) {
        let data = try await get(handle, path: "session/\(sessionID)/message")
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return ("", false)
        }
        for entry in arr.reversed() {
            let info = (entry["info"] as? [String: Any]) ?? entry
            guard (info["role"] as? String) == "assistant" else { continue }
            let parts = (entry["parts"] as? [[String: Any]]) ?? (info["parts"] as? [[String: Any]]) ?? []
            let text = parts
                .filter { ($0["type"] as? String) == "text" }
                .compactMap { $0["text"] as? String }
                .joined()
            let completed = (info["time"] as? [String: Any])?["completed"] != nil
            return (text, completed)
        }
        return ("", false)
    }

    private func fetchAssistantText(_ handle: ServerHandle,
                                    sessionID: String,
                                    assistantMessageID: String?) async throws -> String? {
        // Scan the message LIST first (newest assistant message wins). In a
        // tool-calling turn the session holds several assistant messages;
        // the pinned `assistantMessageID` is typically the EARLIER
        // tool-invoking one whose text is empty/partial.
        for attempt in 0..<8 {
            let listData = try await get(handle, path: "session/\(sessionID)/message")
            if let text = Self.assistantText(fromMessageListJSON: listData), !text.isEmpty { return text }
            if let id = assistantMessageID {
                let data = try await get(handle, path: "session/\(sessionID)/message/\(id)")
                if let text = Self.assistantText(fromMessageJSON: data), !text.isEmpty { return text }
            }
            if attempt < 7 { try? await Task.sleep(nanoseconds: 500_000_000) } // 0.5s
        }
        return nil
    }

    /// Extracts concatenated `text` part content from a single message
    /// payload (`{ info: {...}, parts: [{type,text}] }` or a bare message
    /// object).
    nonisolated static func assistantText(fromMessageJSON data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return textFromParts(obj["parts"])
    }

    /// Extracts the newest assistant message's text from a message-list
    /// payload.
    nonisolated static func assistantText(fromMessageListJSON data: Data) -> String? {
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        for entry in arr.reversed() {
            let info = (entry["info"] as? [String: Any]) ?? entry
            if (info["role"] as? String) == "assistant" {
                if let text = textFromParts(entry["parts"]), !text.isEmpty { return text }
            }
        }
        return nil
    }

    /// Joins the `text` fields of a `parts` array, skipping non-text parts.
    private nonisolated static func textFromParts(_ parts: Any?) -> String? {
        guard let parts = parts as? [[String: Any]] else { return nil }
        let text = parts
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        return text.isEmpty ? nil : text
    }

    // MARK: - HTTP core

    // `nonisolated` (invariant #1, THE critical fix): these only read the
    // passed-in `handle` and static session/timeout — never mutable actor
    // state — so they must NOT run on the actor's serial executor. Keeping
    // them actor-isolated meant the URLSession call (and its continuation
    // resumption) was tied to the actor; combined with the long-lived
    // streaming/consume work that also hops through the actor, the first
    // `waitForHealth` GET could suspend and never be resumed — the observed
    // "server never becomes healthy / stuck at 10%" wedge. Running the HTTP
    // off the actor lets the request complete independently of actor
    // scheduling.
    nonisolated private func get(_ handle: ServerHandle, path: String) async throws -> Data {
        var request = URLRequest(url: handle.baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))))
        request.timeoutInterval = Self.requestTimeout
        handle.authorize(&request)
        let (data, response) = try await Self.session.data(for: request)
        try Self.validate(response, data: data)
        return data
    }

    @discardableResult
    nonisolated private func post(_ handle: ServerHandle, path: String, json: [String: Any]) async throws -> Data {
        var request = URLRequest(url: handle.baseURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))))
        request.httpMethod = "POST"
        request.timeoutInterval = Self.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        handle.authorize(&request)
        request.httpBody = try JSONSerialization.data(withJSONObject: json)
        let (data, response) = try await Self.session.data(for: request)
        try Self.validate(response, data: data)
        return data
    }

    private static func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw OpenCodeServerError.badResponse("no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw OpenCodeServerError.httpError(status: http.statusCode, body: String(body.prefix(400)))
        }
    }

    private func waitForHealth(_ handle: ServerHandle) async throws {
        let deadline = Date().addingTimeInterval(Self.startupTimeout)
        while Date() < deadline {
            try Task.checkCancellation()
            // A crashed server never becomes healthy, and polling a dead
            // process for the full 45s makes a bad global plugin/config look
            // like a slow npm install. Fail NOW, with the server's own
            // stderr as the explanation.
            if !handle.process.isRunning {
                // Best-effort grace period: the background drain thread may
                // not have appended the child's final stderr bytes yet.
                try? await Task.sleep(nanoseconds: 100_000_000)
                throw OpenCodeServerError.launchFailed(Self.startupExitMessage(
                    status: handle.process.terminationStatus,
                    reason: handle.process.terminationReason,
                    stderrTail: handle.stderrTail.tailString()))
            }
            do {
                let data = try await get(handle, path: "/global/health")
                if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   (obj["healthy"] as? Bool) == true {
                    return
                }
            } catch {
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        throw OpenCodeServerError.startupTimedOut
    }

    /// Human-readable diagnostic for an `opencode serve` that died before
    /// becoming healthy. Pure (no `Process` needed) so it's unit-testable.
    nonisolated static func startupExitMessage(status: Int32,
                                               reason: Process.TerminationReason,
                                               stderrTail: String) -> String {
        let lead = reason == .uncaughtSignal
            ? "the process was killed by a signal during startup"
            : "the process exited during startup (status \(status))"
        let tail = stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tail.isEmpty else { return lead }
        let clipped = tail.count > 600 ? "…" + tail.suffix(600) : tail
        return "\(lead). Last output:\n\(clipped)"
    }

    // MARK: - Binary resolution + env

    private func resolveBinary(override: String?) async throws -> String {
        if let override, !override.isEmpty {
            guard FileManager.default.isExecutableFile(atPath: override) else {
                throw OpenCodeServerError.binaryNotFound(searched: [override])
            }
            return override
        }
        for path in Self.candidateBinaryPaths where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        throw OpenCodeServerError.binaryNotFound(searched: Self.candidateBinaryPaths)
    }

    private static func augmentedPath(_ existing: String?) -> String {
        let extras = ["/usr/local/bin", "/opt/homebrew/bin", "/usr/bin", "/bin"]
        var components = (existing ?? "").split(separator: ":").map(String.init)
        var seen = Set(components)
        for extra in extras where !seen.contains(extra) {
            components.append(extra); seen.insert(extra)
        }
        return components.joined(separator: ":")
    }

    private static func randomPassword() -> String {
        UUID().uuidString + UUID().uuidString
    }

    /// Binds a temporary socket to :0 to discover a free loopback port, then
    /// closes it. There's an inherent race between close and reuse, but it's
    /// the standard approach and the window is tiny for a locally-managed
    /// server.
    private static func freeLoopbackPort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return 4096 }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { return 4096 }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &addr) { ptr in
            _ = ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        return Int(UInt16(bigEndian: addr.sin_port))
    }
}

/// Process-wide holder for the single managed `OpenCodeServerClient`, so the
/// `opencode serve` process persists across turns rather than spawning and
/// tearing down a server on every message.
actor OpenCodeServerRegistry {
    static let shared = OpenCodeServerRegistry()
    private let client = OpenCodeServerClient()

    func complete(messages: [AIMessage], config: AIConfig) async throws -> String {
        try await client.complete(messages: messages, config: config)
    }

    /// Tool-free connection probe (see `OpenCodeServerClient.testConnection`).
    func testConnection(config: AIConfig) async throws -> String {
        try await client.testConnection(config: config)
    }

    /// Signals that the NovaCAD tool forwarders were (re)installed, so an
    /// already running server (bootstrapped before the tools existed) is
    /// restarted to pick them up.
    func noteToolsInstalled(signature: String) async {
        await client.noteToolsInstalled(signature: signature)
    }

    /// Signals that the NovaCAD tool forwarders were removed (tools disabled).
    func noteToolsUninstalled() async {
        await client.noteToolsUninstalled()
    }

    /// Starts a fresh opencode conversation session on the next turn (used
    /// when the user clears the conversation).
    func resetConversationSession() async {
        await client.resetConversationSession()
    }

    func listModels(config: AIConfig) async throws -> [String] {
        try await client.listModels(config: config)
    }

    func sendStreaming(messages: [AIMessage],
                       config: AIConfig) async throws -> AsyncThrowingStream<AIStreamEvent, Error> {
        try await client.sendStreaming(messages: messages, config: config)
    }

    func respondToPermission(_ request: AIPermissionRequest,
                             sessionID: String,
                             allow: Bool,
                             remember: Bool = false,
                             config: AIConfig) async throws {
        try await client.respondToPermission(request, sessionID: sessionID,
                                             allow: allow, remember: remember, config: config)
    }

    func shutdown() async {
        await client.shutdown()
    }
}

/// Handle to a running `opencode serve` instance.
private struct ServerHandle {
    let process: Process
    let baseURL: URL
    let username: String
    let password: String
    /// Bounded tail of the server's stderr, for startup-failure diagnostics
    /// (see `OpenCodeServerClient.ProcessOutputTail`).
    let stderrTail: OpenCodeServerClient.ProcessOutputTail

    var isAlive: Bool { process.isRunning }

    func authorize(_ request: inout URLRequest) {
        let credentials = "\(username):\(password)"
        if let token = credentials.data(using: .utf8)?.base64EncodedString() {
            request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }
    }
}

/// Shared NovaCAD-managed scratch directory the OpenCode server backend runs
/// inside, so opencode's file/bash tools never touch the user's real
/// project/home dir. Mirrors the earlier project's OpenCode workspace, at
/// NovaCAD's own Application Support path.
enum OpenCodeWorkspace {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("NovaCAD/OpenCodeServerWorkspace", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }
}

// MARK: - Bus event decoding

/// A minimal decoder for opencode's SSE bus events. Only the fields NovaCAD
/// reacts to are modeled; unknown fields/events are ignored.
struct BusEvent: Decodable {
    var type: String?
    var properties: Properties?

    struct Properties: Decodable {
        var sessionID: String?
        var part: Part?
        var permissionID: String?
        var toolName: String?
        var title: String?
        /// Human-readable error message for `session.error` events. opencode
        /// delivers this as a NESTED object — `{"name": "...", "data":
        /// {"message": "..."}}` — NOT a flat string.
        var error: String?
        var info: MessageInfo?
        var status: SessionStatus?
        var messageID: String?
        var field: String?
        var delta: String?

        enum CodingKeys: String, CodingKey {
            case sessionID = "sessionID"
            case sessionIDAlt = "session_id"
            case part
            case permissionID
            case permissionIDAlt = "permission_id"
            case toolName
            case title
            case error
            case info
            case status
            case messageID
            case field
            case delta
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            sessionID = (try? c.decode(String.self, forKey: .sessionID))
                ?? (try? c.decode(String.self, forKey: .sessionIDAlt))
            part = try? c.decode(Part.self, forKey: .part)
            permissionID = (try? c.decode(String.self, forKey: .permissionID))
                ?? (try? c.decode(String.self, forKey: .permissionIDAlt))
            toolName = try? c.decode(String.self, forKey: .toolName)
            title = try? c.decode(String.self, forKey: .title)
            if let obj = try? c.decode(BusError.self, forKey: .error) {
                error = obj.message
            } else {
                error = try? c.decode(String.self, forKey: .error)
            }
            info = try? c.decode(MessageInfo.self, forKey: .info)
            status = try? c.decode(SessionStatus.self, forKey: .status)
            messageID = try? c.decode(String.self, forKey: .messageID)
            field = try? c.decode(String.self, forKey: .field)
            delta = try? c.decode(String.self, forKey: .delta)
        }
    }

    /// The `status` payload of a `session.status` event.
    struct SessionStatus: Decodable {
        var type: String?
        var isBusy: Bool { (type ?? "").lowercased() == "busy" }
    }

    /// The nested `error` payload of a `session.error` event:
    /// `{"name": "...", "data": {"message": "..."}}`.
    struct BusError: Decodable {
        var name: String?
        var data: Data?
        struct Data: Decodable {
            var message: String?
            var reason: String?
        }
        var message: String? {
            if let m = data?.message, !m.isEmpty { return m }
            if let r = data?.reason, !r.isEmpty { return r }
            if let n = name, !n.isEmpty { return n }
            return nil
        }
    }

    /// The `info` payload of a `message.updated` event: which message this
    /// is and whether it's the user's or the assistant's.
    struct MessageInfo: Decodable {
        var id: String?
        var role: String?
    }

    struct Part: Decodable {
        var id: String?
        var callID: String?
        var messageID: String?
        var type: String?
        var text: String?
        var tool: String?
        var name: String?
        var status: String?
        var output: String?
        var state: State?

        struct State: Decodable {
            var status: String?
            var output: String?
            var input: OpenCodeJSONValue?
            var inputJSONString: String? { input?.jsonString }
        }

        var input: OpenCodeJSONValue?
        var inputJSONString: String? { input?.jsonString }

        enum CodingKeys: String, CodingKey {
            case id, callID = "callID", messageID, type, text, tool, name, status, output, state, input
        }
    }
}

/// A tiny JSON value box so tool-call inputs of arbitrary shape can be
/// captured and re-serialized to a string for display/execution. Named
/// distinctly from `AIJSONValue` (`AIClient.swift`'s Anthropic-response
/// decoder) to avoid a symbol collision, even though the shape is identical.
enum OpenCodeJSONValue: Decodable {
    case string(String), number(Double), bool(Bool), object([String: OpenCodeJSONValue]), array([OpenCodeJSONValue]), null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Double.self) { self = .number(value); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode([String: OpenCodeJSONValue].self) { self = .object(value); return }
        if let value = try? container.decode([OpenCodeJSONValue].self) { self = .array(value); return }
        self = .null
    }

    var jsonString: String? {
        guard let data = try? JSONSerialization.data(withJSONObject: foundationValue) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private var foundationValue: Any {
        switch self {
        case .string(let value): return value
        case .number(let value): return value
        case .bool(let value): return value
        case .null: return NSNull()
        case .array(let values): return values.map(\.foundationValue)
        case .object(let dict): return dict.mapValues(\.foundationValue)
        }
    }
}

enum OpenCodeServerError: LocalizedError {
    case binaryNotFound(searched: [String])
    case launchFailed(String)
    case startupTimedOut
    case httpError(status: Int, body: String)
    case badResponse(String)
    case turnFailed(String)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .binaryNotFound(let searched):
            let hint = searched.isEmpty ? "" : " Checked: \(searched.joined(separator: ", "))."
            return "Could not find the `opencode` CLI on this Mac.\(hint) Install it from https://opencode.ai or set a custom binary path in AI Assistant Settings."
        case .launchFailed(let message):
            return "Failed to launch `opencode serve`: \(message)"
        case .startupTimedOut:
            return "The opencode server took too long to start. This is usually a slow first-time npm/node install — try again in a moment, or check Activity Monitor for a stuck `opencode` process to quit manually."
        case .httpError(let status, let body):
            return "opencode server returned HTTP \(status)\(body.isEmpty ? "" : ": \(body)")"
        case .badResponse(let message):
            return "Unexpected response from the opencode server: \(message)"
        case .turnFailed(let message):
            return "opencode turn failed: \(message)"
        case .emptyResponse:
            return "opencode returned no text response."
        }
    }
}
