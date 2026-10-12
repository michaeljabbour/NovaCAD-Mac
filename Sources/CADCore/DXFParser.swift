import Foundation
import CoreGraphics

// MARK: - Raw (pre-expansion) entity model

/// Public — NovaCAD's separate `EntityStoreParser` (its own from-scratch DXF
/// group-code scan, kept outside this module per the CADCore extraction
/// boundary) constructs its own `PolyVertex` values during its independent
/// parse, rather than duplicating this small scratch type.
public struct PolyVertex {
    public var x: Double
    public var y: Double
    public var bulge: Double = 0

    public init(x: Double, y: Double, bulge: Double = 0) {
        self.x = x
        self.y = y
        self.bulge = bulge
    }
}

/// Int conversion that cannot trap: malformed DXF values can parse to NaN/±inf
/// (e.g. "1e999"), and `Int(Double.infinity)` crashes. Public for the same
/// reason as `PolyVertex` above — NovaCAD's `EntityStoreParser` needs this
/// exact untrusted-input-safe conversion for its own independent DXF scan.
@inline(__always) public func safeInt(_ d: Double) -> Int {
    guard d.isFinite else { return 0 }
    return Int(max(min(d, 9.2e18), -9.2e18))
}

/// `Int64` sibling of `safeInt`, for the same reason: `Int64(Double)` traps on
/// non-finite or out-of-range input, and DXF group-code text is untrusted
/// (hand-edited or corrupted files can contain "1e400", "nan", etc.).
@inline(__always) public func safeInt64(_ d: Double) -> Int64 {
    guard d.isFinite else { return 0 }
    return Int64(max(min(d, 9.2e18), -9.2e18))
}

struct TextRaw {
    var p1 = CGPoint.zero            // first alignment point (code 10/20)
    var p2: CGPoint? = nil           // second alignment point (code 11/21)
    var height: Double = 2.5
    var rotationDegrees: Double = 0
    var widthFactor: Double = 1
    var text = ""
    var hAlign = 0                   // 0 left, 1 center, 2 right
    var vAlign = 0                   // 0 baseline, 1 bottom, 2 middle, 3 top
    /// An ATTRIB entity's TAG (group code 2 — the field NAME, e.g. "PART_BASE"),
    /// distinct from `text` (group code 1, the field's VALUE). Empty for plain
    /// TEXT/MTEXT, which have no tag. This is what lets a consumer distinguish
    /// "this value is the PART_BASE" from "this value is the PART_DESC" on a
    /// block instance carrying several ATTRIBs — previously discarded entirely,
    /// so only one arbitrary attribute value per block instance was visible.
    var tag = ""
}

struct InsertRaw {
    var name = ""
    var x: Double = 0, y: Double = 0
    var sx: Double = 1, sy: Double = 1
    var rotationDegrees: Double = 0
    var cols = 1, rows = 1
    var colSpacing: Double = 0, rowSpacing: Double = 0
    /// True for the synthetic inserts that surface orphaned block definitions —
    /// their contents select as individual entities, not as one block reference.
    var isSyntheticRoot = false
    /// DXF group code 66 ("attributes follow" flag). When true, the ENTITIES
    /// stream carries this INSERT's per-instance `ATTRIB` values as standalone
    /// entities immediately following it (up to the matching `SEQEND`) —
    /// the dominant real-world pattern for per-instance attribute VALUES
    /// (e.g. a plant part-marker block's `PART_BASE` differing per placement),
    /// as distinct from an `ATTDEF` baked into the block DEFINITION itself.
    /// `GeometryBuilder.walk` uses this to back-link those standalone ATTRIBs
    /// to this INSERT's `insertId`: it tracks "the entities immediately
    /// following an attributes-follow INSERT, in file order, up until the
    /// next non-ATTRIB entity, belong to that INSERT instance" — the exact
    /// DXF `INSERT`…`ATTRIB`*…`SEQEND` structure, since `SEQEND` itself
    /// produces no `RawEntity` (dropped like the POLYLINE-family SEQEND is).
    /// No absolute-position handling is needed here: unlike an `ATTDEF`
    /// baked into a block DEFINITION (which lives in the block's LOCAL
    /// space), a standalone `ATTRIB` following an `INSERT` already carries
    /// its own placed, WORLD-space coordinates — it is emitted at the
    /// walk's CURRENT context, not re-transformed through the INSERT's
    /// block-local transform. Previously unparsed entirely, which left every
    /// such ATTRIB permanently un-owned (`insertId == -1`), so downstream
    /// importers never saw ANY of that block instance's attribute values.
    var attributesFollow = false
    /// NovaCAD's per-instance "Display Name" cosmetic override, when this
    /// INSERT carries one — read from XDATA app-id `NOVACAD_DISPLAYNAME`
    /// (group 1001) whose value is the immediately-following group-1000
    /// string (see `xdataString(_:appID:)` in `makeGeoms`). `nil` when no
    /// such XDATA is present — meaning NO override; the real block name
    /// (this struct's `name`) is the fallback identifier in that case. This
    /// is a LABEL ONLY: it never changes which block definition is drawn
    /// (unlike `name`, which selects the actual geometry) — purely a
    /// human-readable identifier for downstream consumers (e.g. a
    /// station-name resolver) to prefer over the raw block name/ATTRIB
    /// heuristic when present.
    var displayNameOverride: String?
}

enum RawGeom {
    case line(x1: Double, y1: Double, x2: Double, y2: Double)
    case circle(cx: Double, cy: Double, r: Double)
    case arc(cx: Double, cy: Double, r: Double, a1: Double, a2: Double) // degrees, CCW
    case polyline(verts: [PolyVertex], closed: Bool)
    case solidFill(pts: [CGPoint])
    case hatch(loops: [[CGPoint]], solid: Bool)
    case point(x: Double, y: Double)
    case text(TextRaw)
    case insert(InsertRaw)
}

struct RawEntity {
    var geom: RawGeom
    var kind: EntityKind = .other
    var layerId: Int32 = 0
    var aci: Int16 = 256             // 256 = BYLAYER, 0 = BYBLOCK
    var trueColor: UInt32 = RawEntity.noTrueColor
    var linetypeId: Int16 = -1       // -1 BYLAYER, -2 BYBLOCK, >=0 table index
    var mirrorOCS = false            // extrusion normal Z < 0
    /// Set by the scanner when this entity is a standalone `ATTRIB` that
    /// immediately follows an "attributes follow" `INSERT` (group code 66)
    /// in the SAME entity list, before the matching `SEQEND` — i.e. it is
    /// one of that INSERT's per-instance attribute VALUES, not a freestanding
    /// annotation. `GeometryBuilder.walk` uses this to back-link the entity
    /// to its owning INSERT's `insertId` (see `InsertRaw.attributesFollow`'s
    /// doc comment for the full "why").
    var followsInsertAttributes = false
    /// The entity's own DXF handle (group code 5), parsed from its hex string.
    /// 0 = none present (older/synthetic sources, or block-expanded content
    /// that inherits the top-level INSERT's handle instead). This is the
    /// STABLE per-entity identity that survives round-tripping a drawing
    /// through an editor — downstream layout-sync consumers key persistent
    /// state off it so a re-imported/edited drawing keeps matching the same
    /// aisles/marketplaces instead of re-identifying everything.
    var handle: UInt64 = 0

    static let noTrueColor: UInt32 = 0xFF00_0000
}

final class BlockDef {
    var name = ""
    var base = CGPoint.zero
    var flags = 0
    var xrefPath = ""
    var entities: [RawEntity] = []
    /// True for blocks transplanted out of a resolved xref file — these are
    /// never candidates for orphan-block recovery in the host drawing.
    var isXrefDependent = false
    /// Set when PackageLoader successfully loaded this xref's file, even if
    /// its model space happened to be empty.
    var wasResolved = false
    var isXref: Bool { (flags & 4) != 0 || (flags & 32) != 0 || !xrefPath.isEmpty }
}

public struct RawParseOutput {
    var model: [RawEntity] = []
    var paper: [RawEntity] = []
    var blocks: [String: BlockDef] = [:]
    var layers: [DXFLayer] = []
    var layerIdByName: [String: Int32] = [:]
    var linetypes: [DXFLinetype] = []
    var linetypeIdByName: [String: Int16] = [:]
    var ltScale: Double = 1
    /// $INSUNITS header value (0 unitless, 1 in, 2 ft, 4 mm, 5 cm, 6 m, ...).
    var insUnits = 0
    var skippedTypes: [String: Int] = [:]
    var totalEntities = 0
}

// MARK: - Parser

/// Byte-level streaming DXF parser. Never materializes the whole file as a String —
/// group-code values become Strings only for the handful of codes that carry text.
public struct DXFParser {

    public static func parse(url: URL, progress: ((Double) -> Void)? = nil) throws -> DXFDocument {
        let t0 = Date()
        var raw = try scanRaw(url: url) { p in progress?(p * 0.72) }
        let parseSeconds = Date().timeIntervalSince(t0)
        let doc = GeometryBuilder.build(from: &raw,
                                        parseSeconds: parseSeconds) { p in
            progress?(0.72 + p * 0.27)
        }
        progress?(1.0)
        return doc
    }

    /// Scans a DXF into raw (pre-expansion) form. PackageLoader uses this to
    /// merge xref files into a host drawing before geometry building.
    static func scanRaw(url: URL, progress: (Double) -> Void) throws -> RawParseOutput {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        if data.prefix(18).elementsEqual("AutoCAD Binary DXF".utf8) {
            throw NSError(domain: "DXFParser", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Binary DXF is not supported yet. Re-save as ASCII DXF (or open the DWG directly)."])
        }
        return try scan(data: data, progress: progress)
    }

    // MARK: Scanner

    private struct Pair {
        var code: Int32
        var num: Double
        var str: String?
    }

    /// Codes whose values we need as text.
    @inline(__always)
    private static func isStringCode(_ c: Int32) -> Bool {
        switch c {
        // 5 = entity handle (a hex string like "2A3"); carved into the string
        // range so its value is retained as text for hex parsing rather than
        // being coerced through `Double`.
        case 1, 2, 3, 5, 6, 7, 8, 9: return true
        // 1001 = XDATA app-id registration marker (e.g. "NOVACAD_DISPLAYNAME");
        // 1000 = an XDATA string value immediately following one. Without
        // these in the string range, their text would be routed through
        // `parseNum` (garbage/0 for non-numeric text) and lost — needed to
        // read NovaCAD's per-instance "Display Name" cosmetic override once
        // NovaCAD starts persisting it into the DXF via XDATA (see
        // `insertDisplayNameOverride(forInsertId:)` in GeometryBuilder.swift
        // for the consumer).
        case 1000, 1001: return true
        default: return false
        }
    }

    private static func scan(data: Data, progress: (Double) -> Void) throws -> RawParseOutput {
        var out = RawParseOutput()

        // Layer 0 always exists and is index 0.
        out.layers.append(DXFLayer(id: 0, name: "0"))
        out.layerIdByName["0"] = 0
        // Linetype 0 = CONTINUOUS.
        out.linetypes.append(DXFLinetype(name: "CONTINUOUS", dashes: []))
        out.linetypeIdByName["CONTINUOUS"] = 0
        out.linetypeIdByName["BYLAYER"] = -1
        out.linetypeIdByName["BYBLOCK"] = -2

        enum Section { case none, header, tables, blocks, entities, other }

        var section = Section.none
        var expectSectionName = false
        var currentTable = ""
        var expectTableName = false
        var headerVar = ""

        var inBlockDef: BlockDef? = nil

        // Record accumulation
        var recType = ""
        var pairs: [Pair] = []
        pairs.reserveCapacity(64)

        // Legacy POLYLINE assembly
        struct PendingPolyline {
            var flags = 0
            var mVerts = 0, nVerts = 0
            var verts: [PolyVertex] = []
            var vertFlags: [Int] = []
            var faces: [[Int]] = []
            var common = RawEntity(geom: .point(x: 0, y: 0))
            var isPaper = false
            var inBlock = false
        }
        var pendingPoly: PendingPolyline? = nil

        // Tracks whether we're currently inside an "attributes follow" INSERT's
        // ATTRIB run (INSERT[66=1] … ATTRIB* … SEQEND) — see `InsertRaw.
        // attributesFollow`'s doc comment. Set true the moment such an INSERT
        // is emitted; every immediately-following ATTRIB record is tagged
        // `followsInsertAttributes = true` while this stays true; cleared by
        // the run's `SEQEND`, or defensively by any other record type
        // (a malformed/unexpected file structure should never mis-tag an
        // unrelated entity as belonging to a stale INSERT).
        var pendingAttribInsertActive = false

        // LTYPE assembly
        var ltName = ""
        var ltDashes: [Double] = []

        // LAYER assembly
        var layName = ""
        var layColor = 7
        var layTrue: UInt32? = nil
        var layFlags = 0
        var layLtype = "CONTINUOUS"
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
            out.layers[Int(id)] = layer
        }

        func flushLtypeRecord() {
            guard inLtypeRecord else { return }
            inLtypeRecord = false
            let upper = ltName.uppercased()
            guard out.linetypeIdByName[upper] == nil else { return }
            let id = Int16(out.linetypes.count)
            // Convert signed DXF dash items to CG paint/gap lengths.
            var dashes: [CGFloat] = []
            if !ltDashes.isEmpty, ltDashes.contains(where: { $0 != 0 }) {
                var items = ltDashes
                // CG patterns start with a painted length.
                if items.first ?? 0 < 0 { items.append(items.removeFirst()) }
                let total = items.reduce(0) { $0 + abs($1) }
                let dot = max(total * 0.04, 1e-6)
                for v in items { dashes.append(CGFloat(v == 0 ? dot : abs(v))) }
                if dashes.count % 2 == 1 { dashes.append(dashes.last ?? 0) }
            }
            out.linetypes.append(DXFLinetype(name: ltName, dashes: dashes))
            out.linetypeIdByName[upper] = id
        }

        // MARK: per-record finalization

        func commonProps(_ pairs: [Pair]) -> (RawEntity, isPaper: Bool, invisible: Bool) {
            var e = RawEntity(geom: .point(x: 0, y: 0))
            var isPaper = false
            var invisible = false
            for p in pairs {
                switch p.code {
                case 5:   if let s = p.str, let v = UInt64(s, radix: 16) { e.handle = v }
                case 8:   e.layerId = internLayer(p.str ?? "0")
                case 62:  e.aci = Int16(clamping: safeInt(p.num))
                case 420: e.trueColor = UInt32(truncatingIfNeeded: safeInt(p.num)) & 0x00FF_FFFF
                case 6:
                    let name = (p.str ?? "").uppercased()
                    e.linetypeId = out.linetypeIdByName[name] ?? -1
                case 67:  isPaper = p.num == 1
                case 60:  invisible = p.num == 1
                case 230: if p.num < 0 { e.mirrorOCS = true }
                default: break
                }
            }
            if e.aci < 0 { e.aci = Int16(clamping: abs(Int(e.aci))) } // some exporters write negatives
            return (e, isPaper, invisible)
        }

        func emit(_ entity: RawEntity, isPaper: Bool) {
            out.totalEntities += 1
            if let block = inBlockDef { block.entities.append(entity) }
            else if isPaper { out.paper.append(entity) }
            else { out.model.append(entity) }
        }

        func finishRecord() {
            guard !recType.isEmpty else { return }
            defer { pairs.removeAll(keepingCapacity: true); recType = "" }

            // Table records
            if section == .tables {
                switch recType {
                case "LAYER":
                    flushLayerRecord(); flushLtypeRecord()
                    guard currentTable == "LAYER" else { return }
                    inLayerRecord = true
                    layName = ""; layColor = 7; layTrue = nil; layFlags = 0; layLtype = "CONTINUOUS"
                    for p in pairs {
                        switch p.code {
                        case 2: layName = p.str ?? ""
                        case 62: layColor = safeInt(p.num)
                        case 420: layTrue = UInt32(truncatingIfNeeded: safeInt(p.num)) & 0x00FF_FFFF
                        case 70: layFlags = safeInt(p.num)
                        case 6: layLtype = p.str ?? "CONTINUOUS"
                        default: break
                        }
                    }
                    flushLayerRecord()
                case "LTYPE":
                    flushLtypeRecord(); flushLayerRecord()
                    guard currentTable == "LTYPE" else { return }
                    ltName = ""; ltDashes = []
                    for p in pairs {
                        switch p.code {
                        case 2: ltName = p.str ?? ""
                        case 49: ltDashes.append(p.num)
                        default: break
                        }
                    }
                    inLtypeRecord = true
                    flushLtypeRecord()
                default:
                    break
                }
                return
            }

            guard section == .blocks || section == .entities else { return }

            switch recType {
            case "BLOCK":
                let b = BlockDef()
                for p in pairs {
                    switch p.code {
                    case 2: if b.name.isEmpty { b.name = p.str ?? "" }
                    case 10: b.base.x = p.num
                    case 20: b.base.y = p.num
                    case 70: b.flags = safeInt(p.num)
                    case 1: b.xrefPath = p.str ?? ""
                    case 3: if b.name.isEmpty { b.name = p.str ?? "" }
                    default: break
                    }
                }
                inBlockDef = b
                return
            case "ENDBLK":
                if let b = inBlockDef, !b.name.isEmpty { out.blocks[b.name] = b }
                inBlockDef = nil
                return
            default:
                break
            }

            // ---- POLYLINE / VERTEX / SEQEND ----
            if recType == "POLYLINE" {
                var pp = PendingPolyline()
                let (common, isPaper, invisible) = commonProps(pairs)
                pp.common = common
                pp.isPaper = isPaper
                pp.inBlock = inBlockDef != nil
                if invisible { return }
                for p in pairs {
                    switch p.code {
                    case 70: pp.flags = safeInt(p.num)
                    case 71: pp.mVerts = safeInt(p.num)
                    case 72: pp.nVerts = safeInt(p.num)
                    default: break
                    }
                }
                pendingPoly = pp
                return
            }
            if recType == "VERTEX" {
                guard pendingPoly != nil else { return }
                var x = 0.0, y = 0.0, bulge = 0.0, flags = 0
                var face = [0, 0, 0, 0]
                for p in pairs {
                    switch p.code {
                    case 10: x = p.num
                    case 20: y = p.num
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
                    pendingPoly?.vertFlags.append(flags)
                }
                return
            }
            if recType == "SEQEND" {
                // A SEQEND can close EITHER a POLYLINE/VERTEX run OR an
                // attributes-follow INSERT's ATTRIB run — always clear
                // whichever (if any) is currently pending.
                pendingAttribInsertActive = false
                guard let pp = pendingPoly else { return }
                pendingPoly = nil
                var e = pp.common
                if (pp.flags & 8) != 0 { e.mirrorOCS = false } // 3D polyline verts are WCS
                let closed = (pp.flags & 1) != 0
                func emitPoly(_ verts: [PolyVertex], closed: Bool) {
                    guard verts.count > 1 else { return }
                    e.geom = .polyline(verts: verts, closed: closed)
                    out.totalEntities += 1
                    if pp.inBlock { inBlockDef?.entities.append(e) }
                    else if pp.isPaper { out.paper.append(e) }
                    else { out.model.append(e) }
                }
                if (pp.flags & 64) != 0 {
                    // Polyface mesh: emit visible edges of each face.
                    let pool = pp.verts
                    for face in pp.faces {
                        let idx = face.filter { $0 != 0 }
                        guard idx.count >= 2 else { continue }
                        for k in 0..<idx.count {
                            let a = idx[k], b = idx[(k + 1) % idx.count]
                            guard a > 0 else { continue } // negative start = invisible edge
                            let ia = abs(a) - 1, ib = abs(b) - 1
                            guard ia < pool.count, ib < pool.count else { continue }
                            emitPoly([pool[ia], pool[ib]], closed: false)
                        }
                    }
                } else if (pp.flags & 16) != 0, pp.mVerts > 1, pp.nVerts > 1,
                          pp.verts.count >= pp.mVerts * pp.nVerts {
                    // M x N mesh grid: draw the wireframe.
                    let m = pp.mVerts, n = pp.nVerts
                    for i in 0..<m {
                        emitPoly(Array(pp.verts[(i * n)..<(i * n + n)]),
                                 closed: (pp.flags & 32) != 0)
                    }
                    for j in 0..<n {
                        var col: [PolyVertex] = []
                        for i in 0..<m { col.append(pp.verts[i * n + j]) }
                        emitPoly(col, closed: (pp.flags & 1) != 0)
                    }
                } else {
                    // Regular 2D/3D polyline. Skip spline-frame control points (bit 16)
                    // when the polyline is spline-fit and true curve vertices exist.
                    var verts: [PolyVertex] = []
                    var hasNonFrame = false
                    for f in pp.vertFlags where (f & 16) == 0 { hasNonFrame = true; break }
                    for (i, v) in pp.verts.enumerated() {
                        if hasNonFrame && (pp.vertFlags[i] & 16) != 0 { continue }
                        verts.append(v)
                    }
                    emitPoly(verts, closed: closed)
                }
                return
            }
            // ---- end POLYLINE family ----

            guard let (geoms, kind) = makeGeoms(type: recType, pairs: pairs,
                                                skipped: &out.skippedTypes)
            else { return }

            var (common, isPaper, invisible) = commonProps(pairs)
            guard !invisible else { return }
            common.kind = kind
            // LINE/SPLINE/ELLIPSE/3DFACE/MTEXT/LEADER coordinates are WCS in DXF;
            // their 210/230 normal orients thickness only and must not mirror geometry.
            switch recType {
            case "LINE", "SPLINE", "ELLIPSE", "3DFACE", "MTEXT", "LEADER":
                common.mirrorOCS = false
            default: break
            }

            // Attributes-follow INSERT/ATTRIB tracking (see `InsertRaw.
            // attributesFollow`'s doc comment). An INSERT starts the run (if
            // flagged); an ATTRIB while the run is active gets tagged; any
            // OTHER record type ends the run defensively (a well-formed file
            // always closes the run with SEQEND first, but a malformed one
            // must never mis-tag unrelated geometry as belonging to a stale
            // INSERT).
            if recType == "INSERT", case .insert(let ins) = geoms.first, ins.attributesFollow {
                pendingAttribInsertActive = true
            } else if recType == "ATTRIB" {
                common.followsInsertAttributes = pendingAttribInsertActive
            } else {
                pendingAttribInsertActive = false
            }

            for g in geoms {
                var e = common
                e.geom = g
                emit(e, isPaper: isPaper)
            }
        }

        // MARK: byte loop

        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            let bytes = buf.bindMemory(to: UInt8.self)
            let n = bytes.count
            // Skip a UTF-8 BOM so the very first code/value pair parses.
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
                // Values keep interior spaces; trim only the trailing CR (already
                // excluded) — but trim leading spaces which some exporters pad.
                var st = s
                while st < end && bytes[st] == 0x20 { st += 1 }
                while end > st && bytes[end - 1] == 0x20 { end -= 1 }
                guard st < end else { return "" }
                return String(decoding: UnsafeRawBufferPointer(rebasing: buf[st..<end]),
                              as: UTF8.self)
            }

            while i < n {
                // find end of line
                var e = i
                while e < n && bytes[e] != 0x0A { e += 1 }
                var lineEnd = e
                if lineEnd > i && bytes[lineEnd - 1] == 0x0D { lineEnd -= 1 }

                if lineNo & 1 == 0 {
                    code = parseCode(i, lineEnd) ?? -9999
                } else if code != -9999 {
                    if code == 0 || code == 9 {
                        finishRecord()
                        let v = makeString(i, lineEnd).uppercased()
                        if code == 9 {
                            headerVar = v
                        } else {
                            switch v {
                            case "SECTION": expectSectionName = true
                            case "ENDSEC":
                                finishRecord(); flushLayerRecord(); flushLtypeRecord()
                                section = .none; currentTable = ""
                            case "TABLE": expectTableName = true
                            case "ENDTAB":
                                flushLayerRecord(); flushLtypeRecord()
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
                    } else if !recType.isEmpty {
                        if isStringCode(code) {
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
        progress(1.0)
        return out
    }

    // MARK: - Geometry construction per entity type

    private static func makeGeoms(type: String, pairs: [Pair],
                                  skipped: inout [String: Int]) -> ([RawGeom], EntityKind)? {
        func d(_ code: Int32) -> Double? {
            for p in pairs where p.code == code { return p.num }
            return nil
        }
        func s(_ code: Int32) -> String? {
            for p in pairs where p.code == code { return p.str }
            return nil
        }

        /// Reads an entity's XDATA (extended entity data) string value for a
        /// given app-id: a `1001` group whose string value is `appID`,
        /// immediately followed by a `1000` group carrying the actual value —
        /// the exact XDATA shape NovaCAD writes for its per-instance "Display
        /// Name" cosmetic override (`NOVACAD_DISPLAYNAME`). An entity can
        /// carry XDATA for MULTIPLE app-ids back-to-back; this scans every
        /// `1001` pair (not just the first) so a `NOVACAD_DISPLAYNAME` block
        /// isn't missed just because it's not the first app-id present.
        /// Returns `nil` when the app-id isn't present at all — callers fall
        /// back to the entity's real name/tag in that case.
        func xdataString(_ pairs: [Pair], appID: String) -> String? {
            for (i, p) in pairs.enumerated() where p.code == 1001 && p.str == appID {
                let next = i + 1
                guard next < pairs.count, pairs[next].code == 1000 else { continue }
                return pairs[next].str
            }
            return nil
        }

        switch type {
        case "LINE":
            guard let x1 = d(10), let y1 = d(20), let x2 = d(11), let y2 = d(21) else { return nil }
            return ([.line(x1: x1, y1: y1, x2: x2, y2: y2)], .line)

        case "CIRCLE":
            guard let cx = d(10), let cy = d(20), let r = d(40), r > 0 else { return nil }
            return ([.circle(cx: cx, cy: cy, r: r)], .circle)

        case "ARC":
            guard let cx = d(10), let cy = d(20), let r = d(40), r > 0,
                  let a1 = d(50), let a2 = d(51) else { return nil }
            return ([.arc(cx: cx, cy: cy, r: r, a1: a1, a2: a2)], .arc)

        case "LWPOLYLINE":
            var verts: [PolyVertex] = []
            var closed = false
            var pendingX: Double? = nil
            for p in pairs {
                switch p.code {
                case 70: closed = (safeInt(p.num) & 1) != 0
                case 10: pendingX = p.num
                case 20:
                    if let x = pendingX { verts.append(PolyVertex(x: x, y: p.num)); pendingX = nil }
                case 42:
                    if !verts.isEmpty { verts[verts.count - 1].bulge = p.num }
                default: break
                }
            }
            guard verts.count > 1 else { return nil }
            return ([.polyline(verts: verts, closed: closed)], .polyline)

        case "SPLINE":
            var knots: [Double] = []
            var weights: [Double] = []
            var ctrl: [CGPoint] = []
            var fit: [CGPoint] = []
            var degree = 3
            var flags = 0
            var cx: Double? = nil, fx: Double? = nil
            for p in pairs {
                switch p.code {
                case 70: flags = safeInt(p.num)
                case 71: degree = safeInt(p.num)
                case 40: knots.append(p.num)
                case 41: weights.append(p.num)
                case 10: cx = p.num
                case 20: if let x = cx { ctrl.append(CGPoint(x: x, y: p.num)); cx = nil }
                case 11: fx = p.num
                case 21: if let x = fx { fit.append(CGPoint(x: x, y: p.num)); fx = nil }
                default: break
                }
            }
            let closed = (flags & 1) != 0
            var pts: [CGPoint]
            if ctrl.count >= 2 && knots.count == ctrl.count + degree + 1 {
                let samples = min(72, max(8, ctrl.count * 3))
                pts = SplineEvaluator.tessellate(controlPoints: ctrl, knots: knots,
                                                 weights: weights.count == ctrl.count ? weights : nil,
                                                 degree: degree, samples: samples)
            } else if fit.count >= 2 {
                pts = fit
            } else if ctrl.count >= 2 {
                pts = ctrl
            } else { return nil }
            let verts = pts.map { PolyVertex(x: $0.x, y: $0.y) }
            return ([.polyline(verts: verts, closed: closed)], .spline)

        case "ELLIPSE":
            guard let cx = d(10), let cy = d(20),
                  let mx = d(11), let my = d(21), let ratio = d(40) else { return nil }
            let start = d(41) ?? 0
            let end = d(42) ?? (2 * .pi)
            let majorLen = (mx * mx + my * my).squareRoot()
            guard majorLen > 0 else { return nil }
            let minorLen = majorLen * ratio
            let rot = atan2(my, mx)
            var verts: [PolyVertex] = []
            let sweep = end > start ? end - start : end + 2 * .pi - start
            let steps = max(16, min(96, safeInt(sweep / 0.08)))
            for k in 0...steps {
                let a = start + sweep * Double(k) / Double(steps)
                let ex = majorLen * cos(a), ey = minorLen * sin(a)
                verts.append(PolyVertex(x: cx + ex * cos(rot) - ey * sin(rot),
                                        y: cy + ex * sin(rot) + ey * cos(rot)))
            }
            let isFull = abs(sweep - 2 * .pi) < 1e-6
            return ([.polyline(verts: verts, closed: isFull)], .ellipse)

        case "SOLID", "TRACE":
            var pts: [CGPoint] = []
            for (xc, yc) in [(Int32(10), Int32(20)), (11, 21), (12, 22), (13, 23)] {
                if let x = d(xc), let y = d(yc) { pts.append(CGPoint(x: x, y: y)) }
            }
            guard pts.count >= 3 else { return nil }
            if pts.count == 4 { pts.swapAt(2, 3) }
            if pts.count == 4 && pts[2] == pts[3] { pts.removeLast() }
            return ([.solidFill(pts: pts)], .solid)

        case "3DFACE":
            // AutoCAD draws 3DFACE as edges (honoring invisible-edge flags in
            // group 70), not as a filled polygon.
            var pts: [CGPoint] = []
            for (xc, yc) in [(Int32(10), Int32(20)), (11, 21), (12, 22), (13, 23)] {
                if let x = d(xc), let y = d(yc) { pts.append(CGPoint(x: x, y: y)) }
            }
            if pts.count == 4 && pts[2] == pts[3] { pts.removeLast() }
            guard pts.count >= 3 else { return nil }
            let invisible = safeInt(d(70) ?? 0)
            if invisible == 0 {
                let verts = pts.map { PolyVertex(x: $0.x, y: $0.y) }
                return ([.polyline(verts: verts, closed: true)], .face3d)
            }
            var edges: [RawGeom] = []
            for k in 0..<pts.count {
                guard invisible & (1 << k) == 0 else { continue }
                let p1 = pts[k], p2 = pts[(k + 1) % pts.count]
                edges.append(.line(x1: p1.x, y1: p1.y, x2: p2.x, y2: p2.y))
            }
            return edges.isEmpty ? nil : (edges, .face3d)

        case "POINT":
            guard let x = d(10), let y = d(20) else { return nil }
            return ([.point(x: x, y: y)], .point)

        case "TEXT", "ATTRIB":
            if type == "ATTRIB", let f = d(70), (Int(f) & 1) != 0 { return nil } // invisible
            guard let x = d(10), let y = d(20) else { return nil }
            var t = TextRaw()
            t.p1 = CGPoint(x: x, y: y)
            if let x2 = d(11), let y2 = d(21) { t.p2 = CGPoint(x: x2, y: y2) }
            t.height = d(40) ?? 2.5
            t.rotationDegrees = d(50) ?? 0
            // Clamp: some exporters bake fit-justification stretch into code 41,
            // producing absurd factors (seen: 157.9) that would smear the label.
            t.widthFactor = min(max(d(41) ?? 1, 0.1), 10)
            let h = safeInt(d(72) ?? 0)
            t.hAlign = [0: 0, 1: 1, 2: 2, 3: 1, 4: 1, 5: 1][h] ?? 0
            // ATTRIB stores vertical justification in group 74 (73 is field length).
            t.vAlign = min(max(safeInt(d(type == "ATTRIB" ? 74 : 73) ?? 0), 0), 3)
            if h == 4 { t.vAlign = 2 } // "middle" justification
            t.text = MTextParser.plainSingleLineText(from: s(1) ?? "")
            if type == "ATTRIB" { t.tag = s(2) ?? "" }
            guard !t.text.isEmpty, t.height > 0 else { return nil }
            return ([.text(t)], type == "ATTRIB" ? .attrib : .text)

        case "MTEXT":
            guard let x = d(10), let y = d(20) else { return nil }
            var rawStr = ""
            for p in pairs where p.code == 3 { rawStr += p.str ?? "" }
            rawStr += s(1) ?? ""
            var t = TextRaw()
            t.p1 = CGPoint(x: x, y: y)
            t.height = d(40) ?? 2.5
            if let dx = d(11), let dy = d(21), dx != 0 || dy != 0 {
                t.rotationDegrees = atan2(dy, dx) * 180 / .pi
            } else {
                t.rotationDegrees = d(50) ?? 0
            }
            let attach = safeInt(d(71) ?? 1)
            t.hAlign = (attach - 1) % 3
            t.vAlign = [3, 2, 1][min(max((attach - 1) / 3, 0), 2)]
            t.text = MTextParser.plainText(from: rawStr)
            t.text = TextLayout.wrap(t.text, height: CGFloat(t.height), width: CGFloat(d(41) ?? 0))
            guard !t.text.isEmpty, t.height > 0 else { return nil }
            return ([.text(t)], .mtext)

        case "INSERT":
            guard let name = s(2), !name.isEmpty,
                  let x = d(10), let y = d(20) else { return nil }
            var ins = InsertRaw()
            ins.name = name
            ins.x = x; ins.y = y
            ins.sx = d(41) ?? 1; ins.sy = d(42) ?? (d(41) ?? 1)
            ins.rotationDegrees = d(50) ?? 0
            // NOTE: group code 70 is REUSED here — column count for an MINSERT
            // array (only meaningful when this INSERT is an array), but also
            // happens to be a different semantic on other record types. For
            // plain (non-array) block inserts, which never emit code 70, this
            // safely defaults to 1 via `?? 1`; the "attributes follow" flag is
            // group code 66, parsed separately below (distinct code, no clash).
            ins.cols = max(1, safeInt(d(70) ?? 1)); ins.rows = max(1, safeInt(d(71) ?? 1))
            ins.colSpacing = d(44) ?? 0; ins.rowSpacing = d(45) ?? 0
            ins.attributesFollow = (d(66) ?? 0) != 0
            ins.displayNameOverride = xdataString(pairs, appID: "NOVACAD_DISPLAYNAME")
            return ([.insert(ins)], .other)

        case "DIMENSION":
            guard let name = s(2), !name.isEmpty else { return nil }
            var ins = InsertRaw()
            ins.name = name
            return ([.insert(ins)], .other)

        case "ACAD_TABLE":
            guard let name = s(2), !name.isEmpty,
                  let x = d(10), let y = d(20) else { return nil }
            var ins = InsertRaw()
            ins.name = name
            ins.x = x; ins.y = y
            return ([.insert(ins)], .other)

        case "LEADER":
            var verts: [PolyVertex] = []
            var px: Double? = nil
            for p in pairs {
                if p.code == 10 { px = p.num }
                else if p.code == 20, let x = px { verts.append(PolyVertex(x: x, y: p.num)); px = nil }
            }
            guard verts.count > 1 else { return nil }
            return ([.polyline(verts: verts, closed: false)], .leader)

        case "HATCH":
            return makeHatch(pairs: pairs).map { ($0, EntityKind.hatch) }

        // Entities with nothing useful to draw in a 2D viewer.
        case "ATTDEF", "VIEWPORT", "MLEADER", "MULTILEADER",
             "ACAD_PROXY_ENTITY", "OLEFRAME", "OLE2FRAME", "IMAGE",
             "BODY", "REGION", "3DSOLID", "SURFACE", "MESH", "TOLERANCE",
             "WIPEOUT", "XLINE", "RAY", "SHAPE", "HELIX", "LIGHT":
            return nil

        default:
            skipped[type, default: 0] += 1
            return nil
        }
    }

    // MARK: HATCH

    private static func makeHatch(pairs: [Pair]) -> [RawGeom]? {
        var solid = false
        var loops: [[CGPoint]] = []
        var i = 0
        let n = pairs.count

        func num(_ idx: Int) -> Double { pairs[idx].num }

        // Locate 70 (solid flag) and 91 (path count) at the top level.
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
            // find the 92 flags for this path
            while i < n && pairs[i].code != 92 { i += 1 }
            guard i < n else { break }
            let flags = safeInt(num(i)); i += 1
            var loop: [CGPoint] = []

            if flags & 2 != 0 {
                // Polyline boundary: 72 hasBulge, 73 closed, 93 count, verts 10/20 (42)
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
                // Flatten bulges into the loop.
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
                // Edge list: 93 = edge count, then per-edge 72 = type.
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
                    case 1: // line
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
                    case 2: // circular arc
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
                    case 3: // elliptic arc — approximate with segments
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
                    case 4: // spline edge — use control or fit points
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

            if loop.count >= 3 { loops.append(loop) }
            pathsDone += 1
        }

        guard !loops.isEmpty else { return nil }
        return [.hatch(loops: loops, solid: solid)]
    }
}

// MARK: - Bulge helper (shared with GeometryBuilder)

/// Appends the intermediate arc points for a bulged polyline segment (excluding
/// both endpoints; caller appends `to` afterwards or relies on the loop's flow).
/// Public — shared with NovaCAD's `EntityStoreParser` (its own independent DXF
/// scan, kept in NovaCAD per the CADCore extraction's Option B boundary).
public func appendBulgeArc(from p1: CGPoint, to p2: CGPoint, bulge: Double, into pts: inout [CGPoint]) {
    let theta = 4 * atan(bulge)             // included angle, signed
    let dx = p2.x - p1.x, dy = p2.y - p1.y
    let chord = (dx * dx + dy * dy).squareRoot()
    guard chord > 1e-12, abs(theta) > 1e-6 else { return }
    let r = chord / (2 * abs(sin(theta / 2)))
    let mid = CGPoint(x: (p1.x + p2.x) / 2, y: (p1.y + p2.y) / 2)
    // Perpendicular offset from chord midpoint to arc center.
    let h = (r * r - chord * chord / 4).squareRoot().isNaN ? 0
        : (r * r - chord * chord / 4).squareRoot()
    let ux = -dy / chord, uy = dx / chord   // unit normal (left of travel)
    // CCW arcs (theta > 0) have their center left of travel for sweeps <= 180°,
    // right of travel beyond that; CW arcs mirror. Verified: bulge tan(π/8) from
    // (0,0)->(2,0) centers at (1,1) and sags to (1,-0.414).
    let sign: Double = (abs(theta) > .pi ? -1 : 1) * (theta > 0 ? 1 : -1)
    let c = CGPoint(x: mid.x + ux * h * sign, y: mid.y + uy * h * sign)
    let a1 = atan2(p1.y - c.y, p1.x - c.x)
    let steps = max(2, min(48, safeInt(abs(theta) / 0.1)))
    for k in 1..<steps {
        let a = a1 + theta * Double(k) / Double(steps)
        pts.append(CGPoint(x: c.x + r * cos(a), y: c.y + r * sin(a)))
    }
}
