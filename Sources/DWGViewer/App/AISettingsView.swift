import SwiftUI

/// NovaCAD ▸ Settings ▸ AI Assistant — configures the AI Assistant's backend
/// (see `AIConfig`'s own header comment for the four supported provider
/// shapes, including the ported `.opencodeServer` agentic backend). Modeled
/// on the earlier internal project's settings sheet (provider picker, model
/// field, API key field, Test Connection), extended with the
/// OpenCode-Server-specific fields (agent, port, tools-enabled) per
/// `Resources/Specs/AI_ASSISTANT_PORTING_GUIDE.md`.
///
/// All field state lives in `AISettingsDraft` rather than one `@State` per
/// field: the old per-field state plus `.onChange(of: provider)` re-applied
/// provider defaults after `load()` assigned `provider` programmatically
/// (SwiftUI fires `.onChange` after the body update that follows the
/// assignment), clobbering the just-loaded model/baseURL. The picker's custom
/// binding routes ONLY user selection through `selectProvider(_:)`; loading
/// uses `loaded(from:)`, which preserves every saved value verbatim.
struct AISettingsView: View {
    @State private var draft = AISettingsDraft()
    @State private var testStatus: String?
    @State private var isTesting = false

    var body: some View {
        Form {
            Section("AI Assistant Backend") {
                Picker("Provider", selection: Binding(get: { draft.provider },
                                                       set: { draft.selectProvider($0) })) {
                    ForEach(AIConfig.Provider.allCases) { p in
                        Text(p.displayName).tag(p)
                    }
                }

                switch draft.provider {
                case .anthropic, .openAICompatible:
                    TextField("Base URL", text: $draft.baseURL)
                    TextField("Model", text: $draft.model)
                    SecureField("API Key", text: $draft.apiKey)
                    Text("Stored locally in this Mac's preferences (not Keychain-protected).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .opencode:
                    TextField("Model (optional, e.g. anthropic/claude-sonnet-4-5)", text: $draft.model)
                    TextField("opencode binary path (optional — auto-detected if blank)", text: $draft.opencodeBinaryPath)
                    Text("Plain chat only — one-shot `opencode run`, no tool-calling.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .opencodeServer:
                    opencodeServerFields
                }

                HStack {
                    Button("Test Connection") { test() }
                        .disabled(isTesting)
                    if isTesting { ProgressView().controlSize(.small) }
                    if let testStatus { Text(testStatus).font(.caption).foregroundStyle(.secondary) }
                }

                HStack {
                    Spacer()
                    Button("Disconnect") { disconnect() }
                    Button("Save") { save() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .padding()
        .onAppear(perform: load)
    }

    /// The OpenCode (agentic) provider's fields — a managed `opencode serve`
    /// subprocess with tool-calling against the live drawing (see
    /// `OpenCodeServerClient.swift`/`NovaCADToolBridge.swift`/
    /// `NovaCADToolInstaller.swift`).
    @ViewBuilder
    private var opencodeServerFields: some View {
        TextField("Model (optional, e.g. anthropic/claude-sonnet-4-5)", text: $draft.model)
        TextField("opencode binary path (optional — auto-detected if blank)", text: $draft.opencodeBinaryPath)
        TextField("Agent (optional — opencode's default agent if blank)", text: $draft.opencodeAgent)
        TextField("Server port (optional — auto-selected if blank)", text: $draft.opencodeServerPort)
        Toggle("Enable drawing tools (read_drawing, propose_attribute_edits, …)", isOn: $draft.opencodeToolsEnabled)

        HStack(spacing: 6) {
            Image(systemName: NovaCADToolInstaller.pluginIsInstalled ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundColor(NovaCADToolInstaller.pluginIsInstalled ? .green : .orange)
            Text(NovaCADToolInstaller.pluginIsInstalled
                 ? "@opencode-ai/plugin is installed — tool-calling is available."
                 : "@opencode-ai/plugin is NOT installed — tools will run text-only until it's added.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Text("Requires the `opencode` CLI and, for tool-calling, `npm install @opencode-ai/plugin` "
             + "inside \(OpenCodeWorkspace.directory.path)/.opencode/. "
             + "The richest backend: durable sessions, streamed responses, and tool calls against this drawing.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func load() {
        guard let config = AIConfig.load() else { return }
        draft = .loaded(from: config)
    }

    private func currentConfig() -> AIConfig {
        draft.makeConfig()
    }

    private func save() {
        currentConfig().save()
        testStatus = "Saved."
    }

    private func disconnect() {
        AIConfig.clear()
        draft.apiKey = ""
        testStatus = "Disconnected."
    }

    private func test() {
        isTesting = true
        testStatus = nil
        let config = currentConfig()
        Task { @MainActor in
            defer { isTesting = false }
            do {
                let client = AIClient(config: config)
                let reply = try await client.complete(messages: [
                    AIMessage(role: .user, content: "Reply with exactly: OK")
                ])
                testStatus = "Connected — reply: \(reply.prefix(60))"
            } catch {
                testStatus = error.localizedDescription
            }
        }
    }
}
