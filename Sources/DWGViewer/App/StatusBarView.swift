import CADCore
import SwiftUI

/// Phase 5.1: the status bar row — sits between the canvas and the command
/// bar (command bar stays "above the status bar unchanged" per the plan).
/// Currently carries the Model/Paper space indicator and the rendering
/// quality picker, both extracted VERBATIM out of `ContentView`'s old
/// `toolbar` (the Model/Paper `Picker` and the "Quality N" button +
/// `qualityPopover`/`qualityDescription` — see git history) rather than
/// reimplemented, per this phase's "move, don't invent" rule.
///
/// Left slot (live cursor coordinates via `MeasureFormat`) and the SNAP/
/// GRID/ORTHO/POLAR/OSNAP/OTRACK/DYN/LWT toggle row are DELIBERATELY NOT
/// included here:
///   - No persistent "current cursor world position" text readout exists
///     anywhere in ContentView today (hover state is tracked per-tool —
///     `draft.hover`/`measure.hover`/etc. — for snapping/preview math only,
///     never surfaced as a standing text label) — inventing one from
///     scratch would be new functionality, not a move, which the plan
///     explicitly says to avoid ("don't reimplement... if not, skip").
///   - SNAP/GRID/ORTHO/POLAR/OSNAP/OTRACK/DYN/LWT have no real backing
///     behavior yet (that's Phase 5.2, not started) — the plan explicitly
///     allows skipping these entirely rather than wiring inert stub
///     buttons, and this pass takes that option to avoid any appearance of
///     functionality that doesn't exist.
///
/// The Model/Paper space `Picker`'s `.onChange` side effect (cancel every
/// modal tool + refit the view) is passed in as `onSpaceChanged` rather than
/// duplicated — `ContentView` still owns `cancelModify`/`cancelTrimExtend`/
/// `cancelFilletChamfer`/`cancelOffset`/`fitToView`.
struct StatusBarView: View {
    @ObservedObject var settings: AppSettings
    let document: DXFDocument?
    let isLoading: Bool
    @Binding var space: SpaceSelection
    let onSpaceChanged: () -> Void

    @State private var showQualityPopover = false

    var body: some View {
        HStack(spacing: 12) {
            Picker("", selection: $space) {
                ForEach(SpaceSelection.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 140)
            .disabled(isLoading || document == nil)
            .onChange(of: space) { _, _ in onSpaceChanged() }

            Spacer()

            Button {
                showQualityPopover.toggle()
            } label: {
                Label("Quality \(settings.renderQuality)", systemImage: "dial.medium")
            }
            .help("Rendering quality vs. performance")
            .popover(isPresented: $showQualityPopover) { qualityPopover }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var qualityPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Rendering Quality").font(.headline)
            Picker("", selection: $settings.renderQuality) {
                ForEach(1...5, id: \.self) { Text("\($0)").tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 240)
            HStack {
                Text("Fastest").font(.caption).foregroundColor(.secondary)
                Spacer()
                Text("Superb").font(.caption).foregroundColor(.secondary)
            }
            .frame(width: 240)
            Text(qualityDescription)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(width: 240, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Button("Reset to Default") { settings.renderQuality = 3 }
                .disabled(settings.renderQuality == 3)
        }
        .padding(14)
    }

    private var qualityDescription: String {
        switch settings.renderQuality {
        case 1: return "Coarsest detail, no antialiasing — smoothest panning on very large drawings."
        case 2: return "Reduced detail with antialiasing — fast on large drawings."
        case 4: return "Fine detail — slightly slower redraws on dense views."
        case 5: return "Near-lossless detail — crispest linework; redraws of dense full-extent views may lag."
        default: return "Balanced detail and speed (recommended)."
        }
    }
}
