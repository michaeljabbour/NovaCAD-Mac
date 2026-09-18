import Foundation

/// Runtime configuration for the AI Assistant's backend. Modeled directly on
/// the earlier internal project's LLM config — same provider/auth/style
/// vocabulary, same env-var-then-persisted-file loading order — so anyone
/// familiar with that project's AI settings feels at home here. NovaCAD
/// supports four provider shapes:
///   - `.anthropic`        — Anthropic's native Messages API, with full
///                           tool-calling (see `AIToolSchema`).
///   - `.openAICompatible` — any generic OpenAI-compatible chat-completions
///                           gateway. Plain chat only, no tool-calling —
///                           matches the earlier project's own documented
///                           limitation for this wire format.
///   - `.opencode`         — shells out to the local `opencode` CLI
///                           headlessly (`opencode run --format json`),
///                           mirroring the earlier project's equivalent
///                           client. Plain chat only.
///   - `.opencodeServer`   — the full **agentic** backend, ported from the
///                           earlier project's agentic server backend per
///                           `Resources/Specs/AI_ASSISTANT_PORTING_GUIDE.md`:
///                           a managed local `opencode serve` subprocess
///                           (`OpenCodeServerClient`/`OpenCodeServerRegistry`),
///                           streamed responses, and round-tripped tool
///                           calls against NovaCAD's OWN drawing tools via
///                           `NovaCADToolBridge`/`NovaCADToolInstaller` (the
///                           same seam that project's executor/bridge/
///                           installer occupy there). This is the ONLY
///                           provider besides `.anthropic` that supports
///                           tool-calling.
/// Deliberately NOT ported: the earlier project's AI-gateway-specific
/// HTTP/WebKit bridges — NovaCAD has no equivalent internal gateway;
/// `.openAICompatible` already covers "point this at an OpenAI-shaped
/// gateway," and the OpenCode server's own provider config (`opencode.json`)
/// is left generic (whatever model/provider the user configures in
/// `opencode`'s own setup) rather than hardcoding a dev/prod environment
/// switch the way the earlier project does.
struct AIConfig: Equatable, Codable {
    var baseURL: String
    var apiKey: String?
    var model: String
    var provider: Provider
    /// OpenCode CLI/Server only — overrides the searched-for binary path.
    var opencodeBinaryPath: String?
    /// OpenCode Server only: named agent to run (passed as the prompt
    /// request's `agent` field). nil/empty uses opencode's default agent.
    var opencodeAgent: String?
    /// OpenCode Server only: preferred port for `opencode serve`. nil picks
    /// a free port automatically at launch (the common case).
    var opencodeServerPort: Int?
    /// OpenCode Server only: whether NovaCAD installs its tool forwarders
    /// (`read_drawing`, `propose_attribute_edits`, …) into the opencode
    /// workspace so the agent can call back into the live drawing. Defaults
    /// to `true` — unlike the earlier project (gated off there pending
    /// internal registry access), NovaCAD has no such network restriction
    /// of its own to model; the
    /// runtime `NovaCADToolInstaller.pluginIsInstalled` check still gates
    /// this safely per-machine regardless of this default.
    var opencodeToolsEnabled: Bool

    init(baseURL: String, apiKey: String?, model: String, provider: Provider,
         opencodeBinaryPath: String?, opencodeAgent: String? = nil,
         opencodeServerPort: Int? = nil, opencodeToolsEnabled: Bool = true) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.provider = provider
        self.opencodeBinaryPath = opencodeBinaryPath
        self.opencodeAgent = opencodeAgent
        self.opencodeServerPort = opencodeServerPort
        self.opencodeToolsEnabled = opencodeToolsEnabled
    }

    // MARK: - Backward-compatible decoding
    //
    // A config saved by an earlier NovaCAD build (before the OpenCode Server
    // fields existed) has no `opencodeAgent`/`opencodeServerPort`/
    // `opencodeToolsEnabled` keys at all — a plain synthesized `Decodable`
    // conformance would fail to decode that persisted blob entirely (the
    // non-optional `opencodeToolsEnabled` has no way to default itself),
    // silently reverting the user to "not configured" on first launch after
    // an update. Decoding each new field with `decodeIfPresent` + a sensible
    // default preserves every pre-existing saved config across the upgrade.
    enum CodingKeys: String, CodingKey {
        case baseURL, apiKey, model, provider, opencodeBinaryPath
        case opencodeAgent, opencodeServerPort, opencodeToolsEnabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        baseURL = try c.decode(String.self, forKey: .baseURL)
        apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey)
        model = try c.decode(String.self, forKey: .model)
        provider = try c.decode(Provider.self, forKey: .provider)
        opencodeBinaryPath = try c.decodeIfPresent(String.self, forKey: .opencodeBinaryPath)
        opencodeAgent = try c.decodeIfPresent(String.self, forKey: .opencodeAgent)
        opencodeServerPort = try c.decodeIfPresent(Int.self, forKey: .opencodeServerPort)
        opencodeToolsEnabled = try c.decodeIfPresent(Bool.self, forKey: .opencodeToolsEnabled) ?? true
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(baseURL, forKey: .baseURL)
        try c.encodeIfPresent(apiKey, forKey: .apiKey)
        try c.encode(model, forKey: .model)
        try c.encode(provider, forKey: .provider)
        try c.encodeIfPresent(opencodeBinaryPath, forKey: .opencodeBinaryPath)
        try c.encodeIfPresent(opencodeAgent, forKey: .opencodeAgent)
        try c.encodeIfPresent(opencodeServerPort, forKey: .opencodeServerPort)
        try c.encode(opencodeToolsEnabled, forKey: .opencodeToolsEnabled)
    }

    enum Provider: String, Equatable, CaseIterable, Codable, Identifiable {
        case anthropic
        case openAICompatible = "openai"
        case opencode
        /// The full agentic backend — see this file's header comment.
        case opencodeServer = "opencode_server"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .anthropic: return "Anthropic"
            case .openAICompatible: return "OpenAI-compatible"
            case .opencode: return "OpenCode CLI"
            case .opencodeServer: return "OpenCode (agentic)"
            }
        }

        /// Anthropic (via `AIClient.runAnthropicToolLoop`) and the OpenCode
        /// server (via `OpenCodeServerRegistry.sendStreaming`, when
        /// `opencodeToolsEnabled` and the plugin are both available) support
        /// tool-calling; plain OpenAI-compatible chat and the one-shot
        /// OpenCode CLI do not.
        var supportsTools: Bool { self == .anthropic || self == .opencodeServer }
    }

    static let anthropicBaseURL = "https://api.anthropic.com/v1"
    static let anthropicDefaultModel = "claude-sonnet-4-5"
    static let openAIDefaultModel = "gpt-4o"
    static let opencodeDefaultModel = ""

    static func anthropicDefaults(apiKey: String? = nil) -> AIConfig {
        AIConfig(baseURL: anthropicBaseURL, apiKey: apiKey, model: anthropicDefaultModel,
                provider: .anthropic, opencodeBinaryPath: nil, opencodeAgent: nil,
                opencodeServerPort: nil, opencodeToolsEnabled: true)
    }

    static func openAIDefaults(baseURL: String = "https://api.openai.com/v1", apiKey: String? = nil) -> AIConfig {
        AIConfig(baseURL: baseURL, apiKey: apiKey, model: openAIDefaultModel,
                provider: .openAICompatible, opencodeBinaryPath: nil, opencodeAgent: nil,
                opencodeServerPort: nil, opencodeToolsEnabled: true)
    }

    static func opencodeDefaults(binaryPath: String? = nil) -> AIConfig {
        AIConfig(baseURL: "", apiKey: nil, model: opencodeDefaultModel,
                provider: .opencode, opencodeBinaryPath: binaryPath, opencodeAgent: nil,
                opencodeServerPort: nil, opencodeToolsEnabled: true)
    }

    static func opencodeServerDefaults(model: String = opencodeDefaultModel, binaryPath: String? = nil,
                                       agent: String? = nil, port: Int? = nil) -> AIConfig {
        AIConfig(baseURL: "", apiKey: nil, model: model, provider: .opencodeServer,
                opencodeBinaryPath: binaryPath, opencodeAgent: agent,
                opencodeServerPort: port, opencodeToolsEnabled: true)
    }

    // MARK: - Persistence
    //
    // Per this feature's product decision, stored as a plain (not Keychain-
    // backed) UserDefaults value — matching `AppSettings`' own existing
    // preference-storage convention (`UserDefaults.standard`, see
    // `DocumentSession.swift`'s `AppSettings` class) rather than introducing
    // a new storage mechanism. Encoded as JSON under one key rather than N
    // separate keys so loading/saving is one atomic read/write.

    private static let defaultsKey = "novacad.aiAssistant.config"

    static func load() -> AIConfig? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let config = try? JSONDecoder().decode(AIConfig.self, from: data)
        else { return nil }
        return config
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }
}
