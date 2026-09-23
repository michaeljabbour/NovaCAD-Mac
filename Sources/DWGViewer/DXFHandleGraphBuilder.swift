import Foundation

// MARK: - Phase 3: handle graph pass 1
//
// Walks every record `DXFStructuralWriter` will emit and assigns it a
// handle: reuses the source's own handle where one already exists (parsed
// from the original file, never reassigned — see HandleAllocator.swift's
// doc comment on why this matters for foreign-pointer-graph survival), or
// allocates a fresh one for anything that doesn't have one yet (new
// entities, R12-sourced content, synthesized bookkeeping records this
// writer itself introduces like table headers).
extension DXFStructuralWriter {

    static func buildHandleGraph(parsed: EditableParsedDocument, store: EntityStore, version: DXFVersion) -> HandleGraph {
        // Seed the allocator above the highest handle seen ANYWHERE in the
        // parsed document — entities, layers, linetypes, blocks, symbol
        // tables, objects, and the source's own $HANDSEED. Never trust
        // $HANDSEED alone (a hand-edited or buggy source file's $HANDSEED
        // can under-report the true max, exactly the scenario
        // `DXFWriter.writeMergedCopy` already guards against with its own
        // max-of-both strategy — this writer applies the same idea more
        // exhaustively, across every handle-bearing structure this codebase
        // models, not just entities).
        var maxSeen: UInt64 = 0
        if let seedHex = parsed.headerVars.handseed, let seed = UInt64(seedHex, radix: 16) {
            maxSeen = max(maxSeen, seed)
        }
        for h in store.headers { maxSeen = max(maxSeen, h.handle) }
        for l in parsed.layers { maxSeen = max(maxSeen, l.handle) }
        for lt in parsed.linetypes { maxSeen = max(maxSeen, lt.handle) }
        for b in parsed.blocks.values {
            maxSeen = max(maxSeen, b.handle)
            if let brh = b.blockRecordHandle { maxSeen = max(maxSeen, brh) }
        }
        for records in parsed.symbolTables.values {
            for r in records { maxSeen = max(maxSeen, r.handle, r.ownerHandle) }
        }
        for c in parsed.classes {
            for p in c.pairs { if case .handle(let v, _) = p.value { maxSeen = max(maxSeen, v) } }
        }
        maxSeen = max(maxSeen, maxHandleInObjects(parsed.objects))

        let allocator = HandleAllocator(startingAfter: maxSeen)
        // Placeholder dynamic allocator — replaced below once the FIXED
        // handles (entities' own handle, tables, blocks, etc.) have all been
        // assigned and the total dynamic-handle count is known. See
        // `HandleGraph.dynamicHandles`'s doc comment for why this two-
        // allocator split exists (in short: counting dynamic handles and
        // actually consuming them are two separate walks that must NOT
        // share one counter, or $HANDSEED — computed after the counting
        // walk — undercounts what the consuming walk goes on to use).
        let graph = HandleGraph(allocator: allocator, dynamicHandles: HandleAllocator(startingAfter: 0))

        // ---- Entities (model/paper/block-owned, including ATTRIB/VERTEX children) ----
        // Single O(n) pass also builds the parent->children index (see
        // `HandleGraph.childrenByParent`'s doc comment on why this can't be
        // `EntityStore.children(of:)` at write-time scale) AND counts every
        // DYNAMIC extra handle this entity's pass-2 emission will consume
        // beyond its own single `handle` — VERTEX/SEQEND children for
        // polyline-family entities, extra per-line TEXT records for a
        // degraded MTEXT, extra boundary-loop POLYLINE/VERTEX/SEQEND chains
        // for a degraded multi-loop HATCH. This is a COUNT only (pure
        // arithmetic on the entity's payload shape) — no allocation happens
        // here; the total is reserved on `allocator` in one `skip(_:)` call
        // after this loop, and pass 2 draws the actual handle VALUES from
        // `graph.dynamicHandles` (see that property's doc comment).
        // Handle-uniqueness note: a source file could, in principle
        // (illegally, but not something this codebase's parser defends
        // against), assign the same handle to two different records of ANY
        // kind — two entities, an entity and a LAYER, a block and a symbol-
        // table record, etc. A concrete, confirmed case: a 3DFACE with
        // per-edge invisibility flags (group 70) splits into several
        // independent `.face3d`-typed fragments at parse time, but every
        // fragment's `common.handle` comes from the ONE shared
        // `commonProps(pairs, ...)` call captured before the per-edge loop
        // — see EntityStoreParser.swift's 3DFACE case, lines ~1105-1117 (a
        // pre-existing, out-of-scope-to-change parser characteristic; this
        // writer must tolerate it, not "fix" the parser). Blindly reusing a
        // colliding handle would silently write a duplicate 5/handle across
        // multiple records — the exact invariant AutoCAD polices strictly.
        // Rather than tracking claims locally per call site (which only
        // catches collisions WITHIN one loop, missing cross-call-site
        // collisions like layer-vs-entity), `HandleGraph.reuseOrAllocate`
        // itself now maintains the claimed-handle set centrally and
        // reassigns a fresh handle to any later caller — ANY call site,
        // not just this entity loop — that presents an already-claimed
        // value. See that method's doc comment for the full invariant.
        var totalDynamicHandles = 0
        for i in store.headers.indices {
            let h = store.headers[i]
            guard !h.flags.contains(.deleted) else { continue }
            let id = EntityID(raw: Int32(i))
            let assigned = graph.reuseOrAllocate(h.handle)
            graph.entityHandles[id.raw] = assigned
            if let parent = h.owner.parentEntityID {
                graph.childrenByParent[parent.raw, default: []].append(id)
            }
            totalDynamicHandles += dynamicChildHandleCount(for: h, store: store, version: version)
        }

        // Second small pass: every INSERT with at least one ATTRIB/VERTEX-
        // shaped child (via genuine `OwnerRef.parentEntity`, not the common
        // parsed-file case — see DXFBlocksEntitiesEmitter's doc comment on
        // why real parsed ATTRIBs are NOT children today) needs one more
        // handle for its own closing SEQEND.
        if version.hasHandles {
            for i in store.headers.indices {
                let h = store.headers[i]
                guard !h.flags.contains(.deleted), h.type == .insert else { continue }
                let id = EntityID(raw: Int32(i))
                if let kids = graph.childrenByParent[id.raw], !kids.isEmpty {
                    totalDynamicHandles += 1
                }
            }
        }

        // ---- LAYER / LTYPE (already have a `handle` field on the model struct) ----
        for l in parsed.layers { graph.layerHandles[Int32(l.id)] = graph.reuseOrAllocate(l.handle) }
        for (i, lt) in parsed.linetypes.enumerated() { graph.linetypeHandles[Int16(i)] = graph.reuseOrAllocate(lt.handle) }

        // ---- STYLE/VIEW/UCS/APPID/DIMSTYLE symbol records ----
        // Uses `DXFStructuralWriter.effectiveSymbolRecords` — the SAME
        // parsed-or-synthesized record list `writeGenericSymbolTable` (pass
        // 2) will use — so a synthesized STYLE/DIMSTYLE/APPID default row
        // (when the source had none) gets its handle allocated here, at the
        // same index the emitter looks up, rather than only ever seeing the
        // ORIGINAL (possibly empty) `parsed.symbolTables` entry.
        for tableType in ["STYLE", "VIEW", "UCS", "APPID", "DIMSTYLE"] {
            let records = DXFStructuralWriter.effectiveSymbolRecords(tableType, parsed: parsed, ensureACAD: tableType == "APPID")
            var perTable: [Int: UInt64] = [:]
            for (i, r) in records.enumerated() { perTable[i] = graph.reuseOrAllocate(r.handle) }
            graph.symbolRecordHandles[tableType] = perTable
        }
        // VPORT: real parsed records get their handles here; an EMPTY
        // source VPORT table still needs one handle reserved for
        // `writeVportTable`'s synthesized "*ACTIVE*" fallback record — index
        // 0 in a single-entry table, matching how that function looks
        // `graph.symbolRecordHandles["VPORT"]?[0]` up (this used to be a
        // live `graph.allocator.allocate()` call inside the emitter itself,
        // which pass 1 had no way to account for — exactly the kind of
        // post-HEADER allocation `$HANDSEED` must never miss; caught by
        // RoundTripTests' handle-uniqueness assertion during development).
        let vportRecords = parsed.symbolTables["VPORT"] ?? []
        if vportRecords.isEmpty {
            graph.symbolRecordHandles["VPORT"] = [0: allocator.allocate()]
        } else {
            var perTable: [Int: UInt64] = [:]
            for (i, r) in vportRecords.enumerated() { perTable[i] = graph.reuseOrAllocate(r.handle) }
            graph.symbolRecordHandles["VPORT"] = perTable
        }

        // ---- Blocks: BLOCK_RECORD (table entry) + BLOCK/ENDBLK (block-section pair) ----
        // Every block this writer will emit into BLOCKS needs its own
        // BLOCK_RECORD — including the two always-present spaces
        // (*Model_Space, *Paper_Space) which may or may not have been
        // present as parsed `EditableBlockDef`s (a from-scratch/rewritten
        // source could plausibly lack them; this writer always emits them).
        assignSpaceBlockHandles(name: "*Model_Space", parsed: parsed, graph: graph)
        assignSpaceBlockHandles(name: "*Paper_Space", parsed: parsed, graph: graph)
        for (name, b) in parsed.blocks {
            let upper = name.uppercased()
            guard upper != "*MODEL_SPACE", upper != "$MODEL_SPACE", upper != "*PAPER_SPACE" else { continue }
            graph.blockEntityHandles[name] = graph.reuseOrAllocate(b.handle)
            graph.endBlkHandles[name] = graph.allocator.allocate()
            graph.blockRecordHandles[name] = graph.reuseOrAllocate(b.blockRecordHandle ?? 0)
        }

        // ---- TABLES table-header records (0/TABLE line's own handle) ----
        for tableName in ["VPORT", "LTYPE", "LAYER", "STYLE", "VIEW", "UCS", "APPID", "DIMSTYLE", "BLOCK_RECORD"] {
            graph.tableHeaderHandles[tableName] = allocator.allocate()
        }

        // ---- OBJECTS root/synthesized dictionaries (only if the source had none) ----
        if parsed.objects.rootDictionaryHandle == nil {
            graph.syntheticRootDictionaryHandle = allocator.allocate()
        }

        // Every FIXED handle is now assigned; `allocator.handseed` is the
        // first free handle after all of them. Reserve the dynamic range
        // (advancing `allocator` — and therefore the final `$HANDSEED` — by
        // exactly `totalDynamicHandles` WITHOUT handing any of them out),
        // then hand pass 2 a fresh `dynamicHandles` allocator seeded at the
        // value `allocator` had BEFORE that reservation — see
        // `HandleGraph.dynamicHandles`'s doc comment for why this precise
        // split is what keeps $HANDSEED correct without a second I/O pass.
        let dynamicRangeStart = allocator.handseed - 1
        allocator.skip(totalDynamicHandles)
        graph.dynamicHandles = HandleAllocator(startingAfter: dynamicRangeStart)

        return graph
    }

    /// Number of EXTRA handles (beyond the entity's own single `handle`)
    /// that `EntityRecordWriter.write` will consume for this entity at the
    /// given version — mirrors that function's version-degrade branching
    /// exactly (kept in sync by hand; see the file-level doc comment on why
    /// this must be a pure function of (header, payload shape, version)
    /// with no I/O, so it can run during pass 1 before any bytes are
    /// written). Returns 0 for every entity type/version combination that
    /// writes a single self-contained record.
    private static func dynamicChildHandleCount(for h: EntityHeader, store: EntityStore, version: DXFVersion) -> Int {
        guard version.hasHandles, h.payload >= 0 else { return 0 }
        switch h.type {
        case .lwpolyline:
            let p = store.polylines[Int(h.payload)]
            if version.supportsLWPolyline && !p.is3D { return 0 }
            return Int(p.vertsCount) + 1   // one VERTEX per vertex + one SEQEND
        case .polyline2d, .polyline3d:
            let p = store.polylines[Int(h.payload)]
            return Int(p.vertsCount) + 1
        case .leader:
            let p = store.polylines[Int(h.payload)]
            return Int(p.vertsCount) + 1
        case .solid, .trace, .face3d:
            return 0   // single self-contained record, no children
        case .ellipse:
            guard version < .r14 else { return 0 }
            let p = store.ellipses[Int(h.payload)]
            var sweep = p.endParam - p.startParam
            if sweep <= 0 { sweep += 2 * .pi }
            let steps = max(16, min(128, Int(sweep / 0.05)))
            return (steps + 1) + 1   // one VERTEX per tessellated point + SEQEND
        case .spline:
            guard version < .r14 else { return 0 }
            let p = store.splines[Int(h.payload)]
            return Int(p.controlCount) + 1
        case .mtext:
            guard version < .r14 else { return 0 }
            let p = store.mtexts[Int(h.payload)]
            let text = store.strings.string(for: p.stringId)
            let lineCount = text.split(separator: "\n", omittingEmptySubsequences: false).count
            return max(lineCount - 1, 0)   // first line reuses the entity's own handle
        case .hatch:
            guard version < .r14 else { return 0 }
            let p = store.hatches[Int(h.payload)]
            var extra = 0
            for r in Int(p.loopRangeStart)..<Int(p.loopRangeStart + p.loopRangeCount) {
                let range = store.hatchLoopRanges[r]
                extra += Int(range.vertCount) + 1   // VERTEX per point + SEQEND, per loop
            }
            // First loop reuses the HATCH's own handle for its POLYLINE;
            // every loop AFTER the first needs its own top-level handle too.
            extra += max(Int(p.loopRangeCount) - 1, 0)
            return extra
        default:
            return 0
        }
    }

    private static func assignSpaceBlockHandles(name: String, parsed: EditableParsedDocument, graph: HandleGraph) {
        // Match the canonical space exactly: suffixed paper-space blocks
        // belong to separate layouts and must retain their own handles.
        let match = parsed.blocks.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        graph.blockEntityHandles[name] = graph.reuseOrAllocate(match?.handle ?? 0)
        graph.endBlkHandles[name] = graph.allocator.allocate()
        graph.blockRecordHandles[name] = graph.reuseOrAllocate(match?.blockRecordHandle ?? 0)
    }

    private static func maxHandleInObjects(_ objects: ObjectsModel) -> UInt64 {
        var m: UInt64 = 0
        for d in objects.dictionaries.values {
            m = max(m, d.handle, d.ownerHandle)
            for e in d.entries { m = max(m, e.valueHandle) }
        }
        for l in objects.layouts.values { m = max(m, l.handle, l.ownerHandle, l.blockRecordHandle ?? 0) }
        for g in objects.groups.values {
            m = max(m, g.handle, g.ownerHandle)
            for mem in g.memberHandles { m = max(m, mem) }
        }
        for i in objects.imageDefs.values { m = max(m, i.handle, i.ownerHandle) }
        for r in objects.rawObjects.values {
            m = max(m, r.handle, r.ownerHandle)
            for p in r.rawPairs { if case .handle(let v, _) = p.value { m = max(m, v) } }
        }
        return m
    }
}
