import Foundation

/// Bridges the AI Assistant to the local `opencode` CLI (https://opencode.ai),
/// run headlessly and non-interactively — ported near-verbatim from the
/// earlier internal project's equivalent client (same sandboxed-workspace
/// design, same NDJSON parsing, same subprocess-with-timeout core), adapted
/// to NovaCAD's own `AIMessage`/`AIConfig` types. See that project for the
/// full design rationale; reproduced here rather than shared across packages
/// since the two are separate Swift packages with no shared dependency today.
actor OpenCodeCLIClient {
    private static let candidateBinaryPaths = [
        "/usr/local/bin/opencode",
        "/opt/homebrew/bin/opencode",
        "/usr/bin/opencode"
    ]

    private static let defaultTimeout: TimeInterval = 180

    func complete(messages: [AIMessage], config: AIConfig) async throws -> String {
        let binary = try await resolveBinary(override: config.opencodeBinaryPath)
        let prompt = Self.renderPrompt(messages: messages)

        var arguments = ["run", "--format", "json", "--dir", Self.workspaceDirectory.path]
        if !config.model.trimmingCharacters(in: .whitespaces).isEmpty {
            arguments += ["-m", config.model]
        }
        arguments.append(prompt)

        let result = try await run(binary: binary, arguments: arguments,
                                    workingDirectory: Self.workspaceDirectory, timeout: Self.defaultTimeout)
        guard result.status == 0 else {
            throw OpenCodeCLIError.processFailed(status: result.status, stderr: Self.trimmedTail(result.stderr))
        }
        let text = Self.extractFinalText(fromNDJSON: result.stdout)
        guard !text.isEmpty else {
            throw OpenCodeCLIError.emptyResponse(stderr: Self.trimmedTail(result.stderr))
        }
        return text
    }

    func listModels(config: AIConfig) async throws -> [String] {
        let binary = try await resolveBinary(override: config.opencodeBinaryPath)
        let result = try await run(binary: binary, arguments: ["models"],
                                    workingDirectory: Self.workspaceDirectory, timeout: 30)
        guard result.status == 0 else {
            throw OpenCodeCLIError.processFailed(status: result.status, stderr: Self.trimmedTail(result.stderr))
        }
        return result.stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Prompt rendering

    private static func renderPrompt(messages: [AIMessage]) -> String {
        messages.map { message -> String in
            switch message.role {
            case .system: return "[System instructions]\n\(message.content)"
            case .user: return "[User]\n\(message.content)"
            case .assistant: return "[Assistant]\n\(message.content)"
            }
        }.joined(separator: "\n\n")
    }

    // MARK: - NDJSON parsing

    nonisolated static func extractFinalText(fromNDJSON output: String) -> String {
        var pieces: [String] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let event = try? JSONDecoder().decode(Event.self, from: data) else { continue }
            guard event.type == "text", let text = event.part?.text, !text.isEmpty else { continue }
            pieces.append(text)
        }
        return pieces.joined()
    }

    private struct Event: Decodable {
        var type: String?
        var part: Part?
        struct Part: Decodable {
            var type: String?
            var text: String?
        }
    }

    private static func trimmedTail(_ text: String, limit: Int = 800) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > limit ? "…" + trimmed.suffix(limit) : trimmed
    }

    // MARK: - Sandboxed working directory

    /// A dedicated scratch directory opencode is always run in — NEVER the
    /// user's real project/home directory, since opencode's default agent
    /// has full file read/write + bash tool access to wherever it runs.
    static var workspaceDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("NovaCAD/OpenCodeWorkspace", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    // MARK: - Binary resolution

    private func resolveBinary(override: String?) async throws -> String {
        if let override, !override.isEmpty {
            guard FileManager.default.isExecutableFile(atPath: override) else {
                throw OpenCodeCLIError.binaryNotFound(searched: [override])
            }
            return override
        }
        for path in Self.candidateBinaryPaths where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        if let found = try? await whichOpencode() {
            return found
        }
        throw OpenCodeCLIError.binaryNotFound(searched: Self.candidateBinaryPaths)
    }

    private func whichOpencode() async throws -> String {
        let result = try await run(binary: "/usr/bin/which", arguments: ["opencode"],
                                    workingDirectory: Self.workspaceDirectory, timeout: 10)
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.status == 0, !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else {
            throw OpenCodeCLIError.binaryNotFound(searched: [])
        }
        return path
    }

    // MARK: - Process core

    private struct ProcessResult {
        var stdout: String
        var stderr: String
        var status: Int32
    }

    private func run(binary: String, arguments: [String], workingDirectory: URL,
                      timeout: TimeInterval) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = Self.augmentedPath(env["PATH"])
        process.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let outBuffer = AIDataBuffer()
        let errBuffer = AIDataBuffer()

        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { outBuffer.append(data) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { errBuffer.append(data) }
        }

        let timedOut = AITimeoutFlag()

        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, Error>) in
                process.terminationHandler = { proc in
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    let leftoverOut = outPipe.fileHandleForReading.readDataToEndOfFile()
                    if !leftoverOut.isEmpty { outBuffer.append(leftoverOut) }
                    let leftoverErr = errPipe.fileHandleForReading.readDataToEndOfFile()
                    if !leftoverErr.isEmpty { errBuffer.append(leftoverErr) }
                    if timedOut.value {
                        continuation.resume(throwing: OpenCodeCLIError.timeout)
                        return
                    }
                    let stdout = String(data: outBuffer.data, encoding: .utf8) ?? ""
                    let stderr = String(data: errBuffer.data, encoding: .utf8) ?? ""
                    continuation.resume(returning: ProcessResult(stdout: stdout, stderr: stderr, status: proc.terminationStatus))
                }

                do {
                    try process.run()
                } catch {
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: OpenCodeCLIError.launchFailed(error.localizedDescription))
                    return
                }

                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if process.isRunning {
                        timedOut.value = true
                        process.terminate()
                    }
                }
            }
        }, onCancel: {
            if process.isRunning { process.terminate() }
        })
    }

    private static func augmentedPath(_ existing: String?) -> String {
        let extras = ["/usr/local/bin", "/opt/homebrew/bin", "/usr/bin", "/bin"]
        var components = (existing ?? "").split(separator: ":").map(String.init)
        var seen = Set(components)
        for extra in extras where !seen.contains(extra) {
            components.append(extra)
            seen.insert(extra)
        }
        return components.joined(separator: ":")
    }
}

private final class AIDataBuffer: @unchecked Sendable {
    private var storage = Data()
    private let lock = NSLock()
    func append(_ data: Data) { lock.lock(); storage.append(data); lock.unlock() }
    var data: Data { lock.lock(); defer { lock.unlock() }; return storage }
}

private final class AITimeoutFlag: @unchecked Sendable {
    private var _value = false
    private let lock = NSLock()
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}

enum OpenCodeCLIError: LocalizedError {
    case binaryNotFound(searched: [String])
    case launchFailed(String)
    case processFailed(status: Int32, stderr: String)
    case emptyResponse(stderr: String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .binaryNotFound(let searched):
            let hint = searched.isEmpty ? "" : " Checked: \(searched.joined(separator: ", "))."
            return "Could not find the `opencode` CLI on this Mac.\(hint) Install it from https://opencode.ai or set a custom binary path in AI Assistant Settings."
        case .launchFailed(let message):
            return "Failed to launch opencode: \(message)"
        case .processFailed(let status, let stderr):
            return "opencode exited with status \(status)\(stderr.isEmpty ? "" : ": \(stderr)")"
        case .emptyResponse(let stderr):
            return stderr.isEmpty ? "opencode returned no text response." : "opencode returned no text response: \(stderr)"
        case .timeout:
            return "opencode timed out without responding."
        }
    }
}
