import Foundation
import CoreGraphics
import CADCore

// MARK: - AI Assistant: staged geometry-creation actions
//
// Sibling to `AIProposedEdit` (attribute value changes) for the aisle/dock
// tool catalog's WRITE half: `repair_aisle_network`, `route_along_aisles`,
// `shade_aisle_network`, `shade_dock_aprons` all CREATE geometry rather than
// edit an existing attribute, so they need their own staged-action shape —
// but the same governing product decision applies without exception: the
// assistant never touches the document itself. Every one of these tools
// computes its result eagerly (against `AisleNetwork`/`DockAprons`, both
// pure and fast enough to run synchronously inside the tool call) and stages
// the geometry as an `AIProposedGeometry`, which the panel UI shows for
// review; only the user's "Apply" commits it, as one undoable transaction,
// exactly mirroring `AIProposedEditApplier`.
//
// Staging the ALREADY-COMPUTED geometry (not just "a promise to compute it
// later") is a deliberate choice: it means what the user reviews in the
// panel is EXACTLY what gets drawn — no re-derivation gap between proposal
// and apply that could silently disagree if the document changed in
// between. The one exception is entity IDs referenced for context (e.g.
// which layer to draw on) are re-resolved by name at apply time, since a
// layer index from `RegenCoordinator` is a rebuild-time-transient int, not a
// stable id — see `AIProposedGeometryApplier.apply`.
struct AIProposedGeometry: Identifiable, Codable {
    let id: UUID

    enum Kind: String, Codable {
        /// Bridge segments for `repair_aisle_network` — plain LINE entities
        /// on a new "<source layer>-REPAIRED" layer.
        case aisleRepair
        /// One routed polyline for `route_along_aisles`.
        case route
        /// Ribbon fills for `shade_aisle_network`.
        case aisleShading
        /// Apron fills for `shade_dock_aprons`.
        case dockAprons
    }
    var kind: Kind

    /// Human-readable one-line summary for the review card
    /// ("Bridge 10 aisle gaps", "Route: Dock 4 → Station STN-101 (312 ft)").
    var summary: String

    /// Straight line segments to create (world space) — used by
    /// `.aisleRepair` (bridge connectors), whose segments are genuinely
    /// INDEPENDENT bridges between disconnected components (each one should
    /// be separately selectable/deletable), so one LINE each is correct.
    var lines: [LineSegmentDTO] = []
    /// Connected open paths to create as single LWPOLYLINE entities — used by
    /// `.route`, whose points form ONE continuous walked path. Emitting a
    /// route as one polyline rather than N disjoint LINEs matters for
    /// EDITABILITY: dragging a vertex of a polyline moves both adjoining
    /// segments with it (the path stays connected), whereas dragging one of N
    /// separate LINEs tears a gap at both its neighbours — see
    /// `GripEditing`'s own header comment on exactly this distinction.
    var polylines: [PolylineDTO] = []
    /// Closed polygon shapes to create — used by `.aisleShading` (ribbons)
    /// and `.dockAprons` (apron rectangles).
    var polygons: [PolygonDTO] = []

    /// Name of the NEW layer this geometry belongs on (auto-created if
    /// absent). Every kind here draws onto a dedicated overlay layer, never
    /// the source layer — matching `ShadeLayer`'s own precedent.
    var targetLayerName: String
    /// Drawing space in which the proposal was computed and must be applied.
    /// Without this, paper-space proposals were silently created in model
    /// space and appeared to do nothing after the user pressed Apply.
    var isPaperSpace: Bool
    /// ACI color for the new geometry (256 = ByLayer, so the layer's own
    /// color governs unless overridden).
    var aci: Int16 = 256

    /// When true, any EXISTING geometry already on `targetLayerName` is
    /// deleted before this geometry is added — the idempotent "redraw when
    /// circumstances change" behavior `ShadeLayer` already established,
    /// carried over here so repeatedly calling a tool (e.g. after docks
    /// shift) never stacks duplicates.
    var replaceExistingLayerContent: Bool = true

    struct LineSegmentDTO: Codable {
        var ax: Double, ay: Double, bx: Double, by: Double
        init(_ a: CGPoint, _ b: CGPoint) { ax = Double(a.x); ay = Double(a.y); bx = Double(b.x); by = Double(b.y) }
        var a: CGPoint { CGPoint(x: ax, y: ay) }
        var b: CGPoint { CGPoint(x: bx, y: by) }
    }

    struct PolygonDTO: Codable {
        var xs: [Double]
        var ys: [Double]
        init(_ points: [CGPoint]) { xs = points.map { Double($0.x) }; ys = points.map { Double($0.y) } }
        var points: [CGPoint] { zip(xs, ys).map { CGPoint(x: $0, y: $1) } }
    }

    /// An OPEN connected path (same point-list shape as `PolygonDTO`, but
    /// materialized as an open rather than closed LWPOLYLINE).
    struct PolylineDTO: Codable {
        var xs: [Double]
        var ys: [Double]
        init(_ points: [CGPoint]) { xs = points.map { Double($0.x) }; ys = points.map { Double($0.y) } }
        var points: [CGPoint] { zip(xs, ys).map { CGPoint(x: $0, y: $1) } }
    }

    init(id: UUID = UUID(), kind: Kind, summary: String, targetLayerName: String,
        lines: [LineSegmentDTO] = [], polygons: [PolygonDTO] = [],
        polylines: [PolylineDTO] = [],
        space: SpaceID = .model, aci: Int16 = 256,
        replaceExistingLayerContent: Bool = true) {
        self.id = id
        self.kind = kind
        self.summary = summary
        self.targetLayerName = targetLayerName
        self.isPaperSpace = space == .paper
        self.lines = lines
        self.polygons = polygons
        self.polylines = polylines
        self.aci = aci
        self.replaceExistingLayerContent = replaceExistingLayerContent
    }
}

@MainActor
enum AIProposedGeometryApplier {
    /// Commits every staged geometry action as ONE undoable transaction,
    /// mirroring `AIProposedEditApplier.apply`'s batch idiom. Each action's
    /// target layer is created (or reused) via `MarkupStore.ensureLayer`,
    /// existing content is cleared first when `replaceExistingLayerContent`
    /// is set (the `ShadeLayer` idempotency precedent), then lines become
    /// plain LINE entities and polygons become solid-fill HATCH entities —
    /// both already-proven persistence shapes elsewhere in this codebase
    /// (`DimensionTool`'s LINE members, `ShadeLayer`'s solid HATCH case), so
    /// this reuses rather than invents entity-construction conventions.
    @discardableResult
    static func apply(_ actions: [AIProposedGeometry], session: DocumentSession,
                      regen: RegenCoordinator) -> Int {
        guard !actions.isEmpty else { return 0 }
        var created = 0
        session.performEdit("AI Assistant Geometry") { tx in
            let parsed = regen.parsed
            let store = parsed.store
            for action in actions {
                let layerId = MarkupStore.ensureLayer(named: action.targetLayerName, in: parsed)
                let owner: OwnerRef = action.isPaperSpace ? .paper : .model

                if action.replaceExistingLayerContent {
                    for i in store.headers.indices {
                        let h = store.headers[i]
                        guard !h.flags.contains(.deleted), h.layerId == layerId,
                              (action.isPaperSpace ? h.owner.isPaper : h.owner.isModel) else { continue }
                        tx.delete(EntityID(raw: Int32(i)))
                    }
                }

                for line in action.lines {
                    let proto = EntityPrototype(type: .line, layerId: layerId, aci: action.aci, owner: owner,
                                                payload: .line(LinePayload(a: Vec3(line.a), b: Vec3(line.b))))
                    tx.add(proto)
                    created += 1
                }
                for path in action.polylines {
                    let pts = path.points
                    guard pts.count >= 2 else { continue }
                    // One OPEN LWPOLYLINE for the whole connected path, so
                    // grip-dragging an interior vertex keeps the route
                    // continuous instead of tearing it (see `polylines`' own
                    // doc comment).
                    let proto = EntityPrototype(type: .lwpolyline, layerId: layerId, aci: action.aci,
                                                 owner: owner,
                                                payload: .polyline(PolylinePayload(closed: false),
                                                                   vertices: pts.map { Vec3($0) },
                                                                   bulges: Array(repeating: 0, count: pts.count)))
                    tx.add(proto)
                    created += 1
                }
                for poly in action.polygons {
                    let pts = poly.points
                    guard pts.count >= 3 else { continue }
                    let vecs = pts.map { Vec3($0) }
                    let centroid = Vec3(x: vecs.reduce(0.0) { $0 + $1.x } / Double(vecs.count),
                                        y: vecs.reduce(0.0) { $0 + $1.y } / Double(vecs.count))
                    let payload = HatchPayload(isSolid: true, angle: 0, scale: 1, origin: centroid)
                    let proto = EntityPrototype(type: .hatch, layerId: layerId, aci: action.aci, owner: owner,
                                                payload: .hatch(payload, loops: [vecs]))
                    tx.add(proto)
                    created += 1
                }
            }
        }
        return created
    }
}
