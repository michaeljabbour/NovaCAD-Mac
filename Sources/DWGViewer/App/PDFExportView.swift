import SwiftUI
import CADCore
import UniformTypeIdentifiers

struct PDFExportView: View {
    let parsed: EditableParsedDocument
    let visibility: VisibilityState
    let currentSpace: SpaceSelection
    let sourceName: String
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<UInt64> = []
    @State private var model = false
    @State private var paper: PDFPaper = .drawing
    @State private var scale: PDFScale = .pageSetup
    @State private var busy = false
    @State private var progress = ""
    @State private var result: String?
    @State private var outputURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Export Sheets to PDF").font(.title2.bold())
            Text("Each selected sheet becomes a separate PDF page. Drawing colors and lineweights are preserved; CTB/STB styles are not applied.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Select All") { selected = Set(parsed.paperLayouts.map(\.id)) }
                Button("Clear") { selected = []; model = false }
                Spacer()
                Text("\(selected.count + (model ? 1 : 0)) pages")
            }
            List {
                Toggle("Model", isOn: $model)
                ForEach(parsed.paperLayouts) { sheet in
                    Toggle(sheet.name, isOn: Binding(get: { selected.contains(sheet.id) }, set: { value in
                        if value { selected.insert(sheet.id) } else { selected.remove(sheet.id) }
                    }))
                }
            }.frame(height: 230)
            Picker("Paper size", selection: $paper) { ForEach(PDFPaper.allCases) { Text($0.rawValue).tag($0) } }
            Picker("Scale", selection: $scale) { ForEach(PDFScale.allCases) { Text($0.rawValue).tag($0) } }
            if scale != .fit { Text("Actual scale can crop content outside the page. Fit to page changes the scale to include all content.").font(.caption).foregroundStyle(.secondary) }
            if busy { ProgressView(progress).controlSize(.small) }
            if let result { ScrollView { Text(result).font(.caption).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 120) }
            HStack {
                if let outputURL { Button("Show PDF in Finder") { NSWorkspace.shared.activateFileViewerSelecting([outputURL]) } }
                Spacer()
                Button(outputURL == nil ? "Cancel" : "Done") { dismiss() }.keyboardShortcut(.cancelAction).disabled(busy)
                Button("Export…", action: export).keyboardShortcut(.defaultAction).disabled(busy || (selected.isEmpty && !model))
            }
        }.padding(24).frame(width: 610).disabled(busy)
        .onAppear {
            if currentSpace == .paper, let id = parsed.activePaperLayoutID { selected = [id] } else { model = true; scale = .fit }
        }
    }
    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = sourceName + ".pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let snapshot = parsed.detachedSnapshot()
        let sheets: [UInt64?] = (model ? [nil] : []) + parsed.paperLayouts.filter { selected.contains($0.id) }.map { Optional($0.id) }
        let options = PDFExportOptions(sheets: sheets, paper: paper, scale: scale, visibility: visibility)
        busy = true; result = nil; progress = "Preparing sheets…"
        Task.detached(priority: .userInitiated) {
            do {
                let warnings = try SheetPDFExporter.write(snapshot, to: url, options: options) { page, total in
                    Task { @MainActor in progress = "Page \(page) of \(total)" }
                }
                await MainActor.run { busy = false; outputURL = url; result = "Exported \(sheets.count) pages." + (warnings.isEmpty ? "" : "\n" + warnings.joined(separator: "\n")) }
            } catch { await MainActor.run { busy = false; result = error.localizedDescription } }
        }
    }
}
