import Foundation
import CoreGraphics
import CADCore

// MARK: - "Attach Xref…" (new feature): pick a file, choose which of its
// layers to bring in, then place it like INSERT places a block.
//
// Two-phase API, mirroring how `RegenCoordinator.loadPackage` /
// `ContentView.openFile` already split "parse off the main thread" from
// "commit to the live document on the main thread":
//
//   1. `prepareAttach(url:hostBlockNames:)` — off the main thread. Converts
//      a .dwg source via the same `DWGConverter` this app already uses for
//      ordinary xref resolution, then fully parses the candidate file with
//      `EntityStoreParser` (so its OWN layer table is available before the
//      user picks which layers to import) and returns a `PendingAttach`.
//      Does not touch the host document at all.
//   2. `commitAttach(_:selectedLayerNames:at:layerId:owner:in:tx:)` — main
//      thread, inside a `session.performEdit` transaction. Registers a new
//      xref BLOCK definition in the host (deduped against existing block
//      names), transplants the candidate's own block definitions verbatim
//      (matching ordinary xref-merge fidelity — a block reference's CONTENT
//      is a structural, shared thing, not something a top-level "which
//      layers do I want" filter should prune), transplants the candidate's
//      MODEL-SPACE content filtered down to `selectedLayerNames` (the
//      user-facing "layer selection" — same granularity real xref
//      layer-freeze acts at), then adds one host INSERT of the new block at
//      `position`.
//
// Scope decision (documented rather than silently gapped): unlike
// `PackageLoader.loadIntoStore`'s xref resolution, this does NOT recursively
// resolve any NESTED xrefs the attached file itself references — they come
// across as ordinary unresolved xref stubs (renamed "<newBlock>$<nested>",
// exactly like `PackageLoader+Store.mergeIntoStore` already does for a
// package-load xref's own nested xrefs), showing up in the Layers panel's
// External References list as "Not embedded in this DXF" with the existing
// "Set Xref Path…" flow available. A future enhancement could thread a full
// recursive resolve through here; the existing per-xref "Set Xref Path…"/
// Reload path already covers it for now, so this isn't a functional dead
// end, just a smaller first cut.
enum XrefAttach {

    /// A fully-parsed candidate file, ready for the layer-selection sheet —
    /// nothing here has touched the host document yet.
    struct PendingAttach: Identifiable {
        /// `sourceURL`'s path is a stable enough identity for one attach
        /// attempt's lifetime (a `.sheet(item:)` presentation) — no two
        /// concurrent attaches of the exact same file path can be in flight
        /// at once (the UI is modal per window), so this never collides.
        var id: String { sourceURL.path }
        /// The file the user actually picked (before any DWG->DXF conversion).
        let sourceURL: URL
        /// The file NovaCAD's parser actually reads — equal to `sourceURL`
        /// for a .dxf source; a converted temp .dxf for a .dwg source.
        let loadedURL: URL
        let parsed: EditableParsedDocument
        /// Block name this attach will register in the host, already deduped
        /// against every block name the host currently has.
        let suggestedBlockName: String

        /// Every layer name in the candidate file's own layer table, in file
        /// order — feeds the layer-selection sheet's checkbox list.
        var availableLayerNames: [String] { parsed.layers.map(\.name) }
    }

    // MARK: - Phase 1: parse (off the main thread)

    /// Converts (if needed) and fully parses `url`, returning a
    /// `PendingAttach` for the layer-selection sheet. Throws whatever
    /// `DWGConverter`/`EntityStoreParser` throw on failure — callers should
    /// surface `(error as? LocalizedError)?.errorDescription` the same way
    /// `ContentView.openFile` already does for the main "Open File" flow.
    static func prepareAttach(url: URL, hostBlockNames: Set<String>) throws -> PendingAttach {
        var loadedURL = url
        if url.pathExtension.lowercased() == "dwg" {
            loadedURL = try DWGConverter.convertToDXF(url: url)
        }
        let parsed = try EntityStoreParser.parse(url: loadedURL)
        let blockName = dedupedBlockName(
            base: url.deletingPathExtension().lastPathComponent, existing: hostBlockNames)
        return PendingAttach(sourceURL: url, loadedURL: loadedURL, parsed: parsed,
                             suggestedBlockName: blockName)
    }

    /// "NAME" if free, else "NAME_2", "NAME_3", ... — case-insensitive
    /// comparison against `existing` (AutoCAD block names are effectively
    /// case-insensitive even though this codebase preserves case on disk).
    private static func dedupedBlockName(base: String, existing: Set<String>) -> String {
        let existingUpper = Set(existing.map { $0.uppercased() })
        guard existingUpper.contains(base.uppercased()) else { return base }
        var n = 2
        while existingUpper.contains("\(base)_\(n)".uppercased()) { n += 1 }
        return "\(base)_\(n)"
    }

    // MARK: - Phase 2: commit (main thread, inside a Transaction)

    /// Registers the new xref block + transplants its content into `parsed`,
    /// then adds one host INSERT of it at `position`. Returns the new
    /// INSERT's `EntityID`, or `nil` if `pending`'s suggested name somehow
    /// collides by the time this runs (caller should treat that as "attach
    /// failed," matching `BlockEditor.createBlock`'s own nil-on-collision
    /// convention) — race is only possible if two attaches are somehow
    /// in flight at once, which today's single-window-modal-tool UI
    /// prevents, but the guard costs nothing.
    @discardableResult
    static func commitAttach(_ pending: PendingAttach, selectedLayerNames: Set<String>,
                             at position: CGPoint, layerId: Int32, owner: OwnerRef = .model,
                             in parsed: EditableParsedDocument, tx: Transaction) -> EntityID? {
        let blockName = pending.suggestedBlockName
        guard parsed.blocks[blockName] == nil else { return nil }
        let sub = pending.parsed
        let hostStore = parsed.store
        let subStore = sub.store

        // Every new `EditableBlockDef` this attach registers (the xref stub
        // itself + any of the candidate's OWN local/nested-xref block defs)
        // — `parsed.blocks` is a plain dictionary living entirely OUTSIDE
        // `EntityStore`/`Transaction`'s own undo system (see
        // `BlockEditor.createBlock`'s identical concern), so undo/redo of
        // this whole attach is threaded through ONE grouped side effect
        // registered at the end, covering every key added here.
        var addedBlockDefs: [(name: String, def: EditableBlockDef)] = []

        // ---- Layers: sub layer 0 keeps host layer 0; others get "NAME|layer" ----
        // Built for EVERY sub layer regardless of the user's selection —
        // block-definition content (transplanted verbatim, unfiltered) can
        // reference any of them, and `remapLayer` below must resolve
        // correctly for those references too, not just the top-level
        // entities the layer-selection filter actually gates.
        var layerMap = [Int32: Int32]()
        var subLayerNameById = [Int32: String]()
        for subLayer in sub.layers {
            subLayerNameById[Int32(subLayer.id)] = subLayer.name
            if subLayer.id == 0 { layerMap[0] = 0; continue }
            let depName = "\(blockName)|\(subLayer.name)"
            let hostId: Int32
            if let existing = parsed.layerIdByName[depName] {
                hostId = existing
            } else {
                hostId = Int32(parsed.layers.count)
                parsed.layers.append(DXFLayer(id: Int(hostId), name: depName,
                                              color: subLayer.color, linetypeId: 0,
                                              isOffByDefault: subLayer.isOffByDefault,
                                              isFrozen: subLayer.isFrozen, entityCount: 0))
                parsed.layerIdByName[depName] = hostId
            }
            layerMap[Int32(subLayer.id)] = hostId
        }

        // ---- Linetypes: merge by name ----
        var ltMap = [Int16: Int16]()
        ltMap[-1] = -1; ltMap[-2] = -2
        for (subId, subLt) in sub.linetypes.enumerated() {
            let upper = subLt.name.uppercased()
            let hostId: Int16
            if let existing = parsed.linetypeIdByName[upper] {
                hostId = existing
            } else {
                hostId = Int16(parsed.linetypes.count)
                parsed.linetypes.append(subLt)
                parsed.linetypeIdByName[upper] = hostId
            }
            ltMap[Int16(subId)] = hostId
        }
        for subLayer in sub.layers where subLayer.id != 0 {
            let depName = "\(blockName)|\(subLayer.name)"
            if let hostId = parsed.layerIdByName[depName] {
                let mapped = ltMap[Int16(subLayer.linetypeId)] ?? 0
                parsed.layers[Int(hostId)].linetypeId = Int(max(mapped, 0))
            }
        }

        func remapLayer(_ id: Int32) -> Int32 { layerMap[id] ?? 0 }
        func remapLinetype(_ id: Int16) -> Int16 { ltMap[id] ?? 0 }

        // ---- Block names: NEWBLOCK$name (matches ordinary xref-merge naming) ----
        var blockNameMap = [String: String]()
        for (subName, _) in sub.blocks {
            let upper = subName.uppercased()
            guard !upper.hasPrefix("*MODEL_SPACE"), !upper.hasPrefix("*PAPER_SPACE"),
                  upper != "$MODEL_SPACE" else { continue }
            blockNameMap[subName] = "\(blockName)$\(subName)"
        }
        func remapBlockName(_ name: String) -> String {
            blockNameMap[name] ?? "\(blockName)$\(name)"
        }

        // ---- Register the new xref block stub up front (needs a real
        // blockIndex before any entity can be transplanted under it) ----
        let hostBlock = EditableBlockDef()
        hostBlock.name = blockName
        hostBlock.base = .zero
        hostBlock.flags = 4   // DXF group-70 bit 4: this BLOCK is an xref
        hostBlock.xrefPath = pending.sourceURL.lastPathComponent
        hostBlock.xrefSourcePath = pending.sourceURL.path
        hostBlock.xrefLoadedPath = pending.loadedURL.path
        hostBlock.blockIndex = BlockEditor.nextBlockIndex(in: parsed)
        parsed.blocks[blockName] = hostBlock
        addedBlockDefs.append((blockName, hostBlock))
        let xrefOwner = OwnerRef.block(hostBlock.blockIndex)

        // Every OTHER sub-block also needs its host block index allocated
        // up front, same reason (see `PackageLoader+Store.mergeIntoStore`).
        var newBlockIndex = [String: Int32]()
        for (subName, _) in sub.blocks.sorted(by: { $0.key < $1.key }) {
            guard blockNameMap[subName] != nil else { continue }
            newBlockIndex[subName] = BlockEditor.nextBlockIndex(in: parsed) + Int32(newBlockIndex.count)
        }

        // Built ONCE per attach (O(n) over the CANDIDATE file's own entity
        // count only) so the recursive copy below can look up an entity's
        // ATTRIB children in O(1) instead of re-scanning `subStore` per
        // copied entity. See `copyWithAttributeChildren`'s own doc comment
        // for the full "stuck at 51%" performance rationale (identical fix
        // to `PackageLoader+Store.mergeIntoStore`'s `subChildrenByParent`).
        let subChildrenByParent = subStore.childrenByParent()

        /// Copies `id` plus every `.parentEntity`-owned child `subStore
        /// .children(of: id)` finds (e.g. an INSERT's ATTRIBs), re-parented
        /// onto the new copy — see `PackageLoader+Store.mergeIntoStore`'s
        /// identical helper (`copyWithAttributeChildren`) for the full
        /// rationale: without this, an attached xref's INSERT's attribute
        /// text was silently OMITTED from the host store entirely (a
        /// `.parentEntity`-owned ATTRIB can never satisfy the plain
        /// `.isModel`/fixed-`owner` tests this file's copy loops use), which
        /// is the "attributes missing only when viewed as an xref, present
        /// when the same file is opened directly" bug. `tx.adopt` is called
        /// for the top-level id AND every recursively-copied child, matching
        /// every other call site in this function.
        ///
        /// PERFORMANCE (the "stuck at 51%" fix): this used to call
        /// `subStore.children(of: id)` — a FULL linear scan of every header
        /// in the sub-store — once per copied entity, making a bulk attach
        /// of a large candidate file O(entities^2). It is now a single O(n)
        /// `childrenByParent()` index built ONCE above and an O(1) lookup
        /// here. Behavior is otherwise IDENTICAL (same children, same
        /// ascending-id order, deleted still skipped), so AGENTS.md's
        /// ATTRIB-linking invariant #1 is preserved verbatim.
        @discardableResult
        func copyWithAttributeChildren(_ id: EntityID, owner: OwnerRef) -> EntityID? {
            guard let newId = hostStore.appendCopy(of: id, from: subStore,
                                                   remapLayer: remapLayer, remapLinetype: remapLinetype,
                                                   remapBlockName: remapBlockName, owner: owner) else { return nil }
            tx.adopt(newId)
            // O(1) lookup; absent key == no children (the overwhelmingly
            // common case — plain LINEs etc. never have any).
            if let kids = subChildrenByParent[id.raw] {
                for childId in kids {
                    // `childrenByParent()` already filtered deleted
                    // entities, so no re-check is needed here.
                    _ = copyWithAttributeChildren(childId, owner: .parentEntity(newId))
                }
            }
            return newId
        }

        /// Appends a contiguous copy of `range` from `subStore` into
        /// `hostStore` under `owner`, remapping layer/linetype/insert-name
        /// references — UNFILTERED (used for the candidate's own local/
        /// nested block definitions, which are transplanted verbatim
        /// regardless of the layer selection; see this file's header
        /// comment on why block CONTENT isn't layer-filtered).
        ///
        /// Entities already owned via `.parentEntity` in the SOURCE range
        /// are skipped on their own pass and instead copied by their
        /// parent's `copyWithAttributeChildren` recursion — see
        /// `PackageLoader+Store.mergeIntoStore`'s `transplant` for the
        /// identical reasoning (a nested INSERT's ATTRIBs would otherwise
        /// have their owner silently overwritten from `.parentEntity` to
        /// flat block content).
        @discardableResult
        func transplant(_ start: Int32, _ count: Int32, owner: OwnerRef) -> (start: Int32, count: Int32) {
            let newStart = Int32(hostStore.count)
            if count > 0 {
                for i in Int(start)..<Int(start + count) {
                    let id = EntityID(raw: Int32(i))
                    guard let h = subStore.header(id), !h.flags.contains(.deleted) else { continue }
                    guard h.owner.parentEntityID == nil else { continue }
                    _ = copyWithAttributeChildren(id, owner: owner)
                }
            }
            let newCount = Int32(hostStore.count) - newStart
            return (newStart, newCount)
        }

        // ---- Top-level content: model space (+ *Model_Space blocks),
        // FILTERED to the user's selected layers — this is the actual
        // "layer selection" the user made in the attach sheet. ----
        let modelStart = Int32(hostStore.count)
        for i in subStore.headers.indices {
            let h = subStore.headers[i]
            guard !h.flags.contains(.deleted), h.owner.isModel else { continue }
            guard let layerName = subLayerNameById[h.layerId], selectedLayerNames.contains(layerName)
            else { continue }
            let id = EntityID(raw: Int32(i))
            _ = copyWithAttributeChildren(id, owner: xrefOwner)
        }
        for (subName, b) in sub.blocks.sorted(by: { $0.key < $1.key }) {
            let upper = subName.uppercased()
            if upper.hasPrefix("*MODEL_SPACE") || upper == "$MODEL_SPACE" {
                // *MODEL_SPACE's own content IS top-level model-space
                // content (see `EntityStoreParser`'s `ownerFor(isPaper:)` —
                // it's just a BLOCK/ENDBLK-wrapped alias for it), so the
                // SAME layer filter applies here, unlike the "other block
                // defs" transplant below.
                for i in Int(b.entityStart)..<Int(b.entityStart + b.entityCount) {
                    let id = EntityID(raw: Int32(i))
                    guard let h = subStore.header(id), !h.flags.contains(.deleted) else { continue }
                    guard h.owner.parentEntityID == nil else { continue }
                    guard let layerName = subLayerNameById[h.layerId], selectedLayerNames.contains(layerName)
                    else { continue }
                    _ = copyWithAttributeChildren(id, owner: xrefOwner)
                }
            }
        }
        let modelCount = Int32(hostStore.count) - modelStart
        hostBlock.entityStart = modelStart
        hostBlock.entityCount = modelCount
        hostBlock.wasResolved = true
        hostBlock.isXrefDependent = false

        // ---- Transplant the candidate's OTHER block definitions, verbatim ----
        for (subName, b) in sub.blocks.sorted(by: { $0.key < $1.key }) {
            guard let newName = blockNameMap[subName], let blockIndex = newBlockIndex[subName] else { continue }
            let (start, count) = transplant(b.entityStart, b.entityCount, owner: .block(blockIndex))
            let copy = EditableBlockDef()
            copy.name = newName
            copy.base = b.base
            copy.flags = b.flags
            copy.xrefPath = b.xrefPath
            copy.xrefSourcePath = b.xrefSourcePath
            copy.xrefLoadedPath = b.xrefLoadedPath
            copy.blockIndex = blockIndex
            copy.entityStart = start
            copy.entityCount = count
            copy.isXrefDependent = true
            copy.wasResolved = b.wasResolved
            parsed.blocks[newName] = copy
            addedBlockDefs.append((newName, copy))
        }

        for (k, v) in sub.skippedTypes { parsed.skippedTypes[k, default: 0] += v }

        tx.registerSideEffect(
            undo: { for (name, _) in addedBlockDefs { parsed.blocks[name] = nil } },
            redo: { for (name, def) in addedBlockDefs { parsed.blocks[name] = def } })

        // ---- Host INSERT ----
        let nameId = hostStore.strings.intern(blockName)
        let insertId = tx.add(EntityPrototype(
            type: .insert, layerId: layerId, owner: owner,
            payload: .insert(InsertPayload(blockNameId: nameId, position: Vec3(position)))))
        return insertId
    }

    // MARK: - Detach

    /// Result of `xrefsAffectedByDetach`, driving the confirmation alert —
    /// every xref (by block name) that shares the SAME underlying source
    /// file as the one the user right-clicked, since detaching removes the
    /// shared host block definition those OTHER references depend on too
    /// (see `commitDetach`'s doc comment for why this can't be scoped to
    /// just one reference).
    static func xrefsAffectedByDetach(_ xref: XrefInfo, in document: DXFDocument) -> [XrefInfo] {
        document.xrefs.filter { $0.sourceDrawingKey == xref.sourceDrawingKey }
    }

    /// Removes every xref block that shares `xref`'s source drawing —
    /// deletes each of their host INSERT entities plus every entity their
    /// (possibly-shared) block definition subtree owns, and unregisters the
    /// block definitions themselves from `parsed.blocks`.
    ///
    /// Whole-source-drawing scope (not just the one block the user
    /// clicked): per this session's product decision, de-duped xref content
    /// (`PackageLoader.loadIntoStore`'s "same source file merged once,
    /// every other reference ALIASES that range" optimization — see
    /// `PackageLoader+Store.swift`'s `SharedXrefContent`) means two
    /// `XrefInfo` entries can point at the EXACT SAME host block/entity
    /// range under different names/nesting paths. Detaching only one name's
    /// INSERT while leaving that shared range referenced by another
    /// still-live block definition is safe on its own, but detaching the
    /// block DEFINITION itself (this function's whole point — an orphaned,
    /// still-resolved xref block left with nothing pointing at it would
    /// otherwise render as a synthetic root per `Regenerator.build`'s
    /// "orphan block with real geometry still renders" rule, silently
    /// UN-deleting content the user just asked to remove) must therefore
    /// remove every reference sharing that block/content in one atomic
    /// transaction — hence "detach" acts on the whole `sourceDrawingKey`
    /// group, not one `XrefInfo.id`, and the confirmation alert (built from
    /// `xrefsAffectedByDetach`) always tells the user every block name this
    /// will affect before they confirm.
    @discardableResult
    static func commitDetach(_ xrefs: [XrefInfo], in parsed: EditableParsedDocument,
                             regen: RegenCoordinator, tx: Transaction) -> Bool {
        guard !xrefs.isEmpty else { return false }
        let store = parsed.store
        var removedAny = false

        // Every block name in this detach group's whole subtree (a nested
        // xref reached only through one of `xrefs` must go too — otherwise
        // its now-parentless content would linger as another orphan root).
        var namesToRemove = Set<String>()
        for x in xrefs {
            namesToRemove.insert(x.blockName)
            let nestedPrefix = x.blockName + "$"
            for (name, _) in parsed.blocks where name.hasPrefix(nestedPrefix) {
                namesToRemove.insert(name)
            }
        }

        // 1) Delete every top-level INSERT referencing any of these blocks
        //    (wherever it lives — model space, paper space, or nested inside
        //    some OTHER still-surviving block).
        //
        // Built ONCE before the scan below (O(n) over the WHOLE store) so
        // each matching INSERT's ATTRIB children are an O(1) lookup instead
        // of a fresh `store.children(of:)` full linear scan per match — the
        // same "stuck at 51%" anti-pattern documented on
        // `copyWithAttributeChildren` above and fixed identically in
        // `PackageLoader+Store.mergeIntoStore`. A detach on a store with
        // many attributed INSERTs of the removed block(s) would otherwise
        // be O(matching_inserts x total_headers).
        let childrenByParent = store.childrenByParent()
        for h in store.headers.enumerated() {
            let (i, header) = h
            guard !header.flags.contains(.deleted), header.type == .insert, header.payload >= 0 else { continue }
            let name = store.strings.string(for: store.inserts[Int(header.payload)].blockNameId)
            guard namesToRemove.contains(name) else { continue }
            let id = EntityID(raw: Int32(i))
            // `childrenByParent()` already filtered deleted entities, so no
            // re-check is needed here.
            for child in childrenByParent[id.raw] ?? [] { tx.delete(child) }
            tx.delete(id)
            removedAny = true
        }

        // 2) Delete each removed block definition's own direct content, then
        //    unregister the definition itself.
        var removedDefs: [(name: String, def: EditableBlockDef)] = []
        for name in namesToRemove {
            guard let def = parsed.blocks[name] else { continue }
            for i in Int(def.entityStart)..<Int(def.entityStart + def.entityCount) {
                let id = EntityID(raw: Int32(i))
                guard !store.isDeleted(id) else { continue }
                tx.delete(id)
                removedAny = true
            }
            removedDefs.append((name, def))
        }
        for (name, _) in removedDefs { parsed.blocks[name] = nil }
        tx.registerSideEffect(
            undo: { for (name, def) in removedDefs { parsed.blocks[name] = def } },
            redo: { for (name, _) in removedDefs { parsed.blocks[name] = nil } })

        return removedAny
    }
}
