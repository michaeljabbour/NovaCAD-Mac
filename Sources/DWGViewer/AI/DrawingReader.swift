import Foundation
import CoreGraphics
import CADCore

// MARK: - AI Assistant: reading the drawing
//
// The read-side half of the AI Assistant feature: a compact, JSON-friendly
// summary of every entity currently in the live document (type, layer, text
// content, world-space position/bounding box), plus the one piece of spatial
// query the "rename the workstation from its label" use case needs — "which
// INSERT (block reference) is world point P positioned inside of."
//
// Deliberately built on the ALREADY-EXPANDED, ALREADY-WORLD-SPACE render
// model (`DXFDocument.modelGroups`/`paperGroups`/`inserts`), not a raw walk
// of `EntityStore.headers` — see this file's own `AIDrawingSummary.build`
// doc comment for why: the render model is what the user actually SEES
// (orphan-root block content, INSERT-transformed positions, etc. already
// resolved), and every primitive already carries `.entityId`/`.insertId`
// back-references to resolve to a stable `EntityID` for editing.
enum DrawingReader {

    /// One entity, summarized for the AI's consumption. `entityId` is the
    /// stable `EntityID.raw` — round-tripped back by the AI (via
    /// `AIToolExecutor`) to target a bulk edit at this exact entity.
    struct EntitySummary: Codable {
        var entityId: Int32
        /// "line", "circle", "text", "insert", etc. — `DXFEntityType`'s own
        /// case name (lowercased), not the display-friendly `EntityKind.label`
        /// (kept machine-stable so the AI can reliably filter/match on it
        /// across turns without this string's wording ever being tuned for
        /// human readability and silently breaking a prior turn's filter).
        var type: String
        var layer: String
        /// World-space bounding box (already accounts for any owning
        /// INSERT's transform, unlike raw `EntityStore.bounds(_:)`).
        var minX: Double
        var minY: Double
        var maxX: Double
        var maxY: Double
        /// TEXT/MTEXT/ATTRIB only — the resolved plain-text content.
        var text: String?
        /// INSERT only — the block definition name it references.
        var blockName: String?
        /// ATTRIB only — the owning INSERT's stable `EntityID.raw`, so the
        /// AI can group "this label belongs to that block reference"
        /// without a separate spatial query.
        var ownerInsertId: Int32?
    }

    /// A bounded summary of the whole drawing — capped (see `maxEntities`)
    /// so a multi-million-entity production file doesn't blow up the LLM's
    /// context window; `truncated` tells the AI (and the panel UI) that the
    /// list isn't exhaustive.
    struct DrawingSummary: Codable {
        var space: String   // "model" or "paper"
        var entities: [EntitySummary]
        var truncated: Bool
        var totalEntityCount: Int
    }

    /// Hard cap on how many entities `summarize` includes — keeps the
    /// serialized JSON handed to the LLM to a reasonable size even on a
    /// large plant-layout drawing. High enough to cover the vast majority of
    /// real single-station/small-area layouts (the AI assistant's primary
    /// use case per this feature's scope) without paying full production-
    /// file (multi-million-entity) serialization cost on every turn.
    static let maxEntities = 4000

    /// Builds a summary of every entity currently rendered in `space`,
    /// walking the render-facing `RenderGroup`s (`strokes.runs/arcs/texts/
    /// points`) exactly like `HitTester`/`SelectionEngine` do — this is what
    /// guarantees the AI sees the SAME positions/content the user sees on
    /// canvas, including content reached only through an INSERT or an
    /// orphan-root block, without re-deriving any transform math here.
    static func summarize(document: DXFDocument, space: SpaceID, visibility: VisibilityState) -> DrawingSummary {
        let groups = space == .paper ? document.paperGroups : document.modelGroups
        var out: [EntitySummary] = []
        var total = 0
        var truncated = false

        func layerName(_ layerId: Int) -> String {
            guard layerId >= 0, layerId < document.layers.count else { return "?" }
            return document.layers[layerId].name
        }

        func appendIfRoom(_ summary: @autoclosure () -> EntitySummary) {
            total += 1
            guard out.count < maxEntities else { truncated = true; return }
            out.append(summary())
        }

        for g in groups where !visibility.hiddenLayerIds.contains(Int(g.layerId)) {
            let layer = layerName(Int(g.layerId))
            for run in g.strokes.runs where run.entityId >= 0 {
                let b = run.bounds
                appendIfRoom(EntitySummary(
                    entityId: run.entityId, type: run.kind.novaCADTypeName, layer: layer,
                    minX: b.minX, minY: b.minY, maxX: b.maxX, maxY: b.maxY,
                    text: nil, blockName: nil, ownerInsertId: run.insertId >= 0 ? run.insertId : nil))
            }
            for arc in g.strokes.arcs where arc.entityId >= 0 {
                let b = CGRect(x: arc.center.x - arc.radius, y: arc.center.y - arc.radius,
                               width: arc.radius * 2, height: arc.radius * 2)
                appendIfRoom(EntitySummary(
                    entityId: arc.entityId, type: arc.isFullCircle ? "circle" : "arc", layer: layer,
                    minX: b.minX, minY: b.minY, maxX: b.maxX, maxY: b.maxY,
                    text: nil, blockName: nil, ownerInsertId: arc.insertId >= 0 ? arc.insertId : nil))
            }
            for t in g.texts where t.entityId >= 0 {
                let ownerId: Int32? = t.insertId >= 0 ? insertEntityId(t.insertId, document: document, space: space)
                                                       : nil
                appendIfRoom(EntitySummary(
                    entityId: t.entityId, type: t.kind.novaCADTypeName, layer: layer,
                    minX: t.position.x, minY: t.position.y, maxX: t.position.x, maxY: t.position.y,
                    text: t.text, blockName: nil, ownerInsertId: ownerId))
            }
        }

        // Top-level INSERTs (block references) — not carried by RenderGroup
        // at all (see `DXFDocument.inserts`'s own doc comment: an INSERT
        // emits no geometry of its own). Each contributes its own summary
        // row, with a bounding box computed as the union of every primitive
        // this document tagged with its index (`insertId`) — i.e. exactly
        // the content the renderer/hit-tester already attribute to it.
        let insertRange = space == .paper
            ? document.modelInsertCount..<document.inserts.count
            : 0..<document.modelInsertCount
        for idx in insertRange {
            let ins = document.inserts[idx]
            guard !visibility.hiddenLayerIds.contains(Int(ins.layerId)) else { continue }
            let bbox = insertContentBounds(insertIndex: Int32(idx), groups: groups) ?? CGRect(origin: ins.position, size: .zero)
            appendIfRoom(EntitySummary(
                entityId: ins.entityId, type: "insert", layer: layerName(Int(ins.layerId)),
                minX: bbox.minX, minY: bbox.minY, maxX: bbox.maxX, maxY: bbox.maxY,
                text: nil, blockName: ins.name, ownerInsertId: nil))
        }

        return DrawingSummary(space: space == .paper ? "paper" : "model",
                              entities: out, truncated: truncated, totalEntityCount: total)
    }

    /// Resolves a positional INSERT index (as carried by `TextItem.insertId`/
    /// `StrokeStore.Run.insertId`) to that INSERT's stable `EntityID.raw` —
    /// `InsertInstance.entityId`, looked up by array index. -1 if
    /// unavailable (shouldn't happen for the live EntityStore-backed
    /// document this feature targets, but handled defensively).
    private static func insertEntityId(_ insertIndex: Int32, document: DXFDocument, space: SpaceID) -> Int32? {
        guard insertIndex >= 0, Int(insertIndex) < document.inserts.count else { return nil }
        let id = document.inserts[Int(insertIndex)].entityId
        return id >= 0 ? id : nil
    }

    /// World-space bounding box of every primitive tagged with `insertIndex`
    /// across `groups` — the "expanded content bounds of one top-level
    /// INSERT" query neither `EntityStore.bounds(_:)` (own-geometry only,
    /// ignores the INSERT transform) nor any existing function in the
    /// codebase provides (confirmed by this feature's own research phase).
    /// Reuses the render model's already-correct, already-transformed
    /// primitive bounds rather than re-deriving the INSERT transform matrix
    /// by hand — guarantees exact agreement with what's rendered/hit-tested.
    static func insertContentBounds(insertIndex: Int32, groups: [RenderGroup]) -> CGRect? {
        insertContentBoundsByIndex(groups: groups)[insertIndex]
    }

    /// Computes every INSERT footprint in one render-model pass. Large plant
    /// drawings can contain thousands of workstations; rescanning every
    /// primitive once per INSERT made exhaustive assistant tools effectively
    /// quadratic and caused them to time out before enumerating anything.
    static func insertContentBoundsByIndex(groups: [RenderGroup]) -> [Int32: CGRect] {
        var bounds: [Int32: CGRect] = [:]
        func include(_ insertId: Int32, _ rect: CGRect) {
            guard insertId >= 0 else { return }
            bounds[insertId] = bounds[insertId]?.union(rect) ?? rect
        }
        for g in groups {
            let tombstones = GroupTombstoneRegistry.tombstones(for: g)
            for (index, run) in g.strokes.runs.enumerated() {
                if let tombstones, tombstones.isDead(.run, Int32(index)) { continue }
                include(run.insertId, run.bounds)
            }
            for (index, arc) in g.strokes.arcs.enumerated() {
                if let tombstones, tombstones.isDead(.arc, Int32(index)) { continue }
                let b = CGRect(x: arc.center.x - arc.radius, y: arc.center.y - arc.radius,
                               width: arc.radius * 2, height: arc.radius * 2)
                include(arc.insertId, b)
            }
            for (index, run) in g.strokes.fillRuns.enumerated() {
                if let tombstones, tombstones.isDead(.fillRun, Int32(index)) { continue }
                include(run.insertId, run.bounds)
            }
            for (index, t) in g.texts.enumerated() {
                if let tombstones, tombstones.isDead(.text, Int32(index)) { continue }
                include(t.insertId, CGRect(x: t.position.x, y: t.position.y, width: 0, height: 0))
            }
            for (index, point) in g.points.enumerated() {
                if let tombstones, tombstones.isDead(.point, Int32(index)) { continue }
                guard index < g.strokes.pointInsertIds.count else { continue }
                include(g.strokes.pointInsertIds[index], CGRect(x: point.x, y: point.y, width: 0, height: 0))
            }
        }
        return bounds
    }

    /// "Which top-level INSERT (block reference) is world point `point`
    /// positioned inside of" — the spatial-containment query the
    /// workstation-renaming use case needs when a label TEXT isn't already
    /// an ATTRIB child of the block it names (e.g. a loose TEXT entity
    /// merely drawn on top of/near a block, not wired as its attribute).
    /// Returns the CONTAINING insert with the SMALLEST bounding-box area
    /// (innermost match) when several nested/overlapping INSERTs all
    /// contain the point, matching the intuitive "closest enclosing block"
    /// reading. nil if no top-level INSERT's content bounds contain the
    /// point.
    static func insertContaining(worldPoint: CGPoint, document: DXFDocument, space: SpaceID) -> InsertInstance? {
        let groups = space == .paper ? document.paperGroups : document.modelGroups
        let insertRange = space == .paper
            ? document.modelInsertCount..<document.inserts.count
            : 0..<document.modelInsertCount
        var best: (insert: InsertInstance, area: Double)? = nil
        for idx in insertRange {
            guard let bbox = insertContentBounds(insertIndex: Int32(idx), groups: groups),
                  bbox.contains(worldPoint) else { continue }
            let area = Double(bbox.width * bbox.height)
            if best == nil || area < best!.area {
                best = (document.inserts[idx], area)
            }
        }
        return best?.insert
    }
}

extension EntityKind {
    /// Machine-stable type name for `EntitySummary.type` — distinct from
    /// `.label` (a display string, e.g. "3D Face", not a stable identifier).
    var novaCADTypeName: String {
        switch self {
        case .line: return "line"
        case .polyline: return "polyline"
        case .spline: return "spline"
        case .ellipse: return "ellipse"
        case .circle: return "circle"
        case .arc: return "arc"
        case .solid: return "solid"
        case .face3d: return "face3d"
        case .hatch: return "hatch"
        case .point: return "point"
        case .text: return "text"
        case .mtext: return "mtext"
        case .attrib: return "attrib"
        case .leader: return "leader"
        case .other: return "other"
        }
    }
}
