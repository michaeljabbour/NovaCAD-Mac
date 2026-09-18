import Foundation

// MARK: - Phase 3: BLOCKS + ENTITIES section emitters
//
// BLOCKS holds *Model_Space, *Paper_Space, and every real block definition
// (xref blocks as stubs — flags + path, no entities, per the plan's spec).
// ENTITIES holds model+paper space's own entities (owner 330 = the
// corresponding space's BLOCK_RECORD handle). Every block's CONTENT lives in
// BLOCKS' own BLOCK/ENDBLK pair, driven by `OwnerRef.block(index)`; entities
// with `owner: .model`/`.paper` go to ENTITIES directly — this mirrors how
// `EntityStoreParser` actually populates the store (see that file's
// `ownerFor(isPaper:)`: content inside a BLOCK/ENDBLK, INCLUDING one named
// `*Model_Space`, is `.block(index)`-owned; direct ENTITIES-section content
// is `.model`/`.paper`-owned).
extension DXFStructuralWriter {

    static func writeBlocksSection(parsed: EditableParsedDocument, store: EntityStore,
                                   version: DXFVersion, graph: HandleGraph,
                                   out: DXFOutputStream, warnings: inout [WriteWarning]) {
        out.pair(0, "SECTION")
        out.pair(2, "BLOCKS")

        writeSpaceBlock(name: "*Model_Space", parsed: parsed, store: store, version: version,
                        graph: graph, out: out, warnings: &warnings)
        writeSpaceBlock(name: "*Paper_Space", parsed: parsed, store: store, version: version,
                        graph: graph, out: out, warnings: &warnings)

        for (name, b) in parsed.blocks.sorted(by: { $0.key < $1.key }) {
            let upper = name.uppercased()
            guard !upper.hasPrefix("*MODEL_SPACE"), upper != "$MODEL_SPACE", !upper.hasPrefix("*PAPER_SPACE") else { continue }
            writeUserBlock(name: name, block: b, parsed: parsed, store: store, version: version,
                          graph: graph, out: out, warnings: &warnings)
        }

        warnOnOrphanedBlockEntities(parsed: parsed, store: store, warnings: &warnings)

        out.pair(0, "ENDSEC")
    }

    /// Detects entities whose `owner` points at a block index that
    /// `EntityStoreParser` never actually registered into `parsed.blocks` —
    /// a malformed source BLOCK record with an empty/missing name (group 2
    /// AND group 3 both blank/absent). `EntityStoreParser`'s ENDBLK handler
    /// only does `out.blocks[b.name] = b` when `!b.name.isEmpty` (see that
    /// file's ENDBLK case), but it unconditionally assigns a `blockIndex`
    /// to the BLOCK the moment it starts and gives every entity parsed
    /// inside it a valid `owner: .block(blockIndex)` regardless — so those
    /// entities exist in `EntityStore` with real geometry, but the block
    /// they claim to belong to is invisible to `writeBlocksSection`'s
    /// `for (name, b) in parsed.blocks` walk above, since it can only ever
    /// iterate blocks that MADE IT into that dictionary.
    ///
    /// Per this session's task brief, `EntityStoreParser.swift` is
    /// explicitly out of scope to touch (a different subsystem, risk of
    /// destabilizing something else) — so this writer-side check does NOT
    /// attempt to recover or emit those entities' content (their block has
    /// no name to write a BLOCK record under, no BLOCK_RECORD handle
    /// anywhere in `HandleGraph`, and no well-defined DXF representation
    /// without one). It instead makes the loss VISIBLE via a `WriteWarning`
    /// rather than leaving it silent, so a caller inspecting warnings (or a
    /// future session that wants to actually fix the root cause in the
    /// parser) has a concrete signal instead of just a smaller-than-expected
    /// entity count with no explanation.
    private static func warnOnOrphanedBlockEntities(parsed: EditableParsedDocument, store: EntityStore,
                                                     warnings: inout [WriteWarning]) {
        let registeredBlockIndices = Set(parsed.blocks.values.map(\.blockIndex))
        var orphanedIndices: Set<Int32> = []
        var orphanedEntityCount = 0
        for h in store.headers where !h.flags.contains(.deleted) {
            guard h.owner.isBlock, !registeredBlockIndices.contains(h.owner.raw) else { continue }
            orphanedIndices.insert(h.owner.raw)
            orphanedEntityCount += 1
        }
        guard orphanedEntityCount > 0 else { return }
        warnings.append(WriteWarning(kind: .dropped,
            message: "\(orphanedEntityCount) entit\(orphanedEntityCount == 1 ? "y" : "ies") in "
                + "\(orphanedIndices.count) unnamed/malformed block record\(orphanedIndices.count == 1 ? "" : "s") "
                + "(source BLOCK with an empty or missing name — group 2/3 both blank) could not be written: "
                + "this writer has no BLOCK/BLOCK_RECORD to attach them to, since EntityStoreParser only "
                + "registers a block into the document's block table when it has a non-empty name"))
    }

    private static func blockCommon(name: String, base: CGPointLike, flags: Int, xrefPath: String,
                                    parsed: EditableParsedDocument, version: DXFVersion, graph: HandleGraph,
                                    out: DXFOutputStream) {
        out.pair(0, "BLOCK")
        if version.hasHandles {
            out.handlePair(5, graph.blockEntityHandles[name] ?? 0)
            out.handlePair(330, graph.blockRecordHandles[name] ?? 0)
            out.pair(100, "AcDbEntity")
        }
        out.pair(8, "0")
        if version.hasHandles { out.pair(100, "AcDbBlockBegin") }
        out.pair(2, name)
        out.pair(70, flags)
        out.pair(10, base.x); out.pair(20, base.y); out.pair(30, base.z)
        out.pair(3, name)
        out.pair(1, xrefPath)
    }

    private static func blockEnd(name: String, version: DXFVersion, graph: HandleGraph, out: DXFOutputStream) {
        out.pair(0, "ENDBLK")
        if version.hasHandles {
            out.handlePair(5, graph.endBlkHandles[name] ?? 0)
            out.handlePair(330, graph.blockRecordHandles[name] ?? 0)
            out.pair(100, "AcDbEntity")
        }
        out.pair(8, "0")
        if version.hasHandles { out.pair(100, "AcDbBlockEnd") }
    }

    private static func writeSpaceBlock(name: String, parsed: EditableParsedDocument, store: EntityStore,
                                        version: DXFVersion, graph: HandleGraph,
                                        out: DXFOutputStream, warnings: inout [WriteWarning]) {
        blockCommon(name: name, base: CGPointLike(x: 0, y: 0, z: 0), flags: 0, xrefPath: "",
                   parsed: parsed, version: version, graph: graph, out: out)
        blockEnd(name: name, version: version, graph: graph, out: out)
    }

    private static func writeUserBlock(name: String, block: EditableBlockDef, parsed: EditableParsedDocument,
                                       store: EntityStore, version: DXFVersion, graph: HandleGraph,
                                       out: DXFOutputStream, warnings: inout [WriteWarning]) {
        blockCommon(name: name, base: CGPointLike(x: Double(block.base.x), y: Double(block.base.y), z: 0),
                   flags: block.flags, xrefPath: block.isXref ? block.xrefPath : "",
                   parsed: parsed, version: version, graph: graph, out: out)

        // Xref blocks: the plan's spec says "stubs — flags + path, no
        // entities" for an UNRESOLVED xref (definition unavailable at load
        // time — nothing to write). But `PackageLoader.mergeIntoStore`
        // transplants a RESOLVED xref's content directly under the host's
        // OWN xref block index (`OwnerRef.block(hostBlock.blockIndex)` —
        // verified by inspection: it is NOT re-owned to some other
        // location, contrary to an earlier assumption in this function that
        // caused a real bug caught by `--roundtrip` on the 731MB production
        // file — 10,483 polylines belonging to one resolved xref block
        // silently vanished on write because this guard skipped ALL xref
        // blocks unconditionally). A resolved xref (`wasResolved` true, or
        // simply `entityCount > 0`) must have its real content written like
        // any other block; only a genuinely-still-unresolved xref (content
        // never loaded) stays a stub.
        if !block.isXref || block.wasResolved || block.entityCount > 0 {
            let ownerHandle = graph.blockRecordHandles[name] ?? 0
            // Fresh per-block counter — a VIEWPORT living inside a block
            // (unusual, but not something this codebase's model rules out)
            // gets its own independent group-69 numbering, same as model/
            // paper space each do in `writeEntitiesSection`.
            var blockViewportCounter = 1
            writeEntitiesForOwner(.block(block.blockIndex), ownerHandle: ownerHandle,
                                 parsed: parsed, store: store, version: version, graph: graph,
                                 out: out, warnings: &warnings, viewportCounter: &blockViewportCounter)
        }

        blockEnd(name: name, version: version, graph: graph, out: out)
    }

    // MARK: - ENTITIES section

    static func writeEntitiesSection(parsed: EditableParsedDocument, store: EntityStore,
                                     version: DXFVersion, graph: HandleGraph,
                                     out: DXFOutputStream, warnings: inout [WriteWarning]) {
        out.pair(0, "SECTION")
        out.pair(2, "ENTITIES")

        let modelOwnerHandle = graph.blockRecordHandles["*Model_Space"] ?? 0
        let paperOwnerHandle = graph.blockRecordHandles["*Paper_Space"] ?? 0
        // Model space never legitimately contains VIEWPORT entities (those
        // are a paper-space-layout concept), but a fresh counter is passed
        // regardless of space for symmetry/safety — it simply never
        // increments if writeViewport is never reached there.
        var modelViewportCounter = 1
        var paperViewportCounter = 1
        writeEntitiesForOwner(.model, ownerHandle: modelOwnerHandle, parsed: parsed, store: store,
                             version: version, graph: graph, out: out, warnings: &warnings,
                             viewportCounter: &modelViewportCounter)
        writeEntitiesForOwner(.paper, ownerHandle: paperOwnerHandle, parsed: parsed, store: store,
                             version: version, graph: graph, out: out, warnings: &warnings,
                             viewportCounter: &paperViewportCounter)

        out.pair(0, "ENDSEC")
    }

    /// Shared BLOCKS/ENTITIES content walker: emits every non-deleted,
    /// non-child (top-level) entity whose owner matches `space`, in
    /// ascending `EntityID` order (== original parse/append order — stable
    /// and deterministic across repeated writes of the same store), followed
    /// immediately by any of its own ATTRIB/VERTEX-shaped children (INSERT's
    /// ATTRIBs) — matching the plan's "ATTRIB/SEQEND and VERTEX/SEQEND
    /// children inline after parents" requirement. (POLYLINE's VERTEX/SEQEND
    /// children are NOT stored as separate `EntityStore` entities at all —
    /// see `PolylinePayload`'s arena-backed storage — so `EntityRecordWriter`
    /// emits those inline as part of a single `write` call; this walker only
    /// needs to handle the INSERT/ATTRIB case, the one place this codebase's
    /// object model actually uses `OwnerRef.parentEntity`.)
    private static func writeEntitiesForOwner(_ owner: EntityOwnerKind, ownerHandle: UInt64,
                                              parsed: EditableParsedDocument, store: EntityStore,
                                              version: DXFVersion, graph: HandleGraph,
                                              out: DXFOutputStream, warnings: inout [WriteWarning],
                                              viewportCounter: inout Int) {
        for i in store.headers.indices {
            let h = store.headers[i]
            guard !h.flags.contains(.deleted) else { continue }
            guard ownerMatches(h.owner, owner) else { continue }
            let id = EntityID(raw: Int32(i))
            writeOneEntityAndChildren(id: id, h: h, ownerHandle: ownerHandle, parsed: parsed, store: store,
                                     version: version, graph: graph, out: out, warnings: &warnings,
                                     viewportCounter: &viewportCounter)
        }
    }

    private static func writeOneEntityAndChildren(id: EntityID, h: EntityHeader, ownerHandle: UInt64,
                                                  parsed: EditableParsedDocument, store: EntityStore,
                                                  version: DXFVersion, graph: HandleGraph,
                                                  out: DXFOutputStream, warnings: inout [WriteWarning],
                                                  viewportCounter: inout Int) {
        let entLayerName = layerName(for: h.layerId, parsed: parsed)
        let entLinetypeName = linetypeName(for: h.linetypeId, parsed: parsed)
        let handle = graph.entityHandles[id.raw] ?? 0
        // Computed BEFORE the write call (not after) because `writeInsert`
        // needs to know whether ATTRIB children are coming so it can emit
        // DXF group 66 ("attributes follow") correctly — that adjacency
        // data lives entirely in `graph.childrenByParent`, which
        // `EntityRecordWriter` has no access to on its own.
        let insertHasAttribChildren = h.type == .insert && !(graph.childrenByParent[id.raw] ?? []).isEmpty
        // Group 69 ("viewport ID") must be a unique, sequential, positive
        // integer within the layout/space a VIEWPORT belongs to — real
        // AutoCAD reserves 1 for the layout's own overall/master viewport
        // and numbers floating viewports 2, 3, 4... from there. This writer
        // doesn't model a separate "overall viewport" record, so it simply
        // numbers every VIEWPORT it actually writes sequentially starting
        // at 1, scoped to one `viewportCounter` per space/block (see the
        // call sites in `writeEntitiesSection`/`writeBlocksSection`) —
        // previously this was hardcoded to a bare `1` for every viewport,
        // which is spec-violating (duplicate IDs) for any layout with more
        // than one floating viewport.
        var thisViewportID = 0
        if h.type == .viewport {
            thisViewportID = viewportCounter
            viewportCounter += 1
        }
        EntityRecordWriter.write(id: id, header: h, store: store, ownerHandle: ownerHandle, handle: handle,
                                layerName: entLayerName, linetypeName: entLinetypeName, version: version, out: out,
                                nextHandle: { graph.dynamicHandles.allocate() }, warnings: &warnings,
                                hasAttribChildren: insertHasAttribChildren, viewportID: thisViewportID)

        // INSERT's ATTRIB children, if any — emitted inline right after
        // their parent INSERT, each closed with its own SEQEND (matches
        // AutoCAD's own INSERT-with-attributes record shape).
        if insertHasAttribChildren, let kids = graph.childrenByParent[id.raw] {
            for kidID in kids {
                guard let kh = store.header(kidID), !kh.flags.contains(.deleted) else { continue }
                let kidHandle = graph.entityHandles[kidID.raw] ?? 0
                let kidLayer = layerName(for: kh.layerId, parsed: parsed)
                let kidLt = linetypeName(for: kh.linetypeId, parsed: parsed)
                EntityRecordWriter.write(id: kidID, header: kh, store: store, ownerHandle: handle, handle: kidHandle,
                                        layerName: kidLayer, linetypeName: kidLt, version: version, out: out,
                                        nextHandle: { graph.dynamicHandles.allocate() }, warnings: &warnings)
            }
            out.pair(0, "SEQEND")
            if version.hasHandles {
                // Drawn from `graph.dynamicHandles` — the SAME reserved
                // dynamic range `DXFHandleGraphBuilder`'s second small pass
                // counted this SEQEND into — NOT a live
                // `graph.allocator.allocate()` call, which `$HANDSEED`
                // (already written by the time this runs) couldn't
                // account for.
                out.handlePair(5, graph.dynamicHandles.allocate())
                out.handlePair(330, handle)
                out.pair(100, "AcDbEntity")
            }
            out.pair(8, entLayerName)
        }
    }

    // MARK: - Small shared helpers

    enum EntityOwnerKind { case model, paper, block(Int32) }

    private static func ownerMatches(_ owner: OwnerRef, _ kind: EntityOwnerKind) -> Bool {
        switch kind {
        case .model: return owner.isModel
        case .paper: return owner.isPaper
        case .block(let idx): return owner.isBlock && owner.raw == idx
        }
    }

    static func layerName(for layerId: Int32, parsed: EditableParsedDocument) -> String {
        let i = Int(layerId)
        guard i >= 0, i < parsed.layers.count else { return "0" }
        return parsed.layers[i].name
    }

    static func linetypeName(for linetypeId: Int16, parsed: EditableParsedDocument) -> String? {
        if linetypeId == -1 { return nil }           // BYLAYER — common() omits group 6 for this
        if linetypeId == -2 { return "BYBLOCK" }
        let i = Int(linetypeId)
        guard i >= 0, i < parsed.linetypes.count else { return nil }
        return parsed.linetypes[i].name
    }
}

/// Tiny coordinate carrier so `blockCommon` doesn't need to import
/// CoreGraphics types beyond what's already used elsewhere — avoids
/// conflating "a CGPoint" (2D, used for block base points in the parsed
/// model) with the 3D `Vec3` this writer otherwise uses everywhere.
struct CGPointLike { var x: Double; var y: Double; var z: Double }
