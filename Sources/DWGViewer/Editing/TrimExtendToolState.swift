//
//  TrimExtendToolState.swift
//  DWGViewer / Editing
//
//  Phase 4.3 — interactive state machine for TRIM/EXTEND: "Select cutting
//  edges or <Enter> for all visible" -> click loop on individual targets
//  (Shift+click toggles trim<->extend for that click; drag = fence batch).
//
//  DESIGN DECISION (documented per the plan's request, mirroring
//  `ModifyToolState`'s own header comment): TRIM/EXTEND's interaction shape
//  is genuinely different from `ModifyToolState`'s "select ALL objects up
//  front, then transform them all at once" — here, boundary acquisition
//  happens ONCE, but then each subsequent click independently trims/extends
//  ONE target and immediately commits (AutoCAD: every click at the
//  Select-object-to-trim prompt is its own mini-transaction), looping until
//  Enter/Esc. Shoehorning this into `ModifyToolState`'s phase enum would
//  require either a fake "one object at a time" `objectIDs` re-interpretation
//  or a parallel phase branch that doesn't fit the existing type's shape at
//  all — a new, additive type is the same judgment call the previous session
//  made for COPY/ROTATE/SCALE/MIRROR vs. MOVE, applied consistently here.
//
//  `SelectionPrompt` IS reused as-is for the boundary-acquisition step
//  (identical semantics: click objects, W/C/F/ALL/etc, Enter to finish) —
//  only the FOLLOW-ON per-target click loop is new state, not a
//  reinvention of "Select objects:".
//

import Foundation
import CoreGraphics

enum TrimExtendCommand: Equatable {
    case trim
    case extend

    var displayName: String {
        switch self {
        case .trim: return "Trim"
        case .extend: return "Extend"
        }
    }
}

enum TrimExtendPhase: Equatable {
    case idle
    /// Acquiring cutting/boundary edges via `SelectionPrompt`. A bare Enter
    /// with NOTHING picked is valid here (unlike every `ModifyToolState`
    /// command) and means "all visible, resolved lazily per target" — see
    /// `TrimExtendToolState.boundaryMode`.
    case selectingBoundaries
    /// Click loop: each click trims/extends ONE target and immediately
    /// commits; Shift+click toggles this click's trim<->extend sense;
    /// stays in this phase until Enter/Esc. A drag (fence) batches multiple
    /// targets from one gesture, still without leaving this phase.
    case pickingTargets
}

/// Drives one TRIM or EXTEND command's full interactive lifecycle.
struct TrimExtendToolState: Equatable {
    var command: TrimExtendCommand
    var phase: TrimExtendPhase = .idle

    /// Explicitly-picked boundary/cutting-edge ids — empty AND
    /// `usedAllVisible == true` together mean "Enter for all visible"
    /// (lazy per-target resolution, per the plan's hard performance
    /// requirement); empty with `usedAllVisible == false` never actually
    /// occurs in a committed state (an empty pick with Enter always sets
    /// `usedAllVisible`).
    var boundaryIDs: Set<EntityID> = []
    var usedAllVisible: Bool = false

    /// Live cursor position (world) — used for hover-based candidate
    /// preview/ghost, matching `ModifyToolState.hover`'s role.
    var hover: CGPoint? = nil
    var snap: SnapResult? = nil

    var isActive: Bool { phase != .idle }

    static func begin(_ command: TrimExtendCommand) -> TrimExtendToolState {
        var state = TrimExtendToolState(command: command)
        state.phase = .selectingBoundaries
        return state
    }

    /// Transitions from `.selectingBoundaries` — `nil` ids (Enter with
    /// nothing picked) means "all visible, extended" per the plan; a
    /// non-empty explicit set means "just these boundaries."
    mutating func withAcquiredBoundaries(_ ids: Set<EntityID>?) {
        if let ids, !ids.isEmpty {
            boundaryIDs = ids
            usedAllVisible = false
        } else {
            boundaryIDs = []
            usedAllVisible = true
        }
        phase = .pickingTargets
    }

    var prompt: String {
        switch phase {
        case .idle:
            return ""
        case .selectingBoundaries:
            return "\(command.displayName) — select cutting edges or <Enter> for all visible, extended"
        case .pickingTargets:
            let modeNote = command == .trim ? "(Shift = Extend)" : "(Shift = Trim)"
            return "\(command.displayName) — select object to \(command.displayName.lowercased()) \(modeNote), or <Enter>/Esc to finish"
        }
    }
}
