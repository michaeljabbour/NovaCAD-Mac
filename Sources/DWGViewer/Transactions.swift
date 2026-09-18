import Foundation
import CADCore

/// One undoable group of edits against an `EntityStore`. Callers (drafting
/// tools, future modification commands) call `add`/`delete`/`modifyPayload`/
/// `modifyHeader` any number of times, then `EditableDocument.commit(_:)`
/// turns the accumulated ops into one undo-stack entry.
///
/// Undo is inverse-images, not whole-store snapshots: a transaction that
/// edits 10,000 entities costs roughly 10,000 entities' worth of memory, not
/// a copy of the entire 2.5M-entity document.
final class Transaction {
    let name: String
    private unowned let store: EntityStore

    private(set) var ops: [Op] = []
    /// The state of each touched entity the FIRST time this transaction
    /// touches it — captured lazily so repeated edits to the same entity
    /// within one transaction (e.g. a live drag) coalesce into a single
    /// before/after pair instead of one per intermediate edit.
    private var beforeImages: [Int32: EntityImage] = [:]
    private(set) var addedIDs: Set<EntityID> = []
    private(set) var deletedIDs: Set<EntityID> = []

    /// Non-`EntityStore` undo/redo side effects registered by a caller that
    /// mutates state OUTSIDE the entity store as part of this same logical
    /// operation — e.g. `BlockEditor` updating `EditableBlockDef.entityStart`/
    /// `entityCount` or `EditableParsedDocument.blocks`'s dictionary keys,
    /// neither of which live in `EntityStore` and so aren't covered by the
    /// `Op` enum's entity-level undo/redo at all. Each registered pair is
    /// replayed in the SAME relative order as the `Op`s around it would
    /// suggest: `undo` closures run (in registration order) as part of
    /// `EditableDocument.undo()`, `redo` closures as part of `redo()`. This
    /// is deliberately a generic escape hatch (closures, not a typed `Op`
    /// case) rather than teaching `EntityStore`/`Transaction.Op` about
    /// block-table structure, since block metadata is owned by
    /// `EditableParsedDocument` (a layer above `EntityStore`/`Transaction`,
    /// which have no reference to it) — adding a real typed `Op` case would
    /// require threading an `EditableParsedDocument` reference down into
    /// `Transaction`'s constructor for every call site in the codebase, a
    /// far larger change than this fix warrants. Found necessary by
    /// adversarial review: `BlockEditor.createBlock`/`createAttdef`/
    /// `redefineBlock` all mutate `EditableBlockDef`/`parsed.blocks` in
    /// place with NO undo registration at all prior to this fix, so
    /// undoing one of those commands left the block definition's metadata
    /// permanently pointing at a stale (often entirely-tombstoned) entity
    /// range even though the entities themselves were correctly restored.
    private(set) var sideEffects: [(undo: () -> Void, redo: () -> Void)] = []

    /// Registers a paired undo/redo closure for a non-entity-store mutation
    /// this transaction is also performing. Call AFTER performing the
    /// forward mutation (mirroring how `add`/`delete`/`modifyPayload` all
    /// perform their forward effect immediately and only record how to
    /// reverse it). `undo` must exactly reverse whatever side effect was
    /// just applied; `redo` must exactly re-apply it.
    func registerSideEffect(undo: @escaping () -> Void, redo: @escaping () -> Void) {
        sideEffects.append((undo: undo, redo: redo))
    }

    enum Op {
        case add(EntityID)
        case delete(EntityID, before: EntityImage)
        case modify(EntityID, before: EntityImage, after: EntityImage)
    }

    init(name: String, store: EntityStore) {
        self.name = name
        self.store = store
    }

    @discardableResult
    func add(_ proto: EntityPrototype) -> EntityID {
        let id = store.append(proto)
        ops.append(.add(id))
        addedIDs.insert(id)
        return id
    }

    /// Registers `id` as if `add(_:)` had just created it, WITHOUT appending
    /// anything to the store itself — for a caller that appended `id`
    /// directly via a lower-level `EntityStore` API (e.g.
    /// `EntityStore.appendCopy`, used by xref attach's bulk transplant of a
    /// whole source file's content) and needs that append covered by THIS
    /// transaction's undo/redo instead of being permanently untracked.
    /// `Op.add`'s undo/redo (`markDeleted`/`undelete`) are correct for an
    /// already-appended entity exactly as they are for one `add(_:)` itself
    /// appended — this is purely a bookkeeping registration, not a second
    /// append.
    func adopt(_ id: EntityID) {
        ops.append(.add(id))
        addedIDs.insert(id)
    }

    func delete(_ id: EntityID) {
        guard !deletedIDs.contains(id), let before = store.snapshot(id) else { return }
        store.markDeleted(id)
        ops.append(.delete(id, before: before))
        deletedIDs.insert(id)
    }

    /// Mutates `id`'s geometry payload. `body` receives the CURRENT payload
    /// (reflecting any earlier edits to `id` within this same transaction)
    /// and may change it in place; the result is written back immediately.
    func modifyPayload(_ id: EntityID, _ body: (inout EntityPayloadCopy) -> Void) {
        guard !deletedIDs.contains(id), var image = store.snapshot(id) else { return }
        if beforeImages[id.raw] == nil { beforeImages[id.raw] = image }
        body(&image.payloadCopy)
        store.restore(id, image)
    }

    /// Phase 4.2: applies `t` (a `Transform2` — translation for MOVE,
    /// rotation-about for ROTATE, scaling-about for SCALE, mirror-across for
    /// MIRROR) to `id`'s payload in place via `EntityTransform`. Thin
    /// convenience wrapper over `modifyPayload` so ContentView's command
    /// bodies read as "transform these ids by this transform" rather than
    /// repeating the `EntityTransform.apply` call at every site.
    func transform(_ id: EntityID, by t: Transform2, mirrtext: Bool) {
        modifyPayload(id) { copy in EntityTransform.apply(t, to: &copy, mirrtext: mirrtext) }
    }

    /// Phase 4.2 (COPY command): clones `id` into a brand-new entity,
    /// optionally transformed by `t` (nil/`.identity` for a copy in place at
    /// the same location — callers building a "stamp a duplicate here"
    /// interaction always pass a translation at minimum). `owner` lets a
    /// copy target a different space/block than the source; nil keeps the
    /// source's own owner (copy within the same space). Returns the new
    /// entity's id, or nil if `id` doesn't resolve (already deleted, or
    /// never existed) — mirrors `add`'s discardable-result convention since
    /// most callers only need the id for `selectNewEntities`-style bulk
    /// selection.
    @discardableResult
    func copyTransformed(_ id: EntityID, by t: Transform2 = .identity, mirrtext: Bool = false,
                         owner: OwnerRef? = nil) -> EntityID? {
        guard let image = store.snapshot(id) else { return nil }
        var proto = image.asPrototype(owner: owner)
        if t != .identity {
            EntityTransform.apply(t, to: &proto.payload, mirrtext: mirrtext)
        }
        return add(proto)
    }

    /// Mutates `id`'s header fields (layer, color, linetype, lineweight, ...).
    func modifyHeader(_ id: EntityID, _ body: (inout EntityHeader) -> Void) {
        guard !deletedIDs.contains(id), let current = store.header(id) else { return }
        if beforeImages[id.raw] == nil { beforeImages[id.raw] = store.snapshot(id) }
        var h = current
        body(&h)
        store.setHeader(id) { $0 = h }
    }

    /// Deletes `id` and creates one or more replacement entities carrying
    /// the same properties (layer/color/linetype/lineweight) — the form
    /// TRIM/EXPLODE (later phases) need for structural changes a simple
    /// payload edit can't express (e.g. a polyline splitting into two).
    /// Returns the new entities' ids.
    @discardableResult
    func replace(_ id: EntityID, with protos: [EntityPrototype]) -> [EntityID] {
        guard let original = store.header(id) else { return [] }
        delete(id)
        return protos.map { proto in
            var p = proto
            p.layerId = proto.layerId == -1 ? original.layerId : proto.layerId
            return add(p)
        }
    }

    /// Finalizes this transaction's op list: appends one `.modify` per
    /// entity touched by `modifyPayload`/`modifyHeader` that wasn't also
    /// added or deleted within the same transaction (those are already
    /// captured by their own `.add`/`.delete` op and don't need a redundant
    /// entry). Called by `EditableDocument.commit`/`cancel` — not meant to
    /// be called more than once per transaction.
    func finalize() -> [Op] {
        var result = ops
        for (raw, before) in beforeImages {
            let id = EntityID(raw: raw)
            guard !addedIDs.contains(id), !deletedIDs.contains(id) else { continue }
            guard let after = store.snapshot(id) else { continue }
            result.append(.modify(id, before: before, after: after))
        }
        return result
    }
}

/// Owns the entity database plus its undo/redo history. This is the object
/// ContentView/DocumentSession will hold once the parser (Phase 1.2) and
/// regenerator (Phase 1.3) exist to populate and render it — today it's the
/// store + transaction machinery on its own, unit-tested in isolation.
final class EditableDocument {
    let store = EntityStore()
    private(set) var revision: UInt64 = 0

    /// `sideEffects` mirrors `Transaction.sideEffects` — see that property's
    /// doc comment for why non-`EntityStore` mutations (block-table
    /// metadata) need this parallel, generic undo/redo channel alongside
    /// `ops`.
    private(set) var undoStack: [(ops: [Transaction.Op], name: String, sideEffects: [(undo: () -> Void, redo: () -> Void)])] = []
    private(set) var redoStack: [(ops: [Transaction.Op], name: String, sideEffects: [(undo: () -> Void, redo: () -> Void)])] = []
    /// Cap on undo depth — bounds memory on a session with many large edits.
    /// (The plan's fuller design also caps by estimated byte size; that's a
    /// refinement for when real editing commands start producing multi-
    /// thousand-entity transactions.)
    private static let maxUndoTransactions = 100

    func begin(_ name: String) -> Transaction {
        Transaction(name: name, store: store)
    }

    /// Commits `tx`: finalizes its ops, pushes them onto the undo stack
    /// (clearing redo), and bumps `revision`. A transaction with no actual
    /// changes (e.g. a modify that touched nothing) AND no registered side
    /// effects is dropped silently rather than creating an empty undo step.
    func commit(_ tx: Transaction) {
        let ops = tx.finalize()
        guard !ops.isEmpty || !tx.sideEffects.isEmpty else { return }
        undoStack.append((ops, tx.name, tx.sideEffects))
        if undoStack.count > Self.maxUndoTransactions { undoStack.removeFirst() }
        redoStack.removeAll()
        revision += 1
    }

    /// Reverts whatever `tx` already applied to the store, without
    /// publishing it to the undo stack — for aborting a transaction mid-way
    /// (e.g. a command the user cancels, or an error partway through).
    func cancel(_ tx: Transaction) {
        applyInverse(tx.finalize())
        for effect in tx.sideEffects.reversed() { effect.undo() }
    }

    /// begin → body → commit, cancel on throw. The form editing commands use.
    func transact(_ name: String, _ body: (Transaction) throws -> Void) rethrows {
        let tx = begin(name)
        do {
            try body(tx)
            commit(tx)
        } catch {
            cancel(tx)
            throw error
        }
    }

    func undo() {
        guard let entry = undoStack.popLast() else { return }
        applyInverse(entry.ops)
        for effect in entry.sideEffects.reversed() { effect.undo() }
        redoStack.append(entry)
        revision += 1
    }

    func redo() {
        guard let entry = redoStack.popLast() else { return }
        applyForward(entry.ops)
        for effect in entry.sideEffects { effect.redo() }
        undoStack.append(entry)
        revision += 1
    }

    private func applyInverse(_ ops: [Transaction.Op]) {
        for op in ops.reversed() {
            switch op {
            case .add(let id): store.markDeleted(id)
            case .delete(let id, let before): store.restore(id, before)
            case .modify(let id, let before, _): store.restore(id, before)
            }
        }
    }

    private func applyForward(_ ops: [Transaction.Op]) {
        for op in ops {
            switch op {
            case .add(let id): store.undelete(id)
            case .delete(let id, _): store.markDeleted(id)
            case .modify(let id, _, let after): store.restore(id, after)
            }
        }
    }
}
