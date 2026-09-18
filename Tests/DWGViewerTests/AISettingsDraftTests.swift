import XCTest
@testable import DWGViewer

/// Tests for `AISettingsDraft` — the pure state object behind `AISettingsView`.
///
/// Regression context: the view used to hold each field in its own `@State`
/// and re-apply provider defaults from `.onChange(of: provider)`. Loading a
/// saved config (`provider = config.provider` …) programmatically changed
/// `provider`, so SwiftUI fired `.onChange` right after `load()` returned and
/// `applyProviderDefaults` clobbered the just-loaded `model` (and, for
/// anthropic/OpenAI, `baseURL`). Opening AI Settings on a saved
/// `.opencodeServer` config (e.g. model "example/model-id") and
/// clicking Save then persisted an empty model. The draft makes loading and
/// user-selection distinct, testable paths.
final class AISettingsDraftTests: XCTestCase {

    // MARK: - Loading a saved config

    func testLoadingSavedServerConfigPreservesModelAndBaseURL() {
        let config = AIConfig.opencodeServerDefaults(model: "example/model-id")
        let draft = AISettingsDraft.loaded(from: config)

        XCTAssertEqual(draft.provider, .opencodeServer)
        XCTAssertEqual(draft.model, "example/model-id",
                       "loading must preserve the saved model verbatim, never re-apply provider defaults")
        XCTAssertEqual(draft.baseURL, "",
                       "loading must preserve the saved baseURL verbatim")
    }

    func testLoadingPreservesApiKeyBinaryAgentPortAndToolsFlag() {
        let config = AIConfig(baseURL: "https://example.test/v1",
                              apiKey: "sk-test-123",
                              model: "some-model",
                              provider: .opencodeServer,
                              opencodeBinaryPath: "/opt/homebrew/bin/opencode",
                              opencodeAgent: "build",
                              opencodeServerPort: 4599,
                              opencodeToolsEnabled: false)
        let draft = AISettingsDraft.loaded(from: config)

        XCTAssertEqual(draft.apiKey, "sk-test-123")
        XCTAssertEqual(draft.opencodeBinaryPath, "/opt/homebrew/bin/opencode")
        XCTAssertEqual(draft.opencodeAgent, "build")
        XCTAssertEqual(draft.opencodeServerPort, "4599")
        XCTAssertFalse(draft.opencodeToolsEnabled)

        let roundTripped = draft.makeConfig()
        XCTAssertEqual(roundTripped.apiKey, "sk-test-123")
        XCTAssertEqual(roundTripped.opencodeBinaryPath, "/opt/homebrew/bin/opencode")
        XCTAssertEqual(roundTripped.opencodeAgent, "build")
        XCTAssertEqual(roundTripped.opencodeServerPort, 4599)
        XCTAssertFalse(roundTripped.opencodeToolsEnabled)
    }

    // MARK: - User-selection path

    func testSelectingProviderAppliesDefaults() {
        let draft = AISettingsDraft.loaded(from: .opencodeServerDefaults())

        var anthropic = draft
        anthropic.selectProvider(.anthropic)
        XCTAssertEqual(anthropic.baseURL, AIConfig.anthropicBaseURL)
        XCTAssertEqual(anthropic.model, AIConfig.anthropicDefaultModel)

        var openAI = anthropic
        openAI.selectProvider(.openAICompatible)
        XCTAssertEqual(openAI.baseURL, "https://api.openai.com/v1")
        XCTAssertEqual(openAI.model, AIConfig.openAIDefaultModel)

        var opencodeCLI = openAI
        opencodeCLI.selectProvider(.opencode)
        XCTAssertEqual(opencodeCLI.model, AIConfig.opencodeDefaultModel)
        XCTAssertEqual(opencodeCLI.baseURL, "https://api.openai.com/v1",
                       "opencode must leave baseURL untouched")

        var server = opencodeCLI
        server.selectProvider(.opencodeServer)
        XCTAssertEqual(server.model, AIConfig.opencodeDefaultModel)
        XCTAssertEqual(server.baseURL, "https://api.openai.com/v1",
                       "opencodeServer must leave baseURL untouched")
    }

    // MARK: - makeConfig()

    func testMakeConfigOmitsEmptyOptionalStrings() {
        let draft = AISettingsDraft()

        let config = draft.makeConfig()
        XCTAssertNil(config.apiKey, "empty apiKey must map to nil")
        XCTAssertNil(config.opencodeBinaryPath, "empty binary path must map to nil")
        XCTAssertNil(config.opencodeAgent, "empty agent must map to nil")
        XCTAssertNil(config.opencodeServerPort, "empty port must map to nil")

        var configured = draft
        configured.apiKey = "sk-abc"
        configured.opencodeBinaryPath = "/usr/local/bin/opencode"
        configured.opencodeAgent = "plan"
        configured.opencodeServerPort = "5599"
        configured.opencodeToolsEnabled = false

        let full = configured.makeConfig()
        XCTAssertEqual(full.apiKey, "sk-abc")
        XCTAssertEqual(full.opencodeBinaryPath, "/usr/local/bin/opencode")
        XCTAssertEqual(full.opencodeAgent, "plan")
        XCTAssertEqual(full.opencodeServerPort, 5599)
        XCTAssertFalse(full.opencodeToolsEnabled)
    }

    // MARK: - Selection defaults must never re-fire on load

    func testSelectingProviderThenLoadingAgainKeepsLoadedValues() {
        var draft = AISettingsDraft()
        draft.selectProvider(.opencodeServer)
        XCTAssertEqual(draft.model, AIConfig.opencodeDefaultModel)

        let saved = AIConfig.opencodeServerDefaults(model: "example/model-id")
        draft = .loaded(from: saved)

        XCTAssertEqual(draft.model, "example/model-id",
                       "a load after a provider selection must not re-apply selection defaults")
        XCTAssertEqual(draft.baseURL, saved.baseURL)
        XCTAssertEqual(draft.provider, .opencodeServer)
    }
}
