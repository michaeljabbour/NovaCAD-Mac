import SwiftUI
import AppKit

struct FileDispatch {
    var ready: Bool
    var open: () -> Void
    var openURL: (URL) -> Void
    var newTab: () -> Void
    var close: () -> Void
    var save: () -> Void
    var saveAs: () -> Void
    var reload: () -> Void
    var exportPDF: () -> Void
    var exportMarkup: () -> Void
    var recover: () -> Void
}
private struct FileDispatchKey: FocusedValueKey { typealias Value = FileDispatch }
extension FocusedValues {
    var novaCADFileDispatch: FileDispatch? {
        get { self[FileDispatchKey.self] }
        set { self[FileDispatchKey.self] = newValue }
    }
}

struct FileMenuItems: View {
    let dispatch: FileDispatch?
    var body: some View {
        Button("New Tab") { dispatch?.newTab() }.keyboardShortcut("t", modifiers: .command)
        Button("Open…") { dispatch?.open() }.keyboardShortcut("o", modifiers: .command)
        Menu("Open Recent") {
            let recent = NSDocumentController.shared.recentDocumentURLs
            ForEach(recent, id: \.self) { url in
                Button(url.lastPathComponent) { dispatch?.openURL(url) }.help(url.path)
            }
            if recent.isEmpty { Text("No recent drawings") }
            Divider()
            Button("Clear Menu") { NSDocumentController.shared.clearRecentDocuments(nil) }
        }
        Divider()
        Button("Save") { dispatch?.save() }.keyboardShortcut("s", modifiers: .command)
            .disabled(!(dispatch?.ready ?? false))
        Button("Save As…") { dispatch?.saveAs() }.keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(!(dispatch?.ready ?? false))
        Button("Reload from Disk…") { dispatch?.reload() }.disabled(!(dispatch?.ready ?? false))
        Divider()
        Button("Export Sheets to PDF…") { dispatch?.exportPDF() }.keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(!(dispatch?.ready ?? false))
        Button("Export Markup as DXF…") { dispatch?.exportMarkup() }.disabled(!(dispatch?.ready ?? false))
        Button("Recover Unsaved Drawings…") { dispatch?.recover() }
        Divider()
        Button("Close Tab") { dispatch?.close() }.keyboardShortcut("w", modifiers: .command)
    }
}

struct RecoveryBrowser: View {
    let open: (RecoveryEntry) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var entries = RecoveryStore.entries()
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Recover Unsaved Drawings").font(.title2.bold())
            Text("Recovery copies contain your edits. Opening one leaves the original drawing unchanged.")
                .foregroundStyle(.secondary)
            if entries.isEmpty { Text("No recovery copies available.").padding(.vertical, 30) }
            List(entries) { entry in
                HStack {
                    VStack(alignment: .leading) {
                        Text(entry.displayName).fontWeight(.medium)
                        Text(entry.savedAt, style: .date) + Text(" · ") + Text(entry.savedAt, style: .time)
                        if !entry.warnings.isEmpty { Text("Saved with \(entry.warnings.count) compatibility warnings").foregroundStyle(.orange) }
                    }
                    Spacer()
                    Button("Open Recovery") { dismiss(); open(entry) }
                }.padding(.vertical, 5)
            }.frame(minHeight: 180)
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
        }.padding(24).frame(width: 580)
    }
}
