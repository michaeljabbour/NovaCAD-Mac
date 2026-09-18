import SwiftUI
import CADCore
import AppKit

/// AutoCAD-style "Select Color" dialog: the full 255-entry ACI index-color
/// grid plus a True Color (custom RGB) picker. Used by Layer Properties'
/// color swatch (and reusable anywhere else a full ACI picker is needed —
/// the existing `markupPalette` menu in `PropertiesPanel.swift` is a
/// deliberately separate, curated 9-color "quick pick" and is left as-is).
///
/// Presented via `.sheet(item:)`/`.sheet(isPresented:)` by the caller; this
/// view itself only needs the CURRENT color (to pre-select/highlight it) and
/// an `onApply` callback — it has no knowledge of layers/entities/undo.
struct SelectColorDialog: View {
    let title: String
    let initial: ResolvedColor
    let onApply: (ResolvedColor) -> Void
    let onCancel: () -> Void

    @State private var choice: ColorChoice
    @State private var customColor: Color
    /// Drives the theme-aware header-preview circle — see `body`'s use of
    /// `swatchDisplayRGB(darkBackground:)` below. Without this, ACI 7
    /// ("foreground" — the single most common color in a real drawing)
    /// always rendered as literal white via `ACIPalette.rgb(forACI: 7)`,
    /// which is invisible against this dialog's own light background: the
    /// reported "the thumbnail/square always shows white" bug.
    @Environment(\.colorScheme) private var colorScheme

    init(title: String, initial: ResolvedColor,
         onApply: @escaping (ResolvedColor) -> Void, onCancel: @escaping () -> Void) {
        self.title = title
        self.initial = initial
        self.onApply = onApply
        self.onCancel = onCancel
        let c = ColorChoice(resolved: initial)
        _choice = State(initialValue: c)
        _customColor = State(initialValue: Color(rgb: c.previewRGB))
    }

    /// Internal selection model — bridges `ResolvedColor` (only
    /// `.foreground`/`.rgb(_)`) to "which ACI index (if any) is highlighted
    /// in the grid" so the grid can show an exact-match selection outline
    /// even though `ResolvedColor` itself only stores a raw RGB.
    enum ColorChoice: Equatable {
        case aci(Int)            // 1...255; 7 maps to/from `.foreground`
        case trueColor(UInt32)

        init(resolved: ResolvedColor) {
            switch resolved {
            case .foreground:
                self = .aci(7)
            case .rgb(let v):
                let idx = ACIPalette.nearestACI(forRGB: v)
                self = (ACIPalette.rgb(forACI: idx) == v) ? .aci(idx) : .trueColor(v)
            }
        }

        var resolvedColor: ResolvedColor {
            switch self {
            case .aci(7): return .foreground
            case .aci(let i): return .rgb(ACIPalette.rgb(forACI: i))
            case .trueColor(let v): return .rgb(v)
            }
        }

        var previewRGB: UInt32 {
            switch self {
            case .aci(let i): return ACIPalette.rgb(forACI: i)
            case .trueColor(let v): return v
            }
        }

        var label: String {
            switch self {
            case .aci(7): return "White (ByLayer default)"
            case .aci(let i): return "Index Color \(i)"
            case .trueColor(let v): return String(format: "True Color #%06X", v & 0xFFFFFF)
            }
        }
    }

    private let columns = Array(repeating: GridItem(.flexible(minimum: 16, maximum: 22), spacing: 3), count: 17)

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Circle()
                    .fill(Color(rgb: choice.resolvedColor.swatchDisplayRGB(darkBackground: colorScheme == .dark)))
                    .frame(width: 20, height: 20)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.3), lineWidth: 0.5))
                Text(choice.label)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding([.top, .horizontal], 16)
            .padding(.bottom, 8)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Index Color (ACI 1–255)")
                            .font(.caption).foregroundColor(.secondary)
                        LazyVGrid(columns: columns, spacing: 3) {
                            ForEach(1...255, id: \.self) { aci in
                                aciSwatch(aci)
                            }
                        }
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 6) {
                        Text("True Color")
                            .font(.caption).foregroundColor(.secondary)
                        HStack(spacing: 10) {
                            ColorPicker("", selection: customColorBinding, supportsOpacity: false)
                                .labelsHidden()
                            Text(String(format: "#%06X", customColor.rgbValue))
                                .font(.system(.callout, design: .monospaced))
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                    }
                }
                .padding(16)
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("OK") { onApply(choice.resolvedColor) }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 440, height: 520)
    }

    private func aciSwatch(_ aci: Int) -> some View {
        let isSelected = choice == .aci(aci)
        return RoundedRectangle(cornerRadius: 2)
            .fill(Color(rgb: ACIPalette.rgb(forACI: aci)))
            .frame(width: 18, height: 18)
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.15),
                                  lineWidth: isSelected ? 2 : 0.5)
            )
            .contentShape(Rectangle())
            .onTapGesture { choice = .aci(aci) }
            .help("ACI \(aci)")
    }

    private var customColorBinding: Binding<Color> {
        Binding(
            get: { customColor },
            set: { newValue in
                customColor = newValue
                choice = .trueColor(newValue.rgbValue)
            }
        )
    }
}

private extension Color {
    /// Best-effort RGB extraction via `NSColor` — used only for the True
    /// Color picker's hex readout / round trip into a `ResolvedColor.rgb`.
    var rgbValue: UInt32 {
        guard let converted = NSColor(self).usingColorSpace(.deviceRGB) else { return 0xFFFFFF }
        let r = UInt32((converted.redComponent * 255).rounded())
        let g = UInt32((converted.greenComponent * 255).rounded())
        let b = UInt32((converted.blueComponent * 255).rounded())
        return (r << 16) | (g << 8) | b
    }
}
