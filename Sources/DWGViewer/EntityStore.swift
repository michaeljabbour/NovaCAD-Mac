import Foundation
import CoreGraphics
import CADCore

// MARK: - Core identity & geometry primitives

/// 24-byte 3D point. Deliberately NOT `SIMD3<Double>` — that type's array
/// stride is 32B due to 16-byte alignment, a 33% memory tax on the vertex
/// arena for nothing (3.4M-entity drawings make that difference real).
/// `Codable` (cross-drawing Copy/Paste): `PasteboardSnapshot.swift` encodes
/// world-space points straight from arena/payload data onto `NSPasteboard`
/// — synthesized for free (all-`Double` fields) and has zero cost for every
/// existing non-serializing caller (hot-path vertex arenas neither know nor
/// care that the element type happens to also conform to `Codable`).
struct Vec3: Equatable, Codable {
    var x, y, z: Double
    init(x: Double, y: Double, z: Double = 0) { self.x = x; self.y = y; self.z = z }
    init(_ p: CGPoint, z: Double = 0) { x = Double(p.x); y = Double(p.y); self.z = z }
    var cgPoint: CGPoint { CGPoint(x: x, y: y) }
    var length: Double { (x * x + y * y + z * z).squareRoot() }
}

/// Stable identity for one entity: a slot index into `EntityStore.headers`.
/// Slots are tombstoned (via `EntityHeader.flags.deleted`) on delete, never
/// reused within a session — compaction only happens at save time (a later
/// phase), so an `EntityID` a caller is holding never silently starts
/// referring to a different entity.
/// `Codable` (Phase 6.4): ARRAY's `ArrayDefinition` round-trips through
/// JSON for XDATA persistence (see `Editing/ArrayTool.swift`) and needs to
/// serialize the `EntityID`s it tracks — a trivial, purely additive
/// single-`Int32` encoding, safe for a type whose only other conformance is
/// `Hashable`.
struct EntityID: Hashable, Codable {
    var raw: Int32
}

/// SpaceID is provided by CADCore (public enum SpaceID: model, paper)

/// Every DXF entity type this database can hold. `.unknown` covers types the
/// parser round-trips verbatim (residual group codes only, no typed
/// payload) — round-tripped for fidelity, not rendered or editable.
/// `Codable` (cross-drawing Copy/Paste): `PasteboardSnapshot.PastedEntity`
/// carries this enum directly rather than re-deriving it from a name string
/// — automatic `RawRepresentable`-backed `Codable` conformance costs
/// nothing for every existing caller (this is a fixed, append-only case
/// list within one shipped app, not a long-lived external file format, so a
/// raw `UInt8` encoding carries no forward-compatibility risk here).
enum DXFEntityType: UInt8, Codable {
    case line, point, circle, arc, ellipse
    case lwpolyline, polyline2d, polyline3d
    case spline, solid, trace, face3d, hatch
    case text, mtext, attdef, attrib
    case insert, dimension, leader, mleader
    case xline, ray, wipeout, image, viewport, acadTable
    case unknown
}

struct EntityFlags: OptionSet {
    let rawValue: UInt8
    static let deleted     = EntityFlags(rawValue: 1 << 0)
    static let invisible   = EntityFlags(rawValue: 1 << 1)
    static let paperSpace  = EntityFlags(rawValue: 1 << 2)   // mirrors owner.isPaper; kept for a fast bit-test in hot loops
    static let hasXData    = EntityFlags(rawValue: 1 << 3)
    static let hasResidual = EntityFlags(rawValue: 1 << 4)
    static let mirrorOCS   = EntityFlags(rawValue: 1 << 5)   // extrusion Z < 0 (mirrored block/entity)
}

/// Who owns an entity: a block definition (>= 0, index into
/// `EditableDocument.blocks`), the model or paper space root, or — for
/// ATTRIB/VERTEX children — the parent entity they belong to.
struct OwnerRef: Equatable {
    var raw: Int32

    static let model = OwnerRef(raw: -1)
    static let paper = OwnerRef(raw: -2)
    static func block(_ index: Int32) -> OwnerRef { OwnerRef(raw: index) }
    static func parentEntity(_ id: EntityID) -> OwnerRef { OwnerRef(raw: -3 - id.raw) }

    var isBlock: Bool { raw >= 0 }
    var isModel: Bool { raw == -1 }
    var isPaper: Bool { raw == -2 }
    var parentEntityID: EntityID? { raw <= -3 ? EntityID(raw: -3 - raw) : nil }
}

/// 48-byte fixed header, one per entity, in a flat array — the hot-path data
/// every query touches. Per-type geometry lives in the payload arrays below,
/// indexed by `payload`.
struct EntityHeader {
    var handle: UInt64            // 0 = none parsed yet (R12 sources / not-yet-saved new entities); allocated at save
    var type: DXFEntityType
    var flags: EntityFlags = []
    var layerId: Int32
    var aci: Int16 = 256           // 256 = BYLAYER, 0 = BYBLOCK
    var trueColor: UInt32 = 0xFF00_0000   // top byte 0xFF = "no true color set"
    var linetypeId: Int16 = -1     // -1 = BYLAYER, -2 = BYBLOCK
    var lineweight: Int16 = -1     // -1 BYLAYER, -2 BYBLOCK, -3 default; else 1/100 mm
    var owner: OwnerRef = .model
    var payload: Int32 = -1        // index into the per-type payload array named by `type`; -1 = none (.unknown)
    var ltScale: Float = 1.0
}

// MARK: - Per-type payloads

struct LinePayload { var a, b: Vec3 }
struct PointPayload { var p: Vec3 }
struct CirclePayload { var center: Vec3; var radius: Double; var extrusionZ: Double = 1.0 }
struct ArcPayload {
    var center: Vec3; var radius: Double
    var startAngleDeg: Double; var endAngleDeg: Double   // CCW sweep, matches today's StrokeStore.Arc convention
    var extrusionZ: Double = 1.0
}
struct EllipsePayload {
    var center: Vec3
    var majorAxisEndpoint: Vec3    // center -> major-axis endpoint, world space
    var ratio: Double              // minor/major
    var startParam: Double         // DXF parametric angle, NOT the geometric angle
    var endParam: Double
}
/// Vertex/bulge data lives in `EntityStore.vertexArena`/`scalarArena`
/// (`vertsStart..<vertsStart+vertsCount`, `bulgesStart` parallel to it — 0
/// bulge = straight segment). Covers LWPOLYLINE (`is3D == false`) and legacy
/// POLYLINE 2D/3D.
struct PolylinePayload {
    var vertsStart: Int32 = 0; var vertsCount: Int32 = 0
    var bulgesStart: Int32 = 0    // same count as vertsCount
    var closed: Bool = false
    var constantWidth: Double = 0
    var elevation: Double = 0
    var is3D: Bool = false
}
/// Control points / knots / weights live in `vertexArena`/`scalarArena`.
/// Empty weight range = non-rational (all weights implicitly 1).
struct SplinePayload {
    var degree: Int32 = 3
    var controlStart: Int32 = 0; var controlCount: Int32 = 0
    var knotStart: Int32 = 0; var knotCount: Int32 = 0
    var weightStart: Int32 = 0     // same count as controlCount, or 0-length range if non-rational
    var weightCount: Int32 = 0
    var closed: Bool = false
}
struct TextPayload {
    var position: Vec3
    var alignPosition: Vec3 = Vec3(x: 0, y: 0)   // secondary alignment point (group 11)
    var height: Double
    var rotationDeg: Double = 0
    var widthFactor: Double = 1
    var obliqueDeg: Double = 0
    var stringId: Int32            // into EntityStore.strings — TEXT/ATTRIB/ATTDEF's VALUE (group 1)
    var styleNameId: Int32 = -1    // into EntityStore.strings; -1 = "STANDARD"
    var hAlign: Int16 = 0
    var vAlign: Int16 = 0
    var isBackwards: Bool = false
    var isUpsideDown: Bool = false
    /// Phase 6.1 (BlockEditor): ATTDEF/ATTRIB's TAG (DXF group 2), kept
    /// separate from `stringId`'s VALUE text. -1 (the default, and the only
    /// value any TEXT/pre-Phase-6.1 ATTRIB/ATTDEF ever has, since the parser
    /// doesn't retain ATTDEF at all yet and ATTRIB parsing never populated
    /// this) means "no distinct tag" — `EntityRecordWriter.writeAttribLike`
    /// (a frozen file, per this project's writer-subsystem constraint) is
    /// UNCHANGED by this addition and still derives a tag from `stringId`'s
    /// text via `sanitizeTag` for any entity that leaves this at -1, exactly
    /// as it always has; a real distinct tag set here is simply available
    /// for BlockEditor/the attribute editor to look ATTRIBs up by tag
    /// in-memory (`EditableDocument.attributeTag(for:)`) without forcing a
    /// value-derived tag through `sanitizeTag`'s lossy transform first.
    /// `promptStringId` (ATTDEF only) is the DXF group-3 prompt shown to the
    /// user during INSERT's attribute-value prompt sequence; -1 = no prompt.
    var tagStringId: Int32 = -1
    var promptStringId: Int32 = -1
}
struct MTextPayload {
    var insertion: Vec3
    var height: Double
    var refWidth: Double = 0
    var rotationDeg: Double = 0
    var attachPoint: Int16 = 1
    var stringId: Int32            // RAW mtext string (formatting codes retained verbatim; stripped only at regen)
    var styleNameId: Int32 = -1
}
struct InsertPayload {
    var blockNameId: Int32          // into EntityStore.strings; resolved to a BlockRecord by EditableDocument
    var position: Vec3
    var scale: Vec3 = Vec3(x: 1, y: 1, z: 1)
    var rotationDeg: Double = 0
    var cols: Int32 = 1; var rows: Int32 = 1
    var colSpacing: Double = 0; var rowSpacing: Double = 0
    /// -1 = no override (the common case). A purely COSMETIC, app-only
    /// display name for this ONE INSERT instance — set via Data
    /// Extraction's editable `blockName` column (see `DataExtraction.swift`)
    /// or `BlockEditor.setDisplayName`. Deliberately NEVER read by
    /// `Regenerator`/`Explode`/`EntityRecordWriter`'s geometry-resolution
    /// paths (those all resolve the block DEFINITION — and therefore the
    /// actual drawn geometry — solely via `blockNameId`, unchanged) — this
    /// field exists ONLY so a user can give one specific object instance a
    /// human-readable label (e.g. relabeling a workstation's identifying
    /// name) WITHOUT retargeting which block definition it draws, matching
    /// the explicit product decision that changing this must never alter
    /// the displayed object. Read by `DataExtraction.extractRows`'s
    /// `blockName` column and `AIToolExecutor`'s drawing summary, both of
    /// which fall back to `blockNameId`'s real name when this is -1.
    var displayNameId: Int32 = -1
}
/// Loop geometry lives in `hatchLoopRanges` + `vertexArena` as tessellated
/// point loops — matching the CURRENT parser's fidelity (it already
/// tessellates arcs into the boundary). Phase 7's hatch engine upgrades this
/// to typed edges (line/arc/ellipse/spline) for exact re-serialization;
/// nothing downstream depends on that yet.
struct HatchPayload {
    var patternNameId: Int32 = -1   // -1 = SOLID
    var isSolid: Bool
    var angle: Double = 0
    var scale: Double = 1
    var origin: Vec3 = Vec3(x: 0, y: 0)
    var loopRangeStart: Int32 = 0; var loopRangeCount: Int32 = 0
    var associative: Bool = false
    /// This hatch's OWN 0-100% transparency (AutoCAD's convention: 0 =
    /// opaque, 100 = fully invisible-but-still-selectable), independent of
    /// `DXFLayer.transparency` (`CGRenderCore.fillAlpha`'s layer-level
    /// lookup) — the two multiply together at render time (see
    /// `CGRenderCore`'s hatch fill pass), matching real DXF semantics where
    /// an entity's own transparency (group 440 on the ENTITY, distinct from
    /// the group 440 on its LAYER table entry) layers on top of the layer's.
    /// Deliberately scoped to HATCH ONLY rather than added to the generic
    /// `EntityHeader` shared by every entity type: per-entity transparency
    /// for every line/circle/text would touch the render GROUP KEY
    /// (`Regenerator.GroupKey`) app-wide, multiplying render-group count
    /// (hence memory/perf) across the whole renderer for a property only
    /// fill areas asked for. Living in `HatchPayload` instead costs nothing
    /// extra for non-hatch entities, and a HATCH's own fillPath is already
    /// drawn as one CGPath per RenderGroup fill pass, so per-hatch alpha
    /// varying WITHIN a shared-color group is handled by
    /// `CGRenderCore`'s hatch pass reading this field per fill rather than
    /// needing its own additional GroupKey dimension.
    var transparency: Double = 0
}
struct HatchLoopRange { var vertStart: Int32; var vertCount: Int32 }

struct ImagePayload {
    var origin: Vec3
    var uVector: Vec3; var vVector: Vec3
    var sizePxWidth: Double; var sizePxHeight: Double
    var imageDefHandle: UInt64 = 0
    var displayFlags: Int = 3
    var clipping = false
    var clipVertices: [Vec3] = []
    var clipInverted = false
    var brightness: Int = 50
    var contrast: Int = 50
    var fade: Int = 0
}
/// Placeholder shape for Phase 11 (layouts/viewports) — kept minimal since
/// nothing consumes it yet; the real field set is designed there.
struct ViewportPayload {
    var centerPaper: Vec3
    var widthPaper: Double; var heightPaper: Double
    var viewCenter: Vec3; var viewHeight: Double
    var twistDeg: Double = 0
    var status: Int32 = 1
    var viewportID: Int = 0
    var flags: Int = 0
    var target = Vec3(x: 0, y: 0, z: 0)
    var direction = Vec3(x: 0, y: 0, z: 1)
    var frozenLayerHandles: [UInt64] = []
    var clipHandle: UInt64 = 0
}
/// Retained as an INSERT-like block reference today, matching current parser
/// behavior (DIMENSION renders via its anonymous block). Full dimension
/// authoring is a later phase; this is just enough to round-trip.
struct DimensionPayload {
    var blockNameId: Int32
    var defPoint: Vec3
    var dimStyleNameId: Int32 = -1
    var textOverrideId: Int32 = -1   // -1 = none (use measured value)
}

// MARK: - Sparse per-entity extras

enum XDataValue: Equatable {
    case string(String), double(Double), int(Int32), handle(UInt64)
}
struct XDataBlob {
    var appId: String
    var pairs: [(code: Int16, value: XDataValue)]
}
/// Unknown/unrecognized DXF group-code pairs on an otherwise-typed entity,
/// or the entire record for an `.unknown`-typed one — retained verbatim so
/// the structural writer (Phase 3) can echo them back unchanged.
struct RawPairBlob {
    var pairs: [(code: Int16, value: String)]
}

// MARK: - Prototype / image (add & undo payloads)

/// One payload value, tagged by entity type, carrying its own arena data
/// alongside it (rather than pre-existing arena indices) — the form both a
/// brand-new entity (`EntityPrototype`) and a captured-for-undo snapshot
/// (`EntityImage`) need.
enum EntityPayloadCopy {
    case line(LinePayload)
    case point(PointPayload)
    case circle(CirclePayload)
    case arc(ArcPayload)
    case ellipse(EllipsePayload)
    case polyline(PolylinePayload, vertices: [Vec3], bulges: [Double])
    case spline(SplinePayload, control: [Vec3], knots: [Double], weights: [Double])
    case text(TextPayload)
    case mtext(MTextPayload)
    case insert(InsertPayload)
    case hatch(HatchPayload, loops: [[Vec3]])
    case image(ImagePayload)
    case viewport(ViewportPayload)
    case dimension(DimensionPayload)
    case unknown
}

extension EntityPayloadCopy {
    /// In-place translation of any payload shape that has world-space
    /// coordinates, by a world-space delta — the general-purpose "move any
    /// entity" primitive `Transaction.modifyPayload` bodies use (the live
    /// app's Move tool, Phase 1.7). Every loop/control/vertex point moves,
    /// so this is correct for compound shapes (polylines, splines, hatch
    /// loops), not just single-point ones; `.unknown` (residual/unsupported
    /// entities) is a no-op.
    mutating func translate(dx: Double, dy: Double) {
        func t(_ v: Vec3) -> Vec3 { Vec3(x: v.x + dx, y: v.y + dy, z: v.z) }
        switch self {
        case .line(var p): p.a = t(p.a); p.b = t(p.b); self = .line(p)
        case .point(var p): p.p = t(p.p); self = .point(p)
        case .circle(var p): p.center = t(p.center); self = .circle(p)
        case .arc(var p): p.center = t(p.center); self = .arc(p)
        case .ellipse(var p): p.center = t(p.center); self = .ellipse(p)
        case .polyline(let p, var verts, let bulges):
            for i in verts.indices { verts[i] = t(verts[i]) }
            self = .polyline(p, vertices: verts, bulges: bulges)
        case .spline(let p, var control, let knots, let weights):
            for i in control.indices { control[i] = t(control[i]) }
            self = .spline(p, control: control, knots: knots, weights: weights)
        case .text(var p): p.position = t(p.position); p.alignPosition = t(p.alignPosition); self = .text(p)
        case .mtext(var p): p.insertion = t(p.insertion); self = .mtext(p)
        case .insert(var p): p.position = t(p.position); self = .insert(p)
        case .hatch(var p, var loops):
            p.origin = t(p.origin)
            for i in loops.indices { for j in loops[i].indices { loops[i][j] = t(loops[i][j]) } }
            self = .hatch(p, loops: loops)
        case .image(var p): p.origin = t(p.origin); self = .image(p)
        case .viewport(var p): p.centerPaper = t(p.centerPaper); self = .viewport(p)
        case .dimension(var p): p.defPoint = t(p.defPoint); self = .dimension(p)
        case .unknown: break
        }
    }
}

/// Describes a brand-new entity to create. `EntityStore.append(_:)` stores
/// the payload into the right typed array and appends a header pointing at
/// it.
struct EntityPrototype {
    var type: DXFEntityType
    var layerId: Int32
    var aci: Int16 = 256
    var trueColor: UInt32 = 0xFF00_0000
    var linetypeId: Int16 = -1
    var lineweight: Int16 = -1
    var owner: OwnerRef = .model
    var ltScale: Float = 1.0
    var payload: EntityPayloadCopy
}

/// A self-contained snapshot of one entity (header + payload + its arena
/// data) — enough to fully restore it via `EntityStore.restore(_:_:)`. Used
/// by undo/redo: proportional in size to ONE entity, not the whole document.
struct EntityImage {
    var header: EntityHeader
    var payloadCopy: EntityPayloadCopy

    /// Phase 4.2 (COPY command): turns this snapshot into an `EntityPrototype`
    /// `Transaction.add` can insert as a brand-new entity — the "clone an
    /// existing entity's properties+geometry" primitive COPY needs and that
    /// nothing before this phase required (every prior `Transaction.add`
    /// call site builds a prototype from scratch: drafting tools, stamps,
    /// xref transplant). `owner` defaults to the source entity's own owner
    /// (copy-in-place, same space/block) — COPY always passes the ambient
    /// space explicitly since the destination might differ (e.g. copying
    /// paper-space markup) even though today's command layer always copies
    /// within the same space the selection was made in.
    func asPrototype(owner: OwnerRef? = nil) -> EntityPrototype {
        EntityPrototype(type: header.type, layerId: header.layerId, aci: header.aci,
                        trueColor: header.trueColor, linetypeId: header.linetypeId,
                        lineweight: header.lineweight, owner: owner ?? header.owner,
                        ltScale: header.ltScale, payload: payloadCopy)
    }
}

// MARK: - EntityStore

/// The retained, mutable entity database — replaces the old freed-after-load
/// `RawEntity` model. Struct-of-arrays layout: one flat `headers` array plus
/// one array per entity type, so a 2.5M-entity drawing's hot fields (layer,
/// color, type, owner) stay densely packed instead of scattered across
/// per-entity heap objects.
///
/// Mutation is intended to happen ONLY through `Transaction` (Transactions.swift)
/// once that lands, so every edit is undoable and the regenerator gets
/// notified — but the primitives here (`append`, `markDeleted`, `restore`,
/// `setHeader`) are the mechanism Transaction is built on, not something it
/// wraps opaquely.
final class EntityStore {
    private(set) var headers: [EntityHeader] = []

    var lines: [LinePayload] = []
    var points: [PointPayload] = []
    var circles: [CirclePayload] = []
    var arcs: [ArcPayload] = []
    var ellipses: [EllipsePayload] = []
    var polylines: [PolylinePayload] = []
    var splines: [SplinePayload] = []
    var texts: [TextPayload] = []
    var mtexts: [MTextPayload] = []
    var inserts: [InsertPayload] = []
    var hatches: [HatchPayload] = []
    var images: [ImagePayload] = []
    var viewports: [ViewportPayload] = []
    var dimensions: [DimensionPayload] = []

    var vertexArena: [Vec3] = []
    var scalarArena: [Double] = []
    var hatchLoopRanges: [HatchLoopRange] = []
    let strings = StringTable()

    /// Sparse; only entities that actually have XDATA/residual pairs appear
    /// here — the overwhelming majority of entities in a real drawing don't.
    var xdata: [Int32: XDataBlob] = [:]
    var residualPairs: [Int32: RawPairBlob] = [:]

    private var handleIndex: [UInt64: Int32]? = nil

    var count: Int { headers.count }

    // MARK: - Checkpoint (Phase 1.8 `--edit-script save`/`load`)

    /// A self-contained snapshot of the ENTIRE store — every header, every
    /// typed payload array, both arenas, the string table, and the sparse
    /// XDATA/residual maps. Not a general persistence format (there is no
    /// disk serialization here — Phase 3's DXF writer is the real "save my
    /// drawing" feature); this exists solely so `--edit-script`'s `save`/
    /// `compact` interplay can be tested: checkpoint, mutate further,
    /// compact, then verify a restore still resolves the same `EntityID`s to
    /// the same geometry. Proportional in cost to the WHOLE store (all
    /// arrays are value types, so this is a series of O(n) array copies, not
    /// a deep per-element clone) — deliberately not something `RegenCoordinator`
    /// calls on every commit.
    struct Checkpoint {
        fileprivate var headers: [EntityHeader]
        fileprivate var lines: [LinePayload]
        fileprivate var points: [PointPayload]
        fileprivate var circles: [CirclePayload]
        fileprivate var arcs: [ArcPayload]
        fileprivate var ellipses: [EllipsePayload]
        fileprivate var polylines: [PolylinePayload]
        fileprivate var splines: [SplinePayload]
        fileprivate var texts: [TextPayload]
        fileprivate var mtexts: [MTextPayload]
        fileprivate var inserts: [InsertPayload]
        fileprivate var hatches: [HatchPayload]
        fileprivate var images: [ImagePayload]
        fileprivate var viewports: [ViewportPayload]
        fileprivate var dimensions: [DimensionPayload]
        fileprivate var vertexArena: [Vec3]
        fileprivate var scalarArena: [Double]
        fileprivate var hatchLoopRanges: [HatchLoopRange]
        fileprivate var stringTable: StringTable
        fileprivate var xdata: [Int32: XDataBlob]
        fileprivate var residualPairs: [Int32: RawPairBlob]
        /// Entity count at checkpoint time — exposed for `assert-count`-style
        /// verification without needing a live `EntityStore` reference.
        var entityCount: Int { headers.count }
    }

    func checkpoint() -> Checkpoint {
        Checkpoint(headers: headers, lines: lines, points: points, circles: circles, arcs: arcs,
                  ellipses: ellipses, polylines: polylines, splines: splines, texts: texts,
                  mtexts: mtexts, inserts: inserts, hatches: hatches, images: images,
                  viewports: viewports, dimensions: dimensions, vertexArena: vertexArena,
                  scalarArena: scalarArena, hatchLoopRanges: hatchLoopRanges,
                  stringTable: strings.clone(), xdata: xdata, residualPairs: residualPairs)
    }

    /// Overwrites every array in this store with `checkpoint`'s contents.
    /// `EntityID`s captured before the checkpoint remain valid afterward IFF
    /// they were already part of the checkpointed state (identical slot
    /// indices) — restoring to an OLDER checkpoint after further edits
    /// legitimately invalidates any `EntityID` created after that point,
    /// same as any other undo-past-that-edit would.
    func restore(fromCheckpoint checkpoint: Checkpoint) {
        headers = checkpoint.headers
        lines = checkpoint.lines
        points = checkpoint.points
        circles = checkpoint.circles
        arcs = checkpoint.arcs
        ellipses = checkpoint.ellipses
        polylines = checkpoint.polylines
        splines = checkpoint.splines
        texts = checkpoint.texts
        mtexts = checkpoint.mtexts
        inserts = checkpoint.inserts
        hatches = checkpoint.hatches
        images = checkpoint.images
        viewports = checkpoint.viewports
        dimensions = checkpoint.dimensions
        vertexArena = checkpoint.vertexArena
        scalarArena = checkpoint.scalarArena
        hatchLoopRanges = checkpoint.hatchLoopRanges
        strings.replaceContents(with: checkpoint.stringTable)
        xdata = checkpoint.xdata
        residualPairs = checkpoint.residualPairs
        handleIndex = nil   // rebuilt lazily on next `entity(forHandle:)` call
    }

    // MARK: Lookup

    func header(_ id: EntityID) -> EntityHeader? {
        guard let i = index(of: id) else { return nil }
        return headers[i]
    }

    func isDeleted(_ id: EntityID) -> Bool {
        guard let i = index(of: id) else { return true }
        return headers[i].flags.contains(.deleted)
    }

    /// Lazy flat map, built on first use and kept in sync incrementally by
    /// `appendHeader`/`restore` afterward.
    func entity(forHandle handle: UInt64) -> EntityID? {
        guard handle != 0 else { return nil }
        if handleIndex == nil { rebuildHandleIndex() }
        guard let slot = handleIndex?[handle] else { return nil }
        return EntityID(raw: slot)
    }

    private func rebuildHandleIndex() {
        var m: [UInt64: Int32] = [:]
        m.reserveCapacity(headers.count)
        for (i, h) in headers.enumerated() where h.handle != 0 {
            m[h.handle] = Int32(i)
        }
        handleIndex = m
    }

    private func index(of id: EntityID) -> Int? {
        let i = Int(id.raw)
        guard i >= 0, i < headers.count else { return nil }
        return i
    }

    // MARK: Mutation primitives (called by Transaction)

    @discardableResult
    func appendHeader(_ header: EntityHeader) -> EntityID {
        let id = EntityID(raw: Int32(headers.count))
        headers.append(header)
        if header.handle != 0 { handleIndex?[header.handle] = id.raw }
        return id
    }

    @discardableResult
    func append(_ proto: EntityPrototype) -> EntityID {
        let payloadIndex = storePayload(proto.payload)
        let header = EntityHeader(handle: 0, type: proto.type, flags: proto.owner.isPaper ? [.paperSpace] : [],
                                  layerId: proto.layerId, aci: proto.aci, trueColor: proto.trueColor,
                                  linetypeId: proto.linetypeId, lineweight: proto.lineweight,
                                  owner: proto.owner, payload: payloadIndex, ltScale: proto.ltScale)
        return appendHeader(header)
    }

    func markDeleted(_ id: EntityID) {
        guard let i = index(of: id) else { return }
        headers[i].flags.insert(.deleted)
    }

    /// Clears the tombstone flag set by `markDeleted` — deletion never
    /// actually removes array data, so this is all "redo of a delete's
    /// undo" (i.e. redo-of-add) needs.
    func undelete(_ id: EntityID) {
        guard let i = index(of: id) else { return }
        headers[i].flags.remove(.deleted)
    }

    func setHeader(_ id: EntityID, _ body: (inout EntityHeader) -> Void) {
        guard let i = index(of: id) else { return }
        body(&headers[i])
    }

    /// Captures a self-contained image of `id` for undo — proportional to
    /// one entity's data, not the whole store.
    func snapshot(_ id: EntityID) -> EntityImage? {
        guard let h = header(id) else { return nil }
        return EntityImage(header: h, payloadCopy: copyPayload(h))
    }

    /// Restores `id` to the state captured in `image` (used by undo, for
    /// both "un-delete" and "revert a modify"). Overwrites the payload
    /// in-place at the entity's existing arena range when the shape matches
    /// exactly (always true for property-only edits — TRIM/EXPLODE-style
    /// structural changes go through `Transaction.replace`, a delete+add
    /// pair, not `restore`); falls back to appending a fresh arena range
    /// (harmlessly leaking the old one — reclaimed only at save-time
    /// compaction, a later phase) if it doesn't.
    func restore(_ id: EntityID, _ image: EntityImage) {
        guard let i = index(of: id) else { return }
        var h = image.header
        h.payload = writePayload(image.payloadCopy, overExisting: headers[i])
        headers[i] = h
        if h.handle != 0 { handleIndex?[h.handle] = id.raw }
    }

    // MARK: Cross-store transplant (xref merge — additive, Phase 1.x package loading)

    /// Copies entity `id` from `other` into `self`, remapping its
    /// layer/linetype ids and (for INSERT) its block-name reference, and
    /// appending it under `owner`. Used by `PackageLoader.loadIntoStore` to
    /// transplant a resolved xref file's entities into the host store —
    /// the `EntityStore`-level equivalent of `PackageLoader.merge`'s
    /// `RawEntity` remap-and-append.
    ///
    /// Deliberately drops the source handle (sets 0 on the copy): handles
    /// are scoped per-DXF-file, so blindly preserving them across a merge
    /// of N files risks silent collisions in `entity(forHandle:)`'s shared
    /// index. This matches the OLD path's fidelity exactly — `RawEntity`
    /// never carried a handle at all, so merged content was always
    /// handle-less there too. XDATA and residual pairs (which never key off
    /// the handle) are copied verbatim.
    @discardableResult
    func appendCopy(of id: EntityID, from other: EntityStore,
                    remapLayer: (Int32) -> Int32,
                    remapLinetype: (Int16) -> Int16,
                    remapBlockName: ((String) -> String)? = nil,
                    owner: OwnerRef) -> EntityID? {
        guard let src = other.header(id) else { return nil }
        var h = src
        h.handle = 0
        h.layerId = remapLayer(src.layerId)
        if src.linetypeId >= 0 { h.linetypeId = remapLinetype(src.linetypeId) }
        h.owner = owner

        var payloadCopy = other.copyPayload(src)
        if src.type == .insert, case .insert(var ip) = payloadCopy {
            if let remap = remapBlockName {
                let name = other.strings.string(for: ip.blockNameId)
                ip.blockNameId = strings.intern(remap(name))
            }
            // `displayNameId` is a plain cosmetic string, never remapped
            // through `remapBlockName` (it doesn't NAME a block — see its
            // own doc comment) — just re-interned into the destination's
            // own `StringTable`, same as every other string field below.
            if ip.displayNameId >= 0 {
                ip.displayNameId = strings.intern(other.strings.string(for: ip.displayNameId))
            }
            payloadCopy = .insert(ip)
        }
        // Every OTHER string-table reference a payload can carry — TEXT/
        // ATTRIB/ATTDEF's value/style/tag/prompt, MTEXT's raw string/style,
        // HATCH's pattern name — is likewise an index into `other`'s own
        // `StringTable`, not `self`'s. Left unremapped, these silently
        // pointed at whatever string happened to sit at that same numeric
        // index in the DESTINATION's own (unrelated) table — garbage text,
        // or (once out of that table's range) `StringTable.string(for:)`'s
        // empty-string fallback — for ANY appendCopy'd TEXT/MTEXT/ATTRIB/
        // ATTDEF/HATCH. Caught only now (no existing xref test fixture
        // happens to contain a TEXT/MTEXT/ATTRIB entity — see
        // `XrefAttachTests`/`XrefMergeTests`'s fixtures) despite this
        // function backing BOTH the shipped xref-merge/attach paths AND
        // (from this point on) cross-document paste, so it's fixed here
        // once for every caller rather than patched per-caller.
        @inline(__always) func reinternString(_ id: Int32) -> Int32 {
            id >= 0 ? strings.intern(other.strings.string(for: id)) : id
        }
        switch payloadCopy {
        case .text(var p):
            p.stringId = reinternString(p.stringId)
            p.styleNameId = reinternString(p.styleNameId)
            p.tagStringId = reinternString(p.tagStringId)
            p.promptStringId = reinternString(p.promptStringId)
            payloadCopy = .text(p)
        case .mtext(var p):
            p.stringId = reinternString(p.stringId)
            p.styleNameId = reinternString(p.styleNameId)
            payloadCopy = .mtext(p)
        case .hatch(var p, let loops):
            p.patternNameId = reinternString(p.patternNameId)
            payloadCopy = .hatch(p, loops: loops)
        default:
            break
        }
        h.payload = storePayload(payloadCopy)

        let newId = appendHeader(h)
        if let xdata = other.xdata[id.raw] {
            self.xdata[newId.raw] = xdata
        }
        if let residual = other.residualPairs[id.raw] {
            self.residualPairs[newId.raw] = residual
        }
        return newId
    }

    // MARK: Geometry queries

    /// World-space bounding box of `id`'s own geometry — does NOT account
    /// for any owning INSERT's transform (callers wanting fully-transformed
    /// block-content bounds go through the regenerator, not this).
    func bounds(_ id: EntityID) -> CGRect {
        guard let h = header(id) else { return .zero }
        func pointRect(_ p: Vec3) -> CGRect { CGRect(origin: p.cgPoint, size: .zero) }
        func rangeRect(start: Int32, count: Int32) -> CGRect {
            guard count > 0 else { return .zero }
            var minX = Double.greatestFiniteMagnitude, minY = Double.greatestFiniteMagnitude
            var maxX = -Double.greatestFiniteMagnitude, maxY = -Double.greatestFiniteMagnitude
            for k in 0..<Int(count) {
                let v = vertexArena[Int(start) + k]
                minX = min(minX, v.x); maxX = max(maxX, v.x)
                minY = min(minY, v.y); maxY = max(maxY, v.y)
            }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
        switch h.type {
        case .line:
            guard h.payload >= 0 else { return .zero }
            let p = lines[Int(h.payload)]
            return pointRect(p.a).union(pointRect(p.b))
        case .point:
            guard h.payload >= 0 else { return .zero }
            return pointRect(points[Int(h.payload)].p)
        case .circle:
            guard h.payload >= 0 else { return .zero }
            let c = circles[Int(h.payload)]
            return CGRect(x: c.center.x - c.radius, y: c.center.y - c.radius,
                         width: c.radius * 2, height: c.radius * 2)
        case .arc:
            guard h.payload >= 0 else { return .zero }
            // Conservative full-circle bbox; exact sweep-bound bbox is a later refinement.
            let a = arcs[Int(h.payload)]
            return CGRect(x: a.center.x - a.radius, y: a.center.y - a.radius,
                         width: a.radius * 2, height: a.radius * 2)
        case .ellipse:
            guard h.payload >= 0 else { return .zero }
            let e = ellipses[Int(h.payload)]
            let extent = max(e.majorAxisEndpoint.length, e.majorAxisEndpoint.length * e.ratio)
            return CGRect(x: e.center.x - extent, y: e.center.y - extent, width: extent * 2, height: extent * 2)
        case .lwpolyline, .polyline2d, .polyline3d, .solid, .trace, .face3d, .leader:
            // SOLID/TRACE/3DFACE are stored as a closed vertex loop reusing
            // PolylinePayload's shape (see EntityStoreParser) — same bounds
            // computation as an actual polyline.
            guard h.payload >= 0 else { return .zero }
            let p = polylines[Int(h.payload)]
            return rangeRect(start: p.vertsStart, count: p.vertsCount)
        case .spline:
            // Control-polygon hull — conservative, not tight (a spline's true
            // extent lies within its control polygon's convex hull).
            guard h.payload >= 0 else { return .zero }
            let s = splines[Int(h.payload)]
            return rangeRect(start: s.controlStart, count: s.controlCount)
        case .text, .attrib, .attdef:
            // ATTRIB/ATTDEF share TextPayload's storage with TEXT — see the
            // matching note on `copyPayload`/`writePayload`.
            guard h.payload >= 0 else { return .zero }
            return pointRect(texts[Int(h.payload)].position)
        case .mtext:
            guard h.payload >= 0 else { return .zero }
            return pointRect(mtexts[Int(h.payload)].insertion)
        case .insert:
            guard h.payload >= 0 else { return .zero }
            return pointRect(inserts[Int(h.payload)].position)
        case .hatch:
            guard h.payload >= 0 else { return .zero }
            let hp = hatches[Int(h.payload)]
            var result = CGRect.null
            for r in Int(hp.loopRangeStart)..<Int(hp.loopRangeStart + hp.loopRangeCount) {
                let range = hatchLoopRanges[r]
                result = result.union(rangeRect(start: range.vertStart, count: range.vertCount))
            }
            return result
        default:
            return .zero
        }
    }

    /// Naive linear scan over non-deleted entities in `space` whose bounds
    /// intersect `region`. Correctness baseline for Phase 1.6's spatial-grid
    /// index (not yet built) to be checked against — O(n), fine for tests
    /// and small documents, not yet suitable for the 2.5M-entity case.
    func entities(in region: CGRect, space: SpaceID) -> [EntityID] {
        var result: [EntityID] = []
        for i in headers.indices {
            let h = headers[i]
            guard !h.flags.contains(.deleted) else { continue }
            guard spaceMatches(h.owner, space) else { continue }
            let id = EntityID(raw: Int32(i))
            guard bounds(id).intersects(region) else { continue }
            result.append(id)
        }
        return result
    }

    private func spaceMatches(_ owner: OwnerRef, _ space: SpaceID) -> Bool {
        switch space {
        case .model: return owner.isModel
        case .paper: return owner.isPaper
        }
    }

    /// ATTRIB/VERTEX-style children of `id` (e.g. an INSERT's ATTRIBs),
    /// found by owner back-reference. Linear scan for now — once entities
    /// are appended contiguously by the parser/transactions, a direct
    /// (start, count) range on the parent's payload can replace this.
    func children(of id: EntityID) -> [EntityID] {
        headers.indices.compactMap { i -> EntityID? in
            let h = headers[i]
            guard !h.flags.contains(.deleted), h.owner.parentEntityID == id else { return nil }
            return EntityID(raw: Int32(i))
        }
    }

    /// EVERY `.parentEntity`-owned child in the whole store, keyed by PARENT
    /// `EntityID.raw`, built in ONE O(n) pass — the bulk-scale replacement
    /// for calling `children(of:)` in a loop.
    ///
    /// `children(of:)` above is a FULL linear scan of every header. That is
    /// fine for its UI-driven call sites (one lookup per user click), but
    /// calling it once per entity turns a bulk walk into O(n^2). At xref-
    /// merge scale that is catastrophic rather than merely slow: on a real
    /// production eTransmit package (33 xrefs, ~14M entities) the per-entity
    /// `children(of:)` call in `PackageLoader+Store.mergeIntoStore`'s
    /// `copyWithAttributeChildren` measured 1.6e13+ header reads — a
    /// multi-HOUR apparent hang, reproduced and confirmed by stack-sampling
    /// the live app (99.7% of samples inside `children(of:)`), which the
    /// user saw as "the loading bar sticks at 51% forever". The vast
    /// majority of those calls are for entities that can never HAVE a child
    /// at all (8.8M plain LINEs in that package).
    ///
    /// Callers that need parent→children for MANY parents must build this
    /// once and do O(1) dictionary lookups instead. Mirrors the identical
    /// precomputed maps `DXFStructuralWriter.childrenByParent` (see
    /// `HandleAllocator`'s doc comment) and `Regenerator`'s
    /// `attributeOwningInserts` already use for exactly this reason.
    ///
    /// Deleted entities are skipped, matching `children(of:)` exactly, so a
    /// parent with only deleted children is simply absent from the result
    /// (equivalent to `children(of:)` returning `[]`). Insertion order per
    /// parent is ascending `EntityID`, also matching `children(of:)` —
    /// important because an INSERT's ATTRIB order is user-visible (it drives
    /// Data Extraction column order and the attribute-editor row order).
    func childrenByParent() -> [Int32: [EntityID]] {
        var map: [Int32: [EntityID]] = [:]
        for i in headers.indices {
            let h = headers[i]
            guard !h.flags.contains(.deleted),
                  let parent = h.owner.parentEntityID else { continue }
            map[parent.raw, default: []].append(EntityID(raw: Int32(i)))
        }
        return map
    }

    // MARK: Payload storage helpers

    @discardableResult
    private func storePayload(_ copy: EntityPayloadCopy) -> Int32 {
        switch copy {
        case .line(let p): lines.append(p); return Int32(lines.count - 1)
        case .point(let p): points.append(p); return Int32(points.count - 1)
        case .circle(let p): circles.append(p); return Int32(circles.count - 1)
        case .arc(let p): arcs.append(p); return Int32(arcs.count - 1)
        case .ellipse(let p): ellipses.append(p); return Int32(ellipses.count - 1)
        case .polyline(var p, let verts, let bulges):
            p.vertsStart = Int32(vertexArena.count); p.vertsCount = Int32(verts.count)
            vertexArena.append(contentsOf: verts)
            p.bulgesStart = Int32(scalarArena.count)
            scalarArena.append(contentsOf: bulges)
            polylines.append(p); return Int32(polylines.count - 1)
        case .spline(var p, let control, let knots, let weights):
            p.controlStart = Int32(vertexArena.count); p.controlCount = Int32(control.count)
            vertexArena.append(contentsOf: control)
            p.knotStart = Int32(scalarArena.count); p.knotCount = Int32(knots.count)
            scalarArena.append(contentsOf: knots)
            p.weightStart = Int32(scalarArena.count); p.weightCount = Int32(weights.count)
            scalarArena.append(contentsOf: weights)
            splines.append(p); return Int32(splines.count - 1)
        case .text(let p): texts.append(p); return Int32(texts.count - 1)
        case .mtext(let p): mtexts.append(p); return Int32(mtexts.count - 1)
        case .insert(let p): inserts.append(p); return Int32(inserts.count - 1)
        case .hatch(var p, let loops):
            p.loopRangeStart = Int32(hatchLoopRanges.count)
            for loop in loops {
                let start = Int32(vertexArena.count)
                vertexArena.append(contentsOf: loop)
                hatchLoopRanges.append(HatchLoopRange(vertStart: start, vertCount: Int32(loop.count)))
            }
            p.loopRangeCount = Int32(loops.count)
            hatches.append(p); return Int32(hatches.count - 1)
        case .image(let p): images.append(p); return Int32(images.count - 1)
        case .viewport(let p): viewports.append(p); return Int32(viewports.count - 1)
        case .dimension(let p): dimensions.append(p); return Int32(dimensions.count - 1)
        case .unknown: return -1
        }
    }

    /// Overwrites the payload data referenced by `existing.payload` in place
    /// when `copy`'s shape (vertex/control count) matches exactly; otherwise
    /// falls back to `storePayload` (a fresh append, leaking the old range).
    private func writePayload(_ copy: EntityPayloadCopy, overExisting existing: EntityHeader) -> Int32 {
        let i = Int(existing.payload)
        guard i >= 0 else { return storePayload(copy) }
        switch copy {
        case .line where existing.type == .line:
            if case .line(let p) = copy { lines[i] = p; return existing.payload }
        case .point where existing.type == .point:
            if case .point(let p) = copy { points[i] = p; return existing.payload }
        case .circle where existing.type == .circle:
            if case .circle(let p) = copy { circles[i] = p; return existing.payload }
        case .arc where existing.type == .arc:
            if case .arc(let p) = copy { arcs[i] = p; return existing.payload }
        case .ellipse where existing.type == .ellipse:
            if case .ellipse(let p) = copy { ellipses[i] = p; return existing.payload }
        case .polyline where polylines.indices.contains(i):
            if case .polyline(let p, let verts, let bulges) = copy,
               Int(polylines[i].vertsCount) == verts.count {
                var np = p
                np.vertsStart = polylines[i].vertsStart
                for k in 0..<verts.count { vertexArena[Int(np.vertsStart) + k] = verts[k] }
                for k in 0..<bulges.count { scalarArena[Int(polylines[i].bulgesStart) + k] = bulges[k] }
                np.bulgesStart = polylines[i].bulgesStart
                polylines[i] = np
                return existing.payload
            }
        case .spline where splines.indices.contains(i):
            if case .spline(let p, let control, let knots, let weights) = copy,
               Int(splines[i].controlCount) == control.count,
               Int(splines[i].knotCount) == knots.count,
               Int(splines[i].weightCount) == weights.count {
                var np = p
                np.controlStart = splines[i].controlStart
                np.knotStart = splines[i].knotStart
                np.weightStart = splines[i].weightStart
                for k in 0..<control.count { vertexArena[Int(np.controlStart) + k] = control[k] }
                for k in 0..<knots.count { scalarArena[Int(np.knotStart) + k] = knots[k] }
                for k in 0..<weights.count { scalarArena[Int(np.weightStart) + k] = weights[k] }
                splines[i] = np
                return existing.payload
            }
        // ATTRIB/ATTDEF are stored via the same TextPayload array as TEXT
        // (see EntityStoreParser: `finish(type == "ATTRIB" ? .attrib : .text,
        // .text(payload), ...)` — ATTDEF round-trips the same shape) — must
        // accept those header types here too, or a snapshot/restore cycle
        // (any modifyPayload/modifyHeader/delete+undo of an ATTRIB/ATTDEF)
        // falls through to the `default: break` below, appends a FRESH
        // payload via storePayload(.text(...)), and satisfies this call —
        // but a MISMATCHED case here caused a worse silent failure before
        // this fix: `copyPayload` returned `.unknown` for these types (see
        // that function's fix), so `copy` was never even `.text` to begin
        // with, and `storePayload(.unknown)` returns -1, corrupting the
        // entity's payload pointer entirely.
        case .text where existing.type == .text || existing.type == .attrib || existing.type == .attdef:
            if case .text(let p) = copy { texts[i] = p; return existing.payload }
        case .mtext where existing.type == .mtext:
            if case .mtext(let p) = copy { mtexts[i] = p; return existing.payload }
        case .insert where existing.type == .insert:
            if case .insert(let p) = copy { inserts[i] = p; return existing.payload }
        case .image where existing.type == .image:
            if case .image(let p) = copy { images[i] = p; return existing.payload }
        case .viewport where existing.type == .viewport:
            if case .viewport(let p) = copy { viewports[i] = p; return existing.payload }
        case .dimension where existing.type == .dimension:
            if case .dimension(let p) = copy { dimensions[i] = p; return existing.payload }
        default:
            break
        }
        // Hatch (variable loop count) and any shape mismatch: fresh append.
        return storePayload(copy)
    }

    private func copyPayload(_ h: EntityHeader) -> EntityPayloadCopy {
        guard h.payload >= 0 else { return .unknown }
        let i = Int(h.payload)
        switch h.type {
        case .line: return .line(lines[i])
        case .point: return .point(points[i])
        case .circle: return .circle(circles[i])
        case .arc: return .arc(arcs[i])
        case .ellipse: return .ellipse(ellipses[i])
        case .lwpolyline, .polyline2d, .polyline3d, .solid, .trace, .face3d, .leader:
            let p = polylines[i]
            let verts = Array(vertexArena[Int(p.vertsStart)..<Int(p.vertsStart + p.vertsCount)])
            let bulges = Array(scalarArena[Int(p.bulgesStart)..<Int(p.bulgesStart) + Int(p.vertsCount)])
            return .polyline(p, vertices: verts, bulges: bulges)
        case .spline:
            let p = splines[i]
            let control = Array(vertexArena[Int(p.controlStart)..<Int(p.controlStart + p.controlCount)])
            let knots = Array(scalarArena[Int(p.knotStart)..<Int(p.knotStart + p.knotCount)])
            let weights = Array(scalarArena[Int(p.weightStart)..<Int(p.weightStart + p.weightCount)])
            return .spline(p, control: control, knots: knots, weights: weights)
        // ATTRIB/ATTDEF share TextPayload's storage with TEXT (see the
        // matching note in `writePayload`) — omitting them here (a
        // pre-Phase-1.6 bug fixed alongside this phase's incremental-regen
        // work, which is what surfaced it: any snapshot of an ATTRIB/ATTDEF
        // silently returned `.unknown`, and restoring `.unknown` zeroes the
        // entity's `payload` index, permanently losing its geometry on the
        // very first modifyPayload/modifyHeader/delete+undo touching it).
        case .text, .attrib, .attdef: return .text(texts[i])
        case .mtext: return .mtext(mtexts[i])
        case .insert: return .insert(inserts[i])
        case .hatch:
            let p = hatches[i]
            var loops: [[Vec3]] = []
            for r in Int(p.loopRangeStart)..<Int(p.loopRangeStart + p.loopRangeCount) {
                let range = hatchLoopRanges[r]
                loops.append(Array(vertexArena[Int(range.vertStart)..<Int(range.vertStart + range.vertCount)]))
            }
            return .hatch(p, loops: loops)
        case .image: return .image(images[i])
        case .viewport: return .viewport(viewports[i])
        case .dimension: return .dimension(dimensions[i])
        default: return .unknown
        }
    }
}
