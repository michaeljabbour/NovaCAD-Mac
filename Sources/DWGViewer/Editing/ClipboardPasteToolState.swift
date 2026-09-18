//
//  ClipboardPasteToolState.swift
//  DWGViewer / Editing
//
//  "Paste" (cross-drawing Copy/Paste — see `CrossDocumentPaste.swift`'s
//  header comment) interactive state — mirrors `XrefAttachToolState`'s exact
//  shape: everything else (which entities, from which layers/blocks) was
//  already decided at Copy time and is fully captured in the
//  `PasteboardSnapshot.Snapshot` read off `NSPasteboard`; all that remains
//  is a plain point pick for where to place it, via the same
//  hover/snap/plain-click machinery INSERT/Attach-Xref already use. A
//  separate type (not reusing `XrefAttachToolState`) for the same reason
//  `XrefAttachToolState`'s own header comment gives: each command family
//  gets its own parallel tool-state type per this codebase's established
//  convention, since the "parameters gathered before the modal state
//  exists" payload shape differs (a decoded pasteboard snapshot, not a
//  parsed candidate file).
//

import Foundation
import CoreGraphics

struct ClipboardPasteToolState {
    /// Non-nil while awaiting the placement click.
    var snapshot: PasteboardSnapshot.Snapshot? = nil
    var hover: CGPoint? = nil
    var snap: SnapResult? = nil

    var isActive: Bool { snapshot != nil }

    static func begin(_ snapshot: PasteboardSnapshot.Snapshot) -> ClipboardPasteToolState {
        var state = ClipboardPasteToolState()
        state.snapshot = snapshot
        return state
    }

    var prompt: String {
        guard snapshot != nil else { return "" }
        return "PASTE — specify insertion point (or use \u{201c}Paste at Original Coordinates\u{201d})"
    }
}
