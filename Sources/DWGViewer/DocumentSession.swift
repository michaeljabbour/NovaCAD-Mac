import SwiftUI
import CADCore
import Foundation
import Combine

/// View/markup snapshot restored after a Reload so it doesn't reset.
struct ReloadSnapshot {
    var zoom: CGFloat
    var pan: CGSize
    var space: SpaceSelection
    // Captured by NAME so restore survives layer-table reordering on reload.
    var hiddenLayerNames: Set<String>
    var lockedLayerNames: Set<String>
    var hiddenXrefNames: Set<String>
    /// Markup captured from the OLD store as plain [DrawnEntity] (see
    /// MarkupStore.drawnEntities) — a Reload re-parses the file from disk
    /// into a brand-new EntityStore that naturally contains no markup yet,
    /// so this is how markup survives a reload, same as it always has (only
    /// the capture/restore MECHANISM changed — old code captured `drawn`
    /// directly; new code reads it back out of the store first).
    var drawn: [DrawnEntity]
}

/// Owns the state of one open drawing: the document itself, view transform,
/// selection, active tool, markup, and deep-search state. One instance per
/// window (each ContentView owns its own `@StateObject`, so multiple windows
/// stay independent).
///
/// Phase 1.7 live cutover: `document: DXFDocument?` (render-only, replaced
/// wholesale on every edit) is now `regen: RegenCoordinator?` — the editable,
/// incrementally-regenerable session (`EntityStore` + undo/redo + the render
/// model it keeps patched in place). `document` survives as a computed proxy
/// so the large amount of existing view code reading `document.foo` needs no
/// changes. `selection` is `Set<EntityID>` (stable identity) instead of
/// `Set<EntityRef>` (positional) — per the plan, "HitTester resolves
/// internally positional -> EntityID via the new entityId fields." Markup
/// (`drawn`/`selectedMarkup`) is retired: it's ordinary EntityStore content
/// on the NOVACAD-MARKUP layer now, selected/rendered/hit-tested exactly like
/// any other entity.
///
/// `RegenCoordinator` is a plain class (not `ObservableObject`) by design —
/// avoiding whole-document `@Published` copies is the entire point of
/// incremental regen. Every mutating operation on the document MUST go
/// through `performEdit`/`undo`/`redo` below, which explicitly call
/// `objectWillChange.send()` after patching `regen` in place, so SwiftUI
/// still redraws correctly despite `regen` itself (the object reference)
/// never being reassigned by an edit.
@MainActor
final class DocumentSession: ObservableObject {
    @Published var presets: [WorkspacePreset] = []
    @Published var recoveryStatus = ""
    @Published var workspaceError: String?
    var pendingWorkspace: DrawingWorkspace?
    var pendingRecovery: RecoveryEntry?
    var savedRevision: UInt64 = 0
    var lastRecoveryRevision: UInt64?
    var recoveredDocument = false
    var recoveredFromID: UUID?
    var layerUsageCache: (ObjectIdentifier, UInt64, SpaceSelection, [Int: LayerUsage])?
    var recoveryID = UUID()
    var recoveryGeneration = 0
    var recoveryTask: Task<Void, Never>?
    private var persistenceObservers = Set<AnyCancellable>()

    init() {
        DocumentSessionRegistry.sessions.add(self)
        Publishers.Merge4($zoom.map { _ in () }, $pan.map { _ in () },
                          $visibility.map { _ in () }, $space.map { _ in () })
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.persistWorkspace() }
            .store(in: &persistenceObservers)
        Timer.publish(every: 30, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.checkpointRecovery() }
            .store(in: &persistenceObservers)
    }

    @Published var regen: RegenCoordinator?
    /// Render-only view of the current document — unchanged call shape for
    /// the ~50+ existing `document.foo` reads in ContentView/DXFCanvasView.
    var document: DXFDocument? { regen?.document }
    /// The editable entity database + undo/redo stacks backing `regen`.
    var editableDocument: EditableDocument? { regen?.parsed.document }
    /// Stable layer id for user-drawn markup, valid for the lifetime of the
    /// current `regen` (set by `applyDocument` right after
    /// `MarkupStore.ensureMarkupLayer` runs, pre-load).
    var markupLayerId: Int32?

    @Published var visibility = VisibilityState()
    @Published var space: SpaceSelection = .model
    @Published var zoom: CGFloat = 1.0
    @Published var pan: CGSize = .zero
    @Published var viewSize: CGSize = .zero

    /// Stable-identity selection — survives undo/redo/compaction, unlike a
    /// positional `EntityRef`. Includes markup (drawn/stamped entities),
    /// which is just another kind of EntityStore content now.
    @Published var selection: Set<EntityID> = []
    @Published var draft = DraftState()
    @Published var measure = MeasureState()
    @Published var moveState = MoveState()
    /// Phase 4.2: COPY/ROTATE/SCALE/MIRROR state — see `ModifyToolState.swift`
    /// for why this is a NEW type alongside `moveState` rather than a
    /// generalization of it. `.command` is meaningless while `.idle`
    /// (defaults to `.copy` purely so the struct has SOME initial value;
    /// callers must check `modifyState.isActive` before reading `.command`).
    @Published var modifyState = ModifyToolState(command: .copy)
    /// Phase 4.3: TRIM/EXTEND state — see `TrimExtendToolState.swift` for why
    /// this is ANOTHER new, parallel type alongside `modifyState`/`moveState`
    /// rather than folded into either (the click-loop-per-target interaction
    /// shape doesn't fit `ModifyToolState`'s "acquire once, transform as a
    /// batch" shape). `.command` is meaningless while `.idle` (defaults to
    /// `.trim` purely so the struct has SOME initial value).
    @Published var trimExtendState = TrimExtendToolState(command: .trim)
    /// Phase 4.4: FILLET/CHAMFER state — see `FilletChamferToolState.swift`
    /// for why this is a third parallel type alongside `modifyState`/
    /// `trimExtendState`.
    @Published var filletChamferState = FilletChamferToolState(command: .fillet)
    /// CHAMFER's own distance/angle parameters, persisted across
    /// invocations within a session (matching FILLETRAD's own sysvar
    /// persistence) — not registered as separate named SysVars since the
    /// plan's Phase 0.6 sysvar list doesn't name them individually (only
    /// FILLETRAD/TRIMMODE/EDGEMODE/OFFSETDIST); plain published fields here
    /// are the additive, non-invasive choice consistent with "don't invent
    /// a separate ad hoc persistence mechanism" while not overreaching into
    /// SysVars.swift for names the plan never specified.
    @Published var chamferD1: Double = 1.0
    @Published var chamferD2: Double = 1.0
    @Published var chamferAngleDeg: Double = 45.0
    @Published var chamferUsesAngle: Bool = false
    /// Phase 4.5: OFFSET state.
    @Published var offsetState = OffsetToolState()
    /// DIMENSION (linear/aligned) tool state.
    @Published var dimensionToolState = DimensionToolState()
    /// Phase 6.1: BLOCK/INSERT state — see `BlockToolState.swift` for why
    /// this is a fourth parallel type alongside `modifyState`/
    /// `trimExtendState`/`filletChamferState` rather than folded into any
    /// of them (BLOCK/INSERT operate on block DEFINITIONS/NAMES, not an
    /// ambient object selection being transformed in place).
    @Published var blockToolState = BlockToolState(command: .block)
    /// "Attach Xref…" state — mirrors `blockToolState`'s own "own parallel
    /// tool-state type" convention (see `XrefAttachToolState.swift`'s header
    /// comment). `@Published` for the same reason as every other tool
    /// state here: `performEdit`/`applyDocument` mutate it and SwiftUI must
    /// see the change.
    @Published var xrefAttachToolState = XrefAttachToolState()
    /// "Paste" (cross-drawing Copy/Paste) placement state — see
    /// `ClipboardPasteToolState.swift`'s header comment. Same rationale as
    /// `xrefAttachToolState` immediately above.
    @Published var clipboardPasteToolState = ClipboardPasteToolState()
    /// Grip editing's single-grip drag/hover state — see
    /// `GripDragState.swift`'s header comment. Unlike every OTHER tool
    /// state above, this is NOT a typed command reachable via
    /// `CommandParser`; it's a direct-manipulation interaction active
    /// whenever exactly one grip-editable entity is selected and no other
    /// modal tool is running (`ContentView` gates entry on that
    /// precondition, mirroring how `moveState`/`modifyState` gate on
    /// `selection` before `startMove`/`startModify`).
    @Published var gripDragState = GripDragState()
    /// STRETCH's interactive state — see `StretchToolState.swift`'s header
    /// comment for why it's a separate type from `TrimExtendToolState`/
    /// `ModifyToolState` (crossing-window VERTEX acquisition, not
    /// whole-entity acquisition).
    @Published var stretchState = StretchToolState()
    /// AI Assistant conversation state for this drawing tab — see
    /// `AIAssistantSession`'s own header comment for why this IS
    /// `ObservableObject` (unlike `regen`) despite the "one @Published
    /// reference to a plain class" pattern every other tool-state field
    /// here follows. Reset to a fresh session on every `applyDocument` (see
    /// that function) — a reload/new file starts a clean conversation, same
    /// as every other per-document tool-state field.
    @Published var aiAssistant = AIAssistantSession()
    /// Phase 6.3: CLAYER/CECOLOR/CELTYPE/CELTSCALE/current-text-style — see
    /// `CurrentProperties.swift`'s header comment for the "old markup tools
    /// unchanged, new Phase 6.3 tools honor this fully" scope decision.
    /// Reset on every `applyDocument` (see that function) so a reload/new
    /// file starts back at NOVACAD-MARKUP/BYLAYER, matching how every other
    /// per-document tool-state field here resets on load.
    @Published var currentProperties = CurrentProperties()
    /// Phase 6.3: REGION's session-side "this entity is a region" tags —
    /// see `RegionTool.swift`'s header comment for why this is a plain
    /// dictionary rather than new geometry. Reset on every `applyDocument`
    /// (a reload's fresh `EntityStore` renumbers `EntityID`s, so any prior
    /// mapping would point at unrelated post-reload entities).
    @Published var regions: [EntityID: RegionRecord] = [:]
    /// Phase 6.4: ARRAY's associativity side-table (`db.arrays` per the
    /// plan) — `sourceHandles`/`memberHandles` inside each `ArrayDefinition`
    /// are `EntityID`s, so (like `regions` above) this is rebuilt empty on
    /// every reload rather than attempting to remap ids across a renumbering.
    /// Existing ARRAYDEF XDATA on member entities (see `ArrayTool.swift`)
    /// is NOT re-parsed back into this table on load — this session-side
    /// table is a LIVE editing convenience ("Edit Array" needs the
    /// definition to regenerate from), not the on-disk source of truth,
    /// exactly like `EditableBlockDef` isn't reconstructed from a
    /// just-loaded INSERT's own transform either.
    @Published var arrays: [EntityID: ArrayDefinition] = [:]
    /// Phase 6.4: ARRAY's interactive state — see `ArrayToolState.swift`
    /// for why this is a fifth parallel type alongside `modifyState`/
    /// `trimExtendState`/`filletChamferState`/`blockToolState` rather than
    /// folded into any of them (ARRAY gathers a SEQUENCE of command-bar
    /// field values, a shape none of the existing tool-state types have).
    @Published var arrayToolState = ArrayToolState()
    /// Phase 6.2: EXPLODE's acquisition state — a plain boolean (not a full
    /// state-machine type like the others above) because EXPLODE has NO
    /// geometric parameter phase after acquiring its objects: PICKFIRST
    /// (non-empty `selection`) commits immediately with no further UI
    /// interaction at all; an empty selection starts the SAME shared
    /// `SelectionPrompt` acquisition every other command uses, and
    /// `.done` commits immediately too — there is no intervening phase to
    /// go stale across an undo/redo the way `modifyState.objectIDs` can,
    /// since the objects are used and the tool resets to idle within the
    /// same synchronous call.
    @Published var explodeAwaitingSelection = false
    /// JOIN (new feature) — the same "acquire a selection set, then commit
    /// in one synchronous call" shape as `explodeAwaitingSelection` above
    /// (see its doc comment for why neither needs a full state-machine
    /// type): true while JOIN is running its shared `SelectionPrompt`
    /// acquisition; a PICKFIRST invocation (non-empty selection) skips
    /// acquisition and commits immediately without ever setting this.
    @Published var joinAwaitingSelection = false
    /// Phase 4.1: the live "Select objects:" acquisition loop while a modify
    /// command's `modifyState.phase == .selecting` — nil whenever no modify
    /// command is actively collecting a fresh selection (PICKFIRST-invoked
    /// commands never populate this at all, since they skip `.selecting`
    /// entirely). Reused as-is by TRIM/EXTEND's boundary-acquisition step
    /// (`trimExtendState.phase == .selectingBoundaries`) — one shared prompt
    /// field serves both, since only one of `modifyState`/`trimExtendState`
    /// is ever active at a time.
    @Published var selectionPrompt: SelectionPrompt?
    /// `P` (Previous) token support: the selection set as it stood the last
    /// time a modify command completed (committed OR cancelled) — mirrors
    /// AutoCAD's "Previous" selection-set memory. Updated by
    /// `DocumentSession`'s modify-command completion path, not read
    /// speculatively elsewhere.
    @Published var previousSelection: Set<EntityID> = []
    /// `L` (Last) token support: the ids of the most recently
    /// added/duplicated entities (COPY's output, or any future command that
    /// creates new entities) — mirrors AutoCAD's "Last" selection-set memory.
    @Published var lastCreatedEntities: Set<EntityID> = []

    // Deep search
    @Published var searchIndex: SearchIndex?
    @Published var searchVisible = false
    @Published var searchQuery = ""
    @Published var searchResults: [SearchHit] = []
    @Published var searchCursor = -1
    @Published var halo: SearchHalo?

    // File load
    @Published var isLoading = false
    @Published var loadProgress: Double = 0.0
    /// Current xref file name being merged, for the loading overlay — nil
    /// outside the xref-resolution stage (parse/conversion stages just show
    /// the bare percentage). See `PackageLoader.XrefProgress`'s doc comment:
    /// added so a large multi-xref package's loading bar visibly moves and
    /// names which file it's on, instead of appearing frozen for however
    /// long one large xref takes to merge.
    @Published var loadingXrefName: String?
    @Published var loadingXrefIndex: Int = 0
    @Published var loadingXrefTotal: Int = 0
    /// Set by the Cancel button on the loading overlay; polled by
    /// `PackageLoader.loadIntoStore`'s `isCancelled` closure between
    /// coarse stages (zip extract, DWG batch conversion, each xref file).
    /// Reset to false at the start of every `openFile`.
    @Published var loadCancelRequested = false
    @Published var alertMessage: String?
    /// The URL the current document was opened from (for Reload).
    @Published var currentSourceURL: URL?
    @Published var reloadRestore: ReloadSnapshot?

    /// Set by DocumentTabsView when it creates a new tab for "open in a new
    /// tab" — that tab's ContentView doesn't exist yet to call openFile()
    /// itself, so it picks this up in its own `.onAppear` once it does.
    @Published var pendingOpenURL: URL?

    // MARK: - Editing (Phase 1.7)
    //
    // Every mutation of the live document funnels through these three
    // methods so `objectWillChange.send()` and `RegenCoordinator.apply`/
    // `fullRebuild` are never forgotten at a call site — ContentView's
    // drafting/move/erase/stamp code calls these instead of touching
    // `regen`/`editableDocument` directly.

    /// Runs `body` as one undoable transaction against the live document,
    /// then incrementally patches the render model to match. `body` returns
    /// the ids of any entities it ADDED, which are folded into `selection`
    /// when `selectNewEntities` is true (the drafting tools' "select what I
    /// just drew" behavior — AutoCAD does NOT auto-select freshly drawn
    /// markup, so callers that want the old "just drawn, not yet selected"
    /// feel pass `selectNewEntities: false`, which is every current call
    /// site; the parameter exists for future commands that DO want it, e.g.
    /// paste).
    @discardableResult
    func performEdit(_ name: String, selectNewEntities: Bool = false,
                     _ body: (Transaction) -> Void) -> [EntityID] {
        guard let regen, let doc = editableDocument else { return [] }
        let revisionBefore = doc.revision
        let tx = doc.begin(name)
        body(tx)
        doc.commit(tx)
        // A transaction that touched nothing is dropped silently by `commit`
        // (see Transactions.swift) — nothing to apply/select in that case.
        guard doc.revision != revisionBefore, let entry = doc.undoStack.last else {
            return []
        }
        regen.apply(entry.ops)
        var added: [EntityID] = []
        for op in entry.ops { if case .add(let id) = op { added.append(id) } }
        if selectNewEntities, !added.isEmpty { selection = Set(added) }
        objectWillChange.send()
        scheduleRecovery()
        return added
    }

    /// Sibling to `performEdit` for edits that mutate STRUCTURAL, non-
    /// `EntityStore` state (e.g. the layer table's color, `parsed.layers`) —
    /// exclusively via `Transaction.registerSideEffect`, with NO entity
    /// `Op`s at all. `regen.apply(entry.ops)` (what `performEdit` calls)
    /// only knows how to patch render groups from entity-level `Op`s and
    /// would be a no-op here since there are none; a `fullRebuild()` is the
    /// only way such a change reaches the already-built `RenderGroup`s (same
    /// reasoning as `undo()`/`redo()` below, and the existing `createLayer`
    /// precedent this generalizes into an undoable form). Every
    /// `Transaction` `body` passed here MUST call `tx.registerSideEffect`
    /// for its forward mutation to be undoable — a body that only mutates
    /// `parsed.layers` directly with no side effect registered will still
    /// visually apply (this function unconditionally calls `fullRebuild()`
    /// after committing) but won't be reversible by `undo()`.
    func performStructuralEdit(_ name: String, _ body: (Transaction) -> Void) {
        guard let regen, let doc = editableDocument else { return }
        let revisionBefore = doc.revision
        let tx = doc.begin(name)
        body(tx)
        doc.commit(tx)
        guard doc.revision != revisionBefore else { return }
        regen.fullRebuild()
        objectWillChange.send()
        scheduleRecovery()
    }

    /// Undo one transaction. `EditableDocument.undo()` mutates the
    /// `EntityStore` directly (inverse-image application), bypassing
    /// `Transaction`/its op list — so, same as `EditScriptRunner`'s
    /// documented approach, there is no incremental delta to hand
    /// `RegenCoordinator.apply`; a full rebuild is the correctness-preserving
    /// choice (see EditScriptRunner.swift's `reconcileAfterUndoRedo` for the
    /// detailed rationale, which applies identically here). Stale selection
    /// (referring to an entity undo just deleted, e.g. undoing an add) is
    /// dropped, matching how a real UI clears selection it can no longer
    /// show properties for.
    func undo() {
        guard let regen, let doc = editableDocument, !doc.undoStack.isEmpty else { return }
        doc.undo()
        regen.fullRebuild()
        selection = selection.filter { !regen.parsed.store.isDeleted($0) }
        pruneStaleToolObjectIDs()
        objectWillChange.send()
        scheduleRecovery()
    }

    func redo() {
        guard let regen, let doc = editableDocument, !doc.redoStack.isEmpty else { return }
        doc.redo()
        regen.fullRebuild()
        selection = selection.filter { !regen.parsed.store.isDeleted($0) }
        pruneStaleToolObjectIDs()
        objectWillChange.send()
        scheduleRecovery()
    }

    /// Phase 4.2: an in-progress Move/Copy/Rotate/Scale/Mirror gesture keeps
    /// its OWN snapshot of the objects it's transforming
    /// (`moveState.objectIDs`/`modifyState.objectIDs`), separate from
    /// `selection` — an undo/redo triggered mid-gesture (⌘Z, or "U"/"UNDO"
    /// typed while e.g. ROTATE is at `.pickAngle`) can delete/recreate the
    /// very entities that snapshot references, same as it already can for
    /// `selection` above. Dropping now-dead ids here (rather than aborting
    /// the whole gesture) mirrors `selection`'s own "drop what's gone,
    /// keep going with what's left" behavior — a command already committed
    /// against N objects that ends up applying to N-1 after an intervening
    /// undo is a reasonable, non-crashing outcome; leaving a stale id
    /// pointing at a deleted (or since-different) entity was the actual gap
    /// (Transaction.modifyPayload/copyTransformed already silently skip a
    /// non-resolving id, so this is a "don't let it silently under-apply
    /// without saying so" polish, not a crash fix) flagged by adversarial
    /// review. Called from both undo() and redo() since either direction
    /// can equally invalidate ids the gesture is holding.
    private func pruneStaleToolObjectIDs() {
        guard let regen else { return }
        moveState.objectIDs = moveState.objectIDs.filter { !regen.parsed.store.isDeleted($0) }
        modifyState.objectIDs = modifyState.objectIDs.filter { !regen.parsed.store.isDeleted($0) }
        trimExtendState.boundaryIDs = trimExtendState.boundaryIDs.filter { !regen.parsed.store.isDeleted($0) }
        // Phase 6.1: BLOCK's own in-flight object set can go stale the same
        // way modifyState's does (an undo/redo mid-command can delete/
        // restore the very entities BLOCK is about to blockify) — same
        // filter, same rationale, added here per this file's own documented
        // "don't let it silently under-apply without saying so" precedent.
        blockToolState.objectIDs = blockToolState.objectIDs.filter { !regen.parsed.store.isDeleted($0) }
        // Phase 6.4: ARRAY's own in-flight object set can go stale the same
        // way BLOCK's/modifyState's does — same filter, same rationale.
        arrayToolState.objectIDs = arrayToolState.objectIDs.filter { !regen.parsed.store.isDeleted($0) }
        // FILLET/CHAMFER's `firstTargetId` and OFFSET's `objectId` are
        // single optional ids, not sets — filtering doesn't apply the same
        // way, so an undo/redo that deletes/restores the underlying entity
        // instead resets the tool back to its own "pick the first/only
        // object" phase, matching the Set-based fields' effect (never leave
        // a stale id referencing a since-deleted entity). Previously
        // missing entirely — an adversarial review found only moveState/
        // modifyState/trimExtendState were pruned here.
        if let id = filletChamferState.firstTargetId, regen.parsed.store.isDeleted(id) {
            filletChamferState.resetForNextCorner()
        }
        if let id = offsetState.objectId, regen.parsed.store.isDeleted(id) {
            offsetState.resetForNextObject()
        }
        // Edit Array's anchor (the existing array entity being re-edited)
        // is a single optional id keyed to one specific entity, same shape
        // as `firstTargetId`/`objectId` above — if an undo/redo deletes it
        // out from under an in-progress Edit Array session, the whole
        // session no longer refers to anything real, so reset it back to
        // idle entirely (there's no "next corner"/"next object" phase to
        // fall back to the way FILLET/OFFSET have). Previously missing —
        // found by adversarial review, same pattern as the two cases above.
        if let anchor = arrayToolState.editingExistingAnchor, regen.parsed.store.isDeleted(anchor) {
            arrayToolState = ArrayToolState()
        }
    }

    var canUndo: Bool { !(editableDocument?.undoStack.isEmpty ?? true) }
    var canRedo: Bool { !(editableDocument?.redoStack.isEmpty ?? true) }
}

/// App-wide preferences persisted across launches. Backed by UserDefaults
/// directly (not @AppStorage — that property wrapper relies on SwiftUI's
/// per-View `DynamicProperty` update mechanism for change notification, which
/// doesn't fire when it's embedded in a plain ObservableObject) via `didSet`,
/// so views observing this object still get correct SwiftUI invalidation.
@MainActor
final class AppSettings: ObservableObject {
    /// 1 = fastest, 5 = superb.
    @Published var renderQuality: Int {
        didSet { UserDefaults.standard.set(renderQuality, forKey: "renderQualityLevel") }
    }
    @Published var unitSystemRaw: String {
        didSet { UserDefaults.standard.set(unitSystemRaw, forKey: "unitSystem") }
    }
    @Published var lengthStyleRaw: String {
        didSet { UserDefaults.standard.set(lengthStyleRaw, forKey: "lengthStyle") }
    }
    @Published var unitPrecision: Int {
        didSet { UserDefaults.standard.set(unitPrecision, forKey: "unitPrecision") }
    }
    /// ACI color new markup is drawn in.
    @Published var markupColor: Int {
        didSet { UserDefaults.standard.set(markupColor, forKey: "markupColorACI") }
    }

    init() {
        let d = UserDefaults.standard
        renderQuality = (d.object(forKey: "renderQualityLevel") as? Int) ?? 3
        unitSystemRaw = d.string(forKey: "unitSystem") ?? UnitSystem.asDrawn.rawValue
        lengthStyleRaw = d.string(forKey: "lengthStyle") ?? LengthStyle.decimal.rawValue
        unitPrecision = (d.object(forKey: "unitPrecision") as? Int) ?? 2
        markupColor = (d.object(forKey: "markupColorACI") as? Int) ?? 1
    }
}
