//
//  StretchToolState.swift
//  DWGViewer / Editing
//
//  STRETCH — AutoCAD's "select by crossing window, then move a base point
//  to a destination, and every caught VERTEX moves while everything else
//  stays put" command. Built directly on `GripEditing`'s grip primitives
//  (`caughtGrips`/`applyStretch`) rather than `Transaction.modifyPayload`'s
//  whole-entity translate (which is what MOVE uses) — STRETCH's entire
//  point is reshaping PART of an entity while the rest stays fixed, exactly
//  the scenario `GripEditing.swift`'s header comment describes.
//
//  DESIGN DECISION: unlike every other modify-family command, STRETCH's
//  acquisition step can't reuse `SelectionPrompt` as-is — `SelectionPrompt`
//  only remembers the RESULTING set of touched `EntityID`s, but
//  `GripEditing.caughtGrips` needs the actual crossing RECT to know WHICH
//  vertices of a touched entity were caught (a crossing window over the
//  right edge of a square must NOT also catch the left edge's vertices,
//  even though the square itself is "touched"). Rather than teaching
//  `SelectionPrompt` about a second, richer acquisition result shape (which
//  every OTHER caller would have to ignore), this type accumulates the
//  already-resolved `GripEditing.CaughtGrip`s directly — `ContentView`
//  computes each crossing drag's catch (`SelectionEngine.rectSelect` for
//  "which entities does this rect touch" + `GripEditing.caughtGrips` for
//  "which of THEIR grips fall inside it") and appends the result here,
//  the same "resolve immediately, accumulate the resolved thing" shape
//  `SelectionPrompt.applyAcquisition` itself uses for box/lasso/fence
//  batches. A plain (non-crossing) click on a whole object appends ALL of
//  that entity's grips, matching AutoCAD's own "picked whole, moves whole"
//  STRETCH rule.
//

import Foundation
import CoreGraphics

struct StretchToolState: Equatable {
    enum Phase: Equatable {
        case idle
        /// Accumulating caught grips via crossing-window drags / whole-
        /// object clicks — see `ContentView.handleStretchBoxSelect`/
        /// `handleStretchClick`.
        case selecting
        case pickingBase
        case pickingDestination
    }
    var phase: Phase = .idle

    /// Every grip caught so far, keyed by (entityId, gripIndex) to keep
    /// re-crossing the same vertex in a second drag from producing a
    /// duplicate (which `applyStretch` would otherwise apply the delta to
    /// twice). Order doesn't matter for correctness; a plain array (not a
    /// Set, since `CaughtGrip` isn't `Hashable`) with de-duplication on
    /// insert is simplest.
    var caught: [GripEditing.CaughtGrip] = []

    var basePoint: CGPoint? = nil
    var hover: CGPoint? = nil
    var snap: SnapResult? = nil

    var isActive: Bool { phase != .idle }

    /// Adds `newlyCaught`, skipping any (entityId, gripIndex) already
    /// present — mirrors `SelectionPrompt.applyAcquisition`'s own "batch
    /// acquisitions add to the accumulated set" convention (shift-to-add is
    /// STRETCH's only mode; AutoCAD's real command has no "remove mode"
    /// analog for crossing windows, so there is no shiftHeld-toggle here).
    mutating func addCaught(_ newlyCaught: [GripEditing.CaughtGrip]) {
        var seen = Set(caught.map { EntityGripKey(entityId: $0.entityId, gripIndex: $0.gripIndex) })
        for grip in newlyCaught {
            let key = EntityGripKey(entityId: grip.entityId, gripIndex: grip.gripIndex)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            caught.append(grip)
        }
    }

    private struct EntityGripKey: Hashable {
        var entityId: EntityID
        var gripIndex: Int
    }

    var prompt: String {
        switch phase {
        case .idle:
            return ""
        case .selecting:
            let count = caught.count
            return count == 0
                ? "STRETCH — select objects to stretch by crossing-window or crossing-polygon, then <Enter>"
                : "STRETCH — select objects (\(count) point(s) found), <Enter> to finish"
        case .pickingBase:
            return "STRETCH — specify base point"
        case .pickingDestination:
            return "STRETCH — specify destination point"
        }
    }
}
