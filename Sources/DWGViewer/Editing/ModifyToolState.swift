//
//  ModifyToolState.swift
//  DWGViewer / Editing
//
//  Phase 4.2 — state machine for COPY/ROTATE/SCALE/MIRROR. MOVE keeps using
//  the existing `MoveState` (DraftingTools.swift) UNCHANGED — see the design
//  note below for why this phase adds a NEW parallel type instead of
//  generalizing `MoveState` in place, per the plan's explicit "use your
//  judgment" allowance.
//
//  DESIGN DECISION (documented per the plan's request): the plan's original
//  vision was for `MoveState` to become `.modify(.move)`, folding all 5
//  commands into one state shape. `MoveState` is deeply wired into
//  ContentView.swift (~20 call sites) and DXFCanvasView.swift (ghost-preview
//  drawing, ContextMenuAction wiring) as of Phase 1.7 — ALL of which are
//  shared files a separate, concurrently-running agent may also be editing
//  for unrelated Phase 4-adjacent work. Generalizing `MoveState` in place
//  would touch every one of those call sites for a purely mechanical
//  rename/reshape with no functional benefit (MOVE's actual behavior is not
//  changing), while meaningfully raising merge-conflict risk and the chance
//  of a subtle regression in a tool that already shipped and works
//  correctly (including the OSNAP-`excluding:` fix from the immediately
//  prior session, which a mechanical refactor could easily reintroduce).
//  Adding a NEW, additive `ModifyToolState` for COPY/ROTATE/SCALE/MIRROR
//  ONLY achieves the plan's actual goal (these 4 commands share one state
//  machine, driven through `SelectionPrompt` for acquisition, transformed
//  via `EntityTransform`/`Transaction.transform`/`copyTransformed`) without
//  touching MOVE's existing, working code path at all. `Command` still
//  includes `.move` (never constructed by this session's wiring) so the
//  enum's shape matches the plan's stated one and a FUTURE session can
//  freely choose to consolidate MOVE into this type later without an enum
//  case rename.
//

import Foundation
import CoreGraphics

enum ModifyCommand: Equatable {
    case move       // reserved — MOVE still runs on the separate MoveState; see type-level doc comment
    case copy
    case rotate
    case scale
    case mirror
    // Future phases (not implemented here — see the plan's 4.3/4.4/4.5):
    // case trim, extend, offset, fillet, chamfer, array(kind: ArrayKind), explode

    var displayName: String {
        switch self {
        case .move: return "Move"
        case .copy: return "Copy"
        case .rotate: return "Rotate"
        case .scale: return "Scale"
        case .mirror: return "Mirror"
        }
    }
}

enum ModifyPhase: Equatable {
    case idle
    /// Acquiring the object set via `SelectionPrompt` — skipped entirely
    /// when PICKFIRST noun-verb applies (non-empty selection at invocation).
    case selecting
    case pickBase        // ROTATE/SCALE: the pivot point; not used by MIRROR (which picks a LINE, not a point)
    case pickDestination // COPY: where to place this placement (loops until Esc/Enter)
    case pickAngle        // ROTATE: second point (or typed angle) defining the rotation
    case pickFactor        // SCALE: second point (or typed factor) defining the scale
    case pickMirrorEnd    // MIRROR: second point of the mirror line (first point reuses pickBase's semantics as "line start")
    /// MIRROR only: AutoCAD's "Erase source objects? [Yes/No]" confirmation
    /// after the mirror line is set — deferred to a future refinement (this
    /// phase always keeps the source, i.e. always answers "No"); the phase
    /// case exists so `ModifyToolState`'s shape doesn't need to change when
    /// that refinement lands.
    case confirmEraseSource
}

/// Drives the interactive lifecycle of COPY/ROTATE/SCALE/MIRROR: acquire
/// objects (PICKFIRST or `SelectionPrompt`), then gather the command-specific
/// geometric parameters (base point, angle/factor, or mirror line), applying
/// a live ghost preview throughout, then commit via ONE transaction (COPY
/// commits once per placement and loops back to `.pickDestination` until
/// Esc/Enter, matching AutoCAD's multi-copy default).
struct ModifyToolState: Equatable {
    var command: ModifyCommand
    var phase: ModifyPhase = .idle

    /// Objects being transformed — set once acquisition finishes (PICKFIRST
    /// immediate, or `SelectionPrompt.result == .done`).
    var objectIDs: Set<EntityID> = []

    /// ROTATE/SCALE pivot, or MIRROR line's first point.
    var basePoint: CGPoint? = nil
    /// MIRROR line's second point.
    var mirrorEndPoint: CGPoint? = nil
    /// Live cursor position (world), for ghost preview + typed-angle/factor
    /// direction inference — mirrors `MoveState.hover`'s exact role.
    var hover: CGPoint? = nil
    var snap: SnapResult? = nil

    /// The provisional transform implied by the current basePoint/
    /// mirrorEndPoint/hover — computed by `ContentView` each time hover
    /// updates (not stored redundantly here since it's cheap to recompute
    /// and keeping ONE source of truth — the raw points — avoids a
    /// staleness bug where `hover` and a cached transform disagree).

    var isActive: Bool { phase != .idle }

    /// PICKADD/PICKFIRST plumbing: true once acquisition has produced a
    /// non-empty set and geometric parameter collection has begun (used to
    /// decide whether Esc aborts the WHOLE command vs. just steps back —
    /// this phase always fully aborts on Esc, matching `MoveState`'s
    /// existing "Esc always fully resets" convention, but the flag is kept
    /// for a future incremental-step-back refinement).
    var hasAcquiredObjects: Bool { !objectIDs.isEmpty }

    var prompt: String {
        switch phase {
        case .idle:
            return ""
        case .selecting:
            return "Select objects:"
        case .pickBase:
            switch command {
            case .rotate: return "\(command.displayName) — specify base point"
            case .scale: return "\(command.displayName) — specify base point"
            case .mirror: return "\(command.displayName) — specify first point of mirror line"
            default: return "\(command.displayName) — specify base point"
            }
        case .pickDestination:
            return "\(command.displayName) — specify destination point (Enter/Esc to finish)"
        case .pickAngle:
            return "\(command.displayName) — specify rotation angle"
        case .pickFactor:
            return "\(command.displayName) — specify scale factor"
        case .pickMirrorEnd:
            return "\(command.displayName) — specify second point of mirror line"
        case .confirmEraseSource:
            return "\(command.displayName) — erase source objects? [Yes/No] <N>"
        }
    }

    /// Constructs the state a modify command starts in: if `preselection` is
    /// non-empty (PICKFIRST), objects are already acquired and the state
    /// jumps straight to the command's first geometric-parameter phase;
    /// otherwise it starts in `.selecting` (caller drives a `SelectionPrompt`
    /// and calls `withAcquiredObjects` once that finishes).
    static func begin(_ command: ModifyCommand, preselection: Set<EntityID>) -> ModifyToolState {
        var state = ModifyToolState(command: command)
        if !preselection.isEmpty {
            state.objectIDs = preselection
            state.phase = command.firstParameterPhase
        } else {
            state.phase = .selecting
        }
        return state
    }

    /// Transitions from `.selecting` once `SelectionPrompt` finishes with a
    /// non-empty result; an EMPTY result (user hit Enter with nothing
    /// picked, or Esc) is the caller's responsibility to treat as a full
    /// cancel (reset to `ModifyToolState()`) rather than calling this.
    mutating func withAcquiredObjects(_ ids: Set<EntityID>) {
        objectIDs = ids
        phase = command.firstParameterPhase
    }
}

private extension ModifyCommand {
    /// The phase a command lands in immediately after object acquisition
    /// completes (PICKFIRST or interactive) — ROTATE/SCALE/MIRROR all start
    /// by asking for a base/line point; COPY does too (its "base point" is
    /// the reference point later placements are offset from, exactly like
    /// MOVE's basePoint).
    var firstParameterPhase: ModifyPhase {
        switch self {
        case .move, .copy, .rotate, .scale: return .pickBase
        case .mirror: return .pickBase   // "first point of mirror line"
        }
    }
}
