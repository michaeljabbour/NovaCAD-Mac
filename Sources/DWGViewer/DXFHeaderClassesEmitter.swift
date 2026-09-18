import Foundation

// MARK: - Phase 3: HEADER + CLASSES section emitters

extension DXFStructuralWriter {

    /// HEADER: echoes every parsed `$VAR` in file order (see
    /// `OrderedHeaderVars`), OVERWRITING the computed vars
    /// ($ACADVER/$HANDSEED/$EXTMIN/$EXTMAX/$INSUNITS — see
    /// `DXFHeaderTemplate.computedVarNames`) with this write's own fresh
    /// values wherever the source already defined them, then appends any
    /// STILL-missing computed var plus every `DXFHeaderTemplate.defaults`
    /// entry the source didn't already define.
    static func writeHeaderSection(parsed: EditableParsedDocument, version: DXFVersion,
                                   graph: HandleGraph, extents: Extents, out: DXFOutputStream) {
        out.pair(0, "SECTION")
        out.pair(2, "HEADER")

        var emitted: Set<String> = []

        func emitComputed(_ name: String) {
            emitted.insert(name)
            switch name {
            case "$ACADVER":
                out.pair(9, "$ACADVER"); out.pair(1, version.rawValue)
            case "$HANDSEED":
                guard version.hasHandles else { return }
                out.pair(9, "$HANDSEED"); out.handlePair(5, graph.allocator.handseed)
            case "$EXTMIN":
                out.pair(9, "$EXTMIN")
                out.pair(10, extents.isEmpty ? 0 : extents.minX)
                out.pair(20, extents.isEmpty ? 0 : extents.minY)
                out.pair(30, extents.isEmpty ? 0 : extents.minZ)
            case "$EXTMAX":
                out.pair(9, "$EXTMAX")
                out.pair(10, extents.isEmpty ? 0 : extents.maxX)
                out.pair(20, extents.isEmpty ? 0 : extents.maxY)
                out.pair(30, extents.isEmpty ? 0 : extents.maxZ)
            case "$INSUNITS":
                out.pair(9, "$INSUNITS"); out.pair(70, parsed.insUnits)
            default:
                break
            }
        }

        // 1. Echo every source var in file order, substituting computed
        //    values in place for the handful this writer always overrides —
        //    this preserves the SOURCE's ordering/position for those vars
        //    (AutoCAD itself is tolerant of HEADER var order, but keeping it
        //    stable minimizes unnecessary diff noise against the original
        //    file for a human comparing before/after).
        for v in parsed.headerVars.vars {
            let key = v.name.uppercased()
            guard !emitted.contains(key) else { continue }   // malformed source repeating a var — first wins, matches OrderedHeaderVars' own doc comment
            if DXFHeaderTemplate.computedVarNames.contains(key) {
                emitComputed(key)
            } else {
                out.pair(9, v.name)
                for p in v.pairs { out.pair(Int(p.code), p.value) }
                emitted.insert(key)
            }
        }

        // 2. Any computed var the source never had at all still must be
        //    written (a from-scratch or heavily-stripped source).
        for name in DXFHeaderTemplate.computedVarNames where !emitted.contains(name) {
            emitComputed(name)
        }

        // 3. $MEASUREMENT: a smarter DEFAULT than the hardcoded-constant
        //    entries in `DXFHeaderTemplate.defaults` below — derived from
        //    $INSUNITS (see `measurementValue(forInsUnits:)`'s doc comment)
        //    — but still only a fill-the-gap default: only written here if
        //    the source didn't already supply its own $MEASUREMENT above
        //    (step 1), matching every other var's "source always wins" rule.
        if !emitted.contains("$MEASUREMENT") {
            out.pair(9, "$MEASUREMENT")
            out.pair(70, DXFHeaderTemplate.measurementValue(forInsUnits: parsed.insUnits))
            emitted.insert("$MEASUREMENT")
        }

        // 4. Fill remaining gaps from the curated template, preserving
        //    template order, skipping anything already emitted above.
        for entry in DXFHeaderTemplate.defaults where !emitted.contains(entry.name.uppercased()) {
            out.pair(9, entry.name)
            for (code, value) in entry.pairs { out.pair(code, value) }
            emitted.insert(entry.name.uppercased())
        }

        out.pair(0, "ENDSEC")
    }

    /// CLASSES: verbatim echo of everything the parser captured — per the
    /// task brief, synthesizing NEW class rows for object types this
    /// codebase doesn't yet author itself is explicitly out of scope this
    /// session. R12/R13 omit this section entirely (no CLASSES support).
    static func writeClassesSection(parsed: EditableParsedDocument, out: DXFOutputStream) {
        guard !parsed.classes.isEmpty else { return }
        out.pair(0, "SECTION")
        out.pair(2, "CLASSES")
        for c in parsed.classes {
            out.pair(0, c.recordType)
            for p in c.pairs { out.pair(Int(p.code), p.value) }
        }
        out.pair(0, "ENDSEC")
    }
}

// MARK: - RawGroupValue -> DXFOutputStream bridging

extension DXFOutputStream {
    /// Emits one already-classified `RawGroupValue` at `code` — the bridge
    /// between `DXFMetadataModel`'s parse-time capture and this writer's
    /// output, used by every verbatim-echo section (HEADER template
    /// substitution aside, CLASSES, extra TABLES, OBJECTS raw echoes).
    /// Handle-shaped values re-emit their ORIGINAL hex text verbatim (not
    /// re-derived from the parsed `UInt64`) UNLESS a rewrite is requested by
    /// the caller — plain echo call sites always want byte-faithful
    /// preservation of whatever the source wrote (leading zeros, casing).
    ///
    /// KNOWN FRAGILITY (confirmed safe today, documented rather than fixed
    /// per adversarial review): HEADER vars that are themselves
    /// handle-typed pointers into another section (e.g. `$CPSNID`, a
    /// pointer to a plot-style-name object in OBJECTS) go through THIS
    /// verbatim-echo path, not through `HandleGraph`'s handle-remapping —
    /// so if the record that handle points at ever needed a DIFFERENT
    /// handle in the OUTPUT (e.g. because `HandleGraph.reuseOrAllocate`
    /// resolved a collision and reassigned it — see that method's doc
    /// comment), this echoed pointer would silently go stale, still
    /// pointing at the OLD handle value. This is safe under the writer's
    /// CURRENT policy of "never reassign an existing nonzero handle except
    /// on a genuine collision" (collisions are rare and, when they do
    /// happen, are not currently known to involve any handle a HEADER var
    /// like `$CPSNID` points at) — but would become a real bug if that
    /// policy ever changed to reassign handles more aggressively. Flagged
    /// here so it's the first place a future change to `reuseOrAllocate`'s
    /// collision policy gets checked against.
    func pair(_ code: Int, _ value: RawGroupValue) {
        switch value {
        case .string(let s): pair(code, s)
        case .double(let d): pair(code, d)
        case .int(let i): pair(code, Int(i))
        case .handle(_, let hex): pair(code, hex)
        }
    }
}
