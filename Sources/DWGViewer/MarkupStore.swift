import Foundation
import CADCore
import CoreGraphics

// MARK: - Phase 1.7: markup unification
//
// Per the plan's 1.7 spec, user-drawn markup ("Draw" tools, block Stamp, Move)
// is no longer a separate `[DrawnEntity]` array living on `DocumentSession` —
// it's ordinary `EntityStore` entities on the `NOVACAD-MARKUP` layer, added
// via the same `EditableDocument.begin/commit` transaction machinery as any
// other edit. This file provides the two directions of conversion the live
// app needs to keep `DrawnEntity`-shaped code (the existing `DraftState`
// geometry composition, and `DXFWriter`'s two existing export functions,
// neither of which needs to change) working unchanged:
//
//   - `MarkupStore.prototype(for:aci:layerId:)`: DrawnEntity.Shape -> EntityPrototype,
//     used by the new `commitDrawn`/`placeStamp`/Move-tool bodies to build the
//     transaction that actually adds the markup to the store.
//   - `MarkupStore.drawnEntities(in:isPaper:)`: EntityStore -> [DrawnEntity],
//     used by (a) DXF export ("Export Markup as DXF" / "Save Copy with
//     Markup" still call DXFWriter.writeMarkupDXF/writeMergedCopy, which take
//     [DrawnEntity] — this reconstructs that array from the live store) and
//     (b) reload preservation (a reload re-parses the file from disk, which
//     naturally does NOT include in-session-only markup — the old code
//     carried `drawn` forward via `ReloadSnapshot`; the new code captures the
//     OLD store's markup as [DrawnEntity] the same way, then re-commits it
//     into the FRESH store after reload via `prototype(for:)`).
enum MarkupStore {

    static let layerName = DXFWriter.markupLayer

    /// Finds or creates the `NOVACAD-MARKUP` layer in `parsed`, returning its
    /// stable layer id. MUST be called before `Regenerator.build`/
    /// `RegenCoordinator.load` finishes building the `DXFDocument` for the
    /// FIRST time after a (re)load, because `DXFDocument.layers` is an
    /// immutable `let` populated once from `parsed.layers` at build time —
    /// unlike `modelGroups`/`paperGroups` (which `RegenCoordinator.appendGroup`
    /// can grow after the fact), there is no append-a-layer-after-load path.
    /// Pre-registering the layer here means it has a real, stable id from the
    /// very first render, exactly like any layer the file itself defined, so
    /// markup drawn in the first session immediately participates in the
    /// layers sidebar / visibility / lock machinery like any other layer.
    @discardableResult
    static func ensureMarkupLayer(in parsed: EditableParsedDocument) -> Int32 {
        ensureLayer(named: layerName, in: parsed, defaultColor: .rgb(0xFF0000))
    }

    /// General find-or-create-layer helper, used by `ensureMarkupLayer`
    /// above and by the live app's editable "Layer" field on the markup
    /// properties panel (retargeting selected markup to an arbitrary,
    /// possibly brand-new, layer name). Case-SENSITIVE exact match against
    /// `parsed.layerIdByName`, matching how the DXF parser itself interns
    /// layer names (see `EntityStoreParser.internLayer`). Returns the
    /// EXISTING id when `name` already names a layer — including one the
    /// file itself defines — so retargeting markup onto a real drawing layer
    /// reuses that layer's id/appearance exactly, not a shadow copy.
    @discardableResult
    static func ensureLayer(named name: String, in parsed: EditableParsedDocument,
                            defaultColor: ResolvedColor = .foreground) -> Int32 {
        if let existing = parsed.layerIdByName[name] { return existing }
        let id = Int32(parsed.layers.count)
        parsed.layers.append(DXFLayer(id: Int(id), name: name, color: defaultColor))
        parsed.layerIdByName[name] = id
        return id
    }

    // MARK: - DrawnEntity.Shape -> EntityPrototype

    /// Builds the prototype `Transaction.add(_:)` needs to create one markup
    /// entity from a `DrawnEntity`. `owner` is `.model` or `.paper` per
    /// whichever space was active when the shape was drawn (mirrors the old
    /// `DrawnEntity.isPaper` flag exactly — group 67 in the DXF sense).
    static func prototype(for e: DrawnEntity, layerId: Int32, store: EntityStore) -> EntityPrototype {
        let owner: OwnerRef = e.isPaper ? .paper : .model
        let aci = Int16(e.aci)
        func proto(_ type: DXFEntityType, _ payload: EntityPayloadCopy) -> EntityPrototype {
            EntityPrototype(type: type, layerId: layerId, aci: aci, owner: owner, payload: payload)
        }
        switch e.shape {
        case .line(let a, let b):
            return proto(.line, .line(LinePayload(a: Vec3(a), b: Vec3(b))))
        case .polyline(let pts, let closed):
            let bulges = [Double](repeating: 0, count: pts.count)
            return proto(.lwpolyline, .polyline(
                PolylinePayload(closed: closed), vertices: pts.map(Vec3.init), bulges: bulges))
        case .circle(let c, let r):
            return proto(.circle, .circle(CirclePayload(center: Vec3(c), radius: Double(r))))
        case .arc(let c, let r, let s, let en):
            return proto(.arc, .arc(ArcPayload(center: Vec3(c), radius: Double(r),
                                               startAngleDeg: s, endAngleDeg: en)))
        case .rect(let a, let b):
            let pts = [CGPoint(x: a.x, y: a.y), CGPoint(x: b.x, y: a.y),
                      CGPoint(x: b.x, y: b.y), CGPoint(x: a.x, y: b.y)]
            let bulges = [Double](repeating: 0, count: pts.count)
            return proto(.lwpolyline, .polyline(
                PolylinePayload(closed: true), vertices: pts.map(Vec3.init), bulges: bulges))
        case .text(let pos, let h, let str):
            let sid = store.strings.intern(str)
            return proto(.text, .text(TextPayload(position: Vec3(pos), height: Double(h), stringId: sid)))
        }
    }

    // MARK: - EntityStore -> [DrawnEntity]  (export + reload-preservation)

    /// Reconstructs `[DrawnEntity]` from every LIVE (non-deleted) entity on
    /// the markup layer in `store` — the inverse of `prototype(for:)`, used
    /// wherever the app still needs the legacy `[DrawnEntity]` shape:
    /// `DXFWriter.writeMarkupDXF`/`writeMergedCopy` (export) and
    /// `ReloadSnapshot` (reload preservation). Only the entity TYPES
    /// `prototype(for:)` itself ever produces are recognized — a store could
    /// in principle contain other entity types on this layer (e.g. if a
    /// FUTURE editing command changes an existing entity's layer to
    /// NOVACAD-MARKUP), and those are silently skipped rather than crashing;
    /// this mirrors today's behavior where only tool-drawn shapes ever
    /// populated `drawn` in the first place.
    static func drawnEntities(in store: EntityStore, layerId: Int32) -> [DrawnEntity] {
        var result: [DrawnEntity] = []
        result.reserveCapacity(64)
        for i in store.headers.indices {
            let h = store.headers[i]
            guard !h.flags.contains(.deleted), h.layerId == layerId, h.payload >= 0 else { continue }
            guard let shape = shape(for: h, at: i, store: store) else { continue }
            var e = DrawnEntity(shape: shape)
            e.aci = h.aci == 256 ? 1 : Int(h.aci)   // BYLAYER markup (shouldn't occur) falls back to red
            e.isPaper = h.owner.isPaper
            result.append(e)
        }
        return result
    }

    /// Public `EntityID`-keyed wrapper around the same reconstruction
    /// `drawnEntities(in:layerId:)` uses internally — for callers that need
    /// ONE entity's shape rather than a whole-layer scan (e.g. the live
    /// app's Move-tool ghost preview, which only needs to look up the
    /// handful of currently-selected entities, not scan every entity on the
    /// markup layer). Works for ANY entity type this reader recognizes,
    /// regardless of layer — the ghost preview isn't markup-specific.
    ///
    /// HATCH is handled HERE rather than in the shared `shape(for:)` reader
    /// on purpose: a ghost wants a visible OUTLINE of the filled area (drawn
    /// as a closed polyline, since `DrawnEntity.Shape` has no filled case),
    /// but `shape(for:)` also backs markup EXPORT (`writeMarkupDXF`/
    /// `writeMergedCopy`), where silently turning a solid fill into an
    /// unfilled polyline would corrupt the exported drawing. Without this,
    /// Move/Modify of any shaded area (`ShadeLayer` solid fill, the AI
    /// Assistant's aisle/dock shading) committed correctly but showed NO
    /// preview while dragging — which reads as "nothing is happening / this
    /// object can't be edited."
    static func shapeForGhost(id: EntityID, store: EntityStore) -> DrawnEntity.Shape? {
        guard let h = store.header(id), !h.flags.contains(.deleted), h.payload >= 0 else { return nil }
        if h.type == .hatch {
            let hp = store.hatches[Int(h.payload)]
            guard hp.loopRangeCount > 0 else { return nil }
            // The OUTER boundary (loop 0) is what a drag preview needs; inner
            // island loops would clutter the ghost without telling the user
            // anything more about where the shape is landing.
            let range = store.hatchLoopRanges[Int(hp.loopRangeStart)]
            let start = Int(range.vertStart)
            let pts = (0..<Int(range.vertCount)).map { store.vertexArena[start + $0].cgPoint }
            guard pts.count >= 2 else { return nil }
            return .polyline(pts: pts, closed: true)
        }
        return shape(for: h, at: Int(id.raw), store: store)
    }

    private static func shape(for h: EntityHeader, at index: Int, store: EntityStore) -> DrawnEntity.Shape? {
        let p = Int(h.payload)
        switch h.type {
        case .line:
            let l = store.lines[p]
            return .line(a: l.a.cgPoint, b: l.b.cgPoint)
        case .lwpolyline, .polyline2d, .polyline3d:
            let pl = store.polylines[p]
            let verts = (0..<Int(pl.vertsCount)).map { store.vertexArena[Int(pl.vertsStart) + $0].cgPoint }
            // A rect round-trips through this reader as a closed 4-point
            // polyline — indistinguishable from (and behaviorally identical
            // to) a hand-drawn closed polyline, which is fine: nothing
            // downstream (export, reload) cares which drafting tool produced
            // the shape, only its final geometry.
            return .polyline(pts: verts, closed: pl.closed)
        case .circle:
            let c = store.circles[p]
            return .circle(center: c.center.cgPoint, radius: CGFloat(c.radius))
        case .arc:
            let a = store.arcs[p]
            return .arc(center: a.center.cgPoint, radius: CGFloat(a.radius),
                       startDeg: a.startAngleDeg, endDeg: a.endAngleDeg)
        case .text:
            let t = store.texts[p]
            return .text(position: t.position.cgPoint, height: CGFloat(t.height),
                        string: store.strings.string(for: t.stringId))
        default:
            return nil
        }
    }
}

private extension Vec3 {
    init(_ p: CGPoint) { self.init(x: Double(p.x), y: Double(p.y)) }
}
