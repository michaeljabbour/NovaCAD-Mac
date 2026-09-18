//
//  SelectionPrompt.swift
//  DWGViewer / Selection
//
//  Phase 4.1 — the reusable "Select objects:" acquisition loop every modify
//  command (MOVE/COPY/ROTATE/SCALE/MIRROR now; TRIM/EXTEND/FILLET/CHAMFER/
//  OFFSET/ARRAY/EXPLODE later) drives identically, matching AutoCAD's own
//  command-line "Select objects:" prompt semantics: PICKFIRST noun-verb
//  (select first, then invoke a command — skips the prompt entirely),
//  click-to-add/remove, drag-to-box-select (Window/Crossing), lasso, fence,
//  and the W/C/F/ALL/P/L/R/A/U command-bar tokens.
//
//  This type is deliberately UI-framework-agnostic (no SwiftUI/AppKit
//  imports) — ContentView/DXFCanvasView translate raw mouse/keyboard input
//  into `SelectionPrompt.Event` values and read `state`/`promptText` back
//  out; this file owns none of the actual event routing (mouse-down/drag
//  thresholds, keyboard focus) — see DXFCanvasView.swift's existing
//  box-select drag-threshold code for that layer, which SelectionPrompt
//  callers reuse unchanged.
//

import Foundation
import CoreGraphics

/// Input events `SelectionPrompt` reacts to. Callers (ContentView) are
/// responsible for translating raw mouse/keyboard input into these — e.g. a
/// single left-click (no drag) becomes `.pick`, a completed rubber-band drag
/// becomes `.boxComplete`, typing "W" then Enter becomes `.commandToken("W")`
/// followed by two `.pick`s once the explicit-window sub-mode is armed (the
/// world point on EVERY `.pick` is what those two corner-collection picks
/// consume — `SelectionPrompt` manages the W/C two-point sub-state entirely
/// internally, so callers never need to know whether a given click is being
/// interpreted as an object pick or a rect corner).
enum SelectionPromptEvent {
    /// A single point pick (click) in WORLD coordinates, with the entity
    /// under it if any (nil = clicked empty space) and whether Shift was
    /// held (forces remove mode for that one pick regardless of the ambient
    /// add/remove mode). `worldPoint` is used only while awaiting an
    /// explicit W/C rect's corners; ordinary picks ignore it.
    case pick(EntityID?, worldPoint: CGPoint, shiftHeld: Bool)
    /// A completed rectangle drag, in WORLD coordinates, with the L→R vs
    /// R→L direction already resolved into a mode by the caller (matching
    /// the plan's gesture spec — DXFCanvasView computes this live during
    /// the drag; SelectionPrompt only ever sees the final resolved mode).
    case boxComplete(CGRect, mode: SelectionMode, shiftHeld: Bool)
    /// A completed lasso (Option+drag), already resolved to Window/Crossing
    /// by the same L→R/R→L rule as a box drag.
    case lassoComplete([CGPoint], mode: SelectionMode, shiftHeld: Bool)
    /// A completed fence polyline (crossing-only — no mode parameter, per
    /// AutoCAD FENCE semantics and `SelectionEngine.fenceSelect`).
    case fenceComplete([CGPoint])
    /// A command-bar token typed during the prompt: W, C, F, ALL, P, L, R,
    /// A, U (case-insensitive; ContentView uppercases before calling).
    case commandToken(String)
    /// Enter with no other pending input — finishes acquisition with
    /// whatever's accumulated so far (AutoCAD: a bare Enter at "Select
    /// objects:" ends the command).
    case finish
    /// Esc — aborts the whole modify command, discarding any accumulated
    /// selection.
    case cancel
}

enum SelectionPromptResult: Equatable {
    case pending
    case done(Set<EntityID>)
    case cancelled
}

/// Sub-mode `SelectionPrompt` is in — drives what `promptText` says and how
/// the NEXT event is interpreted (e.g. while `.awaitingWindowCorner1`, a
/// `.pick` is consumed as a corner point, not a normal object pick).
private enum SubMode: Equatable {
    case normal
    case awaitingWindowCorner1
    case awaitingWindowCorner2(CGPoint)
    case awaitingFence
}

/// Drives one "Select objects:" acquisition loop. Construct fresh per modify
/// command invocation (MOVE/COPY/ROTATE/SCALE/MIRROR's `ModifyToolState`
/// transitions into `.selecting` by creating one of these); `handle(_:)`
/// mutates internal state and returns the current result — callers poll
/// `result` after each call (or use the return value directly) to know when
/// to advance to the next phase.
struct SelectionPrompt {
    /// PICKADD=0 semantics: when true, each new pick REPLACES the
    /// accumulated set instead of adding to it, unless Shift is held for
    /// that pick (matching the plan's "PICKADD=0 -> replace unless Shift").
    /// Read once at construction from the session's sysvar — not re-read
    /// per event, matching how AutoCAD fixes PICKADD's effect for the
    /// duration of one selection-set build.
    private let pickAddIsZero: Bool

    /// The set of `EntityID`s available for `ALL` — visible + unlocked in
    /// the current space, computed once at construction (matches AutoCAD:
    /// ALL is a snapshot of what's selectable right now, not re-evaluated
    /// live as the user continues picking).
    private let allSelectableProvider: () -> Set<EntityID>
    /// `P` (Previous) — the selection set from the command run before this
    /// one. `L` (Last) — the most recently created entity/entities (e.g.
    /// the ids `performEdit(selectNewEntities:)` would have populated, or a
    /// freshly drawn/copied entity). Both are read lazily (only if the user
    /// actually types P/L) since most invocations never need them.
    private let previousSelectionProvider: () -> Set<EntityID>
    private let lastCreatedProvider: () -> Set<EntityID>

    private let rectSelectProvider: (CGRect, SelectionMode) -> Set<EntityID>
    private let lassoSelectProvider: ([CGPoint], SelectionMode) -> Set<EntityID>
    private let fenceSelectProvider: ([CGPoint]) -> Set<EntityID>

    private(set) var accumulated: Set<EntityID>
    private var subMode: SubMode = .normal
    /// Add (default) or Remove mode, toggled by the R/A command-bar tokens.
    private var removeMode = false
    /// History of accumulated-set snapshots, one per acquisition step, for
    /// `U` (undo last acquisition step) — mirrors AutoCAd's own "U" at the
    /// Select objects: prompt, which undoes the most recent pick/window/
    /// crossing/etc., not the whole selection.
    private var history: [Set<EntityID>] = []

    private(set) var result: SelectionPromptResult

    /// PICKFIRST noun-verb: if `preselected` is non-empty, the prompt is
    /// immediately `.done` and no interactive acquisition ever happens —
    /// callers should check `result` right after construction before
    /// presenting any UI at all.
    init(preselected: Set<EntityID>,
         pickAddIsZero: Bool = false,
         allSelectable: @escaping () -> Set<EntityID>,
         previousSelection: @escaping () -> Set<EntityID> = { [] },
         lastCreated: @escaping () -> Set<EntityID> = { [] },
         rectSelect: @escaping (CGRect, SelectionMode) -> Set<EntityID>,
         lassoSelect: @escaping ([CGPoint], SelectionMode) -> Set<EntityID> = { _, _ in [] },
         fenceSelect: @escaping ([CGPoint]) -> Set<EntityID> = { _ in [] }) {
        self.pickAddIsZero = pickAddIsZero
        self.allSelectableProvider = allSelectable
        self.previousSelectionProvider = previousSelection
        self.lastCreatedProvider = lastCreated
        self.rectSelectProvider = rectSelect
        self.lassoSelectProvider = lassoSelect
        self.fenceSelectProvider = fenceSelect

        if !preselected.isEmpty {
            self.accumulated = preselected
            self.result = .done(preselected)
        } else {
            self.accumulated = []
            self.result = .pending
        }
    }

    var promptText: String {
        switch result {
        case .done, .cancelled:
            return ""
        case .pending:
            break
        }
        switch subMode {
        case .awaitingWindowCorner1:
            return "Select objects: specify first corner"
        case .awaitingWindowCorner2:
            return "Select objects: specify opposite corner"
        case .awaitingFence:
            return "Select objects: FENCE — specify next point (⏎ to finish)"
        case .normal:
            let count = accumulated.count
            let modeTag = removeMode ? " (Remove mode)" : ""
            return count == 0
                ? "Select objects:\(modeTag)"
                : "Select objects: (\(count) found)\(modeTag)"
        }
    }

    /// Feeds one event; mutates internal state and returns the new result.
    /// Once `result` is `.done`/`.cancelled`, further calls are a no-op
    /// (construct a new `SelectionPrompt` for the next command).
    @discardableResult
    mutating func handle(_ event: SelectionPromptEvent) -> SelectionPromptResult {
        guard case .pending = result else { return result }

        switch event {
        case .cancel:
            result = .cancelled
            return result

        case .finish:
            result = .done(accumulated)
            return result

        case .commandToken(let raw):
            handleCommandToken(raw.uppercased())
            return result

        case .pick(let hit, let worldPoint, let shiftHeld):
            switch subMode {
            case .awaitingWindowCorner1:
                // First corner of an explicit W/C rect — a plain point, not
                // an object pick (the hit-test result, if any, is ignored).
                subMode = .awaitingWindowCorner2(worldPoint)
            case .awaitingWindowCorner2(let corner1):
                let rect = CGRect(x: min(corner1.x, worldPoint.x), y: min(corner1.y, worldPoint.y),
                                  width: abs(worldPoint.x - corner1.x), height: abs(worldPoint.y - corner1.y))
                let mode = pendingExplicitMode ?? .window
                let hits = rectSelectProvider(rect, mode)
                applyAcquisition(hits, shiftHeld: shiftHeld)
                subMode = .normal
                pendingExplicitMode = nil
            case .awaitingFence:
                // Fence point-by-point collection is caller-driven (mirrors
                // how PLINE accumulates points in DraftState) — a `.pick`
                // arriving here would mean the caller is feeding fence
                // vertices one at a time rather than all at once via
                // `.fenceComplete`; since the plan's fence UX is "rubber-
                // band polyline, Enter -> crossing-select along it" (i.e.
                // the whole polyline arrives at once on Enter, same as
                // `DraftState.finishPolyline`), a bare `.pick` here is
                // ignored rather than partially consumed — ContentView owns
                // accumulating fence vertices itself (exactly as it already
                // owns `DraftState.points` for PLINE) and sends the
                // complete polyline via `.fenceComplete` once Enter is
                // pressed.
                break
            case .normal:
                applyPick(hit, shiftHeld: shiftHeld)
            }
            return result

        case .boxComplete(let rect, let mode, let shiftHeld):
            let hits = rectSelectProvider(rect, mode)
            applyAcquisition(hits, shiftHeld: shiftHeld)
            subMode = .normal
            return result

        case .lassoComplete(let polygon, let mode, let shiftHeld):
            let hits = lassoSelectProvider(polygon, mode)
            applyAcquisition(hits, shiftHeld: shiftHeld)
            return result

        case .fenceComplete(let polyline):
            let hits = fenceSelectProvider(polyline)
            applyAcquisition(hits, shiftHeld: false)
            subMode = .normal
            return result
        }
    }

    // MARK: - Command-bar tokens

    private mutating func handleCommandToken(_ token: String) {
        switch token {
        case "W", "C":
            // Explicit two-point rect: the next two `.pick` events (world
            // points, hit-test result ignored) supply the corners — handled
            // entirely internally by the `.awaitingWindowCorner1`/`2`
            // branches in `handle(_:)` above. `pendingExplicitMode` records
            // which mode the ALWAYS-explicit W/C rect uses (unlike a plain
            // drag, where L→R vs R→L determines Window vs Crossing — typing
            // W or C overrides that entirely, matching AutoCAD).
            subMode = .awaitingWindowCorner1
            pendingExplicitMode = token == "W" ? .window : .crossing

        case "F":
            subMode = .awaitingFence

        case "ALL":
            applyAcquisition(allSelectableProvider(), shiftHeld: false)

        case "P":
            applyAcquisition(previousSelectionProvider(), shiftHeld: false)

        case "L":
            applyAcquisition(lastCreatedProvider(), shiftHeld: false)

        case "R":
            removeMode = true

        case "A":
            removeMode = false

        case "U":
            undoLastAcquisition()

        default:
            break   // unrecognized token — ignored, prompt text unchanged
        }
    }

    /// Set by the W/C token handler above; consumed by the second corner's
    /// `.pick` in `handle(_:)`. `nil` when no W/C sequence is in progress.
    private var pendingExplicitMode: SelectionMode?

    // MARK: - Acquisition bookkeeping

    private mutating func applyPick(_ hit: EntityID?, shiftHeld: Bool) {
        guard let hit else {
            // Clicking empty space during an active prompt is a no-op for
            // acquisition (unlike the plain-select-mode click handler,
            // which clears the selection on an empty-space click) — AutoCAD
            // ignores empty clicks at "Select objects:" rather than
            // resetting progress.
            return
        }
        history.append(accumulated)
        if shiftHeld {
            // Shift on a SINGLE pick TOGGLES membership — exactly
            // `ContentView.handleClick`'s existing plain-select-mode
            // behavior (insert if absent, remove if present), not an
            // unconditional remove. `removeMode` (the R token) is
            // irrelevant here: Shift always means "toggle this one," an
            // explicit per-click override independent of the ambient mode.
            if accumulated.contains(hit) { accumulated.remove(hit) } else { accumulated.insert(hit) }
        } else if removeMode {
            accumulated.remove(hit)
        } else if pickAddIsZero {
            accumulated = [hit]
        } else {
            accumulated.insert(hit)
        }
    }

    /// Shared bookkeeping for any "acquired a whole SET at once" step (box/
    /// lasso/fence/ALL/P/L), applied to every id in `hits` at once, as ONE
    /// undo-able history step (matching AutoCAD: a single window/crossing
    /// selection is one "U" step, not one per object it happened to catch).
    /// Unlike a single pick, Shift on a BATCH acquisition means "add to the
    /// existing set" (matching `ContentView.handleBoxSelect`'s existing
    /// `shiftDown ? selection.union(hits) : hits` behavior) rather than a
    /// per-item toggle, which would be ambiguous/surprising for a
    /// multi-hundred-entity crossing-select.
    private mutating func applyAcquisition(_ hits: Set<EntityID>, shiftHeld: Bool) {
        history.append(accumulated)
        if shiftHeld {
            accumulated.formUnion(hits)
        } else if removeMode {
            accumulated.subtract(hits)
        } else if pickAddIsZero {
            accumulated = hits
        } else {
            accumulated.formUnion(hits)
        }
    }

    private mutating func undoLastAcquisition() {
        guard let prior = history.popLast() else { return }
        accumulated = prior
    }
}
