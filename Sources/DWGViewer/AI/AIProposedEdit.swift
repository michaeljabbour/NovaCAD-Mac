import Foundation
import CoreGraphics

// MARK: - AI Assistant: the write side (proposed bulk edits)
//
// Per this feature's product decision, the AI never mutates the drawing
// directly — it PROPOSES a plan (a list of `AIProposedEdit`s), which the
// panel UI shows to the user for review, and only "Apply" commits them, all
// as ONE undoable transaction (mirrors `recolorSelectedMarkup`'s bulk-edit
// idiom — see `ContentView.swift` — but funneled through a single
// `session.performEdit` call for the WHOLE batch rather than one per edit,
// so Undo reverts the entire AI-proposed change in one step).
//
// Scope decision (see this feature's own research phase): "rename an
// object" is implemented as SETTING AN ATTRIBUTE VALUE
// (`BlockEditor.setAttribute`), not renaming the underlying block
// DEFINITION — there is no existing UI/API for the latter anywhere in this
// codebase, and renaming a block definition would rename EVERY instance of
// that block type at once, which is almost certainly not what a user means
// by "rename this one workstation." A future, explicitly-separate verb could
// add block-definition renaming if a real need for it emerges.
struct AIProposedEdit: Identifiable, Codable {
    let id: UUID
    /// The INSERT (block reference) this edit targets, by stable `EntityID.raw`.
    var insertEntityId: Int32
    /// The ATTRIB tag to set (e.g. "NAME", "STATION_ID").
    var attributeTag: String
    /// The value currently on that attribute, if known (for display —
    /// "OLD → NEW" — not otherwise used; re-read fresh at apply time so a
    /// stale display value never silently overwrites something a user
    /// nudged in between proposing and applying). `nil` also covers "this
    /// INSERT has no such tag today" — the bulk-add case (see `willCreate`)
    /// — not just "unknown," so the review card can say "(new attribute)"
    /// rather than a misleading "(none)" that implies the tag exists but is
    /// blank.
    var oldValue: String?
    var newValue: String
    /// True when applying this edit will CREATE a brand-new ATTRIB (this
    /// INSERT doesn't have `attributeTag` yet) rather than update an existing
    /// one — set at proposal time from the same read `oldValue == nil` came
    /// from, so the review card can distinguish "add a new tag to N objects"
    /// from "update an existing one" instead of both looking like a plain
    /// "(none) → X". Re-validated at apply time exactly like `oldValue`
    /// (via `BlockEditor.setOrCreateAttribute`'s own return value), so a tag
    /// added by some OTHER edit in between proposing and applying doesn't
    /// silently create a duplicate.
    var willCreate: Bool

    init(id: UUID = UUID(), insertEntityId: Int32, attributeTag: String,
         oldValue: String?, newValue: String, willCreate: Bool = false) {
        self.id = id
        self.insertEntityId = insertEntityId
        self.attributeTag = attributeTag
        self.oldValue = oldValue
        self.newValue = newValue
        self.willCreate = willCreate
    }
}

@MainActor
enum AIProposedEditApplier {
    /// Applies every edit in `edits` as ONE undoable transaction via
    /// `session.performEdit` — the idiom `ContentView.recolorSelectedMarkup`/
    /// `deleteSelectedMarkup` already establish for "loop over ids, one
    /// `Transaction` for the whole batch."
    ///
    /// Uses `BlockEditor.setOrCreateAttribute` (not the plain `setAttribute`
    /// the single-edit `propose_attribute_edits` flow historically used) so a
    /// `willCreate` edit (the bulk "add a NEW tag to every object on layer Z"
    /// case — see `AIProposedEdit.willCreate`'s own doc comment) actually
    /// creates the ATTRIB rather than silently no-op'ing; an edit that turns
    /// out to already exist by apply time (e.g. some OTHER edit created it in
    /// between) is just updated instead, which is still the correct outcome.
    ///
    /// Returns the count of edits that actually wrote something (an edit
    /// whose target INSERT no longer resolves — e.g. deleted since the plan
    /// was proposed — is silently skipped, and one whose value already
    /// matched is a genuine no-op per `setOrCreateAttribute`'s `.unchanged`
    /// case, matching re-running an unedited Data Import being a no-op too).
    @discardableResult
    static func apply(_ edits: [AIProposedEdit], session: DocumentSession, regen: RegenCoordinator) -> Int {
        guard !edits.isEmpty else { return 0 }
        var applied = 0
        session.performEdit("AI Assistant Edit") { tx in
            for edit in edits {
                let insertId = EntityID(raw: edit.insertEntityId)
                switch BlockEditor.setOrCreateAttribute(insertId, tag: edit.attributeTag,
                                                        value: edit.newValue, in: regen.parsed, tx: tx) {
                case .created, .updated: applied += 1
                case .unchanged, nil: break
                }
            }
        }
        return applied
    }
}
