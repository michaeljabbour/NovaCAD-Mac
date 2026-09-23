import CADCore
import SwiftUI

/// The sidebar's two stacked panels: External References (top) and Layers
/// (bottom), each with its own name-filter search bar.
///
/// Split layout (was previously a single `List` with an xrefs `Section` above
/// a layers `Section`): the top half lists xrefs and filters them by name; the
/// bottom half lists layers grouped under their owning xref and filters them by
/// name. A layer belonging to an xref that is toggled OFF is not shown at all —
/// there's nothing to toggle on a hidden xref's layers, and hiding them keeps
/// the layer list focused on what's actually on the canvas.
///
/// The eye toggles write through `$visibility` (a `@Published` on
/// `DocumentSession`), which `ContentView.renderParams()` reads every frame, so
/// a toggle both hides the geometry from the renderer and skips it during
/// hit-testing.
struct LayersPanel: View {
    @Environment(\.colorScheme) private var colorScheme
    let document: DXFDocument?
    let isLoading: Bool
    let currentSourceURL: URL?
    @Binding var visibility: VisibilityState
    @Binding var currentProperties: CurrentProperties
    @Binding var layerSearch: String
    let space: SpaceSelection
    @Binding var selection: Set<EntityID>
    let onReloadDocument: () -> Void
    /// "+ New Layer" button — see `ContentView.createLayer(named:)`.
    let onCreateLayer: (String) -> Void
    /// Layer Properties — sets an EXISTING layer's default color, undoably.
    /// See `ContentView.setLayerColor(_:to:)`'s own doc comment.
    let onSetLayerColor: (Int, ResolvedColor) -> Void
    /// "Layer Settings…" — sets an EXISTING layer's 0-100% transparency,
    /// undoably. See `ContentView.setLayerTransparency(_:to:)`'s own doc
    /// comment. Applied alongside color from the same `LayerSettingsDialog`
    /// sheet, but as its own callback (mirroring `onSetLayerColor`'s own
    /// single-property shape) so a caller not wiring transparency support
    /// yet only has one new parameter to add, not a combined-properties type.
    let onSetLayerTransparency: (Int, Double) -> Void
    /// "Shade Layer…" — fills every closed shape on this layer with a solid
    /// color or crosshatch pattern, as real HATCH/LINE entities on a
    /// dedicated `NOVACAD-SHADE-<layer>` layer. See `ShadeLayer.swift`.
    let onShadeLayer: (Int, ShadeStyle) -> Void
    /// Opens an xref source drawing in a new document tab.
    let onOpenXref: (XrefInfo) -> Void
    /// "Detach" context-menu item — shows the confirmation alert, then
    /// removes the xref (and every other reference sharing its source
    /// drawing) from the live document. Called with every currently-
    /// selected xref row (`selectedXrefIds`, resolved back to `XrefInfo`s)
    /// when the user right-clicks WHILE a multi-selection is active, or
    /// with just the one row otherwise — see `xrefRow`'s context-menu
    /// wiring and this file's header comment on multi-select.
    let onDetachXref: ([XrefInfo]) -> Void
    /// Live entity-store scan (`RegenCoordinator.layerIdsWithLiveEntities()`)
    /// — see that function's own doc comment for exactly why this can't be
    /// `document.layers[i].entityCount > 0` alone: that field goes stale
    /// after any INCREMENTAL edit (which never recomputes it) and is blind to
    /// entities inside a never-instantiated block definition. `nil` only for
    /// the legacy/no-live-document case (mirrors `document`'s own optionality
    /// — e.g. no file loaded yet), in which case `visibleLayers` falls back
    /// to the stale `entityCount` alone, same as before this fix.
    let liveLayerIds: Set<Int32>?
    /// "Delete Layer" — deletes the layer itself AND every entity on it,
    /// regardless of reachability (see `RegenCoordinator.entityIDsOnLayer`'s
    /// doc comment) — the robust cleanup path for an accidental/orphaned
    /// layer, including ones an edit created that the panel/search couldn't
    /// even show you until `liveLayerIds` fixed that.
    let onDeleteLayer: (Int) -> Void
    var onZoomToLayer: (Int) -> Void = { _ in }
    @AppStorage("layersInCurrentSheetOnly") private var currentSheetOnly = true
    var sheetUsage: [Int: LayerUsage] = [:]

    @State private var isAddingLayer = false
    @State private var newLayerName = ""
    @State private var xrefSearch = ""
    @AppStorage("layerNamesInEnglish") private var englishNames = true
    @State private var isolation = LayerIsolationState()
    /// The layer whose "Select Color" dialog is currently presented (its
    /// `DXFLayer.id`), or nil when no color picker is open. `Identifiable`
    /// wrapper so `.sheet(item:)` works directly off this optional int.
    @State private var colorPickerLayerId: IdentifiableInt?
    /// The layer pending a "Delete Layer" confirmation alert (its
    /// `DXFLayer.id`), or nil when no deletion is pending.
    @State private var pendingLayerDeletion: IdentifiableInt?

    // ---- Multi-select states (xrefs pane & layers pane) ----
    //
    // Both panes share the same multi-select convention, mirroring macOS
    // Finder/tree-multiselect behavior:
    //   - Plain click on a row:  replaces panel selection with just that
    //     row. Layer object selection is an explicit context-menu action.
    //   - ⌘-click:               toggles that row in/out of the panel
    //     multi-selection (no canvas select).  Retains the anchor used by
    //     Shift-click below — if the user ⌘-clicks row A, then later
    //     shift-clicks row B, the range is from A to B.
    //   - Shift-click:           extends the panel multi-selection to
    //     include every row from the LAST single/⌘-anchor through this
    //     one (no canvas select).
    //   - Right-click:           if the clicked row is part of the current
    //     panel selection, acts on that selection; otherwise acts on just
    //     the right-clicked row alone.
    //
    // Each pane keeps its own selection set and its own range anchor.

    /// Multi-selection for the External References pane.
    @State private var selectedXrefIds: Set<Int> = []
    @State private var lastXrefAnchor: Int = 0
    /// Multi-selection for the Layers pane.
    @State private var selectedLayerIds: Set<Int> = []
    @State private var lastLayerAnchor: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            if let doc = document {
                if doc.xrefs.isEmpty {
                    layersPane(doc: doc)
                } else {
                    VSplitView {
                        xrefsPane(doc: doc)
                            .frame(minHeight: 100, idealHeight: 160)
                        layersPane(doc: doc)
                            .frame(minHeight: 250)
                    }
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "square.3.layers.3d")
                        .font(.largeTitle).foregroundColor(.secondary)
                    Text("Layers appear here\nafter opening a file")
                        .multilineTextAlignment(.center)
                        .font(.callout).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: currentSourceURL) { _, _ in
            selectedLayerIds = []
            isolation = LayerIsolationState()
        }
    }

    // MARK: - Xrefs pane (top)

    /// One row per unique SOURCE drawing (deduplicated across every parent that
    /// xrefs it) so the user toggles a given drawing exactly once to hide it
    /// everywhere — see XrefInfo.groupedBySourceDrawing().
    private var filteredXrefs: [XrefInfo] {
        guard let doc = document else { return [] }
        let filter = xrefSearch.trimmingCharacters(in: .whitespaces)
        return doc.xrefs.groupedBySourceDrawing()
            .filter { filter.isEmpty || $0.blockName.localizedCaseInsensitiveContains(filter) }
    }

    private func xrefsPane(doc: DXFDocument) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("External References")
                    .font(.headline)
                Spacer()
                Button {
                    onReloadDocument()
                } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
                .disabled(currentSourceURL == nil || isLoading)
                .help("Reload the drawing and all xrefs from disk")
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 4)

            SearchField(text: $xrefSearch, prompt: "Search xrefs")
                .padding(.horizontal, 10)
                .padding(.bottom, 6)

            if doc.xrefs.isEmpty {
                Text("No external references")
                    .font(.caption).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(filteredXrefs) { xref in
                        xrefRow(xref)
                            .listRowBackground(selectedXrefIds.contains(xref.id)
                                               ? Color.accentColor.opacity(0.18) : Color.clear)
                    }
                }
                .listStyle(.inset)
                // Prunes any selected id that no longer exists in the
                // document at all (a completed Detach, or a reload) — keyed
                // on the FULL `doc.xrefs` list (not `filteredXrefs`), so
                // merely typing a search filter that temporarily hides a
                // selected row does NOT clear its selection (Finder-like:
                // search shouldn't discard a multi-selection), only an
                // actual removal from the document does.
                .onChange(of: doc.xrefs.map(\.id)) { _, stillPresent in
                    let present = Set(stillPresent)
                    selectedXrefIds.formIntersection(present)
                }
            }
        }
    }

    private func xrefRow(_ xref: XrefInfo) -> some View {
        // Toggling acts on EVERY reference to this source drawing (under any
        // parent) plus each reference's nested subtree — so the user hides a
        // given drawing once and it disappears everywhere it's xref'd. See
        // Collection.xrefIdsSharingSource(with:).
        let affected = (document?.xrefs.xrefIdsSharingSource(with: xref)) ?? [xref.id]
        let isOn = affected.isDisjoint(with: visibility.hiddenXrefIds)
        let isRowSelected = selectedXrefIds.contains(xref.id)
        return HStack(spacing: 8) {
            Button {
                if isOn { visibility.hiddenXrefIds.formUnion(affected) }
                else { visibility.hiddenXrefIds.subtract(affected) }
            } label: {
                Image(systemName: isOn ? "eye.fill" : "eye.slash")
                    .foregroundColor(isOn ? .accentColor : .secondary)
                    .frame(width: 18)
                    // Give the eye a generous, opaque hit area so the tap lands
                    // on the button, not the row's select-objects gesture.
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!xref.isResolved)
            .help(isOn ? "Hide this drawing everywhere it's xref'd (incl. nested xrefs)"
                       : "Show this drawing everywhere it's xref'd")

            Image(systemName: "link")
                .font(.caption)
                .foregroundColor(xref.isResolved ? .primary : .orange)

            // Only THIS label area triggers "select this xref's objects" — kept
            // off the eye button so its tap is never swallowed (Option A).
            VStack(alignment: .leading, spacing: 1) {
                Text(xref.blockName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Text(xref.isResolved
                     ? "\(xref.entityCount) entities · \(xref.insertCount) insert(s)"
                     : "Not embedded in this DXF")
                    .font(.caption2)
                    .foregroundColor(xref.isResolved ? .secondary : .orange)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                handleXrefClick(xref)
            }
            .help(xref.isResolved ? "\(xref.path)\n\nClick — select this xref's objects\n⌘-click — toggle in/out of multi-select\nShift-click — range-select multiple rows"
                                  : xref.path)

            if !xref.isResolved {
                Spacer()
                Button {
                    linkXrefPath(for: xref)
                } label: {
                    Image(systemName: "folder.badge.plus")
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
                .help("Locate this xref's file on disk and link it so it loads")
            } else {
                Spacer()
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            if xref.isResolved {
                Button("Open Xref…") { onOpenXref(xref) }
            }
            Button("Copy Xref Name") { copyToPasteboard(xref.blockName) }
            if !xref.isResolved {
                Button("Set Xref Path…") { linkXrefPath(for: xref) }
            }
            if XrefPathOverrides.hasOverride(forBlockName: xref.blockName) {
                Button("Clear Linked Path") {
                    XrefPathOverrides.clear(blockName: xref.blockName)
                    onReloadDocument()
                }
            }
            Divider()
            // Right-clicking a row that's part of an active multi-selection
            // (Shift-clicked beforehand) detaches the WHOLE selection in one
            // pass; right-clicking any other row (no multi-selection, or a
            // row outside it) detaches just that one — matching standard
            // macOS list behavior where a right-click on an unselected row
            // acts on that row alone rather than a stale prior selection.
            let detachSelection = (isRowSelected && selectedXrefIds.count > 1)
                ? filteredXrefs.filter { selectedXrefIds.contains($0.id) }
                : [xref]
            Button(detachSelection.count > 1 ? "Detach \(detachSelection.count) Xrefs…" : "Detach…",
                  role: .destructive) {
                onDetachXref(detachSelection)
            }
        }
    }

    /// Prompts for the xref's source drawing on disk, remembers it (so it loads
    /// on this and future opens), then reloads to bring the xref in.
    private func linkXrefPath(for xref: XrefInfo) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = []   // allow any; we accept .dwg and .dxf
        panel.title = "Locate Xref"
        panel.message = "Choose the drawing file for “\(xref.blockName)”."
        panel.prompt = "Link"
        if panel.runModal() == .OK, let url = panel.url {
            XrefPathOverrides.set(blockName: xref.blockName, fileURL: url)
            onReloadDocument()
        }
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Layers pane (bottom)

    /// Layers that currently earn a row: something is drawn on them (or they
    /// were created this session), they match the search filter, AND they do
    /// not belong to an xref that is toggled off.
    private var visibleLayers: [DXFLayer] {
        guard let doc = document else { return [] }
        let filter = layerSearch.trimmingCharacters(in: .whitespaces)
        let hiddenXrefs = doc.xrefs.filter { visibility.hiddenXrefIds.contains($0.id) }
        return doc.layers
            .filter {
                // `entityCount > 0` is a SNAPSHOT from the last full rebuild
                // and goes stale after any incremental edit — never trust it
                // alone. `liveLayerIds` (a fresh scan of the actual entity
                // store) is authoritative when available; `entityCount`/
                // `sessionCreatedLayerIds` remain as the fallback for the
                // (should-be-rare) case liveLayerIds wasn't threaded in. See
                // `RegenCoordinator.layerIdsWithLiveEntities()`'s doc comment.
                if let liveLayerIds, liveLayerIds.contains(Int32($0.id)) { return true }
                return $0.entityCount > 0 || visibility.sessionCreatedLayerIds.contains($0.id)
            }
            .filter { !currentSheetOnly || sheetUsage[$0.id] != nil || visibility.sessionCreatedLayerIds.contains($0.id) }
            .filter { LayerDisplayName.matches($0.name, search: filter) }
            .filter { layer in
                // Omit layers belonging to a toggled-off xref.
                !hiddenXrefs.contains { $0.owns(layerNamed: layer.name) }
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// The layers to show, split into (host layers, [(xref, its layers)]).
    private func groupedLayers(doc: DXFDocument) -> (host: [DXFLayer], xrefGroups: [(XrefInfo, [DXFLayer])]) {
        let layers = visibleLayers
        // Only xrefs that are currently visible get a group.
        let visibleXrefs = doc.xrefs.filter { !visibility.hiddenXrefIds.contains($0.id) }
        // Sort xref prefixes longest-first so a nested xref (PARENT|CHILD|)
        // claims a layer before its parent (PARENT|) would.
        let prefixed = visibleXrefs
            .sorted { $0.layerPrefix.count > $1.layerPrefix.count }

        var host: [DXFLayer] = []
        var byXref: [Int: [DXFLayer]] = [:]
        for layer in layers {
            if let match = prefixed.first(where: { $0.owns(layerNamed: layer.name) }) {
                byXref[match.id, default: []].append(layer)
            } else {
                host.append(layer)
            }
        }
        let xrefGroups = visibleXrefs
            .compactMap { xref -> (XrefInfo, [DXFLayer])? in
                guard let ls = byXref[xref.id], !ls.isEmpty else { return nil }
                return (xref, ls)
            }
            .sorted { $0.0.blockName.localizedCaseInsensitiveCompare($1.0.blockName) == .orderedAscending }
        return (host, xrefGroups)
    }

    private func layersPane(doc: DXFDocument) -> some View {
        let grouped = groupedLayers(doc: doc)
        let total = grouped.host.count + grouped.xrefGroups.reduce(0) { $0 + $1.1.count }
        return VStack(spacing: 0) {
            HStack {
                Text("Layers (\(total))")
                    .font(.headline)
                Spacer()
                Button {
                    isAddingLayer = true
                } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.borderless)
                .foregroundColor(.accentColor)
                .help("New Layer…")
                Button("All On") {
                    visibility.hiddenLayerIds = []
                    isolation = LayerIsolationState()
                }
                    .buttonStyle(.plain).font(.caption)
                    .foregroundColor(.accentColor)
                Button("All Off") {
                    visibility.hiddenLayerIds = Set(doc.layers.map(\.id))
                }
                .buttonStyle(.plain).font(.caption)
                .foregroundColor(.accentColor)
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 4)

            HStack {
                Text("Drawing labels").font(.caption).foregroundColor(.secondary)
                Spacer()
                Picker("Drawing labels", selection: $englishNames) {
                    Text("English").tag(true)
                    Text("Original").tag(false)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 165)
                .help("English names in layer and block controls; original names remain available in tooltips and Original mode")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            SearchField(text: $layerSearch, prompt: "Search English or original names")
                .padding(.horizontal, 10)
                .padding(.bottom, 6)

            Toggle("Only layers on this \(space == .paper ? "sheet" : "model")", isOn: $currentSheetOnly)
                .font(.caption).toggleStyle(.checkbox)
                .padding(.horizontal, 10).padding(.bottom, 6)
            layerActions(doc: doc)

            if isAddingLayer {
                HStack(spacing: 6) {
                    TextField("Layer name", text: $newLayerName)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        .onSubmit { commitNewLayer() }
                    Button("Add") { commitNewLayer() }
                        .font(.caption)
                        .disabled(newLayerName.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Cancel") { isAddingLayer = false; newLayerName = "" }
                        .font(.caption)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            }

            List {
                if grouped.xrefGroups.isEmpty {
                    ForEach(grouped.host) { layer in layerRow(layer) }
                } else if !grouped.host.isEmpty {
                    Section {
                        ForEach(grouped.host) { layer in layerRow(layer) }
                    } header: {
                        Text(grouped.xrefGroups.isEmpty ? "" : "Host layers")
                    }
                }
                ForEach(grouped.xrefGroups, id: \.0.id) { pair in
                    Section {
                        ForEach(pair.1) { layer in layerRow(layer) }
                    } header: {
                        Label(pair.0.blockName, systemImage: "link")
                            .font(.caption)
                    }
                }
            }
            .listStyle(.sidebar)
            // Prune selected layer ids that filtered out (e.g. the user
            // types a search that hides them, or the layer was deleted).
            .onChange(of: visibleLayers.map(\.id)) { _, stillPresent in
                selectedLayerIds.formIntersection(Set(stillPresent))
            }

            clayerPicker(doc: doc)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
        }
    }

    private func layerActions(doc: DXFDocument) -> some View {
        let targets = selectedLayerIds.isEmpty ? Set(visibleLayers.map(\.id)) : selectedLayerIds
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(selectedLayerIds.isEmpty ? "\(targets.count) matching layers" : "\(targets.count) selected layers")
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
                if !selectedLayerIds.isEmpty {
                    Button("Clear selection") { selectedLayerIds = [] }
                        .buttonStyle(.plain).font(.caption)
                }
            }
            HStack(spacing: 6) {
                Button("Show") { visibility.hiddenLayerIds.subtract(targets) }
                    .disabled(targets.isEmpty)
                Button("Hide") { visibility.hiddenLayerIds.formUnion(targets) }
                    .disabled(targets.isEmpty)
                Button("Isolate") {
                    isolation.isolate(targets, allLayerIDs: Set(doc.layers.map(\.id)),
                                      hidden: &visibility.hiddenLayerIds)
                }
                .disabled(targets.isEmpty)
                Spacer(minLength: 0)
                Button("Restore") { isolation.restore(hidden: &visibility.hiddenLayerIds) }
                    .disabled(isolation.previousHidden == nil)
                    .help("Restore the layer visibility from before isolation")
            }
            .controlSize(.small)
            .help("Apply to selected layers, or to all search results when nothing is selected")
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    private func layerRow(_ layer: DXFLayer) -> some View {
        let isOn = !visibility.hiddenLayerIds.contains(layer.id)
        let isLocked = visibility.lockedLayerIds.contains(layer.id)
        let isRowSelected = selectedLayerIds.contains(layer.id)
        return HStack(spacing: 6) {
            Button {
                if isOn { visibility.hiddenLayerIds.insert(layer.id) }
                else { visibility.hiddenLayerIds.remove(layer.id) }
            } label: {
                Image(systemName: isOn ? "eye.fill" : "eye.slash")
                    .foregroundColor(isOn ? .accentColor : .secondary)
                    .frame(width: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isOn ? "Hide layer (freeze)" : "Show layer (thaw)")
            .accessibilityLabel("\(isOn ? "Hide" : "Show") \(displayName(layer))")

            Button {
                if isLocked { visibility.lockedLayerIds.remove(layer.id) }
                else { visibility.lockedLayerIds.insert(layer.id) }
            } label: {
                Image(systemName: isLocked ? "lock.fill" : "lock.open")
                    .foregroundColor(isLocked ? .orange : .secondary.opacity(0.5))
                    .frame(width: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isLocked ? "Unlock layer (allow selection)" : "Lock layer (prevent selection)")
            .accessibilityLabel("\(isLocked ? "Unlock" : "Lock") \(displayName(layer))")

            Button {
                colorPickerLayerId = IdentifiableInt(layer.id)
            } label: {
                // A checkerboard peeking through behind the swatch at
                // partial opacity is what makes a transparent layer visually
                // distinguishable from an opaque one of the SAME color at a
                // glance, in the same compact space the plain color swatch
                // already occupied — no extra row real estate spent on a
                // separate transparency indicator.
                ZStack {
                    if layer.transparency > 0 { rowCheckerboard }
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color(rgb: layer.color.swatchDisplayRGB(darkBackground: colorScheme == .dark)).opacity(1 - layer.transparency / 100))
                }
                .frame(width: 14, height: 14)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .help(layer.transparency > 0
                  ? "\(Int(layer.transparency.rounded()))% transparent — click for Layer Settings"
                  : "Click for Layer Settings (color, transparency)")

            VStack(alignment: .leading, spacing: 3) {
                Text(displayName(layer))
                    .font(.callout)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundColor(isOn ? (isLocked ? .secondary : .primary) : .secondary)
                HStack(spacing: 6) {
                    Spacer(minLength: 2)
                    Text("\((sheetUsage[layer.id]?.count ?? 0).formatted()) objects").fixedSize()
                }
                .font(.caption2)
                .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help("\(layer.name)\nClick to select a layer; ⌘-click or Shift-click for multiple layers. Double-click to isolate.")
        }
        .padding(.leading, 4)
        .padding(.vertical, 4)
        .background(isRowSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        .cornerRadius(4)
        .contentShape(Rectangle())
        .onTapGesture {
            handleLayerClick(layer)
        }
        .onTapGesture(count: 2) {
            // Double-click: isolate this layer, preserving the previous view.
            guard let doc = document else { return }
            let others = Set(doc.layers.map(\.id)).subtracting([layer.id])
            if visibility.hiddenLayerIds == others, isolation.previousHidden != nil {
                isolation.restore(hidden: &visibility.hiddenLayerIds)
            } else {
                isolation.isolate([layer.id], allLayerIDs: Set(doc.layers.map(\.id)),
                                  hidden: &visibility.hiddenLayerIds)
            }
        }
        .contextMenu {
            Button("Isolate Layer") {
                guard let doc = document else { return }
                isolation.isolate([layer.id], allLayerIDs: Set(doc.layers.map(\.id)),
                                  hidden: &visibility.hiddenLayerIds)
            }
            Button("Zoom to Layer") { onZoomToLayer(layer.id) }
                .disabled(sheetUsage[layer.id] == nil)
            Button("Select Objects on Layer") {
                if let doc = document { selectLayer(layerIds: [layer.id], doc: doc) }
            }
            Divider()
            Button("Layer Settings…") { colorPickerLayerId = IdentifiableInt(layer.id) }
            Menu("Shade Layer") {
                Button("Solid Fill") { onShadeLayer(layer.id, .solid) }
                Button("Crosshatch") { onShadeLayer(layer.id, .crosshatch) }
            }
            Divider()
            Button("Copy Layer Name") { copyToPasteboard(layer.name) }
            Divider()
            // Robust regardless of whether this layer's entities are
            // reachable through block instantiation or whether its
            // `entityCount` is stale (see `onDeleteLayer`'s own doc
            // comment) — exactly the cleanup path for an accidental/
            // orphaned layer (e.g. one an edit created) that the OLD
            // entityCount-gated panel/search couldn't even show you.
            Button("Delete Layer…", role: .destructive) {
                pendingLayerDeletion = IdentifiableInt(layer.id)
            }
        }
        .alert(item: $pendingLayerDeletion) { pending in
            let name = document?.layers.first { $0.id == pending.value }?.name ?? "this layer"
            return Alert(
                title: Text("Delete Layer \"\(name)\"?"),
                message: Text("This permanently deletes the layer and every object on it. This can be undone with Cmd+Z."),
                primaryButton: .destructive(Text("Delete")) { onDeleteLayer(pending.value) },
                secondaryButton: .cancel()
            )
        }
        .sheet(item: colorPickerLayerIdBinding(for: layer)) { _ in
            LayerSettingsDialog(
                layerName: displayName(layer),
                initialColor: layer.color,
                initialTransparency: layer.transparency,
                onApply: { newColor, newTransparency in
                    onSetLayerColor(layer.id, newColor)
                    onSetLayerTransparency(layer.id, newTransparency)
                    colorPickerLayerId = nil
                },
                onCancel: { colorPickerLayerId = nil }
            )
        }
    }

    /// A tiny 2x2 checkerboard for the row's compact color/transparency
    /// swatch — same "this is see-through" cue as `LayerSettingsDialog`'s
    /// larger one, scaled down to fit the row's 14x14 swatch.
    private var rowCheckerboard: some View {
        VStack(spacing: 0) {
            ForEach(0..<2, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<2, id: \.self) { col in
                        Rectangle()
                            .fill((row + col).isMultiple(of: 2) ? Color.gray.opacity(0.35) : Color.gray.opacity(0.15))
                    }
                }
            }
        }
    }

    /// `.sheet(item:)` needs a `Binding` scoped to THIS row's layer id so the
    /// sheet only presents for the row that was actually clicked (a plain
    /// shared `$colorPickerLayerId` binding would try to attach the modal to
    /// every row in the `ForEach`, which SwiftUI presents on whichever row
    /// happens to still be alive — scoping it per-row avoids that).
    private func colorPickerLayerIdBinding(for layer: DXFLayer) -> Binding<IdentifiableInt?> {
        Binding(
            get: { colorPickerLayerId?.value == layer.id ? colorPickerLayerId : nil },
            set: { colorPickerLayerId = $0 }
        )
    }

    /// Under an xref group, strip the `XREFNAME|` prefix so the row shows just
    /// the layer's own name (the group header already names the xref).
    private func displayName(_ layer: DXFLayer) -> String {
        let original = originalDisplayName(layer)
        return englishNames ? LayerDisplayName.englishAlias(for: original) ?? original : original
    }

    private func originalDisplayName(_ layer: DXFLayer) -> String {
        guard let doc = document else { return layer.name }
        // Longest prefix first so a nested xref's layer strips PARENT|CHILD|
        // rather than only the shorter PARENT| a parent xref would match.
        let match = doc.xrefs
            .filter { $0.owns(layerNamed: layer.name) }
            .max { $0.layerPrefix.count < $1.layerPrefix.count }
        if let match {
            return String(layer.name.dropFirst(match.layerPrefix.count))
        }
        return layer.name
    }

    // MARK: - Current-layer picker

    private func clayerPicker(doc: DXFDocument) -> some View {
        let names = clayerPickerNames(doc: doc)
        return HStack(spacing: 6) {
            Text("Current layer").font(.caption2).foregroundColor(.secondary)
            Picker("", selection: Binding(
                get: { currentProperties.layerName },
                set: { currentProperties.layerName = $0 }
            )) {
                ForEach(names, id: \.self) { name in
                    Text(englishNames ? LayerDisplayName.englishAlias(for: name) ?? name : name).tag(name)
                }
            }
            .labelsHidden()
            .font(.caption)
        }
        .help("New entities drawn with Phase 6.3 tools (Ellipse, Point, Spline, 3DFace) go on this layer — legacy Draw tools (Line/Polyline/Circle/Arc/Rect/Polygon/Text) still always use the markup layer.")
    }

    private func clayerPickerNames(doc: DXFDocument) -> [String] {
        var names = Set(doc.layers.map(\.name))
        names.insert(currentProperties.layerName)
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func commitNewLayer() {
        let name = newLayerName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        onCreateLayer(name)
        newLayerName = ""
        isAddingLayer = false
    }

    /// Selects every entity belonging to `xref` — merged-in-place render
    /// groups tagged with its xrefId, plus any top-level INSERT tagged the
    /// same way — into the ordinary `selection` set.
    private func selectXref(_ xref: XrefInfo, doc: DXFDocument) {
        let usePaper = space == .paper
        let groups = usePaper ? doc.paperGroups : doc.modelGroups
        var ids: Set<EntityID> = []
        func addResolved(_ ref: EntityRef) {
            if let id = HitTester.resolveEntityID(ref, document: doc, usePaperSpace: usePaper) {
                ids.insert(id)
            }
        }
        for (gi, g) in groups.enumerated() where g.xrefId == xref.id {
            let group = Int32(gi)
            for i in g.strokes.runs.indices { addResolved(.primitive(group: group, store: .run, index: Int32(i))) }
            for i in g.strokes.arcs.indices { addResolved(.primitive(group: group, store: .arc, index: Int32(i))) }
            for i in g.texts.indices { addResolved(.primitive(group: group, store: .text, index: Int32(i))) }
            for i in g.points.indices { addResolved(.primitive(group: group, store: .point, index: Int32(i))) }
            for i in g.strokes.fillRuns.indices { addResolved(.primitive(group: group, store: .fillRun, index: Int32(i))) }
        }
        for (idx, insert) in doc.inserts.enumerated() {
            let isPaperInsert = idx >= doc.modelInsertCount
            guard isPaperInsert == usePaper, Int(insert.xrefId) == xref.id else { continue }
            addResolved(.insert(Int32(idx)))
        }
        guard !ids.isEmpty else { return }
        selection = ids
    }

    // MARK: - Multi-select helpers

    /// Handles a plain/⌘/Shift click on an xref row — macOS Finder-like
    /// multi-select semantics (see the `@State` comments above for the
    /// full spec). `filtered` is the same per-pane list the row belongs to.
    private func handleXrefClick(_ xref: XrefInfo) {
        let all = filteredXrefs
        guard let ordinal = all.firstIndex(where: { $0.id == xref.id }) else { return }
        let cmd = NSEvent.modifierFlags.contains(.command)
        let shift = NSEvent.modifierFlags.contains(.shift)

        if cmd && !shift {
            // ⌘-click: toggle panel selection, update anchor, no canvas.
            if selectedXrefIds.contains(xref.id) { selectedXrefIds.remove(xref.id) }
            else { selectedXrefIds.insert(xref.id) }
            lastXrefAnchor = ordinal
        } else if shift && !cmd {
            // Shift-click: range-select from anchor to here.
            let lo = min(lastXrefAnchor, ordinal), hi = max(lastXrefAnchor, ordinal)
            selectedXrefIds = Set(all[lo...hi].map(\.id))
        } else {
            // Plain click: replace panel selection + select on canvas.
            selectedXrefIds = [xref.id]
            lastXrefAnchor = ordinal
            if let doc = document, xref.isResolved { selectXref(xref, doc: doc) }
        }
    }

    /// Same as `handleXrefClick` but for the layers pane — uses
    /// `visibleLayers` as its ordinal list and selects canvas entities
    /// by layer id.
    private func handleLayerClick(_ layer: DXFLayer) {
        let all = visibleLayers
        guard let ordinal = all.firstIndex(where: { $0.id == layer.id }) else { return }
        let cmd = NSEvent.modifierFlags.contains(.command)
        let shift = NSEvent.modifierFlags.contains(.shift)

        if cmd && !shift {
            if selectedLayerIds.contains(layer.id) { selectedLayerIds.remove(layer.id) }
            else { selectedLayerIds.insert(layer.id) }
            lastLayerAnchor = ordinal
        } else if shift && !cmd {
            let lo = min(lastLayerAnchor, ordinal), hi = max(lastLayerAnchor, ordinal)
            selectedLayerIds = Set(all[lo...hi].map(\.id))
        } else {
            selectedLayerIds = [layer.id]
            lastLayerAnchor = ordinal
        }
    }

    /// Selects every entity on `layerIds` into the canvas `selection` —
    /// matching the existing `selectXref` for xrefs, but keyed by layer id
    /// rather than xref id.
    private func selectLayer(layerIds: Set<Int>, doc: DXFDocument) {
        let usePaper = space == .paper
        let groups = usePaper ? doc.paperGroups : doc.modelGroups
        var ids: Set<EntityID> = []
        func addResolved(_ ref: EntityRef) {
            if let id = HitTester.resolveEntityID(ref, document: doc, usePaperSpace: usePaper) {
                ids.insert(id)
            }
        }
        for (gi, g) in groups.enumerated() where layerIds.contains(Int(g.layerId)) {
            let group = Int32(gi)
            for i in g.strokes.runs.indices { addResolved(.primitive(group: group, store: .run, index: Int32(i))) }
            for i in g.strokes.arcs.indices { addResolved(.primitive(group: group, store: .arc, index: Int32(i))) }
            for i in g.texts.indices { addResolved(.primitive(group: group, store: .text, index: Int32(i))) }
            for i in g.points.indices { addResolved(.primitive(group: group, store: .point, index: Int32(i))) }
            for i in g.strokes.fillRuns.indices { addResolved(.primitive(group: group, store: .fillRun, index: Int32(i))) }
        }
        guard !ids.isEmpty else { return }
        selection = ids
    }
}

/// Trivial `Identifiable` wrapper around a plain `Int` — for `.sheet(item:)`
/// presentations keyed off a layer id (`DXFLayer.id`), which isn't itself
/// `Identifiable`.
struct IdentifiableInt: Identifiable, Equatable {
    let value: Int
    var id: Int { value }
    init(_ value: Int) { self.value = value }
}

/// A compact rounded search field used by both sidebar panes. A plain
/// `TextField` styled as a search box with a magnifying-glass icon and a clear
/// button — used instead of `.searchable`, which only supports one search bar
/// per column and wouldn't let the xrefs and layers panes each have their own.
struct SearchField: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
                .font(.caption)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.callout)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
    }
}
