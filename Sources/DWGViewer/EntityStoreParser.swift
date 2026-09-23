import Foundation
import CADCore
import CoreGraphics

// MARK: - Block bookkeeping for the EntityStore parse path

/// One BLOCK definition's bookkeeping for the eager `EntityStore` path —
/// the entities themselves live in `EntityStore` (owner = `.block(index)`);
/// this only tracks the block-level metadata plus, for performance, the
/// contiguous `EntityID` range the parser appended (block entities are
/// always appended contiguously between BLOCK/ENDBLK, exactly as the old
/// `BlockDef.entities` array was built) so the regenerator can walk a
/// block's content without a scan over the whole store.
final class EditableBlockDef {
    var name = ""
    var base = CGPoint.zero
    var flags = 0
    var xrefPath = ""
    /// Absolute local path of the source file chosen to resolve this xref, when
    /// PackageLoader found one. This is the ORIGINAL file path (.dwg/.dxf), not
    /// necessarily the converted DXF the parser consumed.
    var xrefSourcePath = ""
    /// Absolute local path actually parsed for this xref. For DWG sources this
    /// is the cached/temporary converted DXF; for DXF sources it equals
    /// `xrefSourcePath`. "Open Xref..." uses this because NovaCAD's editor can
    /// save DXF, not DWG.
    var xrefLoadedPath = ""
    /// Stable index used as this block's `OwnerRef.block(index)` value for
    /// every entity it owns — assigned once, when the BLOCK record starts.
    var blockIndex: Int32 = -1
    /// Contiguous slot range in `EntityStore.headers` this block's entities
    /// occupy (start..<start+count), mirroring old `BlockDef.entities`'
    /// append-order semantics exactly.
    var entityStart: Int32 = 0
    var entityCount: Int32 = 0
    var isXrefDependent = false
    var wasResolved = false
    var isXref: Bool { (flags & 4) != 0 || (flags & 32) != 0 || !xrefPath.isEmpty }
    /// Phase 3 groundwork: the BLOCK entity's own handle (group 5 on the
    /// `0/BLOCK` record itself — distinct from `blockRecordHandle`, the
    /// separate BLOCK_RECORD table entry a real DXF always pairs with each
    /// block definition). 0 if absent (R12 sources). Purely additive — a
    /// new `var` on a class with no custom init to update.
    var handle: UInt64 = 0
    /// Owning BLOCK_RECORD handle, read from group 330 and reconciled with
    /// the symbol table by name after parsing. Used to associate paper-space
    /// blocks with their named layouts and preserve that link when saving.
    var blockRecordHandle: UInt64? = nil
}

/// The eager single-pass parse path's output: a populated, mutable
/// `EntityStore` (via `document.store`) plus the block/layer/linetype
/// bookkeeping the regenerator needs to expand it. Parallel to
/// `RawParseOutput`, but entities live in `EntityStore` from the moment
/// they're parsed — never a separate freed-after-use array.
final class EditableParsedDocument {
    let document = EditableDocument()
    var blocks: [String: EditableBlockDef] = [:]
    var layers: [DXFLayer] = []
    var layerIdByName: [String: Int32] = [:]
    var linetypes: [DXFLinetype] = []
    var linetypeIdByName: [String: Int16] = [:]
    var ltScale: Double = 1
    var insUnits = 0
    var skippedTypes: [String: Int] = [:]

    // MARK: Phase 3 groundwork: structural metadata retention (see
    // DXFMetadataModel.swift). Populated from the HOST file only — xref
    // merge (`PackageLoader.mergeIntoStore`) deliberately does NOT fold a
    // resolved xref's own HEADER/CLASSES/TABLES/OBJECTS into these fields,
    // matching real DXF semantics (an xref's metadata section is not part
    // of the host file's structural sections).
    var headerVars = OrderedHeaderVars()
    var classes: [RawClass] = []

    /// Set by `PackageLoader.loadIntoStore`'s xref resolution when either
    /// `storeMaxMergedEntities` or `storeMaxXrefFiles` was hit, i.e. one or
    /// more xref BLOCKs were left unresolved SOLELY because the package hit
    /// a safety cap (as opposed to a genuinely missing/unreachable source
    /// file). Distinct from a plain "source file not found" unresolved xref
    /// (see `XrefInfo.isResolved`, already surfaced per-row in the External
    /// References panel) — this flag exists so the caller can raise ONE
    /// louder, package-level warning ("this drawing hit its size limit")
    /// instead of the cap silently manifesting as an unremarkable handful of
    /// orange rows indistinguishable from ordinary missing-file xrefs. See
    /// `PackageLoader.storeMaxMergedEntities`'s doc comment for the
    /// real-production-layout motivation for the cap itself.
    var xrefMergeCapped = false
    /// Symbol-table records for VPORT/STYLE/VIEW/UCS/APPID/DIMSTYLE/
    /// BLOCK_RECORD — LAYER/LTYPE stay in `layers`/`linetypes` above
    /// (render-facing, unchanged). Keyed by table type so a writer can
    /// re-emit one TABLE block at a time in the original per-table order.
    var symbolTables: [String: [SymbolRecord]] = [:]
    var objects = ObjectsModel()
    /// View state only; nil retains legacy combined rendering for callers
    /// that have no sheet selection. All sheets remain in the editable store.
    var activePaperLayoutID: UInt64?
    var paperLayouts: [PaperLayout] { PaperLayout.sheets(in: self) }

    var store: EntityStore { document.store }
}

/// Retention gap this parser closes vs. the legacy `RawParseOutput` path:
/// handles (5), Z (30/31/32/33/38), XDATA (1001+), and unrecognized group
/// codes on otherwise-typed entities (routed to `residualPairs` instead of
/// silently dropped). See DXFParser.swift's `scan(data:progress:)` for the
/// byte-scanning loop this intentionally duplicates — kept algorithmically
/// identical (same section/table/record state machine, same byte-level
/// code/value tokenizer) so its ~3s/731MB performance is unaffected; only
/// what happens when a finished record's pairs are interpreted differs.
enum EntityStoreParser {

    static func parse(url: URL, progress: ((Double) -> Void)? = nil) throws -> EditableParsedDocument {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        if data.prefix(18).elementsEqual("AutoCAD Binary DXF".utf8) {
            throw NSError(domain: "DXFParser", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Binary DXF is not supported yet. Re-save as ASCII DXF (or open the DWG directly)."])
        }
        return try scanIntoStore(data: data) { p in progress?(p) }
    }

    // MARK: - Pair (identical shape to DXFParser.Pair)

    private struct Pair {
        var code: Int32
        var num: Double
        var str: String?
    }

    /// Scans a raw pair list for one specific XDATA app-id's string value —
    /// used by the INSERT case to read back a display-name override (see
    /// `BlockEditor.displayNameXDataAppId`'s doc comment) at the moment its
    /// `InsertPayload` is constructed, rather than after `commonProps`'s own
    /// (more general, multi-app-id) XDATA capture runs. Returns the FIRST
    /// group-1000 string immediately following a matching group-1001 marker;
    /// `nil` if that app-id's group isn't present at all.
    private static func scanXDataString(_ pairs: [Pair], appId: String) -> String? {
        var inTargetGroup = false
        for p in pairs {
            switch p.code {
            case 1001:
                inTargetGroup = (p.str == appId)
            case 1000:
                if inTargetGroup { return p.str ?? "" }
            default:
                break
            }
        }
        return nil
    }

    // MARK: - Precomputed residual-code recognition sets (perf)
    //
    // `commonProps` needs, for every entity, the set of group codes this
    // entity type recognizes (so anything else becomes a retained residual
    // pair). Building that Set from an array literal + `.union(_:)` on every
    // single one of 3.4M entities measurably shows up in profiles (Set
    // allocation + hashing per call) — these are computed exactly ONCE
    // (Swift `static let`s are lazily initialized on first access and then
    // cached) and referenced by name at each `finish(...)` call site below
    // instead of rebuilding a literal every time.
    private static let alwaysCommonCodes: Set<Int32> = [8, 62, 420, 6, 67, 60, 230, 5, 100, 210, 220,
                                                        330, 340, 360, 390, 1000, 1001, 1002, 1005,
                                                        1040, 1041, 1042, 1070, 1071, 370]
    private static let lineCodes = alwaysCommonCodes.union([10, 20, 30, 11, 21, 31])
    private static let circleCodes = alwaysCommonCodes.union([10, 20, 30, 40])
    private static let arcCodes = alwaysCommonCodes.union([10, 20, 30, 40, 50, 51])
    private static let lwpolylineCodes = alwaysCommonCodes.union([70, 10, 20, 42, 38, 90, 43])
    private static let splineCodes = alwaysCommonCodes.union([70, 71, 40, 41, 10, 20, 30, 11, 21, 31, 12, 22, 32, 13, 23, 33, 72, 73, 74])
    private static let ellipseCodes = alwaysCommonCodes.union([10, 20, 30, 11, 21, 31, 40, 41, 42])
    private static let solidCodes = alwaysCommonCodes.union([10, 20, 30, 11, 21, 31, 12, 22, 32, 13, 23, 33])
    private static let face3dCodes = alwaysCommonCodes.union([10, 20, 30, 11, 21, 31, 12, 22, 32, 13, 23, 33, 70])
    private static let pointCodes = alwaysCommonCodes.union([10, 20, 30])
    // Codes 2 (ATTRIB/ATTDEF tag), 3 (multi-line ATTRIB value continuation),
    // and 70 (ATTRIB flags: invisible/constant/…) are recognized so they're
    // consumed as real fields rather than becoming residual pairs — see the
    // TEXT/ATTRIB parse case, which reads the tag from 2, concatenates 3, and
    // tests 70's invisible bit.
    private static let textCodes = alwaysCommonCodes.union([10, 20, 30, 11, 21, 31, 40, 41, 50, 72, 73, 74, 1, 2, 3, 70])
    private static let mtextCodes = alwaysCommonCodes.union([10, 20, 30, 11, 21, 31, 40, 41, 50, 71, 1, 3])
    private static let insertCodes = alwaysCommonCodes.union([2, 10, 20, 30, 41, 42, 43, 50, 70, 71, 44, 45])
    private static let dimensionCodes = alwaysCommonCodes.union([2, 10, 20, 30])
    private static let acadTableCodes = alwaysCommonCodes.union([2, 10, 20, 30])
    private static let leaderCodes = alwaysCommonCodes.union([10, 20, 30])
    private static let hatchCodes = alwaysCommonCodes.union([10, 20, 30, 210, 220, 230, 2, 70, 71, 91, 92, 93, 97, 98,
                                                             72, 73, 74, 75, 76, 40, 41, 42, 50, 51, 52, 11, 21, 31, 12, 22, 32])

    // MARK: - Generic group-code value classification (HEADER/CLASSES/TABLES/OBJECTS)
    //
    // Unlike `isStringCode` above (which only needs to distinguish "string
    // vs number" for the small set of codes an ENTITY record's typed fields
    // actually read), the structural-metadata capture below stores EVERY
    // code's value in a `RawGroupValue`, so it needs the full three-way
    // split (string / double / int) plus a fourth "handle" case for
    // pointer-shaped codes — per the DXF group-code range convention (the
    // same ranges used by every DXF-emitting/consuming tool): 0-9 string
    // EXCEPT 5 (this record's own handle), 10-59 double, 60-99 int16/int32,
    // 100/102 string, 105 handle-string, 110-149 double, 160-169 int64,
    // 170-179 int16, 210-239 double, 270-289 int16, 290-299 bool-as-int16,
    // 300-309 string, 310-319 binary-chunk-as-string, 320-329/330-369/
    // 390-399 handle-string, 370-389 int16, 400-409 int16, 410-419 string,
    // 420-429 int32, 430-439 string, 440-449 int32, 450-459 int64, 460-469
    // double, 470-481 string, 999 comment-string, 1000-1009 string (XDATA),
    // 1010-1059 double, 1060-1070 int16, 1071 int32.
    private enum GroupValueKind { case string, double_, int_, handle }

    @inline(__always)
    private static func groupValueKind(_ c: Int32) -> GroupValueKind {
        switch c {
        case 5: return .handle   // carve-out within the 0-9 "string" range — this record's own handle
        case 0...9: return .string
        case 10...59: return .double_
        case 60...99: return .int_
        case 100, 102: return .string
        case 105: return .handle
        case 110...149: return .double_
        case 160...169: return .int_
        case 170...179: return .int_
        case 210...239: return .double_
        case 270...289: return .int_
        case 290...299: return .int_
        case 300...309: return .string
        case 310...319: return .string
        case 320...329: return .handle
        case 330...369: return .handle
        case 370...389: return .int_
        case 390...399: return .handle
        case 400...409: return .int_
        case 410...419: return .string
        case 420...429: return .int_
        case 430...439: return .string
        case 440...449: return .int_
        case 450...459: return .int_
        case 460...469: return .double_
        case 470...481: return .string
        case 999: return .string
        case 1000...1009: return .string
        case 1010...1059: return .double_
        case 1060...1070: return .int_
        case 1071: return .int_
        default: return .string   // unknown/reserved code — safest fallback, never mis-truncates a value
        }
    }

    @inline(__always)
    private static func isStringCode(_ c: Int32) -> Bool {
        switch c {
        // 5 (this entity's handle) and 330/340/360/390 (owner/pointer
        // handles) are hex strings, not numbers — DXFParser never reads
        // these codes at all (no handle retention in the old path) so it
        // never needed them here; the new path's handle retention does, and
        // parsing "2A1" as a Double via strtod would silently truncate to
        // 2.0 instead of preserving the hex string.
        //
        // 1000 (arbitrary XDATA string), 1001 (XDATA appid name), and 1005
        // (XDATA handle reference) are also strings per the DXF spec — 1002/
        // 1003/1004 aren't currently read (no control-string/layer-name/
        // binary-chunk XDATA retention yet) so they're deliberately left off
        // this list; if a future phase reads them via `p.str` they'll need
        // adding here too, same as this bug's fix for 5/1000/1001/1005.
        case 1, 2, 3, 6, 7, 8, 9, 5, 102, 330, 340, 360, 390, 410, 1000, 1001, 1005: return true
        default: return false
        }
    }

    // MARK: - Scanner (byte loop copied verbatim from DXFParser.scan)

    private static func scanIntoStore(data: Data, progress: (Double) -> Void) throws -> EditableParsedDocument {
        let out = EditableParsedDocument()
        let store = out.store

        // Layer 0 always exists and is index 0.
        out.layers.append(DXFLayer(id: 0, name: "0"))
        out.layerIdByName["0"] = 0
        out.linetypes.append(DXFLinetype(name: "CONTINUOUS", dashes: []))
        out.linetypeIdByName["CONTINUOUS"] = 0
        out.linetypeIdByName["BYLAYER"] = -1
        out.linetypeIdByName["BYBLOCK"] = -2

        enum Section { case none, header, tables, blocks, entities, classes, objects, other }

        var section = Section.none
        var expectSectionName = false
        var currentTable = ""
        var expectTableName = false
        var headerVar = ""

        // MARK: HEADER $VAR capture (Phase 3 groundwork)
        //
        // Every `$VARNAME` (code 9) starts a new var; every subsequent pair
        // until the next code-9 line or ENDSEC belongs to it. Flushed into
        // `out.headerVars` in file order — this is a SEPARATE accumulator
        // from `pairs` (which is reset per code-0 record and used for
        // TABLES/BLOCKS/ENTITIES), because HEADER vars are delimited by
        // code 9, not code 0.
        var headerVarPairs: [RawGroupPair] = []
        func flushHeaderVar() {
            guard !headerVar.isEmpty else { return }
            out.headerVars.append(HeaderVar(name: headerVar, pairs: headerVarPairs))
            headerVarPairs = []
        }

        var inBlockDef: EditableBlockDef? = nil
        var inBlockStartSlot: Int32 = 0
        var nextBlockIndex: Int32 = 0
        /// The most recently emitted INSERT's id, live only for the
        /// immediately-following run of ATTRIB records up to their closing
        /// SEQEND — mirrors real AutoCAD's own INSERT-with-attributes file
        /// shape (`INSERT`, then N `ATTRIB`s, then one `SEQEND`, all as
        /// consecutive records with no other entity in between). Lets the
        /// `"ATTRIB"` case below assign `owner: .parentEntity(insertId)`
        /// instead of the generic `.model`/`.paper`/`.block(n)` every other
        /// entity type gets — WITHOUT this, `BlockEditor.attributes(of:in:)`/
        /// `EntityStore.children(of:)` (both keyed on `owner.parentEntityID`)
        /// silently return EMPTY for every INSERT parsed from a real file,
        /// even though its ATTRIB tag/value pairs are sitting right there in
        /// the store as ordinary top-level entities — the root cause of a
        /// real bug this comment documents (Data Extraction's `attr:<TAG>`
        /// columns coming back blank for parsed-from-file block attributes,
        /// e.g. a "Contents" attribute). Cleared (`nil`) by ANY other
        /// record — `SEQEND` (the normal, well-formed end of the run), or
        /// any entity/BLOCK/ENDBLK/table record that isn't ATTRIB (a
        /// defensive guard against a malformed file where ATTRIBs don't
        /// actually follow their INSERT contiguously; in that case they fall
        /// back to the old generic-owner behavior rather than mis-attaching
        /// to a stale, no-longer-adjacent INSERT).
        var lastInsertId: EntityID? = nil
        /// Owner to use for an entity given this record's paper-space flag
        /// (group 67) — inside a BLOCK/ENDBLK pair, `isPaper` is irrelevant
        /// (block content is never itself "paper space"; only its eventual
        /// INSERT placement is), matching `GeometryBuilder.emit`'s
        /// `if inBlockDef { block } else if isPaper { paper } else { model }`
        /// priority exactly.
        func ownerFor(isPaper: Bool) -> OwnerRef {
            if let b = inBlockDef { return .block(b.blockIndex) }
            return isPaper ? .paper : .model
        }

        var recType = ""
        var pairs: [Pair] = []
        pairs.reserveCapacity(64)

        // MARK: CLASSES/TABLES(new types)/OBJECTS full-fidelity pair capture
        //
        // `pairs`/`isStringCode` above are entity-record-oriented: they only
        // classify the small set of codes ENTITIES/LAYER/LTYPE records
        // actually read as strings, so e.g. STYLE's code-4 (big-font
        // filename) would silently parse as 0.0 through that path. Records
        // in CLASSES, the NEW table types (VPORT/STYLE/VIEW/UCS/APPID/
        // DIMSTYLE/BLOCK_RECORD), and OBJECTS need every code captured with
        // full string/double/int/handle fidelity instead — `structPairs`
        // does that, using the same `groupValueKind` classifier as HEADER.
        // Gated to only the sections/tables that need it so the hot
        // ENTITIES/LAYER/LTYPE path pays zero extra cost per line.
        // No `reserveCapacity` here (unlike `pairs` above) — see
        // `finishRecord`'s doc comment on why `structPairs` is reset to a
        // fresh empty array (not `removeAll(keepingCapacity:)`) after every
        // record: a pre-reserved capacity would just be the first thing
        // discarded by that reset anyway, so reserving it up front buys
        // nothing.
        var structPairs: [RawGroupPair] = []

        // Per-TABLE-block accumulator for the new symbol-table types: all of
        // one TABLE's member records are contiguous in the file, so batching
        // them into a local array and writing to `out.symbolTables` ONCE per
        // table (at ENDTAB) avoids a dictionary hash+lookup on every single
        // record — measurable on files with pathologically large tables
        // (one real 731MB reference file carries >60K APPID records).
        var pendingSymbolTableType = ""
        var pendingSymbolRecords: [SymbolRecord] = []
        func flushSymbolTable() {
            guard !pendingSymbolTableType.isEmpty, !pendingSymbolRecords.isEmpty else { return }
            out.symbolTables[pendingSymbolTableType, default: []].append(contentsOf: pendingSymbolRecords)
            pendingSymbolRecords.removeAll(keepingCapacity: true)
        }
        @inline(__always) func wantsStructCapture() -> Bool {
            switch section {
            case .classes, .objects: return true
            case .tables: return currentTable != "LAYER" && currentTable != "LTYPE"
            default: return false
            }
        }

        // Legacy POLYLINE assembly
        struct PendingHeaderCommon {
            var layerId: Int32 = 0
            var aci: Int16 = 256
            var trueColor: UInt32 = 0xFF00_0000
            var linetypeId: Int16 = -1
            /// DXF group 370 — per-entity lineweight override, in 1/100 mm;
            /// -1 BYLAYER (the default — the overwhelming common case, no
            /// group 370 present at all), -2 BYBLOCK, -3 "default". See
            /// `EntityHeader.lineweight`'s own doc comment for the same
            /// encoding. Previously this group code was silently swallowed
            /// (never read anywhere in `commonProps`), so every parsed
            /// entity's stored lineweight was BYLAYER regardless of what a
            /// source file actually specified — round-tripped fine (a
            /// never-set field just never got written back either) but made
            /// an explicit per-object lineweight from an imported file
            /// invisible to both Properties-panel display and the renderer.
            var lineweight: Int16 = -1
            var mirrorOCS = false
            var handle: UInt64 = 0
            var layoutOwnerHandle: UInt64?
        }
        struct PendingPolyline {
            var flags = 0
            var mVerts = 0, nVerts = 0
            var verts: [PolyVertex] = []
            var vertZ: [Double] = []
            var vertFlags: [Int] = []
            var faces: [[Int]] = []
            var common = PendingHeaderCommon()
            var isPaper = false
            var inBlock = false
            var ownerBlockIndex: Int32 = -1
            var elevation: Double = 0
        }
        var pendingPoly: PendingPolyline? = nil

        var ltName = ""
        var ltDashes: [Double] = []
        var ltHandle: UInt64 = 0

        var layName = ""
        var layColor = 7
        var layTrue: UInt32? = nil
        var layFlags = 0
        var layLtype = "CONTINUOUS"
        var layHandle: UInt64 = 0
        // DXF group 440 on a LAYER record: `0x02000000 | alpha` where
        // `alpha` is 0 (100% transparent) ... 255 (opaque) — see
        // `DXFLayer.transparency`'s own doc comment for the full
        // encode/decode contract this mirrors (kept identical to
        // `DXFTablesEmitter`'s writer so a round trip is lossless up to
        // integer-percent rounding). `nil` means the group was absent
        // (the overwhelming common case: most DXFs have no transparency
        // set), leaving `DXFLayer.transparency` at its 0 (opaque) default.
        var layTransparency: Int? = nil
        var inLayerRecord = false
        var inLtypeRecord = false

        func internLayer(_ name: String) -> Int32 {
            if let id = out.layerIdByName[name] { return id }
            let id = Int32(out.layers.count)
            out.layers.append(DXFLayer(id: Int(id), name: name))
            out.layerIdByName[name] = id
            return id
        }

        func flushLayerRecord() {
            guard inLayerRecord else { return }
            inLayerRecord = false
            let id = internLayer(layName)
            var layer = out.layers[Int(id)]
            let aci = abs(layColor)
            layer.color = (aci == 7 || aci == 0) ? .foreground
                : .rgb(layTrue ?? ACIPalette.rgb(forACI: aci))
            if let t = layTrue { layer.color = .rgb(t) }
            layer.isOffByDefault = layColor < 0
            layer.isFrozen = (layFlags & 1) != 0
            layer.linetypeId = Int(out.linetypeIdByName[layLtype.uppercased()] ?? 0)
            // Group 440's high byte (0x02) marks it as a transparency value
            // (as opposed to some other 440 use); only the low byte is the
            // actual alpha. `0xFF` (opaque) decodes to 0% transparency —
            // deliberately NOT stored as "no override," since a real 0xFF
            // group 440 is an explicit (if redundant) opaque setting, not an
            // absent one; `layTransparency == nil` (the group wasn't present
            // at all) is the only case left at the 0 default via no write.
            if let raw = layTransparency {
                let alphaByte = raw & 0xFF
                layer.transparency = (255 - Double(alphaByte)) / 255 * 100
            }
            // Phase 3 groundwork: preserve the LAYER record's original
            // handle so a future writer can re-emit pointer graphs that
            // reference it — additive only (defaults to 0 if unset/no
            // group-5 present, e.g. layer "0" synthesized before any real
            // record is seen).
            if layHandle != 0 { layer.handle = layHandle }
            out.layers[Int(id)] = layer
        }

        func flushLtypeRecord() {
            guard inLtypeRecord else { return }
            inLtypeRecord = false
            let upper = ltName.uppercased()
            guard out.linetypeIdByName[upper] == nil else { return }
            let id = Int16(out.linetypes.count)
            var dashes: [CGFloat] = []
            if !ltDashes.isEmpty, ltDashes.contains(where: { $0 != 0 }) {
                var items = ltDashes
                if items.first ?? 0 < 0 { items.append(items.removeFirst()) }
                let total = items.reduce(0) { $0 + abs($1) }
                let dot = max(total * 0.04, 1e-6)
                for v in items { dashes.append(CGFloat(v == 0 ? dot : abs(v))) }
                if dashes.count % 2 == 1 { dashes.append(dashes.last ?? 0) }
            }
            out.linetypes.append(DXFLinetype(name: ltName, dashes: dashes, handle: ltHandle))
            out.linetypeIdByName[upper] = id
        }

        // MARK: per-record finalization -> EntityStore

        /// Parses common group codes (8/62/420/6/67/60/230/5/330) plus
        /// collects residual (unrecognized) codes and XDATA, mirroring
        /// `DXFParser.commonProps` but writing directly into an
        /// `EntityHeader`-shaped bag, retained fields included.
        func commonProps(_ pairs: [Pair], recognizedCodes: Set<Int32>)
            -> (common: PendingHeaderCommon, isPaper: Bool, invisible: Bool,
                xdata: [XDataBlob], residual: [(code: Int16, value: String)]) {
            var e = PendingHeaderCommon()
            var isPaper = false
            var invisible = false
            var xdataBlobs: [XDataBlob] = []
            var currentXDataAppId: String? = nil
            var currentXDataPairs: [(code: Int16, value: XDataValue)] = []
            var residual: [(code: Int16, value: String)] = []
            var controlDepth = 0

            func flushXData() {
                guard let appId = currentXDataAppId else { return }
                xdataBlobs.append(XDataBlob(appId: appId, pairs: currentXDataPairs))
                currentXDataAppId = nil
                currentXDataPairs = []
            }

            for p in pairs {
                switch p.code {
                case 102:
                    if p.str?.hasPrefix("{") == true { controlDepth += 1 }
                    else if p.str == "}" { controlDepth = max(0, controlDepth - 1) }
                case 330:
                    if controlDepth == 0, e.layoutOwnerHandle == nil, let value = p.str {
                        e.layoutOwnerHandle = UInt64(value, radix: 16)
                    }
                case 8:   e.layerId = internLayer(p.str ?? "0")
                case 62:  e.aci = Int16(clamping: safeInt(p.num))
                case 420: e.trueColor = UInt32(truncatingIfNeeded: safeInt(p.num)) & 0x00FF_FFFF
                case 6:
                    let name = (p.str ?? "").uppercased()
                    e.linetypeId = out.linetypeIdByName[name] ?? -1
                case 370: e.lineweight = Int16(clamping: safeInt(p.num))
                case 67:  isPaper = p.num == 1
                case 60:  invisible = p.num == 1
                case 230: if p.num < 0 { e.mirrorOCS = true }
                case 5:
                    if let s = p.str, let v = UInt64(s, radix: 16) { e.handle = v }
                case 1001:
                    flushXData()
                    currentXDataAppId = p.str ?? ""
                case 1000:
                    if currentXDataAppId != nil { currentXDataPairs.append((1000, .string(p.str ?? ""))) }
                case 1040, 1041, 1042:
                    if currentXDataAppId != nil { currentXDataPairs.append((Int16(p.code), .double(p.num))) }
                case 1070, 1071:
                    if currentXDataAppId != nil { currentXDataPairs.append((Int16(p.code), .int(Int32(safeInt(p.num))))) }
                case 1005:
                    if currentXDataAppId != nil, let s = p.str, let v = UInt64(s, radix: 16) {
                        currentXDataPairs.append((1005, .handle(v)))
                    }
                default:
                    // Anything not in the recognized set for this entity type,
                    // and not one of the always-common codes above, is a
                    // residual pair retained verbatim (unless it's XDATA,
                    // already handled, or a 330/340/360/390 owner/pointer we
                    // don't yet interpret but still want to keep).
                    if !recognizedCodes.contains(p.code), p.code < 1000 {
                        let text = p.str ?? String(p.num)
                        residual.append((Int16(clamping: p.code), text))
                    }
                }
            }
            flushXData()
            if e.aci < 0 { e.aci = Int16(clamping: abs(Int(e.aci))) }
            return (e, isPaper, invisible, xdataBlobs, residual)
        }

        /// Appends one entity to the store — `proto.owner` must already be
        /// set correctly by the caller (via `ownerFor(isPaper:)`) — and
        /// records its XDATA/residual pairs if any.
        @discardableResult
        func emit(_ proto: EntityPrototype, common: PendingHeaderCommon,
                 xdata: [XDataBlob], residual: [(code: Int16, value: String)]) -> EntityID {
            var residual = residual
            if proto.owner.isPaper, let owner = common.layoutOwnerHandle {
                residual.append((330, String(owner, radix: 16, uppercase: true)))
            }
            let id = store.append(proto)
            if common.handle != 0 {
                store.setHeader(id) { $0.handle = common.handle }
            }
            if !xdata.isEmpty {
                store.xdata[id.raw] = xdata.count == 1 ? xdata[0]
                    : XDataBlob(appId: xdata.map(\.appId).joined(separator: ","),
                               pairs: xdata.flatMap(\.pairs))
                store.setHeader(id) { $0.flags.insert(.hasXData) }
            }
            if !residual.isEmpty {
                store.residualPairs[id.raw] = RawPairBlob(pairs: residual)
                store.setHeader(id) { $0.flags.insert(.hasResidual) }
            }
            return id
        }

        /// Builds a `SymbolRecord` from a finished non-LAYER/LTYPE TABLES
        /// record's `structPairs` — handle (5), owner (330), name (2), flags
        /// (70) lifted into named fields; everything else (INCLUDING 2/5/
        /// 330/70 again, for full echo) retained verbatim in `rawPairs`. Adds
        /// the plan's handful of typed lifts (STYLE font/big-font, DIMSTYLE's
        /// override bag, BLOCK_RECORD's layout handle) where cheap to do.
        func makeSymbolRecord(tableType: String, pairs: [RawGroupPair]) -> SymbolRecord {
            var name = "", flags = 0
            var handle: UInt64 = 0, ownerHandle: UInt64 = 0
            for p in pairs {
                switch (p.code, p.value) {
                case (2, .string(let s)): name = s
                // DIMSTYLE table records are the one DXF oddity that uses
                // group 105 (not 5) for their own handle — verified against
                // a real AutoCAD-written file's DIMSTYLE table ("105\n3301"
                // pattern) — every other table type here uses plain 5.
                case (5, .handle(let h, _)), (105, .handle(let h, _)): handle = h
                case (330, .handle(let h, _)): ownerHandle = h
                case (70, .int(let i)): flags = Int(i)
                default: break
                }
            }
            var typed: TypedTableLift? = nil
            switch tableType {
            case "STYLE":
                var font = "", bigFont = ""
                for p in pairs {
                    if p.code == 3, case .string(let s) = p.value { font = s }
                    if p.code == 4, case .string(let s) = p.value { bigFont = s }
                }
                typed = .style(fontFile: font, bigFontFile: bigFont)
            case "DIMSTYLE":
                // The override bag deliberately EXCLUDES the already-lifted
                // 2/5/105/330/70 (still present in `rawPairs` for full echo,
                // but not duplicated into `.dimstyle`'s convenience payload).
                let overrides = pairs.filter { ![2, 5, 105, 330, 70].contains($0.code) }
                typed = .dimstyle(overrides: overrides)
            case "BLOCK_RECORD":
                var layoutHandle: UInt64? = nil
                for p in pairs {
                    if p.code == 340, case .handle(let h, _) = p.value { layoutHandle = h }
                }
                typed = .blockRecord(layoutHandle: layoutHandle)
            default:
                break
            }
            return SymbolRecord(tableType: tableType, name: name, handle: handle,
                                ownerHandle: ownerHandle, flags: flags, rawPairs: pairs, typed: typed)
        }

        /// Common handle/owner-handle extraction shared by every OBJECTS
        /// record type below. Group 5 (handle) is safe to scan across the
        /// whole record. Group 330, however, is NOT: the DXF spec only
        /// guarantees "330 = soft-pointer to owner object" for the code
        /// appearing in an object's COMMON property section, i.e. before its
        /// first subclass marker (group 100) — a real AutoCAD LAYOUT object
        /// reuses 330 a SECOND time inside its `AcDbLayout` subclass to mean
        /// "associated block-record handle", a completely different pointer
        /// (verified against this project's own 731MB reference file's
        /// LAYOUT objects, which carry both). Stopping the owner-scan at the
        /// first 100 avoids picking up that unrelated later 330 by accident.
        func handleAndOwner(_ pairs: [RawGroupPair]) -> (handle: UInt64, owner: UInt64) {
            var handle: UInt64 = 0, owner: UInt64 = 0
            for p in pairs {
                if p.code == 100 { break }
                if p.code == 5, case .handle(let h, _) = p.value { handle = h }
                if p.code == 330, case .handle(let h, _) = p.value { owner = h }
            }
            // Handle (group 5) can legally appear even if somehow positioned
            // oddly; re-scan the full record for it in the rare case the
            // 100-gated loop above missed it (defensive — real files always
            // put 5 before 100, but this keeps handle capture robust even if
            // one doesn't).
            if handle == 0 {
                for p in pairs where p.code == 5 {
                    if case .handle(let h, _) = p.value { handle = h; break }
                }
            }
            return (handle, owner)
        }

        // OBJECTS records are stored in `[UInt64: T]` dictionaries keyed by
        // handle — but handle 0 means "absent/unparseable" (see
        // `handleAndOwner`), so two handle-less records of the SAME type
        // would otherwise collide at key 0 and silently lose all but the
        // last one, violating the "nothing from OBJECTS is silently
        // dropped" guarantee. Allocate a synthetic key from the top of the
        // UInt64 range (descending) for these — real DXF handles grow
        // upward from a small $HANDSEED and never come remotely close to
        // this range even in enormous files, so collision with a genuine
        // handle is not a practical concern. The record's OWN `handle`
        // field still faithfully reports 0 ("none in the source file");
        // only the dictionary KEY is synthesized.
        var nextSyntheticObjectHandle: UInt64 = .max
        func storageKey(for handle: UInt64) -> UInt64 {
            guard handle == 0 else { return handle }
            defer { nextSyntheticObjectHandle -= 1 }
            return nextSyntheticObjectHandle
        }

        /// Dispatches one finished OBJECTS-section record into `out.objects`.
        /// Every object type lands SOMEWHERE (typed bucket or `rawObjects`
        /// fallback) — see `ObjectsModel`'s doc comment: breadth over depth,
        /// nothing from OBJECTS is silently dropped even where no typed
        /// accessor exists yet.
        func appendObjectRecord(type: String, pairs: [RawGroupPair]) {
            guard !pairs.isEmpty || !type.isEmpty else { return }
            let (handle, owner) = handleAndOwner(pairs)

            switch type {
            case "DICTIONARY":
                var hardOwner: Int? = nil
                var entries: [DictionaryEntry] = []
                var pendingKey: String? = nil
                for p in pairs {
                    switch (p.code, p.value) {
                    case (281, .int(let i)): hardOwner = Int(i)
                    case (3, .string(let s)): pendingKey = s
                    case (350, .handle(let h, _)), (360, .handle(let h, _)):
                        if let key = pendingKey {
                            entries.append(DictionaryEntry(key: key, valueHandle: h))
                            pendingKey = nil
                        }
                    default: break
                    }
                }
                let dict = DictionaryObject(handle: handle, ownerHandle: owner,
                                            hardOwnerFlag: hardOwner, entries: entries, rawPairs: pairs)
                // Resolve the storage key ONCE and reuse it for
                // `rootDictionaryHandle` below — calling `storageKey(for:)`
                // twice would consume two different synthetic keys for the
                // SAME handle-less record, leaving `rootDictionaryHandle`
                // pointing at a key that was never actually stored in
                // `dictionaries` (a real bug caught while writing this
                // fix's own regression test).
                let dictKey = storageKey(for: handle)
                out.objects.dictionaries[dictKey] = dict
                // The very first DICTIONARY object in OBJECTS (file order) is
                // always the Named Object Dictionary root in a well-formed
                // DXF (it's the object HEADER's $DICTIONARY / handle-0
                // owner's dictionary points at, and nothing else in the file
                // owns it) — recognized here as "owner handle 0", which no
                // other object in a valid DXF ever has as ITS OWN owner
                // except the root. Uses `dictKey` (the STORAGE key), not the
                // raw `handle`, so lookups via `dictionaries[rootDictionaryHandle]`
                // resolve correctly even when the root dictionary itself was
                // handle-less and got a synthesized key.
                if out.objects.rootDictionaryHandle == nil && owner == 0 {
                    out.objects.rootDictionaryHandle = dictKey
                }

            case "LAYOUT":
                var name = "", tabOrder: Int? = nil
                var blockRecordHandle: UInt64? = nil
                for p in pairs {
                    switch (p.code, p.value) {
                    case (1, .string(let s)): name = s
                    case (71, .int(let i)): tabOrder = Int(i)
                    case (330, .handle(let h, _)): blockRecordHandle = h
                    default: break
                    }
                }
                out.objects.layouts[storageKey(for: handle)] = LayoutObject(
                    handle: handle, ownerHandle: owner, name: name,
                    blockRecordHandle: blockRecordHandle,
                    // DXF's LAYOUT object doubles as its own plot-settings
                    // record (AcDbPlotSettings + AcDbLayout subclasses on the
                    // SAME object) rather than pointing at a separate one —
                    // there is no distinct handle to capture here; `rawPairs`
                    // carries the full plot-settings group codes verbatim for
                    // whenever a later phase parses them.
                    plotSettingsHandle: nil,
                    tabOrder: tabOrder, rawPairs: pairs)

            case "GROUP":
                var desc = "", selectable = false
                var members: [UInt64] = []
                for p in pairs {
                    switch (p.code, p.value) {
                    case (300, .string(let s)): desc = s
                    case (70, .int(let i)): selectable = i != 0   // group 70 = "group selectability flag" per DXF spec
                    case (340, .handle(let h, _)): members.append(h)
                    default: break
                    }
                }
                out.objects.groups[storageKey(for: handle)] = GroupObject(
                    handle: handle, ownerHandle: owner, description: desc,
                    isSelectable: selectable, memberHandles: members, rawPairs: pairs)

            case "IMAGEDEF":
                var fileName = ""
                var w: Double? = nil, h: Double? = nil
                for p in pairs {
                    switch (p.code, p.value) {
                    case (1, .string(let s)): fileName = s
                    case (10, .double(let d)): w = d
                    case (20, .double(let d)): h = d
                    default: break
                    }
                }
                let size: ImageSizePx? = (w != nil && h != nil) ? ImageSizePx(w: w!, h: h!) : nil
                out.objects.imageDefs[storageKey(for: handle)] = ImageDefObject(
                    handle: handle, ownerHandle: owner, fileName: fileName,
                    imageSizePx: size, rawPairs: pairs)

            default:
                // Fallback: every OBJECTS record type without a typed lift
                // above still round-trips as a RawObject — handle, owner,
                // and every group code verbatim. This is the "nothing from
                // OBJECTS is silently dropped" guarantee.
                out.objects.rawObjects[storageKey(for: handle)] = RawObject(
                    objectType: type, handle: handle, ownerHandle: owner, rawPairs: pairs)
            }
        }

        func finishRecord() {
            guard !recType.isEmpty else { return }
            // `lastInsertId` only stays live across a contiguous run of
            // ATTRIB records right after their INSERT — any OTHER record
            // type (including this INSERT's own eventual SEQEND, or a
            // malformed file where something else appears before it) ends
            // that run. Cleared unconditionally up front, then re-armed by
            // the "INSERT" case below when THIS record is itself an INSERT
            // — so an INSERT immediately following another INSERT's
            // (SEQEND-less, i.e. attribute-less) run correctly starts a NEW
            // run rather than inheriting the previous one.
            if recType != "ATTRIB" { lastInsertId = nil }
            // `structPairs.removeAll(keepingCapacity: true)` — DELIBERATELY NOT
            // used here, unlike `pairs` above. `structPairs` is finalized
            // directly into a long-lived struct's stored property
            // (`SymbolRecord.rawPairs`, `RawObject.rawPairs`, etc.) via
            // straight assignment, which shares the SAME backing buffer
            // (Swift array COW) rather than copying. If ANY one record in a
            // CLASSES/TABLES/OBJECTS section is large (this project's own
            // 731MB reference file has a single SORTENTSTABLE object with
            // ~570,000 pairs), `structPairs`'s capacity grows to fit it —
            // and `keepingCapacity: true` would make EVERY SUBSEQUENT
            // record's stored `rawPairs`, no matter how tiny, permanently
            // carry that same oversized capacity (measured: this exact bug
            // inflated the reference file's peak RSS from ~1.2GB to
            // ~4.6GB — a single shared accumulator array whose capacity
            // never shrinks, "leaking" through every struct it gets copied
            // into). Resetting to a fresh, empty array (capacity 0) instead
            // means each record's stored copy is right-sized to its own
            // content — `pairs` doesn't have this problem because its
            // consumers (POLYLINE/LAYER/LTYPE/entity `makeAndEmit`) only
            // ever read scalar fields out of it, never store the array
            // itself into a long-lived struct.
            defer { pairs.removeAll(keepingCapacity: true); structPairs = []; recType = "" }

            // Table records
            if section == .tables {
                switch recType {
                case "LAYER":
                    flushLayerRecord(); flushLtypeRecord()
                    guard currentTable == "LAYER" else { return }
                    inLayerRecord = true
                    layName = ""; layColor = 7; layTrue = nil; layFlags = 0; layLtype = "CONTINUOUS"; layHandle = 0
                    layTransparency = nil
                    for p in pairs {
                        switch p.code {
                        case 2: layName = p.str ?? ""
                        case 62: layColor = safeInt(p.num)
                        case 420: layTrue = UInt32(truncatingIfNeeded: safeInt(p.num)) & 0x00FF_FFFF
                        case 440: layTransparency = safeInt(p.num)
                        case 70: layFlags = safeInt(p.num)
                        case 6: layLtype = p.str ?? "CONTINUOUS"
                        case 5: if let s = p.str, let v = UInt64(s, radix: 16) { layHandle = v }
                        default: break
                        }
                    }
                    flushLayerRecord()
                case "LTYPE":
                    flushLtypeRecord(); flushLayerRecord()
                    guard currentTable == "LTYPE" else { return }
                    ltName = ""; ltDashes = []; ltHandle = 0
                    for p in pairs {
                        switch p.code {
                        case 2: ltName = p.str ?? ""
                        case 49: ltDashes.append(p.num)
                        case 5: if let s = p.str, let v = UInt64(s, radix: 16) { ltHandle = v }
                        default: break
                        }
                    }
                    inLtypeRecord = true
                    flushLtypeRecord()
                case "VPORT", "STYLE", "VIEW", "UCS", "APPID", "DIMSTYLE", "BLOCK_RECORD":
                    // The record type name always matches its owning TABLE's
                    // name for these (unlike LAYER/LTYPE above, which guard
                    // against a stray same-named record type showing up
                    // outside its table — these never collide with anything
                    // else, so no analogous `currentTable ==` guard is needed).
                    if pendingSymbolTableType != recType { flushSymbolTable(); pendingSymbolTableType = recType }
                    pendingSymbolRecords.append(makeSymbolRecord(tableType: recType, pairs: structPairs))
                default:
                    break
                }
                return
            }

            if section == .classes {
                // A well-formed DXF's CLASSES section holds only CLASS
                // records, but this capture is meant to lose nothing even on
                // a malformed/nonstandard file — unlike a silent `return`,
                // route anything unexpected into `skippedTypes` (the same
                // fallback-accounting mechanism ENTITIES already uses for
                // unrecognized types) so it's at least visible in
                // `--db-stats`/`stats.skippedTypes`, even though there's no
                // dedicated raw bucket for it (CLASSES has no OBJECTS-style
                // typed/raw split to fall back into).
                guard recType == "CLASS" else {
                    out.skippedTypes["CLASSES:\(recType)", default: 0] += 1
                    return
                }
                out.classes.append(RawClass(recordType: recType, pairs: structPairs))
                return
            }

            if section == .objects {
                appendObjectRecord(type: recType, pairs: structPairs)
                return
            }

            guard section == .blocks || section == .entities else { return }

            switch recType {
            case "BLOCK":
                let b = EditableBlockDef()
                for p in pairs {
                    switch p.code {
                    case 2: if b.name.isEmpty { b.name = p.str ?? "" }
                    case 10: b.base.x = p.num
                    case 20: b.base.y = p.num
                    case 70: b.flags = safeInt(p.num)
                    case 1: b.xrefPath = p.str ?? ""
                    case 3: if b.name.isEmpty { b.name = p.str ?? "" }
                    case 5: if let s = p.str, let v = UInt64(s, radix: 16) { b.handle = v }
                    case 330: if let s = p.str, let v = UInt64(s, radix: 16) { b.blockRecordHandle = v }
                    default: break
                    }
                }
                b.blockIndex = nextBlockIndex
                nextBlockIndex += 1
                inBlockDef = b
                inBlockStartSlot = Int32(store.count)
                return
            case "ENDBLK":
                if let b = inBlockDef, !b.name.isEmpty {
                    b.entityStart = inBlockStartSlot
                    b.entityCount = Int32(store.count) - inBlockStartSlot
                    out.blocks[b.name] = b
                }
                inBlockDef = nil
                return
            default:
                break
            }

            // ---- POLYLINE / VERTEX / SEQEND ----
            if recType == "POLYLINE" {
                var pp = PendingPolyline()
                let (common, isPaper, invisible, _, _) = commonProps(pairs, recognizedCodes: Self.alwaysCommonCodes)
                pp.common = common
                pp.isPaper = isPaper
                pp.inBlock = inBlockDef != nil
                pp.ownerBlockIndex = inBlockDef?.blockIndex ?? -1
                if invisible { return }
                for p in pairs {
                    switch p.code {
                    case 70: pp.flags = safeInt(p.num)
                    case 71: pp.mVerts = safeInt(p.num)
                    case 72: pp.nVerts = safeInt(p.num)
                    case 38: pp.elevation = p.num
                    default: break
                    }
                }
                pendingPoly = pp
                return
            }
            if recType == "VERTEX" {
                guard pendingPoly != nil else { return }
                var x = 0.0, y = 0.0, z = 0.0, bulge = 0.0, flags = 0
                var face = [0, 0, 0, 0]
                for p in pairs {
                    switch p.code {
                    case 10: x = p.num
                    case 20: y = p.num
                    case 30: z = p.num
                    case 42: bulge = p.num
                    case 70: flags = safeInt(p.num)
                    case 71: face[0] = safeInt(p.num)
                    case 72: face[1] = safeInt(p.num)
                    case 73: face[2] = safeInt(p.num)
                    case 74: face[3] = safeInt(p.num)
                    default: break
                    }
                }
                if (flags & 128) != 0 && (flags & 64) == 0 {
                    pendingPoly?.faces.append(face)
                } else {
                    pendingPoly?.verts.append(PolyVertex(x: x, y: y, bulge: bulge))
                    pendingPoly?.vertZ.append(z)
                    pendingPoly?.vertFlags.append(flags)
                }
                return
            }
            if recType == "SEQEND" {
                guard let pp = pendingPoly else { return }
                pendingPoly = nil
                var common = pp.common
                if (pp.flags & 8) != 0 { common.mirrorOCS = false }
                let closed = (pp.flags & 1) != 0
                // POLYLINE's owner is fixed at the moment it opened (matches
                // the old parser: `pp.inBlock`/`pp.isPaper` were captured when
                // the POLYLINE record itself was seen, not at SEQEND time).
                let polyOwner = pp.inBlock ? OwnerRef.block(pp.ownerBlockIndex) : (pp.isPaper ? .paper : .model)

                func emitPoly(_ verts: [PolyVertex], _ zs: [Double], closed: Bool) {
                    guard verts.count > 1 else { return }
                    let vec3s = zip(verts, zs).map { Vec3(x: $0.0.x, y: $0.0.y, z: $0.1) }
                    let bulges = verts.map { $0.bulge }
                    let proto = EntityPrototype(
                        type: .lwpolyline, layerId: common.layerId, aci: common.aci,
                        trueColor: common.trueColor, linetypeId: common.linetypeId,
                        lineweight: common.lineweight,
                        owner: polyOwner,
                        payload: .polyline(PolylinePayload(closed: closed, elevation: pp.elevation, is3D: (pp.flags & 8) != 0),
                                          vertices: vec3s, bulges: bulges))
                    _ = emit(proto, common: common, xdata: [], residual: [])
                }

                if (pp.flags & 64) != 0 {
                    let pool = pp.verts
                    let poolZ = pp.vertZ
                    for face in pp.faces {
                        let idx = face.filter { $0 != 0 }
                        guard idx.count >= 2 else { continue }
                        for k in 0..<idx.count {
                            let a = idx[k], b = idx[(k + 1) % idx.count]
                            guard a > 0 else { continue }
                            let ia = abs(a) - 1, ib = abs(b) - 1
                            guard ia < pool.count, ib < pool.count else { continue }
                            emitPoly([pool[ia], pool[ib]], [poolZ[ia], poolZ[ib]], closed: false)
                        }
                    }
                } else if (pp.flags & 16) != 0, pp.mVerts > 1, pp.nVerts > 1,
                          pp.verts.count >= pp.mVerts * pp.nVerts {
                    let m = pp.mVerts, n = pp.nVerts
                    for i in 0..<m {
                        emitPoly(Array(pp.verts[(i * n)..<(i * n + n)]),
                                Array(pp.vertZ[(i * n)..<(i * n + n)]),
                                closed: (pp.flags & 32) != 0)
                    }
                    for j in 0..<n {
                        var col: [PolyVertex] = []
                        var colZ: [Double] = []
                        for i in 0..<m { col.append(pp.verts[i * n + j]); colZ.append(pp.vertZ[i * n + j]) }
                        emitPoly(col, colZ, closed: (pp.flags & 1) != 0)
                    }
                } else {
                    var verts: [PolyVertex] = []
                    var zs: [Double] = []
                    var hasNonFrame = false
                    for f in pp.vertFlags where (f & 16) == 0 { hasNonFrame = true; break }
                    for (i, v) in pp.verts.enumerated() {
                        if hasNonFrame && (pp.vertFlags[i] & 16) != 0 { continue }
                        verts.append(v)
                        zs.append(pp.vertZ[i])
                    }
                    emitPoly(verts, zs, closed: closed)
                }
                return
            }
            // ---- end POLYLINE family ----

            makeAndEmit(type: recType, pairs: pairs, blockIndex: inBlockDef?.blockIndex ?? -1)
        }

        /// Dispatches one finished non-POLYLINE-family record: parses its
        /// geometry (same field set as `DXFParser.makeGeoms`, plus Z/handle/
        /// XDATA/residual retention) and appends it to the store.
        func makeAndEmit(type: String, pairs: [Pair], blockIndex: Int32) {
            func d(_ code: Int32) -> Double? {
                for p in pairs where p.code == code { return p.num }
                return nil
            }
            func s(_ code: Int32) -> String? {
                for p in pairs where p.code == code { return p.str }
                return nil
            }

            // `recognized` here is always one of the `EntityStoreParser.*Codes`
            // static sets declared above — already merged with
            // `alwaysCommonCodes` once at first access, not per call.
            /// - Parameter keepIfInvisible: when `true`, an entity flagged
            ///   invisible (entity-level group 60=1) is STILL emitted, just
            ///   marked `EntityFlags.invisible` (so the renderer skips it —
            ///   see `Regenerator.emitPrimitive`) rather than dropped
            ///   outright. Used for ATTRIB: an invisible attribute still
            ///   carries data (material codes, carrier ids, BOM values on
            ///   factory layouts) that Data Extraction / `BlockEditor
            ///   .attributes(of:)` must be able to read, even though it
            ///   isn't drawn. Everything else keeps the historical
            ///   drop-invisible behavior.
            @discardableResult
            func finish(_ type: DXFEntityType, _ payload: EntityPayloadCopy,
                       recognized: Set<Int32>, mirrorForced: Bool? = nil,
                       ownerOverride: OwnerRef? = nil, keepIfInvisible: Bool = false) -> EntityID? {
                var (common, isPaper, invisible, xdata, residual) =
                    commonProps(pairs, recognizedCodes: recognized)
                guard !invisible || keepIfInvisible else { return nil }
                if let forced = mirrorForced { common.mirrorOCS = forced }
                let owner: OwnerRef = ownerOverride ?? (blockIndex >= 0 ? .block(blockIndex) : (isPaper ? .paper : .model))
                let proto = EntityPrototype(type: type, layerId: common.layerId, aci: common.aci,
                                            trueColor: common.trueColor, linetypeId: common.linetypeId,
                                            lineweight: common.lineweight,
                                            owner: owner, payload: payload)
                let id = emit(proto, common: common, xdata: xdata, residual: residual)
                if common.mirrorOCS {
                    store.setHeader(id) { $0.flags.insert(.mirrorOCS) }
                }
                if invisible {
                    store.setHeader(id) { $0.flags.insert(.invisible) }
                }
                return id
            }

            switch type {
            case "LINE":
                guard let x1 = d(10), let y1 = d(20), let x2 = d(11), let y2 = d(21) else { return }
                let z1 = d(30) ?? 0, z2 = d(31) ?? 0
                finish(.line, .line(LinePayload(a: Vec3(x: x1, y: y1, z: z1), b: Vec3(x: x2, y: y2, z: z2))),
                      recognized: Self.lineCodes, mirrorForced: false)

            case "CIRCLE":
                guard let cx = d(10), let cy = d(20), let r = d(40), r > 0 else { return }
                let cz = d(30) ?? 0
                finish(.circle, .circle(CirclePayload(center: Vec3(x: cx, y: cy, z: cz), radius: r)),
                      recognized: Self.circleCodes)

            case "ARC":
                guard let cx = d(10), let cy = d(20), let r = d(40), r > 0,
                      let a1 = d(50), let a2 = d(51) else { return }
                let cz = d(30) ?? 0
                finish(.arc, .arc(ArcPayload(center: Vec3(x: cx, y: cy, z: cz), radius: r,
                                            startAngleDeg: a1, endAngleDeg: a2)),
                      recognized: Self.arcCodes)

            case "LWPOLYLINE":
                var verts: [Vec3] = []
                var bulges: [Double] = []
                var closed = false
                var pendingX: Double? = nil
                var elevation = 0.0
                // DXF group 43 — LWPOLYLINE's "constant width" (AutoCAD's
                // Global Width property). `lwpolylineCodes` already listed
                // 43 as a recognized code (so it never became a residual
                // pair), but nothing here actually read it — the value was
                // silently discarded and `PolylinePayload.constantWidth`
                // always parsed as 0 regardless of file content.
                var constantWidth = 0.0
                for p in pairs {
                    switch p.code {
                    case 70: closed = (safeInt(p.num) & 1) != 0
                    case 10: pendingX = p.num
                    case 20:
                        if let x = pendingX { verts.append(Vec3(x: x, y: p.num)); bulges.append(0); pendingX = nil }
                    case 42:
                        if !bulges.isEmpty { bulges[bulges.count - 1] = p.num }
                    case 38: elevation = p.num
                    case 43: constantWidth = p.num
                    default: break
                    }
                }
                guard verts.count > 1 else { return }
                finish(.lwpolyline, .polyline(PolylinePayload(closed: closed, constantWidth: constantWidth,
                                                              elevation: elevation, is3D: false),
                                              vertices: verts, bulges: bulges),
                      recognized: Self.lwpolylineCodes)

            case "SPLINE":
                // Flushes control points on code 20 (matching DXFParser
                // exactly), then patches Z from an immediately following 30
                // if present — waiting for 30 to flush silently drops every
                // control point but the last whenever 30 isn't emitted right
                // after its own 10/20 pair (same bug class fixed for LEADER
                // above; SPLINE needs the identical fix).
                var knots: [Double] = []
                var weights: [Double] = []
                var ctrl: [Vec3] = []
                var degree = 3
                var flags = 0
                var cx: Double? = nil
                for p in pairs {
                    switch p.code {
                    case 70: flags = safeInt(p.num)
                    case 71: degree = safeInt(p.num)
                    case 40: knots.append(p.num)
                    case 41: weights.append(p.num)
                    case 10: cx = p.num
                    case 20: if let x = cx { ctrl.append(Vec3(x: x, y: p.num)); cx = nil }
                    case 30: if !ctrl.isEmpty { ctrl[ctrl.count - 1].z = p.num }
                    default: break
                    }
                }
                guard ctrl.count >= 2 else { return }
                let closed = (flags & 1) != 0
                finish(.spline, .spline(SplinePayload(degree: Int32(degree), closed: closed),
                                        control: ctrl, knots: knots, weights: weights),
                      recognized: Self.splineCodes,
                      mirrorForced: false)

            case "ELLIPSE":
                guard let cx = d(10), let cy = d(20),
                      let mx = d(11), let my = d(21), let ratio = d(40) else { return }
                let cz = d(30) ?? 0, mz = d(31) ?? 0
                let start = d(41) ?? 0
                let end = d(42) ?? (2 * .pi)
                finish(.ellipse, .ellipse(EllipsePayload(center: Vec3(x: cx, y: cy, z: cz),
                                                         majorAxisEndpoint: Vec3(x: mx, y: my, z: mz),
                                                         ratio: ratio, startParam: start, endParam: end)),
                      recognized: Self.ellipseCodes, mirrorForced: false)

            case "SOLID", "TRACE":
                var pts: [Vec3] = []
                for (xc, yc, zc) in [(Int32(10), Int32(20), Int32(30)), (11, 21, 31), (12, 22, 32), (13, 23, 33)] {
                    if let x = d(xc), let y = d(yc) { pts.append(Vec3(x: x, y: y, z: d(zc) ?? 0)) }
                }
                guard pts.count >= 3 else { return }
                if pts.count == 4 { pts.swapAt(2, 3) }
                if pts.count == 4 && pts[2] == pts[3] { pts.removeLast() }
                let bulges = [Double](repeating: 0, count: pts.count)
                finish(.solid, .polyline(PolylinePayload(closed: true), vertices: pts, bulges: bulges),
                      recognized: Self.solidCodes)

            case "3DFACE":
                var pts: [Vec3] = []
                for (xc, yc, zc) in [(Int32(10), Int32(20), Int32(30)), (11, 21, 31), (12, 22, 32), (13, 23, 33)] {
                    if let x = d(xc), let y = d(yc) { pts.append(Vec3(x: x, y: y, z: d(zc) ?? 0)) }
                }
                if pts.count == 4 && pts[2] == pts[3] { pts.removeLast() }
                guard pts.count >= 3 else { return }
                let invisible = safeInt(d(70) ?? 0)
                let recognized = Self.face3dCodes
                if invisible == 0 {
                    let bulges = [Double](repeating: 0, count: pts.count)
                    finish(.face3d, .polyline(PolylinePayload(closed: true), vertices: pts, bulges: bulges),
                          recognized: recognized, mirrorForced: false)
                } else {
                    // Edges with per-edge invisibility: emit visible edges as
                    // separate 2-vertex open-polyline entities (matches old
                    // parser's per-edge granularity for hit-testing/
                    // selection). Stored as `.polyline` shape, NOT `.line`,
                    // so `Regenerator`'s `.solid, .face3d` case (which always
                    // reads `store.polylines[pIdx]`) finds the right array —
                    // `type: .face3d` must always pair with a polyline-shaped
                    // payload, never a `.line` one.
                    var (common, isPaper, inv, xdata, residual) = commonProps(pairs, recognizedCodes: recognized)
                    guard !inv else { return }
                    common.mirrorOCS = false   // 3DFACE coords are WCS, same rule as the solid-face branch
                    let owner: OwnerRef = blockIndex >= 0 ? .block(blockIndex) : (isPaper ? .paper : .model)
                    for k in 0..<pts.count {
                        guard invisible & (1 << k) == 0 else { continue }
                        let p1 = pts[k], p2 = pts[(k + 1) % pts.count]
                        let proto = EntityPrototype(type: .face3d, layerId: common.layerId, aci: common.aci,
                                                    trueColor: common.trueColor, linetypeId: common.linetypeId,
                                                    lineweight: common.lineweight,
                                                    owner: owner,
                                                    payload: .polyline(PolylinePayload(closed: false),
                                                                       vertices: [p1, p2], bulges: [0, 0]))
                        _ = emit(proto, common: common, xdata: k == 0 ? xdata : [], residual: k == 0 ? residual : [])
                    }
                }

            case "POINT":
                guard let x = d(10), let y = d(20) else { return }
                let z = d(30) ?? 0
                finish(.point, .point(PointPayload(p: Vec3(x: x, y: y, z: z))), recognized: Self.pointCodes)

            case "TEXT", "ATTRIB":
                let isAttrib = (type == "ATTRIB")
                // group-70 bit 1 = invisible. HISTORICALLY this dropped the
                // ATTRIB entirely — but an invisible attribute still carries
                // extractable data (material/carrier/BOM codes on factory
                // layouts, which are routinely stored invisible), so instead
                // mark it invisible (via `keepIfInvisible` on `finish`, plus
                // the flag set below) and let the renderer skip drawing it
                // while Data Extraction / `BlockEditor.attributes(of:)` can
                // still read it. TEXT keeps the old drop behavior (an
                // invisible plain TEXT carries no separate data worth
                // retaining).
                let attribInvisibleFlag = isAttrib && ((d(70).map { Int($0) & 1 } ?? 0) != 0)
                if !isAttrib, let f = d(70), (Int(f) & 1) != 0 { return }
                guard let x = d(10), let y = d(20) else { return }
                let z = d(30) ?? 0
                let height = d(40) ?? 2.5
                guard height > 0 else { return }
                // VALUE (group 1). For an ATTRIB, also honor group-3
                // continuation chunks that a multi-line (AcDbMText-embedded)
                // ATTRIB emits — mirroring the MTEXT case below. Without
                // this, a multi-line attribute's value is truncated to its
                // final group-1 chunk, losing earlier lines.
                var rawValue = ""
                if isAttrib { for p in pairs where p.code == 3 { rawValue += p.str ?? "" } }
                rawValue += s(1) ?? ""
                let text = MTextParser.plainSingleLineText(from: rawValue)
                // An ATTRIB with an empty VALUE is still meaningful (its TAG
                // identifies a data field that's simply blank in this
                // instance — a user may fill it in, or Data Extraction may
                // report the blank), so ATTRIBs are NOT dropped for an empty
                // value the way plain TEXT is.
                guard isAttrib || !text.isEmpty else { return }
                let rot = d(50) ?? 0
                let widthFactor = min(max(d(41) ?? 1, 0.1), 10)
                let h = safeInt(d(72) ?? 0)
                let hAlign = [0: 0, 1: 1, 2: 2, 3: 1, 4: 1, 5: 1][h] ?? 0
                var vAlign = min(max(safeInt(d(isAttrib ? 74 : 73) ?? 0), 0), 3)
                if h == 4 { vAlign = 2 }
                let sid = store.strings.intern(text)
                // alignPosition defaults to `position` (not (0,0)) when code
                // 11/21 is absent, so "anchor = alignPosition when hAlign/
                // vAlign non-default" (Regenerator) is exactly equivalent to
                // the old parser's `tr.p2 ?? tr.p1` fallback.
                var alignPos = Vec3(x: x, y: y, z: z)
                if let x2 = d(11), let y2 = d(21) {
                    alignPos = Vec3(x: x2, y: y2, z: d(31) ?? 0)
                }
                var payload = TextPayload(position: Vec3(x: x, y: y, z: z), alignPosition: alignPos, height: height,
                                          rotationDeg: rot, widthFactor: widthFactor, stringId: sid,
                                          hAlign: Int16(hAlign), vAlign: Int16(vAlign))
                // TAG (group 2) — the attribute's identifier, kept separate
                // from its VALUE. HISTORICALLY never read by the parser, so
                // every parsed-from-file ATTRIB left `tagStringId = -1` and
                // `BlockEditor.attributes(of:)`/`setAttribute` fell back to
                // deriving the "tag" from the VALUE text — meaning Data
                // Extraction's `attr:<TAG>` columns were mislabeled and
                // re-import edits keyed on the real tag never matched. Now
                // populated so the real tag round-trips.
                if isAttrib, let tag = s(2), !tag.isEmpty {
                    payload.tagStringId = store.strings.intern(tag)
                }
                // An ATTRIB immediately following an INSERT (before that
                // INSERT's closing SEQEND) is that INSERT's attribute — give
                // it `.parentEntity(insertId)` so `BlockEditor.attributes(of:)`/
                // `EntityStore.children(of:)` (both keyed on
                // `owner.parentEntityID`) can find it, matching the owner
                // `BlockEditor.insert(...)` already assigns for
                // interactively-created attributes. See `lastInsertId`'s own
                // doc comment for the bug this fixes.
                let attribOwner: OwnerRef? = isAttrib ? lastInsertId.map(OwnerRef.parentEntity) : nil
                let newId = finish(isAttrib ? .attrib : .text, .text(payload),
                                   recognized: Self.textCodes, ownerOverride: attribOwner,
                                   keepIfInvisible: isAttrib)
                if attribInvisibleFlag, let newId {
                    store.setHeader(newId) { $0.flags.insert(.invisible) }
                }

            case "MTEXT":
                guard let x = d(10), let y = d(20) else { return }
                let z = d(30) ?? 0
                var rawStr = ""
                for p in pairs where p.code == 3 { rawStr += p.str ?? "" }
                rawStr += s(1) ?? ""
                let height = d(40) ?? 2.5
                let plain = MTextParser.plainText(from: rawStr)
                guard !plain.isEmpty, height > 0 else { return }
                var rot = d(50) ?? 0
                if let dx = d(11), let dy = d(21), dx != 0 || dy != 0 {
                    rot = atan2(dy, dx) * 180 / .pi
                }
                let attach = safeInt(d(71) ?? 1)
                let sid = store.strings.intern(plain)
                let payload = MTextPayload(insertion: Vec3(x: x, y: y, z: z), height: height,
                                          refWidth: d(41) ?? 0, rotationDeg: rot,
                                          attachPoint: Int16(attach), stringId: sid)
                finish(.mtext, .mtext(payload), recognized: Self.mtextCodes,
                      mirrorForced: false)

            case "INSERT":
                guard let name = s(2), !name.isEmpty, let x = d(10), let y = d(20) else { return }
                let z = d(30) ?? 0
                let nameId = store.strings.intern(name)
                let sx = d(41) ?? 1, sy = d(42) ?? (d(41) ?? 1)
                var payload = InsertPayload(blockNameId: nameId, position: Vec3(x: x, y: y, z: z),
                                           scale: Vec3(x: sx, y: sy, z: d(43) ?? sy),
                                           rotationDeg: d(50) ?? 0,
                                           cols: Int32(max(1, safeInt(d(70) ?? 1))),
                                           rows: Int32(max(1, safeInt(d(71) ?? 1))),
                                           colSpacing: d(44) ?? 0, rowSpacing: d(45) ?? 0)
                // A per-instance DISPLAY NAME override (`InsertPayload
                // .displayNameId`, e.g. from a prior Data Import) round-trips
                // through this INSERT's own XDATA — see
                // `BlockEditor.displayNameXDataAppId`'s doc comment for the
                // exact wire format. Scanning `pairs` here directly (rather
                // than waiting for `commonProps`'s own XDATA capture inside
                // `finish`, below) because `payload` must already carry the
                // resolved string id at the moment it's constructed — this
                // repeats the same 1001/1000 scan `commonProps` does, scoped
                // to just this one app-id, so the two can't disagree about
                // which pairs belong to it.
                if let overrideName = Self.scanXDataString(pairs, appId: BlockEditor.displayNameXDataAppId),
                   !overrideName.isEmpty {
                    payload.displayNameId = store.strings.intern(overrideName)
                }
                // Track this INSERT's id so any ATTRIB records immediately
                // following (before this INSERT's own SEQEND) attach to it —
                // see `lastInsertId`'s own doc comment.
                lastInsertId = finish(.insert, .insert(payload), recognized: Self.insertCodes)

            case "DIMENSION":
                guard let name = s(2), !name.isEmpty else { return }
                let nameId = store.strings.intern(name)
                let x = d(10) ?? 0, y = d(20) ?? 0, z = d(30) ?? 0
                finish(.dimension, .dimension(DimensionPayload(blockNameId: nameId, defPoint: Vec3(x: x, y: y, z: z))),
                      recognized: Self.dimensionCodes)

            case "ACAD_TABLE":
                guard let name = s(2), !name.isEmpty, let x = d(10), let y = d(20) else { return }
                let z = d(30) ?? 0
                let nameId = store.strings.intern(name)
                let payload = InsertPayload(blockNameId: nameId, position: Vec3(x: x, y: y, z: z))
                finish(.insert, .insert(payload), recognized: Self.acadTableCodes)

            case "LEADER":
                // Flushes on code 20 (matching DXFParser exactly — it never
                // waits for code 30), then patches in Z from an immediately
                // following 30 if present. Waiting for 30 to flush (as an
                // earlier version of this code did) silently drops every
                // vertex but the last whenever a LEADER's writer doesn't put
                // 30 right after every 10/20 pair — seen in the wild on this
                // exact file's dimension leaders.
                var verts: [Vec3] = []
                var px: Double? = nil
                for p in pairs {
                    if p.code == 10 { px = p.num }
                    else if p.code == 20, let x = px { verts.append(Vec3(x: x, y: p.num)); px = nil }
                    else if p.code == 30, !verts.isEmpty { verts[verts.count - 1].z = p.num }
                }
                guard verts.count > 1 else { return }
                let bulges = [Double](repeating: 0, count: verts.count)
                finish(.leader, .polyline(PolylinePayload(closed: false), vertices: verts, bulges: bulges),
                      recognized: Self.leaderCodes, mirrorForced: false)

            case "HATCH":
                guard let (isSolid, loops) = makeHatchLoops(pairs: pairs) else { return }
                let originX = d(10) ?? 0, originY = d(20) ?? 0
                var payload = HatchPayload(isSolid: isSolid, origin: Vec3(x: originX, y: originY))
                // Group 2 (pattern name, non-solid only), 52 (pattern
                // angle), 41 (pattern scale/spacing) — previously never
                // read, so every parsed non-solid HATCH's `angle`/`scale`
                // silently reset to their struct defaults (0/1) regardless
                // of what the source file actually specified, and its
                // pattern name was lost entirely (round-tripped as whatever
                // `EntityRecordWriter.writeHatch` falls back to for an
                // unset `patternNameId`, "ANSI31", rather than the file's
                // real pattern). Group 2's FIRST occurrence is the pattern
                // name (a HATCH record has no other string-valued code this
                // early, so the plain first-match is unambiguous).
                if !isSolid, let name = s(2), !name.isEmpty {
                    payload.patternNameId = store.strings.intern(name)
                }
                if let angle = d(52) { payload.angle = angle }
                if let scale = d(41) { payload.scale = scale }
                // Group 440 on the ENTITY itself (distinct from the SAME
                // group code on its LAYER table entry, which
                // EntityStoreParser's LAYER-record handling reads
                // separately into `DXFLayer.transparency`) —
                // `HatchPayload.transparency`'s own doc comment covers why
                // this is scoped to HATCH rather than every entity type.
                // Format identical to the layer case: `0x02000000 | alpha`,
                // alpha 0...255 (0=100% transparent, 255=opaque); the
                // special "by block" sentinel 0x01000000 has no low byte to
                // decode meaningfully, so it's treated the same as absent
                // (0% own transparency) rather than mis-decoded.
                if let rawD = d(440) {
                    let raw = Int32(rawD)
                    if (raw & 0x0300_0000) == 0x0200_0000 {
                        let alphaByte = raw & 0xFF
                        payload.transparency = (255 - Double(alphaByte)) / 255 * 100
                    }
                }
                finish(.hatch, .hatch(payload, loops: loops),
                      recognized: Self.hatchCodes.union([440]))

            // Entities with nothing useful to draw in a 2D viewer — the
            // same discard category as DXFParser.makeGeoms (unchanged, out
            // of scope for this phase's retention work). Any type not named
            // here still falls through to the counted `default` path below
            // rather than being drawn.
            case "ATTDEF", "VIEWPORT", "MLEADER", "MULTILEADER",
                 "ACAD_PROXY_ENTITY", "OLEFRAME", "OLE2FRAME", "IMAGE",
                 "BODY", "REGION", "3DSOLID", "SURFACE", "MESH", "TOLERANCE",
                 "WIPEOUT", "XLINE", "RAY", "SHAPE", "LIGHT":
                return

            default:
                out.skippedTypes[type, default: 0] += 1
                return
            }
        }

        // MARK: byte loop (identical algorithm to DXFParser.scan)

        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            let bytes = buf.bindMemory(to: UInt8.self)
            let n = bytes.count
            var i = (n >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) ? 3 : 0
            var lineNo = 0
            var code: Int32 = 0
            var reportedProgress = 0

            @inline(__always) func parseCode(_ s: Int, _ e: Int) -> Int32? {
                var j = s
                while j < e && (bytes[j] == 0x20 || bytes[j] == 0x09) { j += 1 }
                var end = e
                while end > j && (bytes[end - 1] == 0x20 || bytes[end - 1] == 0x09) { end -= 1 }
                guard j < end else { return nil }
                var neg = false
                if bytes[j] == 0x2D { neg = true; j += 1 }
                else if bytes[j] == 0x2B { j += 1 }
                var v: Int32 = 0
                while j < end {
                    let d = bytes[j]
                    guard d >= 0x30 && d <= 0x39 else { return nil }
                    v = v * 10 + Int32(d - 0x30)
                    if v > 1100 { return nil }
                    j += 1
                }
                return neg ? -v : v
            }

            var numBuf = [CChar](repeating: 0, count: 64)
            func parseNum(_ s: Int, _ e: Int) -> Double {
                var j = s
                while j < e && (bytes[j] == 0x20 || bytes[j] == 0x09) { j += 1 }
                guard j < e else { return 0 }
                let len = min(e - j, 63)
                return numBuf.withUnsafeMutableBufferPointer { tmp -> Double in
                    for k in 0..<len { tmp[k] = CChar(bitPattern: bytes[j + k]) }
                    tmp[len] = 0
                    return strtod(tmp.baseAddress, nil)
                }
            }

            @inline(__always) func makeString(_ s: Int, _ e: Int) -> String {
                var end = e
                var st = s
                while st < end && bytes[st] == 0x20 { st += 1 }
                while end > st && bytes[end - 1] == 0x20 { end -= 1 }
                guard st < end else { return "" }
                return String(decoding: UnsafeRawBufferPointer(rebasing: buf[st..<end]),
                              as: UTF8.self)
            }

            // DXF is a stream of (code line, value line) pairs. HISTORICALLY
            // this loop keyed "am I on a code or a value line?" off global
            // line-number parity (`lineNo & 1`). That silently breaks on a
            // real-world defect some converters (notably GNU LibreDWG)
            // produce: a string value (e.g. an MTEXT/group-1 blob) that
            // contains a LITERAL embedded newline, so one logical value spans
            // TWO physical lines. Under pure parity, the value's second
            // physical line is then mistaken for the next CODE line, and
            // every code/value pair for the ENTIRE REST OF THE FILE is read
            // one line out of phase — which, on a plant layout, meant the
            // whole ENTITIES section (hundreds of INSERT workstations and
            // thousands of ATTRIB data values, appearing ~900k lines after
            // the offending blob) was silently dropped.
            //
            // `expectingCode` replaces parity with an explicit, SELF-
            // RESYNCHRONIZING toggle: when a code is expected but the line
            // doesn't parse as a valid DXF group code (0…1100 integer — see
            // `parseCode`), it must be the trailing remainder of the previous
            // multi-physical-line value, so we skip it and KEEP expecting a
            // code, snapping pairing back into phase instead of staying
            // desynced forever. For a well-formed file (no embedded-newline
            // values) this behaves identically to the old parity logic.
            var expectingCode = true
            while i < n {
                var e = i
                while e < n && bytes[e] != 0x0A { e += 1 }
                var lineEnd = e
                if lineEnd > i && bytes[lineEnd - 1] == 0x0D { lineEnd -= 1 }

                if expectingCode {
                    if let c = parseCode(i, lineEnd) {
                        code = c
                        expectingCode = false
                    } else {
                        // Continuation of a previous value that contained an
                        // embedded newline — absorb this physical line and
                        // stay in "expecting code" so we don't desync.
                        code = -9999
                    }
                    lineNo += 1
                    i = e + 1
                    if i - reportedProgress > 16_000_000 {
                        reportedProgress = i
                        progress(Double(i) / Double(n))
                    }
                    continue
                }

                // Value line for the code we just read.
                expectingCode = true
                if code != -9999 {
                    if code == 0 || code == 9 {
                        finishRecord()
                        let v = makeString(i, lineEnd).uppercased()
                        if code == 9 {
                            flushHeaderVar()
                            headerVar = v
                        } else {
                            switch v {
                            case "SECTION": expectSectionName = true
                            case "ENDSEC":
                                finishRecord(); flushLayerRecord(); flushLtypeRecord()
                                flushHeaderVar(); headerVar = ""
                                flushSymbolTable(); pendingSymbolTableType = ""
                                section = .none; currentTable = ""
                            case "TABLE": expectTableName = true
                            case "ENDTAB":
                                flushLayerRecord(); flushLtypeRecord()
                                flushSymbolTable(); pendingSymbolTableType = ""
                                currentTable = ""
                            case "EOF": break
                            default:
                                recType = v
                            }
                        }
                    } else if expectSectionName && code == 2 {
                        expectSectionName = false
                        switch makeString(i, lineEnd).uppercased() {
                        case "HEADER": section = .header
                        case "TABLES": section = .tables
                        case "BLOCKS": section = .blocks
                        case "ENTITIES": section = .entities
                        case "CLASSES": section = .classes
                        case "OBJECTS": section = .objects
                        default: section = .other
                        }
                    } else if expectTableName && code == 2 {
                        expectTableName = false
                        currentTable = makeString(i, lineEnd).uppercased()
                    } else if section == .header {
                        if headerVar == "$LTSCALE" && code == 40 {
                            let v = parseNum(i, lineEnd)
                            if v > 0 { out.ltScale = v }
                        } else if headerVar == "$INSUNITS" && code == 70 {
                            out.insUnits = safeInt(parseNum(i, lineEnd))
                        }
                        // Full verbatim capture alongside the two existing
                        // fast-path reads above (kept as-is, unchanged, for
                        // zero behavioral risk to `ltScale`/`insUnits`) —
                        // every code belonging to the CURRENT `$VAR` is
                        // appended to `headerVarPairs`, flushed by
                        // `flushHeaderVar()` on the next code-9/ENDSEC line.
                        switch groupValueKind(code) {
                        case .string:
                            headerVarPairs.append(RawGroupPair(code: code, value: .string(makeString(i, lineEnd))))
                        case .double_:
                            headerVarPairs.append(RawGroupPair(code: code, value: .double(parseNum(i, lineEnd))))
                        case .int_:
                            headerVarPairs.append(RawGroupPair(code: code, value: .int(safeInt64(parseNum(i, lineEnd)))))
                        case .handle:
                            let hex = makeString(i, lineEnd)
                            headerVarPairs.append(RawGroupPair(code: code, value: .handle(UInt64(hex, radix: 16) ?? 0, hex: hex)))
                        }
                    } else if !recType.isEmpty {
                        if wantsStructCapture() {
                            switch groupValueKind(code) {
                            case .string:
                                structPairs.append(RawGroupPair(code: code, value: .string(makeString(i, lineEnd))))
                            case .double_:
                                structPairs.append(RawGroupPair(code: code, value: .double(parseNum(i, lineEnd))))
                            case .int_:
                                structPairs.append(RawGroupPair(code: code, value: .int(safeInt64(parseNum(i, lineEnd)))))
                            case .handle:
                                let hex = makeString(i, lineEnd)
                                structPairs.append(RawGroupPair(code: code, value: .handle(UInt64(hex, radix: 16) ?? 0, hex: hex)))
                            }
                        } else if isStringCode(code) {
                            pairs.append(Pair(code: code, num: 0, str: makeString(i, lineEnd)))
                        } else {
                            pairs.append(Pair(code: code, num: parseNum(i, lineEnd), str: nil))
                        }
                    }
                }

                lineNo += 1
                i = e + 1

                if i - reportedProgress > 16_000_000 {
                    reportedProgress = i
                    progress(Double(i) / Double(n))
                }
            }
        }

        finishRecord()
        flushLayerRecord()
        flushLtypeRecord()
        flushHeaderVar()     // defensive: a malformed file missing HEADER's ENDSEC would otherwise drop the last $VAR
        flushSymbolTable()   // defensive: same, for a TABLES block missing its ENDTAB

        // Phase 3 groundwork: cross-reference each block's BLOCK_RECORD
        // table entry by name, now that both TABLES (which comes first in
        // file order) and BLOCKS are fully parsed. O(blocks + BLOCK_RECORD
        // count) — a name-keyed dictionary built once, not a nested scan —
        // negligible next to this file's other costs even with a real
        // file's ~3000 BLOCK_RECORD entries.
        if let blockRecords = out.symbolTables["BLOCK_RECORD"], !blockRecords.isEmpty {
            var byName: [String: UInt64] = [:]
            byName.reserveCapacity(blockRecords.count)
            for r in blockRecords where !r.name.isEmpty { byName[r.name.uppercased()] = r.handle }
            for (name, block) in out.blocks {
                block.blockRecordHandle = byName[name.uppercased()]
            }
        }

        progress(1.0)
        return out
    }

    // MARK: - HATCH (loop extraction only; same tessellation as DXFParser.makeHatch)

    private static func makeHatchLoops(pairs: [Pair]) -> (isSolid: Bool, loops: [[Vec3]])? {
        var solid = false
        var loops: [[Vec3]] = []
        var i = 0
        let n = pairs.count

        func num(_ idx: Int) -> Double { pairs[idx].num }

        var pathCount = 0
        var scan = 0
        while scan < n {
            if pairs[scan].code == 70 { solid = safeInt(num(scan)) & 1 == 1 }
            if pairs[scan].code == 91 { pathCount = safeInt(num(scan)); scan += 1; break }
            scan += 1
        }
        guard pathCount > 0 else { return nil }
        i = scan

        func tessArc(c: CGPoint, r: Double, a1Deg: Double, a2Deg: Double, ccw: Bool,
                     into pts: inout [CGPoint]) {
            var a1 = a1Deg * .pi / 180, a2 = a2Deg * .pi / 180
            if !ccw { swap(&a1, &a2) }
            var sweep = a2 - a1
            if sweep <= 0 { sweep += 2 * .pi }
            let steps = max(4, min(64, safeInt(sweep / 0.12)))
            for k in 0...steps {
                let a = a1 + sweep * Double(k) / Double(steps)
                pts.append(CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a)))
            }
            if !ccw { pts.replaceSubrange((pts.count - steps - 1)..<pts.count,
                                          with: pts.suffix(steps + 1).reversed()) }
        }

        var pathsDone = 0
        while pathsDone < pathCount && i < n {
            while i < n && pairs[i].code != 92 { i += 1 }
            guard i < n else { break }
            let flags = safeInt(num(i)); i += 1
            var loop: [CGPoint] = []

            if flags & 2 != 0 {
                var count = 0
                while i < n {
                    let c = pairs[i].code
                    if c == 93 { count = safeInt(num(i)); i += 1; break }
                    if c == 92 || c == 97 || c == 98 { break }
                    i += 1
                }
                var verts: [PolyVertex] = []
                var got = 0
                var pendingX: Double? = nil
                while i < n && got < count {
                    let c = pairs[i].code
                    if c == 10 { pendingX = num(i) }
                    else if c == 20, let x = pendingX {
                        verts.append(PolyVertex(x: x, y: num(i))); pendingX = nil; got += 1
                    }
                    else if c == 42, !verts.isEmpty { verts[verts.count - 1].bulge = num(i) }
                    else if c == 92 || c == 97 || c == 98 { break }
                    i += 1
                }
                for (k, v) in verts.enumerated() {
                    loop.append(CGPoint(x: v.x, y: v.y))
                    if v.bulge != 0 {
                        let next = verts[(k + 1) % verts.count]
                        appendBulgeArc(from: CGPoint(x: v.x, y: v.y),
                                       to: CGPoint(x: next.x, y: next.y),
                                       bulge: v.bulge, into: &loop)
                    }
                }
            } else {
                var edgeCount = 0
                while i < n {
                    let c = pairs[i].code
                    if c == 93 { edgeCount = safeInt(num(i)); i += 1; break }
                    if c == 92 || c == 97 || c == 98 { break }
                    i += 1
                }
                var edgesDone = 0
                while edgesDone < edgeCount && i < n {
                    while i < n && pairs[i].code != 72 { i += 1 }
                    guard i < n else { break }
                    let edgeType = safeInt(num(i)); i += 1
                    switch edgeType {
                    case 1:
                        var x1: Double?, y1: Double?, x2: Double?, y2: Double?
                        while i < n {
                            let c = pairs[i].code
                            if c == 10 { x1 = num(i) } else if c == 20 { y1 = num(i) }
                            else if c == 11 { x2 = num(i) } else if c == 21 { y2 = num(i); i += 1; break }
                            else if c == 72 || c == 92 { break }
                            i += 1
                        }
                        if let x1, let y1 { loop.append(CGPoint(x: x1, y: y1)) }
                        if let x2, let y2 { loop.append(CGPoint(x: x2, y: y2)) }
                    case 2:
                        var cx = 0.0, cy = 0.0, r = 0.0, a1 = 0.0, a2 = 360.0, ccw = true
                        var seen40 = false
                        while i < n {
                            let c = pairs[i].code
                            if c == 10 { cx = num(i) } else if c == 20 { cy = num(i) }
                            else if c == 40 { r = num(i); seen40 = true }
                            else if c == 50 { a1 = num(i) } else if c == 51 { a2 = num(i) }
                            else if c == 73 { ccw = num(i) != 0; i += 1; break }
                            else if c == 72 || c == 92 { break }
                            i += 1
                        }
                        if seen40 { tessArc(c: CGPoint(x: cx, y: cy), r: r,
                                            a1Deg: a1, a2Deg: a2, ccw: ccw, into: &loop) }
                    case 3:
                        var cx = 0.0, cy = 0.0, mx = 0.0, my = 0.0, ratio = 1.0
                        var a1 = 0.0, a2 = 360.0, ccw = true
                        while i < n {
                            let c = pairs[i].code
                            if c == 10 { cx = num(i) } else if c == 20 { cy = num(i) }
                            else if c == 11 { mx = num(i) } else if c == 21 { my = num(i) }
                            else if c == 40 { ratio = num(i) }
                            else if c == 50 { a1 = num(i) } else if c == 51 { a2 = num(i) }
                            else if c == 73 { ccw = num(i) != 0; i += 1; break }
                            else if c == 72 || c == 92 { break }
                            i += 1
                        }
                        let majorLen = (mx * mx + my * my).squareRoot()
                        let rot = atan2(my, mx)
                        var s = a1 * .pi / 180, e = a2 * .pi / 180
                        if !ccw { swap(&s, &e) }
                        var sweep = e - s
                        if sweep <= 0 { sweep += 2 * .pi }
                        let steps = max(6, min(64, safeInt(sweep / 0.12)))
                        for k in 0...steps {
                            let a = s + sweep * Double(k) / Double(steps)
                            let ex = majorLen * cos(a), ey = majorLen * ratio * sin(a)
                            loop.append(CGPoint(x: cx + ex * cos(rot) - ey * sin(rot),
                                                y: cy + ex * sin(rot) + ey * cos(rot)))
                        }
                    case 4:
                        var pts: [CGPoint] = []
                        var px: Double? = nil
                        while i < n {
                            let c = pairs[i].code
                            if c == 10 { px = num(i) }
                            else if c == 20, let x = px { pts.append(CGPoint(x: x, y: num(i))); px = nil }
                            else if c == 11 { px = num(i) }
                            else if c == 21, let x = px { pts.append(CGPoint(x: x, y: num(i))); px = nil }
                            else if c == 72 || c == 92 || c == 97 || c == 98 { break }
                            i += 1
                        }
                        loop.append(contentsOf: pts)
                    default:
                        break
                    }
                    edgesDone += 1
                }
            }

            if loop.count >= 3 { loops.append(loop.map { Vec3($0) }) }
            pathsDone += 1
        }

        guard !loops.isEmpty else { return nil }
        return (solid, loops)
    }
}
