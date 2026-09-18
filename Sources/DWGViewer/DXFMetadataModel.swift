import CADCore
import Foundation

// MARK: - Phase 3 groundwork: structural DXF metadata retention
//
// Everything in this file exists so a FUTURE structural DXF writer
// (`DXFStructuralWriter`, not built yet) has the raw material to re-emit a
// complete, AutoCAD-valid file from an `EditableDocument`. Nothing here
// interprets or acts on this data beyond what's needed for typed
// convenience accessors — see `EntityStoreParser.swift`'s capture logic and
// the plan doc's Phase 3 section for the rationale.
//
// Design principle used throughout: BREADTH over depth. Every HEADER var,
// CLASSES record, TABLES record (VPORT/STYLE/VIEW/UCS/APPID/DIMSTYLE/
// BLOCK_RECORD), and OBJECTS entry is captured as raw (code, value) pairs
// verbatim, in file order, even when no typed accessor exists for it yet —
// losing data at parse time is unrecoverable, whereas a missing typed
// accessor can be added later without touching the parser.

// MARK: - Raw group-code pair (echoed exactly)

/// One DXF group-code/value pair, captured for verbatim echo. `RawGroupValue`
/// (not a bare `String`) preserves whether a value was written as a string,
/// integer, or floating-point group in the source file — the DXF group-code
/// ranges pack multiple logical value kinds under codes that look similar
/// (e.g. very different formatting is expected for a "70" int vs. a "40"
/// double), so a writer must know which literal form to re-emit.
enum RawGroupValue: Equatable {
    case string(String)
    case double(Double)
    case int(Int64)
    /// A group 5/105/330/340/350/360/390/... handle-shaped hex string,
    /// stored pre-parsed as a UInt64 for handle-graph bookkeeping (and as
    /// the ORIGINAL hex text, since DXF handles may have leading-zero
    /// variation writers might care about preserving byte-for-byte —
    /// `hex` is authoritative for round-trip, `value` is for convenience).
    case handle(UInt64, hex: String)
}

/// One captured group code + its value, in file order.
struct RawGroupPair: Equatable {
    var code: Int32
    var value: RawGroupValue
}

// MARK: - HEADER section

/// One `$VARNAME` header variable, captured as its ordered list of group
/// code/value pairs exactly as written (most vars are a single pair; a few,
/// like `$EXTMIN`/`$EXTMAX`/`$PUCSORG`, are a point captured as consecutive
/// 10/20/30-style codes; a handful like `$HANDSEED`/`$CLAYER` carry a
/// string-typed value under a numeric-looking code).
struct HeaderVar: Equatable {
    var name: String          // e.g. "$ACADVER", including the leading '$'
    var pairs: [RawGroupPair]
}

/// All HEADER section variables, in FILE ORDER (bit-exact echo target), plus
/// typed convenience accessors for the subset this codebase can already
/// usefully interpret. The ordered list is the load-bearing data for a
/// future writer; the typed accessors are a nice-to-have layered on top —
/// callers should prefer `rawValue(_:)`/`doubleValue(_:)`/etc. over
/// re-deriving from `vars` themselves.
struct OrderedHeaderVars: Equatable {
    /// Every `$VAR` seen, in the order they appeared in the file. A
    /// well-formed DXF has each name at most once; if a malformed/hand-edited
    /// file repeats one, later occurrences are appended too (nothing is
    /// dropped) — `first(name:)` returns the first (AutoCAD's own effective
    /// behavior), a future writer can decide how to handle the duplicate.
    var vars: [HeaderVar] = []

    private var indexByName: [String: Int] = [:]

    mutating func append(_ v: HeaderVar) {
        let key = Self.normalize(v.name)
        if indexByName[key] == nil { indexByName[key] = vars.count }
        vars.append(v)
    }

    /// First occurrence of `name` (e.g. "$ACADVER" or "ACADVER" — case- and
    /// leading-$-insensitive for caller convenience).
    func variable(_ name: String) -> HeaderVar? {
        let key = Self.normalize(name)
        guard let idx = indexByName[key] else { return nil }
        return vars[idx]
    }

    private static func normalize(_ s: String) -> String {
        var u = s.uppercased()
        if !u.hasPrefix("$") { u = "$" + u }
        return u
    }

    // MARK: Typed accessors (best-effort; nil/default when absent or wrong shape)

    func doubleValue(_ name: String) -> Double? {
        guard let v = variable(name) else { return nil }
        for p in v.pairs {
            switch p.value {
            case .double(let d): return d
            case .int(let i): return Double(i)
            default: continue
            }
        }
        return nil
    }

    func intValue(_ name: String) -> Int? {
        guard let v = variable(name) else { return nil }
        for p in v.pairs {
            switch p.value {
            case .int(let i): return Int(i)
            case .double(let d): return Int(d)
            default: continue
            }
        }
        return nil
    }

    func stringValue(_ name: String) -> String? {
        guard let v = variable(name) else { return nil }
        for p in v.pairs {
            if case .string(let s) = p.value { return s }
        }
        return nil
    }

    /// Point-shaped vars (e.g. `$EXTMIN`, `$EXTMAX`, `$INSBASE`) captured as
    /// 10/20/30 codes — DXF's convention for every point-typed header
    /// variable — returns (x, y, z), z defaulting to 0 if code 30 is absent
    /// (legal for a 2D-only point var).
    func pointValue(_ name: String) -> (x: Double, y: Double, z: Double)? {
        guard let v = variable(name) else { return nil }
        var x: Double?, y: Double?, z: Double = 0
        for p in v.pairs {
            let num: Double?
            switch p.value {
            case .double(let d): num = d
            case .int(let i): num = Double(i)
            default: num = nil
            }
            guard let num else { continue }
            if p.code == 10 { x = num } else if p.code == 20 { y = num } else if p.code == 30 { z = num }
        }
        guard let xx = x, let yy = y else { return nil }
        return (xx, yy, z)
    }

    // Convenience typed accessors for the vars this codebase's other
    // components already interpret today, plus the plan's requested set
    // (SysVars.swift's ~29-variable drawing-scoped list) — pre-wired for
    // when a later phase wants to seed `SysVars` from a loaded drawing's
    // HEADER instead of app-global UserDefaults. All are best-effort
    // (return nil/a sensible default when the source file omitted the var,
    // which is legal DXF — AutoCAD fills in its own default in that case).
    var acadver: String? { stringValue("$ACADVER") }
    var handseed: String? {
        guard let v = variable("$HANDSEED") else { return nil }
        for p in v.pairs {
            if case .handle(_, let hex) = p.value { return hex }
            if case .string(let s) = p.value { return s }
        }
        return nil
    }
    var insunits: Int? { intValue("$INSUNITS") }
    var ltscale: Double? { doubleValue("$LTSCALE") }
    var measurement: Int? { intValue("$MEASUREMENT") }
    var angbase: Double? { doubleValue("$ANGBASE") }
    var angdir: Int? { intValue("$ANGDIR") }
    var celtscale: Double? { doubleValue("$CELTSCALE") }
    var pdmode: Int? { intValue("$PDMODE") }
    var pdsize: Double? { doubleValue("$PDSIZE") }
    var mirrtext: Int? { intValue("$MIRRTEXT") }
    var tilemode: Int? { intValue("$TILEMODE") }
    var extmin: (x: Double, y: Double, z: Double)? { pointValue("$EXTMIN") }
    var extmax: (x: Double, y: Double, z: Double)? { pointValue("$EXTMAX") }
    var insbase: (x: Double, y: Double, z: Double)? { pointValue("$INSBASE") }
    var clayer: String? { stringValue("$CLAYER") }
}

// MARK: - CLASSES section

/// One CLASSES record, echoed verbatim (record-type name + every group code
/// pair) — nothing in this codebase interprets classes yet, so no typed
/// lift is offered; a writer just needs to play these back unchanged.
struct RawClass: Equatable {
    /// The record type name is always "CLASS" in a well-formed DXF, but kept
    /// here (rather than assumed) so a hand-edited/nonstandard file still
    /// round-trips exactly what was read.
    var recordType: String
    var pairs: [RawGroupPair]
}

// MARK: - TABLES section (beyond LAYER/LTYPE, which stay in DXFLayer/DXFLinetype)

/// One symbol-table record (VPORT/STYLE/VIEW/UCS/APPID/DIMSTYLE/BLOCK_RECORD)
/// captured generically: handle, owner handle, name, and every other group
/// code verbatim. `typed` holds an optional per-table-type lift for the
/// handful of fields the plan calls out (STYLE font names, DIMSTYLE's
/// variable set, BLOCK_RECORD's layout-handle 340) — always present
/// alongside the raw pairs, never instead of them, so a writer needing a
/// field this struct didn't bother typing can still fall back to `rawPairs`.
struct SymbolRecord: Equatable {
    var tableType: String       // "VPORT", "STYLE", "VIEW", "UCS", "APPID", "DIMSTYLE", "BLOCK_RECORD"
    var name: String            // group 2 (or 3 for some DIMSTYLE contexts — not applicable here)
    var handle: UInt64          // group 5; 0 if absent (rare — R12-era tables could omit it)
    var ownerHandle: UInt64     // group 330; 0 if absent
    var flags: Int              // group 70, when present (0 default)
    /// Every group code NOT already captured into `tableType`/`name`/
    /// `handle`/`ownerHandle` above — includes group 70 again for
    /// convenience of full echo, and everything else verbatim, in file order.
    var rawPairs: [RawGroupPair]
    var typed: TypedTableLift?
}

/// The handful of per-table-type typed lifts the plan calls out. Additive
/// convenience only — `SymbolRecord.rawPairs` always has the full data too.
enum TypedTableLift: Equatable {
    /// STYLE: primary font file name (group 3) and big-font file name
    /// (group 4, empty if none).
    case style(fontFile: String, bigFontFile: String)
    /// DIMSTYLE: the handful of override variables captured as raw (code,
    /// value) pairs (DIMSTYLE has dozens of possible DIM... group codes;
    /// capturing them as a bag rather than ~40 named fields matches the
    /// "breadth over depth" priority — a later phase can promote specific
    /// ones to named fields if/when the writer needs to compute rather than
    /// echo them).
    case dimstyle(overrides: [RawGroupPair])
    /// BLOCK_RECORD: the associated layout's handle (group 340), when this
    /// block record represents a layout block (model space or a paper space
    /// layout) rather than an ordinary block definition.
    case blockRecord(layoutHandle: UInt64?)
}

// MARK: - OBJECTS section

/// One (key, value-handle) entry in a dictionary object, in file order —
/// group 3 (key name) paired with the immediately-following 350/360 (value
/// handle).
struct DictionaryEntry: Equatable {
    var key: String
    var valueHandle: UInt64
}

/// One node in the OBJECTS section's dictionary graph, rooted at the file's
/// Named Object Dictionary. `entries` preserves file order so a writer can
/// re-emit the same key ordering AutoCAD produced.
struct DictionaryObject: Equatable {
    var handle: UInt64
    var ownerHandle: UInt64
    /// True for a "hard owner" dictionary (group 281 == 1 / typical default)
    /// vs. soft-owner — retained verbatim for the writer, not interpreted.
    var hardOwnerFlag: Int?
    var entries: [DictionaryEntry]
    /// Anything else on this dictionary record not already modeled above.
    var rawPairs: [RawGroupPair]
}

/// A minimal typed lift of an `ACAD_LAYOUT` dictionary entry's target object
/// (an actual LAYOUT object elsewhere in OBJECTS) — enough structure for a
/// later phase to find and extend it, not a full plot-settings parse.
struct LayoutObject: Equatable {
    var handle: UInt64
    var ownerHandle: UInt64
    var name: String                    // group 1: layout name
    var blockRecordHandle: UInt64?      // group 330 pointing at the layout's BLOCK_RECORD
    var plotSettingsHandle: UInt64?     // this object doubles as the plot-settings owner in DXF; kept as a
                                         // reference marker, not parsed — see rawPairs for the full record
    var tabOrder: Int?                  // group 71
    var rawPairs: [RawGroupPair]
}

/// A minimal typed lift of an `ACAD_GROUP` dictionary entry's target GROUP
/// object: name/description plus its member entity handles.
struct GroupObject: Equatable {
    var handle: UInt64
    var ownerHandle: UInt64
    var description: String             // group 300
    var isSelectable: Bool              // group 70 (1 = selectable)
    var memberHandles: [UInt64]         // group 340, repeated
    var rawPairs: [RawGroupPair]
}

/// A minimal typed lift of an IMAGEDEF object: file path plus pixel size —
/// enough to resolve/relink an image reference later without a full parse
/// of every image-def group code.
struct ImageDefObject: Equatable {
    var handle: UInt64
    var ownerHandle: UInt64
    var fileName: String                // group 1
    var imageSizePx: ImageSizePx?        // group 10/20
    var rawPairs: [RawGroupPair]
}

struct ImageSizePx: Equatable {
    var w: Double
    var h: Double
}

/// Any OBJECTS-section object this codebase has no typed lift for yet —
/// handle + every group code, verbatim, so it still round-trips through the
/// in-memory model even though nothing here interprets it. This is the
/// fallback every object type not explicitly listed above lands in, so
/// OBJECTS content is never silently dropped.
struct RawObject: Equatable {
    var objectType: String              // the record-start name, e.g. "IMAGEDEF_REACTOR", "MLINESTYLE", "XRECORD"
    var handle: UInt64
    var ownerHandle: UInt64
    var rawPairs: [RawGroupPair]
}

/// The full OBJECTS section graph. `rootDictionaryHandle` is the file's
/// Named Object Dictionary (the very first DICTIONARY object in OBJECTS,
/// always handle-referenced from HEADER's `$DICTIONARY` — in practice the
/// first object emitted). All dictionaries (root and nested, e.g.
/// `ACAD_GROUP`/`ACAD_LAYOUT`/`ACAD_IMAGE_DICT`) are captured in
/// `dictionaries`, keyed by handle, so the graph can be walked from the
/// root. Typed objects are ADDITIONALLY present in `rawObjects` under their
/// own handle (dictionaries are the exception, tracked only in
/// `dictionaries`) so a lookup-by-handle always succeeds regardless of type.
struct ObjectsModel: Equatable {
    var rootDictionaryHandle: UInt64?
    var dictionaries: [UInt64: DictionaryObject] = [:]
    var layouts: [UInt64: LayoutObject] = [:]
    var groups: [UInt64: GroupObject] = [:]
    var imageDefs: [UInt64: ImageDefObject] = [:]
    /// Everything else — the fallback described on `RawObject`.
    var rawObjects: [UInt64: RawObject] = [:]

    var isEmpty: Bool {
        dictionaries.isEmpty && layouts.isEmpty && groups.isEmpty
            && imageDefs.isEmpty && rawObjects.isEmpty
    }

    /// Total object count across every bucket — for diagnostics (`--db-stats`).
    var totalObjectCount: Int {
        dictionaries.count + layouts.count + groups.count + imageDefs.count + rawObjects.count
    }

    /// Count of objects that received a typed lift (everything except
    /// `rawObjects`, which by definition has none) — for diagnostics.
    var typedObjectCount: Int { totalObjectCount - rawObjects.count }
}
