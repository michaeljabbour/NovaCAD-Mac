import SwiftUI

/// "Attach Xref…" step 2: choose which of the candidate file's layers to
/// bring in. All layers start UNCHECKED (per this feature's product
/// decision — the opposite default from ordinary xref resolution, which
/// always imports every layer) — the user explicitly opts in to each layer
/// they want, with "Select All"/"Select None" for the common bulk cases.
struct XrefAttachSheet: View {
    let fileName: String
    let layerNames: [String]
    @Binding var selected: Set<String>
    let onCancel: () -> Void
    /// "Attach…" — enters click-to-place mode on the canvas.
    let onAttach: () -> Void
    /// "Attach at Origin" — commits immediately at world (0,0), no
    /// placement click required.
    let onAttachAtOrigin: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Attach Xref")
                    .font(.headline)
                Text("Choose which layers of “\(fileName)” to import.")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
            .padding([.top, .horizontal], 16)
            .padding(.bottom, 10)

            Divider()

            HStack {
                Button("Select All") { selected = Set(layerNames) }
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                Button("Select None") { selected = [] }
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                Spacer()
                Text("\(selected.count) of \(layerNames.count) selected")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            List {
                ForEach(layerNames, id: \.self) { name in
                    Toggle(isOn: Binding(
                        get: { selected.contains(name) },
                        set: { on in
                            if on { selected.insert(name) } else { selected.remove(name) }
                        }
                    )) {
                        Text(name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 240, idealHeight: 320)

            Divider()

            HStack {
                Button("Attach at Origin") { onAttachAtOrigin() }
                    .disabled(selected.isEmpty)
                    .help("Attach immediately at world (0,0) — no placement click needed")
                Spacer()
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Attach…") { onAttach() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty)
                    .help("Click a point on the drawing to place this xref")
            }
            .padding(16)
        }
        .frame(width: 420)
    }
}
