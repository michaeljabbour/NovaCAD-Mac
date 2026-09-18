//
//  OffsetToolState.swift
//  DWGViewer / Editing
//
//  Phase 4.5 — interactive state machine for OFFSET: distance (persisted
//  OFFSETDIST) or through-point mode -> click object -> click side (or
//  through point) -> commit -> repeat until Esc.
//

import Foundation
import CoreGraphics

enum OffsetPhase: Equatable {
    case idle
    /// Waiting for the object to offset (distance/mode already fixed for
    /// this invocation — set at `begin(...)` time from OFFSETDIST/the
    /// through-point flag, matching AutoCAD's "distance is asked once,
    /// then repeats" default).
    case pickObject
    /// Object acquired; waiting for the side-indicating click (distance
    /// mode) or the through-point click (through-point mode).
    case pickSideOrPoint
}

/// Drives one OFFSET command's interactive lifecycle. `throughPointMode`
/// is fixed for the lifetime of one `begin(...)` invocation (AutoCAD:
/// typing "T" switches to through-point mode for the REST of this command
/// run, not just the next single object) — toggled via the command-bar `T`
/// keyword before the first object pick, handled by the caller
/// constructing a new state with the flag flipped rather than mutating an
/// in-progress one (mirrors how `TrimExtendToolState`/`ModifyToolState`
/// treat their own "fixed at acquisition time" parameters).
struct OffsetToolState: Equatable {
    var phase: OffsetPhase = .idle
    var throughPointMode: Bool = false
    var objectId: EntityID? = nil
    /// Latest hover position — tracked purely for the hover-highlight
    /// preview (mirrors `TrimExtendToolState.hover`); OFFSET's `pickObject`
    /// phase picks a whole OBJECT, not a point, so no OSNAP applies there
    /// (the later `pickSideOrPoint` side-click also doesn't OSNAP — the
    /// side is determined by which side of the object the click falls on,
    /// not by snapping to a point).
    var hover: CGPoint? = nil

    var isActive: Bool { phase != .idle }

    static func begin(throughPointMode: Bool) -> OffsetToolState {
        var state = OffsetToolState()
        state.throughPointMode = throughPointMode
        state.phase = .pickObject
        return state
    }

    mutating func withObject(_ id: EntityID) {
        objectId = id
        phase = .pickSideOrPoint
    }

    /// Resets back to `.pickObject` after committing (or after an invalid
    /// pick) — OFFSET repeats with the SAME distance/mode until Esc,
    /// matching AutoCAD's default multi-offset behavior.
    mutating func resetForNextObject() {
        objectId = nil
        phase = .pickObject
    }

    var prompt: String {
        switch phase {
        case .idle:
            return ""
        case .pickObject:
            return throughPointMode
                ? "OFFSET (through-point) — select object to offset (or Esc to finish)"
                : "OFFSET — select object to offset (or Esc to finish)"
        case .pickSideOrPoint:
            return throughPointMode
                ? "OFFSET — specify through point"
                : "OFFSET — specify point on side to offset"
        }
    }
}
