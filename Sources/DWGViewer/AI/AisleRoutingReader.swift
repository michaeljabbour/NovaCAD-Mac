import Foundation
import CoreGraphics
import CADCore

// MARK: - AI Assistant: resolving routing endpoints
//
// The read-side helper behind `find_route_endpoints`: turns a name the user
// or assistant gives ("Dock 4", "the blue docks", "Station STN-101") into
// world-space coordinates the routing/apron tools can consume — mirrors
// `DrawingReader`'s own convention of answering strictly from the already-
// expanded, already-world-space render model.
enum AisleRoutingReader {

    /// One resolved endpoint candidate — a single dock door, a named dock
    /// group (multiple doors, pre-reduced to a centroid), or a station/
    /// marketplace INSERT.
    struct EndpointMatch: Codable {
        enum Kind: String, Codable { case dockDoor, dockGroup, insert }
        var kind: Kind
        var label: String
        var x: Double
        var y: Double
        /// For `.insert`, its stable EntityID.raw (so a caller can
        /// cross-reference `get_insert_attributes`). nil for dock matches,
        /// which have no single owning entity (a text label, not a block).
        var entityId: Int32?
        /// Rendered workstation footprint. INSERT reference points are often
        /// arbitrary block datums, so routing can use this physical extent
        /// for the final off-aisle delivery leg instead.
        var minX: Double?
        var minY: Double?
        var maxX: Double?
        var maxY: Double?
        /// For `.dockGroup`, every door number folded into the centroid —
        /// so the assistant can report exactly what it routed from.
        var memberDockNumbers: [Int]?

        init(kind: Kind, label: String, x: Double, y: Double, entityId: Int32?,
             memberDockNumbers: [Int]?, bounds: CGRect? = nil) {
            self.kind = kind; self.label = label; self.x = x; self.y = y
            self.entityId = entityId; self.memberDockNumbers = memberDockNumbers
            minX = bounds.map { Double($0.minX) }; minY = bounds.map { Double($0.minY) }
            maxX = bounds.map { Double($0.maxX) }; maxY = bounds.map { Double($0.maxY) }
        }
    }

    /// Finds every dock door / dock group / station-like INSERT whose name
    /// contains `query` (case-insensitive substring match — "dock 4" matches
    /// "DOCK 4", "stn-101" matches an INSERT block name "STN-101"). Ordered
    /// with exact dock-number matches first (an explicit "Dock 4" should
    /// never be shadowed by an unrelated INSERT that merely mentions "4"),
    /// then dock groups, then INSERTs by name.
    static func findEndpoints(matching query: String, document: DXFDocument, space: SpaceID,
                              visibility: VisibilityState? = nil, store: EntityStore? = nil) -> [EndpointMatch] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var results: [EndpointMatch] = []

        // ---- Dock doors / groups ----
        let allDoors = DockAprons.detectDockDoors(document: document, space: space, visibility: visibility)
        if let dockNumber = DockAprons.parseDockNumber(trimmed) ?? Int(trimmed) {
            let doors = allDoors
            for d in doors where d.number == dockNumber {
                results.append(EndpointMatch(kind: .dockDoor, label: "DOCK \(d.number)",
                                             x: Double(d.position.x), y: Double(d.position.y),
                                             entityId: nil, memberDockNumbers: [d.number]))
            }
        }
        // Named dock group ("blue docks", "brown docks") — matched against
        // every text on model/paper space, since group headers aren't
        // numbered doors themselves (see `DockAprons.parseDockGroupName`).
        let groups = space == .paper ? document.paperGroups : document.modelGroups
        for g in groups {
            let idx = Int(g.layerId)
            if let visibility, visibility.hiddenLayerIds.contains(idx) { continue }
            for t in g.texts {
                guard let groupName = DockAprons.parseDockGroupName(t.text) else { continue }
                guard groupName.localizedCaseInsensitiveContains(trimmed.uppercased())
                        || trimmed.uppercased().contains(groupName) else { continue }
                // Resolve the group to its member doors by proximity to this
                // label — the group header sits among the doors it names.
                 let nearby = allDoors.filter {
                    hypot($0.position.x - t.position.x, $0.position.y - t.position.y) < 3_000
                }
                guard let centroid = AisleNetwork.centroid(of: nearby.map(\.position)) else { continue }
                results.append(EndpointMatch(kind: .dockGroup, label: groupName,
                                             x: Double(centroid.x), y: Double(centroid.y),
                                             entityId: nil,
                                             memberDockNumbers: nearby.map(\.number).sorted()))
            }
        }

        // ---- Station / marketplace INSERTs ----
        let insertRange = space == .paper
            ? document.modelInsertCount..<document.inserts.count
            : 0..<document.modelInsertCount
        let boundsByIndex = DrawingReader.insertContentBoundsByIndex(groups: groups)
        for idx in insertRange {
            let ins = document.inserts[idx]
            if let visibility, visibility.hiddenLayerIds.contains(Int(ins.layerId)) { continue }
            // Match (and report) the per-instance COSMETIC display-name
            // override when one is set (e.g. from a bulk Data Import that
            // relabeled stations to their real names), falling back to the
            // real block name otherwise — same reconciliation
            // `HitTester.properties`/`SearchIndex` use, so "route me to
            // Station STN-101" still resolves after that station's objects
            // were renamed via import, rather than only matching the
            // original, now-superseded block name.
            var label = ins.name
            if let store, ins.entityId >= 0,
               let shown = BlockEditor.displayName(of: EntityID(raw: ins.entityId), in: store) {
                label = shown
            }
            guard label.localizedCaseInsensitiveContains(trimmed)
                    || ins.name.localizedCaseInsensitiveContains(trimmed) else { continue }
            let bounds = boundsByIndex[Int32(idx)]
            let point = bounds.map { CGPoint(x: $0.midX, y: $0.midY) } ?? ins.position
            results.append(EndpointMatch(kind: .insert, label: label,
                                         x: Double(point.x), y: Double(point.y),
                                         entityId: ins.entityId >= 0 ? ins.entityId : nil,
                                         memberDockNumbers: nil, bounds: bounds))
        }

        return results
    }
}
