//
//  GripDragState.swift
//  DWGViewer / Editing
//
//  Interactive state for dragging ONE grip (see `GripEditing.swift` for the
//  underlying data model/mutation) of the single currently-selected grip-
//  editable entity. Distinct from `MoveState`/`ModifyToolState` (which move
//  a WHOLE entity/selection) — this reshapes ONE defining point of ONE
//  entity, which is the mechanism behind "extrude/extend a section of an
//  enclosed object" (see this feature's own product research: neither MOVE
//  nor Explode+Move can do this without severing connected edges).
//
//  Shape mirrors `MoveState`'s own click-driven design (drag a point, with
//  a live rubber-band/ghost preview) rather than `ModifyToolState`'s
//  multi-phase command-verb design, since grip editing isn't a typed
//  command at all — it's a direct-manipulation interaction that only makes
//  sense while exactly one grip-editable entity is selected and idle (no
//  other tool active). `ContentView` gates entry into `.dragging` on that
//  precondition; this type itself doesn't know about selection.
//

import Foundation
import CoreGraphics

struct GripDragState: Equatable {
    enum Phase: Equatable { case idle, hovering, dragging }
    var phase: Phase = .idle
    /// The entity + grip index currently hovered (phase == .hovering) or
    /// being dragged (phase == .dragging).
    var entityId: EntityID? = nil
    var gripIndex: Int? = nil
    /// Live cursor position while dragging (world space, post-OSNAP if a
    /// snap was found) — the candidate new position for the dragged grip.
    var hover: CGPoint? = nil
    var snap: SnapResult? = nil

    var isActive: Bool { phase == .dragging }

    var prompt: String {
        switch phase {
        case .idle, .hovering: return ""
        case .dragging: return "Specify new location for grip"
        }
    }
}
