import CADCore
import SwiftUI

/// One right-click context-menu row; a `nil` action renders as a separator.
struct ContextMenuAction {
    let title: String
    let action: (() -> Void)?
    init(title: String, action: (() -> Void)? = nil) {
        self.title = title
        self.action = action
    }
    static let separator = ContextMenuAction(title: "", action: nil)
}

/// Wraps a closure as an NSObject so it survives NSMenuItem.representedObject.
private final class ContextMenuActionBox: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
}

/// AppKit-backed canvas: shows the latest rasterized frame, transforming it on
/// the fly during pan/zoom so interaction never waits on a full redraw.
struct DXFCanvasView: NSViewRepresentable {
    /// Quality level used during gestures (pan/zoom). Lower = much faster.
    static let lowQualityLevel = 1
    let document: DXFDocument
    let params: RenderParams
    var measure = MeasureState()
    var dimension = DimensionToolState()
    var draft = DraftState()
    var move = MoveState()
    /// Phase 4.2: COPY/ROTATE/SCALE/MIRROR state — drives the same
    /// box-select-enabling/ghost-preview machinery as `move` above, for the
    /// 4 commands that use `ModifyToolState` instead of `MoveState`.
    var modify = ModifyToolState(command: .copy)
    /// STRETCH state — like `modify`, box-select stays ENABLED while
    /// `.selecting` (STRETCH's crossing-window acquisition gesture) but is
    /// suppressed during `.pickingBase`/`.pickingDestination` (plain point
    /// picks, same as `modify`'s later phases), via `selectModeActive`'s own
    /// `modify.phase == .selecting`-style carve-out below.
    var stretch = StretchToolState()
    /// Live dashed preview of the Move tool's selection at the candidate
    /// destination — transient screen-space overlay only (see
    /// `ContentView.moveGhostEntities`), unrelated to the retired markup
    /// array/overlay pass below.
    var moveGhost: [DrawnEntity] = []
    /// Phase 4.2: same role as `moveGhost`, generalized to an arbitrary
    /// `Transform2` (see `ContentView.modifyGhostEntities`).
    var modifyGhost: [DrawnEntity] = []
    /// Phase 4.2 MIRROR: the mirror line's two endpoints (world space), or
    /// nil when not applicable — drawn as a distinct dashed reference line,
    /// separate from `modifyGhost`.
    var modifyMirrorLine: (CGPoint, CGPoint)? = nil
    /// Phase 6.4: ARRAY's live ghost preview — every cell's already-
    /// transformed outline (see `ContentView.arrayGhostEntities`), capped at
    /// `ArrayTool.maxPreviewCells` per the plan. Same role/shape as
    /// `modifyGhost` (pre-transformed by ContentView, drawn as a plain
    /// dashed overlay here) — a SEPARATE field rather than reusing
    /// `modifyGhost` since both can't be meaningfully active at once but
    /// keeping them distinct avoids any accidental cross-tool bleed if that
    /// ever changed.
    var arrayGhost: [DrawnEntity] = []
    /// STRETCH's live ghost preview — every affected entity reshaped by the
    /// candidate delta (see `ContentView.stretchGhostEntities`), same
    /// "ContentView precomputes, this view just draws" split as every other
    /// ghost field above; a separate field for the same "don't risk cross-
    /// tool bleed" reasoning as `arrayGhost`.
    var stretchGhost: [DrawnEntity] = []
    /// Erase tool's hover-highlight shape (Phase 1.7): the CURRENT geometry
    /// of whatever markup entity the Erase tool is hovering, precomputed by
    /// `ContentView` (which has the `EntityStore` this view doesn't) — the
    /// markup entity itself renders as part of the NORMAL bitmap via
    /// `RegenCoordinator`/`CGRenderCore` now, not a separate overlay pass;
    /// this is only the yellow highlight drawn on TOP of it while hovering,
    /// before a click deletes it. `nil` when nothing is being hovered.
    var eraseCandidateShape: DrawnEntity.Shape? = nil
    /// Phase 4.3: TRIM/EXTEND's hover-highlight — the CURRENT geometry of
    /// whatever entity the cursor is over while `trimExtendState.phase ==
    /// .pickingTargets`, precomputed by `ContentView` (same role/reuse
    /// pattern as `eraseCandidateShape`) so this view doesn't need direct
    /// `EntityStore` access.
    var trimExtendHoverShape: DrawnEntity.Shape? = nil
    /// Same role as `trimExtendHoverShape`, covering FILLET/CHAMFER/OFFSET.
    var filletChamferOffsetHoverShape: DrawnEntity.Shape? = nil
    var stampGhost: [DrawnEntity] = []
    var markupColorACI = 1
    var halo: SearchHalo? = nil
    var measureFormat = MeasureFormat()
    /// Grip editing: every grip (world-space) of the single currently
    /// grip-editable selected entity — precomputed by `ContentView` (which
    /// has the `EntityStore` this view doesn't), same pattern as
    /// `eraseCandidateShape`/`trimExtendHoverShape` above. Empty whenever
    /// grip display doesn't apply (no selection, multi-selection, or a
    /// non-grip-editable entity type — see `ContentView.gripDisplayPoints`).
    var gripPoints: [GripEditing.GripPoint] = []
    /// The single-grip drag/hover state — see `GripDragState.swift`.
    var gripDrag = GripDragState()
    /// Live preview shape for the entity being grip-dragged, recomputed by
    /// `ContentView` each hover tick from `gripDrag.hover`/`.snap` (same
    /// "ContentView precomputes geometry, this view just draws it" split as
    /// `moveGhost`/`modifyGhost`).
    var gripDragGhost: DrawnEntity.Shape? = nil

    let onScrollZoom: (_ factor: CGFloat, _ location: CGPoint) -> Void
    let onPan: (_ delta: CGSize) -> Void
    let onClick: (_ location: CGPoint, _ shiftDown: Bool) -> Void
    /// Phase 6.1: location added so a double-click on an INSERT (plain
    /// select mode, no other gesture active) can open the attribute editor
    /// sheet per the plan's "double-click an INSERT with ATTRIBs opens it"
    /// spec text — every EXISTING caller of this closure
    /// (`handleFinishGesture`, for polyline/area-measurement completion)
    /// ignores the parameter entirely, so this is purely additive.
    let onDoubleClick: (_ location: CGPoint) -> Void
    let onHover: (_ location: CGPoint) -> Void
    let onEscape: () -> Void
    /// Return/Enter pressed while the canvas has keyboard focus.
    var onReturnKey: () -> Void = { }
    /// A rubber-band drag completed from `start` to `end` (view space).
    /// `mode` is L→R vs R→L already resolved (`.window`/`.crossing`) — see
    /// `InputView.resolvedBoxMode(from:to:)` — every caller acts on this
    /// resolved mode rather than re-deriving it, so the SAME rule (L→R =
    /// Window, R→L = Crossing) applies identically everywhere a drag
    /// completes, including the still-existing plain-select-mode call site
    /// (Phase 4.1 upgrades that from Window-only to mode-aware for free).
    var onBoxSelect: (_ start: CGPoint, _ end: CGPoint, _ mode: SelectionMode, _ shiftDown: Bool) -> Void = { _, _, _, _ in }
    /// Phase 4.1: Option+drag lasso completed — `points` are the sampled
    /// path in VIEW space (≥2px spacing, capped at 2048 points per the
    /// plan), `mode` resolved by the same L→R/R→L rule applied to the
    /// lasso's overall bounding-box drag direction.
    var onLassoSelect: (_ points: [CGPoint], _ mode: SelectionMode, _ shiftDown: Bool) -> Void = { _, _, _ in }
    /// Delete/Forward-Delete pressed with a selection active.
    var onDeleteSelection: () -> Void = { }
    /// Right-click at `location` — returns the actions to show in a context menu.
    var onContextMenu: (_ location: CGPoint) -> [ContextMenuAction] = { _ in [] }
    /// Grip editing: mouse-down at `location` — returns true (and begins a
    /// direct-manipulation drag) if it landed on a grip of the single
    /// grip-editable selected entity. Checked FIRST in `mouseDown`, ahead of
    /// the box-select/lasso/click machinery below — a plain `onClick`/
    /// `onBoxSelect` round trip can't distinguish "hit a grip, begin a
    /// drag" from "empty space, begin a rubber-band select" early enough
    /// (that decision has to happen before `mouseDragged` starts
    /// accumulating box-select state), which is why this is its own
    /// dedicated hook rather than reusing the click/drag closures above.
    var onGripMouseDown: (_ location: CGPoint) -> Bool = { _ in false }
    /// Grip editing: a drag tick while a grip drag begun by
    /// `onGripMouseDown` is in progress.
    var onGripDrag: (_ location: CGPoint) -> Void = { _ in }
    /// Grip editing: the drag ended (mouse-up) — commits the reshape.
    var onGripDragEnd: (_ location: CGPoint) -> Void = { _ in }

    /// When true the renderer drops to quality level 1 + 1× backing scale
    /// during user gestures (pan/zoom) for 4-10× faster rasterization —
    /// the frame is blitted back up to Retina by CoreGraphics. Cleared
    /// shortly after the last gesture event so the static view is crisp.
    var isDragging: Bool = false

    func makeNSView(context: Context) -> InputView {
        let v = InputView()
        v.coordinator = context.coordinator
        // Force synchronous redraw (rather than CA stretching the stale
        // backing store) during window/live-resize, and clip our own layer
        // to its bounds so a resize in flight can never visually paint past
        // this view's frame into sibling views (e.g. the toolbar above it).
        v.wantsLayer = true
        v.layerContentsRedrawPolicy = .duringViewResize
        v.layer?.masksToBounds = true
        context.coordinator.attach(view: v)
        return v
    }

    func updateNSView(_ nsView: InputView, context: Context) {
        context.coordinator.parent = self
        nsView.coordinator = context.coordinator
        nsView.currentParams = params
        nsView.measure = measure
        nsView.dimension = dimension
        nsView.draft = draft
        nsView.move = move
        nsView.modify = modify
        nsView.stretch = stretch
        nsView.moveGhost = moveGhost
        nsView.modifyGhost = modifyGhost
        nsView.modifyMirrorLine = modifyMirrorLine
        nsView.arrayGhost = arrayGhost
        nsView.stretchGhost = stretchGhost
        nsView.eraseCandidateShape = eraseCandidateShape
        nsView.trimExtendHoverShape = trimExtendHoverShape
        nsView.filletChamferOffsetHoverShape = filletChamferOffsetHoverShape
        nsView.stampGhost = stampGhost
        nsView.markupColorACI = markupColorACI
        nsView.halo = halo
        nsView.measureFormat = measureFormat
        nsView.isDragging = isDragging
        nsView.gripPoints = gripPoints
        nsView.gripDrag = gripDrag
        nsView.gripDragGhost = gripDragGhost
        context.coordinator.requestIfNeeded(document: document, params: params)
        nsView.needsDisplay = true
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator {
        var parent: DXFCanvasView
        let renderer = BitmapRenderer()
        private var lastRequested: RenderParams?
        private var lastDocument: ObjectIdentifier?
        private weak var view: InputView?

        /// Debounce: during rapid pan/zoom the delta-blit in `draw(_:)` handles
        /// the visual update; a full re-render is deferred until the camera has
        /// been still for this duration, saving the cost of re-rasterizing
        /// millions of primitives on every gesture tick.
        private static let renderDebounce: TimeInterval = 0.1
        private var renderDebounceTimer: Timer?

        init(parent: DXFCanvasView) {
            self.parent = parent
        }

        func attach(view: InputView) {
            self.view = view
            renderer.onFrame = { [weak self] frame in
                self?.view?.latestFrame = frame
                self?.view?.needsDisplay = true
            }
        }

        func requestIfNeeded(document: DXFDocument, params: RenderParams) {
            guard params.viewSize.width > 1, params.viewSize.height > 1 else { return }
            var p = params
            // The view's actual screen beats NSScreen.main (multi-display setups).
            if let scale = view?.window?.backingScaleFactor, scale > 0 {
                p.backingScale = scale
            }
            // During user gestures (pan/zoom) drop to 1× backing + quality 1
            // for 4-10× faster rasterization. The stale frame is blitted up to
            // Retina by CoreGraphics in `draw(_:)`; full quality resumes ~80ms
            // after the last gesture event.
            if view?.isDragging == true {
                p.backingScale = 1
                p.quality = DXFCanvasView.lowQualityLevel
            }
            let docID = ObjectIdentifier(document)
            guard p != lastRequested || docID != lastDocument else { return }
            lastRequested = p
            lastDocument = docID

            // If the ONLY difference between p and lastRequested is the camera
            // transform (worldToView/zoom/pan — a camera-only change during a
            // gesture), defer the full render so Stationary detail isn't wasted
            // on every pan tick. The view's `draw(_:)` already delta-blits the
            // latest frame, so visual feedback is smooth. Structural changes
            // (visibility, selection, quality, document revision) fire instantly.
            if view?.isDragging == true, isCameraOnlyChange(params, p) {
                renderDebounceTimer?.invalidate()
                renderDebounceTimer = Timer.scheduledTimer(withTimeInterval: Self.renderDebounce,
                                                            repeats: false) { [weak self] _ in
                    self?.renderer.request(document: document, params: p)
                }
                return
            }
            renderDebounceTimer?.invalidate()
            renderer.request(document: document, params: p)
        }

        /// True when the only difference between `from` and the already-stored
        /// `lastRequested` is the camera (worldToView / zoom / viewSize / backingScale)
        /// and optionally quality — things the delta-blit in `draw(_:)` handles
        /// visually without a full re-render. Anything affecting geometric content
        /// (visibility, selection, documentRevision, etc.) fires instantly.
        private func isCameraOnlyChange(_ from: RenderParams, _ to: RenderParams) -> Bool {
            // Stored lastRequested has the camera adjustments baked in already.
            guard let stored = lastRequested else { return false }
            return stored.selection == to.selection
                && stored.visibility == to.visibility
                && stored.documentRevision == to.documentRevision
                && stored.usePaperSpace == to.usePaperSpace
                && stored.renderNonce == to.renderNonce
                // Everything else (worldToView, zoom, pan, viewSize, backingScale,
                // quality) is camera/display — the blit handles it.
        }
    }

    // MARK: - AppKit input + blit view

    final class InputView: NSView {
        weak var coordinator: Coordinator?
        var currentParams = RenderParams()
        var latestFrame: RenderedFrame?
        var measure = MeasureState()
        var dimension = DimensionToolState()
        var draft = DraftState()
        var move = MoveState()
        var modify = ModifyToolState(command: .copy)
        var stretch = StretchToolState()
        var moveGhost: [DrawnEntity] = []
        var modifyGhost: [DrawnEntity] = []
        var modifyMirrorLine: (CGPoint, CGPoint)? = nil
        var arrayGhost: [DrawnEntity] = []
        var stretchGhost: [DrawnEntity] = []
        var eraseCandidateShape: DrawnEntity.Shape? = nil
        var trimExtendHoverShape: DrawnEntity.Shape? = nil
        var filletChamferOffsetHoverShape: DrawnEntity.Shape? = nil
        var stampGhost: [DrawnEntity] = []
        var markupColorACI = 1
        var gripPoints: [GripEditing.GripPoint] = []
        var gripDrag = GripDragState()
        var gripDragGhost: DrawnEntity.Shape? = nil
        var halo: SearchHalo? {
            didSet { if halo != oldValue { manageHaloTimer() } }
        }
        var measureFormat = MeasureFormat()
        private var haloTimer: Timer?
        /// Debounce timer: clears the "is dragging" quality-reduction flag
        /// ~80ms after the last gesture event.
        private static let gestureDebounce: TimeInterval = 0.08
        private static let lowQualityLevel = 1
        /// Current gesture-mode (low-quality) flag, read by the render-params
        /// builder to drop backing scale and quality during pan/zoom.
        var isDragging: Bool = false
        private var gestureTimer: Timer?

        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas { removeTrackingArea(area) }
            let opts: NSTrackingArea.Options = [.activeInKeyWindow, .mouseMoved, .inVisibleRect]
            addTrackingArea(NSTrackingArea(rect: .zero, options: opts, owner: self, userInfo: nil))
        }

        private func manageHaloTimer() {
            haloTimer?.invalidate()
            haloTimer = nil
            guard let halo, halo.until > Date() else { return }
            haloTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) {
                [weak self] t in
                guard let self else { t.invalidate(); return }
                self.needsDisplay = true
                if let h = self.halo, h.until <= Date() {
                    t.invalidate()
                    self.haloTimer = nil
                }
            }
        }

        // MARK: Input

        override func scrollWheel(with event: NSEvent) {
            kickGestureDebounce()
            let p = convert(event.locationInWindow, from: nil)
            if event.hasPreciseScrollingDeltas && !event.modifierFlags.contains(.option) {
                // Trackpad scroll pans (Option-scroll zooms).
                coordinator?.parent.onPan(CGSize(width: event.scrollingDeltaX,
                                                 height: event.scrollingDeltaY))
            } else {
                let delta = event.scrollingDeltaY
                guard delta != 0 else { return }
                coordinator?.parent.onScrollZoom(CGFloat(pow(1.003, Double(delta) * 4)), p)
            }
        }

        override func magnify(with event: NSEvent) {
            kickGestureDebounce()
            let p = convert(event.locationInWindow, from: nil)
            coordinator?.parent.onScrollZoom(1 + event.magnification, p)
        }

        /// Sets the low-quality dragging flag and schedules a debounce to
        /// restore full quality after gestures stop.
        private func kickGestureDebounce() {
            isDragging = true
            gestureTimer?.invalidate()
            gestureTimer = Timer.scheduledTimer(withTimeInterval: Self.gestureDebounce,
                                                repeats: false) { [weak self] _ in
                self?.isDragging = false
            }
        }

        private var lastDrag: NSPoint?
        private var mouseDownPoint: NSPoint?
        private var dragDistance: CGFloat = 0
        private var boxSelecting = false
        /// Phase 4.1: true when this drag started with Option held — a
        /// lasso instead of a rectangle. Latched at `mouseDown` (checking
        /// the CURRENT modifier flags at every `mouseDragged` tick would let
        /// the user switch modes mid-drag by pressing/releasing Option,
        /// which is confusing — AutoCAD-style tools commit to a gesture
        /// shape at the initial press).
        private var lassoActive = false
        /// Sampled lasso path in view space — appended to at >= 2px spacing
        /// per the plan's spec, capped at 2048 points (a runaway drag must
        /// not grow this unboundedly).
        private var lassoPoints: [CGPoint] = []
        private static let lassoMinSampleSpacing: CGFloat = 2
        private static let lassoMaxPoints = 2048
        /// Rubber-band rectangle in view space, drawn live while dragging.
        var marqueeRect: CGRect? = nil
        /// Live-resolved Window/Crossing for the CURRENT drag (recomputed on
        /// every `mouseDragged` tick per the plan's "recomputed live during
        /// the drag" spec) — nil before any real drag distance has
        /// accumulated. `DXFCanvasView`'s overlay-drawing code reads this to
        /// pick marquee color/style (blue solid = Window, green dashed =
        /// Crossing).
        var marqueeMode: SelectionMode? = nil
        private var lastMiddleDrag: NSPoint?
        /// Grip editing: true from a `mouseDown` that landed on a grip
        /// (`onGripMouseDown` returned true) through the matching
        /// `mouseUp` — while true, `mouseDragged`/`mouseUp` route to the
        /// grip-drag closures instead of the box-select/click machinery
        /// below, mirroring how `boxSelecting` latches for the duration of
        /// a rubber-band drag.
        private var gripDragActive = false

        /// True while a tool that consumes clicks as points is running — box
        /// select/lasso only make sense in plain Select mode OR while a
        /// modify command is actively acquiring objects (`.selecting`) —
        /// added in Phase 4.1 so COPY/ROTATE/SCALE/MIRROR's verb-first
        /// Select-objects: prompt gets the SAME box/lasso gestures plain
        /// Select mode already has, instead of a bespoke duplicate.
        private var selectModeActive: Bool {
            (!draft.isActive && !measure.isActive && !dimension.isActive && !move.isActive && !modify.isActive
                && !stretch.isActive)
                || modify.phase == .selecting || stretch.phase == .selecting
        }

        /// L→R drag = Window (AutoCAD convention: dragging left-to-right
        /// draws a solid box and selects only FULLY enclosed objects);
        /// R→L = Crossing (dashed box, selects anything touched). Compares
        /// the drag's start/end X only (Y direction is not part of AutoCAD's
        /// own convention either) — ties (perfectly vertical drag, dx == 0)
        /// default to Window, matching AutoCAD's own tie-break.
        static func resolvedBoxMode(from a: NSPoint, to b: NSPoint) -> SelectionMode {
            b.x >= a.x ? .window : .crossing
        }

        // NOTE (Phase 1.7): the old drag-to-move gesture (mouse-down on
        // markup begins a live drag that translates it in place) is retired
        // per the plan — markup is ordinary EntityStore content now and
        // moves via the same explicit two-click Move COMMAND (M / toolbar /
        // menu) as any other entity, which is unaffected by this. A plain
        // click still SELECTS markup exactly like any other object
        // (`onClick` below, unconditionally); dragging on empty space (or
        // now, on any object) always begins a rubber-band select.
        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
            let p = convert(event.locationInWindow, from: nil)
            lastDrag = p
            mouseDownPoint = p
            dragDistance = 0
            boxSelecting = false
            marqueeRect = nil
            marqueeMode = nil
            lassoActive = event.modifierFlags.contains(.option)
            lassoPoints = lassoActive ? [p] : []
            // Grip editing: only offered in plain select mode (mirrors
            // `selectModeActive` below) — checked BEFORE latching lasso/box
            // state so a grip hit never also arms a rubber-band drag.
            gripDragActive = selectModeActive && coordinator?.parent.onGripMouseDown(p) == true
        }
        override func mouseDragged(with event: NSEvent) {
            let p = convert(event.locationInWindow, from: nil)
            if gripDragActive {
                coordinator?.parent.onGripDrag(p)
                needsDisplay = true
                lastDrag = p
                return
            }
            if let last = lastDrag {
                let delta = CGSize(width: p.x - last.x, height: p.y - last.y)
                dragDistance += abs(delta.width) + abs(delta.height)
                if let down = mouseDownPoint, dragDistance >= 3, selectModeActive {
                    // Left-drag on empty space is a rubber-band select (or,
                    // with Option held at press time, a lasso); panning
                    // moved to the middle mouse button (see otherMouseDragged).
                    boxSelecting = true
                    if lassoActive {
                        if let lastPoint = lassoPoints.last {
                            let spacing = hypot(p.x - lastPoint.x, p.y - lastPoint.y)
                            if spacing >= Self.lassoMinSampleSpacing, lassoPoints.count < Self.lassoMaxPoints {
                                lassoPoints.append(p)
                            }
                        }
                        marqueeMode = Self.resolvedBoxMode(from: down, to: p)
                    } else {
                        marqueeRect = CGRect(x: min(down.x, p.x), y: min(down.y, p.y),
                                             width: abs(p.x - down.x), height: abs(p.y - down.y))
                        marqueeMode = Self.resolvedBoxMode(from: down, to: p)
                    }
                    needsDisplay = true
                }
            }
            lastDrag = p
        }
        override func mouseUp(with event: NSEvent) {
            if gripDragActive {
                let p = convert(event.locationInWindow, from: nil)
                coordinator?.parent.onGripDragEnd(p)
                gripDragActive = false
                lastDrag = nil
                mouseDownPoint = nil
                needsDisplay = true
                return
            }
            if boxSelecting, let down = mouseDownPoint {
                let p = convert(event.locationInWindow, from: nil)
                let mode = Self.resolvedBoxMode(from: down, to: p)
                if lassoActive, lassoPoints.count >= 3 {
                    coordinator?.parent.onLassoSelect(lassoPoints, mode, event.modifierFlags.contains(.shift))
                } else if !lassoActive {
                    coordinator?.parent.onBoxSelect(down, p, mode, event.modifierFlags.contains(.shift))
                }
                // lassoActive but < 3 sampled points (a very short Option-drag
                // that never accumulated enough spacing) intentionally
                // selects nothing — matches a degenerate plain box-drag's
                // existing "tiny rect still runs boxSelect, just catches
                // nothing" behavior closely enough that a dedicated no-op
                // path isn't warranted.
            } else if let down = mouseDownPoint, dragDistance < 3 {
                // A press that never really moved is a pick, not a drag.
                if event.clickCount >= 2 {
                    // >= 2: a triple-click's third mouseUp must not fall through
                    // to onClick and silently restart a finished measurement.
                    coordinator?.parent.onDoubleClick(down)
                } else {
                    coordinator?.parent.onClick(down, event.modifierFlags.contains(.shift))
                }
            }
            lastDrag = nil
            mouseDownPoint = nil
            boxSelecting = false
            marqueeRect = nil
            marqueeMode = nil
            lassoActive = false
            lassoPoints = []
            needsDisplay = true
        }

        // Middle mouse button (wheel click-and-hold) pans, freeing the left
        // button entirely for selection/move.
        override func otherMouseDown(with event: NSEvent) {
            guard event.buttonNumber == 2 else { super.otherMouseDown(with: event); return }
            lastMiddleDrag = convert(event.locationInWindow, from: nil)
        }
        override func otherMouseDragged(with event: NSEvent) {
            guard event.buttonNumber == 2, let last = lastMiddleDrag else {
                super.otherMouseDragged(with: event); return
            }
            let p = convert(event.locationInWindow, from: nil)
            coordinator?.parent.onPan(CGSize(width: p.x - last.x, height: p.y - last.y))
            lastMiddleDrag = p
        }
        override func otherMouseUp(with event: NSEvent) {
            guard event.buttonNumber == 2 else { super.otherMouseUp(with: event); return }
            lastMiddleDrag = nil
        }

        override func rightMouseDown(with event: NSEvent) {
            let p = convert(event.locationInWindow, from: nil)
            let items = coordinator?.parent.onContextMenu(p) ?? []
            guard !items.isEmpty else { return }
            window?.makeFirstResponder(self)
            let menu = NSMenu()
            for item in items {
                guard let action = item.action else { menu.addItem(.separator()); continue }
                let mi = NSMenuItem(title: item.title, action: #selector(contextMenuChosen(_:)),
                                    keyEquivalent: "")
                mi.target = self
                mi.representedObject = ContextMenuActionBox(action)
                menu.addItem(mi)
            }
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }

        @objc private func contextMenuChosen(_ sender: NSMenuItem) {
            (sender.representedObject as? ContextMenuActionBox)?.action()
        }

        override func mouseMoved(with event: NSEvent) {
            // Phase 4.2: `modify.isActive` MUST be included here — missing
            // it (as an earlier draft of this feature did) silently kills
            // ghost preview AND OSNAP for every ROTATE/SCALE/MIRROR/COPY
            // phase past the base point, since `onHover` below is the ONLY
            // call site that populates `modifyState.hover`/`.snap` at all.
            // Caught by adversarial review, not by any unit test (this is
            // exactly the same class of "missing call site" bug as the
            // Move-tool OSNAP `excluding:` regression from a prior session).
            // Grip editing: `!gripPoints.isEmpty` also lets `onHover` fire in
            // plain select mode (every OTHER branch here implies some modal
            // tool is active) so the hover-highlight grip can be computed
            // even though no other tool needs hover tracking at that moment.
            guard measure.isActive || dimension.isActive || draft.isActive || move.isActive || modify.isActive
                    || stretch.isActive || !gripPoints.isEmpty else { return }
            coordinator?.parent.onHover(convert(event.locationInWindow, from: nil))
        }

        override func keyDown(with event: NSEvent) {
            switch event.keyCode {
            case 53:  // Esc — also abandons an in-flight rubber-band drag
                cancelBoxSelect()
                coordinator?.parent.onEscape()
            case 36, 76:  // Return / Enter — finish a gesture, then focus the command bar
                coordinator?.parent.onReturnKey()
            case 51, 117:  // Delete / Forward-Delete — remove the selected
                            // object(s), original geometry or markup (see
                            // `ContentView.deleteSelection`).
                coordinator?.parent.onDeleteSelection()
            default:
                super.keyDown(with: event)
            }
        }

        /// Clears a rubber-band drag in progress so its marquee never gets
        /// stuck on screen if the gesture is abandoned (Esc, or the window/app
        /// losing key status before mouseUp fires).
        private func cancelBoxSelect() {
            guard boxSelecting || marqueeRect != nil else { return }
            boxSelecting = false
            marqueeRect = nil
            needsDisplay = true
        }

        override func resignFirstResponder() -> Bool {
            cancelBoxSelect()
            return super.resignFirstResponder()
        }

        // MARK: Drawing

        override func draw(_ dirtyRect: NSRect) {
            guard let ctx = NSGraphicsContext.current?.cgContext else { return }

            if currentParams.darkBackground {
                let (r, g, b) = CGRenderCore.darkBackgroundRGB
                ctx.setFillColor(CGColor(red: r, green: g, blue: b, alpha: 1))
            } else {
                ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            }
            ctx.fill(bounds)

            guard let frame = latestFrame else { return }

            // Map the frame (rendered at frame.worldToView) onto the current view
            // transform: delta = inverse(rendered) then current.
            let delta = frame.worldToView.inverted()
                .concatenating(currentParams.worldToView)

            ctx.saveGState()
            ctx.interpolationQuality = .none
            ctx.concatenate(delta)
            // Standard flipped-view image blit.
            ctx.translateBy(x: 0, y: frame.viewSize.height)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(frame.image, in: CGRect(origin: .zero, size: frame.viewSize))
            ctx.restoreGState()

            drawEraseCandidate(ctx)
            drawTrimExtendHover(ctx)
            drawFilletChamferOffsetHover(ctx)
            drawDraftPreview(ctx)
            drawMoveOverlay(ctx)
            drawModifyOverlay(ctx)
            drawArrayGhostOverlay(ctx)
            drawStretchGhostOverlay(ctx)
            drawGripsOverlay(ctx)
            drawMeasureOverlay(ctx)
            drawDimensionPreview(ctx)
            drawHalo(ctx)
            drawMarquee(ctx)
            drawLasso(ctx)
        }

        // MARK: Screen-space overlays

        private func toView(_ world: CGPoint) -> CGPoint {
            world.applying(currentParams.worldToView)
        }

        private func strokeShape(_ ctx: CGContext, _ shape: DrawnEntity.Shape) {
            switch shape {
            case .line(let a, let b):
                ctx.move(to: toView(a)); ctx.addLine(to: toView(b))
            case .polyline(let pts, let closed):
                guard let f = pts.first else { return }
                ctx.move(to: toView(f))
                for p in pts.dropFirst() { ctx.addLine(to: toView(p)) }
                if closed { ctx.closePath() }
            case .rect(let a, let b):
                let va = toView(a), vb = toView(b)
                ctx.addRect(CGRect(x: min(va.x, vb.x), y: min(va.y, vb.y),
                                   width: abs(vb.x - va.x), height: abs(vb.y - va.y)))
            case .circle(let c, let r):
                let vc = toView(c)
                let vr = r * currentParams.zoom
                ctx.addEllipse(in: CGRect(x: vc.x - vr, y: vc.y - vr,
                                          width: vr * 2, height: vr * 2))
            case .arc(let c, let r, let a1, let a2):
                let vc = toView(c)
                let vr = r * currentParams.zoom
                // View space is y-flipped relative to world: angles negate and
                // CCW world sweeps become clockwise screen sweeps.
                ctx.move(to: CGPoint(x: vc.x + vr * CoreGraphics.cos(-a1 * .pi / 180),
                                     y: vc.y + vr * CoreGraphics.sin(-a1 * .pi / 180)))
                ctx.addArc(center: vc, radius: vr,
                           startAngle: -a1 * .pi / 180, endAngle: -a2 * .pi / 180,
                           clockwise: true)
            case .text:
                break   // text is filled glyphs, drawn separately
            }
            ctx.strokePath()
        }

        /// Draws markup text; returns the on-screen bounding rect (for the
        /// selection box).
        @discardableResult
        private func drawMarkupText(_ ctx: CGContext, position: CGPoint, height: CGFloat,
                                    string: String, color: NSColor) -> CGRect {
            let capPx = max(height * currentParams.zoom, 1)
            let fontSize = min(max(capPx / 0.72, 4), 4000)   // cap height → point size
            let anchor = toView(position)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize),
                .foregroundColor: color
            ]
            let ns = string as NSString
            let size = ns.size(withAttributes: attrs)
            // DXF text baseline sits at the insertion point; in a flipped view the
            // glyphs extend upward from there (smaller y).
            let origin = CGPoint(x: anchor.x, y: anchor.y - size.height)
            ns.draw(at: origin, withAttributes: attrs)
            return CGRect(origin: origin, size: size)
        }

        /// Yellow hover-highlight for the Erase tool's current candidate,
        /// drawn on TOP of the normal bitmap (which already shows the
        /// entity itself — markup is ordinary EntityStore content rendered
        /// through the normal `RegenCoordinator`/`CGRenderCore` pipeline
        /// now, not a separate array/pass; this overlay only adds the
        /// "about to delete this" emphasis while hovering). Selection
        /// highlighting (the accent glow) is likewise no longer drawn here —
        /// `CGRenderCore.drawSelection` already highlights any selected
        /// entity, markup included, as part of the normal bitmap.
        private func drawEraseCandidate(_ ctx: CGContext) {
            guard let shape = eraseCandidateShape else { return }
            ctx.saveGState()
            ctx.setLineJoin(.round)
            ctx.setLineCap(.round)
            if case .text(let pos, let h, let str) = shape {
                drawMarkupText(ctx, position: pos, height: h, string: str, color: .systemYellow)
            } else {
                ctx.setLineWidth(3.2)
                ctx.setStrokeColor(NSColor.systemYellow.cgColor)
                strokeShape(ctx, shape)
            }
            ctx.restoreGState()
        }

        /// Phase 4.3: TRIM/EXTEND's hover highlight — same visual mechanism
        /// as `drawEraseCandidate` (thick colored outline over the hovered
        /// entity's current geometry) but in cyan/orange to read as "this is
        /// what TRIM/EXTEND would act on," distinct from Erase's yellow.
        private func drawTrimExtendHover(_ ctx: CGContext) {
            guard let shape = trimExtendHoverShape else { return }
            ctx.saveGState()
            ctx.setLineJoin(.round)
            ctx.setLineCap(.round)
            let color = NSColor.systemOrange
            if case .text(let pos, let h, let str) = shape {
                drawMarkupText(ctx, position: pos, height: h, string: str, color: color)
            } else {
                ctx.setLineWidth(3.2)
                ctx.setStrokeColor(color.cgColor)
                strokeShape(ctx, shape)
            }
            ctx.restoreGState()
        }

        /// Same visual mechanism as `drawTrimExtendHover`, for FILLET/
        /// CHAMFER/OFFSET — a distinct color (teal) so the three hover
        /// styles (Erase yellow, TRIM/EXTEND orange, this one) read as
        /// different tools at a glance.
        private func drawFilletChamferOffsetHover(_ ctx: CGContext) {
            guard let shape = filletChamferOffsetHoverShape else { return }
            ctx.saveGState()
            ctx.setLineJoin(.round)
            ctx.setLineCap(.round)
            let color = NSColor.systemTeal
            if case .text(let pos, let h, let str) = shape {
                drawMarkupText(ctx, position: pos, height: h, string: str, color: color)
            } else {
                ctx.setLineWidth(3.2)
                ctx.setStrokeColor(color.cgColor)
                strokeShape(ctx, shape)
            }
            ctx.restoreGState()
        }

        private func drawDraftPreview(_ ctx: CGContext) {
            guard draft.isActive else { return }
            let accent = NSColor(calibratedRed: 0.25, green: 0.66, blue: 1, alpha: 1)
            // Preview the shape in the color it will commit to (WYSIWYG); the
            // erase tool has no color, so fall back to accent there.
            let previewColor: NSColor
            if draft.mode == .erase {
                previewColor = accent
            } else {
                let rgb = ACIPalette.rgb(forACI: markupColorACI)
                previewColor = NSColor(calibratedRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                                       green: CGFloat((rgb >> 8) & 0xFF) / 255,
                                       blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
            }

            ctx.saveGState()
            ctx.setStrokeColor(previewColor.cgColor)
            ctx.setLineWidth(1.5)
            ctx.setLineDash(phase: 0, lengths: [5, 3])

            let pts = draft.points
            let hov = draft.snap?.point ?? draft.hover
            switch draft.mode {
            case .line, .polyline:
                var chain = pts.map(toView)
                if let h = hov { chain.append(toView(h)) }
                if chain.count >= 2 {
                    ctx.move(to: chain[0])
                    for p in chain.dropFirst() { ctx.addLine(to: p) }
                    ctx.strokePath()
                }
            case .circle:
                if let c = pts.first, let h = hov {
                    let r = hypot(h.x - c.x, h.y - c.y)
                    strokeShape(ctx, .circle(center: c, radius: r))
                }
            case .arc3pt:
                if pts.count == 2, let h = hov,
                   let g = DraftState.arcThroughGeometry(pts[0], pts[1], h) {
                    strokeShape(ctx, .arc(center: g.center, radius: g.radius, startDeg: g.startDeg, endDeg: g.endDeg))
                } else if pts.count == 1, let h = hov {
                    strokeShape(ctx, .line(a: pts[0], b: h))
                }
            case .rect:
                if let a = pts.first, let h = hov {
                    strokeShape(ctx, .rect(a: a, b: h))
                }
            case .polygon:
                if let c = pts.first, let h = hov,
                   let verts = DraftState.regularPolygonVertices(center: c, through: h, sides: draft.polygonSides) {
                    strokeShape(ctx, .polyline(pts: verts, closed: true))
                }
            case .text:
                // Crosshair at the cursor marks the text insertion point.
                if let h = hov {
                    let v = toView(h)
                    ctx.move(to: CGPoint(x: v.x - 7, y: v.y)); ctx.addLine(to: CGPoint(x: v.x + 7, y: v.y))
                    ctx.move(to: CGPoint(x: v.x, y: v.y - 7)); ctx.addLine(to: CGPoint(x: v.x, y: v.y + 7))
                    ctx.strokePath()
                }
            case .stamp:
                // Ghost of the block symbol at the cursor.
                for e in stampGhost { strokeShape(ctx, e.shape) }
            case .ellipse, .ellipseAxis:
                drawEllipsePreview(ctx, pts: pts, hover: hov, axisEndpointForm: draft.mode == .ellipseAxis,
                                   rotationMode: draft.ellipseRotationMode)
            case .splineFit, .splineCV:
                var chain = pts.map(toView)
                if let h = hov { chain.append(toView(h)) }
                if chain.count >= 2 {
                    ctx.move(to: chain[0])
                    for p in chain.dropFirst() { ctx.addLine(to: p) }
                    ctx.strokePath()
                }
                // Fit/control points themselves get a slightly larger marker
                // than the generic point markers below, drawn after those.
            case .pointEnt:
                if let h = hov {
                    let v = toView(h)
                    ctx.strokeEllipse(in: CGRect(x: v.x - 4, y: v.y - 4, width: 8, height: 8))
                }
            case .face3d:
                var chain = pts.map(toView)
                if let h = hov { chain.append(toView(h)) }
                if chain.count >= 2 {
                    ctx.move(to: chain[0])
                    for p in chain.dropFirst() { ctx.addLine(to: p) }
                    if chain.count == 4 { ctx.closePath() }
                    ctx.strokePath()
                }
            case .region:
                break   // no multi-point gesture — a single pick, no preview needed.
            case .none, .erase:
                break
            }

            ctx.setLineDash(phase: 0, lengths: [])
            let fill = accent.cgColor
            ctx.setFillColor(fill)
            for p in pts.map(toView) {
                ctx.fillEllipse(in: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6))
            }

            // Snap marker (AutoCAD-style glyphs).
            if let snap = draft.snap { drawSnapGlyph(ctx, snap) }
            ctx.restoreGState()
        }

        /// ELLIPSE ghost preview: while acquiring center/axis (first two
        /// clicks), a straight guide line to the cursor; once the axis is
        /// fixed (3rd point still pending), a polyline approximation of the
        /// actual ellipse the 3rd click/typed value would produce — reuses
        /// `DraftState.ellipsePrototype`'s exact math via a throwaway
        /// `DraftContext` (layer/color are irrelevant for a preview that's
        /// never committed) so the preview and the real result can never
        /// disagree.
        private func drawEllipsePreview(_ ctx: CGContext, pts: [CGPoint], hover: CGPoint?,
                                        axisEndpointForm: Bool, rotationMode: Bool) {
            guard let h = hover else { return }
            if pts.count < 2 {
                if let a = pts.first { strokeShape(ctx, .line(a: a, b: h)) }
                return
            }
            let center: CGPoint
            let major: CGPoint
            if axisEndpointForm {
                center = CGPoint(x: (pts[0].x + pts[1].x) / 2, y: (pts[0].y + pts[1].y) / 2)
                major = CGPoint(x: pts[1].x - center.x, y: pts[1].y - center.y)
            } else {
                center = pts[0]
                major = CGPoint(x: pts[1].x - center.x, y: pts[1].y - center.y)
            }
            let scratchCtx = DraftContext(layerId: 0, aci: 1, owner: .model, store: nil)
            guard case .entity(let proto) = DraftState.ellipsePrototype(
                center: center, major: major, ratioPoint: h, rotationMode: rotationMode, ctx: scratchCtx),
                  case .ellipse(let ep) = proto.payload else {
                // Degenerate (e.g. cursor exactly on the axis line) — just
                // show the axis itself so the tool doesn't look "stuck."
                strokeShape(ctx, .line(a: pts[0], b: pts[1]))
                return
            }
            let majorLen = hypot(ep.majorAxisEndpoint.x, ep.majorAxisEndpoint.y)
            guard majorLen > 1e-9 else { return }
            let ux = ep.majorAxisEndpoint.x / majorLen, uy = ep.majorAxisEndpoint.y / majorLen
            let minorLen = majorLen * ep.ratio
            var poly: [CGPoint] = []
            let segments = 64
            for k in 0...segments {
                let t = Double(k) / Double(segments) * 2 * .pi
                let px = cos(t) * majorLen, py = sin(t) * minorLen
                let wx = ep.center.x + px * ux - py * uy
                let wy = ep.center.y + px * uy + py * ux
                poly.append(CGPoint(x: CGFloat(wx), y: CGFloat(wy)))
            }
            strokeShape(ctx, .polyline(pts: poly, closed: true))
        }

        private func drawSnapGlyph(_ ctx: CGContext, _ snap: SnapResult) {
            let v = toView(snap.point)
            let s: CGFloat = 6
            ctx.saveGState()
            ctx.setStrokeColor(NSColor.systemGreen.cgColor)
            ctx.setLineWidth(1.8)
            switch snap.kind {
            case .endpoint:
                ctx.stroke(CGRect(x: v.x - s, y: v.y - s, width: s * 2, height: s * 2))
            case .midpoint:
                ctx.move(to: CGPoint(x: v.x, y: v.y - s))
                ctx.addLine(to: CGPoint(x: v.x - s, y: v.y + s))
                ctx.addLine(to: CGPoint(x: v.x + s, y: v.y + s))
                ctx.closePath()
                ctx.strokePath()
            case .center:
                ctx.strokeEllipse(in: CGRect(x: v.x - s, y: v.y - s,
                                             width: s * 2, height: s * 2))
            case .intersection:
                ctx.move(to: CGPoint(x: v.x - s, y: v.y - s))
                ctx.addLine(to: CGPoint(x: v.x + s, y: v.y + s))
                ctx.move(to: CGPoint(x: v.x - s, y: v.y + s))
                ctx.addLine(to: CGPoint(x: v.x + s, y: v.y - s))
                ctx.strokePath()
            case .perpendicular:
                // Right-angle glyph: ⌐ with a base.
                ctx.move(to: CGPoint(x: v.x - s, y: v.y - s))
                ctx.addLine(to: CGPoint(x: v.x - s, y: v.y + s))
                ctx.addLine(to: CGPoint(x: v.x + s, y: v.y + s))
                ctx.move(to: CGPoint(x: v.x - s, y: v.y))
                ctx.addLine(to: CGPoint(x: v.x, y: v.y))
                ctx.addLine(to: CGPoint(x: v.x, y: v.y + s))
                ctx.strokePath()
            case .tangent:
                // Circle with a tangent line across the top.
                ctx.strokeEllipse(in: CGRect(x: v.x - s, y: v.y - s + 2,
                                             width: s * 2, height: s * 2))
                ctx.move(to: CGPoint(x: v.x - s, y: v.y - s))
                ctx.addLine(to: CGPoint(x: v.x + s, y: v.y - s))
                ctx.strokePath()
            }
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: NSColor.systemGreen
            ]
            (snap.kind.label as NSString)
                .draw(at: CGPoint(x: v.x + s + 3, y: v.y + s), withAttributes: attrs)
            ctx.restoreGState()
        }

        /// MOVE tool overlay: base-point marker, rubber-band line to the
        /// cursor/snap, and a dashed ghost preview of the selection at the
        /// candidate destination.
        private func drawMoveOverlay(_ ctx: CGContext) {
            guard move.isActive else { return }
            let accent = NSColor(calibratedRed: 0.25, green: 0.66, blue: 1, alpha: 1)

            if move.phase == .pickingDestination, !moveGhost.isEmpty {
                ctx.saveGState()
                ctx.setLineWidth(1.6)
                ctx.setLineDash(phase: 0, lengths: [5, 3])
                for e in moveGhost {
                    let rgb = ACIPalette.rgb(forACI: e.aci)
                    let color = NSColor(calibratedRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                                        green: CGFloat((rgb >> 8) & 0xFF) / 255,
                                        blue: CGFloat(rgb & 0xFF) / 255, alpha: 0.9)
                    if case .text(let pos, let h, let str) = e.shape {
                        drawMarkupText(ctx, position: pos, height: h, string: str, color: color)
                    } else {
                        ctx.setStrokeColor(color.cgColor)
                        strokeShape(ctx, e.shape)
                    }
                }
                ctx.setLineDash(phase: 0, lengths: [])
                ctx.restoreGState()
            }

            if let base = move.basePoint {
                ctx.saveGState()
                let v = toView(base)
                ctx.setFillColor(accent.cgColor)
                ctx.fillEllipse(in: CGRect(x: v.x - 3.5, y: v.y - 3.5, width: 7, height: 7))
                if let h = move.snap?.point ?? move.hover {
                    ctx.setStrokeColor(accent.withAlphaComponent(0.6).cgColor)
                    ctx.setLineWidth(1)
                    ctx.setLineDash(phase: 0, lengths: [3, 3])
                    ctx.move(to: v); ctx.addLine(to: toView(h))
                    ctx.strokePath()
                    ctx.setLineDash(phase: 0, lengths: [])
                }
                ctx.restoreGState()
            }

            if let snap = move.snap { drawSnapGlyph(ctx, snap) }
        }

        /// Phase 4.2: COPY/ROTATE/SCALE/MIRROR ghost preview — same visual
        /// language as `drawMoveOverlay` (dashed outline in each entity's
        /// own color, filled accent dot at the base point, dashed rubber-
        /// band line to the cursor/snap point), generalized to whatever
        /// `modifyGhost` already holds (pre-transformed by `ContentView`).
        /// MIRROR additionally draws its own reference LINE (not part of
        /// `modifyGhost`, which only ever holds transformed COPIES of the
        /// selection).
        private func drawModifyOverlay(_ ctx: CGContext) {
            guard modify.isActive, modify.phase != .selecting else { return }
            let accent = NSColor(calibratedRed: 0.25, green: 0.66, blue: 1, alpha: 1)

            if !modifyGhost.isEmpty {
                ctx.saveGState()
                ctx.setLineWidth(1.6)
                ctx.setLineDash(phase: 0, lengths: [5, 3])
                for e in modifyGhost {
                    let rgb = ACIPalette.rgb(forACI: e.aci)
                    let color = NSColor(calibratedRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                                        green: CGFloat((rgb >> 8) & 0xFF) / 255,
                                        blue: CGFloat(rgb & 0xFF) / 255, alpha: 0.9)
                    if case .text(let pos, let h, let str) = e.shape {
                        drawMarkupText(ctx, position: pos, height: h, string: str, color: color)
                    } else {
                        ctx.setStrokeColor(color.cgColor)
                        strokeShape(ctx, e.shape)
                    }
                }
                ctx.setLineDash(phase: 0, lengths: [])
                ctx.restoreGState()
            }

            if let base = modify.basePoint {
                ctx.saveGState()
                let v = toView(base)
                ctx.setFillColor(accent.cgColor)
                ctx.fillEllipse(in: CGRect(x: v.x - 3.5, y: v.y - 3.5, width: 7, height: 7))
                // ROTATE/SCALE want a rubber-band line to the cursor
                // (defines the angle/factor); MIRROR draws its OWN line
                // below instead (a different accent color, to distinguish
                // "the mirror axis" from "a generic reference line").
                if modify.command != .mirror, let h = modify.snap?.point ?? modify.hover {
                    ctx.setStrokeColor(accent.withAlphaComponent(0.6).cgColor)
                    ctx.setLineWidth(1)
                    ctx.setLineDash(phase: 0, lengths: [3, 3])
                    ctx.move(to: v); ctx.addLine(to: toView(h))
                    ctx.strokePath()
                    ctx.setLineDash(phase: 0, lengths: [])
                }
                ctx.restoreGState()
            }

            if let (a, b) = modifyMirrorLine {
                ctx.saveGState()
                let mirrorAccent = NSColor(calibratedRed: 1, green: 0.55, blue: 0.2, alpha: 1)
                ctx.setStrokeColor(mirrorAccent.cgColor)
                ctx.setLineWidth(1.4)
                ctx.setLineDash(phase: 0, lengths: [6, 3])
                ctx.move(to: toView(a)); ctx.addLine(to: toView(b))
                ctx.strokePath()
                ctx.setLineDash(phase: 0, lengths: [])
                ctx.restoreGState()
            }

            if let snap = modify.snap { drawSnapGlyph(ctx, snap) }
        }

        /// Phase 6.4: ARRAY's live ghost preview — same dashed-outline visual
        /// language as `drawModifyOverlay`'s `modifyGhost` pass, drawing
        /// every already-transformed cell `ContentView.arrayGhostEntities`
        /// computed (capped at `ArrayTool.maxPreviewCells`).
        private func drawArrayGhostOverlay(_ ctx: CGContext) {
            guard !arrayGhost.isEmpty else { return }
            ctx.saveGState()
            ctx.setLineWidth(1.4)
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            for e in arrayGhost {
                let rgb = ACIPalette.rgb(forACI: e.aci)
                let color = NSColor(calibratedRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                                    green: CGFloat((rgb >> 8) & 0xFF) / 255,
                                    blue: CGFloat(rgb & 0xFF) / 255, alpha: 0.85)
                if case .text(let pos, let h, let str) = e.shape {
                    drawMarkupText(ctx, position: pos, height: h, string: str, color: color)
                } else {
                    ctx.setStrokeColor(color.cgColor)
                    strokeShape(ctx, e.shape)
                }
            }
            ctx.setLineDash(phase: 0, lengths: [])
            ctx.restoreGState()
        }

        /// STRETCH's live ghost preview — same dashed-outline visual
        /// language as `drawArrayGhostOverlay`.
        private func drawStretchGhostOverlay(_ ctx: CGContext) {
            guard !stretchGhost.isEmpty else { return }
            ctx.saveGState()
            ctx.setLineWidth(1.4)
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            for e in stretchGhost {
                let rgb = ACIPalette.rgb(forACI: e.aci)
                let color = NSColor(calibratedRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                                    green: CGFloat((rgb >> 8) & 0xFF) / 255,
                                    blue: CGFloat(rgb & 0xFF) / 255, alpha: 0.85)
                if case .text(let pos, let h, let str) = e.shape {
                    drawMarkupText(ctx, position: pos, height: h, string: str, color: color)
                } else {
                    ctx.setStrokeColor(color.cgColor)
                    strokeShape(ctx, e.shape)
                }
            }
            ctx.setLineDash(phase: 0, lengths: [])
            ctx.restoreGState()
        }

        /// Grip editing: small squares at every defining point of the
        /// single currently grip-editable selected entity (`gripPoints`,
        /// precomputed by `ContentView` — see that field's own doc
        /// comment). The grip being hovered or dragged (`gripDrag`) is
        /// drawn filled/accented instead of hollow, matching AutoCAD's own
        /// "hot grip" visual convention; while dragging, a live dashed
        /// ghost of the reshaped entity (`gripDragGhost`) is drawn
        /// underneath so the user sees the actual result before releasing.
        private func drawGripsOverlay(_ ctx: CGContext) {
            guard !gripPoints.isEmpty else { return }
            let accent = NSColor(calibratedRed: 0.25, green: 0.66, blue: 1, alpha: 1)
            let gripBlue = NSColor(calibratedRed: 0.11, green: 0.44, blue: 0.98, alpha: 1)

            if let ghost = gripDragGhost {
                ctx.saveGState()
                ctx.setStrokeColor(accent.cgColor)
                ctx.setLineWidth(1.4)
                ctx.setLineDash(phase: 0, lengths: [5, 3])
                strokeShape(ctx, ghost)
                ctx.setLineDash(phase: 0, lengths: [])
                ctx.restoreGState()
            }

            let halfSize: CGFloat = 4
            for grip in gripPoints {
                let v = toView(grip.position)
                let r = CGRect(x: v.x - halfSize, y: v.y - halfSize, width: halfSize * 2, height: halfSize * 2)
                let isHot = gripDrag.entityId != nil && gripDrag.gripIndex == grip.index
                    && gripDrag.phase != .idle
                ctx.saveGState()
                if isHot {
                    ctx.setFillColor(gripBlue.cgColor)
                    ctx.fill(r)
                } else {
                    ctx.setFillColor(NSColor.white.cgColor)
                    ctx.fill(r)
                    ctx.setStrokeColor(gripBlue.cgColor)
                    ctx.setLineWidth(1.2)
                    ctx.stroke(r)
                }
                ctx.restoreGState()
            }
        }

        private func drawMeasureOverlay(_ ctx: CGContext) {
            guard measure.isActive,
                  !measure.points.isEmpty || measure.hover != nil || measure.pickedArc != nil
            else { return }
            let accent = NSColor(calibratedRed: 0.25, green: 0.66, blue: 1, alpha: 1)

            let pts = measure.points.map(toView)
            var previewPts = pts
            if let hover = measure.hover, !measure.closed,
               !(measure.mode == .distance && measure.points.count >= 2) {
                previewPts.append(toView(hover))
            }

            ctx.saveGState()
            ctx.setStrokeColor(accent.cgColor)
            ctx.setLineWidth(1.5)
            ctx.setLineDash(phase: 0, lengths: [5, 3])
            if measure.mode == .angle {
                // Two rays from the vertex (points[0]).
                if let v = pts.first {
                    if pts.count >= 2 { ctx.move(to: v); ctx.addLine(to: pts[1]) }
                    let end = pts.count >= 3 ? pts[2] : measure.hover.map(toView)
                    if pts.count >= 2, let end { ctx.move(to: v); ctx.addLine(to: end) }
                    ctx.strokePath()
                }
            } else if measure.mode == .distance || measure.mode == .area {
                if previewPts.count >= 2 {
                    ctx.move(to: previewPts[0])
                    for p in previewPts.dropFirst() { ctx.addLine(to: p) }
                    if measure.mode == .area && (measure.closed || previewPts.count > 2) {
                        ctx.addLine(to: previewPts[0])
                    }
                    ctx.strokePath()
                }
                if measure.mode == .area && previewPts.count >= 3 {
                    ctx.setFillColor(accent.withAlphaComponent(0.12).cgColor)
                    ctx.move(to: previewPts[0])
                    for p in previewPts.dropFirst() { ctx.addLine(to: p) }
                    ctx.closePath()
                    ctx.fillPath()
                }
            }
            ctx.setLineDash(phase: 0, lengths: [])
            ctx.setFillColor(accent.cgColor)
            for p in pts {
                ctx.fillEllipse(in: CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7))
            }
            ctx.restoreGState()

            // Snap glyph at the current snapped position, matching the
            // same green AutoCAD-style glyphs Draft/Move/Modify show.
            if let snap = measure.snap {
                drawSnapGlyph(ctx, snap)
            }

            // Radius: draw the picked circle/arc emphasized + its center.
            if measure.mode == .radius, let arc = measure.pickedArc {
                let c = toView(arc.center)
                let rr = arc.radius * currentParams.zoom
                ctx.saveGState()
                ctx.setStrokeColor(accent.cgColor)
                ctx.setLineWidth(2)
                ctx.strokeEllipse(in: CGRect(x: c.x - rr, y: c.y - rr, width: rr * 2, height: rr * 2))
                ctx.move(to: CGPoint(x: c.x - 5, y: c.y)); ctx.addLine(to: CGPoint(x: c.x + 5, y: c.y))
                ctx.move(to: CGPoint(x: c.x, y: c.y - 5)); ctx.addLine(to: CGPoint(x: c.x, y: c.y + 5))
                ctx.strokePath()
                ctx.restoreGState()
            }

            // Readout chip near the last point.
            let worldPts = measure.points
            var lines: [String] = []
            let fmt = measureFormat
            switch measure.mode {
            case .distance:
                var a: CGPoint?, b: CGPoint?
                if worldPts.count >= 2 { a = worldPts[0]; b = worldPts[1] }
                else if worldPts.count == 1, let h = measure.hover { a = worldPts[0]; b = h }
                if let a, let b {
                    lines = ["Distance: \(fmt.length(hypot(b.x - a.x, b.y - a.y)))",
                             "ΔX: \(fmt.length(b.x - a.x))   ΔY: \(fmt.length(b.y - a.y))",
                             "Angle: \(fmt.angle(atan2(b.y - a.y, b.x - a.x) * 180 / .pi))"]
                } else if worldPts.count == 1 {
                    lines = ["Click the second point"]
                } else {
                    lines = ["Click the first point"]
                }
            case .area:
                var poly = worldPts
                if !measure.closed, let h = measure.hover { poly.append(h) }
                if poly.count >= 3 {
                    lines = ["Area: \(fmt.area(MeasureState.polygonArea(poly)))",
                             "Perimeter: \(fmt.length(MeasureState.pathLength(poly, closed: true)))"]
                    if !measure.closed { lines.append("Double-click or ⏎ to finish") }
                } else {
                    lines = ["Click boundary points (\(worldPts.count) so far)"]
                }
            case .radius:
                if let arc = measure.pickedArc {
                    lines = ["Radius: \(fmt.length(arc.radius))",
                             "Diameter: \(fmt.length(arc.radius * 2))",
                             arc.full ? "Circumference: \(fmt.length(2 * .pi * arc.radius))"
                                      : "Arc: \(fmt.length(arc.radius * arcSweepRad(arc)))"]
                } else {
                    lines = ["Click a circle or arc"]
                }
            case .angle:
                lines = angleReadout(worldPts, fmt: fmt)
            case .select:
                return
            }
            guard !lines.isEmpty else { return }

            let anchor = pts.last
                ?? measure.pickedArc.map { toView($0.center) }
                ?? toView(measure.hover ?? .zero)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.white
            ]
            let text = lines.joined(separator: "\n") as NSString
            let size = text.size(withAttributes: attrs)
            var chip = CGRect(x: anchor.x + 14, y: anchor.y - size.height - 14,
                              width: size.width + 16, height: size.height + 10)
            if chip.maxX > bounds.maxX { chip.origin.x = anchor.x - chip.width - 14 }
            if chip.minY < 0 { chip.origin.y = anchor.y + 14 }
            let path = CGPath(roundedRect: chip, cornerWidth: 6, cornerHeight: 6, transform: nil)
            ctx.addPath(path)
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.72).cgColor)
            ctx.fillPath()
            text.draw(at: CGPoint(x: chip.minX + 8, y: chip.minY + 5), withAttributes: attrs)
        }

        private func arcSweepRad(_ arc: (center: CGPoint, radius: CGFloat, startDeg: Double,
                                         endDeg: Double, full: Bool)) -> CGFloat {
            var s = (arc.endDeg - arc.startDeg).truncatingRemainder(dividingBy: 360)
            if s <= 0 { s += 360 }
            return CGFloat(s * .pi / 180)
        }

        private func angleReadout(_ world: [CGPoint], fmt: MeasureFormat) -> [String] {
            func included(_ v: CGPoint, _ a: CGPoint, _ b: CGPoint) -> Double {
                let a1 = atan2(a.y - v.y, a.x - v.x), a2 = atan2(b.y - v.y, b.x - v.x)
                var d = abs(a2 - a1) * 180 / .pi
                if d > 180 { d = 360 - d }
                return d
            }
            switch world.count {
            case 0: return ["Click the angle vertex"]
            case 1: return ["Click the first side"]
            case 2:
                guard let h = measure.hover else { return ["Click the second side"] }
                return ["Angle: \(fmt.angle(included(world[0], world[1], h)))",
                        "Click the second side"]
            default:
                return ["Angle: \(fmt.angle(included(world[0], world[1], world[2])))"]
            }
        }

        /// Live preview for the DIMENSION tool's 3-click gesture — mirrors
        /// `drawMeasureOverlay`'s screen-space dashed-line style. While only
        /// the first (or first two) points are picked, shows simple
        /// guide dots/lines; once BOTH measured points are set and the
        /// cursor is choosing the dimension-line placement, computes the
        /// SAME geometry `DimensionTool.create` would commit (via a plain
        /// world-space re-derivation, not touching the EntityStore) so the
        /// user sees exactly what will be placed before clicking.
        private func drawDimensionPreview(_ ctx: CGContext) {
            guard dimension.isActive else { return }
            let accent = NSColor(calibratedRed: 0.25, green: 0.66, blue: 1, alpha: 1)
            ctx.saveGState()
            ctx.setStrokeColor(accent.cgColor)
            ctx.setFillColor(accent.cgColor)
            ctx.setLineWidth(1.5)

            if let p1 = dimension.firstPoint {
                let v1 = toView(p1)
                ctx.fillEllipse(in: CGRect(x: v1.x - 3.5, y: v1.y - 3.5, width: 7, height: 7))
                let p2 = dimension.secondPoint ?? dimension.hover
                if let p2 {
                    let v2 = toView(p2)
                    ctx.setLineDash(phase: 0, lengths: [5, 3])
                    ctx.move(to: v1); ctx.addLine(to: v2)
                    ctx.strokePath()
                    ctx.setLineDash(phase: 0, lengths: [])
                    if dimension.secondPoint != nil {
                        ctx.fillEllipse(in: CGRect(x: v2.x - 3.5, y: v2.y - 3.5, width: 7, height: 7))
                    }
                }
            }

            // Full geometry preview: both measured points are set AND we're
            // in the placement phase — reuse `DimensionTool`'s own
            // geometry-only helper so the preview matches the committed
            // result exactly (same offset/arrow/text logic, just drawn
            // in view space instead of appended to the store).
            if dimension.phase == .pickDimensionLinePlacement,
               let p1 = dimension.firstPoint, let p2 = dimension.secondPoint,
               let placement = dimension.hover {
                if let preview = DimensionTool.previewGeometry(kind: dimension.kind, p1: p1, p2: p2, placement: placement) {
                    ctx.setLineDash(phase: 0, lengths: [])
                    for (a, b) in preview.lines {
                        ctx.move(to: toView(a)); ctx.addLine(to: toView(b))
                    }
                    ctx.strokePath()
                    for tri in preview.arrowTriangles {
                        let pts = tri.map(toView)
                        ctx.move(to: pts[0]); ctx.addLine(to: pts[1]); ctx.addLine(to: pts[2])
                        ctx.closePath()
                    }
                    ctx.fillPath()
                    let labelPos = toView(preview.textPosition)
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                        .foregroundColor: NSColor.white
                    ]
                    let text = preview.text as NSString
                    let size = text.size(withAttributes: attrs)
                    text.draw(at: CGPoint(x: labelPos.x - size.width / 2, y: labelPos.y - size.height / 2),
                             withAttributes: attrs)
                }
            }

            if let snap = dimension.snap {
                drawSnapGlyph(ctx, snap)
            }
            ctx.restoreGState()
        }

        private func drawHalo(_ ctx: CGContext) {
            guard let halo, halo.until > Date() else { return }
            let remaining = halo.until.timeIntervalSinceNow
            let phase = 1 - max(0, min(1, remaining / 3))        // 0 → 1 over life
            let pulse = 1 + 0.25 * sin(phase * .pi * 4)            // two pulses
            let center = toView(halo.position)
            let baseR = max(halo.worldRadius * currentParams.zoom, 22)
            let r = baseR * pulse
            let alpha = max(0, remaining / 3) * 0.95

            ctx.saveGState()
            ctx.setStrokeColor(NSColor.systemYellow.withAlphaComponent(alpha).cgColor)
            ctx.setLineWidth(3)
            if let bounds = halo.bounds {
                let a = toView(CGPoint(x: bounds.minX, y: bounds.minY))
                let b = toView(CGPoint(x: bounds.maxX, y: bounds.maxY))
                let box = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
                ctx.stroke(box.insetBy(dx: -5, dy: -5))
                ctx.restoreGState()
                return
            }
            ctx.strokeEllipse(in: CGRect(x: center.x - r, y: center.y - r,
                                         width: r * 2, height: r * 2))
            ctx.setStrokeColor(NSColor.systemYellow.withAlphaComponent(alpha * 0.4).cgColor)
            ctx.setLineWidth(7)
            ctx.strokeEllipse(in: CGRect(x: center.x - r - 5, y: center.y - r - 5,
                                         width: (r + 5) * 2, height: (r + 5) * 2))
            ctx.restoreGState()
        }

        /// Rubber-band selection rectangle, drawn directly in view space.
        /// Phase 4.1: Window = solid blue outline/fill (AutoCAD convention —
        /// L→R drag, full-containment selection); Crossing = dashed GREEN
        /// outline/fill (R→L drag, any-intersection selection). Mode is
        /// resolved live during the drag (`marqueeMode`, updated on every
        /// `mouseDragged` tick) so the marquee visually flips the instant
        /// the cursor crosses back over the drag's start X — matching the
        /// plan's "recomputed live during the drag" spec exactly.
        private func drawMarquee(_ ctx: CGContext) {
            guard let r = marqueeRect else { return }
            let isWindow = (marqueeMode ?? .window) == .window
            let color: NSColor = isWindow
                ? NSColor(calibratedRed: 0.25, green: 0.66, blue: 1, alpha: 1)      // blue = Window
                : NSColor(calibratedRed: 0.35, green: 0.85, blue: 0.45, alpha: 1)   // green = Crossing
            ctx.saveGState()
            ctx.setFillColor(color.withAlphaComponent(0.12).cgColor)
            ctx.fill(r)
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(1)
            // Window: solid outline. Crossing: dashed — matches the plan's
            // "L->R = Window (blue 12% fill, solid outline), R->L = Crossing
            // (green 12% fill, dashed outline)" spec precisely.
            ctx.setLineDash(phase: 0, lengths: isWindow ? [] : [4, 3])
            ctx.stroke(r)
            ctx.setLineDash(phase: 0, lengths: [])
            ctx.restoreGState()
        }

        /// Phase 4.1: Option+drag lasso path — same Window/Crossing color
        /// convention as `drawMarquee`, drawn as an open polyline (not
        /// closed until the gesture completes, matching how AutoCAD's own
        /// lasso preview never visually closes the loop while dragging).
        private func drawLasso(_ ctx: CGContext) {
            guard lassoActive, lassoPoints.count >= 2 else { return }
            let isWindow = (marqueeMode ?? .window) == .window
            let color: NSColor = isWindow
                ? NSColor(calibratedRed: 0.25, green: 0.66, blue: 1, alpha: 1)
                : NSColor(calibratedRed: 0.35, green: 0.85, blue: 0.45, alpha: 1)
            ctx.saveGState()
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(1.4)
            ctx.setLineDash(phase: 0, lengths: isWindow ? [] : [4, 3])
            ctx.move(to: lassoPoints[0])
            for p in lassoPoints.dropFirst() { ctx.addLine(to: p) }
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
            ctx.restoreGState()
        }
    }
}
