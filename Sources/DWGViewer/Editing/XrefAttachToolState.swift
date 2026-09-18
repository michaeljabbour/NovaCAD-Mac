//
//  XrefAttachToolState.swift
//  DWGViewer / Editing
//
//  "Attach Xref…" interactive state — mirrors `BlockToolState`'s INSERT shape
//  (`.pickInsertPoint`, hover/snap, plain-point click) exactly, since
//  attaching an xref ends the same way INSERT does: the user has already
//  chosen everything else (here: source file + layer subset, via
//  `XrefAttachSheet`) and just needs to click a placement point on the
//  canvas — see `BlockToolState.pickInsertPoint`'s own doc comment for why
//  that phase has no object-selection step. A separate type (rather than
//  reusing `BlockToolState` itself) because this command's "parameters
//  gathered before the modal state exists" payload (a fully-parsed candidate
//  document + a layer-name subset) doesn't fit `BlockToolState`'s
//  `insertBlockName: String?` shape, and per this codebase's own established
//  convention (see `BlockToolState.swift`'s header comment) each command
//  family gets its own parallel tool-state type rather than overloading an
//  existing one.
//

import Foundation
import CoreGraphics

struct XrefAttachToolState {
    /// Non-nil while awaiting the placement click.
    var pending: XrefAttach.PendingAttach? = nil
    var selectedLayerNames: Set<String> = []
    var hover: CGPoint? = nil
    var snap: SnapResult? = nil

    var isActive: Bool { pending != nil }

    static func begin(pending: XrefAttach.PendingAttach, selectedLayerNames: Set<String>) -> XrefAttachToolState {
        var state = XrefAttachToolState()
        state.pending = pending
        state.selectedLayerNames = selectedLayerNames
        return state
    }

    var prompt: String {
        guard let pending else { return "" }
        return "ATTACH XREF \(pending.suggestedBlockName) — specify insertion point"
    }
}
