import CADCore
import SwiftUI

struct StatusBarView: View {
    @ObservedObject var settings: AppSettings
    let document: DXFDocument?
    let isLoading: Bool
    var recoveryStatus = ""
    var issueCount = 0
    var onShowIssues: () -> Void = {}
    var onShowQuality: () -> Void = {}

    var body: some View {
        HStack(spacing: 12) {
            if let document {
                Text("Coordinates: \(document.unitsLabel.isEmpty ? "unspecified units" : document.unitsLabel)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !recoveryStatus.isEmpty {
                Text(recoveryStatus).font(.caption2).foregroundStyle(.secondary).lineLimit(1).help(recoveryStatus)
            }
            if issueCount > 0 {
                Button(action: onShowIssues) { Label("\(issueCount) issues", systemImage: "exclamationmark.triangle") }
                    .workspaceAnchor(.button(.issues))
            }
            Button(action: onShowQuality) { Label("Quality \(settings.renderQuality)", systemImage: "dial.medium") }
                .help("Rendering quality vs. performance")
                .workspaceAnchor(.button(.quality))
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor))
        .workspaceAnchor(.statusBar)
    }
}

struct SheetNavigationView: View {
    @Binding var space: SpaceSelection
    let sheets: [PaperLayout]
    let activeID: UInt64?
    let onSelect: (UInt64) -> Void
    private var index: Int { sheets.firstIndex { $0.id == activeID } ?? 0 }
    var body: some View {
        HStack(spacing: 6) {
            Picker("Drawing space", selection: $space) {
                Text("Model").tag(SpaceSelection.model)
                Text("Paper").tag(SpaceSelection.paper)
            }.pickerStyle(.segmented).labelsHidden().frame(width: 130)
            if space == .paper, !sheets.isEmpty {
                Button { onSelect(sheets[index - 1].id) } label: {
                    Image(systemName: "chevron.left")
                }
                    .buttonStyle(CompactControlButtonStyle())
                    .disabled(index == 0).help("Previous sheet").accessibilityLabel("Previous sheet")
                Picker("Sheet", selection: Binding(get: { activeID ?? sheets[0].id }, set: onSelect)) {
                    ForEach(sheets) { Text($0.name).tag($0.id) }
                }.labelsHidden().frame(minWidth: 180, maxWidth: 320)
                Button { onSelect(sheets[index + 1].id) } label: {
                    Image(systemName: "chevron.right")
                }
                    .buttonStyle(CompactControlButtonStyle())
                    .disabled(index >= sheets.count - 1).help("Next sheet").accessibilityLabel("Next sheet")
                Text("\(index + 1)/\(sheets.count)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
        }.buttonStyle(.borderless)
    }
}

enum WorkspaceInspector: String {
    case issues = "Drawing Content Issues", quality = "Rendering Quality", units = "Units & Format", info = "Drawing Info"
}

struct WorkspaceInspectorCard<Content: View>: View {
    let title: String
    let onClose: () -> Void
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(CompactControlButtonStyle()).accessibilityLabel("Close \(title)")
            }
            Divider()
            content()
        }
        .padding(16).frame(width: 390)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.secondary.opacity(0.3)))
        .shadow(radius: 12)
        .onExitCommand(perform: onClose)
    }
}

enum WorkspaceAnchor: Hashable { case button(WorkspaceInspector), statusBar }

struct WorkspaceAnchorPreference: PreferenceKey {
    static var defaultValue: [WorkspaceAnchor: Anchor<CGRect>] = [:]
    static func reduce(value: inout [WorkspaceAnchor: Anchor<CGRect>], nextValue: () -> [WorkspaceAnchor: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

extension View {
    func workspaceAnchor(_ anchor: WorkspaceAnchor) -> some View {
        // A parent anchor (the status bar) must preserve its child buttons.
        transformAnchorPreference(key: WorkspaceAnchorPreference.self, value: .bounds) { anchors, bounds in
            anchors[anchor] = bounds
        }
    }
}

enum InspectorPlacement {
    static func frame(anchor: CGRect, size: CGSize, container: CGSize, statusBar: CGRect?) -> CGRect {
        let margin: CGFloat = 8
        let bottom = min(container.height - margin, (statusBar?.minY ?? container.height) - margin)
        let width = min(size.width, max(0, container.width - 2 * margin))
        let height = min(size.height, max(0, bottom - margin))
        let x = min(max(margin, anchor.minX), max(margin, container.width - width - margin))
        let below = anchor.maxY + margin
        let y = below + height <= bottom ? below : max(margin, min(bottom - height, anchor.minY - margin - height))
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

struct AnchoredInspector<Content: View>: View {
    let anchor: CGRect
    let container: CGSize
    let statusBar: CGRect?
    @ViewBuilder var content: () -> Content
    @State private var size = CGSize(width: 390, height: 300)
    var body: some View {
        let frame = InspectorPlacement.frame(anchor: anchor, size: size, container: container, statusBar: statusBar)
        content()
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .frame(width: frame.width, height: frame.height, alignment: .top)
            .clipped()
            .offset(x: frame.minX, y: frame.minY)
    }
}
