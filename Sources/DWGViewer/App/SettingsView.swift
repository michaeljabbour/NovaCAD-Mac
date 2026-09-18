import SwiftUI
import CADCore

/// The app's Settings pane (NovaCAD ▸ Settings…, ⌘,). Controls the persistent
/// DWG→DXF conversion cache: enable/disable, where it lives, how big it is, and
/// a manual clear.
struct SettingsView: View {
    @AppStorage("dwgCacheEnabled") private var cacheEnabled = true

    @State private var cacheSizeText = "…"
    @State private var locationText = ""
    @State private var isCustomLocation = false
    @State private var clearedMessage: String?

    var body: some View {
        Form {
            Section("DWG → DXF Conversion Cache") {
                Toggle("Reuse converted DXF files between sessions", isOn: $cacheEnabled)
                    .help("When on, opening a folder of DWG drawings converts each "
                          + "drawing once and reuses the result next time. Only "
                          + "drawings that changed on disk are re-converted.")

                LabeledContent("Location") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(locationText)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                        HStack {
                            Button("Choose Folder…") { chooseFolder() }
                            if isCustomLocation {
                                Button("Use Automatic") {
                                    DWGCache.setUserChosenRoot(nil)
                                    refresh()
                                }
                            }
                        }
                    }
                }

                LabeledContent("Cache size") {
                    HStack(spacing: 10) {
                        Text(cacheSizeText).foregroundStyle(.secondary)
                        Button("Clear Cache…") { clearCache() }
                        if let msg = clearedMessage {
                            Text(msg).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .padding()
        .onAppear(perform: refresh)
    }

    private func refresh() {
        let root = DWGCache.root()
        locationText = root.path
        isCustomLocation = DWGCache.userChosenRoot() != nil
        cacheSizeText = byteString(DWGCache.currentSize())
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use This Folder"
        panel.message = "Choose where NovaCAD stores converted DXF files."
        if panel.runModal() == .OK, let url = panel.url {
            DWGCache.setUserChosenRoot(url)
            refresh()
        }
    }

    private func clearCache() {
        let alert = NSAlert()
        alert.messageText = "Clear the DWG → DXF cache?"
        alert.informativeText = "The next time you open a DWG drawing folder it will "
            + "be re-converted. This can take a few minutes for large drawing sets."
        alert.addButton(withTitle: "Clear Cache")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let freed = DWGCache.clearAll()
        clearedMessage = "Freed \(byteString(freed))"
        refresh()
    }

    private func byteString(_ bytes: UInt64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: Int64(bytes))
    }
}
