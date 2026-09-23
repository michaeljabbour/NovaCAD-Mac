import SwiftUI

/// Task tabs keep the drawing tools discoverable without an endless icon strip.
/// Actions still use the same command dispatch as menus and typed commands.
enum RibbonTab: String, CaseIterable, Identifiable {
    case home = "Home", draw = "Draw", modify = "Modify", annotate = "Annotate", view = "View"
    var id: String { rawValue }
}

struct RibbonView<Extras: View>: View {
    let dispatch: CommandDispatch?
    let activeAction: CommandAction?
    let activeToolLabel: String
    @ViewBuilder var extras: (RibbonTab) -> Extras
    @AppStorage("ribbonTab") private var selectedTab = RibbonTab.home.rawValue
    @AppStorage("ribbonCollapsed") private var collapsed = false
    private var tab: RibbonTab { RibbonTab(rawValue: selectedTab) ?? .home }
    private var ready: Bool { dispatch?.hasDocument == true && dispatch?.isLoading == false }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(RibbonTab.allCases) { item in
                    Button {
                        collapsed = false
                        selectedTab = item.rawValue
                    } label: {
                        Text(item.rawValue).font(.system(size: 13, weight: tab == item ? .semibold : .regular))
                            .padding(.horizontal, 14).frame(height: 34)
                            .foregroundStyle(tab == item ? Color.accentColor : .primary)
                            .background(tab == item ? Color.accentColor.opacity(0.08) : .clear)
                            .overlay(alignment: .bottom) {
                                if tab == item { Rectangle().fill(Color.accentColor).frame(height: 2) }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(tab == item ? .isSelected : [])
                    .accessibilityLabel("\(item.rawValue) ribbon tab")
                }
                Spacer(minLength: 8)
                Button { collapsed.toggle() } label: {
                    Image(systemName: collapsed ? "chevron.down" : "chevron.up")
                        .frame(width: 30, height: 30)
                }.buttonStyle(.plain)
                    .help(collapsed ? "Expand ribbon (⌥⌘R)" : "Collapse ribbon for more drawing space (⌥⌘R)")
                    .accessibilityLabel(collapsed ? "Expand ribbon" : "Collapse ribbon")
            }.padding(.horizontal, 8)
            if !collapsed {
                GeometryReader { geometry in
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 0) {
                        switch tab {
                        case .home:
                            group("Clipboard", names: ["PASTECLIP", "COPYCLIP"])
                            group("Draw", names: ["SEL", "LINE", "PLINE", "CIRCLE"], compact: geometry.size.width < 1120)
                            group("Edit", names: ["MOVE", "COPY", "ROTATE", "ERASE"], compact: geometry.size.width < 1120)
                        case .draw:
                            group("Shapes", names: ["LINE", "PLINE", "CIRCLE", "ARC", "RECTANGLE", "POLYGON"], compact: geometry.size.width < 800)
                            group("Curves & surfaces", names: ["ELLIPSE", "POINT", "SPLINE", "SPLINECV", "3DFACE", "REGION"], compact: geometry.size.width < 1320)
                            group("Blocks", names: ["BLOCK", "INSERT", "ATTDEF", "ATTEDIT"], compact: geometry.size.width < 1320)
                        case .modify:
                            group("Transform", names: ["MOVE", "COPY", "ROTATE", "SCALE", "MIRROR", "STRETCH"], compact: geometry.size.width < 800)
                            group("Refine", names: ["TRIM", "EXTEND", "FILLET", "CHAMFER", "OFFSET", "JOIN"], compact: geometry.size.width < 1320)
                            group("Organize", names: ["ARRAY", "EXPLODE", "ERASE", "ATTEDIT"], compact: geometry.size.width < 1320)
                        case .annotate:
                            group("Annotate", names: ["TEXT", "DIMLINEAR", "DIMALIGNED"], compact: geometry.size.width < 750)
                            group("Measure", names: ["DISTANCE", "AREA", "RADIUS", "ANGLE"], compact: geometry.size.width < 750)
                        case .view: EmptyView()
                        }
                        extras(tab)
                    }.padding(.horizontal, 8).padding(.vertical, 8)
                }
                .scrollIndicators(.visible)
                .id(tab)
                }.frame(height: 100)
            }
            if !collapsed {
            HStack(spacing: 6) {
                Circle().fill(ready ? Color.accentColor : Color.secondary).frame(width: 5, height: 5)
                Text(ready ? activeToolLabel : dispatch?.isLoading == true ? "Opening drawing…" : "Open a drawing to begin")
                    .font(.system(size: 11, weight: .medium))
                if ready && activeAction != .selectMode {
                    Button("Cancel (Esc)") { dispatch?.perform(.selectMode) }
                        .keyboardShortcut(.cancelAction)
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                        .padding(.horizontal, 6).frame(height: 23)
                }
                Spacer()
                if dispatch?.hasSelection == true {
                    Text("Selection active").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 14).frame(height: 23)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.45))
            }
            Divider()
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func group(_ title: String, names: [String], compact: Bool = false) -> some View {
        let specs = names.compactMap { name in CommandRegistry.all.first { $0.name == name } }
        return RibbonGroup(title: title) {
            if compact, let first = specs.first {
                VStack(alignment: .leading, spacing: 3) {
                    ribbonButton(first)
                    Menu {
                        ForEach(specs.dropFirst()) { spec in
                            Button { dispatch?.perform(spec.action) } label: {
                                Label(Self.title(for: spec), systemImage: Self.icon(for: spec))
                            }.disabled(!isEnabled(spec))
                        }
                    } label: { Label("More…", systemImage: "ellipsis") }
                        .menuStyle(.borderlessButton).fixedSize().frame(height: 29)
                        .padding(.horizontal, 8)
                        .foregroundStyle(specs.dropFirst().contains { $0.action == activeAction } ? Color.accentColor : .primary)
                        .accessibilityLabel("More \(title.lowercased()) tools")
                        .disabled(!ready)
                }
            } else {
                HStack(spacing: 5) {
                    if let primary = specs.first { primaryButton(primary) }
                    if specs.count > 1 {
                        LazyHGrid(rows: [GridItem(.fixed(29)), GridItem(.fixed(29))], alignment: .top, spacing: 3) {
                            ForEach(specs.dropFirst()) { spec in ribbonButton(spec) }
                        }
                    }
                }
            }
        }
    }

    private func primaryButton(_ spec: CommandSpec) -> some View {
        Button { dispatch?.perform(spec.action) } label: {
            VStack(spacing: 6) {
                Image(systemName: Self.icon(for: spec)).font(.system(size: 23, weight: .regular))
                    .symbolRenderingMode(.hierarchical).foregroundStyle(.tint)
                Text(Self.title(for: spec)).font(.system(size: 11, weight: .medium))
            }.frame(minWidth: 58, minHeight: 61)
        }
        .buttonStyle(RibbonButtonStyle(selected: activeAction == spec.action))
        .help("\(spec.desc)\(spec.aliases.first.map { "  (\($0))" } ?? "")")
        .accessibilityLabel(Self.title(for: spec))
        .accessibilityAddTraits(activeAction == spec.action ? .isSelected : [])
        .disabled(!isEnabled(spec))
    }

    private func ribbonButton(_ spec: CommandSpec) -> some View {
        Button { dispatch?.perform(spec.action) } label: {
            Label(Self.title(for: spec), systemImage: Self.icon(for: spec))
                .frame(minWidth: 76, alignment: .leading)
        }
        .buttonStyle(RibbonButtonStyle(selected: activeAction == spec.action))
        .help("\(spec.desc)\(spec.aliases.first.map { "  (\($0))" } ?? "")")
        .accessibilityAddTraits(activeAction == spec.action ? .isSelected : [])
        .disabled(!isEnabled(spec))
    }

    private func isEnabled(_ spec: CommandSpec) -> Bool {
        guard ready, let dispatch else { return false }
        switch spec.action {
        case .moveTool, .clipboardCopy: return dispatch.hasSelection
        case .clipboardPaste: return dispatch.canPaste()
        default: return true
        }
    }

    private static func title(for spec: CommandSpec) -> String {
        switch spec.name {
        case "SEL": return "Select"
        case "COPY": return "Duplicate"
        case "ARC": return "Arc"
        case "TEXT": return "Text note"
        case "ERASE": return "Erase markup"
        case "SPLINE": return "Fit spline"
        case "SPLINECV": return "Control spline"
        case "REGION": return "Region"
        case "ATTDEF": return "Define attribute"
        case "ATTEDIT": return "Edit attributes"
        case "DIMLINEAR": return "Linear dimension"
        case "DIMALIGNED": return "Aligned dimension"
        case "DISTANCE": return "Distance"
        case "AREA": return "Area"
        case "RADIUS": return "Radius"
        case "ANGLE": return "Angle"
        case "COPYCLIP": return "Copy"
        case "PASTECLIP": return "Paste"
        default: return spec.desc
        }
    }

    private static func icon(for spec: CommandSpec) -> String {
        switch spec.name {
        case "SEL": return "cursorarrow"
        case "COPYCLIP": return "doc.on.doc"
        case "PASTECLIP": return "doc.on.clipboard"
        case "STRETCH": return "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left"
        case "JOIN": return "link"
        case "ATTDEF", "ATTEDIT": return "tag"
        case "DIMLINEAR", "DIMALIGNED": return "ruler"
        case "SPLINECV": return "point.3.connected.trianglepath.dotted"
        case "LINE": return "line.diagonal"
        case "PLINE": return "point.topleft.down.to.point.bottomright.curvepath"
        case "CIRCLE": return "circle"
        case "ARC": return "point.3.connected.trianglepath.dotted"
        case "RECTANGLE": return "rectangle"
        case "POLYGON": return "hexagon"
        case "ELLIPSE": return "oval"
        case "POINT": return "smallcircle.filled.circle"
        case "SPLINE": return "scribble"
        case "3DFACE": return "triangle"
        case "REGION": return "square.dashed"
        case "TEXT": return "textformat"
        case "MOVE": return "arrow.up.and.down.and.arrow.left.and.right"
        case "COPY": return "plus.square.on.square"
        case "ROTATE": return "rotate.right"
        case "SCALE": return "arrow.up.left.and.arrow.down.right"
        case "MIRROR": return "arrow.left.and.right.righttriangle.left.righttriangle.right"
        case "TRIM": return "scissors"
        case "EXTEND": return "arrow.up.right.and.arrow.down.left"
        case "FILLET": return "circle.dashed"
        case "CHAMFER": return "triangle.dashed"
        case "OFFSET": return "square.on.square.dashed"
        case "ARRAY": return "square.grid.3x3"
        case "EXPLODE": return "square.dashed"
        case "ERASE": return "eraser"
        case "DISTANCE": return "ruler"
        case "AREA": return "skew"
        case "RADIUS": return "circle.dashed"
        case "ANGLE": return "angle"
        case "BLOCK": return "cube"
        case "INSERT": return "cube.transparent"
        case "CLAYER": return "square.3.layers.3d"
        case "ZOOM": return "arrow.up.left.and.arrow.down.right"
        default: return "questionmark.square"
        }
    }
}


struct RibbonGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            content().frame(height: 61, alignment: .top)
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding(.horizontal, 10)
        .fixedSize(horizontal: true, vertical: false)
        .overlay(alignment: .trailing) { Divider().padding(.vertical, 2) }
    }
}

struct RibbonButtonStyle: ButtonStyle {
    var selected = false
    func makeBody(configuration: Configuration) -> some View {
        RibbonButtonBody(configuration: configuration, selected: selected)
    }
    private struct RibbonButtonBody: View {
        let configuration: ButtonStyle.Configuration
        let selected: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false
        var body: some View {
            configuration.label
                .font(.system(size: 12))
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, 8).frame(minHeight: 29)
                .foregroundStyle(selected && enabled ? Color.accentColor : .primary)
                .background(RoundedRectangle(cornerRadius: 4).fill(
                    selected ? Color.accentColor.opacity(0.15) :
                        Color.primary.opacity(configuration.isPressed ? 0.16 : hovering ? 0.10 : 0.035)))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(
                    selected ? Color.accentColor.opacity(0.65) : Color.primary.opacity(0.10), lineWidth: 1))
                .opacity(enabled ? 1 : 0.4)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}
