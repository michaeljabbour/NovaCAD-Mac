import SwiftUI
import CADCore

/// On-canvas format switcher for a selected DIMENSION entity — per explicit
/// product requirement, this control lives directly on the drawing canvas
/// (as a small floating badge, near the top-left of the viewport whenever
/// exactly one NovaCAD-authored dimension is selected), NOT inside the
/// Properties panel. Lets the user change ONE dimension's own format
/// (decimal/architectural/engineering/etc, unit system, precision)
/// independent of the drawing's global Units preference — see
/// `DimensionTool.swift`'s header comment for the full per-dimension-
/// override design rationale.
struct DimensionFormatBadge: View {
    let current: MeasureFormat
    let onChange: (MeasureFormat) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "ruler").foregroundColor(.accentColor)
            Text("Dimension Format").font(.caption).bold()

            Picker("", selection: styleBinding) {
                ForEach(LengthStyle.allCases) { style in
                    Text(style.label).tag(style)
                }
            }
            .labelsHidden()
            .frame(width: 110)

            Picker("", selection: systemBinding) {
                ForEach(UnitSystem.allCases) { system in
                    Text(system.label).tag(system)
                }
            }
            .labelsHidden()
            .frame(width: 110)
            .disabled(current.style.isFeetInches)   // architectural/engineering force feet-inches, matching the Units popover's own convention

            Stepper(value: precisionBinding, in: 0...6) {
                Text("Precision: \(current.precision)").font(.caption)
            }
            .frame(width: 130)
        }
        .padding(8)
        .background(.regularMaterial)
        .cornerRadius(8)
        .shadow(radius: 2)
    }

    private var styleBinding: Binding<LengthStyle> {
        Binding(get: { current.style },
               set: { onChange(MeasureFormat(system: current.system, style: $0, precision: current.precision, insUnits: current.insUnits)) })
    }
    private var systemBinding: Binding<UnitSystem> {
        Binding(get: { current.system },
               set: { onChange(MeasureFormat(system: $0, style: current.style, precision: current.precision, insUnits: current.insUnits)) })
    }
    private var precisionBinding: Binding<Int> {
        Binding(get: { current.precision },
               set: { onChange(MeasureFormat(system: current.system, style: current.style, precision: $0, insUnits: current.insUnits)) })
    }
}
