import SwiftUI

/// Phase 5.1: a grouped toolbar of icon buttons sourced from
/// `CommandRegistry.all`, routed through the SAME `CommandDispatch.perform`
/// funnel `MainMenuCommands`/the command bar use (see
/// App/MainMenuCommands.swift's `CommandDispatch` doc comment) — no second,
/// parallel dispatch implementation.
///
/// Groups map onto the plan's named ribbon categories (Draw/Modify/Layers/
/// Annotation/Blocks/Properties/View), backed by `MenuPath` where a
/// reasonable mapping exists:
///   - Draw       -> `MenuPath.draw`, minus TEXT (pulled into Annotation)
///   - Modify     -> `MenuPath.modify`
///   - Annotation -> TEXT + every `MenuPath.dimension` command (measurement/
///                   annotation tools)
///   - Blocks     -> `MenuPath.insert`
///   - Properties -> `MenuPath.format` (CLAYER today)
///   - View       -> `MenuPath.view` (ZOOM) plus Undo/Redo, which aren't
///                   registry commands with their own CommandAction the way
///                   ZOOM is, so they're wired directly to `session.undo`/
///                   `session.redo` (same funnel the toolbar's own Undo/Redo
///                   buttons already use) rather than invented as fake
///                   registry entries.
///   - Layers is INTENTIONALLY OMITTED: there is no `CommandRegistry` entry
///     for layer visibility/lock/isolate operations (those live entirely in
///     `LayersPanel`'s own UI, not the command bar), so a "Layers" ribbon
///     group would have nothing genuine to source from `CommandRegistry` —
///     per this phase's "don't invent, reuse existing dispatch" rule, it's
///     left out rather than populated with placeholder buttons.
///
/// Not every registry entry is toolbar-worthy (e.g. `CLOSE`, `SEL`, `UNDO`
/// as typed text are command-bar-only conveniences) — each group below is a
/// curated, reasonable subset rather than a mechanical dump of every
/// `CommandSpec` in that `MenuPath`. INSERT is included as a plain button
/// (mirrors the command bar's own bare "INSERT"/"I" — see
/// `performRegistryAction`'s `.blockCommand(.insert)` case — which shows a
/// "choose a block first" message rather than placing anything), NOT the
/// toolbar's per-block-name "Insert Block…"/"Stamp Block…" submenus (those
/// need a picked block name up front, which has no `CommandAction`
/// representation to route through this ribbon's shared funnel without
/// reinventing that picker here).
///
/// Collapsing to an overflow menu/tabs (the plan's "collapsed = tabs" nice-
/// to-have) is NOT implemented — this is a non-collapsing grouped toolbar,
/// which the plan explicitly accepts as "an acceptable, honestly-reported
/// partial implementation" when time/complexity is a concern.
struct RibbonView: View {
    let dispatch: CommandDispatch?

    var body: some View {
        // Horizontal ScrollView so all 6 groups stay reachable (scroll
        // instead of silently clip) below their natural total width — see
        // DWGViewerApp.swift's `.frame(minWidth:)` comment for the full
        // "regardless of window size" fix this is one half of.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 14) {
                group("Draw", specs: drawSpecs)
                Divider().frame(height: 34)
                group("Modify", specs: modifySpecs)
                Divider().frame(height: 34)
                group("Annotation", specs: annotationSpecs)
                Divider().frame(height: 34)
                group("Blocks", specs: blockSpecs)
                Divider().frame(height: 34)
                group("Properties", specs: propertySpecs)
                Divider().frame(height: 34)
                group("View", specs: viewSpecs)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Groups (curated subsets, not every CommandRegistry entry)

    private var drawSpecs: [CommandSpec] {
        names(["LINE", "PLINE", "CIRCLE", "ARC", "RECTANGLE", "POLYGON",
               "ELLIPSE", "POINT", "SPLINE", "3DFACE", "REGION"])
    }
    private var modifySpecs: [CommandSpec] {
        names(["MOVE", "COPY", "ROTATE", "SCALE", "MIRROR", "TRIM", "EXTEND",
               "FILLET", "CHAMFER", "OFFSET", "ARRAY", "EXPLODE", "ERASE"])
    }
    private var annotationSpecs: [CommandSpec] {
        names(["TEXT", "DISTANCE", "AREA", "RADIUS", "ANGLE"])
    }
    private var blockSpecs: [CommandSpec] {
        names(["BLOCK", "INSERT"])
    }
    private var propertySpecs: [CommandSpec] {
        names(["CLAYER"])
    }
    private var viewSpecs: [CommandSpec] {
        names(["ZOOM"])
    }

    private func names(_ names: [String]) -> [CommandSpec] {
        names.compactMap { n in CommandRegistry.all.first { $0.name == n } }
    }

    @ViewBuilder
    private func group(_ title: String, specs: [CommandSpec]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                ForEach(specs) { spec in
                    ribbonButton(spec)
                }
                // Undo/Redo aren't CommandRegistry entries with their own
                // dedicated CommandAction the toolbar/context-menu treat as
                // a plain button click (UNDO's `.undo` action exists, but
                // there is no registry REDO at all — the command bar has
                // never had a typed "REDO" token, only ⌘⇧Z/the toolbar
                // button) — wired directly to session.undo/redo here,
                // matching the toolbar's own existing Undo/Redo buttons,
                // rather than inventing a new registry entry for Redo.
                if title == "View" {
                    Button {
                        dispatch?.perform(.undo)
                    } label: { Image(systemName: "arrow.uturn.backward") }
                        .help("Undo  (U / ⌘Z)")
                        .disabled(!(dispatch?.canUndo ?? false))
                    Button {
                        dispatch?.performRedo()
                    } label: { Image(systemName: "arrow.uturn.forward") }
                        .help("Redo  (⇧⌘Z)")
                        .disabled(!(dispatch?.canRedo ?? false))
                }
            }
            Text(title).font(.caption2).foregroundColor(.secondary)
        }
    }

    private func ribbonButton(_ spec: CommandSpec) -> some View {
        Button {
            dispatch?.perform(spec.action)
        } label: {
            Image(systemName: Self.icon(for: spec))
        }
        .help("\(spec.desc)\(spec.aliases.first.map { "  (\($0))" } ?? "")")
        .disabled(!isEnabled(spec))
    }

    /// Mirrors `MainMenuCommands.isEnabled` — only MOVE (`.moveTool`) needs a
    /// live selection; COPY/ROTATE/SCALE/MIRROR (`.modify`) do NOT, since
    /// `startModify` falls into its own selection-acquisition prompt when
    /// there's no preselection (see `MainMenuCommands.isEnabled`'s doc
    /// comment for the full rationale — this mirrors that function exactly,
    /// including the bug that comment documents having been caught and
    /// fixed there first).
    private func isEnabled(_ spec: CommandSpec) -> Bool {
        guard let dispatch, dispatch.hasDocument, !dispatch.isLoading else { return false }
        switch spec.action {
        case .moveTool:
            return dispatch.hasSelection
        default:
            return true
        }
    }

    /// SF Symbol per command, matching the EXACT icon already used for that
    /// same command in ContentView's toolbar `Menu` (see git history) —
    /// reused, not reinvented, so the ribbon's icons feel consistent with
    /// the toolbar/context menu the user may already be used to.
    private static func icon(for spec: CommandSpec) -> String {
        switch spec.name {
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
