import Foundation
import CoreGraphics
import CADCore

// MARK: - AI Assistant: reading the user's current selection
//
// Backs the `get_selected_objects` tool and the `useSelection` origin mode on
// the travel-distance tools, so a user can point at something on canvas and
// say "use this as the starting point" instead of hunting for its block name
// or typing coordinates.
//
// ---- Why a provider closure rather than a stored selection set ----
//
// `AIToolExecutor` is built once per turn and then reused by the long-lived
// OpenCode tool bridge across many tool calls within that turn. A selection
// SNAPSHOT captured at construction would go stale the moment the user
// clicked anything, and the assistant would silently measure from the wrong
// object. A closure reads `DocumentSession.selection` at the instant the tool
// runs, which is the only value that is actually correct.
//
// The closure captures the session WEAKLY (see `ContentView`'s wiring): the
// executor already holds `unowned regen`, and adding a second strong edge
// from a long-lived bridge back into per-document state is exactly how a
// closed document gets kept alive — or worse, how a dangling `unowned` access
// crashes. Returning an empty set for a released session degrades to "nothing
// is selected", which every caller already handles.
enum AISelectionReader {

    /// One selected object, described in the terms the routing tools need.
    struct SelectedObject: Codable {
        /// Stable `EntityID.raw` for this session.
        var entityId: Int32
        /// DXF type name ("insert", "lwpolyline", "text", ...).
        var type: String
        var layer: String
        /// Block name for an INSERT; nil otherwise.
        var blockName: String?
        /// Display name override or block name — what the user sees.
        var label: String?
        /// Text content for TEXT/MTEXT/ATTRIB.
        var text: String?
        /// World-space rendered footprint.
        var minX: Double
        var minY: Double
        var maxX: Double
        var maxY: Double
        /// Footprint centre, for convenience.
        var centerX: Double
        var centerY: Double
    }

    /// The full answer returned by `get_selected_objects`.
    struct SelectionReport: Codable {
        var count: Int
        /// Combined bounding box of everything selected.
        var minX: Double?
        var minY: Double?
        var maxX: Double?
        var maxY: Double?
        var centerX: Double?
        var centerY: Double?
        var objects: [SelectedObject]
        /// Set when the selection was too large to enumerate in full.
        var truncated: Bool
        var note: String?
    }

    /// Beyond this many selected objects, individual rows are omitted and only
    /// the aggregate footprint is reported — a rubber-band selection can
    /// easily cover thousands of entities, and flooding the model's context
    /// with them defeats the purpose of the tool (which is almost always
    /// "where is this thing?", not "list every entity").
    static let maxDetailedObjects = 200

    /// Builds a selection report from stable entity ids against the live
    /// render model.
    ///
    /// Bounds come from the RENDER model (via `DrawingReader`'s
    /// insert-content index) rather than `EntityStore.bounds`, because the
    /// latter is own-geometry-only and ignores the owning INSERT's transform
    /// — for a block reference it would report the block-definition extents
    /// at the origin instead of where the object actually sits on the plan.
    static func report(for selection: Set<EntityID>, document: DXFDocument,
                       store: EntityStore, space: SpaceID) -> SelectionReport {
        guard !selection.isEmpty else {
            return SelectionReport(count: 0, minX: nil, minY: nil, maxX: nil, maxY: nil,
                                   centerX: nil, centerY: nil, objects: [], truncated: false,
                                   note: "Nothing is selected in the drawing right now.")
        }

        let groups = space == .paper ? document.paperGroups : document.modelGroups
        let insertBounds = DrawingReader.insertContentBoundsByIndex(groups: groups)

        // Map INSERT entity id -> rendered bounds, so a selected block
        // reference reports its true on-plan footprint.
        var boundsByEntity: [Int32: CGRect] = [:]
        for (index, rect) in insertBounds {
            let i = Int(index)
            guard i >= 0, i < document.inserts.count else { continue }
            let id = document.inserts[i].entityId
            guard id >= 0 else { continue }
            boundsByEntity[id] = boundsByEntity[id].map { $0.union(rect) } ?? rect
        }

        var objects: [SelectedObject] = []
        var combined: CGRect?
        var counted = 0

        for id in selection.sorted(by: { $0.raw < $1.raw }) {
            guard let header = store.header(id), !header.flags.contains(.deleted) else { continue }
            counted += 1

            let rect = boundsByEntity[id.raw] ?? store.bounds(id)
            combined = combined.map { $0.union(rect) } ?? rect

            guard objects.count < maxDetailedObjects else { continue }

            let layerIndex = Int(header.layerId)
            let layerName = (layerIndex >= 0 && layerIndex < document.layers.count)
                ? document.layers[layerIndex].name : ""

            var blockName: String?
            var label: String?
            if header.type == .insert {
                blockName = insertName(of: id, in: store, document: document)
                label = BlockEditor.displayName(of: id, in: store) ?? blockName
            }

            objects.append(SelectedObject(
                entityId: id.raw,
                type: typeName(header.type),
                layer: layerName,
                blockName: blockName,
                label: label,
                text: textContent(of: id, header: header, store: store),
                minX: Double(rect.minX), minY: Double(rect.minY),
                maxX: Double(rect.maxX), maxY: Double(rect.maxY),
                centerX: Double(rect.midX), centerY: Double(rect.midY)))
        }

        let truncated = counted > objects.count
        return SelectionReport(
            count: counted,
            minX: combined.map { Double($0.minX) }, minY: combined.map { Double($0.minY) },
            maxX: combined.map { Double($0.maxX) }, maxY: combined.map { Double($0.maxY) },
            centerX: combined.map { Double($0.midX) }, centerY: combined.map { Double($0.midY) },
            objects: objects,
            truncated: truncated,
            note: truncated
                ? "Only the first \(objects.count) of \(counted) selected objects are listed; the reported bounds cover ALL of them."
                : nil)
    }

    /// Combined footprint of the current selection, or nil when nothing
    /// usable is selected — the shape the routing tools consume when the user
    /// says "use my selection as the origin".
    static func combinedBounds(for selection: Set<EntityID>, document: DXFDocument,
                               store: EntityStore, space: SpaceID) -> CGRect? {
        let r = report(for: selection, document: document, store: store, space: space)
        guard let minX = r.minX, let minY = r.minY, let maxX = r.maxX, let maxY = r.maxY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// A short human label for the selection, used in reports/CSV so a route
    /// row says "Marketplace MP-3" rather than "selection".
    static func label(for selection: Set<EntityID>, document: DXFDocument,
                      store: EntityStore, space: SpaceID) -> String {
        let r = report(for: selection, document: document, store: store, space: space)
        guard r.count > 0 else { return "selection" }
        if r.count == 1, let only = r.objects.first {
            if let label = only.label, !label.isEmpty { return label }
            if let text = only.text, !text.isEmpty { return text }
            return "\(only.type) \(only.entityId)"
        }
        // Several objects: name them by their shared block/layer when they
        // agree, which is the common "I selected the whole marketplace" case.
        let blocks = Set(r.objects.compactMap(\.label).filter { !$0.isEmpty })
        if blocks.count == 1, let name = blocks.first { return "\(name) (\(r.count) objects)" }
        let layers = Set(r.objects.map(\.layer).filter { !$0.isEmpty })
        if layers.count == 1, let layer = layers.first { return "selection on \(layer) (\(r.count) objects)" }
        return "selection (\(r.count) objects)"
    }

    // MARK: - Helpers

    private static func insertName(of id: EntityID, in store: EntityStore,
                                   document: DXFDocument) -> String? {
        for insert in document.inserts where insert.entityId == id.raw {
            return insert.name
        }
        return nil
    }

    private static func textContent(of id: EntityID, header: EntityHeader,
                                    store: EntityStore) -> String? {
        switch store.snapshot(id)?.payloadCopy {
        case .text(let p):
            let value = store.strings.string(for: p.stringId)
            return value.isEmpty ? nil : value
        case .mtext(let p):
            let value = store.strings.string(for: p.stringId)
            return value.isEmpty ? nil : value
        default:
            return nil
        }
    }

    /// Stable, model-friendly type names — deliberately the same spellings
    /// `DrawingReader` reports, so ids and types cross-reference cleanly
    /// between tools.
    private static func typeName(_ type: DXFEntityType) -> String {
        switch type {
        case .line: return "line"
        case .point: return "point"
        case .circle: return "circle"
        case .arc: return "arc"
        case .ellipse: return "ellipse"
        case .lwpolyline, .polyline2d, .polyline3d: return "polyline"
        case .spline: return "spline"
        case .text: return "text"
        case .mtext: return "mtext"
        case .attrib: return "attrib"
        case .attdef: return "attdef"
        case .insert: return "insert"
        case .hatch: return "hatch"
        case .image: return "image"
        case .viewport: return "viewport"
        case .dimension: return "dimension"
        case .solid: return "solid"
        case .face3d: return "face3d"
        default: return "unknown"
        }
    }
}
