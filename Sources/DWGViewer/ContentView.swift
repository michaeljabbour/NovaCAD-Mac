import Foundation
import CADCore
import SwiftUI
import UniformTypeIdentifiers

enum SpaceSelection: String, CaseIterable, Identifiable {
    case model = "Model"
    case paper = "Paper"
    var id: String { rawValue }
}

struct ContentView: View {
    private let englishNames = true
    /// Owns the document, view transform, selection, tool, and markup state
    /// for the one drawing this view is showing (relocated from what used to
    /// be ContentView's own @State — see DocumentSession.swift). One
    /// DocumentSession per open tab; DocumentTabsView creates and owns them,
    /// so this is an @ObservedObject, not a locally-created @StateObject.
    /// Everything below that forwards to `session`/`settings` is a same-name
    /// computed proxy so the ~2000 lines of view logic in this file keep
    /// reading/writing bare identifiers exactly as before; only the storage
    /// moved.
    @ObservedObject var session: DocumentSession
    /// App-wide preferences — ONE shared instance across every tab (render
    /// quality, unit format, markup color are user preferences, not
    /// per-drawing state), owned by DocumentTabsView.
    @ObservedObject var settings: AppSettings
    /// "Open File" while this tab already has a document creates a NEW tab
    /// rather than replacing this one's content. DocumentTabsView supplies
    /// the real implementation; the default is only for previews/tests.
    var onOpenInNewTab: (URL) -> Void = { _ in }

    var onNewTab: () -> Void = {}
    var onCloseTab: () -> Void = {}
    var onRecover: () -> Void = {}
    @State private var showingPDFExport = false

    @State private var darkBackground = true
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all

    @State private var isImporterPresented = false
    @State private var layerSearch = ""
    @State private var inspector: WorkspaceInspector?
    /// AI Assistant panel visibility — a plain per-view `@State` (not
    /// `DocumentSession`) since it's pure UI chrome (like
    /// `propertiesMinimized`), not conversation state that needs to survive
    /// a `.id(activeTab.id)` view-identity change on tab switch (that
    /// survives via `session.aiAssistant` instead — see `DocumentSession`'s
    /// own doc comment on that field).
    @State private var showAIAssistant = false
    /// Docked by default so the drawing stays visible beside the conversation.
    @State private var aiAssistantFloating = false
    /// Where the floating panel currently sits/how big it is. Held here (not
    /// inside `FloatingAIAssistantPanel`) so a float -> dock -> float round
    /// trip returns the panel to where the user last put it rather than
    /// snapping back to the default corner. `nil` until the container size is
    /// known, at which point `FloatingPanelFrame.defaultFrame` seeds it.
    @State private var aiAssistantFrame: FloatingPanelFrame?

    @State private var propertiesMinimized = false


    @State private var eraseCandidate: EntityID? = nil
    /// Backs the command bar's text-entry experience (autocomplete, ghost
    /// completion, history) — UI-input state, appropriately per-tab/
    /// per-ContentView rather than per-app or per-document, so a plain
    /// @StateObject here (not on DocumentSession/AppSettings) is correct.
    @StateObject private var commandLine = CommandLineState()
    @State private var commandMessage = ""
    @State private var lastSnapAt = Date.distantPast
    // Text-note placement
    @State private var pendingTextPos: CGPoint? = nil
    @State private var pendingTextInput = ""
    @State private var showTextPrompt = false
    // Block stamping
    @State private var stampBlockName: String? = nil
    // Phase 6.1: BLOCK/INSERT/ATTDEF/ATTEDIT
    /// Multi-step command-bar text entry for BLOCK (name) and ATTDEF
    /// (block name -> tag -> prompt -> default value), mirroring the EXACT
    /// "type a keyword/action, then the next command-bar submission is the
    /// value" chaining `pendingSetVar`/`pendingFilletChamferEntry` already
    /// use — reused here instead of a SwiftUI `.alert` so this stays
    /// consistent with the established pattern rather than introducing a
    /// second, parallel multi-step-entry mechanism.
    private enum PendingBlockEntry { case blockName }
    @State private var pendingBlockEntry: PendingBlockEntry? = nil
    /// "Attach Xref…": the just-parsed candidate file, shown by the layer-
    /// selection sheet (`.sheet(item:)`-presented via this optional —
    /// non-nil while the sheet is up). Set by `startAttachXref`'s file
    /// picker callback; cleared when the sheet is dismissed (Cancel or
    /// Attach). `Identifiable` conformance below lets `PendingAttach`
    /// itself drive `.sheet(item:)` without a separate `showXrefAttachSheet`
    /// boolean going out of sync with it (the same class of bug this
    /// codebase's own `attributeEditorInsertId` doc comment warns about for
    /// booleans paired with a separate payload).
    @State private var pendingXrefAttach: XrefAttach.PendingAttach? = nil
    /// Layers the user has checked in the attach sheet — starts EMPTY
    /// (opt-in default, per this feature's product decision — the opposite
    /// of ordinary xref resolution, which always imports every layer).
    @State private var xrefAttachSelectedLayers: Set<String> = []
    /// "Extract Data…" step 1's column-picker sheet payload — the rows
    /// already extracted (computed once, before the sheet opens) plus the
    /// candidate column list derived from them. `nil` while the sheet is
    /// closed; non-nil drives `.sheet(item:)` exactly like
    /// `pendingXrefAttach` above.
    @State private var pendingDataExtraction: PendingDataExtraction? = nil

    /// Payload for the `.sheet(item:)`-driven Data Extraction column
    /// picker — see `pendingDataExtraction`'s own doc comment above.
    struct PendingDataExtraction: Identifiable {
        /// One `extractDataToCSV()` invocation is the only one that can be
        /// in flight at a time (the picker sheet is modal per window), so
        /// a fixed constant identity is sufficient — mirrors
        /// `attributeEditorInsertId`'s equivalent single-payload sheets
        /// that don't need a per-instance identity scheme.
        var id: Int { 0 }
        let rows: [DataExtraction.Row]
        let columns: [String]
    }
    /// Confirmation-alert payload for "Detach Xref" — non-nil while the
    /// destructive-action alert is up, carrying every `XrefInfo` the detach
    /// will affect (see `XrefAttach.xrefsAffectedByDetach`) so the alert can
    /// list them before the user confirms.
    @State private var pendingXrefDetach: [XrefInfo]? = nil
    private enum PendingAttdefEntry { case blockName, tag, prompt, defaultValue }
    @State private var pendingAttdefEntry: PendingAttdefEntry? = nil
    /// Phase 6.4: ARRAY's own command-bar field-entry chaining flag — mirrors
    /// `pendingBlockEntry`/`pendingAttdefEntry`'s "the next command-bar
    /// submission is a value, not a command" convention. Non-nil whenever
    /// `arrayToolState.phase == .pickKind || .pickFields` so `executeCommand`
    /// knows to route the next typed line into `feedArrayEntry` instead of
    /// `CommandParser.parse`.
    private enum PendingArrayEntry { case kind, field }
    @State private var pendingArrayEntry: PendingArrayEntry? = nil
    /// Phase 6.3: CLAYER's own command-bar value-entry chaining flag.
    @State private var pendingClayerEntry = false
    /// Phase 6.3: ELLIPSE's "R" (rotation) keyword — true right after "R" is
    /// typed while ELLIPSE has exactly 2 points (center/major-endpoint or
    /// axis-endpoint pair) already picked, so the NEXT typed number is
    /// interpreted as a rotation angle in degrees rather than falling
    /// through to `.length`'s "distance along the hover direction" meaning.
    @State private var pendingEllipseRotationAngle = false
    /// Fields gathered so far for the ATTDEF currently being defined —
    /// reset each time a fresh ATTDEF command starts.
    @State private var attdefBlockName = ""
    @State private var attdefTag = ""
    @State private var attdefPrompt = ""
    @State private var pendingAttdefDefaultValue = ""
    /// The INSERT that a double-click (or the ATTEDIT command) most
    /// recently targeted — non-nil drives the attribute editor sheet's
    /// `.sheet(item:)` presentation.
    @State private var attributeEditorInsertId: EntityID? = nil
    /// ATTEDIT command: waiting for the user to click/pick an INSERT (a
    /// distinct one-shot pick, not a full `BlockToolState`, since ATTEDIT's
    /// only "geometric parameter" is which INSERT to open — no base point/
    /// name/placement follows).
    @State private var awaitingAttEditPick = false
    /// ATTDEF: waiting for the click that places the new attribute
    /// (height fixed at a constant, documented simplification — see
    /// `startAttdefPlacement`).
    @State private var awaitingAttdefPlacement = false
    /// Application-scoped AutoCAD-style system variables (SETVAR). One per
    /// window is fine for now; Phase 1 will thread drawing-scoped vars
    /// through the real per-document header once EditableDocument exists —
    /// see SysVarScope.drawing's doc comment in SysVars.swift.
    @StateObject private var sysVars = SysVars()
    /// Set when the command bar just recognized a bare sysvar name (AutoCAD's
    /// "type the variable name, then type the new value" shortcut) — the
    /// NEXT command-bar submission is interpreted as the new value for this
    /// variable instead of being parsed as a drafting command.
    @State private var pendingSetVar: String? = nil
    /// Phase 4.4: CHAMFER's own "D" (distances) / "A" (angle) keyword
    /// entry — a two-step prompt exactly like `pendingSetVar`'s "type a
    /// name, then type its value" shape, but for `session.chamferD1`/
    /// `chamferD2`/`chamferAngleDeg`/`chamferUsesAngle`, which (unlike
    /// FILLETRAD) aren't registered SysVars and so have no other UI path to
    /// change them — see `DocumentSession`'s doc comment for why. `nil` =
    /// no pending chamfer-parameter entry; `.distance1`/`.distance2` are
    /// visited in sequence after typing "D"; `.angleValue` follows "A".
    @State private var pendingFilletChamferEntry: PendingFilletChamferEntry? = nil
    private enum PendingFilletChamferEntry { case distance1, distance2, angleValue, filletRadius }

    /// Standard markup palette (ACI index, display name).
    static let markupPalette: [(aci: Int, name: String)] = [
        (1, "Red"), (2, "Yellow"), (3, "Green"), (4, "Cyan"),
        (5, "Blue"), (6, "Magenta"), (7, "White"), (30, "Orange"),
        (8, "Dark Gray")
    ]

    @FocusState private var searchFocused: Bool
    @FocusState private var commandFocused: Bool
    @State private var animationTimer: Timer?
    /// Best-effort live-reload watch on the user's acad.pgp — see
    /// PGPFile.watch(_:onChange:).
    @State private var pgpWatcher: DispatchSourceFileSystemObject?

    // MARK: DocumentSession proxies (same names/semantics as the old @State)
    //
    // `nonmutating set`: these write through `session`/`settings`, reference
    // types held by this struct — not this struct's own storage — so the
    // enclosing (non-mutating) View methods can assign through them exactly
    // as they could through the old @State vars.

    private var document: DXFDocument? { session.document }
    private var regen: RegenCoordinator? { session.regen }
    private var visibility: VisibilityState {
        get { session.visibility } nonmutating set { session.visibility = newValue }
    }
    private var space: SpaceSelection {
        get { session.space } nonmutating set { session.space = newValue }
    }
    private var zoom: CGFloat {
        get { session.zoom } nonmutating set { session.zoom = newValue }
    }
    private var pan: CGSize {
        get { session.pan } nonmutating set { session.pan = newValue }
    }
    private var viewSize: CGSize {
        get { session.viewSize } nonmutating set { session.viewSize = newValue }
    }
    /// Stable-identity selection (Phase 1.7) — includes markup, which is
    /// ordinary EntityStore content now (see `selectedMarkupIDs` below).
    private var selection: Set<EntityID> {
        get { session.selection } nonmutating set { session.selection = newValue }
    }
    private var draft: DraftState {
        get { session.draft } nonmutating set { session.draft = newValue }
    }
    private var measure: MeasureState {
        get { session.measure } nonmutating set { session.measure = newValue }
    }
    private var moveState: MoveState {
        get { session.moveState } nonmutating set { session.moveState = newValue }
    }
    /// Phase 4.2: COPY/ROTATE/SCALE/MIRROR state.
    private var modifyState: ModifyToolState {
        get { session.modifyState } nonmutating set { session.modifyState = newValue }
    }
    /// Phase 4.3: TRIM/EXTEND state.
    private var trimExtendState: TrimExtendToolState {
        get { session.trimExtendState } nonmutating set { session.trimExtendState = newValue }
    }
    /// Phase 4.4: FILLET/CHAMFER state.
    private var filletChamferState: FilletChamferToolState {
        get { session.filletChamferState } nonmutating set { session.filletChamferState = newValue }
    }
    /// Phase 4.5: OFFSET state.
    private var offsetState: OffsetToolState {
        get { session.offsetState } nonmutating set { session.offsetState = newValue }
    }
    /// DIMENSION (linear/aligned) tool state.
    private var dimensionToolState: DimensionToolState {
        get { session.dimensionToolState } nonmutating set { session.dimensionToolState = newValue }
    }
    /// Phase 6.1: BLOCK/INSERT state.
    private var blockToolState: BlockToolState {
        get { session.blockToolState } nonmutating set { session.blockToolState = newValue }
    }
    /// "Attach Xref…" state.
    private var xrefAttachToolState: XrefAttachToolState {
        get { session.xrefAttachToolState } nonmutating set { session.xrefAttachToolState = newValue }
    }
    /// Cross-drawing "Paste" placement state.
    private var clipboardPasteToolState: ClipboardPasteToolState {
        get { session.clipboardPasteToolState } nonmutating set { session.clipboardPasteToolState = newValue }
    }
    /// Grip editing's single-grip drag/hover state — see
    /// `GripDragState.swift`.
    private var gripDragState: GripDragState {
        get { session.gripDragState } nonmutating set { session.gripDragState = newValue }
    }
    /// STRETCH's interactive state — see `StretchToolState.swift`.
    private var stretchState: StretchToolState {
        get { session.stretchState } nonmutating set { session.stretchState = newValue }
    }
    /// Phase 6.2: EXPLODE's acquisition flag.
    private var explodeAwaitingSelection: Bool {
        get { session.explodeAwaitingSelection } nonmutating set { session.explodeAwaitingSelection = newValue }
    }
    /// JOIN's acquisition flag — see `DocumentSession.joinAwaitingSelection`.
    private var joinAwaitingSelection: Bool {
        get { session.joinAwaitingSelection } nonmutating set { session.joinAwaitingSelection = newValue }
    }
    /// Phase 6.3: CLAYER/CECOLOR/CELTYPE/CELTSCALE/current text style.
    private var currentProperties: CurrentProperties {
        get { session.currentProperties } nonmutating set { session.currentProperties = newValue }
    }
    /// Phase 6.4: ARRAY state.
    private var arrayToolState: ArrayToolState {
        get { session.arrayToolState } nonmutating set { session.arrayToolState = newValue }
    }
    /// Phase 4.1: the live "Select objects:" acquisition loop, active only
    /// while `modifyState.phase == .selecting` OR
    /// `trimExtendState.phase == .selectingBoundaries`.
    private var selectionPrompt: SelectionPrompt? {
        get { session.selectionPrompt } nonmutating set { session.selectionPrompt = newValue }
    }
    /// Positional `EntityRef`s for the current selection, resolved fresh each
    /// time from `regen` — feeds `RenderParams.selection` (still `EntityRef`-
    /// typed; see `RegenCoordinator.resolveToRefs`'s doc comment for why).
    private var selectionRefs: Set<EntityRef> {
        guard let regen else { return [] }
        return regen.resolveToRefs(selection)
    }
    /// The subset of the current selection that is markup (i.e. lives on the
    /// NOVACAD-MARKUP layer) — replaces the old, separate `selectedMarkup:
    /// Set<UUID>`. Markup is ordinary EntityStore content selected via the
    /// SAME `selection: Set<EntityID>` as any other entity now; this is a
    /// derived view used only to decide which properties panel/behaviors
    /// apply (the markup panel is editable; the read-only panel isn't).
    private var selectedMarkupIDs: Set<EntityID> {
        guard let regen, let markupLayerId = session.markupLayerId else { return [] }
        return selection.filter { regen.parsed.store.header($0)?.layerId == markupLayerId }
    }
    private var searchIndex: SearchIndex? {
        get { session.searchIndex } nonmutating set { session.searchIndex = newValue }
    }
    private var searchVisible: Bool {
        get { session.searchVisible } nonmutating set { session.searchVisible = newValue }
    }
    private var searchQuery: String {
        get { session.searchQuery } nonmutating set { session.searchQuery = newValue }
    }
    private var searchResults: [SearchHit] {
        get { session.searchResults } nonmutating set { session.searchResults = newValue }
    }
    private var searchCursor: Int {
        get { session.searchCursor } nonmutating set { session.searchCursor = newValue }
    }
    private var halo: SearchHalo? {
        get { session.halo } nonmutating set { session.halo = newValue }
    }
    private var isLoading: Bool {
        get { session.isLoading } nonmutating set { session.isLoading = newValue }
    }
    private var loadProgress: Double {
        get { session.loadProgress } nonmutating set { session.loadProgress = newValue }
    }
    private var loadingXrefName: String? {
        get { session.loadingXrefName } nonmutating set { session.loadingXrefName = newValue }
    }
    private var loadingXrefIndex: Int {
        get { session.loadingXrefIndex } nonmutating set { session.loadingXrefIndex = newValue }
    }
    private var loadingXrefTotal: Int {
        get { session.loadingXrefTotal } nonmutating set { session.loadingXrefTotal = newValue }
    }
    private var loadCancelRequested: Bool {
        get { session.loadCancelRequested } nonmutating set { session.loadCancelRequested = newValue }
    }
    private var alertMessage: String? {
        get { session.alertMessage } nonmutating set { session.alertMessage = newValue }
    }
    private var currentSourceURL: URL? {
        get { session.currentSourceURL } nonmutating set { session.currentSourceURL = newValue }
    }
    private var reloadRestore: ReloadSnapshot? {
        get { session.reloadRestore } nonmutating set { session.reloadRestore = newValue }
    }

    // MARK: AppSettings proxies

    private var renderQuality: Int {
        get { settings.renderQuality } nonmutating set { settings.renderQuality = newValue }
    }
    private var unitSystemRaw: String {
        get { settings.unitSystemRaw } nonmutating set { settings.unitSystemRaw = newValue }
    }
    private var lengthStyleRaw: String {
        get { settings.lengthStyleRaw } nonmutating set { settings.lengthStyleRaw = newValue }
    }
    private var unitPrecision: Int {
        get { settings.unitPrecision } nonmutating set { settings.unitPrecision = newValue }
    }
    private var markupColor: Int {
        get { settings.markupColor } nonmutating set { settings.markupColor = newValue }
    }

    /// Live format built from the persisted preferences + the drawing's units.
    private var currentFormat: MeasureFormat {
        MeasureFormat(system: UnitSystem(rawValue: unitSystemRaw) ?? .asDrawn,
                      style: LengthStyle(rawValue: lengthStyleRaw) ?? .decimal,
                      precision: unitPrecision,
                      insUnits: document?.insUnits ?? 0)
    }

    private var bounds: CGRect {
        guard let doc = document else { return .zero }
        return space == .model ? doc.modelFitBounds : doc.paperFitBounds
    }

    private var fullBounds: CGRect {
        guard let doc = document else { return .zero }
        return space == .model ? doc.modelBounds : doc.paperBounds
    }

    var body: some View {
        VStack(spacing: 0) {
        RibbonView(dispatch: commandDispatch, activeAction: activeRibbonAction,
                   activeToolLabel: currentToolLabel, extras: ribbonExtras)
        workspaceStrip
        NavigationSplitView(columnVisibility: $sidebarVisibility) {
            LayersPanel(
                document: document,
                isLoading: isLoading,
                currentSourceURL: currentSourceURL,
                visibility: $session.visibility,
                currentProperties: $session.currentProperties,
                layerSearch: $layerSearch,
                space: space,
                selection: $session.selection,
                onReloadDocument: reloadDocument,
                onCreateLayer: createLayer,
                onSetLayerColor: setLayerColor,
                onSetLayerTransparency: setLayerTransparency,
                onShadeLayer: { layerId, style in shadeLayer(layerId, style: style) },
                onOpenXref: openXrefInNewTab,
                onDetachXref: beginXrefDetach,
                liveLayerIds: regen?.layerIdsWithLiveEntities(),
                onDeleteLayer: deleteLayer,
                onZoomToLayer: zoomToLayer, sheetUsage: session.currentLayerUsage
            )
                .navigationSplitViewColumnWidth(min: 300, ideal: 370, max: 560)
        } detail: {
            VStack(spacing: 0) {
                if searchVisible && document != nil { searchBar }
                HStack(spacing: 0) {
                    drawingArea
                    if !selectedMarkupIDs.isEmpty {
                        MarkupPropertiesPanel(
                            session: session,
                            document: document,
                            selectedMarkupIDs: selectedMarkupIDs,
                            currentFormat: currentFormat,
                            markupPalette: Self.markupPalette,
                            markupColor: Binding(get: { markupColor }, set: { markupColor = $0 }),
                            selection: $session.selection,
                            onStartMove: startMove,
                            onStartModify: startModify,
                            onDeleteSelectedMarkup: deleteSelectedMarkup
                        )
                    } else if !selection.isEmpty {
                        if propertiesMinimized {
                            MinimizedPropertiesTab(selectionCount: selection.count,
                                                   propertiesMinimized: $propertiesMinimized)
                        } else {
                            PropertiesPanel(session: session,
                                            document: document,
                                            selectionCount: selection.count,
                                            mergedProperties: mergedProperties,
                                            propertiesMinimized: $propertiesMinimized,
                                            selection: $session.selection,
                                            format: currentFormat)
                        }
                    }
                    // Only the DOCKED presentation participates in this
                    // layout row; the floating one is an overlay over
                    // `drawingArea` (see its `.overlay` below) so it hovers
                    // over the canvas instead of narrowing it.
                    if showAIAssistant && !aiAssistantFloating {
                        AIAssistantPanel(
                            aiSession: session.aiAssistant,
                            regen: regen,
                            visibility: visibility,
                            selectionProvider: { [weak session] in session?.selection ?? [] },
                            onApplyEdits: applyAIProposedEdits,
                            onApplyGeometry: applyAIProposedGeometry,
                            onClose: { showAIAssistant = false },
                            presentation: .docked,
                            onTogglePresentation: { withAnimation(.easeOut(duration: 0.18)) { aiAssistantFloating = true } }
                        )
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                StatusBarView(settings: settings, document: document, isLoading: isLoading,
                              recoveryStatus: session.workspaceError ?? session.recoveryStatus,
                              issueCount: drawingIssues.count,
                              onShowIssues: { inspector = .issues }, onShowQuality: { inspector = .quality })
                if document != nil { commandBar }
            }
        }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) { quickAccessControls }
            ToolbarItem(placement: .principal) { documentTitle }
            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: toggleSearch) { Image(systemName: "magnifyingglass") }
                    .help("Find text and blocks (⌘F)").accessibilityLabel("Find in drawing")
                    .disabled(document == nil || isLoading)
                assistantToggle
            }
        }
        .overlay(alignment: .bottomTrailing) { inspectorCard }
        .frame(minWidth: 1000, minHeight: 650)
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [
                UTType(filenameExtension: "dxf") ?? .item,
                UTType(filenameExtension: "dwg") ?? .item,
                .zip,       // AutoCAD eTransmit package
                .folder     // unzipped eTransmit / drawing set folder
            ],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    // An empty tab loads in place; a tab that already has a
                    // document open gets a new tab instead — nothing is ever
                    // discarded by opening another file, unlike the old
                    // single-tab behavior this replaces.
                    if document == nil { openFile(url: url) }
                    else { onOpenInNewTab(url) }
                }
            case .failure(let error):
                alertMessage = "Failed to import file: \(error.localizedDescription)"
            }
        }
        .alert("DXF Viewer", isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } })
        ) {
            Button("OK", role: .cancel) { alertMessage = nil }
        } message: {
            if let alertMessage { Text(alertMessage) }
        }
        .alert("Add text note", isPresented: $showTextPrompt) {
            TextField("Note text", text: $pendingTextInput)
            Button("Add") { commitPendingText() }
            Button("Cancel", role: .cancel) { pendingTextPos = nil; pendingTextInput = "" }
        }
        // Phase 6.1: attribute editor sheet — driven by `attributeEditorInsertId`
        // (double-click on an attributed INSERT, or the ATTEDIT command).
        // `Binding(get:set:)` over the optional (rather than adding
        // `Identifiable` to `EntityID` for a `.sheet(item:)` presentation)
        // keeps this additive — no core type gains new conformances just for
        // one sheet.
        .sheet(isPresented: Binding(
            get: { attributeEditorInsertId != nil },
            set: { if !$0 { attributeEditorInsertId = nil } })
        ) {
            if let insertId = attributeEditorInsertId, let regen {
                AttributeEditorView(insertId: insertId, session: session, regen: regen) {
                    attributeEditorInsertId = nil
                }
            }
        }
        // "Attach Xref…" step 2: layer-selection sheet, driven by
        // `pendingXrefAttach` (`.sheet(item:)` — see that property's own
        // doc comment for why this is preferred over a paired boolean).
        .sheet(item: $pendingXrefAttach) { pending in
            XrefAttachSheet(
                fileName: pending.sourceURL.lastPathComponent,
                layerNames: pending.availableLayerNames,
                selected: $xrefAttachSelectedLayers,
                onCancel: { pendingXrefAttach = nil },
                onAttach: { beginXrefAttachPlacement(pending) },
                onAttachAtOrigin: { commitXrefAttachAtOrigin(pending) })
        }
        // "Extract Data…" step 1: column picker, driven by
        // `pendingDataExtraction` — see that property's own doc comment.
        .sheet(item: $pendingDataExtraction) { pending in
            DataExtractionColumnPicker(
                allColumns: pending.columns,
                onCancel: { pendingDataExtraction = nil },
                onExport: { chosenColumns in commitDataExtraction(rows: pending.rows, columns: chosenColumns) })
        }
        // "Detach Xref" confirmation — lists every block name the detach
        // will affect (shared-source de-dup — see `XrefAttach.commitDetach`'s
        // doc comment) before the user confirms a destructive action.
        .alert("Detach Xref?", isPresented: Binding(
            get: { pendingXrefDetach != nil },
            set: { if !$0 { pendingXrefDetach = nil } })
        ) {
            Button("Detach", role: .destructive) {
                if let xrefs = pendingXrefDetach { commitXrefDetach(xrefs) }
                pendingXrefDetach = nil
            }
            Button("Cancel", role: .cancel) { pendingXrefDetach = nil }
        } message: {
            if let xrefs = pendingXrefDetach {
                let names = xrefs.map(\.blockName).joined(separator: ", ")
                Text(xrefs.count == 1
                     ? "This removes “\(names)” from the drawing."
                     : "This source drawing is referenced \(xrefs.count) times in this drawing "
                       + "(as: \(names)) — detaching removes it from all of them.")
            }
        }
        .onAppear {
            NSApp.appearance = NSAppearance(named: .darkAqua)
            // A tab freshly created by "open in new tab" carries the URL to
            // load here — it couldn't call openFile() itself before this
            // view (and its session) existed.
            if let url = session.pendingOpenURL {
                session.pendingOpenURL = nil
                openFile(url: url)
            }
            PGPFile.ensureDefaultExists()
            CommandRegistry.reloadUserAliases(from: PGPFile.userURL)
            pgpWatcher = PGPFile.watch(PGPFile.userURL) {
                CommandRegistry.reloadUserAliases(from: PGPFile.userURL)
            }
        }
        // Belt-and-suspenders alongside the `.onAppear` check above: an
        // external open-file delivery (`DocumentTabsView`'s
        // `ExternalOpenRequestQueue` drain / `.novaCADOpenExternalURL`
        // subscriber) can race this view's OWN `.onAppear` — if THIS
        // ContentView already appeared and checked `pendingOpenURL` (found
        // it nil) before the parent `DocumentTabsView` set it moments later,
        // the `.onAppear` check above would never re-run and the drawing
        // would silently never load (reproducing the exact "blank window"
        // bug this whole mechanism exists to fix). `.onChange` catches that
        // ordering regardless of which side wins the race.
        .onChange(of: session.pendingOpenURL) { _, newValue in
            guard let url = newValue else { return }
            session.pendingOpenURL = nil
            openFile(url: url)
        }
        .onDisappear {
            session.persistWorkspace()
            session.checkpointRecovery()
            pgpWatcher?.cancel()
            pgpWatcher = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: .novaCADDrawingSaved)) { note in
            guard let url = note.userInfo?[DocumentNotificationKey.url] as? URL else { return }
            handleExternalDrawingSaved(url)
        }
        // Phase 5.1: publishes this window's tool-start funnel for
        // MainMenuCommands (native menu bar) to read via `@FocusedValue` —
        // see CommandDispatch's doc comment in App/MainMenuCommands.swift
        // for why a closure (not @FocusedObject) is used. Recomputed on
        // every body evaluation so the disabled-state flags always reflect
        // this tab's CURRENT document/loading/selection/undo state.
        .focusedSceneValue(\.novaCADCommandDispatch, commandDispatch)
        .focusedSceneValue(\.novaCADFileDispatch, fileDispatch)
        .sheet(isPresented: $showingPDFExport) {
            if let regen { PDFExportView(parsed: regen.parsed, visibility: visibility, currentSpace: space,
                                          sourceName: currentSourceURL?.deletingPathExtension().lastPathComponent ?? "Drawing") }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in
            session.persistWorkspace(); session.checkpointRecovery()
        }
    }

    /// The single `CommandDispatch` value shared by BOTH `.focusedSceneValue`
    /// (for `MainMenuCommands`) and `RibbonView`'s direct `dispatch:`
    /// parameter — computed once per body evaluation rather than
    /// constructed twice, so the two surfaces can never drift out of sync
    /// with each other's disabled-state flags.
    private var commandDispatch: CommandDispatch {
        CommandDispatch(
            perform: { action in
                switch action {
                case .clipboardCopy, .undo, .save, .saveAs, .zoomFit, .extractData, .importData: break
                case .selectMode: commandFocused = false
                default: commandFocused = true
                }
                performRegistryAction(action)
            },
            performRedo: { session.redo() },
            hasDocument: document != nil,
            isLoading: isLoading,
            hasSelection: !selection.isEmpty,
            canUndo: session.canUndo,
            canRedo: session.canRedo,
            canPaste: { PasteboardSnapshot.read(from: .general) != nil },
            pasteAtOriginalCoordinates: { pasteAtOriginalCoordinates() },
            showUnits: { inspector = .units },
            toggleLayers: { sidebarVisibility = sidebarVisibility == .detailOnly ? .all : .detailOnly },
            showInfo: { inspector = .info }, showSearch: toggleSearch,
            toggleAssistant: { showAIAssistant.toggle() },
            zoomIn: { zoomAtCenter(by: 1.7) }, zoomOut: { zoomAtCenter(by: 0.59) }
        )
    }

    private var fileDispatch: FileDispatch {
        FileDispatch(ready: document != nil && !isLoading,
            open: { isImporterPresented = true }, openURL: { onOpenInNewTab($0) },
            newTab: onNewTab, close: { session.persistWorkspace(); session.checkpointRecovery(); onCloseTab() },
            save: saveDrawing, saveAs: saveDrawingAs,
            reload: {
                if session.hasUnsavedChanges {
                    let alert = NSAlert()
                    alert.messageText = "Reload from disk?"
                    alert.informativeText = "Your current edits will be kept in a recovery copy, available from File → Recover Unsaved Drawings."
                    alert.addButton(withTitle: "Reload"); alert.addButton(withTitle: "Cancel")
                    guard alert.runModal() == .alertFirstButtonReturn else { return }
                    session.checkpointRecovery()
                }
                reloadDocument()
            }, exportPDF: { showingPDFExport = true }, exportMarkup: saveMarkupAsDXF, recover: onRecover)
    }

    private func locateImagesFolder() {
        guard let regen else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.title = "Locate Drawing Images"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        regen.parsed.resourceDirectories.insert(url, at: 0)
        regen.fullRebuild(); session.objectWillChange.send()
        session.persistWorkspace()
    }

    private func zoomToLayer(_ id: Int) {
        guard document != nil, let target = session.currentLayerUsage[id]?.bounds,
              !target.isNull else { return }
        visibility.hiddenLayerIds.remove(id)
        fit(to: target.insetBy(dx: -max(target.width * 0.04, 0.01), dy: -max(target.height * 0.04, 0.01)))
    }

    private func saveViewPreset() {
        let alert = NSAlert()
        alert.messageText = "Save View Preset"
        alert.informativeText = "Remember this sheet, zoom, and layer visibility."
        let input = NSTextField(string: "")
        input.placeholderString = "Furniture review"
        input.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        alert.accessoryView = input
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = input
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { session.savePreset(name: name) }
    }

    private func commitPendingText() {
        guard let pos = pendingTextPos else { return }
        let trimmed = pendingTextInput.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingTextPos = nil
        pendingTextInput = ""
        guard !trimmed.isEmpty else { return }
        // Height chosen so the note is ~18 pt tall at the current zoom.
        let h = 18 / max(zoom, 1e-12)
        commitDrawn(DrawnEntity(shape: .text(position: pos, height: h, string: trimmed)))
    }

    // MARK: - Toolbar

    /// Runs whenever `StatusBarView`'s Model/Paper `Picker` changes —
    /// extracted verbatim from the old inline `.onChange(of: space)` that
    /// used to sit directly on that Picker in `toolbar` (see git history)
    /// now that the Picker itself lives in `App/StatusBarView.swift`.
    /// Clearing selection/cancelling every modal tool on a space switch is
    /// load-bearing (a tool holding onto model-space EntityIDs/points would
    /// otherwise silently keep operating after the user switches to paper
    /// space, or vice versa) — unchanged behavior, just relocated to a named
    /// function so it can be passed as a closure across the view boundary.
    private func handleSpaceChanged() {
        selection = []; moveState = MoveState(); cancelModify(); cancelTrimExtend(); cancelFilletChamfer(); cancelOffset();
        fitToView()
    }

    private var quickAccessControls: some View {
        Group {
            Menu("File") { FileMenuItems(dispatch: fileDispatch) }
                .fixedSize().fontWeight(.semibold)
            Button(action: saveDrawing) { Image(systemName: "square.and.arrow.down") }
                .help("Save (⌘S)").accessibilityLabel("Save")
                .disabled(document == nil || isLoading)
            Button(action: undoLast) { Image(systemName: "arrow.uturn.backward") }
                .help("Undo (⌘Z)").accessibilityLabel("Undo").disabled(!session.canUndo)
            Button { session.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .help("Redo (⇧⌘Z)").accessibilityLabel("Redo").disabled(!session.canRedo)
        }.buttonStyle(.borderless).controlSize(.regular)
    }

    private var documentTitle: some View {
        HStack(spacing: 6) {
            Text(currentSourceURL?.lastPathComponent ?? "Open a drawing")
                .font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                .help(currentSourceURL?.path ?? "Open a drawing to begin")
            if session.hasUnsavedChanges {
                Circle().fill(.secondary).frame(width: 6, height: 6).help("Unsaved changes")
            }
        }.frame(maxWidth: 360)
    }

    private var assistantToggle: some View {
            Toggle(isOn: $showAIAssistant) {
                Label("AI Assistant", systemImage: "sparkles")
            }
            .toggleStyle(.button)
            .help("Show/hide the AI Assistant")
            .disabled(document == nil)
            // Right-click the toolbar button to switch presentation without
            // first having to open the panel and find its header button —
            // also how a user who somehow lost track of a floating panel can
            // bring it back to a known place (docking re-anchors it).
            .contextMenu {
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { aiAssistantFloating = true }
                    showAIAssistant = true
                } label: {
                    Label("Float Window", systemImage: "macwindow.on.rectangle")
                }
                .disabled(showAIAssistant && aiAssistantFloating)
                Button {
                    withAnimation(.easeOut(duration: 0.18)) { aiAssistantFloating = false }
                    showAIAssistant = true
                } label: {
                    Label("Dock to Side", systemImage: "arrow.down.right.and.arrow.up.left.rectangle")
                }
                .disabled(showAIAssistant && !aiAssistantFloating)
                Divider()
                Button {
                    // Recenters/resizes the floating panel to its default spot
                    // — the recovery path if it ends up somewhere awkward.
                    aiAssistantFrame = nil
                    aiAssistantFloating = true
                    showAIAssistant = true
                } label: {
                    Label("Reset Panel Position", systemImage: "arrow.counterclockwise")
                }
            }

    }

    private var allToolsMenu: some View {
            Menu {
                Button { setTool(select: true) } label: {
                    Label("Select", systemImage: "cursorarrow")
                }
                Button { startMove() } label: {
                    Label("Move", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                }
                .disabled(selection.isEmpty)
                Button { startModify(.copy) } label: {
                    Label("Duplicate", systemImage: "plus.square.on.square")
                }
                Button { startModify(.rotate) } label: {
                    Label("Rotate", systemImage: "rotate.right")
                }
                Button { startModify(.scale) } label: {
                    Label("Scale", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                Button { startModify(.mirror) } label: {
                    Label("Mirror", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                }
                Divider()
                Button { setMeasure(.distance) } label: {
                    Label("Measure Distance", systemImage: "ruler")
                }
                Button { setMeasure(.area) } label: {
                    Label("Measure Area", systemImage: "skew")
                }
                Button { setMeasure(.radius) } label: {
                    Label("Measure Radius", systemImage: "circle.dashed")
                }
                Button { setMeasure(.angle) } label: {
                    Label("Measure Angle", systemImage: "angle")
                }
                Divider()
                Button { startDimensionTool(kind: .aligned) } label: {
                    Label("Dimension (Aligned)", systemImage: "ruler")
                }
                Button { startDimensionTool(kind: .linear) } label: {
                    Label("Dimension (Linear)", systemImage: "ruler.fill")
                }
                Divider()
                Button { setDraft(.line) } label: {
                    Label("Line", systemImage: "line.diagonal")
                }
                Button { setDraft(.polyline) } label: {
                    Label("Polyline", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                }
                Button { setDraft(.circle) } label: {
                    Label("Circle", systemImage: "circle")
                }
                Button { setDraft(.arc3pt) } label: {
                    Label("Arc, 3 points", systemImage: "point.3.connected.trianglepath.dotted")
                }
                Button { setDraft(.rect) } label: {
                    Label("Rectangle", systemImage: "rectangle")
                }
                Button { setDraft(.polygon) } label: {
                    Label("Polygon", systemImage: "hexagon")
                }
                Button { setDraft(.text) } label: {
                    Label("Text Note", systemImage: "textformat")
                }
                Divider()
                Button { setDraft(.ellipse) } label: {
                    Label("Ellipse", systemImage: "oval")
                }
                Button { setDraft(.pointEnt) } label: {
                    Label("Point", systemImage: "smallcircle.filled.circle")
                }
                Button { setDraft(.splineFit) } label: {
                    Label("Spline", systemImage: "scribble")
                }
                Button { setDraft(.splineCV) } label: {
                    Label("Spline (Control Vertices)", systemImage: "point.3.connected.trianglepath.dotted")
                }
                Button { setDraft(.face3d) } label: {
                    Label("3D Face", systemImage: "triangle")
                }
                Button { setDraft(.region) } label: {
                    Label("Region", systemImage: "square.dashed")
                }
                Button { startArray() } label: {
                    Label("Array…", systemImage: "square.grid.3x3")
                }
                if let doc = document, !doc.stampableBlockNames.isEmpty {
                    Menu {
                        ForEach(doc.stampableBlockNames.prefix(60), id: \.self) { name in
                            Button {
                                stampBlockName = name
                                setDraft(.stamp)
                            } label: {
                                Label(LayerDisplayName.display(name, inEnglish: englishNames), systemImage: stampBlockName == name
                                      ? "checkmark.square" : "square.on.square")
                            }
                        }
                    } label: {
                        Label("Stamp Block…", systemImage: "square.on.square")
                    }
                }
                Button { startBlock() } label: {
                    Label("Block", systemImage: "cube")
                }
                if let doc = document, !doc.stampableBlockNames.isEmpty {
                    Menu {
                        ForEach(doc.stampableBlockNames.prefix(60), id: \.self) { name in
                            Button {
                                startInsert(blockName: name)
                            } label: {
                                Label(LayerDisplayName.display(name, inEnglish: englishNames), systemImage: "cube.transparent")
                            }
                        }
                    } label: {
                        Label("Insert Block…", systemImage: "cube.transparent")
                    }
                }
                Button { startExplode() } label: {
                    Label("Explode", systemImage: "square.dashed")
                }
                Button { startAttachXref() } label: {
                    Label("Attach Xref…", systemImage: "link")
                }
                Divider()
                Button { copySelectionToPasteboard() } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .disabled(selection.isEmpty)
                Button { startClipboardPaste() } label: {
                    Label("Paste…", systemImage: "doc.on.clipboard")
                }
                .disabled(PasteboardSnapshot.read(from: .general) == nil)
                Button { pasteAtOriginalCoordinates() } label: {
                    Label("Paste at Original Coordinates", systemImage: "arrow.down.doc")
                }
                .disabled(PasteboardSnapshot.read(from: .general) == nil)
                Divider()
                Button { setDraft(.erase) } label: {
                    Label("Erase Markup", systemImage: "eraser")
                }
                Button {
                    undoLast()
                } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                    .disabled(!session.canUndo)
                Divider()
                Button { saveMarkupAsDXF() } label: {
                    Label("Export Markup as DXF…", systemImage: "square.and.arrow.up")
                }
                .disabled(!hasMarkup)
                Button { saveMergedCopy() } label: {
                    Label("Save Copy with Markup…", systemImage: "square.and.arrow.down.on.square")
                }
                .disabled(!hasMarkup || document?.sourceDXFURL == nil)
                Divider()
                Button { extractDataToCSV() } label: {
                    Label("Extract Data…", systemImage: "tablecells")
                }
                Button { importDataFromCSV() } label: {
                    Label("Import Data…", systemImage: "square.and.arrow.down.on.square.fill")
                }
            } label: {
                Label("All tools", systemImage: "square.grid.2x2")
            }
            .fixedSize()
            .disabled(document == nil || isLoading)


    }

    private var savedViewsMenu: some View {
            Menu("Saved views") {
                Button("Save View Preset…", action: saveViewPreset)
                ForEach(session.presets) { preset in
                    Button(preset.name) { handleSpaceChanged(); _ = session.restoreWorkspace(preset.workspace) }
                }
                if !session.presets.isEmpty {
                    Menu("Delete Preset") {
                        ForEach(session.presets) { preset in
                            Button(preset.name) { session.deletePreset(preset.id) }
                        }
                    }
                }
            }.disabled(document == nil || isLoading)

    }

    private var workspaceStrip: some View {
        HStack(spacing: 12) {
            SheetNavigationView(space: Binding(get: { space }, set: { space = $0 }),
                sheets: regen?.parsed.paperLayouts ?? [], activeID: regen?.parsed.activePaperLayoutID,
                onSpaceChanged: handleSpaceChanged, onSelect: selectPaperSheet)
            Spacer(minLength: 0)
            Picker("Current layer", selection: $session.currentProperties.layerName) {
                if let doc = document {
                    ForEach(doc.layers, id: \.name) { layer in
                        Text(LayerDisplayName.display(layer.name, inEnglish: englishNames)).tag(layer.name)
                    }
                }
            }.frame(maxWidth: 220).help("Layer for new geometry")
            markupColorMenu
        }
        .disabled(document == nil || isLoading)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func selectPaperSheet(_ id: UInt64) {
        regen?.selectPaperLayout(id)
        session.objectWillChange.send()
        handleSpaceChanged()
        session.persistWorkspace()
        if searchVisible { runSearch() }
    }

    @ViewBuilder
    private func ribbonExtras(_ tab: RibbonTab) -> some View {
        switch tab {
        case .home:
            RibbonGroup(title: "Workspace") {
                VStack(alignment: .leading, spacing: 3) {
                    Button { showAIAssistant.toggle() } label: { Label("AI Assistant", systemImage: "sparkles") }
                    Button(action: toggleSearch) { Label("Find in drawing", systemImage: "magnifyingglass") }
                }.buttonStyle(RibbonButtonStyle()).disabled(document == nil || isLoading)
            }
        case .draw:
            RibbonGroup(title: "More tools") { allToolsMenu }
        case .modify, .annotate: EmptyView()
        case .view:
            RibbonGroup(title: "Zoom") {
                VStack(alignment: .leading, spacing: 3) {
                    Button(action: fitButtonPressed) { Label("Fit drawing", systemImage: "arrow.up.left.and.arrow.down.right") }
                    HStack(spacing: 0) {
                        Button { zoomAtCenter(by: 1.7) } label: { Label("In", systemImage: "plus.magnifyingglass") }
                        Button { zoomAtCenter(by: 0.59) } label: { Label("Out", systemImage: "minus.magnifyingglass") }
                    }
                }.buttonStyle(RibbonButtonStyle()).disabled(document == nil || isLoading)
            }
            RibbonGroup(title: "Workspace") {
                VStack(alignment: .leading, spacing: 6) {
                    savedViewsMenu
                    Toggle("Dark canvas", isOn: $darkBackground).toggleStyle(.checkbox)
                }.padding(.top, 3).frame(minWidth: 140, alignment: .leading)
            }
            RibbonGroup(title: "Drawing") {
                VStack(alignment: .leading, spacing: 3) {
                    unitsButton
                    Button { inspector = .info } label: { Label("Drawing info", systemImage: "info.circle") }
                }.buttonStyle(RibbonButtonStyle()).disabled(document == nil || isLoading)
            }
        }
    }

    private var unitsButton: some View {
        Button { inspector = .units } label: { Label("Units & format", systemImage: "ruler.fill") }
            .buttonStyle(RibbonButtonStyle()).disabled(document == nil || isLoading)
    }

    private var unitNotice: String? { document.flatMap { DrawingDiagnostics.unitNotice(in: $0) } }
    private var drawingIssues: [String] { (document?.renderingWarnings ?? []) + [unitNotice].compactMap { $0 } }

    @ViewBuilder private var inspectorCard: some View {
        if let inspector {
            WorkspaceInspectorCard(title: inspector.rawValue, onClose: { self.inspector = nil }) {
                switch inspector {
                case .units: unitsPopover
                case .info: if let doc = document { fileInfoPopover(doc) }
                case .issues:
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(drawingIssues, id: \.self) { issue in
                                Text(issue).font(.callout).fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                            }
                        }
                    }.frame(height: min(300, CGFloat(drawingIssues.count) * 95))
                    Button("Locate Images Folder…", action: locateImagesFolder)
                case .quality:
                    Picker("Rendering quality", selection: $settings.renderQuality) {
                        Text("1 — Fastest").tag(1)
                        Text("2 — Fast").tag(2)
                        Text("3 — Balanced (recommended)").tag(3)
                        Text("4 — Fine").tag(4)
                        Text("5 — Highest detail").tag(5)
                    }.pickerStyle(.radioGroup).labelsHidden()
                    Text("Higher detail can slow redraws on large drawings.").font(.caption).foregroundStyle(.secondary)
                    Button("Reset to Default") { settings.renderQuality = 3 }
                }
            }
        }
    }

    private var activeRibbonAction: CommandAction? {
        if modifyState.isActive { return .modify(modifyState.command) }
        if trimExtendState.isActive { return .trimExtend(trimExtendState.command) }
        if stretchState.isActive { return .stretch }
        if filletChamferState.isActive { return .filletChamfer(filletChamferState.command) }
        if offsetState.isActive { return .offset }
        if dimensionToolState.isActive { return .dimension(dimensionToolState.kind) }
        if blockToolState.isActive { return .blockCommand(blockToolState.command) }
        if clipboardPasteToolState.isActive { return .clipboardPaste }
        if arrayToolState.isActive { return .array }
        if moveState.isActive { return .moveTool }
        if explodeAwaitingSelection { return .explode }
        if joinAwaitingSelection { return .join }
        if awaitingAttEditPick { return .attedit }
        if awaitingAttdefPlacement { return .attdef }
        if xrefAttachToolState.isActive { return nil }
        if draft.isActive { return .tool(draft.mode) }
        switch measure.mode {
        case .distance: return .measureDistance
        case .area: return .measureArea
        case .radius: return .measureRadius
        case .angle: return .measureAngle
        case .select: return .selectMode
        }
    }

    private var unitsPopover: some View {
        VStack(alignment: .leading, spacing: 12) {

            VStack(alignment: .leading, spacing: 4) {
                Text("Length format").font(.caption).foregroundColor(.secondary)
                Picker("", selection: $settings.lengthStyleRaw) {
                    ForEach(LengthStyle.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.menu).labelsHidden().frame(width: 220)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Unit system").font(.caption).foregroundColor(.secondary)
                Picker("", selection: $settings.unitSystemRaw) {
                    ForEach(UnitSystem.allCases) { Text($0.label).tag($0.rawValue) }
                }
                .pickerStyle(.menu).labelsHidden().frame(maxWidth: .infinity)
                .disabled(currentFormat.style.isFeetInches)
                if currentFormat.style.isFeetInches {
                    Text("Architectural/Engineering always use feet & inches.")
                        .font(.caption2).foregroundColor(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                let frac = (LengthStyle(rawValue: lengthStyleRaw) ?? .decimal) == .architectural
                    || (LengthStyle(rawValue: lengthStyleRaw) ?? .decimal) == .fractional
                Text(frac ? "Smallest fraction: 1/\(1 << min(max(unitPrecision,0),6))"
                          : "Decimal places: \(min(max(unitPrecision,0),8))")
                    .font(.caption).foregroundColor(.secondary)
                HStack(spacing: 6) {
                    TextField("Decimal places", value: Binding(get: { settings.unitPrecision },
                        set: { settings.unitPrecision = min(max($0, 0), frac ? 6 : 8) }), format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 55)
                    Stepper("Precision", value: $settings.unitPrecision, in: 0...(frac ? 6 : 8)).labelsHidden()
                }
            }

            if let doc = document {
                Text(doc.unitsLabel.isEmpty ? "Drawing units: unspecified"
                     : "Drawing units: \(doc.unitsLabel)")
                    .font(.caption2).foregroundColor(.secondary)
            }
            if let unitNotice { Text(unitNotice).font(.caption).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Text("Example:").font(.caption).foregroundColor(.secondary)
                Text(currentFormat.length(66.5)).font(.caption).bold()
            }
            Button("Reset") { unitSystemRaw = UnitSystem.asDrawn.rawValue
                lengthStyleRaw = LengthStyle.decimal.rawValue; unitPrecision = 2 }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fileInfoPopover(_ doc: DXFDocument) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("File statistics").font(.headline)
            Text("Entities rendered: \(doc.stats.totalEntities)")
            Text("Layers used in file: \(regen?.layerIdsWithLiveEntities().count ?? doc.layers.filter { $0.entityCount > 0 }.count) of \(doc.layers.count)")
            Text("Includes all sheets and block definitions").font(.caption).foregroundStyle(.secondary)
            Text("Layers on this \(space == .paper ? "sheet" : "model"): \(session.currentLayerUsage.count)")
            Text("Render groups: \(doc.modelGroups.count) model, \(doc.paperGroups.count) paper")
            Text(String(format: "Parse: %.1fs · Geometry: %.1fs",
                        doc.stats.parseSeconds, doc.stats.buildSeconds))
            if doc.stats.truncated {
                Text("Very large drawing — some entities were omitted.")
                    .foregroundColor(.orange)
            }
            if !doc.stats.skippedTypes.isEmpty {
                Divider()
                Text("Unsupported entity types:").font(.caption).bold()
                ForEach(doc.stats.skippedTypes.sorted { $0.value > $1.value }
                    .prefix(8), id: \.key) { k, v in
                    Text("\(k): \(v)").font(.caption).foregroundColor(.secondary)
                }
            }
        }
        .padding(14)
        .frame(minWidth: 280)
    }

    // MARK: - Drawing area

    private var drawingArea: some View {
        GeometryReader { proxy in
            ZStack {
                if let doc = document {
                    DXFCanvasView(
                        document: doc,
                        params: renderParams(),
                        measure: measure,
                        dimension: dimensionToolState,
                        draft: draft,
                        move: moveState,
                        modify: modifyState,
                        stretch: stretchState,
                        moveGhost: moveGhostEntities,
                        modifyGhost: modifyGhostEntities,
                        modifyMirrorLine: modifyMirrorLine,
                        arrayGhost: arrayGhostEntities,
                        stretchGhost: stretchGhostEntities,
                        eraseCandidateShape: eraseCandidateShape,
                        trimExtendHoverShape: trimExtendHoverShape,
                        filletChamferOffsetHoverShape: filletChamferOffsetHoverShape,
                        stampGhost: stampGhost,
                        markupColorACI: markupColor,
                        halo: halo,
                        measureFormat: currentFormat,
                        gripPoints: gripDisplayPoints,
                        gripDrag: gripDragState,
                        gripDragGhost: gripDragGhostShape,
                        onScrollZoom: { factor, location in
                            animationTimer?.invalidate()
                            zoomAt(point: location, by: factor)
                        },
                        onPan: { delta in
                            animationTimer?.invalidate()
                            pan = CGSize(width: pan.width + delta.width,
                                         height: pan.height + delta.height)
                        },
                        onClick: { location, shiftDown in
                            handleClick(at: location, shiftDown: shiftDown)
                        },
                        onDoubleClick: { location in handleFinishGesture(at: location) },
                        onHover: { location in handleHover(at: location) },
                        onEscape: { handleEscape() },
                        onReturnKey: {
                            if draft.mode == .polyline || draft.mode == .splineFit || draft.mode == .splineCV
                                || measure.mode == .area { handleFinishGesture() }
                            else if modifyState.phase == .selecting { finishSelectionPrompt() }
                            else if modifyState.phase == .pickDestination { finishModifyDestinationLoop() }
                            else if trimExtendState.phase == .selectingBoundaries { finishTrimExtendBoundaryPrompt() }
                            else if trimExtendState.phase == .pickingTargets { finishTrimExtendTargetLoop() }
                            else if stretchState.phase == .selecting { finishStretchSelectionPrompt() }
                            else if blockToolState.phase == .selecting { finishBlockSelectionPrompt() }
                            else if explodeAwaitingSelection { finishExplodeSelectionPrompt() }
                            else if joinAwaitingSelection { finishJoinSelectionPrompt() }
                            else if arrayToolState.phase == .selecting { finishArraySelectionPrompt() }
                            else if arrayToolState.phase == .pickFields { commitArrayFromCurrentFields() }
                            commandFocused = true
                        },
                        onBoxSelect: { start, end, mode, shiftDown in
                            handleBoxSelect(startView: start, endView: end, mode: mode, shiftDown: shiftDown)
                        },
                        onLassoSelect: { points, mode, shiftDown in
                            handleLassoSelect(viewPoints: points, mode: mode, shiftDown: shiftDown)
                        },
                        onDeleteSelection: { deleteSelection() },
                        onContextMenu: { location in contextMenuItems(at: location) },
                        onGripMouseDown: { location in handleGripMouseDown(at: location) },
                        onGripDrag: { location in handleGripDrag(at: location) },
                        onGripDragEnd: { location in handleGripMouseUp(at: location) }
                    )
                    .overlay(alignment: .bottomTrailing) {
                        Text(String(format: "zoom %.4g", zoom))
                            .font(.caption).monospacedDigit()
                            .padding(6)
                            .background(.black.opacity(0.5))
                            .foregroundColor(.white)
                            .cornerRadius(6)
                            .padding(10)
                    }
                    .overlay(alignment: .topLeading) {
                        // On-canvas format switcher for a single selected
                        // DIMENSION — per explicit product requirement, this
                        // control lives ON THE CANVAS (near the selected
                        // dimension), NOT in the Properties panel. Only
                        // appears for a NovaCAD-authored dimension (one
                        // carrying `DimensionTool`'s own XDATA metadata) —
                        // a DIMENSION round-tripped from some other source
                        // has no per-entity format override to edit here.
                        if let (dimId, formatInfo) = selectedDimensionFormatInfo() {
                            DimensionFormatBadge(current: formatInfo.format) { newFormat in
                                setDimensionFormat(dimId, to: newFormat)
                            }
                            .padding(10)
                        }
                    }
                } else {
                    Color(red: 0.13, green: 0.16, blue: 0.19)
                    if !isLoading {
                        VStack(alignment: .leading, spacing: 14) {
                            Label("NovaCAD", systemImage: "square.3.layers.3d")
                                .font(.system(size: 23, weight: .semibold))
                            Text("Open a drawing").font(.title3)
                            Text("Explore sheets, organize layers, and mark up your plans.")
                                .foregroundStyle(.secondary)
                            Button { isImporterPresented = true } label: {
                                Label("Open DWG or DXF…", systemImage: "folder")
                            }.buttonStyle(.borderedProminent).controlSize(.large)
                            Text("You can also drop a drawing or drawing package here.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(28).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
            }
            .overlay {
                if !isLoading, space == .model, let doc = document,
                   doc.modelGroups.isEmpty, doc.modelImages.isEmpty {
                    VStack(spacing: 10) {
                        Text("Model space is empty").font(.headline)
                        if let layouts = regen?.parsed.paperLayouts, !layouts.isEmpty {
                            Text("This drawing contains \(layouts.count) paper sheets.").foregroundStyle(.secondary)
                            Button("Show Paper Sheets") { space = .paper; handleSpaceChanged() }
                        }
                    }.padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
            }
            .overlay {
                if isLoading {
                    VStack(spacing: 12) {
                        Text(currentSourceURL?.lastPathComponent ?? "Opening drawing")
                            .font(.headline).lineLimit(1).truncationMode(.middle).frame(width: 300)
                        ProgressView(value: loadProgress) {
                            Text(loadProgress < 0.08 ? "Preparing drawing…" : loadProgress < 0.8 ? "Reading drawing…" : "Preparing canvas…")
                        }
                            .progressViewStyle(.linear)
                            .frame(width: 300)
                        Text(String(format: "%.0f%%", loadProgress * 100))
                            .font(.caption).foregroundColor(.secondary)
                        // Names the xref currently being merged (the slowest
                        // stage on a large multi-xref eTransmit package —
                        // see `PackageLoader.XrefProgress`'s doc comment).
                        // Nil outside that stage, so this row simply doesn't
                        // appear during the main-file parse/DWG-conversion
                        // stages, matching the plain-file-open experience.
                        if let name = loadingXrefName {
                            Text("Resolving xref \(loadingXrefIndex)/\(loadingXrefTotal): \(name)")
                                .font(.caption2).foregroundColor(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                                .frame(width: 300)
                        }
                        // A large eTransmit package's xref resolution can
                        // legitimately still take minutes even after fixing
                        // the O(n²) `children(of:)` merge cost (see
                        // `EntityStore.childrenByParent()`) — several
                        // hundred-MB xref DXFs with millions of entities
                        // each simply take real wall-clock time to parse and
                        // copy. Cancel lets a user back out of an
                        // unexpectedly large load instead of force-quitting.
                        Button("Cancel") { loadCancelRequested = true }
                            .buttonStyle(.bordered)
                            .disabled(loadCancelRequested)
                    }
                    .padding(20).background(.regularMaterial).cornerRadius(12)
                }
            }
            // The FLOATING AI Assistant hovers over the canvas (rather than
            // narrowing it, as the docked presentation does). Anchored
            // `.topLeading` so `FloatingPanelFrame`'s origin is a plain
            // top-left offset in this container's coordinate space, which is
            // exactly what its clamping math assumes.
            .overlay(alignment: .topLeading) {
                if showAIAssistant && aiAssistantFloating {
                    FloatingAIAssistantPanel(
                        aiSession: session.aiAssistant,
                        regen: regen,
                        visibility: visibility,
                        selectionProvider: { [weak session = session] in session?.selection ?? [] },
                        onApplyEdits: applyAIProposedEdits,
                        onApplyGeometry: applyAIProposedGeometry,
                        onClose: { showAIAssistant = false },
                        onDock: { withAnimation(.easeOut(duration: 0.18)) { aiAssistantFloating = false } },
                        containerSize: proxy.size,
                        frame: Binding(
                            get: { aiAssistantFrame ?? FloatingPanelFrame.defaultFrame(in: proxy.size) },
                            set: { aiAssistantFrame = $0 })
                    )
                }
            }
            .onAppear { viewSize = proxy.size }
            .onChange(of: proxy.size) { _, newSize in
                let oldSize = viewSize
                let hadSize = oldSize.width > 1
                let fitPan = CGSize(width: oldSize.width / 2 + (bounds.midX - fullBounds.midX) * zoom,
                                    height: oldSize.height / 2 - (bounds.midY - fullBounds.midY) * zoom)
                let wasFitted = hadSize && abs(zoom - fitZoom(for: fullBounds)) < max(zoom * 0.01, 1e-9)
                    && abs(pan.width - fitPan.width) < 2 && abs(pan.height - fitPan.height) < 2
                viewSize = newSize
                if let saved = session.pendingWorkspace { _ = session.restoreWorkspace(saved) }
                else if searchVisible, searchResults.indices.contains(searchCursor) { performGoTo(hit: searchResults[searchCursor]) }
                else if !hadSize { fitToView() }
                else if wasFitted { fitButtonPressed() }
                else {
                    pan.width += (newSize.width - oldSize.width) / 2
                    pan.height += (newSize.height - oldSize.height) / 2
                }
            }
        }
    }

    // MARK: - Deep search

    private func toggleSearch() {
        searchVisible.toggle()
        if searchVisible {
            DispatchQueue.main.async { searchFocused = true }
        } else {
            closeSearch()
        }
    }

    private func closeSearch() {
        searchVisible = false
        searchFocused = false
        searchQuery = ""
        searchResults = []
        searchCursor = -1
    }

    private func runSearch() {
        if let doc = document, searchIndex?.documentID != ObjectIdentifier(doc) {
            searchIndex = SearchIndex(document: doc, store: regen?.parsed.store)
        }
        searchResults = searchIndex?.search(searchQuery) ?? []
        searchCursor = searchResults.isEmpty ? -1 : 0
        if let first = searchResults.first { goTo(hit: first) }
    }

    private func nextHit(_ direction: Int = 1) {
        guard !searchResults.isEmpty else { return }
        if searchCursor < 0 {
            searchCursor = direction > 0 ? 0 : searchResults.count - 1
        } else {
            searchCursor = ((searchCursor + direction) % searchResults.count
                            + searchResults.count) % searchResults.count
        }
        goTo(hit: searchResults[searchCursor])
    }

    /// The "N-iteration" re-centering engine: animate pan/zoom to center the
    /// hit, select it, and flash an outline for 3s.
    private func goTo(hit: SearchHit) {
        let wantPaper = hit.isPaper
        if (space == .paper) != wantPaper {
            space = wantPaper ? .paper : .model
            // Space switch refits the view on the next runloop turn; navigate after.
            DispatchQueue.main.async { self.performGoTo(hit: hit) }
        } else {
            performGoTo(hit: hit)
        }
    }

    private func performGoTo(hit: SearchHit) {
        if let doc = document,
           let id = HitTester.resolveEntityID(hit.ref, document: doc, usePaperSpace: hit.isPaper) {
            selection = [id]
        }

        // Zoom: keep the current level if the target is comfortably visible,
        // else zoom so its text height lands around 40 points.
        var targetZoom = zoom
        if hit.screenHeightHint > 0 {
            let current = hit.screenHeightHint * zoom
            if current < 14 || current > 300 { targetZoom = 40 / hit.screenHeightHint }
        }
        targetZoom = max(1e-9, min(targetZoom, 1e9))

        let sx = targetZoom * (hit.position.x - bounds.midX)
        let sy = -targetZoom * (hit.position.y - bounds.midY)
        let targetPan = CGSize(width: viewSize.width / 2 - sx,
                               height: viewSize.height / 2 - sy)
        animateViewport(toZoom: targetZoom, pan: targetPan)
        halo = SearchHalo(position: hit.position,
                          worldRadius: hit.screenHeightHint * 1.6,
                          until: Date().addingTimeInterval(3), bounds: hit.bounds)
    }

    private func animateViewport(toZoom targetZoom: CGFloat, pan targetPan: CGSize,
                                 duration: TimeInterval = 0.45) {
        animationTimer?.invalidate()
        let z0 = zoom, p0 = pan
        let start = Date()
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { t in
            let x = min(1, Date().timeIntervalSince(start) / duration)
            let e = x < 0.5 ? 2 * x * x : 1 - pow(-2 * x + 2, 2) / 2   // easeInOutQuad
            zoom = z0 * pow(targetZoom / z0, e)        // log-space zoom feels natural
            pan = CGSize(width: p0.width + (targetPan.width - p0.width) * e,
                         height: p0.height + (targetPan.height - p0.height) * e)
            if x >= 1 { t.invalidate() }
        }
    }

    private var searchBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("Search text, labels, block names…", text: $session.searchQuery)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { nextHit() }
                    .onExitCommand { closeSearch() }
                    .frame(width: 260)
                if !searchResults.isEmpty {
                    Text(searchCursor >= 0
                         ? "\(searchCursor + 1) of \(searchResults.count)"
                         : "\(searchResults.count) found")
                        .font(.caption).monospacedDigit()
                        .foregroundColor(.secondary)
                    Button { nextHit(-1) } label: { Image(systemName: "chevron.up") }
                        .buttonStyle(.plain)
                    Button { nextHit(1) } label: { Image(systemName: "chevron.down") }
                        .buttonStyle(.plain).accessibilityLabel("Next search match")
                    Menu {
                        ForEach(searchResults) { hit in
                            Button(hit.label) {
                                searchCursor = searchResults.firstIndex(of: hit) ?? 0
                                goTo(hit: hit)
                            }
                        }
                    } label: {
                        Text(searchResults[max(0, searchCursor)].label).lineLimit(1).truncationMode(.tail)
                    }.frame(maxWidth: 300)

                } else if searchQuery.count >= 2 {
                    Text("No matches").font(.caption).foregroundColor(.secondary)
                }
                Button { closeSearch() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)


        }
        .background(.regularMaterial)
        .cornerRadius(10)
        .shadow(radius: 8)
        .padding(.top, 10)
        .onChange(of: searchQuery) { _, _ in runSearch() }
    }

    // MARK: - Command palette
    //
    // The "/" autocomplete popover sources its suggestions from
    // `CommandRegistry.complete(prefix:limit:)` via `commandLine.suggestions`
    // (see Commands/CommandRegistry.swift, Commands/CommandLineState.swift)
    // instead of a locally-filtered static array.

    private var showCommandSuggestions: Bool {
        commandLine.text.hasPrefix("/")
    }

    private var commandSuggestionsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            if commandLine.suggestions.isEmpty {
                Text("No matching commands").font(.caption).foregroundColor(.secondary).padding(10)
            } else {
                ForEach(commandLine.suggestions) { entry in
                    Button {
                        commandLine.text = entry.name
                        executeCommand()
                        commandFocused = true
                    } label: {
                        HStack {
                            Text(entry.name)
                                .font(.system(.caption, design: .monospaced)).bold()
                                .frame(width: 70, alignment: .leading)
                            Text(entry.desc).font(.caption)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                }
            }
        }
        .frame(width: 240)
        .padding(.vertical, 4)
    }

    /// Extracted from `commandBar`'s body (Phase 6.4): the giant nested
    /// ternary chain choosing which tool's prompt text to show started
    /// timing out the type checker once ARRAY's own branch was added — the
    /// exact SAME logic, just spelled as an ordinary `if/else if` chain
    /// (which type-checks each branch independently) instead of one huge
    /// single expression.
    private var commandBarPromptText: String {
        if modifyState.isActive {
            return modifyState.phase == .selecting ? (selectionPrompt?.promptText ?? modifyState.prompt) : modifyState.prompt
        } else if trimExtendState.isActive {
            return trimExtendState.phase == .selectingBoundaries ? (selectionPrompt?.promptText ?? trimExtendState.prompt) : trimExtendState.prompt
        } else if stretchState.isActive {
            // STRETCH manages its own acquisition count internally
            // (`StretchToolState.prompt`) rather than delegating to a
            // shared `selectionPrompt` — see that type's header comment for
            // why it doesn't reuse `SelectionPrompt` at all.
            return stretchState.prompt
        } else if filletChamferState.isActive {
            return filletChamferState.prompt
        } else if offsetState.isActive {
            return offsetState.prompt
        } else if dimensionToolState.isActive {
            return dimensionToolState.prompt
        } else if blockToolState.isActive {
            return blockToolState.phase == .selecting ? (selectionPrompt?.promptText ?? blockToolState.prompt) : blockToolState.prompt
        } else if arrayToolState.isActive {
            return arrayToolState.phase == .selecting ? (selectionPrompt?.promptText ?? arrayToolState.prompt) : arrayToolState.prompt
        } else if xrefAttachToolState.isActive {
            return xrefAttachToolState.prompt
        } else if clipboardPasteToolState.isActive {
            return clipboardPasteToolState.prompt
        } else if moveState.isActive {
            return moveState.prompt
        } else if draft.isActive {
            return draft.prompt
        } else if measure.isActive {
            return measure.mode == .distance ? "DIST — click two points" : "AREA — click boundary points"
        } else if let pending = pendingSetVar {
            return "Enter new value for \(pending) <\(sysVarDisplay(pending))>: "
        } else {
            return commandMessage.isEmpty ? "Command (L, PL, C, A, REC, M, E, DI, AA, Z — or x,y / @dx,dy / length)" : commandMessage
        }
    }

    private var commandBar: some View {
        HStack(spacing: 10) {
            Text(commandBarPromptText)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
            Spacer()
            ZStack(alignment: .leading) {
                // Ghost completion rendered behind the live text field: the
                // already-typed portion in clear text, the suggested
                // remainder dimmed — classic inline-autocomplete look.
                if !commandLine.ghost.isEmpty {
                    HStack(spacing: 0) {
                        Text(commandLine.text).opacity(0)
                        Text(commandLine.ghost).foregroundColor(.secondary.opacity(0.5))
                    }
                    .font(.system(.caption, design: .monospaced))
                    .padding(.horizontal, 8)
                    .allowsHitTesting(false)
                }
                TextField("Command", text: $commandLine.text)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                    .focused($commandFocused)
                    .help("Type a command and press Return, or type / to browse commands. Tab/→ accepts the suggestion, ↑/↓ recalls history.")
                    .onSubmit { executeCommand() }
                    .onExitCommand { commandLine.text = ""; commandLine.ghost = ""; handleEscape() }
                    .onChange(of: commandLine.text) { _, _ in commandLine.onTextChanged() }
                    .onKeyPress(.tab) {
                        guard !commandLine.ghost.isEmpty else { return .ignored }
                        commandLine.acceptGhost()
                        return .handled
                    }
                    .onKeyPress(.rightArrow) {
                        guard !commandLine.ghost.isEmpty else { return .ignored }
                        commandLine.acceptGhost()
                        return .handled
                    }
                    .onKeyPress(.upArrow) {
                        commandLine.recallHistory(direction: -1)
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        commandLine.recallHistory(direction: 1)
                        return .handled
                    }
            }
            .frame(width: 200)
            .popover(isPresented: Binding(
                get: { showCommandSuggestions },
                set: { if !$0 { commandLine.text = "" } })
            ) {
                commandSuggestionsList
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// Current value of a sysvar formatted for the "<default>" hint shown
    /// while prompting for a new value.
    private func sysVarDisplay(_ name: String) -> String {
        switch sysVars.get(name) {
        case .bool(let b): return b ? "1" : "0"
        case .int(let i): return "\(i)"
        case .double(let d): return "\(d)"
        case .string(let s): return s
        case .point2(let p): return "\(p.x),\(p.y)"
        case nil: return ""
        }
    }

    /// Parses a command-bar submission as a new value for `pendingSetVar`
    /// (the AutoCAD "type variable name, then type its new value" shortcut).
    /// Accepts bool-ish (0/1/true/false), integer, double, or "x,y" point
    /// input depending on the variable's current type; anything else reports
    /// an error and re-prompts for the same variable.
    private func applyPendingSetVar(_ raw: String, name: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }   // bare Enter: keep prompting
        pendingSetVar = nil
        guard let current = sysVars.get(name) else {
            commandMessage = "Unknown variable: \(name)"
            return
        }
        let candidate: SysVarValue?
        switch current {
        case .bool:
            switch trimmed.uppercased() {
            case "1", "TRUE", "ON": candidate = .bool(true)
            case "0", "FALSE", "OFF": candidate = .bool(false)
            default: candidate = nil
            }
        case .int:
            candidate = Int(trimmed).map { .int($0) }
        case .double:
            candidate = Double(trimmed).map { .double($0) }
        case .string:
            candidate = .string(trimmed)
        case .point2:
            let parts = trimmed.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            candidate = parts.count == 2 ? .point2(CGPoint(x: parts[0], y: parts[1])) : nil
        }
        guard let candidate, sysVars.set(name, candidate) != nil else {
            commandMessage = "Invalid value for \(name): \(trimmed)"
            return
        }
        commandMessage = "\(name) = \(sysVarDisplay(name))"
    }

    /// Second step of CHAMFER's "D"/"A" keyword entry (see the `.pickFirst`-
    /// phase guard in `executeCommand` for the first step) — parses the
    /// typed number and stores it, chaining `.distance1 -> .distance2` (D
    /// mode asks for both distances in sequence, matching AutoCAD) or
    /// completing after `.angleValue` (simplified single-step angle entry:
    /// this session's "A" flow asks for the angle directly against the
    /// PERSISTED d1, rather than AutoCAD's own 2-step "length along line1,
    /// then angle" — a deliberate, documented simplification given this
    /// phase's time budget; `session.chamferD1` remains settable via the
    /// "D" flow's first step for users who want to change it too).
    private func applyPendingFilletChamferEntry(_ raw: String, kind: PendingFilletChamferEntry) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }   // bare Enter: keep prompting
        pendingFilletChamferEntry = nil
        guard let value = Double(trimmed), value >= 0 else {
            commandMessage = "Chamfer — invalid distance/angle: \(trimmed)"
            return
        }
        switch kind {
        case .distance1:
            session.chamferD1 = value
            session.chamferUsesAngle = false
            pendingFilletChamferEntry = .distance2
            commandMessage = String(format: "Chamfer — specify second distance <%.4g>: ", session.chamferD2)
        case .distance2:
            session.chamferD2 = value
            commandMessage = String(format: "Chamfer — distances set to %.4g, %.4g", session.chamferD1, session.chamferD2)
        case .angleValue:
            session.chamferAngleDeg = value
            session.chamferUsesAngle = true
            commandMessage = String(format: "Chamfer — angle mode set: d1=%.4g, angle=%.4g°", session.chamferD1, value)
        case .filletRadius:
            // R=0 is a legitimate FILLETRAD (pure corner join, no arc) —
            // the outer guard above already rejects negative values.
            sysVars.set("FILLETRAD", .double(value))
            commandMessage = String(format: "Fillet — radius set to %.4g", value)
        }
    }

    private func executeCommand() {
        var input = commandLine.text
        commandLine.text = ""
        commandLine.ghost = ""
        if input.hasPrefix("/") { input.removeFirst() }

        // SETVAR shortcut, part 2: the previous submission was a bare sysvar
        // name, so THIS submission is the new value for it (regardless of
        // what it looks like — even if it happens to parse as a drafting
        // command token).
        if let pending = pendingSetVar {
            applyPendingSetVar(input, name: pending)
            commandLine.recordSubmitted(input)
            return
        }
        // CHAMFER "D"/"A" keyword entry, part 2: the previous submission
        // was "D" or "A" (see the `.pickFirst`-phase keyword guard below),
        // so THIS submission is the numeric value being entered.
        if let pending = pendingFilletChamferEntry {
            applyPendingFilletChamferEntry(input, kind: pending)
            commandLine.recordSubmitted(input)
            return
        }
        // Phase 6.1: BLOCK's name step / ATTDEF's tag->prompt->default chain
        // — same two-step "action, then value(s)" shape as the two guards
        // above, checked in the same position (before the empty-input
        // branch, since an EMPTY submission is itself meaningful here —
        // e.g. ATTDEF's prompt step accepts a blank prompt).
        if pendingBlockEntry != nil {
            applyPendingBlockNameEntry(input)
            commandLine.recordSubmitted(input)
            return
        }
        if let pending = pendingAttdefEntry {
            applyPendingAttdefEntry(input, kind: pending)
            commandLine.recordSubmitted(input)
            return
        }
        // Phase 6.4: ARRAY's kind choice / sequential field-value chain —
        // same "action, then value(s)" shape as BLOCK/ATTDEF above. Checked
        // BEFORE the empty-input branch since a bare Enter mid-field-entry
        // is itself meaningful (accepts the field's own shown default,
        // exactly like AutoCAD's own bracketed-default command-line prompts).
        if pendingArrayEntry != nil {
            applyPendingArrayEntry(input)
            commandLine.recordSubmitted(input)
            return
        }
        // Phase 6.3: CLAYER's value step.
        if pendingClayerEntry {
            applyPendingClayerEntry(input)
            commandLine.recordSubmitted(input)
            return
        }
        // Phase 6.3: ELLIPSE's "R" (rotation) keyword — value step. Checked
        // here (top of the function, alongside every other pending-entry
        // flag) rather than further down, specifically so a bare Enter
        // (which reaches this guard BEFORE the empty-input branch below)
        // cleanly falls through to "just keep prompting" instead of being
        // caught by an unrelated bare-Enter handler while the flag is still
        // stuck true — see the "R" keyword's own doc comment (just above,
        // in the executeCommand body) for the adversarial-review finding
        // this placement fixes.
        if pendingEllipseRotationAngle {
            let trimmed = input.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                // Bare Enter with the angle still pending: nothing to
                // commit yet (AutoCAD itself just re-prompts) — leave the
                // flag set and keep waiting rather than silently canceling
                // rotation mode entirely.
                commandLine.recordSubmitted(input)
                return
            }
            guard let angle = Double(trimmed) else {
                commandMessage = "ELLIPSE — expected a rotation angle in degrees"
                commandLine.recordSubmitted(input)
                return
            }
            pendingEllipseRotationAngle = false
            if let ctx = draftContext(for: draft.mode),
               (draft.mode == .ellipse || draft.mode == .ellipseAxis), draft.points.count == 2 {
                // Center-form: points = [center, majorEndpoint]. Axis-
                // endpoint form: points = [axisEnd1, axisEnd2] with the
                // center being their midpoint — same derivation
                // `DraftState.addEllipsePoint`'s own axisEndpointForm
                // branch uses, mirrored here since the command-bar typed-
                // angle path bypasses `addPoint` entirely.
                let center: CGPoint
                let major: CGPoint
                if draft.mode == .ellipseAxis {
                    center = CGPoint(x: (draft.points[0].x + draft.points[1].x) / 2,
                                     y: (draft.points[0].y + draft.points[1].y) / 2)
                    major = CGPoint(x: draft.points[1].x - center.x, y: draft.points[1].y - center.y)
                } else {
                    center = draft.points[0]
                    major = CGPoint(x: draft.points[1].x - center.x, y: draft.points[1].y - center.y)
                }
                let output = DraftState.ellipsePrototypeByRotationAngle(center: center, major: major, angleDeg: angle, ctx: ctx)
                draft.points = []
                draft.ellipseRotationMode = false
                commitDraftOutput(output, label: "Ellipse")
            }
            commandLine.recordSubmitted(input)
            return
        }

        guard !input.trimmingCharacters(in: .whitespaces).isEmpty else {
            // Bare ⏎: finish the running polyline (AutoCAD), OR — if a
            // modify command's Select-objects: prompt is active — finish
            // acquisition with whatever's been picked so far (also AutoCAD
            // behavior; also reachable via the canvas's own Return key, see
            // `onReturnKey`/`finishSelectionPrompt`'s doc comment for why
            // BOTH paths must call this). TRIM/EXTEND's boundary-acquisition
            // step ALSO treats a bare Enter as meaningful — "all visible,
            // extended" — rather than a no-op cancel, since (unlike every
            // ModifyToolState command) an EMPTY cutting-edge selection is a
            // normal, explicitly documented AutoCAD gesture, not an error.
            if modifyState.phase == .selecting { finishSelectionPrompt() }
            else if modifyState.phase == .pickDestination { finishModifyDestinationLoop() }
            else if trimExtendState.phase == .selectingBoundaries { finishTrimExtendBoundaryPrompt() }
            else if trimExtendState.phase == .pickingTargets { finishTrimExtendTargetLoop() }
            else if blockToolState.phase == .selecting { finishBlockSelectionPrompt() }
            else if explodeAwaitingSelection { finishExplodeSelectionPrompt() }
            else if joinAwaitingSelection { finishJoinSelectionPrompt() }
            else if arrayToolState.phase == .selecting { finishArraySelectionPrompt() }
            else if arrayToolState.phase == .pickFields { commitArrayFromCurrentFields() }
            else { handleFinishGesture() }
            return
        }
        let upper = input.trimmingCharacters(in: .whitespaces).uppercased()
        // Context: "C" during an active polyline closes it (AutoCAD).
        if draft.mode == .polyline, !draft.points.isEmpty, upper == "C" {
            if let ctx = draftContext(for: draft.mode) {
                commitDraftOutput(draft.finishPolyline(close: true, ctx: ctx), label: "Polyline")
            }
            commandLine.recordSubmitted(input)
            return
        }
        // SPLINE (fit-point mode): "CLOSE" mid-gesture finishes a closed
        // spline through every fit point so far — mirrors PLINE's own "C"
        // keyword above (AutoCAD's real SPLINE keyword is the full word
        // "Close", not a single letter, since "C" is already PLINE's).
        if draft.mode == .splineFit, draft.points.count >= 2, upper == "CLOSE" {
            if let ctx = draftContext(for: draft.mode) {
                commitDraftOutput(draft.finishSplineFit(close: true, ctx: ctx), label: "Spline")
            }
            commandLine.recordSubmitted(input)
            return
        }
        // POLYGON tool: a bare integer sets the side count (AutoCAD prompts for it).
        if draft.mode == .polygon, draft.points.isEmpty, let n = Int(upper), n >= 3, n <= 64 {
            draft.polygonSides = n
            commandMessage = "Polygon: \(n) sides"
            commandLine.recordSubmitted(input)
            return
        }
        // Context: "T" while OFFSET is waiting for its first object pick
        // switches to through-point mode for the rest of this command run
        // (AutoCAD's own OFFSET "T" keyword) — this is the ONLY way
        // `throughPointMode: true` is ever reachable; without this guard
        // `OffsetToolState.begin(throughPointMode: true)` and everything
        // built on it (`OffsetExecutor.resolveThroughPoint`,
        // `commitOffsetSecondClick`'s through-point branch) would be
        // unreachable dead code from any real user interaction — exactly
        // the "tested in isolation, never wired at its real call site" bug
        // class this project has hit before, caught here by re-tracing
        // every `startOffset` call site during adversarial review and
        // finding NONE of them ever passed `throughPointMode: true`.
        if offsetState.phase == .pickObject, upper == "T" {
            startOffset(throughPointMode: true)
            commandLine.recordSubmitted(input)
            return
        }
        // Context: "R" while ELLIPSE is waiting for its 3rd point (the
        // ratio/rotation pick) switches to rotation mode for the REST of
        // THIS ellipse (AutoCAD's own ELLIPSE "Rotation" option) — the ONLY
        // way `ellipseRotationMode` is ever reachable from real UI
        // interaction; without this guard the rotation-mode math in
        // `DraftState.ellipsePrototype`/`ellipsePrototypeByRotationAngle`
        // would be unreachable dead code, exactly the "tested in isolation,
        // never wired at its real call site" class this project has hit
        // before (see the OFFSET "T" comment immediately above). The
        // FOLLOWING numeric submission (the angle itself) is handled by
        // `pendingEllipseRotationAngle`'s own guard at the TOP of this
        // function (alongside `pendingSetVar`/`pendingBlockEntry`/etc.),
        // not here — placed there specifically so a bare Enter (or any
        // other input) while the angle is pending is never accidentally
        // swallowed by an EARLIER guard (this function's own bare-Enter
        // branch runs BEFORE this point, so a naive placement here would
        // leave `pendingEllipseRotationAngle` stuck true after a stray
        // Enter — found during this session's own adversarial review).
        if (draft.mode == .ellipse || draft.mode == .ellipseAxis), draft.points.count == 2, upper == "R" {
            draft.ellipseRotationMode = true
            pendingEllipseRotationAngle = true
            commandMessage = draft.prompt
            commandLine.recordSubmitted(input)
            return
        }
        // Context: "A" while ELLIPSE is waiting for its FIRST point (no
        // points picked yet) switches to the axis-endpoint variant
        // (`.ellipseAxis` — AutoCAD's own ELLIPSE "Axis endpoint" option,
        // in fact AutoCAD's actual DEFAULT method, with "C" switching to
        // center form; this app's ELLIPSE/EL command instead defaults to
        // center form with "A" opting into axis-endpoint, a deliberate,
        // documented deviation since `CommandRegistry`'s "EL" binding
        // already targets `.ellipse` (center form) and re-pointing the
        // DEFAULT would be a larger, riskier change for a Phase 6.3
        // "medium priority, mostly UI wiring" item than adding one keyword
        // — see the plan's own prioritization guidance). Without this
        // guard `.ellipseAxis` (`DraftState.addEllipsePoint`'s
        // axisEndpointForm branch, fully implemented and unit-tested — see
        // `DraftStatePhase63Tests.testEllipseAxisEndpointFormComputesCenterAsMidpoint`)
        // would be unreachable dead code from any real user interaction,
        // caught by this session's own adversarial-review re-trace.
        if draft.mode == .ellipse, draft.points.isEmpty, upper == "A" {
            draft = DraftState(mode: .ellipseAxis)
            commandMessage = draft.prompt
            commandLine.recordSubmitted(input)
            return
        }
        // Context: "D"/"A" while CHAMFER is waiting for its first line pick
        // set the distance(s)/angle CHAMFER will use, via the same two-step
        // "type keyword, then type value" shape as `pendingSetVar` — the
        // ONLY UI path that can ever change `session.chamferD1`/
        // `chamferD2`/`chamferAngleDeg`/`chamferUsesAngle` away from their
        // hardcoded defaults (these aren't registered SysVars, so the
        // existing SETVAR shortcut can't reach them either). Without this,
        // CHAMFER would always silently run with d1=d2=1.0 regardless of
        // what the user intended — caught during adversarial review by
        // checking whether every field this session added was actually
        // WRITABLE from some real interaction, not just read.
        if filletChamferState.command == .chamfer, filletChamferState.phase == .pickFirst, upper == "D" {
            pendingFilletChamferEntry = .distance1
            commandMessage = String(format: "Chamfer — specify first distance <%.4g>: ", session.chamferD1)
            commandLine.recordSubmitted(input)
            return
        }
        if filletChamferState.command == .chamfer, filletChamferState.phase == .pickFirst, upper == "A" {
            pendingFilletChamferEntry = .angleValue
            commandMessage = String(format: "Chamfer — specify chamfer length <%.4g>: ", session.chamferD1)
            commandLine.recordSubmitted(input)
            return
        }
        // "R" while FILLET is waiting for its first line pick sets
        // FILLETRAD — the fillet-side counterpart to CHAMFER's "D"/"A"
        // above. FilletChamferToolState's own doc comment claims "keywords
        // R/P/D/A/T are accepted here," but the D/A gates above were
        // explicitly `== .chamfer`-only, leaving FILLET's own "R" with no
        // reachable path at all — caught by adversarial review re-tracing
        // every keyword the doc comment promised against what was actually
        // wired.
        if filletChamferState.command == .fillet, filletChamferState.phase == .pickFirst, upper == "R" {
            pendingFilletChamferEntry = .filletRadius
            commandMessage = String(format: "Fillet — specify radius <%.4g>: ", sysVars.double("FILLETRAD"))
            commandLine.recordSubmitted(input)
            return
        }
        // "POL 8" / "POLYGON 5" — activate the tool with a side count.
        if upper.hasPrefix("POL") {
            let parts = upper.split(separator: " ")
            if parts.count == 2, let n = Int(parts[1]), n >= 3, n <= 64 {
                setDraft(.polygon)
                draft.polygonSides = n
                commandLine.recordSubmitted(input)
                return
            }
        }
        // SETVAR shortcut, part 1: typing a recognized sysvar name alone
        // (not while a tool is mid-gesture, so it can't collide with normal
        // coordinate/length entry) prompts for a new value.
        if !draft.isActive, !measure.isActive, !moveState.isActive, !modifyState.isActive, !trimExtendState.isActive, !filletChamferState.isActive,
           sysVars.get(upper) != nil {
            pendingSetVar = upper
            commandLine.recordSubmitted(input)
            return
        }

        // Phase 4.1/4.3: while a modify command OR TRIM/EXTEND's boundary-
        // acquisition step is in its own "Select objects:"-style prompt,
        // W/C/F/ALL/P/L/R/A/U are SelectionPrompt tokens, not tool-switch
        // commands — this MUST be checked before `CommandParser.parse`
        // below, since several of these single letters are also
        // drafting-tool aliases (A=ARC, C=CIRCLE, L=LINE) that would
        // otherwise hijack them. Confirmed (not just assumed) by reading
        // `CommandRegistry.resolve`'s call order: this guard's `return`
        // means these tokens NEVER reach `CommandParser.parse`/the registry
        // at all while a prompt is active, so FILLET's own top-level "F"
        // shortcut (registered in Phase 4.4) and this "F" (fence) token
        // never actually collide — outside an active prompt, "F" always
        // falls through to the registry and resolves to FILLET.
        let promptIsActive = (modifyState.phase == .selecting || trimExtendState.phase == .selectingBoundaries
                               || blockToolState.phase == .selecting || explodeAwaitingSelection
                               || joinAwaitingSelection
                               || arrayToolState.phase == .selecting) && selectionPrompt != nil
        if promptIsActive, ["W", "C", "F", "ALL", "P", "L", "R", "A", "U"].contains(upper) {
            feedSelectionPromptToken(upper)
            commandLine.recordSubmitted(input)
            return
        }

        // Phase 4.3: while TRIM/EXTEND is in `.pickingTargets`, trim<->extend
        // toggling is a per-click Shift modifier (not a typed token — see
        // `handleTrimExtendClick`), so no additional command-bar token
        // interception is needed here beyond Enter (handled above) and Esc
        // (handled by `handleEscape`).

        switch CommandParser.parse(input, context: PromptContext(expectsScalar: modifyExpectsScalar)) {
        case .point(let p):
            feedTypedPoint(p)
        case .relative(let dx, let dy):
            guard let base = modifyState.basePoint ?? moveState.basePoint ?? draft.points.last ?? measure.points.last else {
                commandMessage = "Relative input needs a previous point"
                commandLine.recordSubmitted(input)
                return
            }
            feedTypedPoint(CGPoint(x: base.x + dx, y: base.y + dy))
        case .length(let len):
            guard let base = modifyState.basePoint ?? moveState.basePoint ?? draft.points.last ?? measure.points.last,
                  let toward = modifyState.hover ?? moveState.hover ?? draft.hover ?? measure.hover else {
                commandMessage = "Length input needs a previous point and cursor direction"
                commandLine.recordSubmitted(input)
                return
            }
            let d = hypot(toward.x - base.x, toward.y - base.y)
            guard d > 1e-12 else { return }
            feedTypedPoint(CGPoint(x: base.x + (toward.x - base.x) / d * len,
                                   y: base.y + (toward.y - base.y) / d * len))
        case .scalar(let v):
            feedModifyScalar(v)
        case .unknown(let raw):
            commandMessage = "Unknown command: \(raw)"
        case let action:
            // Every other CommandAction case is a "start this tool/command"
            // action with no coordinate/typed-value payload — shared
            // verbatim with the menu bar (MainMenuCommands) and ribbon
            // (RibbonView) via `performRegistryAction`, so there is exactly
            // ONE place that maps a CommandAction to a tool-start call.
            performRegistryAction(action)
        }
        commandLine.recordSubmitted(input)
    }

    /// The shared "start this tool/command" funnel for every `CommandAction`
    /// case that ISN'T a coordinate/typed-value payload (`.point`/`.relative`/
    /// `.length`/`.scalar`/`.unknown` stay inline in `executeCommand` above,
    /// since those only make sense as command-bar text parses, never as a
    /// menu click or ribbon button). `executeCommand` (command bar), the
    /// native menu bar (`MainMenuCommands`, via the `CommandDispatch`
    /// environment/focused value below), and `RibbonView`'s buttons all
    /// call into this SAME function — never a second, parallel dispatch
    /// switch — so the "recurring bug class" of a feature only reachable
    /// from one of those three surfaces cannot happen here by construction.
    private func performRegistryAction(_ action: CommandAction) {
        switch action {
        case .tool(let mode): setDraft(mode)
        case .measureDistance: setMeasure(.distance)
        case .measureArea: setMeasure(.area)
        case .measureRadius: setMeasure(.radius)
        case .measureAngle: setMeasure(.angle)
        case .selectMode: setTool(select: true)
        case .moveTool: startMove()
        case .modify(let command): startModify(command)
        case .trimExtend(let command): startTrimExtend(command)
        case .stretch: startStretch()
        case .filletChamfer(let command): startFilletChamfer(command)
        case .offset: startOffset()
        case .dimension(let kind): startDimensionTool(kind: kind)
        case .blockCommand(let command):
            switch command {
            case .block: startBlock()
            case .insert:
                // Bare "INSERT"/"I" (or the menu/ribbon's generic "Insert
                // Block" entry, if one is ever added with no name attached)
                // has no block name to act on yet — the name is chosen via
                // the Tools ▸ Insert Block… menu (mirroring Stamp Block's
                // own picker), which calls `startInsert(blockName:)`
                // directly once a name is chosen. Matches `placeStamp`'s own
                // "choose one from the menu first" messaging for the
                // equivalent gap.
                commandMessage = "INSERT — choose a block first (Tools ▸ Insert Block…)"
            }
        case .attdef: startAttdef()
        case .attedit: startAttedit()
        case .explode: startExplode()
        case .join: startJoin()
        case .array: startArray()
        case .clayer: startClayerEntry()
        case .clipboardCopy: copySelectionToPasteboard()
        case .clipboardPaste: startClipboardPaste()
        case .extractData: extractDataToCSV()
        case .importData: importDataFromCSV()
        case .save: saveDrawing()
        case .saveAs: saveDrawingAs()
        case .zoomFit: fitButtonPressed()
        case .closePolyline:
            if let ctx = draftContext(for: draft.mode) {
                commitDraftOutput(draft.finishPolyline(close: true, ctx: ctx), label: "Polyline")
            }
        case .undo:
            undoLast()
        case .point, .relative, .length, .scalar, .unknown:
            // Never reached from executeCommand (those cases are handled
            // inline before falling into this function) — reachable only if
            // a future menu/ribbon caller passes one of these payload cases
            // directly, which doesn't make sense without a coordinate/value
            // to go with it. No-op rather than crash.
            break
        }
    }

    /// True while a ROTATE/SCALE prompt is actively waiting for its
    /// angle/factor and hasn't been given a reference-point-derived value
    /// yet — see `PromptContext`'s doc comment for why a bare typed number
    /// must resolve differently depending on this.
    private var modifyExpectsScalar: Bool {
        modifyState.phase == .pickAngle || modifyState.phase == .pickFactor
    }

    /// A typed numeric value while ROTATE/SCALE is asking for its
    /// angle/factor — the command-bar equivalent of picking a second point,
    /// applied directly rather than converted to a synthetic point (a typed
    /// angle in degrees has no natural "point" to convert to/from, unlike
    /// `.length`, which reuses the live hover DIRECTION).
    private func feedModifyScalar(_ v: Double) {
        guard let base = modifyState.basePoint else {
            commandMessage = "Specify a base point first"
            return
        }
        switch modifyState.phase {
        case .pickAngle:
            commitModifyTransform(.rotation(about: Vec2(base), angleRad: v * .pi / 180))
        case .pickFactor:
            guard v > 1e-9 else { commandMessage = "Scale factor must be > 0"; return }
            commitModifyTransform(.scaling(about: Vec2(base), factor: v))
        default:
            commandMessage = "Unexpected numeric input"
        }
    }

    /// Feeds one uppercased SelectionPrompt token (W/C/F/ALL/P/L/R/A/U) from
    /// the command bar into the active prompt, applying the same
    /// pending/done/cancelled handling the owning tool's mouse-click path
    /// uses. Dispatches to whichever tool actually owns the active
    /// `selectionPrompt` — NOT hardcoded to the modify-specific handler.
    /// Found by adversarial review: this previously always called
    /// `applySelectionPromptResult` (which mutates `modifyState`/calls
    /// `cancelModify()`) regardless of which tool's acquisition was
    /// actually in progress, so a W/C/F/... token typed during TRIM/EXTEND's
    /// boundary pick, BLOCK's object pick, or EXPLODE's object pick would
    /// either silently no-op or corrupt unrelated modal-tool state.
    private func feedSelectionPromptToken(_ token: String) {
        guard var prompt = selectionPrompt else { return }
        let result = prompt.handle(.commandToken(token))
        selectionPrompt = prompt
        if trimExtendState.phase == .selectingBoundaries {
            applyTrimExtendBoundaryPromptResult(result)
        } else if blockToolState.phase == .selecting {
            applyBlockSelectionPromptResult(result)
        } else if arrayToolState.phase == .selecting {
            applyArraySelectionPromptResult(result)
        } else if explodeAwaitingSelection {
            switch result {
            case .pending:
                commandMessage = selectionPrompt?.promptText ?? ""
            case .done(let ids):
                if ids.isEmpty { cancelExplode() } else { commitExplode(ids: Array(ids)) }
            case .cancelled:
                cancelExplode()
            }
        } else if joinAwaitingSelection {
            switch result {
            case .pending:
                commandMessage = selectionPrompt?.promptText ?? ""
            case .done(let ids):
                if ids.isEmpty { cancelJoin() } else { commitJoin(ids: Array(ids)) }
            case .cancelled:
                cancelJoin()
            }
        } else {
            applySelectionPromptResult(result)
        }
    }

    private func feedTypedPoint(_ p: CGPoint) {
        if modifyState.isActive {
            if modifyState.phase == .selecting {
                // A typed coordinate during `.selecting` isn't one of
                // SelectionPrompt's own concerns (it has no "type a point to
                // pick at" capability — AutoCAD's own Select objects: prompt
                // doesn't either) — ignored rather than crashing/misrouting.
                commandMessage = "Pick objects on screen, or type W/C/F/ALL/P/L/U"
            } else {
                commitModifyGeometryPoint(p)
            }
        } else if moveState.isActive {
            commitMovePoint(p)
        } else if draft.mode == .region {
            commitRegionPick(at: p)
        } else if draft.isActive, draft.mode != .erase {
            feedDraftPoint(p)
        } else if measure.isActive {
            measure.addPoint(p)
        } else {
            commandMessage = "Start a tool first (L, PL, C, A, REC, M, DI, AREA)"
        }
    }

    // MARK: - Saving markup

    /// Read-only reconstruction of the current markup as `[DrawnEntity]` —
    /// feeds `DXFWriter`'s two existing export functions (neither needed to
    /// change: they still take `[DrawnEntity]` exactly as before) and
    /// `reloadDocument`'s pre-reload capture. See MarkupStore.swift.
    private var currentDrawnMarkup: [DrawnEntity] {
        guard let regen, let markupLayerId = session.markupLayerId else { return [] }
        return MarkupStore.drawnEntities(in: regen.parsed.store, layerId: markupLayerId)
    }

    private var hasMarkup: Bool { !currentDrawnMarkup.isEmpty }

    /// Phase 3.2: writes the FULL live document (every edit — moves, copies,
    /// arrays, blocks, new drafting entities, attribute changes, etc., not
    /// just markup annotations) back to `document.sourceDXFURL` via
    /// `DXFStructuralWriter`. Distinct from `saveMarkupAsDXF`/
    /// `saveMergedCopy` below, which predate this and only ever wrote the
    /// markup-only `[DrawnEntity]` array through the old `DXFWriter.swift`.
    /// Falls through to `saveDrawingAs` when there's no source URL to write
    /// back to (shouldn't normally happen — every open document was loaded
    /// from a URL — but a Save with nowhere to save is more sensibly a
    /// Save-As prompt than a silent no-op).
    private func saveDrawing() {
        guard let regen = session.regen, let doc = document else { return }
        // `doc.sourceDXFURL` (a CADCore `DXFDocument` field) is the primary
        // check — it's set here on a successful save (below) and by
        // `saveDrawingAs()` — but is otherwise NEVER populated by the app's
        // real Open File path (`RegenCoordinator.loadPackage` →
        // `PackageLoader+Store.loadIntoStore` → `Regenerator.build` sets no
        // such field; only CADCore's separate, unused legacy loader does).
        // `session.currentSourceURL` (set unconditionally in `openFile(url:)`
        // for every file opened through the UI) is the field that's
        // actually reliable for "what file did this document come from" —
        // used as the fallback so a freshly-opened `.dxf` saves in place on
        // the FIRST ⌘S, not just after one manual Save As. Restricted to a
        // `.dxf` extension: a `.dwg`-opened document has no DWG writer (DXF
        // export only, per README/AGENTS.md), so writing DXF bytes straight
        // into a `.dwg`-named path would silently corrupt it from any other
        // tool's point of view — falls through to Save As instead, which
        // prompts for a real `.dxf` destination.
        if session.recoveredDocument { saveDrawingAs(); return }
        guard let url = doc.sourceDXFURL
            ?? (currentSourceURL?.pathExtension.lowercased() == "dxf" ? currentSourceURL : nil)
        else { saveDrawingAs(); return }
        do {
            let warnings = try DrawingFileWriter.write(regen.parsed, to: url)
            doc.sourceDXFURL = url
            session.markSaved(to: url)
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            commandMessage = warnings.isEmpty
                ? "Saved \(url.lastPathComponent)"
                : "Saved \(url.lastPathComponent) (\(warnings.count) warning(s) — see Console)"
            for w in warnings { print("save: \(w)") }
            NotificationCenter.default.post(name: .novaCADDrawingSaved,
                                            object: nil,
                                            userInfo: [DocumentNotificationKey.url: url])
        } catch {
            alertMessage = "Failed to save: \(error.localizedDescription)"
        }
    }

    /// Same as `saveDrawing` but always prompts for a destination. On
    /// success, retargets `document.sourceDXFURL` to the new location so a
    /// subsequent plain Save writes back there (matching ordinary "Save
    /// As" semantics — the app is now editing the NEW file).
    private func saveDrawingAs() {
        guard let regen = session.regen, let doc = document else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "dxf") ?? .data]
        panel.nameFieldStringValue = doc.sourceDXFURL?.lastPathComponent ?? ((currentSourceURL?.deletingPathExtension().lastPathComponent ?? "drawing") + ".dxf")
        panel.title = "Save Drawing As"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let warnings = try DrawingFileWriter.write(regen.parsed, to: url)
            doc.sourceDXFURL = url
            session.markSaved(to: url)
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            commandMessage = warnings.isEmpty
                ? "Saved \(url.lastPathComponent)"
                : "Saved \(url.lastPathComponent) (\(warnings.count) warning(s) — see Console)"
            for w in warnings { print("save: \(w)") }
            NotificationCenter.default.post(name: .novaCADDrawingSaved,
                                            object: nil,
                                            userInfo: [DocumentNotificationKey.url: url])
        } catch {
            alertMessage = "Failed to save copy: \(error.localizedDescription)"
        }
    }

    private func saveMarkupAsDXF() {
        guard let doc = document else { return }
        let drawn = currentDrawnMarkup
        guard !drawn.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "dxf") ?? .data]
        panel.nameFieldStringValue = "markup.dxf"
        panel.title = "Export Markup as DXF"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try DXFWriter.writeMarkupDXF(drawn, to: url, insUnits: doc.insUnits)
            commandMessage = "Markup exported to \(url.lastPathComponent)"
        } catch {
            alertMessage = "Failed to export markup: \(error.localizedDescription)"
        }
    }

    private func saveMergedCopy() {
        guard let doc = document, let source = doc.sourceDXFURL else { return }
        let drawn = currentDrawnMarkup
        guard !drawn.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "dxf") ?? .data]
        panel.nameFieldStringValue = source.deletingPathExtension().lastPathComponent
            + "-markup.dxf"
        panel.title = "Save Copy with Markup"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try DXFWriter.writeMergedCopy(original: source, entities: drawn, to: url)
            commandMessage = "Saved \(url.lastPathComponent)"
        } catch {
            alertMessage = "Failed to save copy: \(error.localizedDescription)"
        }
    }

    // MARK: - Data Extraction (AutoCAD DATAEXTRACTION / "dx" — new feature)
    //
    // Export every entity + INSERT attributes to a CSV the user edits
    // externally, then import the edited CSV to bulk-apply changes. See
    // `DataExtraction.swift` for the format and the round-trip's stable-id
    // caveat (keys are session-scoped). Export follows `saveMarkupAsDXF`'s
    // NSSavePanel shape; import follows `startAttachXref`'s NSOpenPanel shape
    // (read synchronously — a CSV is tiny vs. a DXF parse) and
    // `applyAIProposedEdits`' one-transaction batch-apply idiom.

    /// Step 1: computes the rows once, then opens the column-picker sheet
    /// (`DataExtractionColumnPicker`) so the user chooses which columns to
    /// include and their order BEFORE the save panel appears — see
    /// `commitDataExtraction(columns:)` for step 2 (the actual save).
    private func extractDataToCSV() {
        guard let regen else { return }
        let rows = DataExtraction.extractRows(from: regen.parsed)
        guard !rows.isEmpty else {
            commandMessage = "Extract Data — the drawing has no entities to extract"
            return
        }
        pendingDataExtraction = PendingDataExtraction(rows: rows,
                                                      columns: DataExtraction.availableColumns(for: rows))
    }

    /// Step 2: the user has chosen (and possibly reordered/pruned) columns
    /// in the picker sheet — now show the save panel and write the CSV
    /// using exactly that column selection/order.
    private func commitDataExtraction(rows: [DataExtraction.Row], columns: [String]) {
        pendingDataExtraction = nil
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = (currentSourceURL?.deletingPathExtension().lastPathComponent ?? "drawing")
            + "-data.csv"
        panel.title = "Extract Data"
        panel.message = "Export every object's data and block attributes to a CSV you can edit, then re-import to bulk-update the drawing."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let csv = DataExtraction.csv(for: rows, columns: columns)
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
            commandMessage = "Extracted \(rows.count) object(s) to \(url.lastPathComponent)"
        } catch {
            alertMessage = "Failed to write \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    private func importDataFromCSV() {
        guard let regen else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.title = "Import Data"
        panel.message = "Choose an edited data-extraction CSV to bulk-apply changes back onto this drawing."
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            alertMessage = "Failed to read \(url.lastPathComponent): \(error.localizedDescription)"
            return
        }

        let edits: [DataExtraction.ParsedEdit]
        let malformedRows: Int
        do {
            (edits, malformedRows) = try DataExtraction.parseCSV(text)
        } catch {
            alertMessage = (error as? LocalizedError)?.errorDescription
                ?? "Failed to parse \(url.lastPathComponent): \(error.localizedDescription)"
            return
        }
        guard !edits.isEmpty else {
            commandMessage = "Import Data — no usable rows in \(url.lastPathComponent)"
            return
        }

        var result = DataExtraction.ApplyResult()
        session.performEdit("Import Data") { tx in
            result = DataExtraction.apply(edits, in: regen.parsed, tx: tx)
        }
        // A brand-new layer introduced by the import changes the structural
        // layer table, which the incremental render delta can't patch — same
        // "fullRebuild after a structural change" precedent as attach-xref /
        // markup re-layer.
        if result.createdLayer || result.totalEdits > 0 {
            regen.fullRebuild()
            // The search index snapshots block-reference names (both real and
            // display-name-overridden — see `SearchIndex`'s own doc comment)
            // at BUILD time; a bulk import that just wrote hundreds of
            // display-name overrides (`result.displayNameEdits`) must refresh
            // it, or a renamed object stays unfindable by its new name (and,
            // after `fullRebuild()` replaces `regen.document` outright, the
            // OLD index's `RenderGroup`-relative refs would be stale against
            // the new one regardless) until the next full reload.
            searchIndex = SearchIndex(document: regen.document, store: regen.parsed.store)
        }
        result.rowsSkipped += malformedRows
        commandMessage = "Import Data — " + result.summary
    }

    private func renderParams() -> RenderParams {
        var p = RenderParams()
        p.worldToView = worldToView()
        p.viewSize = viewSize
        p.backingScale = NSScreen.main?.backingScaleFactor ?? 2
        p.zoom = zoom
        p.darkBackground = darkBackground
        p.visibility = visibility
        p.usePaperSpace = space == .paper
        p.selection = selectionRefs
        p.quality = renderQuality
        p.documentRevision = regen?.revision ?? 0
        return p
    }

    // MARK: - Escape chain: measurement → search → selection

    private func handleEscape() {
        pendingSetVar = nil
        pendingFilletChamferEntry = nil
        pendingBlockEntry = nil
        pendingAttdefEntry = nil
        pendingArrayEntry = nil
        pendingClayerEntry = false
        pendingEllipseRotationAngle = false
        awaitingAttEditPick = false
        awaitingAttdefPlacement = false
        if xrefAttachToolState.isActive {
            cancelXrefAttach()
        } else if clipboardPasteToolState.isActive {
            cancelClipboardPaste()
        } else if explodeAwaitingSelection {
            cancelExplode()
        } else if joinAwaitingSelection {
            cancelJoin()
        } else if modifyState.isActive {
            cancelModify()
        } else if trimExtendState.isActive {
            cancelTrimExtend()
        } else if stretchState.isActive {
            cancelStretch()
        } else if filletChamferState.isActive {
            cancelFilletChamfer()
        } else if offsetState.isActive {
            cancelOffset()
        } else if dimensionToolState.isActive {
            cancelDimensionTool()
        } else if blockToolState.isActive {
            cancelBlock()
        } else if arrayToolState.isActive {
            cancelArray()
        } else if moveState.isActive {
            moveState = MoveState()
            commandMessage = ""
        } else if gripDragState.isActive {
            gripDragState = GripDragState()
            commandMessage = ""
        } else if draft.isActive {
            if draft.points.isEmpty {
                draft = DraftState()
                commandMessage = ""
            } else {
                draft.points = []
                draft.ellipseRotationMode = false
                draft.splineClose = false
            }
        } else if measure.isActive {
            measure = MeasureState()
        } else if searchVisible {
            closeSearch()
        } else {
            selection = []
        }
    }

    /// ⏎ / double-click: finishes whichever multi-point gesture is in flight.
    /// `viewLocation` is nil for the Return-key path (`onReturnKey`, which
    /// carries no click position) and non-nil for an actual double-click
    /// (`DXFCanvasView.onDoubleClick`) — used ONLY to check for the Phase
    /// 6.1 "double-click an INSERT with ATTRIBs opens the attribute editor"
    /// case, which by definition can't apply to a keyboard-triggered finish.
    private func handleFinishGesture(at viewLocation: CGPoint? = nil) {
        // For measure tools that just completed, commit the measurement
        // as persistent markup on the NOVACAD-MARKUP layer — just like a
        // drawn line or circle: visible, selectable, savable.
        if measure.isActive {
            finishAreaMeasurement()
            if measure.mode == .distance, measure.points.count >= 2 {
                commitMeasurement(pts: Array(measure.points), mode: .distance, closed: false)
            } else if measure.mode == .area, measure.closed, measure.points.count >= 3 {
                commitMeasurement(pts: measure.points, mode: .area, closed: true)
            } else if measure.mode == .radius, let arc = measure.pickedArc {
                commitMeasurement(pts: [arc.center], mode: .radius, closed: arc.full,
                                  arcCenter: arc.center, arcRadius: arc.radius,
                                  arcStart: arc.startDeg, arcEnd: arc.endDeg)
            }
            measure = MeasureState(mode: measure.mode)
            return
        }
        if let viewLocation, !draft.isActive, !moveState.isActive,
           !modifyState.isActive, !trimExtendState.isActive, !filletChamferState.isActive,
           !offsetState.isActive, !dimensionToolState.isActive, let doc = document, let regen {
            // Plain select mode (no modal tool active) — a double-click here
            // is free to mean "open this INSERT's attribute editor" per the
            // plan's spec text, rather than colliding with any tool's own
            // multi-point-finish gesture (which all take priority via the
            // early-active checks above, matching every other click-routing
            // guard in this file's ordering convention).
            let worldPoint = viewLocation.applying(worldToView().inverted())
            let tolerance = 6 / max(zoom, 1e-12)
            if let hit = HitTester.hitTestEntityID(document: doc, usePaperSpace: space == .paper,
                                                   at: worldPoint, tolerance: tolerance, visibility: visibility),
               let h = regen.parsed.store.header(hit), h.type == .insert,
               !BlockEditor.attributes(of: hit, in: regen.parsed.store).isEmpty {
                attributeEditorInsertId = hit
                return
            }
            // ADDVERTEX: a double-click landing on an EDGE of the currently
            // (singly) selected polyline inserts a new vertex there. Scoped
            // to the SELECTED polyline specifically (not "whatever polyline
            // is under the cursor") so this can't accidentally fire while
            // double-clicking to open an unrelated entity's attribute
            // editor, or on a polyline the user hasn't deliberately chosen
            // to reshape — mirrors `gripEditingEligible`'s own "exactly one
            // grip-editable entity selected" scope, since ADDVERTEX is
            // conceptually part of the same direct-manipulation feature.
            if gripEditingEligible, let id = selection.first,
               let edge = GripEditing.nearestEdge(of: id, in: regen.parsed.store, to: worldPoint, tolerance: tolerance) {
                session.performEdit("Add Vertex") { tx in
                    GripEditing.addVertex(id, afterIndex: edge.afterIndex, at: edge.point, in: tx)
                }
                return
            }
        }
        if draft.mode == .polyline || draft.mode == .splineFit || draft.mode == .splineCV {
            // The double-click's first click added a duplicate vertex — drop it.
            if draft.points.count >= 2,
               let last = draft.points.last, let prev = draft.points.dropLast().last,
               hypot(last.x - prev.x, last.y - prev.y) < 3 / max(zoom, 1e-12) {
                draft.points.removeLast()
            }
            if let ctx = draftContext(for: draft.mode) {
                switch draft.mode {
                case .polyline:
                    commitDraftOutput(draft.finishPolyline(close: false, ctx: ctx), label: "Polyline")
                case .splineFit:
                    commitDraftOutput(draft.finishSplineFit(close: false, ctx: ctx), label: "Spline")
                case .splineCV:
                    commitDraftOutput(draft.finishSplineCV(ctx: ctx), label: "Spline")
                default:
                    break
                }
            }
        } else {
            finishAreaMeasurement()
        }
    }

    /// The NOVACAD-MARKUP layer's stable id — set by `applyDocument` right
    /// after load (see `MarkupStore.ensureMarkupLayer`), so this should
    /// always already be populated by the time any drafting tool runs; the
    /// fallback registers it defensively (e.g. a session somehow reaching a
    /// drafting command before its first `applyDocument` — shouldn't happen,
    /// but a silent no-op layer id of 0 would be a much worse failure mode
    /// than eagerly creating the layer here too).
    private func ensureMarkupLayerId() -> Int32 {
        if let id = session.markupLayerId { return id }
        guard let regen else { return 0 }
        let id = MarkupStore.ensureMarkupLayer(in: regen.parsed)
        session.markupLayerId = id
        return id
    }

    /// Commits one drawn shape as a real EntityStore entity on the
    /// NOVACAD-MARKUP layer — per the plan's exact 1.7 recipe:
    /// `doc.begin("Draw")/tx.add(prototype)/commit`. Markup renders/hit-
    /// tests/moves as an ordinary entity from this point on; there is no
    /// separate markup array or overlay pass anymore.
    private func commitDrawn(_ e: DrawnEntity) {
        guard let regen else { return }
        var e = e
        e.isPaper = space == .paper
        e.aci = markupColor
        let layerId = ensureMarkupLayerId()
        session.performEdit("Draw") { tx in
            _ = tx.add(MarkupStore.prototype(for: e, layerId: layerId, store: regen.parsed.store))
        }
        commandMessage = "Drew \(MarkupPropertiesPanel.markupTypeName(e))"
    }

    /// Commits a completed measurement as persistent markup — a professional
    /// CAD-style dimension line / polygon / arc with a text label showing the
    /// measured value. Entities land on NOVACAD-MARKUP so they're visible after
    /// leaving Measure mode, selectable, and saved with the drawing.
    private func commitMeasurement(pts: [CGPoint], mode: MeasureState.Mode, closed: Bool,
                                   arcCenter: CGPoint = .zero, arcRadius: CGFloat = 0,
                                   arcStart: Double = 0, arcEnd: Double = 0) {
        let fmt = MeasureFormat()
        switch mode {
        case .distance:
            guard pts.count >= 2 else { return }
            let a = pts[0], b = pts[1]
            let len = hypot(b.x - a.x, b.y - a.y)
            // Dimension line (slightly offset to differentiate from the geometry).
            let offset = perpendicularOffset(from: a, to: b, amount: len * 0.03)
            let dimA = CGPoint(x: a.x + offset.x, y: a.y + offset.y)
            let dimB = CGPoint(x: b.x + offset.x, y: b.y + offset.y)
            commitDrawn(DrawnEntity(shape: .line(a: dimA, b: dimB)))
            // Extension lines.
            commitDrawn(DrawnEntity(shape: .line(a: a, b: dimA)))
            if !pts.contains(where: { hypot($0.x - b.x, $0.y - b.y) < 0.001 }) {
                commitDrawn(DrawnEntity(shape: .line(a: b, b: dimB)))
            }
            // Text label at midpoint.
            let mid = CGPoint(x: (dimA.x + dimB.x) / 2, y: (dimA.y + dimB.y) / 2)
            let textHeight = len * 0.04
            commitDrawn(DrawnEntity(shape: .text(position: mid, height: textHeight,
                                                  string: fmt.length(len))))
            commandMessage = "Measured distance: \(fmt.length(len))"

        case .area:
            guard pts.count >= 3 else { return }
            commitDrawn(DrawnEntity(shape: .polyline(pts: pts, closed: true)))
            let areaVal = MeasureState.polygonArea(pts)
            let centroid = pts.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x / CGFloat(pts.count),
                                                              y: $0.y + $1.y / CGFloat(pts.count)) }
            let perimeter = MeasureState.pathLength(pts, closed: true)
            let textHeight = (perimeter / CGFloat(pts.count)) * 0.4
            commitDrawn(DrawnEntity(shape: .text(position: centroid, height: textHeight,
                                                  string: "\(fmt.area(areaVal)) (\(fmt.length(perimeter)))")))
            commandMessage = "Measured area: \(fmt.area(areaVal))"

        case .radius:
            let label = closed ? "Diameter: \(fmt.length(arcRadius * 2))" : "Radius: \(fmt.length(arcRadius))"
            let rPx = arcRadius * zoom
            let pivot = CGPoint(x: arcCenter.x + rPx * 0.6, y: arcCenter.y + rPx * 0.6)
            commitDrawn(DrawnEntity(shape: .line(a: arcCenter, b: pivot)))
            commitDrawn(DrawnEntity(shape: .line(a: pivot, b: CGPoint(x: pivot.x + rPx * 0.15, y: pivot.y))))
            let textHeight = arcRadius * 0.06
            commitDrawn(DrawnEntity(shape: .text(position: pivot, height: textHeight, string: label)))
            commandMessage = "Measured \(label)"

        case .angle:
            guard pts.count >= 3 else { return }
            let vertex = pts[0], arm1 = pts[1], arm2 = pts[2]
            commitDrawn(DrawnEntity(shape: .line(a: vertex, b: arm1)))
            commitDrawn(DrawnEntity(shape: .line(a: vertex, b: arm2)))
            let a1 = atan2(arm1.y - vertex.y, arm1.x - vertex.x)
            let a2 = atan2(arm2.y - vertex.y, arm2.x - vertex.x)
            let r = min(hypot(arm1.x - vertex.x, arm1.y - vertex.y),
                        hypot(arm2.x - vertex.x, arm2.y - vertex.y)) * 0.3
            let deg = fmt.angle(abs((a2 - a1) * 180 / .pi).truncatingRemainder(dividingBy: 360))
            commitDrawn(DrawnEntity(shape: .arc(center: vertex, radius: r,
                                                 startDeg: a1 * 180 / .pi, endDeg: a2 * 180 / .pi)))
            let midAngle = (a1 + a2) / 2
            let labelPos = CGPoint(x: vertex.x + r * 1.3 * cos(midAngle),
                                   y: vertex.y + r * 1.3 * sin(midAngle))
            let textHeight = r * 0.25
            commitDrawn(DrawnEntity(shape: .text(position: labelPos, height: textHeight, string: deg)))
            commandMessage = "Measured angle: \(deg)"

        case .select: break
        }
    }

    /// Returns a perpendicular offset vector (dx, dy) of length `amount`.
    private func perpendicularOffset(from a: CGPoint, to b: CGPoint, amount: CGFloat) -> CGPoint {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = hypot(dx, dy)
        guard len > 0 else { return .zero }
        return CGPoint(x: -dy / len * amount, y: dx / len * amount)
    }

    /// The `DraftContext` a `DraftState` call needs to build a real
    /// `EntityPrototype`, chosen per the plan's "old tools keep their layer,
    /// new CAD tools use CLAYER" scope decision (see `CurrentProperties.
    /// swift`'s header comment and `DraftContext`'s own doc comment in
    /// DraftingTools.swift). `draft.mode` alone decides which flavor — every
    /// legacy mode (LINE/PLINE/CIRCLE/ARC/RECT/POLYGON) still resolves to
    /// the NOVACAD-MARKUP layer + `markupColor`, unchanged from pre-Phase-6.3
    /// behavior; every Phase 6.3 mode resolves to `currentProperties`.
    private func draftContext(for mode: DraftState.Mode) -> DraftContext? {
        guard let regen else { return nil }
        switch mode {
        case .line, .polyline, .circle, .arc3pt, .rect, .polygon:
            let layerId = ensureMarkupLayerId()
            return .markup(layerId: layerId, aci: markupColor, isPaper: space == .paper, store: regen.parsed.store)
        case .ellipse, .ellipseAxis, .splineFit, .splineCV, .pointEnt, .face3d:
            return .current(currentProperties, parsed: regen.parsed, isPaper: space == .paper)
        case .none, .text, .stamp, .erase, .region:
            return nil
        }
    }

    /// Commits a `DraftOutput.entity` prototype exactly like `commitDrawn`
    /// does for the legacy `DrawnEntity` path — same transaction shape
    /// (`session.performEdit("Draw") { tx in tx.add(...) } }`), generalized
    /// to accept an already-built `EntityPrototype` (which already carries
    /// its own layer/color/owner from `DraftContext`, unlike `commitDrawn`,
    /// which stamps `markupColor`/the markup layer on unconditionally).
    /// `.none`/`.needsBoundaryPick` are no-ops here — the latter is handled
    /// by the REGION-specific call site in `feedTypedPoint`, never routed
    /// through this generic committer.
    @discardableResult
    private func commitDraftOutput(_ output: DraftOutput, label: String) -> EntityID? {
        guard case .entity(let proto) = output else { return nil }
        var newId: EntityID?
        session.performEdit("Draw") { tx in newId = tx.add(proto) }
        if newId != nil { commandMessage = "Drew \(label)" }
        return newId
    }

    /// Feeds one point into `draft.addPoint`, resolving the right
    /// `DraftContext` for the active mode and committing whatever comes
    /// back — the shared body every `draft.addPoint` call site now uses
    /// instead of calling `addPoint`/`commitDrawn` directly (see
    /// `draftContext(for:)`'s doc comment for the markup-vs-CurrentProperties
    /// split this hides).
    private func feedDraftPoint(_ p: CGPoint) {
        guard let ctx = draftContext(for: draft.mode) else { return }
        commitDraftOutput(draft.addPoint(p, ctx: ctx), label: draftEntityLabel(draft.mode))
    }

    private func draftEntityLabel(_ mode: DraftState.Mode) -> String {
        switch mode {
        case .line: return "Line"
        case .polyline: return "Polyline"
        case .circle: return "Circle"
        case .arc3pt: return "Arc"
        case .rect: return "Rectangle"
        case .polygon: return "Polygon"
        case .ellipse, .ellipseAxis: return "Ellipse"
        case .splineFit, .splineCV: return "Spline"
        case .pointEnt: return "Point"
        case .face3d: return "3DFace"
        case .text, .stamp, .erase, .region, .none: return "entity"
        }
    }

    /// REGION (fallback scope — see the plan's own "select a closed
    /// polyline/circle/ellipse -> region record" text): hit-tests `world`
    /// and, if the hit is a closed LWPOLYLINE/POLYLINE2D, CIRCLE, or
    /// ELLIPSE, records a `RegionRecord` (see `Editing/RegionTool.swift`)
    /// tagging that source entity as a region — this app does NOT build a
    /// real boundary-tracing REGION from arbitrary intersecting geometry
    /// (explicitly out of scope per the plan; that's Phase 7's
    /// `BoundaryDetect.trace`). Non-closed or unsupported picks report a
    /// clear message rather than silently no-op'ing.
    private func commitRegionPick(at world: CGPoint) {
        guard let doc = document, let regen else { return }
        let tol = 6 / max(zoom, 1e-12)
        guard let hit = HitTester.hitTestEntityID(document: doc, usePaperSpace: space == .paper,
                                                  at: world, tolerance: tol, visibility: visibility) else {
            commandMessage = "REGION — nothing found there"
            return
        }
        guard let record = RegionTool.makeRegion(from: hit, store: regen.parsed.store) else {
            commandMessage = "REGION — that object isn't a closed polyline, circle, or ellipse"
            return
        }
        // Both `session.regions` and the source entity's XDATA are outside
        // `Transaction`'s own undo system (a plain side dictionary and a
        // sparse `EntityStore.xdata` write, respectively — see
        // `RegionTool.swift`'s header comment) — registered as a side
        // effect exactly like `BlockEditor.createBlock`'s block-table
        // metadata, so ⌘Z after REGION un-tags the source entity instead of
        // leaving a dangling region record pointing at an entity that no
        // longer (as far as undo history is concerned) was ever regioned.
        session.performEdit("Region") { tx in
            let store = regen.parsed.store
            let xdataBefore = store.xdata[hit.raw]
            RegionTool.tagAsRegionXData(hit, store: store)
            tx.registerSideEffect(
                undo: {
                    session.regions[hit] = nil
                    store.xdata[hit.raw] = xdataBefore
                },
                redo: {
                    session.regions[hit] = record
                    RegionTool.tagAsRegionXData(hit, store: store)
                })
        }
        session.regions[hit] = record
        session.lastCreatedEntities = [hit]
        commandMessage = "REGION — recorded (area \(String(format: "%.3f", abs(record.area))))"
    }

    /// Ordinary document undo — retired per the plan ("U/⌘Z → doc.undo()").
    /// No longer markup-specific: undoes whatever the last transaction was,
    /// same as ⌘Z.
    private func undoLast() {
        session.undo()
        commandMessage = ""
    }

    /// Phase 6.1 rewire: places a REAL INSERT of the chosen block via
    /// `BlockEditor.insert` — retires the old exploded-stamp workflow (which
    /// added a flattened COPY of the block's geometry as markup-only
    /// entities, with no live link back to the block definition at all).
    /// `document?.blockStamps[name]` (the bounded, pre-captured flattened
    /// geometry) remains in use ONLY for `stampGhost`'s hover preview below
    /// — exactly the plan's "blockStamps geometry remains only as
    /// ghost-preview" instruction — never for the committed entity itself
    /// anymore.
    private func placeStamp(at world: CGPoint) {
        guard let regen, let name = stampBlockName else {
            commandMessage = "Choose a block to stamp first (Tools ▸ Stamp Block)"
            return
        }
        let layerId = ensureMarkupLayerId()
        let owner: OwnerRef = space == .paper ? .paper : .model
        var newId: EntityID?
        session.performEdit("Stamp") { tx in
            newId = BlockEditor.insert(blockName: name, at: world, layerId: layerId, owner: owner,
                                       in: regen.parsed, tx: tx)
        }
        if let newId {
            session.lastCreatedEntities = [newId]
            commandMessage = "Stamped \(name) (INSERT)"
        } else {
            commandMessage = "Stamp — could not insert \"\(name)\" (block missing or empty)"
        }
    }

    private var stampGhost: [DrawnEntity] {
        guard draft.mode == .stamp, let doc = document, let name = stampBlockName,
              let geo = doc.blockStamps[name], let h = draft.snap?.point ?? draft.hover
        else { return [] }
        let d = CGVector(dx: h.x, dy: h.y)
        return geo.map { DrawnEntity(shape: $0.translated(by: d).shape) }
    }

    // MARK: - Tool switching

    private func setTool(select: Bool) {
        draft = DraftState()
        measure = MeasureState()
        moveState = MoveState()
        cancelModify()
        cancelTrimExtend()
        cancelFilletChamfer()
        cancelOffset()
        cancelBlock()
        cancelExplode()
        cancelJoin()
        cancelArray()
        cancelOneShotAttributeFlags()
        eraseCandidate = nil
        pendingEllipseRotationAngle = false
        commandMessage = ""
    }

    private func setMeasure(_ mode: MeasureState.Mode) {
        draft = DraftState()
        moveState = MoveState()
        cancelModify()
        cancelTrimExtend()
        cancelFilletChamfer()
        cancelOffset()
        cancelBlock()
        cancelExplode()
        cancelJoin()
        cancelArray()
        cancelOneShotAttributeFlags()
        eraseCandidate = nil
        pendingEllipseRotationAngle = false
        measure = MeasureState(mode: mode)
    }

    private func setDraft(_ mode: DraftState.Mode) {
        measure = MeasureState()
        moveState = MoveState()
        cancelModify()
        cancelTrimExtend()
        cancelFilletChamfer()
        cancelOffset()
        cancelBlock()
        cancelExplode()
        cancelJoin()
        cancelArray()
        cancelOneShotAttributeFlags()
        eraseCandidate = nil
        pendingEllipseRotationAngle = false
        draft = DraftState(mode: mode)
    }

    private var currentToolLabel: String {
        if stretchState.isActive { return "Stretch" }
        if explodeAwaitingSelection { return "Explode" }
        if joinAwaitingSelection { return "Join" }
        if awaitingAttEditPick { return "Edit attributes" }
        if awaitingAttdefPlacement { return "Define attribute" }
        if modifyState.isActive { return modifyState.command.displayName }
        if trimExtendState.isActive { return trimExtendState.command.displayName }
        if filletChamferState.isActive { return filletChamferState.command.displayName }
        if offsetState.isActive { return "Offset" }
        if dimensionToolState.isActive { return dimensionToolState.kind == .aligned ? "Dimension (Aligned)" : "Dimension (Linear)" }
        if blockToolState.isActive { return blockToolState.command.displayName }
        if xrefAttachToolState.isActive { return "Attach Xref" }
        if clipboardPasteToolState.isActive { return "Paste" }
        if arrayToolState.isActive { return "Array" }
        if moveState.isActive { return "Move" }
        if draft.isActive {
            switch draft.mode {
            case .line: return "Line"
            case .polyline: return "Polyline"
            case .circle: return "Circle"
            case .arc3pt: return "Arc"
            case .rect: return "Rectangle"
            case .polygon: return "Polygon"
            case .text: return "Text"
            case .stamp: return "Stamp"
            case .erase: return "Erase"
            case .ellipse, .ellipseAxis: return "Ellipse"
            case .splineFit, .splineCV: return "Spline"
            case .pointEnt: return "Point"
            case .face3d: return "3DFace"
            case .region: return "Region"
            case .none: break
            }
        }
        switch measure.mode {
        case .distance: return "Distance"
        case .area: return "Area"
        case .radius: return "Radius"
        case .angle: return "Angle"
        case .select: return "Select"
        }
    }

    private var currentToolIcon: String {
        if modifyState.isActive {
            switch modifyState.command {
            case .copy: return "plus.square.on.square"
            case .rotate: return "rotate.right"
            case .scale: return "arrow.up.left.and.arrow.down.right"
            case .mirror: return "arrow.left.and.right.righttriangle.left.righttriangle.right"
            case .move: return "arrow.up.and.down.and.arrow.left.and.right"
            }
        }
        if trimExtendState.isActive {
            switch trimExtendState.command {
            case .trim: return "scissors"
            case .extend: return "arrow.up.left.and.arrow.down.right"
            }
        }
        if filletChamferState.isActive {
            switch filletChamferState.command {
            case .fillet: return "arrow.triangle.merge"
            case .chamfer: return "line.diagonal"
            }
        }
        if offsetState.isActive { return "square.on.square" }
        if dimensionToolState.isActive { return "ruler" }
        if blockToolState.isActive {
            switch blockToolState.command {
            case .block: return "cube"
            case .insert: return "cube.transparent"
            }
        }
        if arrayToolState.isActive { return "square.grid.3x3" }
        if xrefAttachToolState.isActive { return "link" }
        if clipboardPasteToolState.isActive { return "doc.on.clipboard" }
        if moveState.isActive { return "arrow.up.and.down.and.arrow.left.and.right" }
        if draft.isActive {
            switch draft.mode {
            case .line: return "line.diagonal"
            case .polyline: return "point.topleft.down.to.point.bottomright.curvepath"
            case .circle: return "circle"
            case .arc3pt: return "point.3.connected.trianglepath.dotted"
            case .rect: return "rectangle"
            case .polygon: return "hexagon"
            case .text: return "textformat"
            case .stamp: return "square.on.square"
            case .erase: return "eraser"
            case .ellipse, .ellipseAxis: return "oval"
            case .splineFit, .splineCV: return "scribble"
            case .pointEnt: return "smallcircle.filled.circle"
            case .face3d: return "triangle"
            case .region: return "square.dashed"
            case .none: break
            }
        }
        switch measure.mode {
        case .distance: return "ruler"
        case .area: return "skew"
        case .radius: return "circle.dashed"
        case .angle: return "angle"
        case .select: return "cursorarrow"
        }
    }

    private var markupColorMenu: some View {
        Menu {
            ForEach(Self.markupPalette, id: \.aci) { entry in
                Button {
                    markupColor = entry.aci
                    recolorSelectedMarkup()
                } label: {
                    Label {
                        Text(entry.name + (markupColor == entry.aci ? "  ✓" : ""))
                    } icon: {
                        Image(systemName: "square.fill")
                            .foregroundColor(Color(rgb: ACIPalette.rgb(forACI: entry.aci)))
                    }
                }
            }
        } label: {
            Label {
                Text("Markup color")
            } icon: {
                Image(systemName: "square.fill")
                    .foregroundColor(Color(rgb: ACIPalette.rgb(forACI: markupColor)))
            }
        }
        .menuIndicator(.visible)
        .fixedSize()
        .help("Markup color — draw current vs. proposed flows in different colors")
        .disabled(document == nil || isLoading)
    }

    // MARK: - Hover routing (measure preview, OSNAP, erase highlighting)

    private func handleHover(at location: CGPoint) {
        let world = location.applying(worldToView().inverted())
        // Grip editing: hover-highlight which grip WOULD be grabbed — only
        // reachable in plain select mode (`gripEditingEligible` already
        // excludes every state every branch below handles), and only while
        // NOT already mid-drag (`onGripDrag`, wired separately to
        // `DXFCanvasView.onGripDrag`, owns hover updates once a drag is
        // underway — this branch is for the pre-drag "which grip is under
        // the cursor" indicator only).
        if gripEditingEligible, gripDragState.phase != .dragging, let regen, let id = selection.first {
            let tolerance = 8 / max(zoom, 1e-12)
            if let hit = GripEditing.nearestGrip(candidateIds: [id], in: regen.parsed.store,
                                                 to: world, tolerance: tolerance) {
                gripDragState.phase = .hovering
                gripDragState.entityId = hit.entityId
                gripDragState.gripIndex = hit.gripIndex
            } else if gripDragState.phase == .hovering {
                gripDragState = GripDragState()
            }
            return
        }
        if measure.isActive {
            measure.hover = world
            guard let doc = document, Date().timeIntervalSince(lastSnapAt) > 0.05 else { return }
            lastSnapAt = Date()
            let tol = 9 / max(zoom, 1e-12)
            measure.snap = Osnap.snap(document: doc, usePaperSpace: space == .paper,
                near: world, tolerance: tol, visibility: visibility,
                from: measure.points.last)
            return
        }
        if awaitingAttdefPlacement {
            // A plain point pick — reuses `blockToolState`'s hover/snap
            // fields (unused while `blockToolState.phase == .idle`, which it
            // always is during ATTDEF per `startAttdef`'s `cancelBlock()`)
            // rather than adding a THIRD parallel hover/snap pair to
            // ContentView for a single-click, rarely-used command.
            blockToolState.hover = world
            guard let doc = document, Date().timeIntervalSince(lastSnapAt) > 0.05 else { return }
            lastSnapAt = Date()
            let tol = 9 / max(zoom, 1e-12)
            blockToolState.snap = Osnap.snap(document: doc, usePaperSpace: space == .paper,
                near: world, tolerance: tol, visibility: visibility, from: nil)
            return
        }
        if modifyState.isActive, modifyState.phase != .selecting {
            modifyState.hover = world
            guard let doc = document, Date().timeIntervalSince(lastSnapAt) > 0.05 else { return }
            lastSnapAt = Date()
            let tol = 9 / max(zoom, 1e-12)
            // CRITICAL (per the project's own prior regression, fixed in
            // Phase 1.7 for Move — see git history "fix Move tool OSNAP to
            // exclude objects being moved"): once a base point is set, the
            // objects being transformed must be excluded from their own
            // snap candidates for EVERY subsequent point pick (angle/
            // factor/mirror-end/destination) — the render model still shows
            // them at their PRE-transform position until commit, so without
            // this the ghost preview and every later pick would snap back
            // onto the source geometry instead of onto other, untouched
            // entities. Unlike Move (which only excludes during the SECOND
            // point), every one of THESE 4 commands' second-and-later
            // points is itself a candidate for this same bug, so exclusion
            // applies to every phase past `.pickBase`, not just one.
            let excluding: Set<EntityID> = modifyState.phase == .pickBase ? [] : modifyState.objectIDs
            modifyState.snap = Osnap.snap(document: doc, usePaperSpace: space == .paper,
                near: world, tolerance: tol, visibility: visibility, from: modifyState.basePoint,
                excluding: excluding)
            return
        }
        if trimExtendState.phase == .pickingTargets {
            // No OSNAP here — TRIM/EXTEND targets whole OBJECTS, not points
            // (unlike ROTATE/SCALE/MIRROR's later phases), so there is no
            // snap candidate to compute; `hover` is tracked purely for the
            // hover-highlight preview (`trimExtendHoverCandidate`) below.
            trimExtendState.hover = world
            return
        }
        if filletChamferState.isActive {
            // Same "whole object, no OSNAP" convention as TRIM/EXTEND above
            // — FILLET/CHAMFER pick two LINES, not points. Previously
            // missing entirely (an adversarial review found `handleHover`
            // had no branch for this state at all, so FILLET/CHAMFER got
            // zero hover feedback while every other modal tool had some).
            filletChamferState.hover = world
            return
        }
        if offsetState.isActive {
            // OFFSET's `pickObject` phase is also a whole-object pick; its
            // later `pickSideOrPoint` phase doesn't OSNAP either (the side
            // is which side of the object the click lands on, not a snap
            // target) — `hover` here only drives the highlight preview.
            offsetState.hover = world
            return
        }
        if dimensionToolState.isActive {
            // Every DIMENSION click (including the 3rd, "where does the
            // dimension line sit" placement pick) is a plain point pick —
            // OSNAP applies throughout, same as ROTATE/SCALE/MIRROR's
            // later phases, so extension-line origins can snap precisely
            // to endpoints/midpoints of the geometry being measured.
            dimensionToolState.hover = world
            guard let doc = document, Date().timeIntervalSince(lastSnapAt) > 0.05 else { return }
            lastSnapAt = Date()
            let tol = 9 / max(zoom, 1e-12)
            dimensionToolState.snap = Osnap.snap(document: doc, usePaperSpace: space == .paper,
                near: world, tolerance: tol, visibility: visibility, from: dimensionToolState.firstPoint)
            return
        }
        if stretchState.phase == .pickingBase || stretchState.phase == .pickingDestination {
            // Plain point pick, OSNAP-eligible — same shape as MOVE's own
            // base/destination phases. Unlike MOVE, no `excluding:` is
            // needed: the ghost preview shows the STRETCHED result, but
            // OSNAP candidates are drawn from the CURRENT (pre-stretch)
            // document geometry either way, and there's no risk of
            // snapping back onto "the same points being moved" the way
            // MOVE's whole-entity translate can (a stretch typically only
            // moves a handful of vertices, not whole entities, so the
            // "snap back onto my own pre-move self" collision this
            // excludes for MOVE isn't the dominant case here — the
            // simpler, exclusion-free behavior matches AutoCAD's own
            // STRETCH, which does not exclude the stretched entity from
            // its own OSNAP candidates either).
            stretchState.hover = world
            guard let doc = document, Date().timeIntervalSince(lastSnapAt) > 0.05 else { return }
            lastSnapAt = Date()
            let tol = 9 / max(zoom, 1e-12)
            stretchState.snap = Osnap.snap(document: doc, usePaperSpace: space == .paper,
                near: world, tolerance: tol, visibility: visibility, from: stretchState.basePoint)
            return
        }
        if blockToolState.phase == .pickBasePoint || blockToolState.phase == .pickInsertPoint {
            // Both are plain POINT picks (base point / insertion point) —
            // OSNAP applies, same as ROTATE/SCALE/MIRROR's later phases.
            blockToolState.hover = world
            guard let doc = document, Date().timeIntervalSince(lastSnapAt) > 0.05 else { return }
            lastSnapAt = Date()
            let tol = 9 / max(zoom, 1e-12)
            blockToolState.snap = Osnap.snap(document: doc, usePaperSpace: space == .paper,
                near: world, tolerance: tol, visibility: visibility, from: nil)
            return
        }
        if xrefAttachToolState.isActive {
            // Plain point pick, same shape as INSERT's own hover/snap above.
            xrefAttachToolState.hover = world
            guard let doc = document, Date().timeIntervalSince(lastSnapAt) > 0.05 else { return }
            lastSnapAt = Date()
            let tol = 9 / max(zoom, 1e-12)
            xrefAttachToolState.snap = Osnap.snap(document: doc, usePaperSpace: space == .paper,
                near: world, tolerance: tol, visibility: visibility, from: nil)
            return
        }
        if clipboardPasteToolState.isActive {
            // Plain point pick, same shape as INSERT/Attach-Xref's own
            // hover/snap above.
            clipboardPasteToolState.hover = world
            guard let doc = document, Date().timeIntervalSince(lastSnapAt) > 0.05 else { return }
            lastSnapAt = Date()
            let tol = 9 / max(zoom, 1e-12)
            clipboardPasteToolState.snap = Osnap.snap(document: doc, usePaperSpace: space == .paper,
                near: world, tolerance: tol, visibility: visibility, from: nil)
            return
        }
        if moveState.isActive {
            moveState.hover = world
            guard let doc = document, Date().timeIntervalSince(lastSnapAt) > 0.05 else { return }
            lastSnapAt = Date()
            let tol = 9 / max(zoom, 1e-12)
            // Markup is ordinary document geometry now (Phase 1.7) — plain
            // `Osnap.snap` already finds it via `document`'s render groups,
            // same as any other entity; the old `snapWithMarkup`/`drawn`-
            // array path is retired. While picking the DESTINATION point,
            // exclude the object(s) being moved from their own snap
            // candidates — the render model still shows them at their
            // PRE-move position until commit, so without this the ghost
            // preview and destination pick snap back onto the source
            // geometry instead of onto other, stationary entities.
            moveState.snap = Osnap.snap(document: doc, usePaperSpace: space == .paper,
                near: world, tolerance: tol, visibility: visibility, from: moveState.basePoint,
                excluding: moveState.phase == .pickingDestination ? moveState.objectIDs : [])
            return
        }
        guard draft.isActive else { return }
        draft.hover = world

        if draft.mode == .erase {
            guard let doc = document else { return }
            let tol = 6 / max(zoom, 1e-12)
            eraseCandidate = markupHitTest(at: world, document: doc, tolerance: tol)
            return
        }
        // OSNAP — throttled: the scan walks visible run bounds, which can take
        // tens of ms on multi-million-entity drawings.
        guard let doc = document, Date().timeIntervalSince(lastSnapAt) > 0.05 else { return }
        lastSnapAt = Date()
        let tol = 9 / max(zoom, 1e-12)
        draft.snap = Osnap.snap(document: doc, usePaperSpace: space == .paper,
                                near: world, tolerance: tol, visibility: visibility,
                                from: draft.points.last)
    }

    /// Hit-tests ONLY markup (NOVACAD-MARKUP layer) at `world` — used by the
    /// Erase tool, which (like the pre-1.7 code) only ever erases user-drawn
    /// markup, never the original drawing's geometry.
    ///
    /// IMPORTANT: this hides every OTHER layer first, rather than doing a
    /// normal `hitTestEntityID` and checking after the fact whether the
    /// globally-closest hit happens to be markup — the latter would silently
    /// miss a hoverable markup entity whenever ANY non-markup geometry
    /// within tolerance happens to be even slightly closer to the cursor
    /// (`hitTest` only ever returns its single best match), which would
    /// regress `hitTestDrawn`'s old behavior of searching ONLY `drawn`
    /// (so markup was always found regardless of what else was nearby).
    private func markupHitTest(at world: CGPoint, document doc: DXFDocument, tolerance: CGFloat) -> EntityID? {
        guard let markupLayerId = session.markupLayerId else { return nil }
        var markupOnly = visibility
        markupOnly.hiddenLayerIds = Set(doc.layers.map(\.id)).subtracting([Int(markupLayerId)])
        return HitTester.hitTestEntityID(document: doc, usePaperSpace: space == .paper,
                                         at: world, tolerance: tolerance, visibility: markupOnly)
    }

    private func finishAreaMeasurement() {
        guard measure.mode == .area, measure.points.count >= 3 else { return }
        // The double-click's first click added a duplicate point — drop it.
        if measure.points.count >= 2,
           let last = measure.points.last, let prev = measure.points.dropLast().last,
           hypot(last.x - prev.x, last.y - prev.y) < 3 / max(zoom, 1e-12) {
            measure.points.removeLast()
        }
        measure.closed = true
        measure.hover = nil
    }

    // MARK: - Selection

    private func handleClick(at viewPoint: CGPoint, shiftDown: Bool) {
        guard let doc = document else { return }
        let worldPoint = viewPoint.applying(worldToView().inverted())
        // Phase 6.1: ATTEDIT's/ATTDEF's one-shot pick/placement flags — checked
        // FIRST, ahead of every other modal tool's own branch, since they are
        // simple booleans rather than a full state machine and neither
        // command's `start*` function leaves any OTHER modal tool active
        // (see `startAttedit`/`startAttdef`'s own `cancel*` calls), so there
        // is no real ordering ambiguity — this mirrors how `pendingSetVar`/
        // `pendingFilletChamferEntry` are checked before `CommandParser.parse`
        // in `executeCommand`, the same "simple one-shot flag intercepts
        // before the general dispatch" convention.
        if awaitingAttEditPick {
            commitAttEditPick(at: worldPoint)
            return
        }
        if awaitingAttdefPlacement {
            let snapped = blockToolState.snap?.point ?? worldPoint
            commitAttdefPlacement(at: snapped)
            return
        }
        if xrefAttachToolState.isActive {
            // Plain point pick, OSNAP-eligible — mirrors INSERT's own
            // `.pickInsertPoint` (`blockToolState.snap`), a separate
            // hover/snap pair since `xrefAttachToolState` is its own type.
            let snapped = xrefAttachToolState.snap?.point ?? worldPoint
            commitXrefAttachAt(snapped)
            return
        }
        if clipboardPasteToolState.isActive {
            let snapped = clipboardPasteToolState.snap?.point ?? worldPoint
            commitClipboardPasteAt(snapped)
            return
        }
        if explodeAwaitingSelection {
            let tolerance = 6 / max(zoom, 1e-12)
            let hit = HitTester.hitTestEntityID(document: doc, usePaperSpace: space == .paper,
                                                at: worldPoint, tolerance: tolerance, visibility: visibility)
            handleExplodeClick(hit: hit, worldPoint: worldPoint, shiftDown: shiftDown)
            return
        }
        if joinAwaitingSelection {
            let tolerance = 6 / max(zoom, 1e-12)
            let hit = HitTester.hitTestEntityID(document: doc, usePaperSpace: space == .paper,
                                                at: worldPoint, tolerance: tolerance, visibility: visibility)
            handleJoinClick(hit: hit, worldPoint: worldPoint, shiftDown: shiftDown)
            return
        }
        if modifyState.isActive {
            if modifyState.phase == .selecting {
                let tolerance = 6 / max(zoom, 1e-12)
                let hit = HitTester.hitTestEntityID(document: doc, usePaperSpace: space == .paper,
                                                    at: worldPoint, tolerance: tolerance, visibility: visibility)
                handleModifyClick(hit: hit, worldPoint: worldPoint, shiftDown: shiftDown)
            } else {
                handleModifyClick(hit: nil, worldPoint: modifyState.snap?.point ?? worldPoint, shiftDown: shiftDown)
            }
            return
        }
        if trimExtendState.isActive {
            // BOTH phases need a fresh hit-test at the click point: while
            // `.selectingBoundaries` it's an ordinary SelectionPrompt pick;
            // while `.pickingTargets`, every single click targets a NEW
            // entity (unlike ROTATE/SCALE/MIRROR's later phases, which pick
            // abstract POINTS, not objects, after their first click) — there
            // is no "snap to a point" concept for choosing a trim/extend
            // target, only "which object did I click."
            let tolerance = 6 / max(zoom, 1e-12)
            let hit = HitTester.hitTestEntityID(document: doc, usePaperSpace: space == .paper,
                                                at: worldPoint, tolerance: tolerance, visibility: visibility)
            handleTrimExtendClick(hit: hit, worldPoint: worldPoint, shiftDown: shiftDown)
            return
        }
        if stretchState.isActive {
            if stretchState.phase == .selecting {
                let tolerance = 6 / max(zoom, 1e-12)
                let hit = HitTester.hitTestEntityID(document: doc, usePaperSpace: space == .paper,
                                                    at: worldPoint, tolerance: tolerance, visibility: visibility)
                handleStretchClick(hit: hit, worldPoint: worldPoint)
            } else {
                handleStretchClick(hit: nil, worldPoint: stretchState.snap?.point ?? worldPoint)
            }
            return
        }
        if filletChamferState.isActive {
            let tolerance = 6 / max(zoom, 1e-12)
            let hit = HitTester.hitTestEntityID(document: doc, usePaperSpace: space == .paper,
                                                at: worldPoint, tolerance: tolerance, visibility: visibility)
            handleFilletChamferClick(hit: hit, worldPoint: worldPoint)
            return
        }
        if offsetState.isActive {
            if offsetState.phase == .pickObject {
                let tolerance = 6 / max(zoom, 1e-12)
                let hit = HitTester.hitTestEntityID(document: doc, usePaperSpace: space == .paper,
                                                    at: worldPoint, tolerance: tolerance, visibility: visibility)
                handleOffsetClick(hit: hit, worldPoint: worldPoint)
            } else {
                // The side/through-point click is a plain world point, not
                // an object pick — no hit-test needed (mirrors ROTATE/
                // SCALE/MIRROR's later phases, which pick abstract points).
                handleOffsetClick(hit: nil, worldPoint: worldPoint)
            }
            return
        }
        if dimensionToolState.isActive {
            // Every click is a plain point pick (OSNAP-eligible) — no
            // hit-test needed, mirrors OFFSET's own placement-click branch.
            handleDimensionClick(at: dimensionToolState.snap?.point ?? worldPoint)
            return
        }
        if blockToolState.isActive {
            if blockToolState.phase == .selecting {
                let tolerance = 6 / max(zoom, 1e-12)
                let hit = HitTester.hitTestEntityID(document: doc, usePaperSpace: space == .paper,
                                                    at: worldPoint, tolerance: tolerance, visibility: visibility)
                handleBlockClick(hit: hit, worldPoint: worldPoint, shiftDown: shiftDown)
            } else {
                // pickBasePoint/pickInsertPoint are plain world-point picks
                // (with OSNAP), not object hit-tests — mirrors ROTATE/SCALE/
                // MIRROR's later phases.
                handleBlockClick(hit: nil, worldPoint: blockToolState.snap?.point ?? worldPoint, shiftDown: shiftDown)
            }
            return
        }
        if arrayToolState.phase == .selecting {
            let tolerance = 6 / max(zoom, 1e-12)
            let hit = HitTester.hitTestEntityID(document: doc, usePaperSpace: space == .paper,
                                                at: worldPoint, tolerance: tolerance, visibility: visibility)
            guard var prompt = selectionPrompt else { return }
            let result = prompt.handle(.pick(hit, worldPoint: worldPoint, shiftHeld: shiftDown))
            selectionPrompt = prompt
            applyArraySelectionPromptResult(result)
            return
        }
        if moveState.isActive {
            commitMovePoint(moveState.snap?.point ?? worldPoint)
            return
        }
        if draft.isActive {
            if draft.mode == .erase {
                let tol = 6 / max(zoom, 1e-12)
                if let victim = markupHitTest(at: worldPoint, document: doc, tolerance: tol) {
                    session.performEdit("Erase") { tx in tx.delete(victim) }
                    eraseCandidate = nil
                }
                return
            }
            let snapped = draft.snap?.point ?? worldPoint
            if draft.mode == .text {
                pendingTextPos = snapped
                pendingTextInput = ""
                showTextPrompt = true
                return
            }
            if draft.mode == .stamp {
                placeStamp(at: snapped)
                return
            }
            if draft.mode == .region {
                commitRegionPick(at: worldPoint)
                return
            }
            feedDraftPoint(snapped)
            return
        }
        if measure.isActive {
            if measure.mode == .radius {
                measure.pickedArc = pickArc(at: worldPoint)
                return
            }
            measure.addPoint(measure.snap?.point ?? worldPoint)
            measure.snap = nil  // snap consumed; next mouse-move re-snaps
            return
        }
        // Select mode: markup is ordinary geometry now, so one hit-test finds
        // either kind of object — no separate "markup floats on top" pass.
        let tolerance = 6 / max(zoom, 1e-12)   // ~6 view points
        let hit = HitTester.hitTestEntityID(document: doc, usePaperSpace: space == .paper,
                                            at: worldPoint, tolerance: tolerance,
                                            visibility: visibility)
        if let hit {
            if shiftDown {
                // AutoCAD: Shift+click removes from the selection set.
                if selection.contains(hit) { selection.remove(hit) }
                else { selection.insert(hit) }
            } else {
                // AutoCAD PICKADD: plain clicks accumulate.
                selection.insert(hit)
            }
        } else if !shiftDown {
            selection = []
        }
    }

    /// Rubber-band select: Window (L→R drag) selects only FULLY enclosed
    /// objects (markup or original geometry — both are ordinary EntityStore
    /// content); Crossing (R→L drag) selects anything the rect touches at
    /// all — Phase 4.1's `SelectionEngine.rectSelect`, replacing the old
    /// Window-only `HitTester.boxSelectEntityIDs` call at this site (that
    /// function is unchanged and still backs `SelectionEngine`'s own
    /// `.window` case, so behavior for an L→R drag is bit-for-bit identical
    /// to before — only R→L crossing-selection is NEW behavior here).
    /// While a modify command is acquiring objects (`modifyState.phase ==
    /// .selecting`), the drag feeds `SelectionPrompt` instead of the plain
    /// `selection` set.
    private func handleBoxSelect(startView: CGPoint, endView: CGPoint, mode: SelectionMode, shiftDown: Bool) {
        guard let doc = document else { return }
        if awaitingAttEditPick || awaitingAttdefPlacement {
            // One-shot pick/placement flags — same "ignore an accidental
            // drag" convention as filletChamferState/offsetState/blockToolState.
            return
        }
        let inv = worldToView().inverted()
        let wa = startView.applying(inv), wb = endView.applying(inv)
        let rect = CGRect(x: min(wa.x, wb.x), y: min(wa.y, wb.y),
                          width: abs(wa.x - wb.x), height: abs(wa.y - wb.y))

        if modifyState.phase == .selecting {
            guard var prompt = selectionPrompt else { return }
            let result = prompt.handle(.boxComplete(rect, mode: mode, shiftHeld: shiftDown))
            selectionPrompt = prompt
            applySelectionPromptResult(result)
            return
        }
        if blockToolState.phase == .selecting {
            guard var prompt = selectionPrompt else { return }
            let result = prompt.handle(.boxComplete(rect, mode: mode, shiftHeld: shiftDown))
            selectionPrompt = prompt
            applyBlockSelectionPromptResult(result)
            return
        }
        if arrayToolState.phase == .selecting {
            guard var prompt = selectionPrompt else { return }
            let result = prompt.handle(.boxComplete(rect, mode: mode, shiftHeld: shiftDown))
            selectionPrompt = prompt
            applyArraySelectionPromptResult(result)
            return
        }
        if explodeAwaitingSelection {
            guard var prompt = selectionPrompt else { return }
            let result = prompt.handle(.boxComplete(rect, mode: mode, shiftHeld: shiftDown))
            selectionPrompt = prompt
            switch result {
            case .pending: commandMessage = selectionPrompt?.promptText ?? ""
            case .done(let ids): if ids.isEmpty { cancelExplode() } else { commitExplode(ids: Array(ids)) }
            case .cancelled: cancelExplode()
            }
            return
        }
        if joinAwaitingSelection {
            guard var prompt = selectionPrompt else { return }
            let result = prompt.handle(.boxComplete(rect, mode: mode, shiftHeld: shiftDown))
            selectionPrompt = prompt
            switch result {
            case .pending: commandMessage = selectionPrompt?.promptText ?? ""
            case .done(let ids): if ids.isEmpty { cancelJoin() } else { commitJoin(ids: Array(ids)) }
            case .cancelled: cancelJoin()
            }
            return
        }
        if trimExtendState.phase == .selectingBoundaries {
            guard var prompt = selectionPrompt else { return }
            let result = prompt.handle(.boxComplete(rect, mode: mode, shiftHeld: shiftDown))
            selectionPrompt = prompt
            applyTrimExtendBoundaryPromptResult(result)
            return
        }
        if trimExtendState.phase == .pickingTargets {
            // A plain rectangle drag while picking targets isn't a
            // meaningful fence for TRIM (its 4 edges would each need their
            // own "indicated side," which a box doesn't express the way an
            // open fence polyline does) — only the lasso/Option-drag
            // gesture is wired as the fence-batch trigger (see
            // `handleLassoSelect`), matching AutoCAD's own FENCE being a
            // distinct sub-mode from plain Window/Crossing. An ordinary
            // drag here is simply ignored (no selection-set concept applies
            // while picking trim/extend targets).
            return
        }
        if stretchState.phase == .selecting {
            // Unlike every other command's box-select branch, STRETCH
            // ALWAYS uses Crossing semantics regardless of drag direction
            // (AutoCAD's real STRETCH has no Window mode at all — every
            // crossing-window or crossing-polygon catches touched grips) —
            // `mode` (L→R/R→L-resolved) is deliberately ignored here.
            handleStretchBoxSelect(rect: rect)
            return
        }
        if stretchState.isActive {
            // pickingBase/pickingDestination: no drag concept applies,
            // same "ignore an accidental drag" convention as trimExtend's
            // pickingTargets phase above.
            return
        }
        if filletChamferState.isActive || offsetState.isActive || dimensionToolState.isActive || blockToolState.isActive || arrayToolState.isActive || xrefAttachToolState.isActive || clipboardPasteToolState.isActive {
            // Same "ignore an accidental drag, don't clobber the ambient
            // selection set" convention as trimExtendState.pickingTargets
            // above — FILLET/CHAMFER/OFFSET pick individual objects
            // one-at-a-time via plain clicks, never a box/window selection.
            // Previously missing: an adversarial review found a ≥3px drag
            // while clicking a line for these three tools fell through to
            // the plain rect-select below and silently overwrote
            // `selection`. `blockToolState.isActive`/`arrayToolState.isActive`
            // here only match their NON-selecting phases (pickKind/
            // pickFields/pickBasePoint for Array) — the `.selecting` phase
            // already returned above via its own branch, exactly like
            // modifyState's equivalent ordering.
            return
        }

        let hitEntities = SelectionEngine.rectSelect(document: doc, usePaperSpace: space == .paper,
                                                     rect: rect, mode: mode, visibility: visibility)
        selection = shiftDown ? selection.union(hitEntities) : hitEntities
    }

    /// Phase 4.1: Option+drag lasso select — same Window/Crossing duality as
    /// `handleBoxSelect`, generalized to an arbitrary polygon via
    /// `SelectionEngine.lassoSelect`. Phase 4.3: also TRIM's fence-batch
    /// trigger while `trimExtendState.phase == .pickingTargets` — the
    /// existing lasso-drag gesture is the closest primitive the canvas
    /// already captures to an arbitrary OPEN fence polyline (AutoCAD's own
    /// FENCE is a distinct gesture from Window/Crossing/lasso; reusing this
    /// one is a deliberate, documented judgment call rather than adding a
    /// 4th drag-gesture kind to `DXFCanvasView` for a single sub-case).
    private func handleLassoSelect(viewPoints: [CGPoint], mode: SelectionMode, shiftDown: Bool) {
        guard let doc = document else { return }
        if awaitingAttEditPick || awaitingAttdefPlacement {
            return
        }
        let inv = worldToView().inverted()
        let worldPoints = viewPoints.map { $0.applying(inv) }

        if modifyState.phase == .selecting {
            guard var prompt = selectionPrompt else { return }
            let result = prompt.handle(.lassoComplete(worldPoints, mode: mode, shiftHeld: shiftDown))
            selectionPrompt = prompt
            applySelectionPromptResult(result)
            return
        }
        if blockToolState.phase == .selecting {
            guard var prompt = selectionPrompt else { return }
            let result = prompt.handle(.lassoComplete(worldPoints, mode: mode, shiftHeld: shiftDown))
            selectionPrompt = prompt
            applyBlockSelectionPromptResult(result)
            return
        }
        if arrayToolState.phase == .selecting {
            guard var prompt = selectionPrompt else { return }
            let result = prompt.handle(.lassoComplete(worldPoints, mode: mode, shiftHeld: shiftDown))
            selectionPrompt = prompt
            applyArraySelectionPromptResult(result)
            return
        }
        if explodeAwaitingSelection {
            guard var prompt = selectionPrompt else { return }
            let result = prompt.handle(.lassoComplete(worldPoints, mode: mode, shiftHeld: shiftDown))
            selectionPrompt = prompt
            switch result {
            case .pending: commandMessage = selectionPrompt?.promptText ?? ""
            case .done(let ids): if ids.isEmpty { cancelExplode() } else { commitExplode(ids: Array(ids)) }
            case .cancelled: cancelExplode()
            }
            return
        }
        if joinAwaitingSelection {
            guard var prompt = selectionPrompt else { return }
            let result = prompt.handle(.lassoComplete(worldPoints, mode: mode, shiftHeld: shiftDown))
            selectionPrompt = prompt
            switch result {
            case .pending: commandMessage = selectionPrompt?.promptText ?? ""
            case .done(let ids): if ids.isEmpty { cancelJoin() } else { commitJoin(ids: Array(ids)) }
            case .cancelled: cancelJoin()
            }
            return
        }
        if trimExtendState.phase == .selectingBoundaries {
            guard var prompt = selectionPrompt else { return }
            let result = prompt.handle(.lassoComplete(worldPoints, mode: mode, shiftHeld: shiftDown))
            selectionPrompt = prompt
            applyTrimExtendBoundaryPromptResult(result)
            return
        }
        if trimExtendState.phase == .pickingTargets {
            if trimExtendState.command == .trim {
                handleTrimExtendFenceDrag(worldPoints)
            }
            // EXTEND has no fence-batch mode (see `TrimExtendExecutor.trimFenceBatch`'s
            // doc comment) — a lasso drag while extending is simply ignored.
            return
        }
        if stretchState.isActive {
            // Scope decision (matching EXTEND's own "no fence-batch mode"
            // precedent immediately above): `GripEditing.caughtGrips` only
            // takes a rectangular crossing window today, so an Option+drag
            // lasso during STRETCH acquisition is simply ignored rather
            // than approximated against the lasso's bounding box (which
            // would silently catch grips OUTSIDE the drawn polygon but
            // inside its rectangular bounds) — plain crossing-window drags
            // (handled in `handleBoxSelect`) are STRETCH's supported
            // acquisition gesture.
            return
        }
        if filletChamferState.isActive || offsetState.isActive || dimensionToolState.isActive || blockToolState.isActive || arrayToolState.isActive || xrefAttachToolState.isActive || clipboardPasteToolState.isActive {
            // Same rationale as the equivalent guard in `handleBoxSelect`
            // (blockToolState.isActive/arrayToolState.isActive here only
            // match their non-selecting phases, same reasoning as that
            // guard's own comment).
            return
        }

        let hitEntities = SelectionEngine.lassoSelect(document: doc, usePaperSpace: space == .paper,
                                                       polygon: worldPoints, mode: mode, visibility: visibility)
        selection = shiftDown ? selection.union(hitEntities) : hitEntities
    }

    /// Shared `SelectionPromptResult` handling for every gesture that can
    /// finish a `.selecting` acquisition (box/lasso/fence/token) — advances
    /// `modifyState` to its first geometric-parameter phase on `.done`,
    /// fully cancels on `.cancelled` or an EMPTY `.done` (Enter with
    /// nothing picked — AutoCAD's own "Select objects:" + bare Enter aborts
    /// the command when nothing was ever selected).
    private func applySelectionPromptResult(_ result: SelectionPromptResult) {
        switch result {
        case .pending:
            commandMessage = selectionPrompt?.promptText ?? ""
        case .done(let ids):
            if ids.isEmpty { cancelModify() }
            else { modifyState.withAcquiredObjects(ids); selectionPrompt = nil; commandMessage = modifyState.prompt }
        case .cancelled:
            cancelModify()
        }
    }

    /// Finishes the active `SelectionPrompt` acquisition (bare Enter while
    /// `modifyState.phase == .selecting`) — matches AutoCAD's own
    /// "Select objects:" + Enter ending the acquisition with whatever was
    /// picked so far (or aborting the whole command if nothing was ever
    /// picked, via `applySelectionPromptResult`'s empty-`.done` handling).
    /// MUST be reachable from BOTH the canvas's Return key (`onReturnKey`)
    /// and the command bar's bare-Enter path (`executeCommand`) — a prior
    /// draft of this feature wired neither, leaving the entire verb-first
    /// empty-selection entry point for COPY/ROTATE/SCALE/MIRROR unusable
    /// (caught by adversarial review, not by any unit test).
    private func finishSelectionPrompt() {
        guard var prompt = selectionPrompt else { return }
        let result = prompt.handle(.finish)
        selectionPrompt = prompt
        applySelectionPromptResult(result)
    }

    /// Actions offered by a right-click, tailored to what's currently selected
    /// or in progress.
    private func contextMenuItems(at viewPoint: CGPoint) -> [ContextMenuAction] {
        guard document != nil else { return [] }
        var items: [ContextMenuAction] = []
        if moveState.isActive || modifyState.isActive || trimExtendState.isActive || filletChamferState.isActive || offsetState.isActive || dimensionToolState.isActive || blockToolState.isActive || arrayToolState.isActive || draft.isActive || measure.isActive || awaitingAttEditPick || awaitingAttdefPlacement || explodeAwaitingSelection || joinAwaitingSelection || xrefAttachToolState.isActive || clipboardPasteToolState.isActive || stretchState.isActive {
            items.append(ContextMenuAction(title: "Cancel", action: { [self] in handleEscape() }))
            return items
        }
        // Phase 6.4: "Edit Array" — offered when the right-click landed on
        // (or the current selection contains) a live array member, per the
        // plan's '"Edit Array" (context menu on any member)' spec text.
        // Looked up by scanning `session.arrays` for a definition whose
        // `memberHandles` contains the hit entity — a plain linear scan
        // over (typically) a handful of arrays per document, not a hot path.
        if let arrayHit = arrayEditTarget(at: viewPoint) {
            items.append(ContextMenuAction(title: "Edit Array…", action: { [self] in startEditArray(anchor: arrayHit) }))
            items.append(.separator)
        }
        // ADDVERTEX: "Add Vertex" — offered when the right-click landed on
        // an edge of the single selected polyline, mirroring the
        // double-click gesture in `handleFinishGesture` (same underlying
        // `GripEditing.nearestEdge`/`addVertex` call, just a menu entry
        // instead of a double-click for users who prefer/discover the
        // context menu first).
        if gripEditingEligible, let regen, let id = selection.first {
            let world = viewPoint.applying(worldToView().inverted())
            let tolerance = 6 / max(zoom, 1e-12)
            if let edge = GripEditing.nearestEdge(of: id, in: regen.parsed.store, to: world, tolerance: tolerance) {
                items.append(ContextMenuAction(title: "Add Vertex", action: { [self] in
                    session.performEdit("Add Vertex") { tx in
                        GripEditing.addVertex(id, afterIndex: edge.afterIndex, at: edge.point, in: tx)
                    }
                }))
                items.append(.separator)
            }
        }
        if !selection.isEmpty {
            items.append(ContextMenuAction(title: "Move", action: { [self] in startMove() }))
            items.append(ContextMenuAction(title: "Duplicate", action: { [self] in startModify(.copy) }))
            items.append(ContextMenuAction(title: "Rotate", action: { [self] in startModify(.rotate) }))
            items.append(ContextMenuAction(title: "Scale", action: { [self] in startModify(.scale) }))
            items.append(ContextMenuAction(title: "Mirror", action: { [self] in startModify(.mirror) }))
            items.append(ContextMenuAction(title: "Trim (selection = cutting edges)", action: { [self] in startTrimExtend(.trim) }))
            items.append(ContextMenuAction(title: "Extend (selection = boundary edges)", action: { [self] in startTrimExtend(.extend) }))
            items.append(ContextMenuAction(title: "Stretch", action: { [self] in startStretch() }))
            items.append(ContextMenuAction(title: "Join", action: { [self] in startJoin() }))
            items.append(ContextMenuAction(title: "Explode", action: { [self] in startExplode() }))
            items.append(ContextMenuAction(title: "Block", action: { [self] in startBlock() }))
            items.append(ContextMenuAction(title: "Array…", action: { [self] in startArray() }))
            // "Delete" — removes the selected object(s) from the drawing.
            // Works for ANY selected entity (original geometry or markup)
            // via `deleteSelection()`; the deletion is an in-memory,
            // undoable, round-trip-safe tombstone (see that function's doc
            // comment). Previously this was gated on `!selectedMarkupIDs
            // .isEmpty`, so it never appeared for original drawing objects
            // — now always offered whenever something is selected.
            items.append(ContextMenuAction(title: "Delete", action: { [self] in deleteSelection() }))
            items.append(ContextMenuAction(title: "Deselect", action: { [self] in selection = [] }))
            // "Hide Xref" — toggle off every xref referenced by the selection.
            if let doc = document, !selectionRefs.isEmpty {
                let groups = space == .paper ? doc.paperGroups : doc.modelGroups
                var sourceKeys: Set<String> = []
                for ref in selectionRefs {
                    guard case .primitive(let gi, _, _) = ref, Int(gi) < groups.count else { continue }
                    let xid = groups[Int(gi)].xrefId
                    if xid >= 0, let xref = doc.xrefs.first(where: { $0.id == xid }) {
                        sourceKeys.insert(xref.sourceDrawingKey)
                    }
                }
                for key in sourceKeys.sorted() where !key.isEmpty {
                    let name = doc.xrefs.first { $0.sourceDrawingKey == key }?.blockName ?? key
                    items.append(ContextMenuAction(title: "Hide “\(name)”", action: { [self] in
                        guard let doc = self.document else { return }
                        let ids = doc.xrefs.xrefIdsSharingSource(with:
                            doc.xrefs.first { $0.sourceDrawingKey == key }!)
                        self.visibility.hiddenXrefIds.formUnion(ids)
                    }))
                }
            }
            items.append(.separator)
        }
        items.append(ContextMenuAction(title: "Select mode", action: { [self] in setTool(select: true) }))
        items.append(.separator)
        items.append(ContextMenuAction(title: "Line", action: { [self] in setDraft(.line) }))
        items.append(ContextMenuAction(title: "Polyline", action: { [self] in setDraft(.polyline) }))
        items.append(ContextMenuAction(title: "Circle", action: { [self] in setDraft(.circle) }))
        items.append(ContextMenuAction(title: "Rectangle", action: { [self] in setDraft(.rect) }))
        items.append(ContextMenuAction(title: "Text Note", action: { [self] in setDraft(.text) }))
        items.append(.separator)
        items.append(ContextMenuAction(title: "Trim", action: { [self] in startTrimExtend(.trim) }))
        items.append(ContextMenuAction(title: "Extend", action: { [self] in startTrimExtend(.extend) }))
        items.append(ContextMenuAction(title: "Fillet", action: { [self] in startFilletChamfer(.fillet) }))
        items.append(ContextMenuAction(title: "Chamfer", action: { [self] in startFilletChamfer(.chamfer) }))
        items.append(ContextMenuAction(title: "Offset", action: { [self] in startOffset() }))
        items.append(.separator)
        items.append(ContextMenuAction(title: "Measure Distance", action: { [self] in setMeasure(.distance) }))
        items.append(ContextMenuAction(title: "Measure Area", action: { [self] in setMeasure(.area) }))
        items.append(ContextMenuAction(title: "Dimension (Aligned)", action: { [self] in startDimensionTool(kind: .aligned) }))
        items.append(ContextMenuAction(title: "Dimension (Linear)", action: { [self] in startDimensionTool(kind: .linear) }))
        items.append(.separator)
        items.append(ContextMenuAction(title: "Zoom Fit", action: { [self] in fitButtonPressed() }))
        items.append(ContextMenuAction(title: "Undo", action: { [self] in undoLast() }))
        return items
    }

    // MARK: - Markup/entity editing (select mode)
    //
    // The old drag-to-move gesture (mouse-down on markup, drag, mouse-up)
    // was markup-only special-casing that mutated `drawn` in place with no
    // undo step of its own — retired per the plan ("markup-drag special
    // path" deletion). The Move COMMAND (M key / toolbar / menu — pick base
    // point, pick destination point, both OSNAP-snappable) is a real,
    // separate, tested feature (see git history: "Add Move tool with OSNAP,
    // box-select...") and is fully preserved below, just retargeted to
    // `Transaction.modifyPayload` on real `EntityID`s so it now works on ANY
    // selected entity, not just markup.

    /// Starts the two-click MOVE gesture on the current selection (markup or
    /// original drawing geometry — both are ordinary EntityStore content).
    private func startMove() {
        guard !selection.isEmpty else {
            commandMessage = "Select something to move first"
            return
        }
        draft = DraftState()
        measure = MeasureState()
        cancelModify()
        cancelTrimExtend()
        cancelFilletChamfer()
        cancelOffset()
        cancelBlock()
        cancelExplode()
        cancelJoin()
        cancelArray()
        cancelOneShotAttributeFlags()
        moveState = MoveState(phase: .pickingBase, objectIDs: selection)
        commandMessage = ""
    }

    /// Feeds one point (click or typed coordinate) into the active MOVE
    /// gesture: first call sets the base point, second commits the
    /// translation (one "Move" transaction covering every selected entity)
    /// so the base point lands exactly on this point.
    private func commitMovePoint(_ p: CGPoint) {
        switch moveState.phase {
        case .idle:
            break
        case .pickingBase:
            moveState.basePoint = p
            moveState.phase = .pickingDestination
            commandMessage = "MOVE — specify destination point"
        case .pickingDestination:
            guard let base = moveState.basePoint else { moveState = MoveState(); return }
            let dx = Double(p.x - base.x), dy = Double(p.y - base.y)
            let ids = moveState.objectIDs
            session.performEdit("Move") { tx in
                for id in ids {
                    tx.modifyPayload(id) { copy in copy.translate(dx: dx, dy: dy) }
                }
            }
            commandMessage = "Moved \(ids.count) object(s)"
            moveState = MoveState()
        }
    }

    /// Live dashed preview of the selection at the candidate destination,
    /// shown while picking the second (destination) point. Reconstructed as
    /// `[DrawnEntity]` purely for the screen-space ghost overlay (which
    /// stays lightweight/transient — nothing here touches the store).
    /// Entity kinds `DrawnEntity.Shape` can't represent (e.g. a spline, or
    /// block-content the selection resolved to `.insert`) are simply
    /// omitted from the ghost preview; the actual move still applies to
    /// them correctly via `commitMovePoint`'s `EntityID`-based transaction.
    private var moveGhostEntities: [DrawnEntity] {
        guard moveState.phase == .pickingDestination, let regen, let base = moveState.basePoint,
              let dest = moveState.snap?.point ?? moveState.hover else { return [] }
        let d = CGVector(dx: dest.x - base.x, dy: dest.y - base.y)
        let store = regen.parsed.store
        var result: [DrawnEntity] = []
        for id in moveState.objectIDs {
            guard let h = store.header(id), !h.flags.contains(.deleted) else { continue }
            guard let shape = ghostShape(for: id, store: store) else { continue }
            var e = DrawnEntity(shape: shape)
            e.aci = h.aci == 256 ? 7 : Int(h.aci)
            e.isPaper = h.owner.isPaper
            result.append(e.translated(by: d))
        }
        return result
    }

    /// Best-effort `DrawnEntity.Shape` for entity `id`'s CURRENT geometry —
    /// used only to build the Move ghost preview above. Reuses
    /// `MarkupStore`'s reader logic (which already knows how to read back
    /// line/polyline/circle/arc/text) regardless of which layer the entity
    /// is actually on — the move ghost isn't markup-specific, it just
    /// happens to reuse the same reconstruction code.
    private func ghostShape(for id: EntityID, store: EntityStore) -> DrawnEntity.Shape? {
        MarkupStore.shapeForGhost(id: id, store: store)
    }

    // MARK: - Grip editing (direct-manipulation reshape)
    //
    // Unlike every command above (Move/Copy/Trim/.../Array), grip editing is
    // NOT a typed/toolbar-invoked command — it's always-on in plain select
    // mode whenever exactly ONE grip-editable entity is selected, matching
    // AutoCAD's own "grips just appear" behavior. See `GripEditing.swift`'s
    // header comment for the underlying data model and `GripDragState.swift`
    // for why this needed its own tool-state type rather than reusing
    // `MoveState`.

    /// True while grip display/interaction should even be considered — ANY
    /// other modal tool active (or a non-single-entity/non-grip-editable
    /// selection) suppresses grips entirely, mirroring
    /// `contextMenuItems(at:)`'s own "is some other command running" guard
    /// list (reused verbatim here rather than duplicated ad hoc, since a
    /// grip drag beginning while e.g. TRIM/EXTEND is mid-acquisition would
    /// be exactly the same class of cross-tool interaction bug that guard
    /// list already exists to prevent for right-click).
    private var gripEditingEligible: Bool {
        guard let regen, selection.count == 1, let id = selection.first else { return false }
        guard !(moveState.isActive || modifyState.isActive || trimExtendState.isActive
                || filletChamferState.isActive || offsetState.isActive || dimensionToolState.isActive
                || blockToolState.isActive || arrayToolState.isActive || draft.isActive || measure.isActive
                || awaitingAttEditPick || awaitingAttdefPlacement || explodeAwaitingSelection
                || joinAwaitingSelection
                || xrefAttachToolState.isActive || clipboardPasteToolState.isActive
                || stretchState.isActive) else { return false }
        let store = regen.parsed.store
        guard let h = store.header(id), !h.flags.contains(.deleted) else { return false }
        return GripEditing.isGripEditable(h.type)
    }

    /// The single selected entity's grips (world space) — feeds
    /// `DXFCanvasView.gripPoints` for both rendering and (via
    /// `handleGripMouseDown`) hit-testing. Empty whenever
    /// `gripEditingEligible` is false, which the canvas's own `guard
    /// !gripPoints.isEmpty` in `drawGripsOverlay` already treats as "don't
    /// draw anything."
    private var gripDisplayPoints: [GripEditing.GripPoint] {
        guard gripEditingEligible, let regen, let id = selection.first else { return [] }
        return GripEditing.grips(for: id, in: regen.parsed.store)
    }

    /// Live dashed ghost of the entity being grip-dragged, recomputed every
    /// hover tick from `gripDragState.hover`/`.snap` — same "ContentView
    /// precomputes geometry, DXFCanvasView just draws it" split as
    /// `moveGhostEntities` above.
    private var gripDragGhostShape: DrawnEntity.Shape? {
        guard gripDragState.phase == .dragging, let regen,
              let id = gripDragState.entityId, let index = gripDragState.gripIndex,
              let candidate = gripDragState.snap?.point ?? gripDragState.hover else { return nil }
        return GripEditing.previewShape(for: id, in: regen.parsed.store, gripIndex: index,
                                        candidatePosition: candidate)
    }

    /// `DXFCanvasView.onGripMouseDown` — a mouse-down at `viewLocation`
    /// (already screen/view space; converted to world here, matching every
    /// other click handler's own convention) begins a grip drag if it
    /// landed on a grip, returning true so `InputView.mouseDown` latches
    /// `gripDragActive` and routes subsequent drag/up events here instead
    /// of the box-select machinery.
    private func handleGripMouseDown(at viewLocation: CGPoint) -> Bool {
        guard gripEditingEligible, let regen, let id = selection.first else { return false }
        let world = viewLocation.applying(worldToView().inverted())
        let tolerance = 8 / max(zoom, 1e-12)
        guard let hit = GripEditing.nearestGrip(candidateIds: [id], in: regen.parsed.store,
                                                to: world, tolerance: tolerance) else { return false }
        gripDragState.phase = .dragging
        gripDragState.entityId = hit.entityId
        gripDragState.gripIndex = hit.gripIndex
        gripDragState.hover = hit.position
        gripDragState.snap = nil
        commandMessage = gripDragState.prompt
        return true
    }

    /// `DXFCanvasView.onGripDrag` — live drag tick: updates the candidate
    /// position (OSNAP-eligible, same as every other point-picking tool)
    /// that `gripDragGhostShape` previews and `handleGripMouseUp` commits.
    private func handleGripDrag(at viewLocation: CGPoint) {
        guard gripDragState.phase == .dragging, let doc = document else { return }
        let world = viewLocation.applying(worldToView().inverted())
        gripDragState.hover = world
        let tol = 9 / max(zoom, 1e-12)
        // Exclude the entity being reshaped from its own snap candidates —
        // same "don't snap back onto the pre-transform source geometry"
        // rationale as Move's own `excluding:` (see `handleHover`'s Move
        // branch's doc comment for the full history of that bug class).
        let excluding: Set<EntityID> = gripDragState.entityId.map { [$0] } ?? []
        gripDragState.snap = Osnap.snap(document: doc, usePaperSpace: space == .paper,
            near: world, tolerance: tol, visibility: visibility, from: nil, excluding: excluding)
    }

    /// `DXFCanvasView.onGripDragEnd` — commits the reshape via
    /// `GripEditing.moveGrip` (one undoable transaction) and resets to idle.
    private func handleGripMouseUp(at viewLocation: CGPoint) {
        guard gripDragState.phase == .dragging, let id = gripDragState.entityId,
              let index = gripDragState.gripIndex else { gripDragState = GripDragState(); return }
        let world = viewLocation.applying(worldToView().inverted())
        let dest = gripDragState.snap?.point ?? gripDragState.hover ?? world
        session.performEdit("Drag grip") { tx in
            GripEditing.moveGrip(id, index: index, to: dest, in: tx)
        }
        gripDragState = GripDragState()
        commandMessage = ""
    }

    // MARK: - COPY/ROTATE/SCALE/MIRROR (Phase 4.2 — ModifyToolState)
    //
    // Verb-first (toolbar/menu/context-menu/typed command with an EMPTY
    // selection) drives through `SelectionPrompt` (`.selecting` phase);
    // noun-verb (PICKFIRST — a non-empty selection already exists when the
    // command is invoked) skips straight to the first geometric-parameter
    // phase, exactly matching `startMove`'s existing guard/skip shape.

    /// Starts a COPY/ROTATE/SCALE/MIRROR command. PICKFIRST: if `selection`
    /// is already non-empty, acquisition is skipped entirely (matches
    /// `startMove`'s existing noun-verb behavior — this is deliberately NOT
    /// gated behind a "selection empty" guard-and-bail the way `startMove`
    /// is, since verb-first with an empty selection is a NORMAL, supported
    /// entry point for these 4 commands, unlike Move which has never
    /// supported an interactive Select-objects: prompt of its own).
    private func startModify(_ command: ModifyCommand) {
        draft = DraftState()
        measure = MeasureState()
        moveState = MoveState()
        trimExtendState = TrimExtendToolState(command: .trim)
        cancelFilletChamfer()
        cancelOffset()
        cancelBlock()
        cancelExplode()
        cancelJoin()
        cancelArray()
        cancelOneShotAttributeFlags()
        modifyState = ModifyToolState.begin(command, preselection: selection)
        if modifyState.phase == .selecting {
            selectionPrompt = makeSelectionPrompt(preselected: [])
            commandMessage = ""
        } else {
            selectionPrompt = nil
            commandMessage = ""
        }
    }

    /// Builds a `SelectionPrompt` wired to this session's live document —
    /// shared by every modify command's `.selecting` phase (and reusable by
    /// a future TRIM/EXTEND/etc. without change).
    private func makeSelectionPrompt(preselected: Set<EntityID>) -> SelectionPrompt? {
        guard document != nil else { return nil }
        // Capture `session` weakly (not `regen`/`visibility`/`space`, which
        // are COMPUTED properties on ContentView — `[weak regen]` would
        // capture nothing meaningful) — every provider re-reads
        // `session?.regen`/`.visibility`/`.space` FRESH on each call, so a
        // layer visibility toggle or space switch mid-acquisition is
        // reflected immediately, exactly like a plain single click already
        // does via ContentView's own live `visibility` reads. An earlier
        // draft of this function captured `visibility`/`space` ONCE at
        // prompt-construction time, which meant toggling a layer's
        // visibility while "Select objects:" was active silently used a
        // stale snapshot for W/C/F/ALL/lasso/fence acquisitions while a
        // plain click used the current value — caught by adversarial
        // review, fixed here by making every provider read live state the
        // same way `regen` already correctly did.
        return SelectionPrompt(
            preselected: preselected,
            pickAddIsZero: false,   // PICKADD sysvar plumbing exists (SysVars.swift) but isn't read live yet; default matches AutoCAD's factory default (1)
            allSelectable: { [weak session] in
                guard let session, let regen = session.regen else { return [] }
                let usePaper = session.space == .paper
                let full = usePaper ? regen.document.paperBounds : regen.document.modelBounds
                return SelectionEngine.rectSelect(document: regen.document, usePaperSpace: usePaper,
                                                  rect: full.insetBy(dx: -1, dy: -1), mode: .crossing,
                                                  visibility: session.visibility)
            },
            previousSelection: { [weak session] in session?.previousSelection ?? [] },
            lastCreated: { [weak session] in session?.lastCreatedEntities ?? [] },
            rectSelect: { [weak session] rect, mode in
                guard let session, let regen = session.regen else { return [] }
                return SelectionEngine.rectSelect(document: regen.document, usePaperSpace: session.space == .paper,
                                                  rect: rect, mode: mode, visibility: session.visibility)
            },
            lassoSelect: { [weak session] polygon, mode in
                guard let session, let regen = session.regen else { return [] }
                return SelectionEngine.lassoSelect(document: regen.document, usePaperSpace: session.space == .paper,
                                                   polygon: polygon, mode: mode, visibility: session.visibility)
            },
            fenceSelect: { [weak session] polyline in
                guard let session, let regen = session.regen else { return [] }
                return SelectionEngine.fenceSelect(document: regen.document, usePaperSpace: session.space == .paper,
                                                   fence: polyline, visibility: session.visibility)
            })
    }

    /// Routes one click into the active modify command: while `.selecting`,
    /// feeds `SelectionPrompt`; otherwise feeds the current geometric
    /// parameter phase (base/angle/factor/mirror-end/destination point).
    /// Called from `handleClick` — see that function's `modifyState.isActive`
    /// branch.
    private func handleModifyClick(hit: EntityID?, worldPoint: CGPoint, shiftDown: Bool) {
        if modifyState.phase == .selecting {
            guard var prompt = selectionPrompt else { return }
            let result = prompt.handle(.pick(hit, worldPoint: worldPoint, shiftHeld: shiftDown))
            selectionPrompt = prompt
            applySelectionPromptResult(result)
            return
        }
        commitModifyGeometryPoint(modifyState.snap?.point ?? worldPoint)
    }

    /// Feeds one point (click or typed coordinate) into the active modify
    /// command's CURRENT geometric-parameter phase, advancing to the next
    /// phase or committing the transaction, exactly mirroring
    /// `commitMovePoint`'s shape.
    private func commitModifyGeometryPoint(_ p: CGPoint) {
        switch modifyState.phase {
        case .idle, .selecting, .confirmEraseSource:
            break

        case .pickBase:
            modifyState.basePoint = p
            switch modifyState.command {
            case .rotate: modifyState.phase = .pickAngle
            case .scale: modifyState.phase = .pickFactor
            case .mirror: modifyState.phase = .pickMirrorEnd
            case .copy: modifyState.phase = .pickDestination
            case .move: break   // unreachable — MOVE never constructs a ModifyToolState
            }
            commandMessage = modifyState.prompt

        case .pickAngle:
            guard let base = modifyState.basePoint else { modifyState = ModifyToolState(command: modifyState.command); return }
            let angle = atan2(Double(p.y - base.y), Double(p.x - base.x))
            commitModifyTransform(.rotation(about: Vec2(base), angleRad: angle))

        case .pickFactor:
            guard let base = modifyState.basePoint else { modifyState = ModifyToolState(command: modifyState.command); return }
            let factor = Double(hypot(p.x - base.x, p.y - base.y))
            guard factor > 1e-9 else { return }   // degenerate zero-distance pick — ignore, stay in .pickFactor
            commitModifyTransform(.scaling(about: Vec2(base), factor: factor))

        case .pickMirrorEnd:
            guard let base = modifyState.basePoint else { modifyState = ModifyToolState(command: modifyState.command); return }
            guard hypot(p.x - base.x, p.y - base.y) > 1e-9 else { return }   // degenerate zero-length mirror line — ignore
            commitModifyTransform(.mirror(across: Vec2(base), Vec2(p)))

        case .pickDestination:
            guard modifyState.command == .copy, let base = modifyState.basePoint else { return }
            let dx = Double(p.x - base.x), dy = Double(p.y - base.y)
            let ids = modifyState.objectIDs
            let mirrtext = sysVars.bool("MIRRTEXT")
            var newIds: [EntityID] = []
            session.performEdit("Copy") { tx in
                for id in ids {
                    if let newId = tx.copyTransformed(id, by: .translation(dx: dx, dy: dy), mirrtext: mirrtext) {
                        newIds.append(newId)
                    }
                }
            }
            session.lastCreatedEntities = Set(newIds)
            commandMessage = "Copied \(newIds.count) object(s) — specify next destination (Enter/Esc to finish)"
            // COPY loops: stay in .pickDestination (AutoCAD's default
            // multi-copy behavior) until the user presses Enter/Esc. Each
            // placement is independently offset from the SAME original
            // base point (not chained from the previous destination) —
            // `modifyState.basePoint` is deliberately left unchanged here.
        }
    }

    /// Applies `t` to every object in the active modify command's selection
    /// as ONE transaction, then resets to idle (ROTATE/SCALE/MIRROR all
    /// commit immediately on their final point — unlike COPY, which loops).
    private func commitModifyTransform(_ t: Transform2) {
        let ids = modifyState.objectIDs
        let command = modifyState.command
        let mirrtext = sysVars.bool("MIRRTEXT")
        session.performEdit(command.displayName) { tx in
            for id in ids { tx.transform(id, by: t, mirrtext: mirrtext) }
        }
        commandMessage = "\(command.displayName) — \(ids.count) object(s)"
        session.previousSelection = ids
        modifyState = ModifyToolState(command: command)
    }

    /// Cancels the active modify command entirely, discarding any
    /// accumulated selection/geometric progress — matches `handleEscape`'s
    /// existing unconditional-reset convention for Move.
    private func cancelModify() {
        modifyState = ModifyToolState(command: modifyState.command)
        selectionPrompt = nil
        commandMessage = ""
    }

    /// Finishes COPY's multi-placement loop (Enter with no further
    /// destination pick) — the only modify command with a phase that can be
    /// "finished" rather than always auto-completing on its final point.
    private func finishModifyDestinationLoop() {
        guard modifyState.phase == .pickDestination else { return }
        // "P" (Previous) support: matches commitModifyTransform's identical
        // assignment for ROTATE/SCALE/MIRROR — "Previous" means the SOURCE
        // objects the command acted on, not what it created (that's "L"/
        // Last, already tracked via session.lastCreatedEntities at each
        // placement). A prior draft only set this in commitModifyTransform,
        // so "P" after a COPY silently returned a stale pre-COPY selection
        // instead of what was just copied — caught by adversarial review.
        session.previousSelection = modifyState.objectIDs
        commandMessage = "Copy finished"
        modifyState = ModifyToolState(command: .copy)
    }

    /// The provisional `Transform2` implied by the modify command's current
    /// state + live cursor — used for both the ghost preview and (if the
    /// user clicks now) the actual commit, so the two are always in exact
    /// agreement. `nil` when there isn't enough information yet (e.g. still
    /// picking the base point).
    private var modifyProvisionalTransform: Transform2? {
        guard let base = modifyState.basePoint,
              let cursor = modifyState.snap?.point ?? modifyState.hover else { return nil }
        switch modifyState.phase {
        case .pickAngle:
            let angle = atan2(Double(cursor.y - base.y), Double(cursor.x - base.x))
            return .rotation(about: Vec2(base), angleRad: angle)
        case .pickFactor:
            let factor = Double(hypot(cursor.x - base.x, cursor.y - base.y))
            guard factor > 1e-9 else { return nil }
            return .scaling(about: Vec2(base), factor: factor)
        case .pickMirrorEnd:
            guard hypot(cursor.x - base.x, cursor.y - base.y) > 1e-9 else { return nil }
            return .mirror(across: Vec2(base), Vec2(cursor))
        case .pickDestination:
            return .translation(dx: Double(cursor.x - base.x), dy: Double(cursor.y - base.y))
        default:
            return nil
        }
    }

    /// Live ghost preview for COPY/ROTATE/SCALE/MIRROR — same shape/role as
    /// `moveGhostEntities`, generalized to an arbitrary `Transform2` via
    /// `DrawnEntity.transformed(by:)`. MIRROR's ghost additionally shows the
    /// mirror LINE itself (drawn separately by `DXFCanvasView`, not part of
    /// this entity list) — see `modifyMirrorLine` below.
    private var modifyGhostEntities: [DrawnEntity] {
        guard let t = modifyProvisionalTransform, let regen else { return [] }
        let store = regen.parsed.store
        var result: [DrawnEntity] = []
        for id in modifyState.objectIDs {
            guard let h = store.header(id), !h.flags.contains(.deleted) else { continue }
            guard let shape = ghostShape(for: id, store: store) else { continue }
            var e = DrawnEntity(shape: shape)
            e.aci = h.aci == 256 ? 7 : Int(h.aci)
            e.isPaper = h.owner.isPaper
            result.append(e.transformed(by: t))
        }
        return result
    }

    /// The mirror line's two endpoints, while `modifyState.command == .mirror`
    /// and at least the first point is known — `DXFCanvasView` draws this as
    /// a distinct dashed reference line (not part of `modifyGhostEntities`,
    /// which only ever holds TRANSFORMED copies of the selection).
    private var modifyMirrorLine: (CGPoint, CGPoint)? {
        guard modifyState.command == .mirror, let base = modifyState.basePoint else { return nil }
        guard let end = modifyState.phase == .pickMirrorEnd
            ? (modifyState.snap?.point ?? modifyState.hover) : modifyState.mirrorEndPoint else { return nil }
        return (base, end)
    }

    // MARK: - TRIM/EXTEND (Phase 4.3 — TrimExtendToolState)
    //
    // Boundary acquisition reuses `SelectionPrompt` exactly like COPY/ROTATE/
    // SCALE/MIRROR's object acquisition (`makeSelectionPrompt`); the
    // per-target click loop that follows is new (see `TrimExtendToolState`'s
    // header comment for why it isn't folded into `ModifyToolState`). Every
    // click independently resolves boundaries (lazily, per-target, if the
    // user pressed Enter for "all visible") and commits its own
    // `performEdit` — there is no multi-click "gesture in progress" the way
    // ROTATE/SCALE/MIRROR have, so there's no provisional-transform/ghost
    // preview of the SAME kind; the hover highlight below is a lighter-
    // weight "here's what would happen if you clicked now" preview instead.

    /// PICKFIRST here means something different from COPY/ROTATE/SCALE/
    /// MIRROR's own PICKFIRST: a non-empty AMBIENT `selection` at invocation
    /// becomes the CUTTING-EDGE/boundary set (matching real AutoCAD — pre-
    /// selecting objects, then typing TRIM, uses that selection as the
    /// cutting edges, not as the things to be trimmed) — targets are always
    /// individually click-picked afterward regardless, so PICKFIRST only
    /// ever skips the BOUNDARY-acquisition prompt, never the whole command.
    private func startTrimExtend(_ command: TrimExtendCommand) {
        draft = DraftState()
        measure = MeasureState()
        moveState = MoveState()
        modifyState = ModifyToolState(command: .copy)
        cancelFilletChamfer()
        cancelOffset()
        cancelBlock()
        cancelExplode()
        cancelJoin()
        cancelArray()
        cancelOneShotAttributeFlags()
        trimExtendState = TrimExtendToolState.begin(command)
        if !selection.isEmpty {
            trimExtendState.withAcquiredBoundaries(selection)
            selectionPrompt = nil
        } else {
            selectionPrompt = makeSelectionPrompt(preselected: [])
        }
        commandMessage = trimExtendState.prompt
    }

    /// Bare Enter while `.selectingBoundaries` — "all visible, extended" per
    /// AutoCAD (a legitimate, meaningful action, unlike every ModifyToolState
    /// command's empty-selection case).
    private func finishTrimExtendBoundaryPrompt() {
        trimExtendState.withAcquiredBoundaries(nil)
        selectionPrompt = nil
        commandMessage = trimExtendState.prompt
    }

    /// Bare Enter while `.pickingTargets` — finishes the whole command.
    private func finishTrimExtendTargetLoop() {
        commandMessage = "\(trimExtendState.command.displayName) finished"
        trimExtendState = TrimExtendToolState(command: trimExtendState.command)
    }

    private func cancelTrimExtend() {
        trimExtendState = TrimExtendToolState(command: trimExtendState.command)
        selectionPrompt = nil
        commandMessage = ""
    }

    /// Routes one click into the active TRIM/EXTEND command: while
    /// `.selectingBoundaries`, feeds `SelectionPrompt` (identical to
    /// `handleModifyClick`'s own `.selecting` branch); while
    /// `.pickingTargets`, resolves the click to a target entity and
    /// immediately trims/extends + commits it. Called from `handleClick`.
    private func handleTrimExtendClick(hit: EntityID?, worldPoint: CGPoint, shiftDown: Bool) {
        if trimExtendState.phase == .selectingBoundaries {
            guard var prompt = selectionPrompt else { return }
            let result = prompt.handle(.pick(hit, worldPoint: worldPoint, shiftHeld: shiftDown))
            selectionPrompt = prompt
            applyTrimExtendBoundaryPromptResult(result)
            return
        }
        guard trimExtendState.phase == .pickingTargets else { return }
        guard let targetId = hit else { return }   // clicking empty space is a no-op, matching SelectionPrompt's own convention
        commitTrimExtendClick(targetId: targetId, worldPoint: worldPoint, shiftToggles: shiftDown)
    }

    /// Mirrors `applySelectionPromptResult`'s shape but transitions
    /// `trimExtendState` instead of `modifyState` on `.done`.
    private func applyTrimExtendBoundaryPromptResult(_ result: SelectionPromptResult) {
        switch result {
        case .pending:
            commandMessage = selectionPrompt?.promptText ?? ""
        case .done(let ids):
            trimExtendState.withAcquiredBoundaries(ids)
            selectionPrompt = nil
            commandMessage = trimExtendState.prompt
        case .cancelled:
            cancelTrimExtend()
        }
    }

    /// Performs one TRIM or EXTEND click and commits it as its own
    /// transaction (AutoCAD: every click at "Select object to trim/extend:"
    /// is independent — there is no shared multi-object batch the way
    /// ROTATE/SCALE/MIRROR's selection is). `shiftToggles`: Shift held on
    /// this click flips the effective command for JUST this click (Trim
    /// mode's Shift+click extends, and vice versa), per the plan's spec.
    private func commitTrimExtendClick(targetId: EntityID, worldPoint: CGPoint, shiftToggles: Bool) {
        guard let regen else { return }
        let store = regen.parsed.store
        let tol = trimExtendTolerance
        let effectiveCommand: TrimExtendCommand = shiftToggles
            ? (trimExtendState.command == .trim ? .extend : .trim)
            : trimExtendState.command
        let extendBoundaries = sysVars.int("EDGEMODE") == 1

        guard let resolution = TrimExtendExecutor.resolveClick(targetId: targetId, clickWorld: worldPoint, store: store, tol: tol) else {
            commandMessage = "\(effectiveCommand.displayName) — that object has no editable geometry"
            return
        }
        let boundaries = TrimExtendExecutor.boundaryCurves(
            for: targetId, state: trimExtendState, explicitBoundaryCurves: trimExtendExplicitBoundaryCurves,
            document: regen.document, usePaperSpace: space == .paper, store: store, visibility: visibility)

        let outcome = effectiveCommand == .trim
            ? TrimExtendExecutor.trimAtClick(resolution, boundaries: boundaries, extendBoundaries: extendBoundaries, store: store, tol: tol)
            : TrimExtendExecutor.extendAtClick(resolution, boundaries: boundaries, extendBoundaries: extendBoundaries, store: store, tol: tol)

        guard let outcome else {
            commandMessage = "\(effectiveCommand.displayName) — that object cannot be \(effectiveCommand == .trim ? "trimmed" : "extended")"
            return
        }
        var applied = false
        session.performEdit(effectiveCommand.displayName) { tx in
            applied = TrimExtendExecutor.apply(outcome, to: tx)
        }
        commandMessage = applied
            ? "\(effectiveCommand.displayName) — 1 object"
            : "\(effectiveCommand.displayName) — edge(s) do not intersect that object"
    }

    /// A fence drag (Option+drag while `.pickingTargets`, TRIM only — see
    /// `TrimExtendExecutor.trimFenceBatch`'s doc comment for why EXTEND
    /// doesn't support fence batching) — trims every crossed entity at the
    /// fence's own indicated crossing point, ALL as one undo step (matching
    /// how a window/crossing SELECTION is one undo step, not one per
    /// object — see `SelectionPrompt.applyAcquisition`'s identical
    /// rationale). `fenceWorld` is already in WORLD coordinates (converted
    /// by the caller, `handleLassoSelect`, exactly like every other
    /// gesture-completion handler in this file receives world points).
    private func handleTrimExtendFenceDrag(_ fenceWorld: [CGPoint]) {
        guard trimExtendState.phase == .pickingTargets, trimExtendState.command == .trim, let regen else { return }
        let store = regen.parsed.store
        let tol = trimExtendTolerance
        let extendBoundaries = sysVars.int("EDGEMODE") == 1
        let outcomes = TrimExtendExecutor.trimFenceBatch(
            fencePoints: fenceWorld, boundaryState: trimExtendState, explicitBoundaryCurves: trimExtendExplicitBoundaryCurves,
            document: regen.document, usePaperSpace: space == .paper, store: store, visibility: visibility, tol: tol,
            extendBoundaries: extendBoundaries)
        guard !outcomes.isEmpty else {
            commandMessage = "Trim — no objects crossed the fence"
            return
        }
        var appliedCount = 0
        session.performEdit("Trim (fence)") { tx in
            for outcome in outcomes where TrimExtendExecutor.apply(outcome, to: tx) { appliedCount += 1 }
        }
        commandMessage = "Trim — \(appliedCount) object(s)"
    }

    /// Explicit boundary curves, bridged ONCE per command invocation (not
    /// per click/fence-batch-entity) when the user picked specific cutting
    /// edges rather than pressing Enter for "all visible" — cached as a
    /// computed property (re-bridged on each access) since `trimExtendState`
    /// only changes at acquisition time and this is only ever called from
    /// user-gesture handlers, never a hot per-frame path.
    private var trimExtendExplicitBoundaryCurves: [Curve2] {
        guard let regen, !trimExtendState.usedAllVisible else { return [] }
        return TrimExtendExecutor.resolveExplicitBoundaryCurves(trimExtendState.boundaryIDs, store: regen.parsed.store)
    }

    /// World-unit tolerance for TRIM/EXTEND's geometry (closest-point/
    /// intersection) queries, derived from the document's own extents —
    /// matches `Tolerance.forExtents(diagonal:)`'s intended use (never a
    /// hardcoded epsilon that would be wrong at a very different drawing
    /// scale).
    private var trimExtendTolerance: Tolerance {
        guard let doc = document else { return Tolerance(linear: 1e-6) }
        let bounds = space == .paper ? doc.paperBounds : doc.modelBounds
        let diag = hypot(bounds.width, bounds.height)
        return Tolerance.forExtents(diagonal: Double(diag))
    }

    // MARK: - STRETCH (new feature — StretchToolState)
    //
    // Crossing-window vertex acquisition (unlike every command above, which
    // acquires WHOLE entities via `SelectionPrompt`), then a base/destination
    // point pair (same shape as MOVE's own two-click gesture), committing
    // via `GripEditing.applyStretch` — see `StretchToolState.swift`'s header
    // comment for the full design rationale.

    /// Starts STRETCH. PICKFIRST: an already-non-empty `selection` is
    /// treated as "every grip of every selected entity is caught" (matches
    /// AutoCAD's own PICKFIRST-for-STRETCH behavior: a pre-existing
    /// selection stretches as if each object had been individually crossed
    /// in its entirety) — this mirrors `startTrimExtend`'s own PICKFIRST
    /// skip-acquisition shape.
    private func startStretch() {
        draft = DraftState()
        measure = MeasureState()
        moveState = MoveState()
        modifyState = ModifyToolState(command: .copy)
        cancelTrimExtend()
        cancelFilletChamfer()
        cancelOffset()
        cancelBlock()
        cancelExplode()
        cancelJoin()
        cancelArray()
        cancelOneShotAttributeFlags()
        stretchState = StretchToolState()
        guard let regen else { return }
        if !selection.isEmpty {
            var caught: [GripEditing.CaughtGrip] = []
            for id in selection {
                caught.append(contentsOf: GripEditing.grips(for: id, in: regen.parsed.store)
                    .map { GripEditing.CaughtGrip(entityId: id, gripIndex: $0.index, position: $0.position) })
            }
            stretchState.addCaught(caught)
            stretchState.phase = .pickingBase
            selectionPrompt = nil
        } else {
            stretchState.phase = .selecting
            selectionPrompt = nil
        }
        commandMessage = stretchState.prompt
    }

    private func cancelStretch() {
        stretchState = StretchToolState()
        commandMessage = ""
    }

    /// Bare Enter while `.selecting` — finishes acquisition (empty is a
    /// legitimate abort, matching every other command's "Enter/click empty
    /// with nothing caught cancels" convention rather than committing a
    /// no-op stretch).
    private func finishStretchSelectionPrompt() {
        guard stretchState.phase == .selecting else { return }
        guard !stretchState.caught.isEmpty else { cancelStretch(); return }
        stretchState.phase = .pickingBase
        commandMessage = stretchState.prompt
    }

    /// Routes one click into STRETCH: while `.selecting`, a plain click on
    /// an object catches ALL of its grips (AutoCAD's "picked whole, moves
    /// whole" rule — see `StretchToolState`'s header comment); a click on
    /// empty space is a no-op, matching `SelectionPrompt`'s own convention.
    /// While `.pickingBase`/`.pickingDestination`, feeds the point.
    private func handleStretchClick(hit: EntityID?, worldPoint: CGPoint) {
        if stretchState.phase == .selecting {
            guard let hit, let regen else {
                commandMessage = stretchState.prompt
                return
            }
            let caught = GripEditing.grips(for: hit, in: regen.parsed.store)
                .map { GripEditing.CaughtGrip(entityId: hit, gripIndex: $0.index, position: $0.position) }
            stretchState.addCaught(caught)
            commandMessage = stretchState.prompt
            return
        }
        commitStretchPoint(stretchState.snap?.point ?? worldPoint)
    }

    /// A crossing-window/lasso drag while `.selecting` catches every grip
    /// (of every entity the rect/polygon touches at all — Crossing
    /// semantics ALWAYS, matching AutoCAD's own STRETCH, which has no
    /// Window mode) that falls inside the rect — via
    /// `GripEditing.caughtGrips`, which re-examines each touched entity's
    /// individual grip positions against the SAME rect (not just "this
    /// entity was touched, catch all its grips," which `SelectionEngine
    /// .rectSelect` alone can't express).
    private func handleStretchBoxSelect(rect: CGRect) {
        guard let doc = document, let regen else { return }
        let touched = SelectionEngine.rectSelect(document: doc, usePaperSpace: space == .paper,
                                                 rect: rect, mode: .crossing, visibility: visibility)
        let caught = GripEditing.caughtGrips(ids: touched, in: regen.parsed.store, crossingWindow: rect)
        stretchState.addCaught(caught)
        commandMessage = stretchState.prompt
    }

    /// Feeds one point into STRETCH's base/destination phases — same shape
    /// as `commitMovePoint`, but commits via `GripEditing.applyStretch`
    /// (reshaping only the caught grips) instead of a whole-entity
    /// translate.
    private func commitStretchPoint(_ p: CGPoint) {
        switch stretchState.phase {
        case .idle, .selecting:
            break
        case .pickingBase:
            stretchState.basePoint = p
            stretchState.phase = .pickingDestination
            commandMessage = stretchState.prompt
        case .pickingDestination:
            guard let base = stretchState.basePoint else { stretchState = StretchToolState(); return }
            let delta = CGVector(dx: p.x - base.x, dy: p.y - base.y)
            let caught = stretchState.caught
            session.performEdit("Stretch") { tx in
                GripEditing.applyStretch(caught, delta: delta, in: tx)
            }
            commandMessage = "Stretched \(Set(caught.map(\.entityId)).count) object(s)"
            stretchState = StretchToolState()
        }
    }

    /// Live dashed ghost preview while picking the destination point —
    /// groups `stretchState.caught` by entity (an entity can have several
    /// caught grips) and reshapes each via `GripEditing.previewStretchShape`.
    /// Same "ContentView precomputes, DXFCanvasView just draws" split as
    /// every other ghost-entities computed property in this file.
    private var stretchGhostEntities: [DrawnEntity] {
        guard stretchState.phase == .pickingDestination, let regen, let base = stretchState.basePoint,
              let dest = stretchState.snap?.point ?? stretchState.hover else { return [] }
        let delta = CGVector(dx: dest.x - base.x, dy: dest.y - base.y)
        let store = regen.parsed.store
        var byEntity: [EntityID: Set<Int>] = [:]
        for grip in stretchState.caught { byEntity[grip.entityId, default: []].insert(grip.gripIndex) }
        var result: [DrawnEntity] = []
        for (id, indices) in byEntity {
            guard let h = store.header(id), !h.flags.contains(.deleted) else { continue }
            guard let shape = GripEditing.previewStretchShape(for: id, in: store, caughtIndices: indices, delta: delta) else { continue }
            var e = DrawnEntity(shape: shape)
            e.aci = h.aci == 256 ? 7 : Int(h.aci)
            e.isPaper = h.owner.isPaper
            result.append(e)
        }
        return result
    }

    // MARK: - FILLET/CHAMFER (Phase 4.4 — FilletChamferToolState)
    //
    // 2-click-per-corner gesture: click first line, click second line,
    // commit immediately, repeat until Esc — see `FilletChamferToolState`'s
    // header comment for why this is a THIRD parallel state type alongside
    // `ModifyToolState`/`TrimExtendToolState`. Radius (FILLET) persists via
    // the FILLETRAD sysvar; CHAMFER's distances/angle persist via
    // `session.chamferD1`/`chamferD2`/`chamferAngleDeg`/`chamferUsesAngle`
    // (plain published fields — see `DocumentSession`'s doc comment for why
    // these aren't separately-named SysVars).

    private func startFilletChamfer(_ command: FilletChamferCommand) {
        draft = DraftState()
        measure = MeasureState()
        moveState = MoveState()
        cancelModify()
        cancelTrimExtend()
        cancelOffset()
        cancelBlock()
        cancelExplode()
        cancelJoin()
        cancelArray()
        cancelOneShotAttributeFlags()
        pendingFilletChamferEntry = nil
        filletChamferState = FilletChamferToolState.begin(command)
        commandMessage = filletChamferState.prompt
    }

    private func cancelFilletChamfer() {
        filletChamferState = FilletChamferToolState(command: filletChamferState.command)
        pendingFilletChamferEntry = nil
        commandMessage = ""
    }

    /// Routes one click into the active FILLET/CHAMFER command. The first
    /// click just records which line + where; the second click resolves
    /// and IMMEDIATELY commits the corner (AutoCAD: FILLET/CHAMFER has no
    /// separate "confirm" step once both lines are picked), then loops back
    /// to `.pickFirst` for the next corner.
    private func handleFilletChamferClick(hit: EntityID?, worldPoint: CGPoint) {
        guard let targetId = hit else { return }   // clicking empty space is a no-op
        switch filletChamferState.phase {
        case .idle:
            return
        case .pickFirst:
            filletChamferState.withFirstTarget(targetId, at: worldPoint)
            commandMessage = filletChamferState.prompt
        case .pickSecond:
            commitFilletChamferSecondClick(secondId: targetId, secondPoint: worldPoint)
        }
    }

    private func commitFilletChamferSecondClick(secondId: EntityID, secondPoint: CGPoint) {
        guard let regen, let firstId = filletChamferState.firstTargetId,
              let firstPoint = filletChamferState.firstClickPoint else {
            cancelFilletChamfer()
            return
        }
        // Filleting/chamfering an entity against ITSELF (double-clicked the
        // same line twice) is never meaningful — reset and let the user
        // try again, matching AutoCAD's own rejection of a degenerate pick.
        guard secondId != firstId else {
            commandMessage = "\(filletChamferState.command.displayName) — select a DIFFERENT second line"
            return
        }
        let store = regen.parsed.store
        let tol = trimExtendTolerance   // same document-extent-derived tolerance convention as TRIM/EXTEND
        // TRIMMODE is stored as .int (0/1); SysVars.bool(_:) already handles
        // the int->bool coercion internally (see SysVars.swift's `bool(_:)`),
        // so a single call is sufficient here.
        let trimMode = sysVars.bool("TRIMMODE")
        let layerId1 = store.header(firstId)?.layerId ?? 0

        let request: FilletChamferExecutor.CommitRequest?
        switch filletChamferState.command {
        case .fillet:
            let radius = sysVars.double("FILLETRAD")
            request = FilletChamferExecutor.resolveFillet(id1: firstId, click1: firstPoint, id2: secondId, click2: secondPoint,
                                                           radius: radius, store: store, tol: tol)
        case .chamfer:
            let d1 = session.chamferD1
            let d2 = session.chamferUsesAngle ? (session.chamferAngleDeg * .pi / 180) : session.chamferD2
            request = FilletChamferExecutor.resolveChamfer(id1: firstId, click1: firstPoint, id2: secondId, click2: secondPoint,
                                                            d1: d1, d2: d2, angleMode: session.chamferUsesAngle, store: store, tol: tol)
        }

        guard let request else {
            commandMessage = "\(filletChamferState.command.displayName) — cannot \(filletChamferState.command.displayName.lowercased()) that combination of objects"
            filletChamferState.resetForNextCorner()
            return
        }
        session.performEdit(filletChamferState.command.displayName) { tx in
            FilletChamferExecutor.apply(request, trimMode: trimMode, layerId1: layerId1, to: tx)
        }
        commandMessage = "\(filletChamferState.command.displayName) — 1 corner"
        filletChamferState.resetForNextCorner()
    }

    // MARK: - OFFSET (Phase 4.5 — OffsetToolState)
    //
    // Distance (persisted OFFSETDIST) or through-point mode -> click
    // object -> click side/through-point -> commit -> repeat until Esc.
    // Comparatively thin per the plan's own scoping note — see
    // `OffsetExecutor.swift`'s header comment.

    private func startOffset(throughPointMode: Bool = false) {
        draft = DraftState()
        measure = MeasureState()
        moveState = MoveState()
        cancelModify()
        cancelTrimExtend()
        cancelFilletChamfer()
        cancelBlock()
        cancelExplode()
        cancelJoin()
        cancelArray()
        cancelOneShotAttributeFlags()
        offsetState = OffsetToolState.begin(throughPointMode: throughPointMode)
        commandMessage = offsetState.prompt
    }

    private func cancelOffset() {
        offsetState = OffsetToolState()
        commandMessage = ""
    }

    /// Routes one click into the active OFFSET command.
    private func handleOffsetClick(hit: EntityID?, worldPoint: CGPoint) {
        switch offsetState.phase {
        case .idle:
            return
        case .pickObject:
            guard let hit else { return }   // clicking empty space is a no-op
            offsetState.withObject(hit)
            commandMessage = offsetState.prompt
        case .pickSideOrPoint:
            commitOffsetSecondClick(at: worldPoint)
        }
    }

    private func commitOffsetSecondClick(at worldPoint: CGPoint) {
        guard let regen, let objectId = offsetState.objectId else {
            cancelOffset()
            return
        }
        let store = regen.parsed.store
        let tol = trimExtendTolerance   // same document-extent-derived tolerance convention as TRIM/EXTEND/FILLET/CHAMFER

        let protos: [EntityPrototype]?
        if offsetState.throughPointMode {
            protos = OffsetExecutor.resolveThroughPoint(id: objectId, throughPoint: worldPoint, store: store, tol: tol)
        } else {
            let distance = sysVars.double("OFFSETDIST")
            guard distance > 0 else {
                commandMessage = "Offset — OFFSETDIST must be positive (type OFFSETDIST to set it)"
                offsetState.resetForNextObject()
                return
            }
            protos = OffsetExecutor.resolve(id: objectId, distance: distance, sidePoint: worldPoint, store: store, tol: tol)
        }

        guard let protos, !protos.isEmpty else {
            commandMessage = "Offset — that object cannot be offset there"
            offsetState.resetForNextObject()
            return
        }
        var newIds: [EntityID] = []
        session.performEdit("Offset") { tx in
            for proto in protos { newIds.append(tx.add(proto)) }
        }
        session.lastCreatedEntities = Set(newIds)
        commandMessage = "Offset — \(newIds.count) object(s)"
        offsetState.resetForNextObject()
    }

    // MARK: - DIMENSION (linear/aligned annotation)
    //
    // 3-click AutoCAD DIMLINEAR/DIMALIGNED gesture: pick first extension
    // line origin, pick second, then pick where the dimension line itself
    // sits — see `DimensionTool.swift`/`DimensionToolState.swift` for the
    // full design rationale (real DIMENSION entity + anonymous block, why
    // it's persistent, per-dimension format override). Uses CURRENT
    // properties' layer/color, same as every other Phase 6.3 CAD tool
    // (LINE/CIRCLE/etc) — matches `draftContext(for:)`'s own convention,
    // NOT the legacy NOVACAD-MARKUP layer the old measure tools use.

    private func startDimensionTool(kind: DimensionKind) {
        draft = DraftState()
        measure = MeasureState()
        moveState = MoveState()
        cancelModify()
        cancelTrimExtend()
        cancelFilletChamfer()
        cancelOffset()
        cancelBlock()
        cancelExplode()
        cancelJoin()
        cancelArray()
        cancelOneShotAttributeFlags()
        dimensionToolState = DimensionToolState.begin(kind: kind)
        commandMessage = dimensionToolState.prompt
    }

    private func cancelDimensionTool() {
        dimensionToolState = DimensionToolState()
        commandMessage = ""
    }

    /// Routes one click into the active DIMENSION command.
    private func handleDimensionClick(at worldPoint: CGPoint) {
        switch dimensionToolState.phase {
        case .idle:
            return
        case .pickFirstPoint:
            dimensionToolState.withFirstPoint(worldPoint)
            commandMessage = dimensionToolState.prompt
        case .pickSecondPoint:
            dimensionToolState.withSecondPoint(worldPoint)
            commandMessage = dimensionToolState.prompt
        case .pickDimensionLinePlacement:
            commitDimension(placement: worldPoint)
        }
    }

    private func commitDimension(placement: CGPoint) {
        guard let regen,
              let p1 = dimensionToolState.firstPoint,
              let p2 = dimensionToolState.secondPoint else {
            cancelDimensionTool()
            return
        }
        let kind = dimensionToolState.kind
        let layerId = currentProperties.resolvedLayerId(in: regen.parsed)
        let aci = currentProperties.aciOrByLayer
        let isPaper = space == .paper
        var newId: EntityID?
        session.performEdit("Dimension") { tx in
            newId = DimensionTool.create(kind: kind, p1: p1, p2: p2, placement: placement,
                                        layerId: layerId, aci: aci, format: currentFormat,
                                        owner: isPaper ? .paper : .model,
                                        parsed: regen.parsed, tx: tx)
        }
        if let newId {
            session.lastCreatedEntities = [newId]
            commandMessage = "Dimension placed"
        } else {
            commandMessage = "Dimension — the two points must not coincide"
        }
        dimensionToolState.resetForNext()
    }

    /// If the current selection is EXACTLY one NovaCAD-authored DIMENSION
    /// (carrying `DimensionTool`'s own XDATA metadata — see
    /// `DimensionTool.readMetadata`), returns its `EntityID` plus that
    /// metadata, for the on-canvas format-switch badge. `nil` for any other
    /// selection shape (none, multiple, non-dimension, or a DIMENSION with
    /// no NovaCAD metadata — e.g. one round-tripped from an AutoCAD-
    /// authored file, which has no per-entity format override to switch).
    private func selectedDimensionFormatInfo() -> (EntityID, (format: MeasureFormat, measuredValue: Double))? {
        guard let regen, selection.count == 1, let id = selection.first else { return nil }
        let store = regen.parsed.store
        guard let h = store.header(id), !h.flags.contains(.deleted), h.type == .dimension else { return nil }
        guard let info = DimensionTool.readMetadata(id, store: store) else { return nil }
        return (id, info)
    }

    /// Re-formats a NovaCAD-authored dimension's displayed text in place —
    /// wired from the on-canvas format badge (`DimensionFormatBadge`).
    private func setDimensionFormat(_ id: EntityID, to newFormat: MeasureFormat) {
        guard let regen else { return }
        var applied = false
        session.performEdit("Dimension Format") { tx in
            applied = DimensionTool.setFormat(id, to: newFormat, parsed: regen.parsed, tx: tx)
        }
        if applied { commandMessage = "Dimension format updated" }
    }

    // MARK: - BLOCK / INSERT (Phase 6.1 — BlockToolState)

    /// BLOCK: uses the current selection (PICKFIRST) if non-empty, else
    /// starts a fresh `SelectionPrompt` acquisition — exactly the same
    /// noun-verb dispatch `startModify` uses.
    private func startBlock() {
        draft = DraftState()
        measure = MeasureState()
        moveState = MoveState()
        cancelModify()
        cancelTrimExtend()
        cancelFilletChamfer()
        cancelOffset()
        cancelExplode()
        cancelJoin()
        cancelArray()
        cancelOneShotAttributeFlags()
        blockToolState = BlockToolState.beginBlock(preselection: selection)
        if blockToolState.phase == .selecting {
            selectionPrompt = makeSelectionPrompt(preselected: [])
            commandMessage = blockToolState.prompt
        } else {
            selectionPrompt = nil
            commandMessage = blockToolState.prompt
        }
    }

    /// INSERT: the block name is chosen BEFORE this runs (the Tools ▸
    /// Insert Block… menu, mirroring Stamp's own picker) — mirrors
    /// `startOffset`'s "mode fixed at acquisition time" shape.
    private func startInsert(blockName: String) {
        draft = DraftState()
        measure = MeasureState()
        moveState = MoveState()
        cancelModify()
        cancelTrimExtend()
        cancelFilletChamfer()
        cancelOffset()
        cancelExplode()
        cancelJoin()
        cancelArray()
        cancelOneShotAttributeFlags()
        blockToolState = BlockToolState.beginInsert(blockName: blockName)
        selectionPrompt = nil
        commandMessage = blockToolState.prompt
    }

    private func cancelBlock() {
        blockToolState = BlockToolState(command: blockToolState.command)
        selectionPrompt = nil
        pendingBlockEntry = nil
        commandMessage = ""
    }

    /// Cancels an in-progress "Attach Xref…" placement — same shape as
    /// `cancelBlock`/`cancelOffset`/etc. (reset to a fresh, idle tool state).
    private func cancelXrefAttach() {
        xrefAttachToolState = XrefAttachToolState()
        commandMessage = ""
    }

    /// Cancels an in-progress cross-drawing "Paste" placement — same shape
    /// as `cancelXrefAttach` immediately above.
    private func cancelClipboardPaste() {
        clipboardPasteToolState = ClipboardPasteToolState()
        commandMessage = ""
    }

    /// Routes one click into the active BLOCK/INSERT command.
    private func handleBlockClick(hit: EntityID?, worldPoint: CGPoint, shiftDown: Bool) {
        if blockToolState.phase == .selecting {
            guard var prompt = selectionPrompt else { return }
            let result = prompt.handle(.pick(hit, worldPoint: worldPoint, shiftHeld: shiftDown))
            selectionPrompt = prompt
            applyBlockSelectionPromptResult(result)
            return
        }
        switch blockToolState.phase {
        case .idle, .selecting, .pickName:
            break
        case .pickBasePoint:
            blockToolState.basePoint = worldPoint
            blockToolState.phase = .pickName
            pendingBlockEntry = .blockName
            commandMessage = "BLOCK — enter block name:"
        case .pickInsertPoint:
            commitInsertAt(worldPoint)
        }
    }

    /// Shared `SelectionPromptResult` handling for BLOCK's acquisition —
    /// mirrors `applySelectionPromptResult`/`applyTrimExtendBoundaryPromptResult`
    /// exactly (advance on non-empty `.done`, fully cancel on `.cancelled`
    /// or an EMPTY `.done`).
    private func applyBlockSelectionPromptResult(_ result: SelectionPromptResult) {
        switch result {
        case .pending:
            commandMessage = selectionPrompt?.promptText ?? ""
        case .done(let ids):
            if ids.isEmpty { cancelBlock() }
            else {
                blockToolState.withAcquiredObjects(ids)
                selectionPrompt = nil
                commandMessage = blockToolState.prompt
            }
        case .cancelled:
            cancelBlock()
        }
    }

    /// Finishes BLOCK's active `SelectionPrompt` acquisition (bare Enter
    /// while `blockToolState.phase == .selecting`) — mirrors
    /// `finishSelectionPrompt()`'s exact rationale/doc comment: without
    /// this, a user who types BLOCK with an empty selection, clicks a few
    /// objects, then presses Enter intending to move on to picking the
    /// base point (exactly like COPY/ROTATE/SCALE/MIRROR support) has no
    /// way to finish acquisition at all — found missing by adversarial
    /// review (the bare-Enter branches in both `onReturnKey` and
    /// `executeCommand` only ever checked `modifyState`/`trimExtendState`,
    /// never `blockToolState`).
    private func finishBlockSelectionPrompt() {
        guard var prompt = selectionPrompt else { return }
        let result = prompt.handle(.finish)
        selectionPrompt = prompt
        applyBlockSelectionPromptResult(result)
    }

    /// Finishes EXPLODE's active `SelectionPrompt` acquisition (bare Enter
    /// while `explodeAwaitingSelection` is true) — same rationale as
    /// `finishBlockSelectionPrompt`. EXPLODE commits IMMEDIATELY on a
    /// non-empty `.done` (no further geometric-parameter phase exists), so
    /// this reuses `handleExplodeClick`'s own switch logic by feeding
    /// `.finish` directly rather than duplicating the done/cancelled
    /// handling a third time.
    private func finishExplodeSelectionPrompt() {
        guard var prompt = selectionPrompt else { return }
        let result = prompt.handle(.finish)
        selectionPrompt = prompt
        switch result {
        case .pending:
            commandMessage = selectionPrompt?.promptText ?? ""
        case .done(let ids):
            if ids.isEmpty { cancelExplode() } else { commitExplode(ids: Array(ids)) }
        case .cancelled:
            cancelExplode()
        }
    }

    /// Command-bar entry point for BLOCK's name step — called from
    /// `executeCommand`'s `pendingBlockEntry` guard (mirrors
    /// `applyPendingFilletChamferEntry`'s shape).
    private func applyPendingBlockNameEntry(_ raw: String) {
        let name = raw.trimmingCharacters(in: .whitespaces)
        pendingBlockEntry = nil
        guard !name.isEmpty else {
            commandMessage = "BLOCK — name cannot be empty"
            cancelBlock()
            return
        }
        guard let regen, let basePoint = blockToolState.basePoint else {
            cancelBlock()
            return
        }
        guard regen.parsed.blocks[name] == nil else {
            commandMessage = "BLOCK — a block named \"\(name)\" already exists"
            cancelBlock()
            return
        }
        let objectIDs = Array(blockToolState.objectIDs)
        let insertLayerId = regen.parsed.store.header(objectIDs.first ?? EntityID(raw: -1))?.layerId ?? 0
        var result: BlockEditor.CreateBlockResult?
        session.performEdit("Block") { tx in
            result = BlockEditor.createBlock(name: name, basePoint: basePoint, from: objectIDs,
                                             insertLayerId: insertLayerId, in: regen.parsed, tx: tx)
        }
        if let result {
            selection = [result.insertId]
            commandMessage = "BLOCK — created \"\(name)\" (\(objectIDs.count) object(s))"
        } else {
            commandMessage = "BLOCK — could not create \"\(name)\""
        }
        cancelBlock()
    }

    /// Commits INSERT's placement point — no attribute-value prompting in
    /// THIS session's UI (a documented simplification: every ATTDEF the
    /// target block contains uses its own default value; the attribute
    /// editor sheet, reachable immediately afterward via a double-click on
    /// the new INSERT, is the path for setting non-default values). Repeats
    /// at `.pickInsertPoint` until Esc, matching OFFSET's own "repeat with
    /// the same parameters" convention — AutoCAD's own INSERT does NOT
    /// repeat by default, but this project's established modal-tool
    /// convention (OFFSET/FILLET/CHAMFER) is "stay active until Esc," which
    /// is also strictly more useful for INSERT (placing several instances
    /// of the same block back-to-back is extremely common).
    private func commitInsertAt(_ worldPoint: CGPoint) {
        guard let regen, let blockName = blockToolState.insertBlockName else {
            cancelBlock()
            return
        }
        let layerId = ensureMarkupLayerId()
        var newId: EntityID?
        session.performEdit("Insert") { tx in
            newId = BlockEditor.insert(blockName: blockName, at: worldPoint, layerId: layerId, in: regen.parsed, tx: tx)
        }
        if let newId {
            session.lastCreatedEntities = [newId]
            commandMessage = "INSERT \(blockName) — placed (Esc to finish, or click again to place another)"
        } else {
            commandMessage = "INSERT \(blockName) — could not insert (block missing or empty)"
        }
        // Stay at .pickInsertPoint (same blockName) for repeated placement.
        blockToolState.hover = nil
        blockToolState.snap = nil
    }

    // MARK: - Attach Xref (new feature)
    //
    // Two-step UI mirroring INSERT's own shape (pick parameters, then a
    // canvas click to place — see `BlockToolState.pickInsertPoint`): (1) an
    // `NSOpenPanel` + `XrefAttach.prepareAttach` off the main thread produce
    // a `PendingAttach`, which drives (2) `XrefAttachSheet`'s layer-checkbox
    // list. "Attach…" from that sheet enters `xrefAttachToolState`'s own
    // click-to-place mode (`commitXrefAttachAt`); "Attach at Origin" skips
    // straight to committing at world (0,0), per this feature's product
    // decision to support both placement styles.

    /// Tools ▸ Attach Xref… menu item. Presents an open panel for a single
    /// .dxf/.dwg file, then parses it off the main thread (mirrors
    /// `ContentView.openFile`'s own off-main-thread parse) before showing
    /// the layer-selection sheet.
    private func startAttachXref() {
        guard let regen else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = []   // accept both .dxf and .dwg
        panel.title = "Attach Xref"
        panel.message = "Choose a DXF or DWG drawing to attach as an external reference."
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let scoped = url.startAccessingSecurityScopedResource()
        let hostBlockNames = Set(regen.parsed.blocks.keys)
        commandMessage = "Attach Xref — reading \(url.lastPathComponent)…"
        Task.detached(priority: .userInitiated) {
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let pending = try XrefAttach.prepareAttach(url: url, hostBlockNames: hostBlockNames)
                await MainActor.run {
                    xrefAttachSelectedLayers = []
                    pendingXrefAttach = pending
                    commandMessage = ""
                }
            } catch {
                await MainActor.run {
                    commandMessage = ""
                    alertMessage = (error as? LocalizedError)?.errorDescription
                        ?? "Failed to read \(url.lastPathComponent): \(error.localizedDescription)"
                }
            }
        }
    }

    /// "Attach…" from the layer-selection sheet: dismisses the sheet and
    /// enters click-to-place mode on the canvas (like INSERT's
    /// `.pickInsertPoint`), keeping the fully-parsed candidate + the user's
    /// layer selection around in `xrefAttachToolState` until the click.
    private func beginXrefAttachPlacement(_ pending: XrefAttach.PendingAttach) {
        pendingXrefAttach = nil
        draft = DraftState()
        measure = MeasureState()
        moveState = MoveState()
        cancelModify()
        cancelTrimExtend()
        cancelFilletChamfer()
        cancelOffset()
        cancelBlock()
        cancelExplode()
        cancelJoin()
        cancelArray()
        cancelAttedit()
        cancelAttdef()
        xrefAttachToolState = XrefAttachToolState.begin(pending: pending, selectedLayerNames: xrefAttachSelectedLayers)
        commandMessage = xrefAttachToolState.prompt
    }

    /// "Attach at Origin" from the layer-selection sheet: commits
    /// immediately at world (0,0) with no placement click.
    private func commitXrefAttachAtOrigin(_ pending: XrefAttach.PendingAttach) {
        pendingXrefAttach = nil
        commitXrefAttach(pending, selectedLayerNames: xrefAttachSelectedLayers, at: .zero)
    }

    /// Routed from `handleClick`'s `xrefAttachToolState.isActive` branch —
    /// the click-to-place path.
    private func commitXrefAttachAt(_ worldPoint: CGPoint) {
        guard let pending = xrefAttachToolState.pending else { cancelXrefAttach(); return }
        commitXrefAttach(pending, selectedLayerNames: xrefAttachToolState.selectedLayerNames, at: worldPoint)
        cancelXrefAttach()
    }

    /// Shared commit body for both placement styles — runs
    /// `XrefAttach.commitAttach` inside one undoable transaction, then
    /// resyncs the render model. A whole new xref block definition (plus,
    /// often, several of the candidate's own nested block defs) is
    /// structural metadata `RegenCoordinator.apply`'s incremental path
    /// can't safely patch (mirrors `createLayer`'s own "structural change ->
    /// fullRebuild" precedent) — `session.performEdit` already applies the
    /// transaction's ops incrementally, but the fresh block table entries
    /// need a `fullRebuild()` afterward for the Layers panel's External
    /// References list / `document.xrefs` to see the new xref at all
    /// (`DXFDocument.xrefs` is a snapshot built once by `Regenerator.build`,
    /// same "no append-after-load path" constraint documented on
    /// `MarkupStore.ensureMarkupLayer`).
    private func commitXrefAttach(_ pending: XrefAttach.PendingAttach, selectedLayerNames: Set<String>,
                                  at worldPoint: CGPoint) {
        guard let regen else { return }
        let layerId = ensureMarkupLayerId()
        let owner: OwnerRef = space == .paper ? .paper : .model
        var newId: EntityID?
        session.performEdit("Attach Xref") { tx in
            newId = XrefAttach.commitAttach(pending, selectedLayerNames: selectedLayerNames,
                                            at: worldPoint, layerId: layerId, owner: owner,
                                            in: regen.parsed, tx: tx)
        }
        if let newId {
            regen.fullRebuild()
            selection = [newId]
            commandMessage = "Attached \(pending.suggestedBlockName) (\(selectedLayerNames.count) layer(s))"
        } else {
            commandMessage = "Attach Xref — could not attach \(pending.sourceURL.lastPathComponent)"
        }
    }

    /// Layers panel's "Detach" context-menu item — computes every xref this
    /// detach would affect (shared-source de-dup, UNIONED across every
    /// xref in `xrefs` — a multi-row Shift-click selection, or a single
    /// row) and shows the confirmation alert; the actual removal happens in
    /// `commitXrefDetach` once the user confirms.
    private func beginXrefDetach(_ xrefs: [XrefInfo]) {
        guard let doc = document, !xrefs.isEmpty else { return }
        var affected: [XrefInfo] = []
        var seenIds = Set<Int>()
        for xref in xrefs {
            for a in XrefAttach.xrefsAffectedByDetach(xref, in: doc) where !seenIds.contains(a.id) {
                seenIds.insert(a.id)
                affected.append(a)
            }
        }
        pendingXrefDetach = affected
    }

    /// Confirmed removal — see `XrefAttach.commitDetach`'s doc comment for
    /// why this always acts on the WHOLE shared-source group, not just the
    /// one `XrefInfo` the user right-clicked.
    private func commitXrefDetach(_ xrefs: [XrefInfo]) {
        guard let regen, !xrefs.isEmpty else { return }
        var removed = false
        session.performEdit("Detach Xref") { tx in
            removed = XrefAttach.commitDetach(xrefs, in: regen.parsed, regen: regen, tx: tx)
        }
        if removed {
            regen.fullRebuild()
            let names = xrefs.map(\.blockName).joined(separator: ", ")
            commandMessage = "Detached \(names)"
        } else {
            commandMessage = "Detach Xref — nothing to remove"
        }
    }

    // MARK: - Cross-drawing Copy/Paste (new feature)
    //
    // See `CrossDocumentPaste.swift`'s header comment for the overall
    // design (pasteboard transport, no live cross-session registry needed).
    // Copy writes the CURRENT selection to `NSPasteboard`; Paste reads it
    // back and enters click-to-place mode (mirroring Attach-Xref's own
    // two-phase "gather parameters, then one canvas click" shape), with a
    // "Paste at Original Coordinates" menu item alongside it (per this
    // feature's product decision) that commits immediately with zero
    // translation instead of waiting for a click.

    /// Edit ▸ Copy (⌘C) / COPYCLIP. Serializes the current selection (any
    /// mix of ordinary entities, markup, and INSERTs-with-ATTRIBs) to
    /// `NSPasteboard.general` via `PasteboardSnapshot.capture`. A no-op
    /// (with a status message, not a crash) if nothing is selected or
    /// nothing in the selection is capturable (e.g. a selection that
    /// resolved to zero live entities since the selection was made).
    private func copySelectionToPasteboard() {
        guard let regen, !selection.isEmpty else {
            commandMessage = "Copy — nothing selected"
            return
        }
        guard let snapshot = PasteboardSnapshot.capture(ids: selection, from: regen.parsed) else {
            commandMessage = "Copy — nothing to copy"
            return
        }
        PasteboardSnapshot.write(snapshot, to: .general)
        commandMessage = "Copied \(snapshot.entities.count) object(s)"
    }

    /// Edit ▸ Paste (⌘V) / PASTECLIP. Reads `NSPasteboard.general` and, if
    /// it holds a valid `PasteboardSnapshot` (from THIS app — possibly a
    /// different open drawing, another tab, or another window entirely;
    /// see this file's header comment), enters click-to-place mode.
    private func startClipboardPaste() {
        guard let snapshot = PasteboardSnapshot.read(from: .general) else {
            commandMessage = "Paste — clipboard has nothing to paste"
            return
        }
        draft = DraftState()
        measure = MeasureState()
        moveState = MoveState()
        cancelModify()
        cancelTrimExtend()
        cancelFilletChamfer()
        cancelOffset()
        cancelBlock()
        cancelExplode()
        cancelJoin()
        cancelArray()
        cancelAttedit()
        cancelAttdef()
        cancelXrefAttach()
        clipboardPasteToolState = ClipboardPasteToolState.begin(snapshot)
        commandMessage = clipboardPasteToolState.prompt
    }

    /// "Paste at Original Coordinates" — commits immediately with zero
    /// translation (entities land at the exact world X/Y they were copied
    /// from), per this feature's product decision's explicit alternative to
    /// the click-to-place flow. Available any time the clipboard holds a
    /// valid snapshot, independent of whether click-to-place mode is
    /// currently active (mirrors `commitXrefAttachAtOrigin`'s own
    /// "works standalone from the sheet, not just mid-placement" shape).
    private func pasteAtOriginalCoordinates() {
        guard let snapshot = PasteboardSnapshot.read(from: .general) else {
            commandMessage = "Paste — clipboard has nothing to paste"
            return
        }
        cancelClipboardPaste()
        commitClipboardPaste(snapshot, dx: 0, dy: 0)
    }

    /// Routed from `handleClick`'s `clipboardPasteToolState.isActive`
    /// branch — the click-to-place path. Translates by the offset from the
    /// snapshot's own source-bounds CENTER to the clicked point, so "click"
    /// places the copied selection's visual center at the click point
    /// (matching how a user dragging a marquee-selected group intuitively
    /// expects a paste to land) — the only real choice besides "some
    /// specific captured base point," which this feature doesn't ask the
    /// user to pick separately (unlike INSERT's own explicit base-point
    /// step) to keep the common case a single click.
    private func commitClipboardPasteAt(_ worldPoint: CGPoint) {
        guard let snapshot = clipboardPasteToolState.snapshot else { cancelClipboardPaste(); return }
        let sourceCenter = CGPoint(x: (snapshot.sourceBoundsMinX + snapshot.sourceBoundsMaxX) / 2,
                                   y: (snapshot.sourceBoundsMinY + snapshot.sourceBoundsMaxY) / 2)
        let dx = Double(worldPoint.x - sourceCenter.x)
        let dy = Double(worldPoint.y - sourceCenter.y)
        cancelClipboardPaste()
        commitClipboardPaste(snapshot, dx: dx, dy: dy)
    }

    /// Shared commit body for both placement styles — runs
    /// `CrossDocumentPaste.commitPaste` inside one undoable transaction
    /// against the ACTIVE tab's own document/session (the destination —
    /// see this file's header comment on why no other-session registry is
    /// needed), then resyncs the render model. New layer/linetype/block
    /// registrations are structural metadata `RegenCoordinator.apply`'s
    /// incremental path can't safely patch (same "fullRebuild after a
    /// structural change" precedent as `commitXrefAttach`/`createLayer`).
    private func commitClipboardPaste(_ snapshot: PasteboardSnapshot.Snapshot, dx: Double, dy: Double) {
        guard let regen else { return }
        let owner: OwnerRef = space == .paper ? .paper : .model
        var newIds: [EntityID] = []
        session.performEdit("Paste") { tx in
            newIds = CrossDocumentPaste.commitPaste(snapshot, dx: dx, dy: dy, owner: owner,
                                                    in: regen.parsed, tx: tx)
        }
        if !newIds.isEmpty {
            regen.fullRebuild()
            selection = Set(newIds)
            commandMessage = "Pasted \(newIds.count) object(s)"
        } else {
            commandMessage = "Paste — nothing was pasted"
        }
    }

    // MARK: - ATTDEF (Phase 6.1 — minimal, no BEDIT session)
    //
    // Scope decision (documented per the plan's "use your judgment"
    // allowance): AutoCAD's real ATTDEF is placed while INSIDE a block-edit
    // context (BEDIT), which this phase does not implement (6.3/out of
    // scope). This session's ATTDEF instead prompts for an existing block's
    // NAME directly, then tag/prompt/default via the same command-bar
    // chained-entry mechanism as BLOCK's name step, then a single click to
    // place it (height fixed at 2.5 — matching the parser's own TEXT
    // default — since a full dynamic-height prompt adds another entry step
    // for a rarely-changed value; SETVAR-style height entry is a reasonable
    // future enhancement, not implemented here).

    private func startAttdef() {
        draft = DraftState()
        measure = MeasureState()
        moveState = MoveState()
        cancelModify()
        cancelTrimExtend()
        cancelFilletChamfer()
        cancelOffset()
        cancelBlock()
        cancelExplode()
        cancelJoin()
        cancelAttedit()
        cancelArray()
        attdefBlockName = ""
        attdefTag = ""
        attdefPrompt = ""
        pendingAttdefEntry = .blockName
        commandMessage = "ATTDEF — enter target block name:"
    }

    private func cancelAttdef() {
        pendingAttdefEntry = nil
        awaitingAttdefPlacement = false
        commandMessage = ""
    }

    private func cancelAttedit() {
        awaitingAttEditPick = false
        commandMessage = ""
    }

    /// Adversarial-review fix: EVERY `start*`/`setDraft`/`setTool`/
    /// `setMeasure` function that activates some OTHER modal tool must
    /// cancel `awaitingAttEditPick`/`awaitingAttdefPlacement` too — these
    /// two one-shot flags are checked FIRST in `handleClick` (ahead of
    /// every other modal-tool branch), so if a caller starts (say) MOVE
    /// without clearing them, the very next canvas click is silently
    /// hijacked by the stale ATTEDIT/ATTDEF pick instead of reaching
    /// MOVE's own base-point handler. Previously each `start*` function
    /// only cancelled the OLDER Phase 4-6.1 tools it happened to know
    /// about at the time it was written, missing the newer ATTEDIT/ATTDEF
    /// flags entirely (found by adversarial review: only `handleEscape`
    /// and `startAttdef`/`startAttedit` themselves cleared these two
    /// flags — the Tools menu and command-bar dispatch to `startMove`/
    /// `startModify`/`startTrimExtend`/`startFilletChamfer`/`startOffset`/
    /// `setDraft`/`setTool`/`setMeasure` all bypass `handleEscape`
    /// entirely). Centralized here as ONE call every `start*`/`set*`
    /// function makes, rather than fixing each site's own ad hoc list of
    /// `cancel*()` calls piecemeal — this is exactly the kind of
    /// "wiring checklist" step this project has repeatedly missed across
    /// FILLET/CHAMFER/OFFSET/BLOCK/EXPLODE, so it's made structurally hard
    /// to miss again for any FUTURE modal tool: add the new tool's own
    /// one-shot flags here once, and every existing call site picks up the
    /// fix automatically.
    private func cancelOneShotAttributeFlags() {
        cancelAttedit()
        cancelAttdef()
        cancelXrefAttach()
    }

    private func applyPendingAttdefEntry(_ raw: String, kind: PendingAttdefEntry) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        switch kind {
        case .blockName:
            guard !trimmed.isEmpty, let regen, regen.parsed.blocks[trimmed] != nil else {
                commandMessage = "ATTDEF — unknown block \"\(trimmed)\""
                cancelAttdef()
                return
            }
            attdefBlockName = trimmed
            pendingAttdefEntry = .tag
            commandMessage = "ATTDEF — enter attribute tag:"
        case .tag:
            guard !trimmed.isEmpty else {
                commandMessage = "ATTDEF — tag cannot be empty"
                cancelAttdef()
                return
            }
            attdefTag = trimmed
            pendingAttdefEntry = .prompt
            commandMessage = "ATTDEF — enter prompt text (blank for none):"
        case .prompt:
            attdefPrompt = trimmed
            pendingAttdefEntry = .defaultValue
            commandMessage = "ATTDEF — enter default value:"
        case .defaultValue:
            pendingAttdefEntry = nil
            awaitingAttdefPlacement = true
            commandMessage = "ATTDEF \(attdefTag) — specify insertion point:"
            // Stash the default value in `attdefPrompt`'s sibling — reuse a
            // dedicated var to avoid overloading `attdefPrompt`.
            pendingAttdefDefaultValue = trimmed
        }
    }

    /// Places the ATTDEF gathered via `applyPendingAttdefEntry` at a click —
    /// routed from `handleClick`'s plain-select fallthrough (ATTDEF has no
    /// `BlockToolState` phase of its own; `awaitingAttdefPlacement` is a
    /// simple one-shot flag, matching ATTEDIT's own `awaitingAttEditPick`).
    private func commitAttdefPlacement(at worldPoint: CGPoint) {
        guard let regen else { cancelAttdef(); return }
        var newId: EntityID?
        session.performEdit("Attdef") { tx in
            newId = BlockEditor.createAttdef(tag: attdefTag, prompt: attdefPrompt,
                                             defaultValue: pendingAttdefDefaultValue, at: worldPoint,
                                             height: 2.5, layerId: 0, inBlockNamed: attdefBlockName,
                                             in: regen.parsed, tx: tx)
        }
        if newId != nil {
            regen.markBlockDirty(attdefBlockName)
            _ = regen.regenerateDirtyBlocks()
            commandMessage = "ATTDEF — added \(attdefTag) to \(attdefBlockName)"
        } else {
            commandMessage = "ATTDEF — could not add to \(attdefBlockName)"
        }
        cancelAttdef()
    }

    // MARK: - ATTEDIT (Phase 6.1)

    private func startAttedit() {
        draft = DraftState()
        measure = MeasureState()
        moveState = MoveState()
        cancelModify()
        cancelTrimExtend()
        cancelFilletChamfer()
        cancelOffset()
        cancelBlock()
        cancelAttdef()
        cancelExplode()
        cancelJoin()
        cancelArray()
        awaitingAttEditPick = true
        commandMessage = "ATTEDIT — select an INSERT with attributes:"
    }

    /// Routed from `handleClick`'s plain-select fallthrough.
    private func commitAttEditPick(at worldPoint: CGPoint) {
        guard let doc = document, let regen else { awaitingAttEditPick = false; return }
        let tolerance = 6 / max(zoom, 1e-12)
        guard let hit = HitTester.hitTestEntityID(document: doc, usePaperSpace: space == .paper,
                                                  at: worldPoint, tolerance: tolerance, visibility: visibility),
              let h = regen.parsed.store.header(hit), h.type == .insert else {
            commandMessage = "ATTEDIT — no INSERT there"
            awaitingAttEditPick = false
            return
        }
        guard !BlockEditor.attributes(of: hit, in: regen.parsed.store).isEmpty else {
            commandMessage = "ATTEDIT — that INSERT has no attributes"
            awaitingAttEditPick = false
            return
        }
        attributeEditorInsertId = hit
        awaitingAttEditPick = false
        commandMessage = ""
    }

    // MARK: - EXPLODE (Phase 6.2)
    //
    // No geometric-parameter phase at all: PICKFIRST (non-empty `selection`)
    // commits immediately; an empty selection starts the SAME shared
    // `SelectionPrompt` acquisition every other command uses, and `.done`
    // commits immediately too — see `DocumentSession.explodeAwaitingSelection`'s
    // doc comment for why this doesn't need a full state-machine type.

    private func startExplode() {
        draft = DraftState()
        measure = MeasureState()
        moveState = MoveState()
        cancelModify()
        cancelTrimExtend()
        cancelFilletChamfer()
        cancelOffset()
        cancelBlock()
        cancelArray()
        cancelJoin()
        cancelOneShotAttributeFlags()
        if !selection.isEmpty {
            commitExplode(ids: Array(selection))
            return
        }
        explodeAwaitingSelection = true
        selectionPrompt = makeSelectionPrompt(preselected: [])
        commandMessage = selectionPrompt?.promptText ?? "EXPLODE — Select objects:"
    }

    private func cancelExplode() {
        explodeAwaitingSelection = false
        selectionPrompt = nil
        commandMessage = ""
    }

    /// Routes one click into EXPLODE's `SelectionPrompt` acquisition —
    /// called from `handleClick`'s dedicated `explodeAwaitingSelection`
    /// branch (checked alongside `awaitingAttEditPick`/
    /// `awaitingAttdefPlacement`, before every full modal-tool state).
    private func handleExplodeClick(hit: EntityID?, worldPoint: CGPoint, shiftDown: Bool) {
        guard var prompt = selectionPrompt else { return }
        let result = prompt.handle(.pick(hit, worldPoint: worldPoint, shiftHeld: shiftDown))
        selectionPrompt = prompt
        switch result {
        case .pending:
            commandMessage = selectionPrompt?.promptText ?? ""
        case .done(let ids):
            if ids.isEmpty { cancelExplode() }
            else { commitExplode(ids: Array(ids)) }
        case .cancelled:
            cancelExplode()
        }
    }

    /// Commits the actual explode via `EntityExploder`, in ONE transaction
    /// covering every selected object (per the plan's "multi-select in one
    /// transaction"). Shows progress-style messaging above the plan's
    /// `EntityExploder.progressThreshold` (100k) children — this session's
    /// explode always completes synchronously (no background-queue
    /// infrastructure exists for editing commands yet, unlike rendering),
    /// so "progress text" here means an explanatory BEFORE/AFTER message
    /// rather than a live progress bar; a genuinely async/cancellable
    /// explode is a reasonable future enhancement once one large real
    /// INSERT is profiled past a threshold where synchronous blocking is
    /// actually felt (see the final report's headless timing numbers for
    /// this session's own measurement of a large real INSERT).
    private func commitExplode(ids: [EntityID]) {
        guard let regen else { cancelExplode(); return }
        let idsSnapshot = ids
        if idsSnapshot.count > 10 {
            // A rough pre-check so the user sees SOME feedback before a
            // large multi-select explode — exact totals aren't known until
            // after the transaction runs (nested block fan-out isn't
            // predictable from the top-level count alone).
            commandMessage = "Exploding \(idsSnapshot.count) object(s)…"
        }
        var result: EntityExploder.Result!
        session.performEdit("Explode") { tx in
            result = EntityExploder.explode(ids: idsSnapshot, store: regen.parsed.store, parsed: regen.parsed, tx: tx)
        }
        if result.newIDs.count > EntityExploder.progressThreshold {
            commandMessage = "Explode — \(result.explodedCount) object(s) exploded into \(result.newIDs.count) entities"
        } else if result.explodedCount > 0 {
            commandMessage = "Explode — \(result.explodedCount) object(s) exploded"
            if result.skippedCount > 0 {
                commandMessage += " (\(result.skippedCount) could not be exploded)"
            }
        } else {
            commandMessage = "Explode — nothing in the selection could be exploded"
        }
        selection = Set(result.newIDs)
        cancelExplode()
    }

    // MARK: - JOIN (new feature — JoinExecutor)
    //
    // Same "acquire a selection set, then commit in one synchronous call"
    // shape as EXPLODE (a Bool flag, not a full state-machine type — see
    // `DocumentSession.joinAwaitingSelection`): a non-empty selection at
    // invocation (PICKFIRST) commits immediately; an empty selection starts
    // the SAME shared `SelectionPrompt` acquisition every other command
    // uses, and `.done` commits immediately too.

    private func startJoin() {
        draft = DraftState()
        measure = MeasureState()
        moveState = MoveState()
        cancelModify()
        cancelTrimExtend()
        cancelFilletChamfer()
        cancelOffset()
        cancelBlock()
        cancelArray()
        cancelExplode()
        cancelOneShotAttributeFlags()
        if !selection.isEmpty {
            commitJoin(ids: Array(selection))
            return
        }
        joinAwaitingSelection = true
        selectionPrompt = makeSelectionPrompt(preselected: [])
        commandMessage = selectionPrompt?.promptText ?? "JOIN — Select objects:"
    }

    private func cancelJoin() {
        joinAwaitingSelection = false
        selectionPrompt = nil
        commandMessage = ""
    }

    /// Bare Enter while acquiring — finishes with whatever's selected so far
    /// (mirrors `finishExplodeSelectionPrompt`).
    private func finishJoinSelectionPrompt() {
        guard joinAwaitingSelection, var prompt = selectionPrompt else { return }
        let result = prompt.handle(.finish)
        selectionPrompt = prompt
        switch result {
        case .pending: commandMessage = selectionPrompt?.promptText ?? ""
        case .done(let ids): if ids.isEmpty { cancelJoin() } else { commitJoin(ids: Array(ids)) }
        case .cancelled: cancelJoin()
        }
    }

    /// Routes one click into JOIN's `SelectionPrompt` acquisition — called
    /// from `handleClick`'s dedicated `joinAwaitingSelection` branch
    /// (alongside `explodeAwaitingSelection`).
    private func handleJoinClick(hit: EntityID?, worldPoint: CGPoint, shiftDown: Bool) {
        guard var prompt = selectionPrompt else { return }
        let result = prompt.handle(.pick(hit, worldPoint: worldPoint, shiftHeld: shiftDown))
        selectionPrompt = prompt
        switch result {
        case .pending:
            commandMessage = selectionPrompt?.promptText ?? ""
        case .done(let ids):
            if ids.isEmpty { cancelJoin() }
            else { commitJoin(ids: Array(ids)) }
        case .cancelled:
            cancelJoin()
        }
    }

    /// Commits the actual join via `JoinExecutor`, in ONE transaction. The
    /// merged entities become the new selection (via `selectNewEntities`);
    /// if nothing joins, the selection is left as-is and a message explains
    /// why (matching AutoCAD's "JOIN — 0 segments joined" feedback).
    private func commitJoin(ids: [EntityID]) {
        guard let regen else { cancelJoin(); return }
        guard let request = JoinExecutor.resolveJoin(ids: ids, store: regen.parsed.store, tol: trimExtendTolerance) else {
            commandMessage = "Join — nothing in the selection could be joined (objects must be connected lines/arcs/polylines)"
            cancelJoin()
            return
        }
        var created: [EntityID] = []
        session.performEdit("Join") { tx in
            created = JoinExecutor.apply(request, to: tx)
        }
        let sourceCount = request.results.reduce(0) { $0 + $1.sourceIds.count }
        commandMessage = "Join — \(sourceCount) object(s) joined into \(created.count) entity(ies)"
        selection = Set(created)
        cancelJoin()
    }

    /// The Erase tool's current hover-candidate geometry, for
    /// `DXFCanvasView`'s yellow highlight overlay (see
    /// `InputView.drawEraseCandidate`) — the entity itself already renders
    /// via the normal bitmap; this just resolves what to outline.
    private var eraseCandidateShape: DrawnEntity.Shape? {
        guard let id = eraseCandidate, let regen else { return nil }
        return MarkupStore.shapeForGhost(id: id, store: regen.parsed.store)
    }

    /// Phase 4.3: TRIM/EXTEND's hover-highlight target — the entity under
    /// `trimExtendState.hover` while `.pickingTargets` is active, resolved
    /// fresh on every access (same "computed, not cached" convention as
    /// `eraseCandidateShape`) rather than stored as separate `@State`, so it
    /// can never go stale relative to `hover`/the live document. Uses
    /// `MarkupStore.shapeForGhost` (documented gap: flattens a bulged
    /// polyline segment to a straight chord and returns nil for splines —
    /// acceptable for a hover PREVIEW, since the actual committed geometry
    /// via `Transaction` is always exact regardless of what the highlight
    /// shows).
    private var trimExtendHoverShape: DrawnEntity.Shape? {
        guard trimExtendState.phase == .pickingTargets, let hover = trimExtendState.hover,
              let doc = document, let regen else { return nil }
        let tolerance = 6 / max(zoom, 1e-12)
        guard let id = HitTester.hitTestEntityID(document: doc, usePaperSpace: space == .paper,
                                                 at: hover, tolerance: tolerance, visibility: visibility) else { return nil }
        return MarkupStore.shapeForGhost(id: id, store: regen.parsed.store)
    }

    /// Same "computed, not cached" hover-highlight convention as
    /// `trimExtendHoverShape` above, covering FILLET/CHAMFER/OFFSET —
    /// closes a gap an adversarial review found (`handleHover` had no
    /// branch for these three tools at all, so they got zero hover
    /// feedback while every other modal tool had some).
    private var filletChamferOffsetHoverShape: DrawnEntity.Shape? {
        let hover: CGPoint?
        if filletChamferState.isActive { hover = filletChamferState.hover }
        else if offsetState.isActive { hover = offsetState.hover }
        else { hover = nil }
        guard let hover, let doc = document, let regen else { return nil }
        let tolerance = 6 / max(zoom, 1e-12)
        guard let id = HitTester.hitTestEntityID(document: doc, usePaperSpace: space == .paper,
                                                 at: hover, tolerance: tolerance, visibility: visibility) else { return nil }
        return MarkupStore.shapeForGhost(id: id, store: regen.parsed.store)
    }

    /// Deletes the MARKUP subset of the current selection — matching
    /// pre-1.7 behavior exactly (Delete/the context menu's "Delete" only
    /// ever removed user-drawn markup, never the original drawing; there is
    /// still no general "erase original geometry" feature).
    private func deleteSelectedMarkup() {
        let ids = selectedMarkupIDs
        guard !ids.isEmpty else { return }
        session.performEdit("Erase") { tx in
            for id in ids { tx.delete(id) }
        }
        moveState = MoveState()   // deleting mid-move leaves nothing to move
        cancelModify()            // deleting mid-modify leaves nothing to transform
        cancelTrimExtend()        // deleting mid-trim/extend leaves nothing to act on
        cancelFilletChamfer()     // deleting mid-fillet/chamfer leaves nothing to act on
        cancelOffset()            // deleting mid-offset leaves nothing to act on
        commandMessage = "\(ids.count) object(s) deleted"
    }

    /// Deletes EVERY selected object — original drawing geometry as well as
    /// markup — unlike `deleteSelectedMarkup()`, which only touches the
    /// `NOVACAD-MARKUP` layer. Both route through the SAME `tx.delete(id)`
    /// (an in-memory tombstone override — see `NON_DESTRUCTIVE_EDIT_DESIGN.md`
    /// §4.5: the raw on-disk geometry is never mutated, so this is fully
    /// undoable AND round-trip-safe), so deleting an original entity here is
    /// exactly the ERASE tool's own single-click deletion generalized to the
    /// whole selection. Selection is cleared afterward since the deleted ids
    /// no longer resolve to anything drawable.
    private func deleteSelection() {
        let ids = selection
        guard !ids.isEmpty else { return }
        session.performEdit("Erase") { tx in
            for id in ids { tx.delete(id) }
        }
        selection = []
        moveState = MoveState()   // deleting mid-move leaves nothing to move
        cancelModify()            // deleting mid-modify leaves nothing to transform
        cancelTrimExtend()        // deleting mid-trim/extend leaves nothing to act on
        cancelFilletChamfer()     // deleting mid-fillet/chamfer leaves nothing to act on
        cancelOffset()            // deleting mid-offset leaves nothing to act on
        commandMessage = "\(ids.count) object(s) deleted"
    }

    private func recolorSelectedMarkup() {
        let ids = selectedMarkupIDs
        guard !ids.isEmpty else { return }
        let aci = Int16(markupColor)
        session.performEdit("Recolor") { tx in
            for id in ids { tx.modifyHeader(id) { $0.aci = aci } }
        }
    }

    /// AI Assistant panel's "Apply" button — commits every staged
    /// `AIProposedEdit` as one undoable transaction (see
    /// `AIProposedEditApplier`'s own doc comment for why this is a single
    /// batch, not one transaction per edit).
    private func applyAIProposedEdits(_ edits: [AIProposedEdit]) -> Bool {
        guard let regen else { return false }
        let applied = AIProposedEditApplier.apply(edits, session: session, regen: regen)
        commandMessage = applied == 0
            ? "AI Assistant — no edits could be applied (targets may no longer exist)"
            : "AI Assistant — applied \(applied) edit(s)"
        return applied > 0
    }

    /// AI Assistant panel's "Apply" button for staged geometry-creation
    /// actions (aisle repair/route/shading, dock aprons) — sibling to
    /// `applyAIProposedEdits`, see `AIProposedGeometryApplier`'s own doc
    /// comment for why this commits every staged action as one undoable
    /// transaction.
    private func applyAIProposedGeometry(_ actions: [AIProposedGeometry]) -> Bool {
        guard let regen else { return false }
        let created = AIProposedGeometryApplier.apply(actions, session: session, regen: regen)
        commandMessage = created == 0
            ? "AI Assistant — no geometry could be created"
            : "AI Assistant — created \(created) entit\(created == 1 ? "y" : "ies")"
        return created > 0
    }

    /// Nearest visible circle/arc whose ring passes within tolerance of `world`.
    private func pickArc(at world: CGPoint)
        -> (center: CGPoint, radius: CGFloat, startDeg: Double, endDeg: Double, full: Bool)? {
        guard let doc = document else { return nil }
        let groups = space == .paper ? doc.paperGroups : doc.modelGroups
        let tol = 8 / max(zoom, 1e-12)
        var best: (arc: StrokeStore.Arc, d: CGFloat)? = nil
        for g in groups where visibility.isSelectable(g) {
            guard g.bounds.insetBy(dx: -tol, dy: -tol).contains(world) else { continue }
            for arc in g.strokes.arcs {
                let dc = hypot(world.x - arc.center.x, world.y - arc.center.y)
                let d = abs(dc - arc.radius)
                guard d <= tol else { continue }
                if !arc.isFullCircle {
                    let ang = atan2(world.y - arc.center.y, world.x - arc.center.x) * 180 / .pi
                    guard HitTester.angleWithinSweep(ang, from: arc.startAngleDeg,
                                                     to: arc.endAngleDeg) else { continue }
                }
                if best == nil || d < best!.d { best = (arc, d) }
            }
        }
        guard let b = best else { return nil }
        return (b.arc.center, b.arc.radius, b.arc.startAngleDeg, b.arc.endAngleDeg, b.arc.isFullCircle)
    }

    private var mergedProperties: [EntityProperty] {
        guard let doc = document else { return [] }
        return HitTester.mergedProperties(for: Array(selectionRefs), document: doc,
                                          usePaperSpace: space == .paper,
                                          format: currentFormat,
                                          store: regen?.parsed.store)
    }

    /// Resolves the right-click point (falling back to the current
    /// selection if the click didn't land on anything, matching this app's
    /// established "point or selection" convention — see `EditScriptRunner`'s
    /// `explode` verb doc comment for the same pattern) to the ANCHOR
    /// `EntityID` of whichever array it belongs to, if any.
    private func arrayEditTarget(at viewPoint: CGPoint) -> EntityID? {
        guard !session.arrays.isEmpty else { return nil }
        var candidateIDs: Set<EntityID> = []
        if let doc = document {
            let worldPoint = viewPoint.applying(worldToView().inverted())
            let tolerance = 6 / max(zoom, 1e-12)
            if let hit = HitTester.hitTestEntityID(document: doc, usePaperSpace: space == .paper,
                                                   at: worldPoint, tolerance: tolerance, visibility: visibility) {
                candidateIDs.insert(hit)
            }
        }
        candidateIDs.formUnion(selection)
        guard !candidateIDs.isEmpty else { return nil }
        for (anchor, def) in session.arrays {
            if !candidateIDs.isDisjoint(with: def.memberHandles) { return anchor }
        }
        return nil
    }

    // MARK: - ARRAY (Phase 6.4 — ArrayToolState)

    /// PICKFIRST/interactive dispatch, mirroring `startBlock`'s exact shape.
    private func startArray() {
        draft = DraftState()
        measure = MeasureState()
        moveState = MoveState()
        cancelModify()
        cancelTrimExtend()
        cancelFilletChamfer()
        cancelOffset()
        cancelBlock()
        cancelExplode()
        cancelJoin()
        cancelOneShotAttributeFlags()
        arrayToolState = ArrayToolState.begin(preselection: selection)
        if arrayToolState.phase == .selecting {
            selectionPrompt = makeSelectionPrompt(preselected: [])
            commandMessage = arrayToolState.prompt
        } else {
            selectionPrompt = nil
            pendingArrayEntry = .kind
            commandMessage = arrayToolState.prompt
        }
    }

    /// Context menu / future "Edit Array" entry point — re-enters the
    /// field-gathering flow pre-filled from an existing `ArrayDefinition`,
    /// per the plan's "prompts pre-filled -> regenerate" spec.
    private func startEditArray(anchor: EntityID) {
        guard let def = session.arrays[anchor] else { return }
        draft = DraftState()
        measure = MeasureState()
        moveState = MoveState()
        cancelModify()
        cancelTrimExtend()
        cancelFilletChamfer()
        cancelOffset()
        cancelBlock()
        cancelExplode()
        cancelOneShotAttributeFlags()
        arrayToolState = ArrayToolState.beginEdit(anchor: anchor, definition: def)
        selectionPrompt = nil
        pendingArrayEntry = .field
        commandMessage = "Edit Array — " + arrayToolState.prompt
    }

    private func cancelArray() {
        arrayToolState = ArrayToolState()
        pendingArrayEntry = nil
        selectionPrompt = nil
        commandMessage = ""
    }

    private func applyArraySelectionPromptResult(_ result: SelectionPromptResult) {
        switch result {
        case .pending:
            commandMessage = selectionPrompt?.promptText ?? ""
        case .done(let ids):
            if ids.isEmpty { cancelArray() }
            else {
                arrayToolState.withAcquiredObjects(ids)
                selectionPrompt = nil
                pendingArrayEntry = .kind
                commandMessage = arrayToolState.prompt
            }
        case .cancelled:
            cancelArray()
        }
    }

    /// Finishes ARRAY's active `SelectionPrompt` acquisition (bare Enter
    /// while `arrayToolState.phase == .selecting`) — mirrors
    /// `finishBlockSelectionPrompt()` exactly.
    private func finishArraySelectionPrompt() {
        guard var prompt = selectionPrompt else { return }
        let result = prompt.handle(.finish)
        selectionPrompt = prompt
        applyArraySelectionPromptResult(result)
    }

    /// Routes one command-bar submission into ARRAY's kind-choice /
    /// field-value chain (`pendingArrayEntry`). An empty submission accepts
    /// the CURRENTLY SHOWN default for whichever field is pending — matches
    /// AutoCAD's own bracketed-default command-line convention exactly
    /// (pressing Enter alone accepts `<default>`).
    private func applyPendingArrayEntry(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        switch pendingArrayEntry {
        case .kind:
            let upper = trimmed.uppercased()
            if upper.isEmpty || upper == "R" || upper.hasPrefix("REC") {
                arrayToolState.withChosenKind(.rectangular)
            } else if upper == "P" || upper.hasPrefix("POL") {
                arrayToolState.withChosenKind(.polar)
            } else {
                commandMessage = "ARRAY — type R (rectangular) or P (polar)"
                return
            }
            pendingArrayEntry = .field
            commandMessage = arrayToolState.prompt
        case .field:
            applyPendingArrayFieldEntry(trimmed)
        case nil:
            break
        }
    }

    private func applyPendingArrayFieldEntry(_ trimmed: String) {
        guard let field = arrayToolState.pendingField else {
            // No field left to fill (e.g. a stray submission after the
            // sequence already completed via bare Enter) — treat as
            // "commit now" so nothing is silently swallowed.
            commitArrayFromCurrentFields()
            return
        }
        // Empty input accepts the current default silently; a non-numeric
        // value where a number is expected re-prompts rather than crashing.
        func acceptInt(_ body: (Int) -> Void) -> Bool {
            guard !trimmed.isEmpty else { return true }
            guard let v = Int(trimmed) else {
                commandMessage = "ARRAY — expected a whole number"
                return false
            }
            body(v)
            return true
        }
        func acceptDouble(_ body: (Double) -> Void) -> Bool {
            guard !trimmed.isEmpty else { return true }
            guard let v = Double(trimmed) else {
                commandMessage = "ARRAY — expected a number"
                return false
            }
            body(v)
            return true
        }
        switch field {
        case .rows:
            guard acceptInt({ arrayToolState.rows = max(1, $0) }) else { return }
        case .columns:
            guard acceptInt({ arrayToolState.columns = max(1, $0) }) else { return }
        case .rowSpacing:
            guard acceptDouble({ arrayToolState.rowSpacing = $0 }) else { return }
        case .columnSpacing:
            guard acceptDouble({ arrayToolState.columnSpacing = $0 }) else { return }
        case .axisAngle:
            guard acceptDouble({ arrayToolState.axisAngleDeg = $0 }) else { return }
            commitArrayFromCurrentFields()
            return
        case .count:
            guard acceptInt({ arrayToolState.count = max(1, $0) }) else { return }
        case .fillAngle:
            guard acceptDouble({ arrayToolState.fillAngleDeg = $0 }) else { return }
        case .rotateItems:
            if !trimmed.isEmpty {
                let upper = trimmed.uppercased()
                if upper == "Y" || upper == "YES" { arrayToolState.rotateItems = true }
                else if upper == "N" || upper == "NO" { arrayToolState.rotateItems = false }
                else { commandMessage = "ARRAY — type Y or N"; return }
            }
            commitArrayFromCurrentFields()
            return
        }
        arrayToolState.advanceField()
        commandMessage = arrayToolState.prompt
    }

    /// Commits (or re-generates, for Edit Array) the array from whatever
    /// field values `arrayToolState` currently holds — reachable both by
    /// finishing the field sequence naturally (the LAST field's handler
    /// above) and by a bare Enter mid-sequence (AutoCAD: Enter at any point
    /// accepts every remaining default and commits immediately).
    private func commitArrayFromCurrentFields() {
        guard let regen, !arrayToolState.objectIDs.isEmpty else { cancelArray(); return }
        let sourceIDs = Array(arrayToolState.objectIDs)
        let kindParams: ArrayDefinition.Kind
        switch arrayToolState.kind {
        case .rectangular:
            kindParams = .rectangular(rows: arrayToolState.rows, cols: arrayToolState.columns,
                                      rowSpacing: arrayToolState.rowSpacing, colSpacing: arrayToolState.columnSpacing,
                                      axisAngle: arrayToolState.axisAngleDeg)
        case .polar:
            let center = arrayToolState.polarCenter ?? boundsCenter(of: sourceIDs, store: regen.parsed.store)
            kindParams = .polar(center: ArrayDefinition.CodableVec2(center), count: arrayToolState.count,
                                fillAngle: arrayToolState.fillAngleDeg, rotateItems: arrayToolState.rotateItems)
        case .path:
            commandMessage = "ARRAY (path) — not yet supported; use rectangular or polar"
            cancelArray()
            return
        }
        var def: ArrayDefinition?
        let editingAnchor = arrayToolState.editingExistingAnchor
        session.performEdit("Array") { tx in
            let store = regen.parsed.store
            if let editingAnchor, let oldDef = session.arrays[editingAnchor] {
                def = ArrayTool.regenerate(oldDef, sourceIDs: sourceIDs, newKindParams: kindParams, store: store, tx: tx)
            } else {
                switch kindParams {
                case .rectangular(let rows, let cols, let rowSpacing, let colSpacing, let axisAngle):
                    def = ArrayTool.commitRectangular(sourceIDs: sourceIDs, rows: rows, cols: cols,
                                                      rowSpacing: rowSpacing, colSpacing: colSpacing,
                                                      axisAngleDeg: axisAngle, store: store, tx: tx)
                case .polar(let center, let count, let fillAngle, let rotateItems):
                    def = ArrayTool.commitPolar(sourceIDs: sourceIDs, center: center.cgPoint, count: count,
                                                fillAngleDeg: fillAngle, rotateItems: rotateItems, store: store, tx: tx)
                case .path:
                    break
                }
            }
            guard let def else { return }
            // `session.arrays` lives outside `EntityStore`/`Transaction`'s
            // own undo system (a plain dictionary keyed by EntityID, same
            // shape as `session.regions` / `parsed.blocks`) — registered as
            // a side effect so ⌘Z after ARRAY removes the association
            // exactly when the member entities themselves are un-created,
            // mirroring `BlockEditor.createBlock`'s identical pattern.
            let anchor = editingAnchor ?? sourceIDs[0]
            let previousDef = editingAnchor.flatMap { session.arrays[$0] }
            tx.registerSideEffect(
                undo: { session.arrays[anchor] = previousDef },
                redo: { session.arrays[anchor] = def })
            session.arrays[anchor] = def
        }
        if let def {
            session.lastCreatedEntities = Set(def.memberHandles)
            selection = Set(def.memberHandles)
            commandMessage = "Array — \(def.memberHandles.count) object(s)"
        } else {
            commandMessage = "Array — could not create (empty selection or unsupported kind)"
        }
        cancelArray()
    }

    private func boundsCenter(of ids: [EntityID], store: EntityStore) -> CGPoint {
        var result = CGRect.null
        for id in ids { result = result.union(store.bounds(id)) }
        guard !result.isNull else { return .zero }
        return CGPoint(x: result.midX, y: result.midY)
    }

    /// Live ghost-preview cells for the canvas overlay — capped per
    /// `ArrayTool.maxPreviewCells`. Returns `(sourceId, transform)` pairs so
    /// the overlay can look up each source's OWN ghost shape (mirroring
    /// `modifyGhostEntities`'s existing per-entity ghost-shape convention)
    /// rather than a single shared shape.
    private var arrayPreviewCells: [(source: EntityID, transform: Transform2)] {
        guard arrayToolState.phase == .pickFields, !arrayToolState.objectIDs.isEmpty, let regen else { return [] }
        let sourceIDs = Array(arrayToolState.objectIDs)
        var result: [(source: EntityID, transform: Transform2)] = []
        switch arrayToolState.kind {
        case .rectangular:
            let transforms = ArrayTool.previewRectangular(rows: arrayToolState.rows, cols: arrayToolState.columns,
                                                           rowSpacing: arrayToolState.rowSpacing,
                                                           colSpacing: arrayToolState.columnSpacing,
                                                           axisAngleDeg: arrayToolState.axisAngleDeg)
            for id in sourceIDs {
                for t in transforms where result.count < ArrayTool.maxPreviewCells { result.append((id, t)) }
            }
        case .polar:
            let center = arrayToolState.polarCenter ?? boundsCenter(of: sourceIDs, store: regen.parsed.store)
            for id in sourceIDs {
                let b = regen.parsed.store.bounds(id)
                let anchor = CGPoint(x: b.midX, y: b.midY)
                let transforms = ArrayTool.previewPolar(anchor: anchor, center: center, count: arrayToolState.count,
                                                        fillAngleDeg: arrayToolState.fillAngleDeg,
                                                        rotateItems: arrayToolState.rotateItems)
                for t in transforms where result.count < ArrayTool.maxPreviewCells { result.append((id, t)) }
            }
        case .path:
            break
        }
        return result
    }

    /// `arrayPreviewCells`'s transforms, realized into actual `DrawnEntity`
    /// ghosts via `ghostShape(for:store:)` — the `[DrawnEntity]` shape
    /// `DXFCanvasView.arrayGhost` (and every other ghost-preview field in
    /// this file) expects. Cell 0 (`t == .identity`) is skipped — it's the
    /// ORIGINAL source entity, already visible as ordinary document
    /// content, so ghosting it again would just double-draw a highlight
    /// with no new information (matches `createArray`'s own "cell 0 reuses
    /// the source, never re-copied" convention).
    private var arrayGhostEntities: [DrawnEntity] {
        guard let regen else { return [] }
        let store = regen.parsed.store
        var result: [DrawnEntity] = []
        for (source, t) in arrayPreviewCells {
            guard t != .identity, let h = store.header(source), !h.flags.contains(.deleted) else { continue }
            guard let shape = ghostShape(for: source, store: store) else { continue }
            var e = DrawnEntity(shape: shape)
            e.aci = h.aci == 256 ? 7 : Int(h.aci)
            e.isPaper = h.owner.isPaper
            result.append(e.transformed(by: t))
        }
        return result
    }

    // MARK: - CLAYER (Phase 6.3 — CurrentProperties)

    private func startClayerEntry() {
        pendingClayerEntry = true
        commandMessage = "CLAYER — enter new current layer name <\(currentProperties.layerName)>"
    }

    private func applyPendingClayerEntry(_ input: String) {
        pendingClayerEntry = false
        let trimmed = input.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { commandMessage = ""; return }
        currentProperties.layerName = trimmed
        commandMessage = "CLAYER — current layer is now \"\(trimmed)\""
    }

    /// Layers panel's "+ New Layer" button. Unlike CLAYER (which only
    /// RENAMES `currentProperties.layerName` — the layer itself is created
    /// lazily, the first time an entity is actually drawn on it, via
    /// `CurrentProperties.resolvedLayerId`), this creates a real, empty
    /// layer immediately, via the SAME `MarkupStore.ensureLayer` find-or-
    /// create helper.
    ///
    /// `DXFDocument.layers` is a snapshot built once by `Regenerator.build`
    /// (see `MarkupStore.ensureMarkupLayer`'s doc comment: "unlike
    /// modelGroups/paperGroups... there is no append-a-layer-after-load
    /// path") — `ensureLayer` alone would create the layer in
    /// `parsed.layers` but leave it invisible to the Layers panel (which
    /// reads `document.layers`) until some UNRELATED future edit happened
    /// to trigger a `fullRebuild()`. Calling `fullRebuild()` here directly
    /// resyncs `document` from `parsed` immediately, reusing the same
    /// mechanism block redefinition already relies on for the same class of
    /// "structural metadata changed" resync — a multi-second cost on the
    /// full 731MB production file, but this is a deliberate, rare user
    /// action, not a hot path.
    private func createLayer(named rawName: String) {
        guard let regen else { return }
        let name = rawName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        if let existingId = regen.parsed.layerIdByName[name] {
            visibility.sessionCreatedLayerIds.insert(Int(existingId))
            visibility.hiddenLayerIds.remove(Int(existingId))
            commandMessage = "Layer \"\(name)\" already exists"
            return
        }
        let id = MarkupStore.ensureLayer(named: name, in: regen.parsed)
        regen.fullRebuild()
        visibility.sessionCreatedLayerIds.insert(Int(id))
        commandMessage = "Created layer \"\(name)\""
    }

    /// Layer Properties — sets an EXISTING layer's default color, undoably.
    /// Mutates `parsed.layers[layerId].color` directly (the true, persistent
    /// per-document layer table — `DXFDocument.layers` is an immutable `let`
    /// snapshot rebuilt FROM this, never mutated in place) via
    /// `session.performStructuralEdit`, which calls `regen.fullRebuild()`
    /// unconditionally afterward — the ONLY way a layer-table color change
    /// reaches already-baked `RenderGroup`s, since BYLAYER (ACI 256) color
    /// is resolved to a concrete `ResolvedColor` once, at build time
    /// (`Regenerator.resolve`), not live at draw time. Every BYLAYER-colored
    /// entity on this layer picks up the new color automatically — no
    /// per-entity edit needed. Saving already round-trips this for free:
    /// `DXFTablesEmitter.writeLayerTable` emits straight from
    /// `parsed.layers[i].color`.
    private func setLayerColor(_ layerId: Int, to newColor: ResolvedColor) {
        guard let regen, layerId >= 0, layerId < regen.parsed.layers.count else { return }
        let oldColor = regen.parsed.layers[layerId].color
        guard oldColor != newColor else { return }
        let name = regen.parsed.layers[layerId].name
        session.performStructuralEdit("Layer Color") { tx in
            regen.parsed.layers[layerId].color = newColor
            tx.registerSideEffect(
                undo: { regen.parsed.layers[layerId].color = oldColor },
                redo: { regen.parsed.layers[layerId].color = newColor })
        }
        commandMessage = "Changed layer \"\(name)\" color"
    }

    /// "Layer Settings…" transparency slider — sets a layer's AutoCAD-style
    /// 0-100% transparency, undoably, as one structural edit (mirrors
    /// `setLayerColor` above exactly: same `performStructuralEdit`/
    /// `registerSideEffect` shape, since a layer-table mutation isn't
    /// expressible as an ordinary `EntityStore` op and needs a full rebuild
    /// to reach `CGRenderCore.fillAlpha`'s per-frame lookup). Clamped to
    /// 0...100 here — the ONE place this codebase enforces that range, since
    /// `DXFLayer.transparency` itself is a plain unvalidated `Double` (see its
    /// own doc comment).
    private func setLayerTransparency(_ layerId: Int, to newValue: Double) {
        guard let regen, layerId >= 0, layerId < regen.parsed.layers.count else { return }
        let clamped = min(max(newValue, 0), 100)
        let oldValue = regen.parsed.layers[layerId].transparency
        guard abs(oldValue - clamped) > 1e-9 else { return }
        let name = regen.parsed.layers[layerId].name
        session.performStructuralEdit("Layer Transparency") { tx in
            regen.parsed.layers[layerId].transparency = clamped
            tx.registerSideEffect(
                undo: { regen.parsed.layers[layerId].transparency = oldValue },
                redo: { regen.parsed.layers[layerId].transparency = clamped })
        }
        commandMessage = "Changed layer \"\(name)\" transparency to \(Int(clamped.rounded()))%"
    }

    /// "Delete Layer" (Layers panel context menu) — deletes every currently-
    /// alive entity on `layerId`, undoably, as one transaction.
    ///
    /// Layer RECORDS themselves are append-only in this codebase's model
    /// (`parsed.layers`/`layerIdByName` — every entity header's `layerId` is
    /// a bare array index, so removing an entry would silently reassign
    /// every subsequent layer's id/index and corrupt every entity that
    /// references one), so this scopes to "delete every object on the
    /// layer," matching how an emptied layer already behaves in AutoCAD
    /// (it stays in the layer table, invisible/unused, until a separate
    /// PURGE) — a `Delete Layer` action producing an empty-but-still-listed
    /// layer is expected, not a bug.
    ///
    /// Uses `RegenCoordinator.entityIDsOnLayer` (a direct scan of
    /// `parsed.store.headers`), NOT a walk of `document.modelGroups`/
    /// `paperGroups` — the latter only contains entities the render walk
    /// actually reached, which misses content of a never-instantiated block
    /// definition. This is precisely the robust, reachability-independent
    /// deletion path the "I can't find/delete this layer's objects" bug
    /// report called for.
    private func deleteLayer(_ layerId: Int) {
        guard let regen, layerId >= 0, layerId < regen.parsed.layers.count else { return }
        let name = regen.parsed.layers[layerId].name
        let ids = regen.entityIDsOnLayer(Int32(layerId))
        guard !ids.isEmpty else {
            commandMessage = "Layer \"\(name)\" has no objects to delete"
            return
        }
        session.performEdit("Delete Layer") { tx in
            for id in ids { tx.delete(id) }
        }
        commandMessage = "Deleted \(ids.count) object(s) from layer \"\(name)\""
    }

    /// "Shade Layer" (Layers panel context menu) — fills every closed shape
    /// currently on `layerId` (closed LWPOLYLINE/POLYLINE2D, CIRCLE, or
    /// full-sweep ELLIPSE, per `ShadeLayer.closedLoop`'s scope) with `style`,
    /// as real, persistent HATCH/LINE entities placed on an auto-created
    /// `NOVACAD-SHADE-<layer>` layer. Fully undoable (an ordinary
    /// `Transaction` of `.add`/`.delete` ops — no `registerSideEffect`
    /// needed, unlike layer-color edits, since this only touches ordinary
    /// EntityStore content). See `ShadeLayer.swift` for the full design
    /// rationale (why a dedicated layer rather than an in-place overlay,
    /// why nested shapes are shaded independently, etc).
    private func shadeLayer(_ layerId: Int, style: ShadeStyle) {
        guard let regen, layerId >= 0, layerId < regen.parsed.layers.count else { return }
        var result: ShadeLayer.Result?
        session.performEdit("Shade Layer") { tx in
            result = ShadeLayer.apply(toLayer: Int32(layerId), style: style, in: regen.parsed, tx: tx)
        }
        guard let result else { return }
        if result.shapesShaded == 0 {
            commandMessage = "Shade Layer — no closed shapes found on this layer"
        } else {
            let styleLabel = style == .solid ? "solid" : "crosshatch"
            var msg = "Shaded \(result.shapesShaded) shape(s) (\(styleLabel))"
            if result.crosshatchTruncated { msg += " — some hatching truncated (very large shape)" }
            commandMessage = msg
        }
    }

    private func worldToView() -> CGAffineTransform {
        var t = CGAffineTransform.identity
        t = t.translatedBy(x: pan.width, y: pan.height)
        t = t.scaledBy(x: zoom, y: -zoom)   // DXF is y-up; view is y-down
        t = t.translatedBy(x: -bounds.midX, y: -bounds.midY)
        return t
    }

    // MARK: - Loading

    private func handleExternalDrawingSaved(_ savedURL: URL) {
        guard let doc = document, !isLoading else { return }
        // Don't reload the tab that just saved itself.
        if doc.sourceDXFURL?.standardizedFileURL == savedURL.standardizedFileURL { return }
        let savedPath = savedURL.standardizedFileURL.path
        let referencesSavedFile = doc.xrefs.contains { x in
            x.loadedPath == savedPath || x.sourcePath == savedPath
        }
        if referencesSavedFile {
            commandMessage = "Reloading xrefs after saving \(savedURL.lastPathComponent)…"
            reloadDocument()
        }
    }

    /// Re-opens the current source from disk, picking up edits to the drawing
    /// and its xref files, while preserving the view, markup, and layer state.
    private func reloadDocument() {
        guard let url = currentSourceURL, let doc = document, !isLoading else { return }
        func names(_ ids: Set<Int>) -> Set<String> {
            Set(ids.compactMap { $0 < doc.layers.count ? doc.layers[$0].name : nil })
        }
        let xrefNames = Set(visibility.hiddenXrefIds.compactMap { id in
            doc.xrefs.first { $0.id == id }?.blockName
        })
        // Capture markup from the OLD store as plain [DrawnEntity] — a
        // reload re-parses the file from disk into a brand-new EntityStore
        // that naturally has no markup yet; `applyDocument` re-commits this
        // into the FRESH store below (see MarkupStore.swift).
        reloadRestore = ReloadSnapshot(zoom: zoom, pan: pan, space: space,
                                       hiddenLayerNames: names(visibility.hiddenLayerIds),
                                       lockedLayerNames: names(visibility.lockedLayerIds),
                                       hiddenXrefNames: xrefNames, drawn: currentDrawnMarkup)
        openFile(url: url)
    }

    /// Opens the xref's edit target in a new tab. NovaCAD edits/saves DXF; for
    /// DWG xrefs this opens the cached/converted DXF that the host drawing is
    /// actually rendering. Saving that tab posts a notification; host tabs whose
    /// xrefs point at the saved file auto-reload.
    private func openXrefInNewTab(_ xref: XrefInfo) {
        guard let doc = document else { return }
        let target = doc.xrefs
            .filter { $0.sourceDrawingKey == xref.sourceDrawingKey }
            .compactMap { info -> URL? in
                if !info.loadedPath.isEmpty { return URL(fileURLWithPath: info.loadedPath) }
                if !info.sourcePath.isEmpty { return URL(fileURLWithPath: info.sourcePath) }
                return nil
            }
            .first
        guard let target else {
            alertMessage = "Could not locate the source file for \(xref.blockName). Use Set Xref Path… first."
            return
        }
        onOpenInNewTab(target)
    }

    private func openFile(url: URL) {
        isLoading = true
        loadProgress = 0
        loadingXrefName = nil
        loadingXrefIndex = 0
        loadingXrefTotal = 0
        loadCancelRequested = false
        session.persistWorkspace()
        session.checkpointRecovery()
        currentSourceURL = url
        let recovery = session.pendingRecovery
        let scoped = url.startAccessingSecurityScopedResource()
        Task.detached(priority: .userInitiated) {
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                // RegenCoordinator.loadPackage handles plain files, folders,
                // and eTransmit ZIPs exactly like the old PackageLoader.load
                // did (same xref resolution, same DWG conversion), but
                // parses into an editable EntityStore and pre-registers the
                // NOVACAD-MARKUP layer instead of the old render-only path.
                //
                // `isCancelled` reads the cancel flag via a synchronous hop
                // back to the main actor: `DocumentSession` (and this
                // view's `session`) are MainActor-isolated, but
                // `PackageLoader.loadIntoStore`'s `isCancelled` closure is
                // called from this `Task.detached` background context and
                // polled only between coarse stages (not in a hot loop —
                // see that function's own doc comment), so blocking
                // briefly for `MainActor.run` here is cheap and correct
                // rather than racing a nonisolated read of a `@Published`
                // property. `xrefProgress` hops to the main actor per-tick
                // the same way, matching the existing bare-fraction
                // `progress` callback below.
                let coordinator = try RegenCoordinator.loadPackage(
                    url: url,
                    isCancelled: {
                        DispatchQueue.main.sync { session.loadCancelRequested }
                    },
                    xrefProgress: { xp in
                        Task { @MainActor in
                            loadingXrefName = xp.fileName
                            loadingXrefIndex = xp.fileIndex
                            loadingXrefTotal = xp.fileTotal
                        }
                    }
                ) { p in
                    Task { @MainActor in loadProgress = p }
                }
                if let directories = WorkspaceStore.load(url).resourceDirectories {
                    coordinator.parsed.resourceDirectories = directories + coordinator.parsed.resourceDirectories
                    coordinator.fullRebuild()
                }
                if let recovery {
                    coordinator.parsed.resourceDirectories = recovery.resourceDirectories
                    coordinator.fullRebuild()
                }
                await MainActor.run { applyDocument(coordinator) }
            } catch PackageLoadStoreError.cancelled {
                // User-initiated abort via the loading overlay's Cancel
                // button — not an error, so no alert. Silently returns to
                // the pre-open state.
                await MainActor.run {
                    isLoading = false
                    loadCancelRequested = false
                    reloadRestore = nil
                }
            } catch {
                await MainActor.run {
                    isLoading = false
                    reloadRestore = nil   // don't taint the next unrelated open
                    alertMessage = (error as? LocalizedError)?.errorDescription
                        ?? "Failed to open file: \(error.localizedDescription)"
                }
            }
        }
    }

    @MainActor
    private func applyDocument(_ coordinator: RegenCoordinator) {
        let doc = coordinator.document
        isLoading = false
        session.regen = coordinator
        session.savedRevision = coordinator.parsed.document.revision
        session.lastRecoveryRevision = nil
        session.recoveryID = UUID()
        session.recoveryGeneration += 1
        session.recoveryStatus = ""
        let recovery = session.pendingRecovery
        session.pendingRecovery = nil
        session.recoveredDocument = recovery != nil
        session.recoveredFromID = recovery?.id
        if let recovery { currentSourceURL = recovery.sourceURL; session.recoveryStatus = "Recovered copy — use Save As" }
        if let url = currentSourceURL {
            session.presets = WorkspaceStore.load(url).presets
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        }
        session.markupLayerId = coordinator.parsed.layerIdByName[MarkupStore.layerName]
        selection = []
        propertiesMinimized = false
        measure = MeasureState()
        draft = DraftState()
        moveState = MoveState()
        modifyState = ModifyToolState(command: .copy)
        trimExtendState = TrimExtendToolState(command: .trim)
        filletChamferState = FilletChamferToolState(command: .fillet)
        offsetState = OffsetToolState()
        dimensionToolState = DimensionToolState()
        // Phase 6.1/6.2 states — an adversarial review found these were
        // missing here: File > Reload is reachable mid-BLOCK/EXPLODE/
        // ATTDEF (only gated on currentSourceURL/isLoading, not on any
        // modal-tool check), and without this reset a leftover
        // `blockToolState`/`explodeAwaitingSelection` would hold stale
        // `EntityID`s from the JUST-DISCARDED store. Since `EntityID` is a
        // bare array-slot index, those stale ids are likely to resolve to
        // real-but-WRONG entities in the newly-loaded document — the next
        // canvas click would silently continue the old BLOCK/EXPLODE/
        // ATTDEF flow against unrelated geometry, corrupting the
        // just-reloaded file with no error shown.
        blockToolState = BlockToolState(command: .block)
        xrefAttachToolState = XrefAttachToolState()
        clipboardPasteToolState = ClipboardPasteToolState()
        gripDragState = GripDragState()
        stretchState = StretchToolState()
        session.aiAssistant = AIAssistantSession()
        explodeAwaitingSelection = false
        joinAwaitingSelection = false
        awaitingAttEditPick = false
        awaitingAttdefPlacement = false
        pendingBlockEntry = nil
        pendingAttdefEntry = nil
        // Phase 6.3: CLAYER/CECOLOR/CELTYPE/etc. reset to their defaults on
        // every load/reload — a stale CLAYER naming a layer from the
        // PREVIOUSLY loaded document would otherwise silently resurrect
        // (via `CurrentProperties.resolvedLayerId`'s find-or-CREATE
        // behavior) an empty layer of that name in the newly loaded
        // document the moment any Phase 6.3 tool is used, which is exactly
        // the class of "new tool state not reset by applyDocument" bug this
        // project's adversarial-review process has caught repeatedly this
        // session (see this function's own block/explode-state comment
        // above for the precedent).
        currentProperties = CurrentProperties()
        session.regions = [:]
        session.arrays = [:]
        pendingArrayEntry = nil
        pendingClayerEntry = false
        pendingEllipseRotationAngle = false
        arrayToolState = ArrayToolState()
        selectionPrompt = nil
        eraseCandidate = nil
        commandMessage = ""
        halo = nil
        animationTimer?.invalidate()
        closeSearch()
        searchIndex = SearchIndex(document: doc, store: coordinator.parsed.store)
        // Layers marked off/frozen in the file start hidden, like AutoCAD.
        visibility = VisibilityState(
            hiddenLayerIds: Set(doc.layers.filter { $0.isOffByDefault || $0.isFrozen }.map(\.id)),
            hiddenXrefIds: [])
        layerSearch = ""
        space = doc.modelGroups.isEmpty && (!doc.paperGroups.isEmpty || !coordinator.parsed.paperLayouts.isEmpty) ? .paper : .model

        // Unresolved xrefs are already flagged per-row (orange) in the
        // External References panel (LayersPanel), but that's easy to miss
        // on first open — a package-level summary here makes it impossible
        // to silently lose xref content without at least one visible
        // notice. Two distinct causes get two distinct messages, checked in
        // priority order (most actionable/alarming first):
        //   1. `xrefMergeCapped` — the package hit `storeMaxMergedEntities`/
        //      `storeMaxXrefFiles` and one or more xrefs were skipped SOLELY
        //      because of that safety cap (not a missing source file). This
        //      is the "silently truncated a legitimately huge factory
        //      layout" case Phase 3 exists to stop being silent.
        //   2. Otherwise, if any xref simply couldn't find its source file
        //      (moved/renamed/not included in this eTransmit), a plain
        //      count — the per-row orange flag already tells the user WHICH
        //      ones; this just makes sure at least one of them notices.
        let unresolvedCount = doc.xrefs.filter { !$0.isResolved }.count
        if doc.modelGroups.isEmpty && doc.paperGroups.isEmpty && doc.modelImages.isEmpty && doc.paperImages.isEmpty && doc.paperViewports.isEmpty && coordinator.parsed.paperLayouts.isEmpty {
            alertMessage = "No supported entities found in the file."
        } else if doc.stats.truncated {
            alertMessage = "Drawing was very large; some entities were omitted for performance."
        } else if coordinator.parsed.xrefMergeCapped {
            alertMessage = "This drawing's external references exceeded NovaCAD's size limit — "
                + "one or more xrefs were left unresolved. Check the External References panel "
                + "(orange entries) for which ones."
        } else if unresolvedCount > 0 {
            let noun = unresolvedCount == 1 ? "external reference" : "external references"
            alertMessage = "\(unresolvedCount) \(noun) could not be found and " +
                "\(unresolvedCount == 1 ? "was" : "were") not loaded. Check the External " +
                "References panel, or use \u{201c}Set Xref Path\u{2026}\u{201d} to relink."
        }

        if let r = reloadRestore {
            // Reload: keep the user's view, markup, and layer/xref state, mapping
            // the saved names onto the reloaded drawing's (possibly renumbered) ids.
            reloadRestore = nil
            var v = VisibilityState()
            v.hiddenLayerIds = Set(doc.layers.filter { r.hiddenLayerNames.contains($0.name) }.map(\.id))
            v.lockedLayerIds = Set(doc.layers.filter { r.lockedLayerNames.contains($0.name) }.map(\.id))
            v.hiddenXrefIds = Set(doc.xrefs.filter { r.hiddenXrefNames.contains($0.blockName) }.map(\.id))
            visibility = v
            if r.space == .model || !doc.paperGroups.isEmpty { space = r.space }
            zoom = r.zoom
            pan = r.pan
            // Re-commit the captured markup into the FRESH store. One
            // transaction per shape (mirroring `commitDrawn`) rather than a
            // single giant one — keeps this consistent with how markup is
            // normally added, and any single malformed shape can't abort the
            // whole restore.
            if !r.drawn.isEmpty, let markupLayerId = session.markupLayerId {
                for e in r.drawn {
                    session.performEdit("Draw") { tx in
                        _ = tx.add(MarkupStore.prototype(for: e, layerId: markupLayerId, store: coordinator.parsed.store))
                    }
                }
            }
            commandMessage = "Reloaded \(currentSourceURL?.lastPathComponent ?? "drawing")"
        } else {
            fitToView()
        }
        let remembered = recovery?.workspace ?? currentSourceURL.flatMap { WorkspaceStore.load($0).lastView }
        if let remembered { _ = session.restoreWorkspace(remembered) }
        if recovery != nil { session.scheduleRecovery() }
    }

    // MARK: - View transforms

    private func fitToView() {
        fit(to: bounds)
    }

    /// Fit always includes all rendered content, including complete text bounds.
    private func fitButtonPressed() { fit(to: fullBounds) }

    private func fitZoom(for target: CGRect) -> CGFloat {
        guard target.width > 0, target.height > 0,
              viewSize.width > 0, viewSize.height > 0 else { return zoom }
        let z = min(viewSize.width / target.width, viewSize.height / target.height) * 0.92
        return max(1e-9, min(z, 1e9))
    }

    private func fit(to target: CGRect) {
        animationTimer?.invalidate()
        guard target.width > 0, target.height > 0,
              viewSize.width > 0, viewSize.height > 0 else { return }
        zoom = fitZoom(for: target)
        // Keep the transform's reference point at `bounds` center; offset the pan
        // so the requested rect is centered.
        let dx = (bounds.midX - target.midX) * zoom
        let dy = (bounds.midY - target.midY) * zoom
        pan = CGSize(width: viewSize.width / 2 + dx,
                     height: viewSize.height / 2 - dy)   // view y is flipped
    }

    private func zoomAtCenter(by factor: CGFloat) {
        zoomAt(point: CGPoint(x: viewSize.width / 2, y: viewSize.height / 2), by: factor)
    }

    private func zoomAt(point: CGPoint, by factor: CGFloat) {
        animationTimer?.invalidate()
        let newZoom = max(1e-9, min(zoom * factor, 1e9))
        let k = newZoom / zoom
        pan = CGSize(width: point.x + k * (pan.width - point.x),
                     height: point.y + k * (pan.height - point.y))
        zoom = newZoom
    }
}

extension Color {
    init(rgb: UInt32) {
        self.init(red: Double((rgb >> 16) & 0xFF) / 255,
                  green: Double((rgb >> 8) & 0xFF) / 255,
                  blue: Double(rgb & 0xFF) / 255)
    }
}
