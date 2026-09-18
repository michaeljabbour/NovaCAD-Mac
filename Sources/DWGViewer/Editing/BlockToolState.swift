//
//  BlockToolState.swift
//  DWGViewer / Editing
//
//  Phase 6.1 — interactive state machine for BLOCK and INSERT, mirroring
//  ModifyToolState's overall shape (acquire -> geometric parameter(s) ->
//  commit) since both commands are, like COPY/ROTATE/SCALE/MIRROR, a
//  "gather some points/values via the command bar or clicks, then commit
//  through ONE transaction" interaction — but distinct from ModifyToolState
//  itself because BLOCK/INSERT operate on BLOCK DEFINITIONS/NAMES, not on
//  an ambient object selection being transformed in place (see
//  ModifyToolState.swift's own doc comment for why TrimExtend/FilletChamfer/
//  Offset each got their own parallel type instead of folding into
//  ModifyToolState — the same reasoning applies here).
//

import Foundation
import CoreGraphics

enum BlockCommand: Equatable {
    case block   // BLOCK/B: select objects -> pick base point -> name -> commit
    case insert  // INSERT/I: pick block name -> pick placement point -> commit

    var displayName: String {
        switch self {
        case .block: return "Block"
        case .insert: return "Insert"
        }
    }
}

enum BlockPhase: Equatable {
    case idle
    /// BLOCK only: acquiring the object set via `SelectionPrompt` — skipped
    /// entirely when PICKFIRST noun-verb applies (non-empty selection at
    /// invocation), exactly like `ModifyToolState.selecting`.
    case selecting
    /// BLOCK only: waiting for the base-point click.
    case pickBasePoint
    /// BLOCK only: base point acquired; waiting for the block name (fed via
    /// the command bar's text-prompt alert, same UI pattern as the TEXT
    /// tool's `pendingTextInput`/`showTextPrompt`).
    case pickName
    /// INSERT only: waiting for the placement-point click (block name is
    /// already fixed at `begin(...)` time, chosen via the block-name picker
    /// menu — same "picker before the modal state exists" shape as the
    /// Stamp tool's `stampBlockName`).
    case pickInsertPoint
}

/// Drives BLOCK's and INSERT's interactive lifecycle. A single type (like
/// `ModifyToolState`) rather than two, since ContentView already follows
/// the "one active modal tool state at a time" convention throughout, and
/// BLOCK/INSERT never run concurrently.
struct BlockToolState: Equatable {
    var command: BlockCommand
    var phase: BlockPhase = .idle

    /// BLOCK: objects being blockified — set once acquisition finishes.
    var objectIDs: Set<EntityID> = []
    /// BLOCK: base point, once picked.
    var basePoint: CGPoint? = nil
    /// INSERT: the block name chosen via the picker BEFORE this state
    /// became active (mirrors `stampBlockName` — the picker itself is
    /// ordinary SwiftUI Menu/Picker UI outside this state machine).
    var insertBlockName: String? = nil
    /// Live cursor position (world) — ghost preview + ATTRIB anchor
    /// direction inference, mirrors every other tool's `hover` field.
    var hover: CGPoint? = nil
    var snap: SnapResult? = nil

    var isActive: Bool { phase != .idle }

    /// BLOCK, PICKFIRST/interactive acquisition dispatcher — mirrors
    /// `ModifyToolState.begin(_:preselection:)` exactly.
    static func beginBlock(preselection: Set<EntityID>) -> BlockToolState {
        var state = BlockToolState(command: .block)
        if !preselection.isEmpty {
            state.objectIDs = preselection
            state.phase = .pickBasePoint
        } else {
            state.phase = .selecting
        }
        return state
    }

    /// INSERT: block name already chosen (via the picker) — the state
    /// starts directly at `.pickInsertPoint` since there's no ambient
    /// selection to acquire.
    static func beginInsert(blockName: String) -> BlockToolState {
        var state = BlockToolState(command: .insert)
        state.insertBlockName = blockName
        state.phase = .pickInsertPoint
        return state
    }

    /// BLOCK: transitions from `.selecting` once `SelectionPrompt` finishes
    /// with a non-empty result — mirrors `ModifyToolState.withAcquiredObjects`.
    mutating func withAcquiredObjects(_ ids: Set<EntityID>) {
        objectIDs = ids
        phase = .pickBasePoint
    }

    var prompt: String {
        switch phase {
        case .idle:
            return ""
        case .selecting:
            return "BLOCK — Select objects:"
        case .pickBasePoint:
            return "BLOCK — specify base point"
        case .pickName:
            return "BLOCK — enter block name"
        case .pickInsertPoint:
            return "INSERT \(insertBlockName ?? "") — specify insertion point"
        }
    }
}
