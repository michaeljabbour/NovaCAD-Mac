import CADCore
import Foundation

// MARK: - Phase 3: TABLES section emitter
//
// AutoCAD's canonical TABLES order: VPORT, LTYPE, LAYER, STYLE, VIEW, UCS,
// APPID, DIMSTYLE, BLOCK_RECORD. LAYER/LTYPE are driven from this
// codebase's own typed `DXFLayer`/`DXFLinetype` models (kept in
// `parsed.layers`/`parsed.linetypes`, mutable/render-facing); the other five
// are driven from the generic `SymbolRecord` capture in
// `parsed.symbolTables` (verbatim echo of `rawPairs`, with handle/owner
// substitution where pass 1 reassigned a handle).
extension DXFStructuralWriter {

    static func writeTablesSection(parsed: EditableParsedDocument, store: EntityStore,
                                   version: DXFVersion, graph: HandleGraph, out: DXFOutputStream) {
        out.pair(0, "SECTION")
        out.pair(2, "TABLES")

        writeVportTable(parsed: parsed, version: version, graph: graph, out: out)
        writeLtypeTable(parsed: parsed, version: version, graph: graph, out: out)
        writeLayerTable(parsed: parsed, version: version, graph: graph, out: out)
        writeGenericSymbolTable("STYLE", parsed: parsed, version: version, graph: graph, out: out)
        writeGenericSymbolTable("VIEW", parsed: parsed, version: version, graph: graph, out: out)
        writeGenericSymbolTable("UCS", parsed: parsed, version: version, graph: graph, out: out)
        writeGenericSymbolTable("APPID", parsed: parsed, version: version, graph: graph, out: out, ensureACAD: true)
        writeGenericSymbolTable("DIMSTYLE", parsed: parsed, version: version, graph: graph, out: out)
        writeBlockRecordTable(parsed: parsed, store: store, version: version, graph: graph, out: out)

        out.pair(0, "ENDSEC")
    }

    private static func tableHeader(_ name: String, version: DXFVersion, graph: HandleGraph, out: DXFOutputStream, count: Int? = nil) {
        out.pair(0, "TABLE")
        out.pair(2, name)
        if version.hasHandles {
            out.handlePair(5, graph.tableHeaderHandles[name] ?? graph.allocator.allocate())
            out.pair(330, "0")
            out.pair(100, "AcDbSymbolTable")
        }
        if let count { out.pair(70, count) }
    }

    // MARK: VPORT (always at least one: *ACTIVE)

    private static func writeVportTable(parsed: EditableParsedDocument, version: DXFVersion,
                                        graph: HandleGraph, out: DXFOutputStream) {
        let records = parsed.symbolTables["VPORT"] ?? []
        tableHeader("VPORT", version: version, graph: graph, out: out, count: max(records.count, 1))
        if records.isEmpty {
            // Source had no VPORT table at all (unusual but legal for a
            // minimal/R12 source) — synthesize the one AutoCAD always needs.
            // Handle comes from pass 1's pre-reservation (see
            // `buildHandleGraph`'s VPORT handling) — NOT a live
            // `graph.allocator.allocate()` call here, which `$HANDSEED`
            // (already written by the time this runs) couldn't account for.
            out.pair(0, "VPORT")
            if version.hasHandles {
                out.handlePair(5, graph.symbolRecordHandles["VPORT"]?[0] ?? 0)
                out.handlePair(330, graph.tableHeaderHandles["VPORT"] ?? 0)
                out.pair(100, "AcDbSymbolTableRecord"); out.pair(100, "AcDbViewportTableRecord")
            }
            out.pair(2, "*ACTIVE")
            out.pair(70, 0)
            out.pair(10, 0.0); out.pair(20, 0.0)
            out.pair(11, 1.0); out.pair(21, 1.0)
            out.pair(12, 50.0); out.pair(22, 50.0)
            out.pair(40, 100.0)
        } else {
            emitSymbolRecords("VPORT", records, version: version, graph: graph, out: out)
        }
        out.pair(0, "ENDTAB")
    }

    // MARK: LTYPE (from DXFLinetype — always has CONTINUOUS at index 0)

    private static func writeLtypeTable(parsed: EditableParsedDocument, version: DXFVersion,
                                        graph: HandleGraph, out: DXFOutputStream) {
        tableHeader("LTYPE", version: version, graph: graph, out: out, count: parsed.linetypes.count)
        for (i, lt) in parsed.linetypes.enumerated() {
            out.pair(0, "LTYPE")
            if version.hasHandles {
                out.handlePair(5, graph.linetypeHandles[Int16(i)] ?? 0)
                out.handlePair(330, graph.tableHeaderHandles["LTYPE"] ?? 0)
                out.pair(100, "AcDbSymbolTableRecord"); out.pair(100, "AcDbLinetypeTableRecord")
            }
            out.pair(2, lt.name)
            out.pair(70, 0)
            out.pair(3, "")
            out.pair(72, 65)
            // Dash pattern is stored post-$LTSCALE-application in
            // `DXFLinetype.dashes` (CGFloat, already scaled — see
            // EntityStoreParser's `flushLtypeRecord`) — re-derive an
            // approximate element count/total pattern length rather than
            // the ORIGINAL raw group-49 values, which aren't retained
            // separately. A continuous linetype (empty dashes) writes 0
            // dash elements, matching AutoCAD's own CONTINUOUS definition.
            out.pair(73, lt.dashes.count)
            let total = lt.dashes.reduce(0) { $0 + Double($1) }
            out.pair(40, total)
            for (idx, d) in lt.dashes.enumerated() {
                // Even elements = pen-down (positive length); odd = gap
                // (negative length) — DXF's own dash-array sign convention.
                out.pair(49, idx % 2 == 0 ? Double(d) : -Double(d))
                out.pair(74, 0)
            }
        }
        out.pair(0, "ENDTAB")
    }

    // MARK: LAYER (from DXFLayer)

    private static func writeLayerTable(parsed: EditableParsedDocument, version: DXFVersion,
                                        graph: HandleGraph, out: DXFOutputStream) {
        tableHeader("LAYER", version: version, graph: graph, out: out, count: parsed.layers.count)
        for l in parsed.layers {
            out.pair(0, "LAYER")
            if version.hasHandles {
                out.handlePair(5, graph.layerHandles[Int32(l.id)] ?? 0)
                out.handlePair(330, graph.tableHeaderHandles["LAYER"] ?? 0)
                out.pair(100, "AcDbSymbolTableRecord"); out.pair(100, "AcDbLayerTableRecord")
            }
            out.pair(2, l.name)
            out.pair(70, l.isFrozen ? 1 : 0)
            let aci: Int
            switch l.color {
            case .foreground: aci = 7
            case .rgb(let rgb): aci = ACIPalette.nearestACI(forRGB: rgb)
            }
            out.pair(62, l.isOffByDefault ? -abs(aci == 0 ? 7 : aci) : (aci == 0 ? 7 : aci))
            let ltName = l.linetypeId >= 0 && l.linetypeId < parsed.linetypes.count
                ? parsed.linetypes[l.linetypeId].name : "CONTINUOUS"
            out.pair(6, ltName)
            if version.supportsLineweight { out.pair(370, -3) }
            if version.hasHandles {
                out.handlePair(390, 0)   // plot-style handle placeholder — this codebase doesn't retain the original PLOTSTYLE dictionary linkage
            }
            if case .rgb(let rgb) = l.color, version.supportsTrueColor {
                out.pair(420, Int(rgb & 0x00FF_FFFF))
            }
            // Group 440: AutoCAD-style layer transparency (0x02000000 |
            // alpha, alpha 0...255, 0=100% transparent/0xFF=opaque) — see
            // `DXFLayer.transparency`'s own doc comment for the full
            // contract this mirrors, and `EntityStoreParser`'s matching
            // group-440 read for the decode side. Only R2004+ actually
            // supports entity/layer transparency at all (same DXF-version
            // gate `supportsTrueColor` already uses for group 420, since
            // both were introduced in the same AC1018 revision) — omitted
            // entirely for an opaque (0%) layer, matching how the vast
            // majority of real DXFs never carry this group, rather than
            // emitting a redundant "opaque" value on every layer.
            if version.supportsTrueColor, l.transparency > 0 {
                let alphaByte = 255 - Int((min(max(l.transparency, 0), 100) / 100 * 255).rounded())
                out.pair(440, 0x0200_0000 | alphaByte)
            }
        }
        out.pair(0, "ENDTAB")
    }

    // MARK: Generic (STYLE/VIEW/UCS/APPID/DIMSTYLE) — echo rawPairs, substituting handles

    private static func writeGenericSymbolTable(_ tableType: String, parsed: EditableParsedDocument,
                                                version: DXFVersion, graph: HandleGraph,
                                                out: DXFOutputStream, ensureACAD: Bool = false) {
        let records = effectiveSymbolRecords(tableType, parsed: parsed, ensureACAD: ensureACAD)
        tableHeader(tableType, version: version, graph: graph, out: out, count: records.count)
        emitSymbolRecords(tableType, records, version: version, graph: graph, out: out)
        out.pair(0, "ENDTAB")
    }

    /// The DEFINITIVE record list for a generic symbol table — parsed
    /// records if any exist, else the synthesized default this writer
    /// always needs for STYLE/DIMSTYLE/(APPID when `ensureACAD`). Called
    /// from BOTH `buildHandleGraph` (pass 1, so a synthesized record's
    /// handle gets allocated at the same index the emitter will look up)
    /// and `writeGenericSymbolTable` (pass 2) — a single shared source of
    /// truth so the two can never drift out of index-alignment with each
    /// other (the bug this replaced: pass 1 only ever saw the ORIGINAL
    /// parsed records, so a synthesized STYLE/DIMSTYLE/APPID row looked up
    /// a handle at an index pass 1 never populated, silently writing handle
    /// 0 for it).
    static func effectiveSymbolRecords(_ tableType: String, parsed: EditableParsedDocument,
                                       ensureACAD: Bool = false) -> [SymbolRecord] {
        let records = parsed.symbolTables[tableType] ?? []
        guard records.isEmpty else { return records }
        // A few of these MUST exist for AutoCAD to accept the file at all
        // (STYLE needs STANDARD; DIMSTYLE needs STANDARD; APPID needs ACAD).
        // VIEW/UCS have no such requirement (0 rows is legal) so those are
        // left genuinely empty when the source had none — matches real
        // AutoCAD's own behavior for a drawing that never defined any named
        // view/UCS.
        if tableType == "STYLE" || tableType == "DIMSTYLE" || (tableType == "APPID" && ensureACAD) {
            return [synthesizedDefaultRecord(tableType)]
        }
        return []
    }

    private static func synthesizedDefaultRecord(_ tableType: String) -> SymbolRecord {
        switch tableType {
        case "STYLE":
            return SymbolRecord(tableType: "STYLE", name: "STANDARD", handle: 0, ownerHandle: 0, flags: 0,
                                rawPairs: [
                                    RawGroupPair(code: 2, value: .string("STANDARD")),
                                    RawGroupPair(code: 70, value: .int(0)),
                                    RawGroupPair(code: 40, value: .double(0)),
                                    RawGroupPair(code: 41, value: .double(1)),
                                    RawGroupPair(code: 50, value: .double(0)),
                                    RawGroupPair(code: 71, value: .int(0)),
                                    RawGroupPair(code: 42, value: .double(2.5)),
                                    RawGroupPair(code: 3, value: .string("txt.shx")),
                                    RawGroupPair(code: 4, value: .string("")),
                                ], typed: .style(fontFile: "txt.shx", bigFontFile: ""))
        case "DIMSTYLE":
            return SymbolRecord(tableType: "DIMSTYLE", name: "STANDARD", handle: 0, ownerHandle: 0, flags: 0,
                                rawPairs: [
                                    RawGroupPair(code: 2, value: .string("STANDARD")),
                                    RawGroupPair(code: 70, value: .int(0)),
                                ], typed: .dimstyle(overrides: []))
        case "APPID":
            return SymbolRecord(tableType: "APPID", name: "ACAD", handle: 0, ownerHandle: 0, flags: 0,
                                rawPairs: [
                                    RawGroupPair(code: 2, value: .string("ACAD")),
                                    RawGroupPair(code: 70, value: .int(0)),
                                ], typed: nil)
        default:
            return SymbolRecord(tableType: tableType, name: "", handle: 0, ownerHandle: 0, flags: 0, rawPairs: [], typed: nil)
        }
    }

    /// Emits `0/<tableType>` + every group code from `rawPairs` VERBATIM,
    /// except: (a) the record's own handle (code 5, or 105 for DIMSTYLE) is
    /// substituted with pass 1's assigned handle, and (b) its owner (code
    /// 330) is substituted with the owning table-header's handle — both
    /// values may have changed from the source if pass 1 needed to allocate
    /// fresh ones (e.g. R12 source promoted to AC1015+, which has none of
    /// these at all in the source). Every other field (font names, DIMSTYLE
    /// overrides, VIEW/UCS geometry, etc.) is untouched, preserving fields
    /// this codebase has no typed understanding of.
    private static func emitSymbolRecords(_ tableType: String, _ records: [SymbolRecord],
                                          version: DXFVersion, graph: HandleGraph, out: DXFOutputStream) {
        let ownerHandle = graph.tableHeaderHandles[tableType] ?? 0
        let handleCode = tableType == "DIMSTYLE" ? 105 : 5
        for (i, r) in records.enumerated() {
            out.pair(0, tableType)
            let recordHandle = graph.symbolRecordHandles[tableType]?[i] ?? 0
            var pastCommonSection = false
            // AutoCAD always places 5 (or 105 for DIMSTYLE)/330 immediately
            // after the record-type marker — emit them unconditionally here
            // (using pass 1's assigned handle, which may differ from the
            // source's if one needed to be allocated fresh) and skip the
            // source's own copies of those codes below, rather than trying
            // to substitute them in place (simpler, and correct even when
            // the source record had no handle/owner pair at all).
            if version.hasHandles {
                out.handlePair(handleCode, recordHandle)
                out.handlePair(330, ownerHandle)
            }
            for p in r.rawPairs {
                if p.code == 100 { pastCommonSection = true }
                if version.hasHandles, !pastCommonSection, (p.code == 5 || p.code == 105 || p.code == 330) {
                    continue   // already emitted above
                }
                if !version.hasHandles, (p.code == 5 || p.code == 105 || p.code == 330 || p.code == 100) {
                    continue   // R12: no handles, no subclass markers
                }
                out.pair(Int(p.code), p.value)
            }
        }
    }

    // MARK: BLOCK_RECORD
    //
    // Driven directly from the block list (not the generic-echo path above)
    // because every block this writer's BLOCKS section will emit — model
    // space, paper space, and every real `EditableBlockDef` — needs EXACTLY
    // one matching BLOCK_RECORD, and the handle graph (`buildHandleGraph`)
    // already allocated one for every such block. Xref blocks get a stub
    // BLOCK_RECORD like any other (they still need a table entry; only
    // their BLOCKS-section content is stubbed, per the plan's spec).
    private static func writeBlockRecordTable(parsed: EditableParsedDocument, store: EntityStore,
                                              version: DXFVersion, graph: HandleGraph, out: DXFOutputStream) {
        let ownerHandle = graph.tableHeaderHandles["BLOCK_RECORD"] ?? 0
        let names = blockRecordOrder(parsed: parsed)
        tableHeader("BLOCK_RECORD", version: version, graph: graph, out: out, count: names.count)
        for name in names {
            out.pair(0, "BLOCK_RECORD")
            if version.hasHandles {
                out.handlePair(5, graph.blockRecordHandles[name] ?? 0)
                out.handlePair(330, ownerHandle)
                out.pair(100, "AcDbSymbolTableRecord"); out.pair(100, "AcDbBlockTableRecord")
            }
            out.pair(2, name)
            if version.hasHandles {
                out.pair(340, 0)   // layout handle — no distinct LAYOUT object authored for named blocks by this codebase yet (see OBJECTS emitter's model/paper-space LAYOUT handling for the two spaces themselves)
                out.pair(70, 0); out.pair(280, 1); out.pair(281, 0)
            }
        }
        out.pair(0, "ENDTAB")
    }

    /// The definitive list+order of every block name that will get a
    /// BLOCK_RECORD (and a matching BLOCKS-section BLOCK/ENDBLK pair):
    /// *Model_Space and *Paper_Space always first (matches AutoCAD's own
    /// convention — these are always BLOCK_RECORD handles 1F/... in a
    /// from-scratch file, always emitted before user blocks), then every
    /// other parsed block in a stable (sorted) order.
    static func blockRecordOrder(parsed: EditableParsedDocument) -> [String] {
        var names = ["*Model_Space", "*Paper_Space"]
        for (name, _) in parsed.blocks.sorted(by: { $0.key < $1.key }) {
            let upper = name.uppercased()
            guard !upper.hasPrefix("*MODEL_SPACE"), upper != "$MODEL_SPACE", !upper.hasPrefix("*PAPER_SPACE") else { continue }
            names.append(name)
        }
        return names
    }
}
