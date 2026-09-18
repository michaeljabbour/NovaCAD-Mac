import SwiftUI
import CADCore

/// "Layer Settings…" sheet — AutoCAD's Layer Properties Manager reduced to
/// the two properties this app lets a user change per layer: color and
/// transparency. Folds the existing `SelectColorDialog` swatch grid in as a
/// nested sheet (rather than duplicating the ACI grid here) so a user
/// changing a layer's look has ONE entry point instead of two separate
/// right-click menu items to remember.
///
/// Transparency (0-100%, AutoCAD's own convention: 0 = fully opaque, 100 =
/// fully invisible-but-still-selectable/snappable — a DIFFERENT axis from
/// FREEZE/OFF, which actually removes the layer from hit-testing) is a plain
/// slider bound to a live preview swatch, so the user sees the resulting
/// alpha before committing. Committed on "Done" (not live per-drag-tick),
/// matching every other layer-table mutation in this codebase
/// (`setLayerColor`/`setLayerTransparency`) being ONE undo step rather than
/// one per intermediate value — a slider dragged from 0 to 80 must not
/// leave 80 individual undo steps behind it.
struct LayerSettingsDialog: View {
    /// Theme-aware color swatch — see `ResolvedColor.swatchDisplayRGB`.
    @Environment(\.colorScheme) private var colorScheme
    let layerName: String
    let initialColor: ResolvedColor
    let initialTransparency: Double   // 0...100
    let onApply: (ResolvedColor, Double) -> Void
    let onCancel: () -> Void

    @State private var color: ResolvedColor
    @State private var transparency: Double
    @State private var showingColorPicker = false

    init(layerName: String, initialColor: ResolvedColor, initialTransparency: Double,
        onApply: @escaping (ResolvedColor, Double) -> Void, onCancel: @escaping () -> Void) {
        self.layerName = layerName
        self.initialColor = initialColor
        self.initialTransparency = initialTransparency
        self.onApply = onApply
        self.onCancel = onCancel
        _color = State(initialValue: initialColor)
        _transparency = State(initialValue: initialTransparency)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Layer Settings — \(layerName)").font(.headline)
                Spacer()
            }
            .padding([.top, .horizontal], 16)
            .padding(.bottom, 12)

            Divider()

            VStack(alignment: .leading, spacing: 18) {
                // Color
                VStack(alignment: .leading, spacing: 6) {
                    Text("Color").font(.caption).foregroundColor(.secondary)
                    Button {
                        showingColorPicker = true
                    } label: {
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color(rgb: color.swatchDisplayRGB(darkBackground: colorScheme == .dark)))
                                .frame(width: 20, height: 20)
                                .overlay(RoundedRectangle(cornerRadius: 3)
                                    .strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))
                            Text(colorLabel)
                                .font(.callout)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                // Transparency
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Transparency").font(.caption).foregroundColor(.secondary)
                        Spacer()
                        Text("\(Int(transparency.rounded()))%")
                            .font(.caption).monospacedDigit().foregroundColor(.secondary)
                    }
                    HStack(spacing: 10) {
                        Image(systemName: "circle.righthalf.filled")
                            .foregroundColor(.secondary)
                            .font(.caption)
                        Slider(value: $transparency, in: 0...100, step: 1)
                        // A live preview swatch at the CURRENT transparency
                        // (checkerboard behind it so 100% reads as fully
                        // see-through rather than indistinguishable from a
                        // plain white/empty swatch).
                        ZStack {
                            checkerboard
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color(rgb: color.swatchDisplayRGB(darkBackground: colorScheme == .dark)).opacity(1 - transparency / 100))
                        }
                        .frame(width: 28, height: 20)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .overlay(RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))
                    }
                    Text("0% is fully opaque; 100% is fully see-through. Entities on this layer stay selectable and snappable regardless of transparency.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .padding(16)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Done") { onApply(color, transparency) }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 360)
        .sheet(isPresented: $showingColorPicker) {
            SelectColorDialog(
                title: "Layer Color — \(layerName)",
                initial: color,
                onApply: { newColor in
                    color = newColor
                    showingColorPicker = false
                },
                onCancel: { showingColorPicker = false }
            )
        }
    }

    private var colorLabel: String {
        switch color {
        case .foreground: return "White (ByLayer default)"
        case .rgb(let v): return String(format: "#%06X", v & 0xFFFFFF)
        }
    }

    /// A small tiled checkerboard, the standard "this is transparent" cue —
    /// drawn as a fixed 4x2 grid rather than a computed tile size, since the
    /// swatch itself is a fixed 28x20.
    private var checkerboard: some View {
        VStack(spacing: 0) {
            ForEach(0..<4, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<7, id: \.self) { col in
                        Rectangle()
                            .fill((row + col).isMultiple(of: 2) ? Color.gray.opacity(0.35) : Color.gray.opacity(0.15))
                    }
                }
            }
        }
    }
}
