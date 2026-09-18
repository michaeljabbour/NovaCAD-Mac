import Foundation

// MARK: - Phase 3.1: structural DXF writer
//
// Serializes a COMPLETE, valid DXF file (all six sections: HEADER, CLASSES,
// TABLES, BLOCKS, ENTITIES, OBJECTS) from an `EditableDocument`'s
// `EntityStore` plus the `EditableParsedDocument` metadata captured
// alongside it (see DXFMetadataModel.swift). This is a fundamentally
// different, much more capable writer than the existing `DXFWriter.swift`
// (which only injects small markup batches into an existing file) — this
// one can produce a from-scratch, complete file good enough to be the whole
// drawing, the actual "Save"/"Save As" backing implementation a later
// session wires into the UI.
//
// Scope for this session (see task brief's prioritization): solid support
// for AC1015+ (2000 and later — handles, lineweight, true color all
// available) across every entity type this codebase's `EntityStore` can
// hold; a correct, if less exhaustively tested, R12 degrade path; handle
// graph correctness treated as the top priority (a file AutoCAD refuses to
// open is worse than any cosmetic version-degrade gap). CLASSES/complex
// OBJECTS synthesis for object types nothing in this codebase authors yet
// is explicitly deferred — verbatim echo of what was parsed is enough.
enum DXFVersion: String {
    case r12 = "AC1009"
    case r14 = "AC1014"
    case r2000 = "AC1015"
    case r2004 = "AC1018"
    case r2007 = "AC1021"
    case r2010 = "AC1024"
    case r2013 = "AC1027"
    case r2018 = "AC1032"

    /// Ordinal for simple "is this version >= X" comparisons — NOT the same
    /// as comparing `rawValue` strings (which would sort lexicographically,
    /// wrong for "AC1009" vs "AC1014" style codes... actually those DO sort
    /// correctly lexicographically since they're all the same length and
    /// numerically increasing, but relying on that would be fragile/subtle;
    /// this explicit ordinal is the readable, obviously-correct choice).
    var ordinal: Int {
        switch self {
        case .r12: return 0
        case .r14: return 1
        case .r2000: return 2
        case .r2004: return 3
        case .r2007: return 4
        case .r2010: return 5
        case .r2013: return 6
        case .r2018: return 7
        }
    }

    var hasHandles: Bool { ordinal >= DXFVersion.r14.ordinal }
    var supportsLWPolyline: Bool { ordinal >= DXFVersion.r14.ordinal }
    var supportsLineweight: Bool { ordinal >= DXFVersion.r2000.ordinal }
    var supportsTrueColor: Bool { ordinal >= DXFVersion.r2004.ordinal }
    var supportsUTF8: Bool { ordinal >= DXFVersion.r2007.ordinal }
    /// CLASSES/full OBJECTS graph — meaningful starting at R2000; R12/R13
    /// have no CLASSES section and only a minimal/no OBJECTS section.
    var supportsClassesAndObjects: Bool { ordinal >= DXFVersion.r2000.ordinal }
}

extension DXFVersion: Comparable {
    static func < (lhs: DXFVersion, rhs: DXFVersion) -> Bool { lhs.ordinal < rhs.ordinal }
}

struct WriteWarning: CustomStringConvertible {
    enum Kind { case degraded, dropped, bestEffort }
    var kind: Kind
    var message: String
    var description: String { message }
}

struct DXFWriteOptions {
    var version: DXFVersion = .r2000
    init(version: DXFVersion = .r2000) { self.version = version }
}

enum DXFStructuralWriter {

    enum WriteError: LocalizedError {
        case cannotCreateFile(String)
        var errorDescription: String? {
            switch self {
            case .cannotCreateFile(let path): return "Could not create output file at \(path)."
            }
        }
    }

    /// Writes `doc` (an `EditableDocument`'s live entity store) plus
    /// `parsed`'s captured structural metadata (HEADER vars, CLASSES,
    /// extra TABLES, OBJECTS) to `url` as a complete DXF file.
    ///
    /// - Important: `parsed` and `doc` must correspond to the SAME document
    ///   (`parsed.document === doc` in the normal, intended usage — passed
    ///   separately only because `EditableParsedDocument` already exists as
    ///   the natural home for the metadata and callers may hold onto it
    ///   distinctly from just the `EditableDocument`/`EntityStore` pair).
    @discardableResult
    static func write(_ parsed: EditableParsedDocument, to url: URL,
                      options: DXFWriteOptions = DXFWriteOptions()) throws -> [WriteWarning] {
        let doc = parsed.document
        let store = doc.store
        var warnings: [WriteWarning] = []

        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: url.path) else {
            throw WriteError.cannotCreateFile(url.path)
        }
        defer { try? handle.close() }
        let out = DXFOutputStream(handle: handle)

        let version = options.version

        // ---- Handle graph: pass 1 (assign handles to everything) ----
        // Must fully account for every handle pass 2 will EVER hand out —
        // including the dynamic per-entity extras (POLYLINE's VERTEX/SEQEND
        // children, degraded MTEXT's per-line TEXT records, degraded
        // HATCH's boundary-loop POLYLINE/VERTEX/SEQEND chains) — BEFORE
        // `$HANDSEED` is computed and written, since HEADER (which carries
        // $HANDSEED) is necessarily the FIRST section in the file but must
        // report the handle AFTER every other section's allocations. A
        // two-pass "allocate for real, then replay" scheme would risk the
        // two passes drifting out of sync; instead `buildHandleGraph`
        // pre-counts exactly how many extra handles each entity's pass-2
        // emission will consume (a pure function of its payload + version,
        // no I/O) and reserves that many up front — see
        // `DXFHandleGraphBuilder.dynamicChildHandleCount`.
        let graph = buildHandleGraph(parsed: parsed, store: store, version: version)
        let handseedAfterPass1 = graph.allocator.handseed

        // ---- Compute extents from live geometry (drives $EXTMIN/$EXTMAX) ----
        let extents = computeExtents(store: store)

        // ---- Section emission (pass 2) ----
        writeHeaderSection(parsed: parsed, version: version, graph: graph, extents: extents, out: out)
        if version.supportsClassesAndObjects {
            writeClassesSection(parsed: parsed, out: out)
        }
        writeTablesSection(parsed: parsed, store: store, version: version, graph: graph, out: out)
        writeBlocksSection(parsed: parsed, store: store, version: version, graph: graph, out: out, warnings: &warnings)
        writeEntitiesSection(parsed: parsed, store: store, version: version, graph: graph, out: out, warnings: &warnings)
        if version.supportsClassesAndObjects {
            writeObjectsSection(parsed: parsed, version: version, graph: graph, out: out)
        }

        out.write("0\nEOF\n")
        out.flush()

        // Safety net for the pass-1/pass-2 handle-count duplication
        // documented above: if pass 2 allocated even ONE handle beyond what
        // pass 1 pre-counted, `$HANDSEED` (already written, can't be fixed
        // up in a stream) UNDER-reports the true max handle in the file —
        // exactly the collision-risk bug `testAllHandlesAreUniqueAfterRoundTrip`
        // caught during development. Fails loudly in debug builds rather
        // than silently shipping a corrupt-on-next-AutoCAD-edit file.
        //
        // KNOWN GAP (confirmed non-live, documented rather than fixed per
        // adversarial review): this assertion only covers `graph.allocator`
        // (the FIXED-handle allocator — entities' own handle, tables,
        // blocks, symbol records). It does NOT independently verify
        // `graph.dynamicHandles` (the SEPARATE allocator for VERTEX/SEQEND/
        // degraded-MTEXT-line/degraded-HATCH-loop children — see
        // `HandleGraph.dynamicHandles`'s doc comment) stayed in sync with
        // `dynamicChildHandleCount`'s pass-1 count the same way. Today this
        // is safe because `dynamicChildHandleCount` and pass 2's actual
        // consumption are hand-kept-in-sync mirrors of the exact same
        // switch over entity type/version (see that function's own doc
        // comment demanding this), verified indirectly by
        // `testAllHandlesAreUniqueAfterRoundTrip` passing — but it IS a
        // landmine for a future entity type/degrade path that adds a new
        // dynamic-handle-consuming branch to `EntityRecordWriter.write`
        // without updating `dynamicChildHandleCount` to match: that drift
        // would silently produce duplicate handles with no assertion catching
        // it, unlike the fixed-handle side which this assertion does guard.
        assert(graph.allocator.handseed == handseedAfterPass1,
              "pass 2 allocated \(graph.allocator.handseed - handseedAfterPass1) handle(s) beyond what pass 1 " +
              "(dynamicChildHandleCount) pre-counted — $HANDSEED written in HEADER is now stale/unsafe")

        return warnings
    }

    // MARK: - Extents

    struct Extents { var minX, minY, minZ, maxX, maxY, maxZ: Double; var isEmpty: Bool }

    private static func computeExtents(store: EntityStore) -> Extents {
        var minX = Double.greatestFiniteMagnitude, minY = Double.greatestFiniteMagnitude, minZ = Double.greatestFiniteMagnitude
        var maxX = -Double.greatestFiniteMagnitude, maxY = -Double.greatestFiniteMagnitude, maxZ = -Double.greatestFiniteMagnitude
        var any = false
        for i in store.headers.indices {
            let h = store.headers[i]
            guard !h.flags.contains(.deleted), h.owner.isModel || h.owner.isPaper else { continue }
            let b = store.bounds(EntityID(raw: Int32(i)))
            guard b != .zero || h.type == .point else { continue }
            any = true
            minX = min(minX, Double(b.minX)); minY = min(minY, Double(b.minY))
            maxX = max(maxX, Double(b.maxX)); maxY = max(maxY, Double(b.maxY))
        }
        if !any { return Extents(minX: 0, minY: 0, minZ: 0, maxX: 0, maxY: 0, maxZ: 0, isEmpty: true) }
        if minZ == Double.greatestFiniteMagnitude { minZ = 0 }
        if maxZ == -Double.greatestFiniteMagnitude { maxZ = 0 }
        return Extents(minX: minX, minY: minY, minZ: minZ, maxX: maxX, maxY: maxY, maxZ: maxZ, isEmpty: false)
    }
}
