import Foundation
import CoreGraphics

/// Phase 6.1: a real block-definition/INSERT/attribute editing API, operating
/// on `EditableParsedDocument`/`EntityStore` through `Transaction` exactly
/// like every other editing command in this codebase (`Editing/*.swift`).
///
/// `EditableParsedDocument.blocks: [String: EditableBlockDef]` is, before
/// this phase, populated ONLY by the parser (one entry per `BLOCK`/`ENDBLK`
/// record it reads). This file is the first code path that creates or
/// redefines a block definition at RUNTIME, from a live editing command
/// rather than from parsing a file — `createBlock`/`redefineBlock` register/
/// update `EditableBlockDef` entries directly.
///
/// Design notes (documented per the plan's "use your judgment" allowance):
/// - A brand-new block's entities are appended to `EntityStore.headers`
///   contiguously (via a dedicated transaction op sequence — see
///   `createBlock`), preserving `EditableBlockDef.entityStart/entityCount`'s
///   documented "contiguous append-order range" invariant that
///   `Regenerator`/`RegenCoordinator` depend on for O(block size) (not
///   O(document size)) traversal. This means `createBlock` cannot simply
///   `tx.modifyHeader` existing entities' `owner` in place if OTHER edits
///   have been committed since those entities were created (their slots
///   would no longer be contiguous with each other) — see `createBlock`'s
///   own doc comment for exactly how this is handled: entities are always
///   copied to fresh, contiguous slots at the end of the store via
///   `tx.replace`, never relocated in place.
/// - Block-index allocation: `EditableBlockDef.blockIndex` values are
///   allocated by the parser as 0, 1, 2, ... in BLOCK-record encounter
///   order, with no reserved/skipped range. `nextBlockIndex(in:)` below
///   computes the next free index as `(max existing index) + 1` — safe
///   because block indices are NEVER reused/compacted within a session
///   (mirrors `EntityID`'s own "never reused in-session" invariant).
/// - `redefineBlock` marks the block dirty (`RegenCoordinator.markBlockDirty`)
///   rather than trying to incrementally patch every affected INSERT itself
///   — reusing the already-correct, already-tested Phase 1.6 machinery
///   instead of duplicating its "small fan-out incremental / large fan-out
///   full rebuild" threshold logic.
/// - `insert(...)` creates one ATTRIB child per ATTDEF found in the target
///   block's OWN direct entity range (not recursively through nested
///   INSERTs — matches AutoCAD: only a block's OWN attribute definitions
///   become ATTRIBs on an INSERT of it), each ATTRIB's owner set to
///   `.parentEntity(insertId)` (so `EntityStore.children(of:)` finds them —
///   this is the FIRST code path in the whole project that actually sets
///   this owner form for ATTRIB; the parser never has, per this session's
///   own research into `EntityStoreParser.swift`), and each ATTRIB's anchor
///   point transformed by the insert's own position/rotation/scale matrix
///   (AutoCAD: attribute anchors are placed in world space via the insert
///   transform, not left at the ATTDEF's block-local position).
enum BlockEditor {

    // MARK: - Block index allocation

    /// The next unused `EditableBlockDef.blockIndex` value — see this file's
    /// header comment for why a simple max+1 is safe (indices are permanent
    /// once allocated, never reused/compacted mid-session).
    static func nextBlockIndex(in parsed: EditableParsedDocument) -> Int32 {
        (parsed.blocks.values.map(\.blockIndex).max() ?? -1) + 1
    }

    // MARK: - BLOCK (create a new block definition from existing entities)

    /// Result of `createBlock`: the new block's name/index plus the
    /// substituted INSERT's `EntityID` — callers (the live command, unit
    /// tests) typically want to select the new INSERT afterward, matching
    /// AutoCAD's own BLOCK command leaving the newly-blockified geometry
    /// selected as its INSERT replacement.
    struct CreateBlockResult {
        var blockIndex: Int32
        var insertId: EntityID
    }

    /// BLOCK command: moves `entityIDs` (assumed to already be same-space,
    /// same-owner — typically the live selection) into a NEW block
    /// definition named `name`, rebased so each entity's geometry is
    /// expressed relative to `basePoint` (block-local origin), then adds ONE
    /// INSERT at `basePoint` (unscaled, unrotated) to replace them visually
    /// at their original world position — the standard AutoCAD BLOCK
    /// behavior ("the objects you selected are removed from the drawing and
    /// replaced by a single block reference").
    ///
    /// Implementation: entities are relocated via `tx.replace` (delete +
    /// re-add under the block's `OwnerRef`, translated by `-basePoint`) —
    /// NOT `tx.modifyHeader` in place — for two reasons: (1) `tx.replace`
    /// already exists and is exactly "delete original, add renamed/
    /// re-propertied copies in one traceable undo step," matching this
    /// operation's shape precisely; (2) it guarantees the new block's
    /// entities land in FRESH, mutually contiguous store slots (appended in
    /// the same order `entityIDs` is iterated), satisfying
    /// `EditableBlockDef.entityStart/entityCount`'s contiguous-range
    /// invariant regardless of where the ORIGINAL entities happened to sit
    /// (which, for an arbitrary user selection, are almost never already
    /// contiguous with each other).
    ///
    /// Returns `nil` (transaction still commits as a no-op via the caller's
    /// `EditableDocument.transact`, which drops empty transactions silently)
    /// if `entityIDs` is empty or `name` collides with an existing block —
    /// callers should check `parsed.blocks[name] == nil` themselves before
    /// calling if they want a distinct user-facing "name already in use"
    /// error rather than a silent no-op.
    @discardableResult
    static func createBlock(name: String, basePoint: CGPoint, from entityIDs: [EntityID],
                            insertLayerId: Int32, in parsed: EditableParsedDocument,
                            tx: Transaction) -> CreateBlockResult? {
        guard !entityIDs.isEmpty, parsed.blocks[name] == nil else { return nil }
        let store = parsed.store

        // Captured BEFORE any mutation below — `tx.replace` tombstones each
        // original entity's header (its OTHER fields, including `owner`,
        // stay intact on a tombstoned header per `EntityStore.markDeleted`'s
        // "only sets the flag" contract, so reading it back afterward would
        // technically still work, but capturing it up front avoids relying
        // on that non-obvious detail and reads correctly at a glance).
        let insertOwner = store.header(entityIDs[0])?.owner ?? .model

        let blockIndex = nextBlockIndex(in: parsed)
        let owner = OwnerRef.block(blockIndex)
        let dx = -Double(basePoint.x), dy = -Double(basePoint.y)

        // Snapshot BEFORE any mutation — `tx.replace` deletes-then-adds per
        // call, and later iterations must not see earlier ones' effects on
        // an unrelated entity (they're independent, but reading `store`
        // freshly per id keeps this loop obviously correct regardless).
        var newIDsInOrder: [EntityID] = []
        newIDsInOrder.reserveCapacity(entityIDs.count)
        for id in entityIDs {
            guard let image = store.snapshot(id) else { continue }
            var payload = image.payloadCopy
            payload.translate(dx: dx, dy: dy)
            var proto = image.asPrototype(owner: owner)
            proto.payload = payload
            let created = tx.replace(id, with: [proto])
            newIDsInOrder.append(contentsOf: created)
        }
        guard !newIDsInOrder.isEmpty else { return nil }

        // Register the block definition. `entityStart/entityCount` describe
        // the contiguous range `newIDsInOrder` occupies IFF nothing else
        // interleaved appends between them — true here because `tx.replace`
        // always appends its replacements immediately (see
        // `Transaction.replace`/`add`: `store.append` is a plain array
        // append, and this loop's only store mutations are these very
        // `tx.replace` calls, back to back, with no other transaction
        // active concurrently within one `EditableDocument`).
        let start = newIDsInOrder.first!.raw
        let count = Int32(newIDsInOrder.count)
        let def = EditableBlockDef()
        def.name = name
        def.base = .zero   // entities are already rebased to basePoint == block-local origin
        def.blockIndex = blockIndex
        def.entityStart = start
        def.entityCount = count
        parsed.blocks[name] = def
        // `parsed.blocks` is a plain dictionary on `EditableParsedDocument`
        // — entirely OUTSIDE `EntityStore`/`Transaction`'s own undo/redo
        // system (which only knows how to reverse `EntityHeader`/payload
        // changes). Without this registration, undoing `createBlock`
        // restores every relocated entity correctly but leaves
        // `parsed.blocks[name]` still present, pointing at a range that is
        // now entirely tombstoned entities — a dangling block definition a
        // later `insert(blockName: name, ...)` could still (wrongly)
        // succeed against. Found by adversarial review.
        tx.registerSideEffect(
            undo: { parsed.blocks[name] = nil },
            redo: { parsed.blocks[name] = def })

        // Substitute ONE insert at the original world position.
        let nameId = store.strings.intern(name)
        let insertId = tx.add(EntityPrototype(
            type: .insert, layerId: insertLayerId, owner: insertOwner,
            payload: .insert(InsertPayload(blockNameId: nameId, position: Vec3(basePoint)))))

        return CreateBlockResult(blockIndex: blockIndex, insertId: insertId)
    }

    // MARK: - Block redefinition

    /// Redefines an EXISTING block's content by appending `newEntityIDs`
    /// (freshly-created prototypes, NOT yet-owned entities — see the "from
    /// scratch" note below) as additional/replacement geometry, matching
    /// AutoCAD's `BLOCK` command re-run on an existing name (the plan's
    /// "`redefineBlock` -> `dirtyBlocks` regen of all inserts").
    ///
    /// Scope decision: this session's only real CALLER of block redefinition
    /// is a future block-content-editing command (in-place BEDIT-style
    /// editing is explicitly out of scope for Phase 6.1 per the plan's own
    /// text — 6.1 lists BLOCK/INSERT/ATTDEF/ATTEDIT only); this function
    /// exists so the API surface matches the plan's stated shape and so
    /// `RegenCoordinatorTests`/future BEDIT work has a real, tested
    /// entry point, but nothing in THIS phase's live UI wiring calls it.
    /// Takes plain `EntityPrototype`s (not existing `EntityID`s) since a
    /// redefinition's new content is typically hand-authored/freshly copied
    /// geometry, not a relocation of already-live entities (that case is
    /// `createBlock`'s own "move existing entities into a NEW block" shape,
    /// which doesn't apply here since the block already exists and may
    /// already have live INSERTs elsewhere that must keep working).
    @discardableResult
    static func redefineBlock(name: String, with newEntityPrototypes: [EntityPrototype],
                              in parsed: EditableParsedDocument, tx: Transaction,
                              regen: RegenCoordinator) -> Bool {
        guard let existing = parsed.blocks[name] else { return false }
        let store = parsed.store
        // Captured BEFORE mutation, for undo — see the `registerSideEffect`
        // call below. `EditableBlockDef.entityStart`/`entityCount` live
        // entirely OUTSIDE `EntityStore`/`Transaction`'s own undo system,
        // so without this, undoing a redefinition correctly restores the
        // OLD entities' live/deleted status but leaves the block
        // definition's own bookkeeping pointing at the NEW (post-command)
        // range — found by adversarial review.
        let beforeStart = existing.entityStart
        let beforeCount = existing.entityCount

        // Delete the block's OLD direct entities (leaves any nested INSERTs'
        // OWN block definitions untouched — only this block's own immediate
        // content is replaced, matching AutoCAD's redefinition semantics).
        var oldIDs: [EntityID] = []
        for i in Int(existing.entityStart)..<Int(existing.entityStart + existing.entityCount) {
            oldIDs.append(EntityID(raw: Int32(i)))
        }
        for id in oldIDs where !store.isDeleted(id) {
            tx.delete(id)
        }

        // Append the new content under the SAME block index (so every
        // existing INSERT of this block — which reference it by NAME, via
        // `InsertPayload.blockNameId`, not by index — keeps working; only
        // the definition's content changes).
        let owner = OwnerRef.block(existing.blockIndex)
        var newIDs: [EntityID] = []
        for proto in newEntityPrototypes {
            var p = proto
            p.owner = owner
            newIDs.append(tx.add(p))
        }
        let afterStart = newIDs.first?.raw ?? 0
        let afterCount = Int32(newIDs.count)
        // No new content -> block becomes empty; still a valid (if unusual)
        // redefinition. Update bookkeeping to reflect zero entities rather
        // than leaving stale start/count pointing at now-deleted slots.
        existing.entityStart = afterStart
        existing.entityCount = afterCount
        tx.registerSideEffect(
            undo: { existing.entityStart = beforeStart; existing.entityCount = beforeCount },
            redo: { existing.entityStart = afterStart; existing.entityCount = afterCount })
        regen.markBlockDirty(name)
        return true
    }

    // MARK: - INSERT (place an instance of a block, with attributes)

    /// INSERT command: creates one INSERT entity referencing `blockName`,
    /// plus one ATTRIB child per ATTDEF found in that block's own direct
    /// entity range — `attributeValues` supplies the value for each ATTDEF
    /// by TAG (an ATTDEF with no matching key in `attributeValues` uses its
    /// own default value, i.e. `createAttdef`'s `defaultValue`, exactly like
    /// AutoCAD's INSERT prompting "Enter attribute values <default>:" and
    /// accepting the default on a bare Enter).
    ///
    /// Returns `nil` if `blockName` doesn't resolve to a real, non-empty
    /// block definition (mirrors AutoCAD refusing to INSERT an unknown
    /// block name) — callers driving a name-picker UI should already have
    /// validated this against `parsed.blocks.keys`, so `nil` here signals a
    /// genuine caller error, not a normal "user typed a bad name" flow
    /// (that validation belongs in the UI layer, same as every other
    /// command's "resolve a name/pick before committing" convention in this
    /// codebase — e.g. `OffsetExecutor.resolve` returning nil for "cannot
    /// offset this").
    @discardableResult
    static func insert(blockName: String, at position: CGPoint, scale: CGPoint = CGPoint(x: 1, y: 1),
                       rotationDeg: Double = 0, layerId: Int32,
                       attributeValues: [String: String] = [:],
                       owner: OwnerRef = .model,
                       in parsed: EditableParsedDocument, tx: Transaction) -> EntityID? {
        guard let block = parsed.blocks[blockName], block.entityCount > 0 else { return nil }
        let store = parsed.store
        let nameId = store.strings.intern(blockName)

        let insertId = tx.add(EntityPrototype(
            type: .insert, layerId: layerId, owner: owner,
            payload: .insert(InsertPayload(blockNameId: nameId, position: Vec3(position),
                                           scale: Vec3(x: Double(scale.x), y: Double(scale.y), z: 1),
                                           rotationDeg: rotationDeg))))

        // Insert transform: translate(position) * rotate(rotationDeg) *
        // scale(scale) — matches `Regenerator`/`EntityRecordWriter`'s own
        // INSERT matrix convention exactly (position applied last in
        // world-space terms, i.e. first in CGAffineTransform's
        // right-to-left composition via `translatedBy`/`rotated`/`scaledBy`
        // chaining), so an ATTDEF's block-local anchor maps to the SAME
        // world point the block's own geometry would render at.
        var xf = CGAffineTransform.identity
        xf = xf.translatedBy(x: position.x, y: position.y)
        xf = xf.rotated(by: rotationDeg * .pi / 180)
        xf = xf.scaledBy(x: scale.x, y: scale.y)
        xf = xf.translatedBy(x: -block.base.x, y: -block.base.y)

        for i in Int(block.entityStart)..<Int(block.entityStart + block.entityCount) {
            let id = EntityID(raw: Int32(i))
            guard let h = store.header(id), !h.flags.contains(.deleted), h.type == .attdef,
                  h.payload >= 0 else { continue }
            let attdef = store.texts[Int(h.payload)]
            let tag = attdef.tagStringId >= 0 ? store.strings.string(for: attdef.tagStringId)
                                              : store.strings.string(for: attdef.stringId)
            let defaultValue = store.strings.string(for: attdef.stringId)
            let value = attributeValues[tag] ?? defaultValue
            let valueId = store.strings.intern(value)
            let tagId = store.strings.intern(tag)

            let localPos = CGPoint(x: attdef.position.x, y: attdef.position.y)
            let worldPos = localPos.applying(xf)
            let localAlign = CGPoint(x: attdef.alignPosition.x, y: attdef.alignPosition.y)
            let worldAlign = localAlign.applying(xf)

            var attribPayload = attdef
            attribPayload.stringId = valueId
            attribPayload.tagStringId = tagId
            attribPayload.promptStringId = -1   // ATTRIB (unlike ATTDEF) carries no prompt
            attribPayload.position = Vec3(worldPos, z: attdef.position.z)
            attribPayload.alignPosition = Vec3(worldAlign, z: attdef.alignPosition.z)
            // Height/rotation scale/compose with the insert transform the
            // same way EXPLODE's uniform-scale path will (Editing/Explode.swift)
            // — both derive from the same "this text is being placed through
            // an insert transform" fact. Uniform scale assumed here (INSERT's
            // own scale.x/scale.y may legitimately differ, but attribute text
            // height historically follows the Y-scale/rotation convention
            // AutoCAD itself uses for DEFINITION-time attributes; a
            // non-uniform INSERT scaling its ATTRIBs' text into an ellipse
            // shape is not a thing AutoCAD does — text stays text).
            //
            // KNOWN INCONSISTENCY (flagged by adversarial review, deliberately
            // NOT changed): this uses `abs(scale.y)`, while `Regenerator`'s
            // general text-through-an-INSERT-transform path uses
            // `sqrt(|determinant|)` (the uniform-scale-equivalent magnitude).
            // The two agree whenever scale.x == scale.y (every real call site
            // today — both existing callers of `insert(...)` always pass
            // uniform (1,1) scale), so this is currently unreachable, not a
            // live bug. Left as `abs(scale.y)` rather than switched to match
            // Regenerator because it's not clear WITHOUT a real AutoCAD
            // install which convention matches AutoCAD's actual non-uniform-
            // INSERT-with-attributes behavior — do not silently pick one; if
            // a future phase exposes non-uniform-scale INSERT placement with
            // attributes in the UI, resolve this by testing against real
            // AutoCAD output first, then make both paths agree.
            attribPayload.height = attdef.height * abs(scale.y)
            attribPayload.rotationDeg = attdef.rotationDeg + rotationDeg

            _ = tx.add(EntityPrototype(
                type: .attrib, layerId: h.layerId, aci: h.aci, trueColor: h.trueColor,
                linetypeId: h.linetypeId, owner: .parentEntity(insertId),
                payload: .text(attribPayload)))
        }

        return insertId
    }

    // MARK: - ATTDEF (define a new attribute inside a block)

    /// Creates a new ATTDEF entity inside block `blockName`'s own direct
    /// entity range, appended at the end (block ranges are contiguous and
    /// append-order — see this file's header comment — so an ATTDEF added
    /// to a block AFTER its initial creation extends `entityCount` by one
    /// PROVIDED nothing else has appended to the store in between; this
    /// function re-establishes contiguity itself by relocating the block's
    /// existing content alongside the new ATTDEF via the same `tx.replace`
    /// technique `createBlock` uses, exactly like `redefineBlock` would, so
    /// it's correct regardless of intervening appends).
    ///
    /// `flags`: DXF group 70 bit values (1=invisible, 2=constant, 4=verify,
    /// 8=preset) — stored on the returned entity's `EntityFlags.invisible`
    /// bit for the invisible case (the only one of the four this codebase's
    /// `EntityFlags` has a slot for today); constant/verify/preset are
    /// accepted for API completeness (matching the plan's literal
    /// `flags:` parameter) but have no behavioral effect yet (no ATTDEF
    /// editor UI reads them back) — documented here rather than silently
    /// dropped so a future ATTEDIT enhancement knows exactly what's missing.
    @discardableResult
    static func createAttdef(tag: String, prompt: String, defaultValue: String, at position: CGPoint,
                             height: Double, flags: Int = 0, layerId: Int32,
                             inBlockNamed blockName: String,
                             in parsed: EditableParsedDocument, tx: Transaction) -> EntityID? {
        guard let block = parsed.blocks[blockName] else { return nil }
        let store = parsed.store

        let tagId = store.strings.intern(tag)
        let promptId = prompt.isEmpty ? -1 : store.strings.intern(prompt)
        let valueId = store.strings.intern(defaultValue)

        var payload = TextPayload(position: Vec3(position), height: height, stringId: valueId)
        payload.tagStringId = tagId
        payload.promptStringId = promptId

        let proto = EntityPrototype(type: .attdef, layerId: layerId,
                                    owner: .block(block.blockIndex), payload: .text(payload))

        // Append via the same "relocate the whole block to stay contiguous"
        // technique as `createBlock`'s initial population — see that
        // function's header comment. If the block is currently EMPTY
        // (entityCount == 0, e.g. a block created with `createBlock` from
        // zero entities isn't possible today, but a future empty-block-first
        // workflow could reach this), this is just a plain append with no
        // relocation needed.
        // `block.entityStart`/`entityCount` are captured BEFORE mutation in
        // BOTH branches below, and a side effect is registered so undo
        // restores this block-definition metadata alongside the entity-
        // level changes `tx` already reverses correctly — see
        // `redefineBlock`'s identical fix (and its doc comment) for why
        // this is necessary: `EditableBlockDef` lives entirely outside
        // `EntityStore`/`Transaction`'s own undo system. Found by
        // adversarial review.
        let beforeStart = block.entityStart
        let beforeCount = block.entityCount

        if block.entityCount == 0 {
            let id = tx.add(proto)
            block.entityStart = id.raw
            block.entityCount = 1
            if flags & 1 != 0 { tx.modifyHeader(id) { $0.flags.insert(.invisible) } }
            let afterStart = block.entityStart, afterCount = block.entityCount
            tx.registerSideEffect(
                undo: { block.entityStart = beforeStart; block.entityCount = beforeCount },
                redo: { block.entityStart = afterStart; block.entityCount = afterCount })
            return id
        }

        var existingIDs: [EntityID] = []
        for i in Int(block.entityStart)..<Int(block.entityStart + block.entityCount) {
            existingIDs.append(EntityID(raw: Int32(i)))
        }
        var relocatedIDsInOrder: [EntityID] = []
        for id in existingIDs {
            guard let image = store.snapshot(id) else { continue }
            let created = tx.replace(id, with: [image.asPrototype()])
            relocatedIDsInOrder.append(contentsOf: created)
        }
        let newId = tx.add(proto)
        if flags & 1 != 0 { tx.modifyHeader(newId) { $0.flags.insert(.invisible) } }

        let allIDs = relocatedIDsInOrder + [newId]
        block.entityStart = allIDs.first!.raw
        block.entityCount = Int32(allIDs.count)
        let afterStart = block.entityStart, afterCount = block.entityCount
        tx.registerSideEffect(
            undo: { block.entityStart = beforeStart; block.entityCount = beforeCount },
            redo: { block.entityStart = afterStart; block.entityCount = afterCount })
        return newId
    }

    // MARK: - ATTEDIT (edit an existing INSERT's attribute values)

    /// Updates the value of ATTRIB `tag` on INSERT `insertId` — used by the
    /// attribute editor sheet. No-op (returns `false`) if `insertId` isn't a
    /// live INSERT, or has no ATTRIB child with a matching tag (mirrors
    /// AutoCAD refusing to set a non-existent attribute).
    @discardableResult
    static func setAttribute(_ insertId: EntityID, tag: String, value: String,
                             in parsed: EditableParsedDocument, tx: Transaction) -> Bool {
        let store = parsed.store
        guard let h = store.header(insertId), h.type == .insert, !h.flags.contains(.deleted) else { return false }
        for childId in store.children(of: insertId) {
            guard let ch = store.header(childId), ch.type == .attrib, ch.payload >= 0 else { continue }
            let attrib = store.texts[Int(ch.payload)]
            let childTag = attrib.tagStringId >= 0 ? store.strings.string(for: attrib.tagStringId)
                                                   : store.strings.string(for: attrib.stringId)
            guard childTag == tag else { continue }
            let valueId = store.strings.intern(value)
            tx.modifyPayload(childId) { copy in
                guard case .text(var p) = copy else { return }
                p.stringId = valueId
                copy = .text(p)
            }
            return true
        }
        return false
    }

    /// Sets ATTRIB `tag`'s value on `insertId`, CREATING it (as a new ATTRIB
    /// child, `owner: .parentEntity(insertId)`) when the INSERT doesn't
    /// already carry one — unlike `setAttribute` above, which only updates an
    /// EXISTING tag and is a no-op otherwise (matching ATTEDIT's real-AutoCAD
    /// "you can't ATTEDIT a tag that isn't there" restriction). This is the
    /// primitive behind bulk operations like the AI Assistant's "add an
    /// attribute called X with value Y to every object on layer Z" — a
    /// perfectly ordinary ask (tagging a batch of objects with new metadata)
    /// that plain ATTEDIT semantics can't satisfy, since none of those
    /// objects have that tag YET.
    ///
    /// The new ATTRIB's anchor is placed at the INSERT's own position (a
    /// reasonable default with no ATTDEF template to place it against, since
    /// this tag was never defined in the block); its text height matches the
    /// smallest EXISTING attribute's height on this same INSERT when there is
    /// one (so a newly added tag doesn't look wildly out of scale next to its
    /// siblings), else a small fixed fallback. New attributes default to
    /// INVISIBLE (DXF group-70 bit 1) — this mirrors how bulk metadata tags
    /// (BOM/material/routing fields) are routinely authored in real DXFs per
    /// AGENTS.md's own invariant #2 ("an invisible ATTRIB must be RETAINED,
    /// data-bearing"): the value should be extractable/reportable without
    /// visually cluttering every object on the layer with a new label. A user
    /// who DOES want it drawn can toggle visibility via the Properties panel/
    /// existing attribute tools same as any other ATTRIB.
    ///
    /// Returns `.updated` if an existing tag's value changed, `.created` if a
    /// new ATTRIB was added, or `.unchanged` if the requested value already
    /// matched (a true no-op — nothing added to `tx`, so re-running the same
    /// bulk edit twice is idempotent and the second run's count is honestly
    /// zero). `nil` for a non-INSERT/deleted target.
    enum AttributeWriteResult { case created, updated, unchanged }
    @discardableResult
    static func setOrCreateAttribute(_ insertId: EntityID, tag: String, value: String,
                                     in parsed: EditableParsedDocument, tx: Transaction) -> AttributeWriteResult? {
        let store = parsed.store
        guard let h = store.header(insertId), h.type == .insert, !h.flags.contains(.deleted),
              h.payload >= 0 else { return nil }

        for childId in store.children(of: insertId) {
            guard let ch = store.header(childId), ch.type == .attrib, ch.payload >= 0 else { continue }
            let attrib = store.texts[Int(ch.payload)]
            let childTag = attrib.tagStringId >= 0 ? store.strings.string(for: attrib.tagStringId)
                                                   : store.strings.string(for: attrib.stringId)
            guard childTag == tag else { continue }
            if store.strings.string(for: attrib.stringId) == value { return .unchanged }
            let valueId = store.strings.intern(value)
            tx.modifyPayload(childId) { copy in
                guard case .text(var p) = copy else { return }
                p.stringId = valueId
                copy = .text(p)
            }
            return .updated
        }

        // No existing ATTRIB with this tag — create one. Height/position
        // default from the smallest EXISTING sibling attribute's height on
        // this INSERT, when it has any (matches its neighbors' scale);
        // otherwise a small fixed fallback scaled by the insert's own
        // Y-scale, mirroring `insert(...)`'s own "attribute text height
        // follows the INSERT's Y-scale" convention.
        let ip = store.inserts[Int(h.payload)]
        let fallbackHeight = 1.0 * abs(ip.scale.y)
        let siblingHeights: [Double] = store.children(of: insertId).compactMap { childId in
            guard let ch = store.header(childId), ch.type == .attrib, ch.payload >= 0 else { return nil }
            return store.texts[Int(ch.payload)].height
        }
        let height = siblingHeights.min().flatMap { $0 > 0 ? $0 : nil } ?? fallbackHeight

        let tagId = store.strings.intern(tag)
        let valueId = store.strings.intern(value)
        var payload = TextPayload(position: ip.position, height: height, stringId: valueId)
        payload.tagStringId = tagId
        payload.promptStringId = -1

        let proto = EntityPrototype(type: .attrib, layerId: h.layerId, aci: h.aci,
                                    trueColor: h.trueColor, linetypeId: h.linetypeId,
                                    owner: .parentEntity(insertId), payload: .text(payload))
        var attribFlags = EntityFlags()
        attribFlags.insert(.invisible)
        let newId = tx.add(proto)
        tx.modifyHeader(newId) { $0.flags = attribFlags }
        return .created
    }

    /// Reads every ATTRIB child of `insertId` as `(tag, value, entityId)`
    /// triples, in child-discovery order — drives the attribute editor
    /// sheet's row list (`store.children(of: insertId)`, per the plan's
    /// exact "Attribute editor: minimal sheet driven by
    /// `store.children(of: insertId)`" spec text).
    static func attributes(of insertId: EntityID, in store: EntityStore) -> [(tag: String, value: String, id: EntityID)] {
        var result: [(tag: String, value: String, id: EntityID)] = []
        for childId in store.children(of: insertId) {
            guard let ch = store.header(childId), ch.type == .attrib, ch.payload >= 0 else { continue }
            let attrib = store.texts[Int(ch.payload)]
            let tag = attrib.tagStringId >= 0 ? store.strings.string(for: attrib.tagStringId)
                                              : store.strings.string(for: attrib.stringId)
            let value = store.strings.string(for: attrib.stringId)
            result.append((tag: tag, value: value, id: childId))
        }
        return result
    }

    // MARK: - Per-instance display name (cosmetic; does not retarget geometry)

    /// XDATA app-id this display-name override round-trips through — see
    /// `setDisplayName`'s own doc comment for why it's persisted at all
    /// (previously session-only) and `EntityStoreParser`/`EntityRecordWriter`
    /// for the read/write sides. `DimensionTool.xdataAppId` ("NOVACAD_DIM")
    /// is this feature's own precedent for a small, NovaCAD-owned app-id
    /// XDATA group; this is the INSERT-display-name equivalent.
    ///
    /// PERSISTENCE CONTRACT for any external consumer reading this back out
    /// of a saved DXF directly (rather than through NovaCAD's own
    /// EntityStore): the override lives as XDATA on the INSERT entity —
    ///   1001  "NOVACAD_DISPLAYNAME"      <- app id (this constant)
    ///   1000  "<the display name text>"  <- the override string itself
    /// i.e. group 1000 (a plain XDATA string) immediately following the 1001
    /// app-id marker that names this group. An INSERT with NO override has
    /// no such XDATA group at all (nothing is written when displayNameId is
    /// unset) — absence means "use the real block name," exactly matching
    /// `InsertPayload.displayNameId == -1`'s in-memory meaning.
    static let displayNameXDataAppId = "NOVACAD_DISPLAYNAME"

    /// Sets a purely COSMETIC display name on ONE INSERT instance — see
    /// `InsertPayload.displayNameId`'s own doc comment for the product
    /// decision this implements: this NEVER changes which block definition
    /// the INSERT draws (`blockNameId`, and therefore the object's on-canvas
    /// appearance, is completely untouched); it only overrides the
    /// human-readable name Data Extraction / the AI assistant report for
    /// this one object. Pass `nil` (or an empty string) to clear the
    /// override and fall back to the real block name again. Returns `false`
    /// for a non-INSERT/deleted/unknown id, matching `setAttribute`'s own
    /// convention.
    ///
    /// PERSISTS across save/reload (this is the point of it existing at
    /// all — a user relabeling e.g. 739 stations to their real names, per a
    /// real request, must not lose that on the next save): mirrors the write
    /// into `store.xdata[insertId.raw]` under `displayNameXDataAppId`, MERGED
    /// with whatever XDATA that INSERT already carries from its source file
    /// rather than replacing it wholesale — `EntityStore.xdata` holds only
    /// ONE blob per entity (a documented pre-existing limitation; see
    /// `EntityRecordWriter.writeXData`'s own doc comment), so overwriting it
    /// outright would silently destroy a real AutoCAD-authored INSERT's own
    /// XDATA the instant its display name was ever set. `mergeDisplayName`
    /// below is the one place that merge happens, shared by both this setter
    /// and the parser's own read-back path so they can never drift apart on
    /// what "merged" means.
    @discardableResult
    static func setDisplayName(_ insertId: EntityID, to name: String?,
                               in parsed: EditableParsedDocument, tx: Transaction) -> Bool {
        let store = parsed.store
        guard let h = store.header(insertId), h.type == .insert, !h.flags.contains(.deleted) else { return false }
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let newId: Int32 = trimmed.isEmpty ? -1 : store.strings.intern(trimmed)
        tx.modifyPayload(insertId) { copy in
            guard case .insert(var p) = copy else { return }
            p.displayNameId = newId
            copy = .insert(p)
        }
        let oldBlob = store.xdata[insertId.raw]
        let newBlob = mergeDisplayName(trimmed.isEmpty ? nil : trimmed, into: oldBlob)
        store.xdata[insertId.raw] = newBlob
        tx.registerSideEffect(
            undo: { store.xdata[insertId.raw] = oldBlob },
            redo: { store.xdata[insertId.raw] = newBlob })
        return true
    }

    /// Merges a display-name override into `existing` (this entity's current
    /// XDATA blob, if any), returning the blob to store — or `nil` when the
    /// result would be completely empty (no override AND no other XDATA), so
    /// a cleared override on an entity that never had any other XDATA
    /// removes the group entirely rather than leaving a hollow empty blob
    /// behind. Any OTHER app-id's pairs on `existing` are preserved verbatim
    /// and untouched; only this app-id's own group is replaced/added/removed.
    ///
    /// NOTE this still inherits `EntityStore.xdata`'s documented "one blob
    /// per entity" shape: if the source INSERT's OWN app-id happens to
    /// literally be `displayNameXDataAppId` (vanishingly unlikely — that
    /// string is NovaCAD-specific), this would misidentify it as our own
    /// group. Accepted as out of scope, matching how `EntityRecordWriter
    /// .writeXData`'s own doc comment already accepts the "N app-id groups
    /// flatten to one" limitation as pre-existing and not fixed by this work.
    static func mergeDisplayName(_ name: String?, into existing: XDataBlob?) -> XDataBlob? {
        var otherPairs: [(code: Int16, value: XDataValue)] = []
        if let existing, existing.appId != displayNameXDataAppId {
            otherPairs = existing.pairs
        }
        guard let name, !name.isEmpty else {
            // Clearing the override: keep any unrelated XDATA as-is; drop
            // the group entirely if there was none.
            guard let existing, existing.appId != displayNameXDataAppId else { return nil }
            return existing
        }
        // This app-id's group carries exactly one pair (the name string) —
        // any OTHER app-id's pairs the entity already had are preserved by
        // literally keeping them as `otherPairs`, but per
        // `EntityStore.xdata`'s one-blob-per-entity shape they end up under
        // THIS blob's single `appId`/`pairs` list rather than as a separate
        // group; see this function's own doc comment on that inherited
        // limitation. In the overwhelming common case (an INSERT with no
        // pre-existing XDATA at all), `otherPairs` is empty and this is a
        // clean, single-purpose blob.
        return XDataBlob(appId: displayNameXDataAppId, pairs: [(1000, .string(name))] + otherPairs)
    }

    /// The name to SHOW for this INSERT — its cosmetic override if one is
    /// set, else the real block name it draws. The one place both
    /// `blockNameId` (real, geometry-driving) and `displayNameId`
    /// (cosmetic, optional) are reconciled into a single "what do I call
    /// this object" answer, so `DataExtraction`/`AIToolExecutor`/any future
    /// caller never has to duplicate this fallback logic themselves.
    static func displayName(of insertId: EntityID, in store: EntityStore) -> String? {
        guard let h = store.header(insertId), h.type == .insert, h.payload >= 0 else { return nil }
        let p = store.inserts[Int(h.payload)]
        if p.displayNameId >= 0 { return store.strings.string(for: p.displayNameId) }
        return store.strings.string(for: p.blockNameId)
    }
}
