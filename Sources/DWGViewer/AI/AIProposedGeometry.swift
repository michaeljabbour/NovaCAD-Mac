import Foundation
import CoreGraphics
import CADCore

// Attribute edits and geometry changes share the same stage/review/Apply model.
// Creation tools precompute their output. Existing-object edits carry normalized
// replacements plus a document/revision guard. Block extraction is recomputed
// only after that guard passes, so it cannot silently use a changed definition.
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
        case editGeometry
    }
    var kind: Kind
    /// Exact replacements of inspected source objects; never a layer-wide erase.
    var editPlan: AIGeometryEditPlan? = nil

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
                      regen: RegenCoordinator) throws -> Int {
        guard !actions.isEmpty else { return 0 }
        // Validate the complete batch before starting any transaction, including
        // proposals accumulated across multiple tool calls or turns.
        guard session.regen === regen else { throw AIToolError.documentUnavailable }
        let unpacksBlocks = actions.contains { !($0.editPlan?.explodeBlockIDs ?? []).isEmpty }
        if unpacksBlocks && actions.contains(where: { $0.editPlan == nil && $0.replaceExistingLayerContent }) {
            throw AIToolError.invalidArgument("Apply block unpacking separately from proposals that clear a layer.")
        }
        var editedIDs = Set<Int32>()
        for action in actions {
            if let plan = action.editPlan {
                try AIGeometryEditing.validate(plan, regen: regen, visibility: session.visibility,
                    space: session.space == .paper ? .paper : .model)
                for id in plan.edits.flatMap(\.entityIds) + (plan.explodeBlockIDs ?? []) {
                    guard editedIDs.insert(id).inserted else {
                        throw AIToolError.invalidArgument("Two proposals change the same object. Discard the older proposal first.")
                    }
                }
            }
        }
        // A layer-clearing creation action must not erase replacement targets
        // (or the just-created replacement) within the same batch.
        for action in actions where action.editPlan == nil && action.replaceExistingLayerContent {
            let layer = regen.parsed.layerIdByName[action.targetLayerName]
            guard !editedIDs.contains(where: { regen.parsed.store.header(EntityID(raw: $0))?.layerId == layer }) else {
                throw AIToolError.invalidArgument("A layer-clearing proposal conflicts with geometry edits on that layer. Apply these separately.")
            }
        }
        var created = 0
        session.performEdit("AI Assistant Geometry") { tx in
            let parsed = regen.parsed
            let store = parsed.store
            for action in actions {
                if let plan = action.editPlan {
                    created += AIGeometryEditing.apply(plan, tx: tx, regen: regen, visibility: session.visibility)
                    continue
                }
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
        session.selection = session.selection.filter { !regen.parsed.store.isDeleted($0) }
        return created
    }
}
