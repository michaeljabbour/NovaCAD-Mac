//
//  FilletChamferToolState.swift
//  DWGViewer / Editing
//
//  Phase 4.4 — interactive state machine for FILLET/CHAMFER: click first
//  line -> click second line -> commit immediately (a 2-click-per-corner
//  gesture, repeating until Esc — AutoCAD's own FILLET/CHAMFER default
//  behavior when no `P` (polyline-all) keyword is used).
//
//  DESIGN DECISION (documented per the plan's request, mirroring
//  `TrimExtendToolState`/`ModifyToolState`'s own header comments): this is
//  its own third-ish parallel type rather than reusing `TrimExtendToolState`
//  or `ModifyToolState` — FILLET/CHAMFER's shape (exactly 2 entity clicks
//  per corner, no boundary-acquisition step, no batch/fence mode, immediate
//  per-corner commit) doesn't fit either existing type's phase enum
//  cleanly, and forcing it in would mean several phase cases that are
//  meaningless for this command (mirroring the same reasoning that kept
//  MOVE on `MoveState` instead of unifying it into `ModifyToolState`).
//

import Foundation
import CoreGraphics

enum FilletChamferCommand: Equatable {
    case fillet
    case chamfer

    var displayName: String {
        switch self {
        case .fillet: return "Fillet"
        case .chamfer: return "Chamfer"
        }
    }
}

enum FilletChamferPhase: Equatable {
    case idle
    /// Waiting for the first line click (keywords R/P/D/A/T are accepted
    /// here — see `FilletChamferToolState.prompt`).
    case pickFirst
    /// First line acquired; waiting for the second.
    case pickSecond
}

/// Drives one FILLET or CHAMFER command's interactive lifecycle. Radius
/// (FILLET) / distances-or-angle (CHAMFER) are read from `SysVars`
/// (`FILLETRAD`; CHAMFER's own d1/d2/angle aren't separately-named sysvars
/// in the Phase 0.6 spec, so this session persists them as plain
/// `@State`-equivalent fields on `DocumentSession` instead — see
/// `DocumentSession.chamferD1`/`chamferD2`/`chamferAngleMode`) rather than
/// re-prompting every single click, matching AutoCAD's own "radius/distance
/// persists across invocations within a session" behavior.
struct FilletChamferToolState: Equatable {
    var command: FilletChamferCommand
    var phase: FilletChamferPhase = .idle

    var firstTargetId: EntityID? = nil
    /// World-space point of the FIRST click — needed by `FilletChamfer.fillet`/
    /// `chamfer` as `clickPoint1` (which side of line1 the user picked).
    var firstClickPoint: CGPoint? = nil
    /// Latest hover position while picking either line — tracked purely for
    /// the hover-highlight preview (mirrors `TrimExtendToolState.hover`); no
    /// OSNAP applies here since FILLET/CHAMFER pick whole OBJECTS, not points.
    var hover: CGPoint? = nil

    var isActive: Bool { phase != .idle }

    static func begin(_ command: FilletChamferCommand) -> FilletChamferToolState {
        var state = FilletChamferToolState(command: command)
        state.phase = .pickFirst
        return state
    }

    mutating func withFirstTarget(_ id: EntityID, at point: CGPoint) {
        firstTargetId = id
        firstClickPoint = point
        phase = .pickSecond
    }

    /// Resets back to `.pickFirst` after committing a corner (or after an
    /// invalid second pick) — the command stays active so the user can
    /// keep filleting/chamfering more corners without re-invoking it,
    /// matching AutoCAD's own repeat-until-Esc default.
    mutating func resetForNextCorner() {
        firstTargetId = nil
        firstClickPoint = nil
        phase = .pickFirst
    }

    var prompt: String {
        switch phase {
        case .idle:
            return ""
        case .pickFirst:
            return "\(command.displayName) — select first line (or Esc to finish)"
        case .pickSecond:
            return "\(command.displayName) — select second line"
        }
    }
}
