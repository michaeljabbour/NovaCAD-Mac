import SwiftUI

/// "Extract Data…" step 2: choose which columns to include in the CSV, and
/// drag to reorder them (first row = leftmost column). Presented BEFORE the
/// save panel — the user picks columns first, then chooses where to save,
/// matching `XrefAttachSheet`'s own "configure, then commit" two-step shape.
///
/// All columns start CHECKED (the opposite default from `XrefAttachSheet`'s
/// layer picker) since the pre-existing behavior — before this feature
/// existed — was always "every column, every time"; defaulting to
/// everything selected means a user who doesn't care about filtering can
/// just click "Export" immediately with zero extra steps, identical to the
/// old one-click flow.
struct DataExtractionColumnPicker: View {
    /// Every candidate column name, in a stable canonical order (see
    /// `DataExtraction.availableColumns(for:)`) — used as the master list;
    /// `order`/`selected` below are the user's current customization of it.
    let allColumns: [String]
    /// The user's chosen SUBSET and ORDER — starts as `allColumns` (every
    /// column, unfiltered order) and is freely reordered/pruned via the
    /// list below. This is exactly what gets passed to
    /// `DataExtraction.csv(for:columns:)`.
    @State private var order: [String]
    @State private var selected: Set<String>

    let onCancel: () -> Void
    let onExport: ([String]) -> Void

    init(allColumns: [String], onCancel: @escaping () -> Void, onExport: @escaping ([String]) -> Void) {
        self.allColumns = allColumns
        self._order = State(initialValue: allColumns)
        self._selected = State(initialValue: Set(allColumns))
        self.onCancel = onCancel
        self.onExport = onExport
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Extract Data").font(.headline)
                Text("Choose which columns to include and drag to reorder them (top = first column).")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
            .padding([.top, .horizontal], 16)
            .padding(.bottom, 10)

            Divider()

            HStack {
                Button("Select All") { selected = Set(allColumns) }
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                Button("Select None") { selected = [] }
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                Spacer()
                Text("\(selected.count) of \(allColumns.count) selected")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()

            List {
                ForEach(order, id: \.self) { column in
                    HStack {
                        Image(systemName: "line.3.horizontal")
                            .foregroundColor(.secondary.opacity(0.5))
                            .help("Drag to reorder")
                        Toggle(isOn: Binding(
                            get: { selected.contains(column) },
                            set: { on in if on { selected.insert(column) } else { selected.remove(column) } }
                        )) {
                            Text(column.isEmpty ? "(unnamed)" : column)
                        }
                    }
                }
                .onMove { indices, newOffset in
                    order.move(fromOffsets: indices, toOffset: newOffset)
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 280)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Export…") {
                    onExport(order.filter { selected.contains($0) })
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 420, height: 500)
    }
}
