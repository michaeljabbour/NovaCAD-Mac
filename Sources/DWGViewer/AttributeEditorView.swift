import SwiftUI

/// Phase 6.1: minimal attribute editor sheet — "driven by
/// `store.children(of: insertId)`" per the plan's exact spec text. Opened by
/// a double-click on an INSERT with ATTRIBs, or the ATTEDIT command
/// (`ContentView.startAttedit`/`commitAttEditPick`).
///
/// Deliberately minimal (a plain list of tag/value rows + Save/Cancel), not
/// a full AutoCAD-parity "Enhanced Attribute Editor" (text style/properties
/// tabs) — the plan's own 6.1 scope is "minimal sheet," and a richer editor
/// is a natural follow-up once Phase 7's property grid exists to share
/// styling infrastructure with.
struct AttributeEditorView: View {
    let insertId: EntityID
    @ObservedObject var session: DocumentSession
    let regen: RegenCoordinator
    let onDismiss: () -> Void

    /// Local editing buffer — tag -> in-progress value. Populated once on
    /// appear from `BlockEditor.attributes(of:in:)`; committed to the store
    /// (via ONE transaction covering every changed attribute) only on Save,
    /// so Cancel is a true no-op regardless of how many fields were edited.
    @State private var rows: [(tag: String, id: EntityID)] = []
    @State private var values: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Attributes").font(.headline)
            if rows.isEmpty {
                Text("This block reference has no attributes.")
                    .foregroundColor(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(rows, id: \.id) { row in
                            HStack {
                                Text(row.tag)
                                    .frame(width: 120, alignment: .leading)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                TextField("Value", text: Binding(
                                    get: { values[row.tag] ?? "" },
                                    set: { values[row.tag] = $0 }))
                                    .textFieldStyle(.roundedBorder)
                            }
                        }
                    }
                }
                .frame(maxHeight: 300)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onDismiss() }
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(rows.isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 360)
        .onAppear {
            let attrs = BlockEditor.attributes(of: insertId, in: regen.parsed.store)
            rows = attrs.map { (tag: $0.tag, id: $0.id) }
            values = Dictionary(uniqueKeysWithValues: attrs.map { ($0.tag, $0.value) })
        }
    }

    /// Commits every changed tag's value in ONE transaction — matches the
    /// project's own "one transaction for the whole edit" convention (e.g.
    /// the property-grid design in the plan's Phase 7 text, applied here
    /// early since attribute editing is the same shape of operation).
    private func save() {
        session.performEdit("Edit Attributes") { tx in
            for row in rows {
                guard let newValue = values[row.tag] else { continue }
                _ = BlockEditor.setAttribute(insertId, tag: row.tag, value: newValue,
                                             in: regen.parsed, tx: tx)
            }
        }
        onDismiss()
    }
}
