import Foundation
import CoreGraphics
import CADCore

/// Bounded, exact 2D geometry shared by tool inspection, proposal preview and Apply.
/// ARC uses either three points (start, through, end) or center/radius/CCW angles.
struct AIGeometryShape: Codable {
    var type: String
    var points: [[Double]] = []
    var bulges: [Double]? = nil
    var closed: Bool? = nil
    var center: [Double]? = nil
    var radius: Double? = nil
    var startAngle: Double? = nil
    var endAngle: Double? = nil

    private enum CodingKeys: String, CodingKey {
        case type, points, bulges, closed, center, radius, startAngle, endAngle
    }
    init(type: String, points: [[Double]] = [], bulges: [Double]? = nil, closed: Bool? = nil,
         center: [Double]? = nil, radius: Double? = nil, startAngle: Double? = nil, endAngle: Double? = nil) {
        self.type = type; self.points = points; self.bulges = bulges; self.closed = closed
        self.center = center; self.radius = radius; self.startAngle = startAngle; self.endAngle = endAngle
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        type = try c.decode(String.self, forKey: .type)
        points = try c.decodeIfPresent([[Double]].self, forKey: .points) ?? []
        bulges = try c.decodeIfPresent([Double].self, forKey: .bulges)
        closed = try c.decodeIfPresent(Bool.self, forKey: .closed)
        center = try c.decodeIfPresent([Double].self, forKey: .center)
        radius = try c.decodeIfPresent(Double.self, forKey: .radius)
        startAngle = try c.decodeIfPresent(Double.self, forKey: .startAngle)
        endAngle = try c.decodeIfPresent(Double.self, forKey: .endAngle)
    }

    func normalized() throws -> AIGeometryShape {
        func validPoint(_ p: [Double]) -> Bool { p.count == 2 && p.allSatisfy { $0.isFinite && abs($0) <= 1e9 } }
        guard points.count <= 128, points.allSatisfy(validPoint) else {
            throw AIToolError.invalidArgument("Use at most 128 finite 2D points per shape, within ±1e9 drawing units.")
        }
        var shape = self
        switch type {
        case "line", "polyline":
            guard points.count >= 2, type != "line" || points.count == 2,
                  closed != true || (type == "polyline" && points.count >= 3),
                  center == nil, radius == nil, startAngle == nil, endAngle == nil else {
                throw AIToolError.invalidArgument("Line needs two points; a closed polyline needs at least three. Do not mix line/polyline and arc parameters.")
            }
            let bs = bulges ?? Array(repeating: 0, count: points.count)
            guard bs.count == points.count, bs.allSatisfy({ $0.isFinite && abs($0) <= 100 }),
                  type != "line" || bs.allSatisfy({ $0 == 0 }),
                  closed == true || bs.last == 0 else {
                throw AIToolError.invalidArgument("One finite bulge per vertex is required; open paths end with bulge 0; lines cannot have bulges.")
            }
            let edgeCount = closed == true ? points.count : points.count - 1
            for i in 0..<edgeCount {
                let a = points[i], b = points[(i + 1) % points.count]
                guard hypot(a[0] - b[0], a[1] - b[1]) > 1e-9 else {
                    throw AIToolError.invalidArgument("Zero-length edges are not supported.")
                }
            }
            shape.bulges = type == "polyline" ? bs : nil
        case "arc", "circle":
            guard bulges == nil, closed == nil else { throw AIToolError.invalidArgument("Arcs/circles do not use closed or bulges.") }
            if type == "arc", points.count == 3 {
                guard center == nil, radius == nil, startAngle == nil, endAngle == nil else {
                    throw AIToolError.invalidArgument("Use three arc points OR center/radius/angles, not both.")
                }
                // Translate close to the origin before solving, avoiding cancellation
                // on georeferenced drawings. Use the same sweep convention as ARC.
                let origin = CGPoint(x: points[0][0], y: points[0][1])
                let p = points.map { CGPoint(x: $0[0] - origin.x, y: $0[1] - origin.y) }
                guard let arc = DraftState.arcThroughGeometry(p[0], p[1], p[2]) else {
                    throw AIToolError.invalidArgument("The three arc points are collinear or coincident.")
                }
                shape.points = []; shape.center = [arc.center.x + origin.x, arc.center.y + origin.y]
                shape.radius = arc.radius; shape.startAngle = arc.startDeg; shape.endAngle = arc.endDeg
            } else if !points.isEmpty {
                throw AIToolError.invalidArgument("An arc needs exactly three points; a circle uses center/radius.")
            }
            guard let c = shape.center, validPoint(c), let r = shape.radius, r.isFinite, r > 1e-9, r <= 1e9 else {
                throw AIToolError.invalidArgument("A finite center and positive radius within 1e9 drawing units are required.")
            }
            if type == "arc" {
                guard let a = shape.startAngle, let b = shape.endAngle, a.isFinite, b.isFinite,
                      abs(a) <= 360_000, abs(b) <= 360_000 else {
                    throw AIToolError.invalidArgument("Arc startAngle/endAngle must be finite degrees.")
                }
                let sweep = (b - a).truncatingRemainder(dividingBy: 360)
                guard abs(sweep) > 1e-8 else { throw AIToolError.invalidArgument("Use circle for a full circle; an arc must have a nonzero sweep.") }
            } else if shape.startAngle != nil || shape.endAngle != nil {
                throw AIToolError.invalidArgument("A circle does not use startAngle/endAngle.")
            }
        default: throw AIToolError.invalidArgument("Supported replacement types: line, polyline, arc, circle.")
        }
        return shape
    }

    /// Called only for normalized shapes (all required fields validated).
    var payload: EntityPayloadCopy {
        switch type {
        case "line": return .line(LinePayload(a: Vec3(x: points[0][0], y: points[0][1]), b: Vec3(x: points[1][0], y: points[1][1])))
        case "polyline": return .polyline(PolylinePayload(closed: closed ?? false),
            vertices: points.map { Vec3(x: $0[0], y: $0[1]) }, bulges: bulges ?? Array(repeating: 0, count: points.count))
        case "circle": return .circle(CirclePayload(center: Vec3(x: center![0], y: center![1]), radius: radius!))
        default: return .arc(ArcPayload(center: Vec3(x: center![0], y: center![1]), radius: radius!, startAngleDeg: startAngle!, endAngleDeg: endAngle!))
        }
    }
    var entityType: DXFEntityType { type == "line" ? .line : type == "polyline" ? .lwpolyline : type == "circle" ? .circle : .arc }

    var previewPoints: [CGPoint] {
        func samples(center: CGPoint, radius: Double, start: Double, sweep: Double) -> [CGPoint] {
            (0...64).map { i in
                let a = start + sweep * Double(i) / 64
                return CGPoint(x: center.x + radius * cos(a), y: center.y + radius * sin(a))
            }
        }
        if let c = center, let r = radius {
            let a = (startAngle ?? 0) * .pi / 180
            var sweep = ((endAngle ?? 360) - (startAngle ?? 0)).truncatingRemainder(dividingBy: 360)
            if sweep <= 0 { sweep += 360 }
            return samples(center: CGPoint(x: c[0], y: c[1]), radius: r, start: a, sweep: sweep * .pi / 180)
        }
        var result: [CGPoint] = []
        let count = closed == true ? points.count : points.count - 1
        guard count > 0 else { return [] }
        for i in 0..<count {
            let a = points[i], b = points[(i + 1) % points.count], bulge = bulges?[i] ?? 0
            if abs(bulge) > 1e-12 {
                let arc = bulgeToArc(from: Vec2(a[0], a[1]), to: Vec2(b[0], b[1]), bulge: bulge)
                result += samples(center: CGPoint(x: arc.center.x, y: arc.center.y), radius: arc.r, start: arc.startAngle, sweep: arc.sweep)
            } else { result += [CGPoint(x: a[0], y: a[1]), CGPoint(x: b[0], y: b[1])] }
        }
        return result
    }
}

struct AIGeometryEditPlan: Codable {
    struct Edit: Codable {
        var entityIds: [Int32]
        var replacements: [AIGeometryShape]
        var before: [AIGeometryShape] = []
        private enum CodingKeys: String, CodingKey { case entityIds, replacements, before }
        init(entityIds: [Int32], replacements: [AIGeometryShape], before: [AIGeometryShape] = []) {
            self.entityIds = entityIds; self.replacements = replacements; self.before = before
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            entityIds = try c.decode([Int32].self, forKey: .entityIds)
            replacements = try c.decode([AIGeometryShape].self, forKey: .replacements)
            before = try c.decodeIfPresent([AIGeometryShape].self, forKey: .before) ?? []
        }
    }
    let documentID: UUID
    let revision: UInt64
    let paper: Bool
    let sheetID: UInt64?
    var edits: [Edit]
    var explodeBlockIDs: [Int32]? = nil
    var curveEntityIds: [Int32]? = nil
}

@MainActor
enum AIGeometryEditing {
    /// Never expose local block coordinates as editable world coordinates. Paper
    /// layout blocks are roots; ordinary reusable block definitions are not.
    static func inspect(_ id: EntityID, regen: RegenCoordinator, visibility: VisibilityState, space: SpaceID) throws -> AIGeometryShape {
        let parsed = regen.parsed, store = parsed.store
        guard let h = store.header(id), !h.flags.contains(.deleted), !h.flags.contains(.invisible), !h.flags.contains(.mirrorOCS) else {
            throw AIToolError.invalidArgument("Object \(id.raw) is missing, invisible or has unsupported mirrored coordinates.")
        }
        let ownership = PaperLayoutOwnership(parsed)
        let sheet = ownership.ownerSheetID(for: id, in: store)
        guard space == .model ? h.owner.isModel : (sheet != nil && sheet == parsed.activePaperLayoutID) else {
            throw AIToolError.invalidArgument("Object \(id.raw) is not a root object on the active sheet/space. Nested block or xref geometry cannot be replaced by this tool.")
        }
        let layer = Int(h.layerId)
        guard parsed.layers.indices.contains(layer), !parsed.layers[layer].name.contains("|"),
              !visibility.hiddenLayerIds.contains(layer), !visibility.lockedLayerIds.contains(layer) else {
            throw AIToolError.invalidArgument("Object \(id.raw) is on a hidden, locked or external-reference layer.")
        }
        let residual = store.residualPairs[id.raw]?.pairs ?? []
        guard [.line, .lwpolyline, .polyline2d, .arc, .circle].contains(h.type),
              store.xdata[id.raw] == nil,
              !residual.contains(where: { ![100, 330, 410, 48].contains(Int($0.code)) }) else {
            throw AIToolError.invalidArgument("Object \(id.raw) has attached metadata, thickness or variable width that this replacement tool cannot preserve.")
        }
        guard let image = store.snapshot(id) else { throw AIToolError.documentUnavailable }
        func points(_ p: [Vec3]) throws -> [[Double]] {
            guard p.allSatisfy({ abs($0.z) < 1e-9 }) else { throw AIToolError.invalidArgument("Only flat 2D geometry at Z=0 can be replaced.") }
            return p.map { [$0.x, $0.y] }
        }
        let shape: AIGeometryShape
        switch image.payloadCopy {
        case .line(let p): shape = AIGeometryShape(type: "line", points: try points([p.a, p.b]))
        case .polyline(let p, let vertices, let bulges):
            guard !p.is3D, abs(p.elevation) < 1e-9, p.constantWidth == 0 else { throw AIToolError.invalidArgument("Only zero-width 2D polylines are supported.") }
            shape = AIGeometryShape(type: "polyline", points: try points(vertices), bulges: bulges, closed: p.closed)
        case .arc(let p):
            guard p.extrusionZ == 1 else { throw AIToolError.invalidArgument("Unsupported arc extrusion.") }
            shape = AIGeometryShape(type: "arc", center: try points([p.center])[0], radius: p.radius, startAngle: p.startAngleDeg, endAngle: p.endAngleDeg)
        case .circle(let p): shape = AIGeometryShape(type: "circle", center: try points([p.center])[0], radius: p.radius)
        default: throw AIToolError.invalidArgument("Object \(id.raw) is \(h.type). This tool reshapes lines, 2D polylines, arcs and circles; it does not edit blocks, text or dimensions.")
        }
        return try shape.normalized()
    }

    /// Unpack simple curves from one planar block instance; retain complex
    /// content in a private remainder block at its original transform.
    static func inspectBlock(_ id: EntityID, regen: RegenCoordinator, visibility: VisibilityState, space: SpaceID, curveEntityIds: [Int32]? = nil) throws -> Int {
        let parsed = regen.parsed, store = parsed.store
        guard let h = store.header(id), h.type == .insert, !h.flags.contains(.deleted),
              !h.flags.contains(.invisible), !h.flags.contains(.mirrorOCS),
              parsed.layers.indices.contains(Int(h.layerId)),
              !visibility.hiddenLayerIds.contains(Int(h.layerId)), !visibility.lockedLayerIds.contains(Int(h.layerId)) else {
            throw AIToolError.invalidArgument("Choose a visible, unlocked block instance.")
        }
        let sheet = PaperLayoutOwnership(parsed).ownerSheetID(for: id, in: store)
        guard space == .model ? h.owner.isModel : (sheet != nil && sheet == parsed.activePaperLayoutID) else {
            throw AIToolError.invalidArgument("Choose a root block instance on the active sheet/space. Use query_entities with types:[insert].")
        }
        guard !(store.residualPairs[id.raw]?.pairs ?? []).contains(where: { ![100, 330, 410, 48].contains(Int($0.code)) }) else {
            throw AIToolError.invalidArgument("This block instance has display properties or metadata that ungrouping cannot preserve.")
        }
        let p = store.inserts[Int(h.payload)]
        guard let block = parsed.blocks[store.strings.string(for: p.blockNameId)],
              !block.isXref, !block.isXrefDependent, block.entityCount > 0, block.entityCount <= 50_000,
              p.rows == 1, p.cols == 1, p.scale.x > 0, abs(p.scale.x - p.scale.y) < 1e-9,
              p.scale.z == 1, abs(p.position.z) < 1e-9,
              [p.scale.x, p.scale.y, p.rotationDeg, p.position.x, p.position.y].allSatisfy(\.isFinite) else {
            throw AIToolError.invalidArgument("Unpacking requires a local, uniformly scaled 2D block (no arrays/xrefs; at most 50,000 children).")
        }
        let children = (Int(block.entityStart)..<Int(block.entityStart + block.entityCount)).map { EntityID(raw: Int32($0)) }
        let parentChildren = store.childrenByParent()
        for source in [id] + children {
            guard let ch = store.header(source), !ch.flags.contains(.deleted) else { continue }
            let residual = store.residualPairs[source.raw]?.pairs ?? []
            // Cloning unknown handle references or live ATTRIB ownership would
            // need a separate reference-remapping operation. Refuse atomically.
            guard store.xdata[source.raw] == nil,
                  !residual.contains(where: { ([102, 1005].contains(Int($0.code)) || ((320...369).contains(Int($0.code)) && $0.code != 330)) }),
                  (parentChildren[source.raw] ?? []).isEmpty else {
                throw AIToolError.invalidArgument("This block has attached metadata or attributes that instance unpacking cannot preserve.")
            }
        }
        let eligible = Set(children.filter { extractable($0, store: store, visibility: visibility) }.map(\.raw))
        if let requested = curveEntityIds {
            guard !requested.isEmpty, requested.count <= 64, Set(requested).count == requested.count,
                  Set(requested).isSubset(of: eligible) else {
                throw AIToolError.invalidArgument("Specify 1–64 distinct directly editable curve IDs inside this block. Read IDs using query_entities; nested-block children require their own instance.")
            }
        }
        let count = curveEntityIds?.count ?? eligible.count
        guard count > 0 else { throw AIToolError.invalidArgument("This block has no directly editable, unlocked 2D curves. Nested blocks remain grouped.") }
        return count
    }

    /// Resolve the exact source set while staging. Persist those IDs even for
    /// small "all curves" requests so visibility changes cannot alter the plan.
    static func editableCurveIDs(in id: EntityID, regen: RegenCoordinator, visibility: VisibilityState) -> [Int32] {
        let store = regen.parsed.store
        let header = store.header(id)!
        let insert = store.inserts[Int(header.payload)]
        let block = regen.parsed.blocks[store.strings.string(for: insert.blockNameId)]!
        return (block.entityStart..<(block.entityStart + block.entityCount)).filter {
            extractable(EntityID(raw: $0), store: store, visibility: visibility)
        }
    }

    private static func extractable(_ id: EntityID, store: EntityStore, visibility: VisibilityState) -> Bool {
        guard let h = store.header(id), !h.flags.contains(.deleted), !h.flags.contains(.invisible),
              !h.flags.contains(.mirrorOCS), !visibility.lockedLayerIds.contains(Int(h.layerId)),
              !visibility.hiddenLayerIds.contains(Int(h.layerId)),
              [.line, .arc, .circle, .lwpolyline, .polyline2d].contains(h.type),
              !(store.residualPairs[id.raw]?.pairs ?? []).contains(where: { ![100, 330, 410, 48].contains(Int($0.code)) }) else { return false }
        switch store.snapshot(id)!.payloadCopy {
        case .line(let p): return p.a.z == 0 && p.b.z == 0
        case .arc(let p): return p.center.z == 0 && p.extrusionZ == 1
        case .circle(let p): return p.center.z == 0
        case .polyline(let p, let vertices, _): return !p.is3D && p.elevation == 0 && p.constantWidth == 0 && vertices.allSatisfy { $0.z == 0 }
        default: return false
        }
    }

    /// Extract curves from ONE instance. Everything else stays in a private
    /// remainder block with the original transform, preserving text and hatch
    /// pattern residuals in their original coordinate system. No shared source
    /// entities or definitions are edited; structural changes participate in Undo.
    private static func unpack(_ id: EntityID, tx: Transaction, regen: RegenCoordinator,
                               visibility: VisibilityState, paper: Bool, curveEntityIds: [Int32]?) {
        let parsed = regen.parsed, store = parsed.store
        let image = store.snapshot(id)!, h = image.header
        let ip = store.inserts[Int(h.payload)]
        let block = parsed.blocks[store.strings.string(for: ip.blockNameId)]!
        let children = (block.entityStart..<(block.entityStart + block.entityCount)).map { EntityID(raw: $0) }.filter { !store.isDeleted($0) }
        let requested = curveEntityIds.map(Set.init)
        let curves = children.filter { (requested?.contains($0.raw) ?? true) && extractable($0, store: store, visibility: visibility) }
        let curveSet = Set(curves)
        let retained = children.filter { !curveSet.contains($0) }
        let owner: OwnerRef = paper ? .paper : .model
        if !retained.isEmpty {
            let def = EditableBlockDef()
            def.name = "NOVACAD-REMAINDER-" + UUID().uuidString
            def.base = block.base
            def.blockIndex = (parsed.blocks.values.map(\.blockIndex).max() ?? -1) + 1
            def.entityStart = Int32(store.count)
            for source in retained {
                let sourceImage = store.snapshot(source)!
                let newID = tx.add(sourceImage.asPrototype(owner: .block(def.blockIndex)))
                // Keep all untransformed data (including pattern definitions).
                // An entity's old block-owner handle must not follow its clone.
                if let blob = store.residualPairs[source.raw] {
                    store.residualPairs[newID.raw] = RawPairBlob(pairs: blob.pairs.filter { $0.code != 330 && $0.code != 410 })
                }
                tx.modifyHeader(newID) { $0.flags = sourceImage.header.flags.subtracting([.deleted, .paperSpace]) }
            }
            def.entityCount = Int32(retained.count)
            parsed.blocks[def.name] = def
            tx.registerSideEffect(undo: { parsed.blocks[def.name] = nil }, redo: { parsed.blocks[def.name] = def })
            var proto = image.asPrototype(owner: owner)
            var remainder = ip; remainder.blockNameId = store.strings.intern(def.name)
            proto.payload = .insert(remainder)
            tx.add(proto)
        }
        let angle = ip.rotationDeg * .pi / 180, c = cos(angle) * ip.scale.x, s = sin(angle) * ip.scale.x
        let transform = Transform2(m11: c, m12: -s, m21: s, m22: c,
            tx: ip.position.x - c * block.base.x + s * block.base.y,
            ty: ip.position.y - s * block.base.x - c * block.base.y)
        var inherited = PropertyResolver.resolveTopLevel(layerId: h.layerId, aci: h.aci, trueColor: h.trueColor, linetypeId: h.linetypeId)
        let parentLayer = parsed.layers[Int(h.layerId)]
        // BYBLOCK on a child inherits the parent's resolved appearance, not
        // the child's own layer after extraction.
        if h.aci == 256, h.trueColor == 0xFF00_0000 {
            inherited.aci = 7
            switch parentLayer.color {
            case .foreground: inherited.trueColor = 0xFF00_0000
            case .rgb(let rgb): inherited.trueColor = rgb
            }
        }
        if h.linetypeId == -1 { inherited.linetypeId = Int16(clamping: parentLayer.linetypeId) }
        for source in curves {
            let sourceImage = store.snapshot(source)!, ch = sourceImage.header
            let resolved = PropertyResolver.resolveForExplode(entityLayerId: ch.layerId, entityAci: ch.aci,
                entityTrueColor: ch.trueColor, entityLinetypeId: ch.linetypeId, insertResolved: inherited)
            var proto = sourceImage.asPrototype(owner: owner)
            proto.layerId = resolved.layerId; proto.aci = resolved.aci
            proto.trueColor = resolved.trueColor; proto.linetypeId = resolved.linetypeId
            if proto.lineweight == -2 { proto.lineweight = h.lineweight == -1 ? parentLayer.lineweight : h.lineweight }
            EntityTransform.apply(transform, to: &proto.payload, mirrtext: false)
            tx.add(proto)
        }
        tx.delete(id)
        // The renderer recovers unused definitions as model-space content.
        // Retire this definition only when no live INSERT/DIMENSION refers to
        // it anywhere (including nested blocks); otherwise it must stay shared.
        let stillReferenced = store.headers.contains { header in
            guard !header.flags.contains(.deleted) else { return false }
            let nameID: Int32
            if header.type == .insert { nameID = store.inserts[Int(header.payload)].blockNameId }
            else if header.type == .dimension { nameID = store.dimensions[Int(header.payload)].blockNameId }
            else { return false }
            return store.strings.string(for: nameID) == block.name
        }
        if !stillReferenced {
            // The writer groups by owner index rather than entityStart/count.
            // Tombstone retired children too, so a future block-index reuse
            // cannot resurrect them in a newly created definition on save.
            for child in children { tx.delete(child) }
            parsed.blocks[block.name] = nil
            tx.registerSideEffect(undo: { parsed.blocks[block.name] = block }, redo: { parsed.blocks[block.name] = nil })
        }
    }

    static func validate(_ plan: AIGeometryEditPlan, regen: RegenCoordinator, visibility: VisibilityState, space: SpaceID) throws {
        guard plan.documentID == regen.geometryEditIdentity, plan.revision == regen.parsed.document.revision else {
            throw AIToolError.invalidArgument("The drawing changed since this proposal. Discard it and request a fresh geometry proposal.")
        }
        guard plan.paper == (space == .paper), !plan.paper || plan.sheetID == regen.parsed.activePaperLayoutID else {
            throw AIToolError.invalidArgument("Return to the proposal's sheet and drawing space before applying it.")
        }
        for raw in plan.explodeBlockIDs ?? [] {
            _ = try inspectBlock(EntityID(raw: raw), regen: regen, visibility: visibility, space: space, curveEntityIds: plan.curveEntityIds)
        }
        var ids = Set<Int32>()
        for edit in plan.edits {
            for raw in edit.entityIds {
                guard ids.insert(raw).inserted else { throw AIToolError.invalidArgument("An object appears in more than one replacement.") }
                _ = try inspect(EntityID(raw: raw), regen: regen, visibility: visibility, space: space)
            }
            for shape in edit.replacements { _ = try shape.normalized() }
        }
    }

    static func apply(_ plan: AIGeometryEditPlan, tx: Transaction, regen: RegenCoordinator, visibility: VisibilityState) -> Int {
        let store = regen.parsed.store
        var changed = 0
        for raw in plan.explodeBlockIDs ?? [] {
            unpack(EntityID(raw: raw), tx: tx, regen: regen, visibility: visibility, paper: plan.paper, curveEntityIds: plan.curveEntityIds)
            changed += 1
        }
        for edit in plan.edits {
            let h = store.header(EntityID(raw: edit.entityIds[0]))!
            for raw in edit.entityIds { tx.delete(EntityID(raw: raw)); changed += 1 }
            for shape in edit.replacements {
                tx.add(EntityPrototype(type: shape.entityType, layerId: h.layerId, aci: h.aci,
                    trueColor: h.trueColor, linetypeId: h.linetypeId, lineweight: h.lineweight,
                    owner: plan.paper ? .paper : .model, ltScale: h.ltScale, payload: shape.payload))
            }
        }
        return changed
    }
}
