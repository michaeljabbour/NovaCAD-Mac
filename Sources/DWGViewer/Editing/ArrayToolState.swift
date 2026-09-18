//
//  ArrayToolState.swift
//  DWGViewer / Editing
//
//  Phase 6.4 — interactive state machine for ARRAY, mirroring
//  `BlockToolState`/`ModifyToolState`'s overall "acquire objects -> gather
//  parameters via the command bar -> commit" shape. ARRAY's own twist:
//  parameters are gathered through a short SEQUENCE of command-bar prompts
//  (rows, columns, row spacing, column spacing[, axis angle] for
//  rectangular; count, fill angle[, rotate-items] for polar) rather than a
//  single click/typed value the way ROTATE/SCALE/OFFSET's own single
//  geometric parameter is — `ArrayToolState.pendingField` tracks WHICH
//  field of the in-progress definition the next command-bar submission
//  fills, exactly mirroring `ContentView`'s existing `PendingFilletChamferEntry`/
//  `PendingBlockEntry` "type a keyword, then the next submission is its
//  value" chaining convention, just with more steps.
//
//  Live ghost preview: `ArrayTool.previewCells(...)` (ArrayTool.swift) is
//  called fresh on every field edit (capped at 500 cells per the plan) so
//  the user sees the pattern update as they type — no separate preview
//  state lives here, it's derived on demand from `objectIDs` + whichever
//  fields have been filled so far (defaults fill the rest).
//

import Foundation
import CoreGraphics

enum ArrayKindChoice: Equatable {
    case rectangular
    case polar
    // Path array is explicitly lower-priority/deferred per the plan's own
    // scoping guidance ("acceptable to stub or defer with clear
    // documentation") — see ArrayTool.swift's header comment for exactly
    // what's implemented vs. deferred for `.path`.
    case path
}

/// Which field of the in-progress array definition the NEXT command-bar
/// submission fills. Rectangular and polar each have their own field
/// sequence; `.path` is deferred (see `ArrayKindChoice.path`'s doc comment)
/// so it has no field sequence of its own here.
enum ArrayField: Equatable {
    case rows, columns, rowSpacing, columnSpacing, axisAngle
    case count, fillAngle, rotateItems
}

struct ArrayToolState: Equatable {
    enum Phase: Equatable {
        case idle
        /// Acquiring the source object set via `SelectionPrompt` — skipped
        /// when PICKFIRST applies (non-empty selection at invocation),
        /// exactly like BLOCK/COPY/ROTATE/SCALE/MIRROR's own noun-verb
        /// dispatch.
        case selecting
        /// Objects acquired; waiting for the user to choose rectangular vs.
        /// polar (vs. path, deferred) via the command bar/menu.
        case pickKind
        /// Kind chosen; gathering `ArrayField` values one at a time via the
        /// command bar, in the field order `ArrayField` documents above.
        case pickFields
        /// Rectangular only: waiting for a click to set the base point
        /// (array origin) — optional refinement; the default base point is
        /// the source objects' collective bounds' min corner, so this phase
        /// is entered only if the user explicitly asks to reposition it
        /// (not exercised by the MVP command-bar flow — kept for API
        /// completeness/future mouse-driven placement).
        case pickBasePoint
    }

    var phase: Phase = .idle
    var kind: ArrayKindChoice = .rectangular
    var objectIDs: Set<EntityID> = []
    var pendingField: ArrayField? = nil

    // Rectangular parameters (defaults match AutoCAD's own ARRAYRECT dialog defaults).
    var rows: Int = 3
    var columns: Int = 3
    var rowSpacing: Double = 10
    var columnSpacing: Double = 10
    var axisAngleDeg: Double = 0

    // Polar parameters.
    var polarCenter: CGPoint? = nil
    var count: Int = 6
    var fillAngleDeg: Double = 360
    var rotateItems: Bool = true

    /// Non-nil while editing an EXISTING array's definition (context menu's
    /// "Edit Array") — `regenerate` deletes and recreates `memberIDs`
    /// (reconciling any the user has since deleted — see `ArrayTool.
    /// regenerate`'s doc comment) instead of creating brand-new members.
    var editingExistingAnchor: EntityID? = nil

    var isActive: Bool { phase != .idle }

    static func begin(preselection: Set<EntityID>) -> ArrayToolState {
        var state = ArrayToolState()
        if !preselection.isEmpty {
            state.objectIDs = preselection
            state.phase = .pickKind
        } else {
            state.phase = .selecting
        }
        return state
    }

    /// Re-enters the field-gathering flow for an EXISTING array (Edit
    /// Array), pre-filled from its stored `ArrayDefinition` — see
    /// `ContentView.startEditArray`.
    static func beginEdit(anchor: EntityID, definition: ArrayDefinition) -> ArrayToolState {
        var state = ArrayToolState()
        state.objectIDs = Set(definition.sourceHandles)
        state.editingExistingAnchor = anchor
        switch definition.kind {
        case .rectangular(let rows, let cols, let rowSpacing, let colSpacing, let axisAngle):
            state.kind = .rectangular
            state.rows = rows; state.columns = cols
            state.rowSpacing = rowSpacing; state.columnSpacing = colSpacing
            state.axisAngleDeg = axisAngle
        case .polar(let center, let count, let fillAngle, let rotateItems):
            state.kind = .polar
            state.polarCenter = center.cgPoint
            state.count = count; state.fillAngleDeg = fillAngle; state.rotateItems = rotateItems
        case .path:
            state.kind = .path
        }
        state.phase = .pickFields
        // Seed the FIRST field of the chosen kind's sequence (same as
        // `withChosenKind`) rather than `nil` — Edit Array's whole point is
        // "prompts pre-filled" per the plan's spec text, which means the
        // user can walk the SAME field-by-field prompt sequence a fresh
        // ARRAY offers (each prompt shows the CURRENT value as its
        // bracketed default, so bare-Enter-through-everything reproduces
        // the array unchanged, exactly like a fresh ARRAY's own defaults
        // do) — `pendingField == nil` would instead make the very FIRST
        // command-bar submission commit immediately with no chance to
        // change anything, which contradicts "prompts pre-filled" (found
        // by adversarial review: the original `nil` seed made every field
        // of `ArrayField` genuinely unreachable during an Edit Array
        // session specifically, even though the exact same field-handling
        // code is fully reachable and tested from a FRESH array).
        state.pendingField = state.kind == .rectangular ? .rows : .count
        return state
    }

    mutating func withAcquiredObjects(_ ids: Set<EntityID>) {
        objectIDs = ids
        phase = .pickKind
    }

    /// Advances from `.pickKind` to `.pickFields`, seeding `pendingField`
    /// with the FIRST field of the chosen kind's sequence.
    mutating func withChosenKind(_ k: ArrayKindChoice) {
        kind = k
        phase = .pickFields
        pendingField = k == .rectangular ? .rows : .count
    }

    /// Advances `pendingField` to the next field in sequence, or clears it
    /// (all fields gathered — the command bar's "commit now, or keep typing
    /// to override defaults" convention: every field has a sane default, so
    /// the array can commit as soon as the LAST field in sequence is
    /// answered, exactly like FILLET's radius-then-commit shape).
    mutating func advanceField() {
        guard let current = pendingField else { return }
        switch kind {
        case .rectangular:
            switch current {
            case .rows: pendingField = .columns
            case .columns: pendingField = .rowSpacing
            case .rowSpacing: pendingField = .columnSpacing
            case .columnSpacing: pendingField = .axisAngle
            case .axisAngle: pendingField = nil
            default: pendingField = nil
            }
        case .polar:
            switch current {
            case .count: pendingField = .fillAngle
            case .fillAngle: pendingField = .rotateItems
            case .rotateItems: pendingField = nil
            default: pendingField = nil
            }
        case .path:
            pendingField = nil
        }
    }

    var prompt: String {
        switch phase {
        case .idle: return ""
        case .selecting: return "ARRAY — Select objects:"
        case .pickKind: return "ARRAY — Rectangular (R) or Polar (P)?"
        case .pickBasePoint: return "ARRAY — specify base point"
        case .pickFields:
            guard let f = pendingField else { return arraySummary }
            switch f {
            case .rows: return "ARRAY (rectangular) — number of rows <\(rows)>"
            case .columns: return "ARRAY (rectangular) — number of columns <\(columns)>"
            case .rowSpacing: return "ARRAY (rectangular) — row spacing <\(rowSpacing)>"
            case .columnSpacing: return "ARRAY (rectangular) — column spacing <\(columnSpacing)>"
            case .axisAngle: return "ARRAY (rectangular) — axis angle (deg) <\(axisAngleDeg)> — Enter to finish"
            case .count: return "ARRAY (polar) — number of items <\(count)>"
            case .fillAngle: return "ARRAY (polar) — angle to fill (deg) <\(fillAngleDeg)>"
            case .rotateItems: return "ARRAY (polar) — rotate items? Y/N <\(rotateItems ? "Y" : "N")> — Enter to finish"
            }
        }
    }

    private var arraySummary: String {
        switch kind {
        case .rectangular: return "ARRAY (rectangular) — \(rows)x\(columns), press Enter to commit"
        case .polar: return "ARRAY (polar) — \(count) items, press Enter to commit"
        case .path: return "ARRAY (path) — not yet supported"
        }
    }
}
