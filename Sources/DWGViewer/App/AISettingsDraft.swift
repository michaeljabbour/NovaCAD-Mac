import Foundation

/// Pure, testable state behind `AISettingsView`.
///
/// `AISettingsView` previously held each backend field in its own `@State` and
/// re-applied provider defaults from `.onChange(of: provider)`. Loading a saved
/// config programmatically changed `provider`, so SwiftUI fired `.onChange`
/// after `load()` returned and `applyProviderDefaults` clobbered the
/// just-loaded `model` (and, for anthropic/OpenAI, `baseURL`) — silently
/// discarding the user's saved model on the next Save. Keeping the state here
/// separates the two paths: `loaded(from:)` preserves a saved config verbatim,
/// while `selectProvider(_:)` is applied only by explicit user selection.
struct AISettingsDraft: Equatable {
    var provider: AIConfig.Provider = .anthropic
    var baseURL: String = AIConfig.anthropicBaseURL
    var model: String = AIConfig.anthropicDefaultModel
    var apiKey: String = ""
    var opencodeBinaryPath: String = ""
    var opencodeAgent: String = ""
    var opencodeServerPort: String = ""
    var opencodeToolsEnabled: Bool = true

    /// Assigns every field from `config` — never applies provider defaults, so
    /// a saved `model`/`baseURL` survives verbatim.
    static func loaded(from config: AIConfig) -> AISettingsDraft {
        AISettingsDraft(provider: config.provider,
                        baseURL: config.baseURL,
                        model: config.model,
                        apiKey: config.apiKey ?? "",
                        opencodeBinaryPath: config.opencodeBinaryPath ?? "",
                        opencodeAgent: config.opencodeAgent ?? "",
                        opencodeServerPort: config.opencodeServerPort.map(String.init) ?? "",
                        opencodeToolsEnabled: config.opencodeToolsEnabled)
    }

    /// User-selection path: switches provider and applies that provider's
    /// field defaults.
    mutating func selectProvider(_ provider: AIConfig.Provider) {
        self.provider = provider
        switch provider {
        case .anthropic:
            baseURL = AIConfig.anthropicBaseURL
            model = AIConfig.anthropicDefaultModel
        case .openAICompatible:
            baseURL = "https://api.openai.com/v1"
            model = AIConfig.openAIDefaultModel
        case .opencode:
            model = AIConfig.opencodeDefaultModel
        case .opencodeServer:
            model = AIConfig.opencodeDefaultModel
        }
    }

    func makeConfig() -> AIConfig {
        AIConfig(baseURL: baseURL,
                 apiKey: apiKey.isEmpty ? nil : apiKey,
                 model: model,
                 provider: provider,
                 opencodeBinaryPath: opencodeBinaryPath.isEmpty ? nil : opencodeBinaryPath,
                 opencodeAgent: opencodeAgent.isEmpty ? nil : opencodeAgent,
                 opencodeServerPort: Int(opencodeServerPort),
                 opencodeToolsEnabled: opencodeToolsEnabled)
    }
}
