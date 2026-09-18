import Foundation
import CoreGraphics

// MARK: - Colors

/// A display color resolved from DXF color rules (ACI / true color / BYLAYER / BYBLOCK).
/// `.foreground` is ACI 7: white on a dark background, black on a light one —
/// matching AutoCAD's behavior of flipping "white" entities with the background.
public enum ResolvedColor: Hashable {
    case foreground
    case rgb(UInt32) // 0xRRGGBB

    public func cgColor(darkBackground: Bool) -> CGColor {
        switch self {
        case .foreground:
            return darkBackground
                ? CGColor(red: 1, green: 1, blue: 1, alpha: 1)
                : CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        case .rgb(let v):
            var r = CGFloat((v >> 16) & 0xFF) / 255
            var g = CGFloat((v >> 8) & 0xFF) / 255
            var b = CGFloat(v & 0xFF) / 255
            // Pure black is invisible on the dark canvas; AutoCAD shows ACI 250-ish
            // dark grays fine, but entities explicitly colored 0,0,0 flip like white.
            if darkBackground && r == 0 && g == 0 && b == 0 { r = 1; g = 1; b = 1 }
            return CGColor(red: r, green: g, blue: b, alpha: 1)
        }
    }

    /// Solid swatch color for the layer panel (drawn on the sidebar background).
    ///
    /// WARNING: maps `.foreground` to WHITE unconditionally, which is only
    /// correct for a swatch drawn on a DARK surface. Prefer
    /// `swatchDisplayRGB(darkBackground:)` for any UI whose background
    /// follows the system appearance — see that method for the bug this caused.
    public var swatchRGB: UInt32 {
        switch self {
        case .foreground: return 0xFFFFFF
        case .rgb(let v): return v
        }
    }

    /// Swatch color for panel UI, resolved against the CURRENT appearance —
    /// the theme-aware counterpart to `swatchRGB`.
    ///
    /// Fixes a reported bug: the Properties panel's Color swatch "shows white
    /// as the thumbnail that should be colored to match the color selection."
    /// `.foreground` is ACI 7, meaning "whatever contrasts with the
    /// background" — NOT literally white. Painting it via `swatchRGB` drew a
    /// white square, invisible against a light panel and reading as "no color
    /// at all". Since ACI 7 / BYLAYER-on-a-default-layer is the commonest
    /// color state in a real drawing, this affected most objects a user could
    /// click.
    ///
    /// Also mirrors `cgColor(darkBackground:)`'s pure-black flip, so a swatch
    /// never disagrees with what the renderer actually paints on canvas.
    public func swatchDisplayRGB(darkBackground: Bool) -> UInt32 {
        switch self {
        case .foreground:
            return darkBackground ? 0xFFFFFF : 0x000000
        case .rgb(let v):
            if darkBackground && (v & 0x00FF_FFFF) == 0 { return 0xFFFFFF }
            return v & 0x00FF_FFFF
        }
    }
}

// MARK: - Tables

public struct DXFLayer: Identifiable {
    public let id: Int
    public let name: String
    public var color: ResolvedColor = .foreground
    public var linetypeId: Int = 0
    /// Layer starts hidden (negative color in the LAYER table = "off").
    public var isOffByDefault = false
    /// Frozen layers are also hidden by default.
    public var isFrozen = false
    /// Entity count after block expansion — what the user sees next to the name.
    public var entityCount: Int = 0
    /// AutoCAD-style layer transparency, 0...100 (percent transparent; 0 =
    /// fully opaque, 100 = fully invisible-but-still-selectable — matching
    /// AutoCAD's own Layer Properties Manager transparency column, which is
    /// distinct from FREEZE/OFF: a transparent layer's entities remain
    /// selectable/snappable, only their drawn alpha changes). Corresponds to
    /// DXF group 440 on the LAYER table entry (`0x02000000 | (255 -
    /// round(value/100*255))`, per the format `ezdxf`'s `dxf.transparency`
    /// documents: `0x00` = 100% transparent, `0xFF` = opaque) — see
    /// `DXFTablesEmitter`'s LAYER writer for the exact encode/decode, kept
    /// in ONE place there rather than duplicated at every call site.
    /// Clamped to 0...100 by every setter in this codebase (`ContentView
    /// .setLayerTransparency`), never enforced here since this is a plain
    /// data holder with no validating initializer today (matching how
    /// `color`/`linetypeId` are equally unvalidated at this layer).
    public var transparency: Double = 0
    /// Phase 3 groundwork: this LAYER record's original DXF handle (group
    /// 5), 0 if the source file had none (R12, or a layer synthesized by
    /// this app rather than parsed). Purely additive — every existing
    /// `DXFLayer(...)` call site uses named arguments and this field
    /// defaults to 0, so nothing that builds/reads a `DXFLayer` today
    /// changes behavior. A future structural DXF writer needs this to
    /// preserve the pointer graph (entities/dictionaries referencing a
    /// layer by handle) instead of only by name.
    public var handle: UInt64 = 0

    public init(id: Int, name: String, color: ResolvedColor = .foreground, linetypeId: Int = 0,
                isOffByDefault: Bool = false, isFrozen: Bool = false, entityCount: Int = 0, handle: UInt64 = 0,
                transparency: Double = 0) {
        self.id = id
        self.name = name
        self.color = color
        self.linetypeId = linetypeId
        self.isOffByDefault = isOffByDefault
        self.isFrozen = isFrozen
        self.entityCount = entityCount
        self.handle = handle
        self.transparency = transparency
    }
}

public struct DXFLinetype {
    public let name: String
    /// CoreGraphics-ready dash lengths (paint, gap, paint, gap, ...), in drawing
    /// units, already scaled by $LTSCALE. Empty = continuous.
    public let dashes: [CGFloat]
    /// Phase 3 groundwork: see `DXFLayer.handle`'s doc comment — same
    /// rationale, same additive-only guarantee (default 0, named-arg call
    /// sites only).
    public var handle: UInt64 = 0

    public init(name: String, dashes: [CGFloat], handle: UInt64 = 0) {
        self.name = name
        self.dashes = dashes
        self.handle = handle
    }
}

public struct XrefInfo: Identifiable {
    public let id: Int
    public let blockName: String
    public let path: String
    /// Original source file path resolved by PackageLoader, if known.
    public let sourcePath: String
    /// Local file path actually parsed/openable by NovaCAD (DXF; converted cache
    /// for DWG sources), if known.
    public let loadedPath: String
    /// True when the xref's geometry is embedded in this DXF (bound / cached).
    public let isResolved: Bool
    public let entityCount: Int
    public let insertCount: Int

    public init(id: Int, blockName: String, path: String, sourcePath: String, loadedPath: String,
                isResolved: Bool, entityCount: Int, insertCount: Int) {
        self.id = id
        self.blockName = blockName
        self.path = path
        self.sourcePath = sourcePath
        self.loadedPath = loadedPath
        self.isResolved = isResolved
        self.entityCount = entityCount
        self.insertCount = insertCount
    }

    /// The `"PREFIX|"` string that every one of this xref's dependent layers
    /// is named with. Xref-dependent layers are named `XREFNAME|layer`
    /// (nested: `PARENT|CHILD|layer`), where `XREFNAME` is the xref block name
    /// with any `$` nesting separators converted to `|` — see
    /// `PackageLoader.mergeIntoStore`. Used by the Layers panel to attribute a
    /// layer to its owning xref (and to hide an xref's layers when the xref
    /// itself is toggled off).
    public var layerPrefix: String {
        blockName.replacingOccurrences(of: "$", with: "|") + "|"
    }

    /// True if `layerName` is one of this xref's dependent layers.
    public func owns(layerNamed layerName: String) -> Bool {
        layerName.hasPrefix(layerPrefix)
    }

    /// The `"<blockName>$"` prefix every NESTED xref of this one carries in its
    /// own block name (AutoCAD names a dependent xref block "PARENT$CHILD", and
    /// deeper "PARENT$CHILD$GRANDCHILD"). Used to collect an xref's whole
    /// subtree so toggling it off also hides the xrefs embedded within it.
    public var nestedBlockPrefix: String { blockName + "$" }

    /// The SOURCE drawing this xref reference points at — the terminal segment
    /// of the (possibly nested) block name. AutoCAD names a dependent xref
    /// block "PARENT$CHILD" where CHILD is the drawing PARENT xrefs; the last
    /// `$`-segment is therefore the actual source drawing, independent of which
    /// parent path reached it. So "LAP..." and "OTHER STATION$LAP..." share the
    /// source drawing "LAP...". Used to group references by source so toggling
    /// a drawing once hides every place it's xref'd. Case-folded for matching.
    public var sourceDrawingName: String {
        (blockName.split(separator: "$").last.map(String.init) ?? blockName)
    }

    public var sourceDrawingKey: String { sourceDrawingName.lowercased() }
}

extension Collection where Element == XrefInfo {
    /// All xref ids that make up `root`'s subtree: `root` itself plus every
    /// xref whose block name is nested under it (`"<root>$…"`). Toggling an
    /// xref's visibility acts on this whole set so hiding a parent also hides
    /// the xrefs embedded within it. (A copy of the same source referenced
    /// under a DIFFERENT parent is a different block name and stays visible —
    /// it belongs to that other parent's subtree.)
    public func subtreeXrefIds(of root: XrefInfo) -> Set<Int> {
        var ids: Set<Int> = [root.id]
        let prefix = root.nestedBlockPrefix
        for x in self where x.blockName.hasPrefix(prefix) { ids.insert(x.id) }
        return ids
    }

    /// Every xref id that renders the SAME source drawing as `root`, ANYWHERE
    /// it is referenced (under any parent), PLUS the whole nested subtree under
    /// each of those references. This is what a single eye toggle acts on so
    /// the user only has to toggle a given source drawing ONCE to hide it and
    /// its contents across every drawing that xrefs it.
    public func xrefIdsSharingSource(with root: XrefInfo) -> Set<Int> {
        let key = root.sourceDrawingKey
        var ids: Set<Int> = []
        for x in self where x.sourceDrawingKey == key {
            ids.formUnion(subtreeXrefIds(of: x))
        }
        return ids
    }

    /// One representative `XrefInfo` per unique SOURCE drawing (deduplicated by
    /// `sourceDrawingKey`), preferring the shortest/top-level block name as the
    /// representative and summing reference counts. This is the list the panel
    /// shows so each source drawing appears as a single toggleable row.
    public func groupedBySourceDrawing() -> [XrefInfo] {
        var repByKey: [String: XrefInfo] = [:]
        var order: [String] = []
        for x in self {
            let key = x.sourceDrawingKey
            if let existing = repByKey[key] {
                // Prefer the top-level (no "$") / shortest block name as the
                // representative; accumulate entity + insert totals.
                let existingOpenable = !existing.loadedPath.isEmpty || !existing.sourcePath.isEmpty
                let newOpenable = !x.loadedPath.isEmpty || !x.sourcePath.isEmpty
                let preferNew = (!existingOpenable && newOpenable)
                    || (!x.blockName.contains("$") && existing.blockName.contains("$"))
                    || (x.blockName.count < existing.blockName.count
                        && x.blockName.contains("$") == existing.blockName.contains("$"))
                let base = preferNew ? x : existing
                repByKey[key] = XrefInfo(
                    id: base.id, blockName: base.sourceDrawingName, path: base.path,
                    sourcePath: base.sourcePath, loadedPath: base.loadedPath,
                    isResolved: existing.isResolved || x.isResolved,
                    entityCount: existing.entityCount + x.entityCount,
                    insertCount: existing.insertCount + x.insertCount)
            } else {
                repByKey[key] = x
                order.append(key)
            }
        }
        return order.compactMap { repByKey[$0] }
    }
}

// MARK: - Entity identity (selection & properties)

/// Original DXF entity type, preserved through tessellation for the
/// properties panel.
public enum EntityKind: UInt8 {
    case line, polyline, spline, ellipse, circle, arc
    case solid, face3d, hatch, point
    case text, mtext, attrib
    case leader, other

    public var label: String {
        switch self {
        case .line: return "Line"
        case .polyline: return "Polyline"
        case .spline: return "Spline"
        case .ellipse: return "Ellipse"
        case .circle: return "Circle"
        case .arc: return "Arc"
        case .solid: return "Solid"
        case .face3d: return "3D Face"
        case .hatch: return "Hatch"
        case .point: return "Point"
        case .text: return "Text"
        case .mtext: return "MText"
        case .attrib: return "Attribute"
        case .leader: return "Leader"
        case .other: return "Object"
        }
    }
}

/// A selectable object: either a loose primitive (addressed by its slot in a
/// render group's stores) or a whole block reference (AutoCAD-style: clicking
/// any part of an inserted block selects the insert).
public enum EntityRef: Hashable {
    case primitive(group: Int32, store: PrimitiveStore, index: Int32)
    case insert(Int32)              // index into DXFDocument.inserts
}

public enum PrimitiveStore: UInt8, Hashable {
    case run, arc, text, point, fillRun
}

/// One placed block reference (top-level INSERT instance) for selection.
public struct InsertInstance {
    public var name: String
    public var position: CGPoint           // world, after any parent transform
    public var scaleX: CGFloat
    public var scaleY: CGFloat
    public var rotationDegrees: Double
    public var layerId: Int32
    public var xrefId: Int16
    /// Stable `EntityID.raw` of the source INSERT entity this instance came
    /// from (Phase 1.7 live cutover) — lets `EntityRef.insert(_:)` resolve to
    /// a stable `EntityID` via `HitTester`'s resolution helpers, the same way
    /// `StrokeStore.Run.entityId`/`.Arc.entityId`/etc. do for loose
    /// primitives. -1 = not populated (the OLD `GeometryBuilder` path, which
    /// has no `EntityStore`/`EntityID` to attach — `PackageLoader.load`'s
    /// `DXFDocument`s always carry -1 here, which is fine: nothing on that
    /// path ever asks for a stable EntityID).
    public var entityId: Int32 = -1
    /// NovaCAD's per-instance "Display Name" cosmetic override, read from
    /// this INSERT's XDATA (app-id `NOVACAD_DISPLAYNAME`) when present — see
    /// `DXFParser.InsertRaw.displayNameOverride`'s doc comment for the full
    /// "why." `nil` when no override was set; consumers fall back to `name`
    /// (the real block-definition name) in that case.
    public var displayNameOverride: String?

    public init(name: String, position: CGPoint, scaleX: CGFloat, scaleY: CGFloat,
                rotationDegrees: Double, layerId: Int32, xrefId: Int16, entityId: Int32 = -1,
                displayNameOverride: String? = nil) {
        self.name = name
        self.position = position
        self.scaleX = scaleX
        self.scaleY = scaleY
        self.rotationDegrees = rotationDegrees
        self.displayNameOverride = displayNameOverride
        self.layerId = layerId
        self.xrefId = xrefId
        self.entityId = entityId
    }
}

// MARK: - Render groups

/// Flat storage for a group's stroke geometry: polyline runs plus analytic
/// arcs/circles (kept exact so they stay round at any zoom under uniform
/// transforms). Fill outlines are stored separately so hatches/solids remain
/// individually hit-testable even though they rasterize via merged CGPaths.
public final class StrokeStore {
    public struct Run {
        public var start: Int32
        public var count: Int32
        public var closed: Bool
        public var kind: EntityKind = .line
        public var insertId: Int32 = -1    // owning top-level block reference, -1 = none
        public var bounds: CGRect
        /// Stable `EntityID.raw` of the source entity this run came from
        /// (the top-level INSERT's id for expanded block content, or the
        /// source entity's own id for orphan-root content — mirrors
        /// `insertId`'s assignment exactly). -1 = not populated (only true
        /// for geometry produced by the OLD `GeometryBuilder`/`RawParseOutput`
        /// path, which has no stable per-entity identity to attach).
        /// A positional `EntityRef` (HitTesting.swift) can be resolved to a
        /// stable `EntityID` via this field once a caller wants that — not
        /// wired up anywhere yet (out of scope for this phase).
        public var entityId: Int32 = -1
        /// The source entity's own DXF handle (group code 5), or the owning
        /// top-level INSERT's handle for block-expanded content. 0 = none
        /// parsed (synthetic/legacy sources). This is the STABLE cross-import
        /// identity downstream layout-sync consumers can key state off of, so an
        /// edited/re-saved drawing keeps matching the same aisles/marketplaces
        /// instead of re-identifying every entity as brand-new. Distinct from
        /// `entityId` (a NovaCAD editable-store slot index with different
        /// semantics); populated by the legacy `GeometryBuilder` path.
        public var handle: UInt64 = 0
        /// FOR `fillRuns` ENTRIES ONLY (meaningless/unused for stroke
        /// `runs`): this hatch's own 0...1 alpha multiplier — 1 minus its
        /// `HatchPayload.transparency`/100, baked in at emission time since a
        /// `RenderGroup`'s merged `fillPath` has no per-entity granularity
        /// left by the time the renderer draws it (`fillPath` is one
        /// CGMutablePath shared by every hatch/solid sharing the group's
        /// layer+color+linetype+xref key). Defaults to 1 (fully opaque) so
        /// every non-hatch fill (SOLID/3DFACE) and every hatch that never set
        /// a per-entity transparency is unaffected. The renderer multiplies
        /// this by the LAYER's own transparency — the two compose, matching
        /// real DXF semantics where an entity's own transparency layers on
        /// top of its layer's.
        public var fillAlpha: CGFloat = 1
        /// FOR STROKE `runs` ENTRIES ONLY (meaningless/unused for
        /// `fillRuns`): this entity's `EntityHeader.lineweight` (DXF group
        /// 370), in 1/100 mm, baked in at emission time — same rationale as
        /// `fillAlpha` above (a `RenderGroup`'s merged stroke path has no
        /// per-entity granularity left by render time, and adding lineweight
        /// as a `Regenerator.GroupKey` dimension would multiply render-group
        /// count app-wide for a property only a small minority of entities
        /// ever set). -1/-2/-3 (BYLAYER/BYBLOCK/default — the overwhelming
        /// common case, matching `EntityHeader.lineweight`'s own default)
        /// means "render as today's fixed hairline width," so this costs
        /// nothing for any entity that never had an explicit lineweight set.
        public var lineweight: Int16 = -1
        /// FOR STROKE `runs` ENTRIES ONLY (meaningless/unused for
        /// `fillRuns`, which use `fillAlpha` instead): a per-run 0...1 alpha
        /// multiplier, baked in at emission time — same rationale as
        /// `fillAlpha`/`lineweight` above. A non-solid HATCH's "Diagonal
        /// Lines" fill style (see `HatchTool`'s doc comment) is rendered as
        /// real stroke runs (`Regenerator`'s `.hatch` case), and
        /// `HatchPayload.transparency` must dim those LINES exactly as it
        /// dims a solid hatch's fill — matching real AutoCAD behavior, where
        /// hatch transparency applies to the pattern lines, not just a solid
        /// fill. A `RenderGroup`'s batched stroke path has no per-entity
        /// granularity left by render time (the same reason `fillAlpha`
        /// exists), so this is the stroke-side counterpart. Defaults to 1
        /// (fully opaque) so every ordinary LINE/polyline/etc. run — the
        /// overwhelming common case — is completely unaffected.
        public var strokeAlpha: CGFloat = 1

        public init(start: Int32, count: Int32, closed: Bool, kind: EntityKind = .line,
                    insertId: Int32 = -1, bounds: CGRect, entityId: Int32 = -1, handle: UInt64 = 0,
                    fillAlpha: CGFloat = 1, lineweight: Int16 = -1, strokeAlpha: CGFloat = 1) {
            self.start = start
            self.count = count
            self.closed = closed
            self.kind = kind
            self.insertId = insertId
            self.bounds = bounds
            self.entityId = entityId
            self.handle = handle
            self.fillAlpha = fillAlpha
            self.lineweight = lineweight
            self.strokeAlpha = strokeAlpha
        }
    }
    public struct Arc {
        public var center: CGPoint
        public var radius: CGFloat
        public var startAngleDeg: Double   // CCW sweep from start to end
        public var endAngleDeg: Double
        public var isFullCircle: Bool
        public var insertId: Int32 = -1
        /// See `Run.entityId`.
        public var entityId: Int32 = -1
        /// See `Run.handle` — the stable DXF handle for cross-import identity.
        public var handle: UInt64 = 0
        /// See `Run.lineweight` — same encoding/rationale, for analytic
        /// arcs/circles (which are stored separately from polyline `runs`).
        public var lineweight: Int16 = -1

        public init(center: CGPoint, radius: CGFloat, startAngleDeg: Double, endAngleDeg: Double,
                    isFullCircle: Bool, insertId: Int32 = -1, entityId: Int32 = -1, handle: UInt64 = 0,
                    lineweight: Int16 = -1) {
            self.center = center
            self.radius = radius
            self.startAngleDeg = startAngleDeg
            self.endAngleDeg = endAngleDeg
            self.isFullCircle = isFullCircle
            self.insertId = insertId
            self.entityId = entityId
            self.handle = handle
            self.lineweight = lineweight
        }
    }

    public var points: [CGPoint] = []
    public var runs: [Run] = []
    public var arcs: [Arc] = []
    /// POINT entities' owning inserts (parallel to RenderGroup.points).
    public var pointInsertIds: [Int32] = []
    /// POINT entities' owning source entity id (parallel to
    /// RenderGroup.points; see `Run.entityId`).
    public var pointEntityIds: [Int32] = []
    /// Outlines of SOLID/HATCH fills, for hit-testing and properties.
    public var fillPoints: [CGPoint] = []
    public var fillRuns: [Run] = []

    public var isEmpty: Bool { runs.isEmpty && arcs.isEmpty && fillRuns.isEmpty }

    public init() {}
}

/// Immutable batch of geometry sharing (layer, color, linetype, xref membership).
/// Built once per file load; visibility toggles simply include/exclude groups.
public final class RenderGroup {
    public let layerId: Int
    public let color: ResolvedColor
    public let linetypeId: Int
    /// -1 = not part of an xref; otherwise index into DXFDocument.xrefs.
    public let xrefId: Int
    /// Stroke geometry as flat world-space point runs. The renderer transforms
    /// these to screen space per frame and DECIMATES: points landing within the
    /// same pixel are skipped and whole sub-pixel runs collapse to a tick.
    /// Rasterizing full-density CGPaths is not viable — CoreGraphics' AA sweep
    /// (aa_intersection_event) takes minutes on millions of crossing hairlines.
    public let strokes: StrokeStore
    /// Opaque fills: SOLID, TRACE, solid HATCH.
    public let fillPath: CGPath
    /// Pattern-hatch regions, rendered translucent as an approximation.
    public let patternFillPath: CGPath
    /// POINT entities: rendered as fixed-size screen-space dots.
    public let points: [CGPoint]
    public let texts: [TextItem]
    public let bounds: CGRect
    public let entityCount: Int
    // NOTE: NovaCAD's editing-only `tombstones: GroupTombstones?` field was
    // removed during CADCore extraction (Option B) — GroupTombstones lives in
    // NovaCAD's RegenCoordinator (editing layer), which is not part of CADCore.
    // Consumers needing incremental-regen tombstones track them out-of-band.

    public init(layerId: Int, color: ResolvedColor, linetypeId: Int, xrefId: Int,
         strokes: StrokeStore,
         fillPath: CGPath, patternFillPath: CGPath,
         points: [CGPoint], texts: [TextItem], bounds: CGRect, entityCount: Int) {
        self.layerId = layerId
        self.color = color
        self.linetypeId = linetypeId
        self.xrefId = xrefId
        self.strokes = strokes
        self.fillPath = fillPath
        self.patternFillPath = patternFillPath
        self.points = points
        self.texts = texts
        self.bounds = bounds
        self.entityCount = entityCount
    }
}

public struct TextItem {
    public var position: CGPoint      // alignment anchor in world coordinates
    public var height: CGFloat        // cap height in drawing units
    public var rotationDegrees: Double
    public var widthFactor: CGFloat
    public var text: String           // plain text; may contain \n
    public var hAlign: Int            // 0 left, 1 center, 2 right
    public var vAlign: Int            // 0 baseline, 1 bottom, 2 middle, 3 top
    public var mirroredX: Bool = false
    public var kind: EntityKind = .text
    public var insertId: Int32 = -1
    /// See `StrokeStore.Run.entityId`.
    public var entityId: Int32 = -1
    /// An ATTRIB entity's TAG (its DXF group-code-2 field NAME, e.g.
    /// `"PART_BASE"`), distinct from `text` (the field's VALUE). Empty for
    /// plain TEXT/MTEXT `kind`s, which have no tag. Lets a consumer with
    /// multiple ATTRIBs on one block instance tell them apart by NAME rather
    /// than only ever seeing "some string" — the identity a mapping/browse UI
    /// needs (e.g. a drawing-attribute-to-field mapping step).
    public var tag: String = ""

    public init(position: CGPoint, height: CGFloat, rotationDegrees: Double, widthFactor: CGFloat,
                text: String, hAlign: Int, vAlign: Int, mirroredX: Bool = false, kind: EntityKind = .text,
                insertId: Int32 = -1, entityId: Int32 = -1, tag: String = "") {
        self.position = position
        self.height = height
        self.rotationDegrees = rotationDegrees
        self.widthFactor = widthFactor
        self.text = text
        self.hAlign = hAlign
        self.vAlign = vAlign
        self.mirroredX = mirroredX
        self.kind = kind
        self.insertId = insertId
        self.entityId = entityId
        self.tag = tag
    }
}

// MARK: - Document

public struct ParseStats {
    public var totalEntities = 0
    public var parseSeconds: Double = 0
    public var buildSeconds: Double = 0
    public var truncated = false
    public var skippedTypes: [String: Int] = [:]

    public init(totalEntities: Int = 0, parseSeconds: Double = 0, buildSeconds: Double = 0,
                truncated: Bool = false, skippedTypes: [String: Int] = [:]) {
        self.totalEntities = totalEntities
        self.parseSeconds = parseSeconds
        self.buildSeconds = buildSeconds
        self.truncated = truncated
        self.skippedTypes = skippedTypes
    }
}

/// Everything the UI and renderer need for one loaded drawing. Immutable after load.
public final class DXFDocument {
    public let layers: [DXFLayer]
    public let linetypes: [DXFLinetype]
    public let xrefs: [XrefInfo]
    /// Backing storage for `modelGroups`/`paperGroups`. `private(set) var`
    /// (not `let`) ONLY so `RegenCoordinator.appendGroup` (Phase 1.6) can
    /// append delta groups after an edit — existing array INDICES never
    /// move or shrink from an append, so every positional `EntityRef` any
    /// caller already holds stays valid. Every reader still sees a plain
    /// `[RenderGroup]` through the `modelGroups`/`paperGroups` properties
    /// below, unchanged from before this field existed.
    public private(set) var modelGroups: [RenderGroup]
    public private(set) var paperGroups: [RenderGroup]
    /// Raw geometric extents (min/max of everything).
    public let modelBounds: CGRect
    public let paperBounds: CGRect
    /// Robust extents for fit-to-view: 2nd–98th percentile of geometry density.
    /// Real drawings often carry stray content parked at faraway coordinates;
    /// fitting raw extents would crush the actual plant into a few pixels.
    public let modelFitBounds: CGRect
    public let paperFitBounds: CGRect
    /// Top-level block references, addressable via EntityRef.insert.
    /// Model-space instances come first; indices >= modelInsertCount are
    /// paper-space instances. `private(set) var` (not `let`) for the same
    /// reason as `modelGroups`/`paperGroups` above — Phase 6.1's
    /// `RegenCoordinator.emitDelta`/`regenerateDirtyBlocks` need to append/
    /// update entries after a live edit (a freshly-placed INSERT, or an
    /// existing one whose block was redefined) so that clicking the new
    /// content promotes to the whole insert instead of resolving to a loose
    /// leaf primitive — see `appendInsert(_:space:)`'s own doc comment for
    /// why a plain `.append` isn't safe here the way it is for
    /// `modelGroups`/`paperGroups`.
    public private(set) var inserts: [InsertInstance]
    public private(set) var modelInsertCount: Int
    /// Drawing-unit suffix from $INSUNITS ("mm", "in", ...; empty if unitless).
    public let unitsLabel: String
    /// Raw $INSUNITS value, passed through to exported markup DXFs.
    public var insUnits: Int = 0
    /// Stampable block symbols: name → local-space markup geometry (bounded
    /// capture of the most-inserted blocks). Populated after build.
    public var blockStamps: [String: [DrawnEntity]] = [:]
    /// Stampable block names, most-frequently-inserted first.
    public var stampableBlockNames: [String] = []
    public let stats: ParseStats
    /// The persistent on-disk ASCII DXF this document was loaded from, when one
    /// exists (nil for ZIP members, converted DWGs, and other temp sources).
    /// Enables "Save Copy with Markup".
    public var sourceDXFURL: URL? = nil

    public init(layers: [DXFLayer], linetypes: [DXFLinetype], xrefs: [XrefInfo],
         modelGroups: [RenderGroup], paperGroups: [RenderGroup],
         modelBounds: CGRect, paperBounds: CGRect,
         modelFitBounds: CGRect, paperFitBounds: CGRect,
         inserts: [InsertInstance], modelInsertCount: Int,
         unitsLabel: String, stats: ParseStats) {
        self.layers = layers
        self.linetypes = linetypes
        self.xrefs = xrefs
        self.modelGroups = modelGroups
        self.paperGroups = paperGroups
        self.modelBounds = modelBounds
        self.paperBounds = paperBounds
        self.modelFitBounds = modelFitBounds
        self.paperFitBounds = paperFitBounds
        self.inserts = inserts
        self.modelInsertCount = modelInsertCount
        self.unitsLabel = unitsLabel
        self.stats = stats
    }

    /// Phase 1.6: appends one delta `RenderGroup` to the given space's group
    /// array. The ONLY mutator of `modelGroups`/`paperGroups` outside this
    /// initializer — used exclusively by `RegenCoordinator` after an edit
    /// commits. Appending never invalidates an existing index, so any
    /// `EntityRef.primitive(group:...)` a caller already holds stays valid.
    public func appendGroup(_ group: RenderGroup, space: SpaceID) {
        switch space {
        case .model: modelGroups.append(group)
        case .paper: paperGroups.append(group)
        }
    }

    /// Phase 6.1: appends one new top-level `InsertInstance` for a freshly
    /// ADDED top-level INSERT entity (via `RegenCoordinator.emitDelta`), so
    /// `HitTester`'s "block content click promotes to the whole insert"
    /// rule has something to promote to (previously `document.inserts` was
    /// ONLY ever populated by a full `Regenerator.build` rebuild — a gap
    /// discovered building Phase 6.1's BLOCK/INSERT/Stamp-rewire commands,
    /// none of which existed before this phase, so nothing had exercised
    /// it). UNLIKE `appendGroup` (a plain, safe append — group indices have
    /// no ordering invariant), `inserts` is split into two CONTIGUOUS
    /// halves (model-space first, then paper-space, demarcated by
    /// `modelInsertCount`) — a naive append would place a model-space
    /// insert AFTER existing paper-space ones, corrupting the
    /// `idx >= modelInsertCount` space test for every entity resolved via
    /// `EntityRef.insert(_:)`. Instead: a MODEL-space insert is inserted
    /// exactly at the current `modelInsertCount` boundary (shifting every
    /// existing PAPER-space insert's index up by one — safe because
    /// `RegenCoordinator.insertIndexByEntityID` is invalidated by every
    /// call site that calls this, so no caller holds a stale positional
    /// index across the call); a PAPER-space insert is appended at the
    /// true end (paper-space's own end is always the array's end).
    /// Returns the NEW instance's actual index (which the caller must bake
    /// into the primitives it emits at the same time — see
    /// `Regenerator.emitInsertSubtree`'s `startingIndex` parameter, which
    /// this return value's PREDICTED value — `document.inserts.count`
    /// (model) before the call — must match; asserted by
    /// `RegenCoordinatorTests` rather than re-derived defensively here,
    /// since a mismatch would indicate a caller-side sequencing bug worth
    /// surfacing loudly in tests rather than silently working around).
    @discardableResult
    public func appendInsert(_ instance: InsertInstance, space: SpaceID) -> Int32 {
        switch space {
        case .model:
            let index = modelInsertCount
            inserts.insert(instance, at: index)
            modelInsertCount += 1
            return Int32(index)
        case .paper:
            inserts.append(instance)
            return Int32(inserts.count - 1)
        }
    }

    /// Overwrites an EXISTING `inserts` slot in place (used by
    /// `RegenCoordinator.regenerateDirtyBlocks` when re-expanding an
    /// insert whose block definition changed — the insert itself already
    /// has a valid index, so no shift/space-boundary logic is needed, just
    /// a direct replace).
    public func setInsert(_ instance: InsertInstance, at index: Int32) {
        guard index >= 0, Int(index) < inserts.count else { return }
        inserts[Int(index)] = instance
    }
}

/// Per-session visibility state the user controls from the sidebar.
public struct VisibilityState: Equatable {
    public var hiddenLayerIds: Set<Int> = []
    public var hiddenXrefIds: Set<Int> = []
    /// Locked layers stay visible but can't be selected or snapped to.
    public var lockedLayerIds: Set<Int> = []
    /// Layers created via the Layers panel's "+" button (or CLAYER naming a
    /// brand-new layer) THIS session, with zero entities drawn on them yet.
    /// `LayersPanel.usedLayers` normally filters to `entityCount > 0` (a
    /// layer's whole reason for showing up is having something to toggle),
    /// which would otherwise make a freshly-created empty layer invisible
    /// in its own creation UI — included here so it shows immediately
    /// instead of only appearing once the user draws on it.
    public var sessionCreatedLayerIds: Set<Int> = []

    public init() {}

    public init(hiddenLayerIds: Set<Int> = [], hiddenXrefIds: Set<Int> = [],
                lockedLayerIds: Set<Int> = [], sessionCreatedLayerIds: Set<Int> = []) {
        self.hiddenLayerIds = hiddenLayerIds
        self.hiddenXrefIds = hiddenXrefIds
        self.lockedLayerIds = lockedLayerIds
        self.sessionCreatedLayerIds = sessionCreatedLayerIds
    }

    public func isVisible(_ g: RenderGroup) -> Bool {
        if hiddenLayerIds.contains(g.layerId) { return false }
        if g.xrefId >= 0 && hiddenXrefIds.contains(g.xrefId) { return false }
        return true
    }

    /// Visible and not on a locked layer.
    public func isSelectable(_ g: RenderGroup) -> Bool {
        isVisible(g) && !lockedLayerIds.contains(g.layerId)
    }
}
