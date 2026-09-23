import Foundation
import CoreGraphics
import CADCore

/// Executes the AI Assistant's tool calls against the live document. Mirrors
/// the earlier internal project's tool-executor shape (one method per tool,
/// each returning a plain model-friendly string) but scoped to NovaCAD's own
/// drawing-interaction tool catalog (`AIToolSchema.tools`).
///
/// Read tools (`readDrawing`/`insertAttributes`/`findInsertAtPoint`) answer
/// directly from `RegenCoordinator`'s live render model — no state changes.
/// `proposeAttributeEdits` is the sole "this changes something" tool, and per
/// this feature's product decision it does NOT touch the document at all: it
/// validates the requested edits against the live store (so the panel can
/// show real "old → new" values) and returns them as a staged
/// `AIProposedEdit` plan for the panel UI to display — actually applying the
/// plan happens only via `AIProposedEditApplier.apply`, triggered by the
/// user's own "Apply" button press, never by the tool call itself.
@MainActor
final class AIToolExecutor {
    /// The live document this executor reads.
    ///
    /// Deliberately WEAK, not `unowned`. The OpenCode tool bridge is an actor
    /// that outlives any single turn and dispatches into this executor from a
    /// background queue via `MainActor.run`; if the user closed the document
    /// (or the tab reloaded, replacing the `RegenCoordinator`) while a bridge
    /// request was in flight, an `unowned` read is an immediate hard crash.
    /// `weak` turns that same race into a clean "the drawing this request
    /// referred to is no longer open" tool error, which the agent can report
    /// instead of taking the app down with it — one of the reported
    /// occasional crashes.
    private weak var regenRef: RegenCoordinator?
    private let visibility: VisibilityState

    /// Reads the user's CURRENT canvas selection at the moment a tool runs.
    /// A closure (rather than a captured snapshot) because this executor is
    /// reused across an entire agentic turn — see `AISelectionReader`'s own
    /// doc comment for why a snapshot would silently go stale.
    private let selectionProvider: (() -> Set<EntityID>)?
    private let spaceProvider: (() -> SpaceID)?
    private var inspectedSheet: (id: UInt64, revision: UInt64, document: DXFDocument)?

    /// Throwing accessor used by every tool body, so a released document
    /// surfaces as a normal tool error rather than a crash.
    /// Resolves the live document, or throws if it has been closed.
    private func liveRegen() throws -> RegenCoordinator {
        guard let regenRef else { throw AIToolError.documentUnavailable }
        return regenRef
    }
    /// Every `propose_attribute_edits` call this conversation turn makes is
    /// accumulated here so the panel can show the FULL plan once the
    /// assistant finishes, even if it called the tool more than once (e.g.
    /// once per workstation it found).
    private(set) var stagedEdits: [AIProposedEdit] = []
    /// Same accumulation, for the aisle/dock geometry-creation tools
    /// (`repair_aisle_network`/`route_along_aisles`/`shade_aisle_network`/
    /// `shade_dock_aprons`) — see `AIProposedGeometry`'s own doc comment.
    private(set) var stagedGeometry: [AIProposedGeometry] = []

    init(regen: RegenCoordinator, visibility: VisibilityState,
         selectionProvider: (() -> Set<EntityID>)? = nil,
         spaceProvider: (() -> SpaceID)? = nil) {
        self.regenRef = regen
        self.visibility = visibility
        self.selectionProvider = selectionProvider
        self.spaceProvider = spaceProvider
    }

    /// Clears both staged lists — called once their contents have been
    /// drained into `AIAssistantSession`'s own published state (see
    /// `agenticToolExecutor`'s doc comment there for why this executor
    /// instance persists ACROSS turns for the OpenCode Server backend, and
    /// therefore needs an explicit reset rather than just going out of
    /// scope like the per-turn executor the Anthropic tool loop uses).
    func clearStaged() {
        stagedEdits.removeAll()
        stagedGeometry.removeAll()
    }

    /// Dispatches one Anthropic tool call by name to the matching method,
    /// decoding its JSON arguments. Returns plain text/JSON suitable to feed
    /// straight back as the tool's `tool_result` content, or throws
    /// `AIToolError` for a malformed/unknown call (the caller's tool loop
    /// converts that into an error `tool_result` and continues, matching
    /// the LLM client's own resilience).
    func execute(tool name: String, arguments: [String: Any]) throws -> String {
        try AIContextBudget.checkedToolResult(dispatch(tool: name, arguments: arguments))
    }

    private func requestedSpace(_ arguments: [String: Any]) throws -> SpaceID {
        switch (arguments["space"] as? String)?.lowercased() {
        case "paper": return .paper
        case "model": return .model
        case nil, "active": return spaceProvider?() ?? .model
        default: throw AIToolError.invalidArgument("space must be model, paper, or active")
        }
    }

    private func dispatch(tool name: String, arguments: [String: Any]) throws -> String {
        switch name {
        case "read_drawing":
            let space = try requestedSpace(arguments)
            return try readDrawing(space: space)
        case "list_inserts_on_layer":
            guard let layerName = arguments["layerName"] as? String else {
                throw AIToolError.missingArgument("layerName")
            }
            let space = try requestedSpace(arguments)
            return try listInserts(onLayer: layerName, space: space,
                offset: max(0, intArgument(arguments["offset"]) ?? 0),
                limit: max(1, min(intArgument(arguments["limit"]) ?? 30, 100)))
        case "export_csv":
            guard let dataset = arguments["datasetJSON"] as? String else {
                throw AIToolError.missingArgument("datasetJSON")
            }
            return try exportCSV(datasetJSON: dataset, filename: arguments["filename"] as? String)
        case "get_insert_attributes":
            guard let raw = intArgument(arguments["insertEntityId"]) else {
                throw AIToolError.missingArgument("insertEntityId")
            }
            return try insertAttributes(entityId: Int32(raw))
        case "find_insert_at_point":
            guard let x = doubleArgument(arguments["x"]), let y = doubleArgument(arguments["y"]) else {
                throw AIToolError.missingArgument("x/y")
            }
            let space = try requestedSpace(arguments)
            return try findInsertAtPoint(CGPoint(x: x, y: y), space: space)
        case "propose_attribute_edits":
            guard let rawEdits = arguments["edits"] as? [String] else {
                throw AIToolError.missingArgument("edits")
            }
            return try proposeAttributeEdits(rawEdits)

        case "bulk_set_attribute_on_layer":
            guard let layerName = arguments["layerName"] as? String else {
                throw AIToolError.missingArgument("layerName")
            }
            guard let tag = arguments["attributeTag"] as? String else {
                throw AIToolError.missingArgument("attributeTag")
            }
            guard let value = arguments["value"] as? String else {
                throw AIToolError.missingArgument("value")
            }
            let space = try requestedSpace(arguments)
            return try bulkSetAttributeOnLayer(layerName: layerName, space: space, tag: tag, value: value)

        // ---- Aisle network / dock apron tool catalog ----
        case "analyze_aisle_network":
            guard let layerName = arguments["layerName"] as? String else {
                throw AIToolError.missingArgument("layerName")
            }
            let space = try requestedSpace(arguments)
            return try analyzeAisleNetwork(layerName: layerName, space: space)

        case "repair_aisle_network":
            guard let layerName = arguments["layerName"] as? String else {
                throw AIToolError.missingArgument("layerName")
            }
            let space = try requestedSpace(arguments)
            let threshold = doubleArgument(arguments["maxGapDistanceFeet"]) ?? 10
            let targetLayer = arguments["targetLayerName"] as? String
            return try repairAisleNetwork(layerName: layerName, targetLayerName: targetLayer,
                                      space: space, maxGapDistanceFeet: threshold)

        case "find_route_endpoints":
            guard let query = arguments["query"] as? String else {
                throw AIToolError.missingArgument("query")
            }
            let space = try requestedSpace(arguments)
            return try findRouteEndpoints(query: query, space: space)

        case "route_along_aisles":
            guard let layerName = arguments["aisleLayerName"] as? String else {
                throw AIToolError.missingArgument("aisleLayerName")
            }
            let space = try requestedSpace(arguments)
            let mode = Self.centerlineMode(arguments["centerlineMode"])
            let repairFeet = doubleArgument(arguments["autoRepairFeet"]) ?? TravelNetwork.defaultAutoRepairFeet
            let anchor = TravelNetwork.Anchor.parse(arguments["anchor"] as? String) ?? .nearestEdge
            let trip = TravelNetwork.TripType.parse(arguments["tripType"] as? String) ?? .oneWay

            // The origin may be coordinates, the live selection, or a name —
            // resolved against the prepared network so an area object anchors
            // at the point nearest the aisles.
            let prepared = try travelNetwork(
                layers: [layerName, (arguments["connectorLayerName"] as? String) ?? ""].filter { !$0.isEmpty },
                space: space, mode: mode, autoRepairFeet: repairFeet)
            let useSelection = (arguments["useSelectionAsOrigin"] as? Bool) ?? false
            let origin = try resolveOrigin(
                useSelection: useSelection,
                originQuery: arguments["originLabel"] as? String,
                originX: doubleArgument(arguments["originX"]),
                originY: doubleArgument(arguments["originY"]),
                anchor: anchor, space: space, network: prepared.segments)

            guard let destX = doubleArgument(arguments["destinationX"]),
                  let destY = doubleArgument(arguments["destinationY"]) else {
                throw AIToolError.missingArgument("destinationX/destinationY")
            }
            let destLabel = (arguments["destinationLabel"] as? String) ?? "destination"
            return try routeAlongAisles(aisleLayerName: layerName,
                                        connectorLayerName: arguments["connectorLayerName"] as? String,
                                        space: space,
                                        origin: origin.point, originLabel: origin.label,
                                        destination: CGPoint(x: destX, y: destY), destinationLabel: destLabel,
                                        tripType: trip, mode: mode, autoRepairFeet: repairFeet,
                                        measureOnly: (arguments["measureOnly"] as? Bool) ?? false,
                                        routeLayerName: arguments["routeLayerName"] as? String)

        case "export_travel_distances", "export_workstation_travel_distances":
            // The old name stays routable so an in-flight conversation (or a
            // model that learned the previous catalog) keeps working.
            guard let destinationLayer = (arguments["destinationLayerName"] as? String)
                    ?? (arguments["stationLayerName"] as? String) else {
                throw AIToolError.missingArgument("destinationLayerName")
            }
            guard let aisleLayer = arguments["aisleLayerName"] as? String else {
                throw AIToolError.missingArgument("aisleLayerName")
            }
            let space = try requestedSpace(arguments)
            return try exportTravelDistances(
                destinationLayerName: destinationLayer, aisleLayerName: aisleLayer,
                connectorLayerName: arguments["connectorLayerName"] as? String,
                space: space,
                useSelection: (arguments["useSelectionAsOrigin"] as? Bool) ?? false,
                originQuery: arguments["originQuery"] as? String,
                originX: doubleArgument(arguments["originX"]),
                originY: doubleArgument(arguments["originY"]),
                tripType: TravelNetwork.TripType.parse(arguments["tripType"] as? String) ?? .oneWay,
                mode: Self.centerlineMode(arguments["centerlineMode"]),
                autoRepairFeet: doubleArgument(arguments["autoRepairFeet"]) ?? TravelNetwork.defaultAutoRepairFeet,
                anchor: TravelNetwork.Anchor.parse(arguments["anchor"] as? String) ?? .nearestEdge,
                drawPaths: (arguments["drawPaths"] as? Bool) ?? false,
                routeLayerName: arguments["routeLayerName"] as? String,
                filename: arguments["filename"] as? String)

        case "get_selected_objects":
            let space = try requestedSpace(arguments)
            return try selectedObjects(space: space)

        case "draw_polylines":
            guard let pathsJSON = arguments["pathsJSON"] as? String else {
                throw AIToolError.missingArgument("pathsJSON")
            }
            let space = try requestedSpace(arguments)
            let aci = Int16(intArgument(arguments["colorIndex"]) ?? 256)
            return try drawPolylines(pathsJSON: pathsJSON,
                                     layerName: arguments["layerName"] as? String,
                                     space: space,
                                     replaceExisting: (arguments["replaceExistingLayerContent"] as? Bool) ?? false,
                                     closed: (arguments["closed"] as? Bool) ?? false,
                                     aci: aci)

        case "query_entities":
            let space = try requestedSpace(arguments)
            var types: [String]?
            if let list = arguments["types"] as? [String] { types = list }
            else if let single = arguments["types"] as? String {
                types = single.split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespaces)
                }.filter { !$0.isEmpty }
            }
            let limit = max(1, min(intArgument(arguments["limit"]) ?? 30, 100))
            return try queryEntities(types: types,
                                     sheetName: arguments["sheetName"] as? String,
                                     layerContains: arguments["layerContains"] as? String,
                                     nameContains: arguments["nameContains"] as? String,
                                     textContains: arguments["textContains"] as? String,
                                     space: space,
                                     offset: max(0, intArgument(arguments["offset"]) ?? 0),
                                     limit: limit,
                                     countOnly: (arguments["countOnly"] as? Bool) ?? false)

        case "inspect_xrefs":
            return try inspectXrefs(nameContains: arguments["nameContains"] as? String,
                                    includeLayers: (arguments["includeLayers"] as? Bool) ?? true)


        case "shade_aisle_network":
            guard let layerName = arguments["layerName"] as? String else {
                throw AIToolError.missingArgument("layerName")
            }
            let space = try requestedSpace(arguments)
            let fallbackWidthFeet = doubleArgument(arguments["fallbackWidthFeet"]) ?? 13.34
            return try shadeAisleNetwork(layerName: layerName, space: space, fallbackWidthFeet: fallbackWidthFeet)

        case "shade_dock_aprons":
            let space = try requestedSpace(arguments)
            let depthFeet = doubleArgument(arguments["depthFeet"]) ?? 40
            let endPaddingFeet = doubleArgument(arguments["endPaddingFeet"]) ?? 0
            let aisleLayerName = arguments["depthSuggestionAisleLayerName"] as? String
            return try shadeDockAprons(space: space, depthFeet: depthFeet, endPaddingFeet: endPaddingFeet,
                                   aisleLayerNameForSuggestion: aisleLayerName)

        default:
            throw AIToolError.unknownTool(name)
        }
    }

    // MARK: - Read tools

    /// Current render model contains only the selected paper sheet. Enumerate
    /// other sheets by name; never infer that an empty model means an empty file.
    func workspaceContext() throws -> String {
        let regen = try liveRegen()
        let sheets = regen.navigationPaperLayouts
        let selected = sheets.first { $0.id == regen.parsed.activePaperLayoutID }?.name
        let context: [String: Any] = [
            "activeSpace": (spaceProvider?() ?? .model) == .paper ? "paper" : "model",
            "activeSheet": AIContextBudget.clipped(selected ?? "Unnamed paper space", bytes: 160),
            "coordinateUnits": regen.document.unitsLabel,
            "modelPrimitiveCount": regen.document.modelGroups.reduce(0) { $0 + $1.entityCount },
            "paperSheetCount": sheets.count,
            "paperSheets": sheets.prefix(40).map { AIContextBudget.clipped($0.name, bytes: 96) },
            "sheetListTruncated": sheets.count > 40,
            "measurementNote": "Paper coordinates can be scaled. Confirm drawing scale and endpoints before reporting real-world distances."
        ]
        let data = try JSONSerialization.data(withJSONObject: context, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func readDrawing(space: SpaceID) throws -> String {
        let regen = try liveRegen()
        let groups = space == .paper ? regen.document.paperGroups : regen.document.modelGroups
        let visible = groups.filter { !visibility.hiddenLayerIds.contains($0.layerId) }
        let layerIDs = Set(visible.map(\.layerId)).sorted()
        let layers = layerIDs.prefix(20).map { id -> [String: Any] in
            ["name": AIContextBudget.clipped(regen.document.layers[id].name, bytes: 160),
             "primitiveCount": visible.filter { $0.layerId == id }.reduce(0) { $0 + $1.entityCount }]
        }
        // Searchable labels and inserts are more useful than thousands of line
        // endpoints. Details stay paged through query_entities.
        let sample = try queryEntities(types: nil, sheetName: nil, layerContains: nil,
            nameContains: nil, textContains: nil, space: space, offset: 0, limit: 5, countOnly: false)
        let result: [String: Any] = [
            "workspace": try JSONSerialization.jsonObject(with: Data(workspaceContext().utf8)),
            "space": space == .paper ? "paper" : "model",
            "visiblePrimitiveCount": visible.reduce(0) { $0 + $1.entityCount },
            "layers": layers, "layersTruncated": layerIDs.count > 20,
            "sample": try JSONSerialization.jsonObject(with: Data(sample.utf8)),
            "guidance": "This is an overview, not a complete entity dump. Search room labels with query_entities(textContains:...), or block names/layers. Use sheetName to inspect another paper sheet without moving the canvas."
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self)
    }

    private func listInserts(onLayer layerName: String, space: SpaceID, offset: Int, limit: Int) throws -> String {
        let matches = try inserts(onLayer: layerName, space: space)
        var rows: [InsertRow] = []
        var bytes = 0
        for item in matches.dropFirst(offset).prefix(limit) {
            let ins = item.insert
            let bounds = item.bounds
            let row = InsertRow(entityId: ins.entityId,
                blockName: AIContextBudget.clipped(ins.name, bytes: 256),
                displayName: AIContextBudget.clipped(item.label, bytes: 256),
                referenceX: Double(ins.position.x), referenceY: Double(ins.position.y),
                minX: Double(bounds.minX), minY: Double(bounds.minY),
                maxX: Double(bounds.maxX), maxY: Double(bounds.maxY))
            let size = try JSONEncoder().encode(row).count
            guard bytes + size < 10_000 else { break }
            bytes += size; rows.append(row)
        }
        let next = offset + rows.count
        return Self.jsonString(InsertList(layer: AIContextBudget.clipped(layerName, bytes: 160),
            count: matches.count, offset: offset, returned: rows.count,
            nextOffset: next < matches.count ? next : nil, inserts: rows))
            ?? "{\"error\":\"failed to encode inserts\"}"
    }

    private func exportCSV(datasetJSON: String, filename: String?) throws -> String {
        guard let data = datasetJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let columns = object["columns"] as? [String],
              let rawRows = object["rows"] as? [[Any]] else {
            throw AIDataExport.ExportError.malformedDataset
        }
        let rows = rawRows.map { $0.map { String(describing: $0) } }
        let url = try AIDataExport.writeCSV(columns: columns, rows: rows, filename: filename)
        return "Exported \(rows.count) row(s) to \(url.path)"
    }

    private func insertAttributes(entityId: Int32) throws -> String {
        let regen = try liveRegen()
        let insertId = EntityID(raw: entityId)
        let attrs = BlockEditor.attributes(of: insertId, in: regen.parsed.store)
        guard !attrs.isEmpty else { return "This INSERT has no ATTRIB attributes." }
        let rows = attrs.map { "\($0.tag): \($0.value)" }.joined(separator: "\n")
        return rows
    }

    private func findInsertAtPoint(_ point: CGPoint, space: SpaceID) throws -> String {
        let regen = try liveRegen()
        guard let found = DrawingReader.insertContaining(worldPoint: point, document: regen.document, space: space)
        else { return "No INSERT's bounding box contains that point." }
        return "entityId=\(found.entityId) blockName=\(found.name)"
    }

    // MARK: - Write tool (stages only — never applies)

    private func proposeAttributeEdits(_ rawEdits: [String]) throws -> String {
        let regen = try liveRegen()
        var accepted: [String] = []
        var rejected: [String] = []
        for raw in rawEdits {
            guard let data = raw.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let insertEntityId = intArgument(obj["insertEntityId"]),
                  let tag = obj["attributeTag"] as? String,
                  let newValue = obj["newValue"] as? String
            else {
                rejected.append(raw)
                continue
            }
            let insertId = EntityID(raw: Int32(insertEntityId))
            let currentAttrs = BlockEditor.attributes(of: insertId, in: regen.parsed.store)
            let oldValue = currentAttrs.first { $0.tag == tag }?.value
            let edit = AIProposedEdit(insertEntityId: Int32(insertEntityId), attributeTag: tag,
                                      oldValue: oldValue, newValue: newValue, willCreate: oldValue == nil)
            stagedEdits.append(edit)
            let label = oldValue == nil ? "(new attribute) → \(newValue)" : "\(oldValue!) → \(newValue)"
            accepted.append("\(tag): \(label) [entity \(insertEntityId)]")
        }
        var summary = "Staged \(accepted.count) edit(s) for user review:\n" + accepted.joined(separator: "\n")
        if !rejected.isEmpty {
            summary += "\n\(rejected.count) edit(s) could not be parsed and were skipped."
        }
        return summary
    }

    /// Bulk variant of `propose_attribute_edits`: stages the SAME
    /// `attributeTag` = `value` change across EVERY live INSERT on
    /// `layerName`, rather than requiring the caller to enumerate each entity
    /// id one at a time — the direct answer to "add an attribute called X
    /// with value Y to every object on layer Z" (a single ask that plain
    /// `propose_attribute_edits` could only satisfy via one tool call per
    /// object, and would silently fail for any object that didn't already
    /// carry tag X, since that tool only UPDATES an existing tag).
    ///
    /// Works whether the target INSERTs already carry `attributeTag` or not
    /// — each staged `AIProposedEdit.willCreate` reflects, per-object,
    /// whether applying it will add a brand-new ATTRIB or update an existing
    /// one, and `AIProposedEditApplier.apply` (via
    /// `BlockEditor.setOrCreateAttribute`) honors either case correctly at
    /// Apply time. Still stage-only: nothing is written until the user
    /// presses Apply, same as every other write path in this tool catalog.
    private func bulkSetAttributeOnLayer(layerName: String, space: SpaceID,
                                        tag: String, value: String) throws -> String {
        let regen = try liveRegen()
        let wanted = layerName.lowercased()
        var targets: [Int32] = []   // INSERT entity ids, de-duplicated
        var seen = Set<Int32>()
        // A layer's INSERTs are only reachable through `document.inserts`
        // (RenderGroups carry drawn PRIMITIVES, not the INSERT records
        // themselves) — filtered to top-level model/paper-space INSERTs
        // specifically, matching `propose_attribute_edits`' own scope:
        // attribute changes target real, addressable block references, not a
        // synthesized per-instance id from deep inside a nested xref.
        let insertRange = space == .paper
            ? regen.document.modelInsertCount..<regen.document.inserts.count
            : 0..<regen.document.modelInsertCount
        for idx in insertRange {
            let ins = regen.document.inserts[idx]
            let layerIdx = Int(ins.layerId)
            guard layerIdx >= 0, layerIdx < regen.document.layers.count else { continue }
            if visibility.hiddenLayerIds.contains(layerIdx) { continue }
            let full = regen.document.layers[layerIdx].name.lowercased()
            let bare = full.split(separator: "|").last.map(String.init) ?? full
            guard full == wanted || bare == wanted, ins.entityId >= 0,
                  seen.insert(ins.entityId).inserted else { continue }
            targets.append(ins.entityId)
        }
        guard !targets.isEmpty else {
            return "No block references (INSERTs) found on layer '\(layerName)'."
        }

        var created = 0, updated = 0, unchanged = 0
        for entityId in targets {
            let insertId = EntityID(raw: entityId)
            let currentAttrs = BlockEditor.attributes(of: insertId, in: regen.parsed.store)
            let oldValue = currentAttrs.first { $0.tag == tag }?.value
            if oldValue == value { unchanged += 1; continue }
            stagedEdits.append(AIProposedEdit(insertEntityId: entityId, attributeTag: tag,
                                              oldValue: oldValue, newValue: value,
                                              willCreate: oldValue == nil))
            if oldValue == nil { created += 1 } else { updated += 1 }
        }

        var msg = "Staged \(tag) = \(value) on \(created + updated) object(s) on layer '\(layerName)' for user review "
            + "(\(created) new attribute(s), \(updated) update(s) to an existing value)."
        if unchanged > 0 {
            msg += " \(unchanged) object(s) already had this exact value and were skipped."
        }
        return msg
    }

    // MARK: - Aisle network tools

    /// Feet <-> drawing-unit conversion, since these plant layouts are
    /// authored in inches (confirmed by measurement in `AisleNetwork`'s own
    /// header comment: aisle widths of ~13 ft correspond to ~160 drawing
    /// units) while the AI's arguments/reports use feet, the unit a human
    /// (and the drawing's own `13'-4" AISLE` annotations) actually thinks in.
    private static let inchesPerFoot = 12.0

    private func analyzeAisleNetwork(layerName: String, space: SpaceID) throws -> String {
        let regen = try liveRegen()
        let segs = AisleNetwork.segments(onLayerNamed: layerName, document: regen.document,
                                        space: space, visibility: visibility)
        guard !segs.isEmpty else {
            let candidates = AisleNetwork.candidateAisleLayers(document: regen.document, visibility: visibility)
            var msg = "No aisle geometry found on layer '\(layerName)' (in \(space == .paper ? "paper" : "model") space, honoring current layer visibility)."
            if !candidates.isEmpty {
                msg += " Layers that look like aisle layers: \(candidates.joined(separator: ", "))."
            }
            return msg
        }
        let analysis = AisleNetwork.analyze(segments: segs)
        let (corridors, _) = AisleNetwork.detectCorridors(from: segs)
        let anns = AisleNetwork.widthAnnotations(onLayerNamed: layerName, document: regen.document,
                                                 space: space, visibility: visibility)
        let filled = AisleNetwork.applyWidthAnnotations(anns, to: corridors, maxDistance: 600)
        let widthsFt = filled.compactMap { $0.width }.map { $0 / Self.inchesPerFoot }

        var lines: [String] = []
        lines.append("Aisle network analysis for layer '\(layerName)':")
        lines.append("  \(segs.count) source segments, \(analysis.nodeCount) graph nodes after splitting at intersections")
        lines.append("  \(analysis.components.count) disconnected component(s), largest holds \(String(format: "%.0f", analysis.largestComponentShare * 100))% of total aisle length")
        lines.append("  \(analysis.danglingEndpointCount) dangling endpoint(s)")
        if !widthsFt.isEmpty {
            let sorted = widthsFt.sorted()
            lines.append("  \(corridors.count) aisle corridor(s) detected with widths \(String(format: "%.1f", sorted.first!))-\(String(format: "%.1f", sorted.last!)) ft (median \(String(format: "%.1f", sorted[sorted.count/2])) ft)")
        }
        if analysis.isFullyConnected {
            lines.append("  Network is FULLY CONNECTED — no gaps.")
        } else {
            lines.append("  \(analysis.gaps.count) distinct gap(s) found (sorted by distance):")
            for g in analysis.gaps.prefix(30) {
                let ft = g.distance / Self.inchesPerFoot
                lines.append("    \(String(format: "%.1f", ft)) ft (\(g.kind.rawValue)) between component \(g.fromComponent) and \(g.toComponent) at (\(Int(g.from.x)), \(Int(g.from.y))) -> (\(Int(g.to.x)), \(Int(g.to.y)))")
            }
            if analysis.gaps.count > 30 { lines.append("    ... and \(analysis.gaps.count - 30) more") }
            lines.append("  Call repair_aisle_network with a maxGapDistanceFeet threshold to bridge gaps at or below it (a new '<layerName>-REPAIRED' layer is proposed for review — the original layer is never touched).")
        }
        return lines.joined(separator: "\n")
    }

    private func repairAisleNetwork(layerName: String, targetLayerName requestedTarget: String?,
                                    space: SpaceID, maxGapDistanceFeet: Double) throws -> String {
        let regen = try liveRegen()
        let segs = AisleNetwork.segments(onLayerNamed: layerName, document: regen.document,
                                        space: space, visibility: visibility)
        guard !segs.isEmpty else { return "No aisle geometry found on layer '\(layerName)'." }
        let thresholdUnits = maxGapDistanceFeet * Self.inchesPerFoot
        let result = AisleNetwork.repair(segments: segs, autoBridgeUpTo: thresholdUnits)
        guard !result.applied.isEmpty else {
            if result.before.isFullyConnected {
                return "The aisle network on '\(layerName)' is already fully connected — nothing to repair."
            }
            return "No gaps at or below \(String(format: "%.1f", maxGapDistanceFeet)) ft were found. \(result.deferred.count) larger gap(s) remain — the smallest is \(String(format: "%.1f", (result.deferred.map(\.distance).min() ?? 0) / Self.inchesPerFoot)) ft. Try a larger maxGapDistanceFeet, or review them manually via analyze_aisle_network."
        }
        let trimmedTarget = requestedTarget?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let targetLayer = trimmedTarget.isEmpty ? "\(layerName)-REPAIRED" : trimmedTarget
        let bridgeLines = AisleNetwork.bridgeSegments(for: result.applied)
            .map { AIProposedGeometry.LineSegmentDTO($0.a, $0.b) }
        let summary = "Bridge \(result.applied.count) aisle gap(s) on '\(targetLayer)' (\(result.before.components.count) -> \(result.after.components.count) connected components)"
        let action = AIProposedGeometry(kind: .aisleRepair, summary: summary, targetLayerName: targetLayer,
                                        lines: bridgeLines, space: space,
                                        replaceExistingLayerContent: targetLayer.caseInsensitiveCompare(layerName) == .orderedSame ? false : true)
        stagedGeometry.append(action)

        var msg = "Staged: \(summary).\n"
        for g in result.applied {
            msg += "  bridged \(String(format: "%.1f", g.distance / Self.inchesPerFoot)) ft gap (\(g.kind.rawValue))\n"
        }
        if !result.deferred.isEmpty {
            msg += "\(result.deferred.count) larger gap(s) were NOT bridged (smallest: \(String(format: "%.1f", (result.deferred.map(\.distance).min() ?? 0) / Self.inchesPerFoot)) ft) — these may be genuine physical separations; review with analyze_aisle_network before deciding whether to bridge them too."
        }
        return msg
    }

    private func findRouteEndpoints(query: String, space: SpaceID) throws -> String {
        let regen = try liveRegen()
        let matches = AisleRoutingReader.findEndpoints(matching: query, document: regen.document,
                                                       space: space, visibility: visibility,
                                                       store: regen.parsed.store)
        guard !matches.isEmpty else { return "No dock, dock group, or block matching '\(query)' was found." }
        return Self.jsonString(matches) ?? "{\"error\":\"failed to encode matches\"}"
    }

    // MARK: - Travel distance (centerline-accurate)
    //
    // Every distance tool below routes through `TravelNetwork`, NOT over the
    // raw layer geometry. See that file's header comment for the measured
    // reason: a real aisle layer carries the two parallel BOUNDARY EDGE lines
    // of each aisle alongside (or instead of) its centerline, and routing
    // those edges inflates distance badly — on the reference plant layout,
    // raw-edge routing scored a 14.8x straight-line detour ratio against
    // 2.3x for centerline routing, and could only route half as many trips.
    // That is the "estimates were almost double" defect.

    /// Builds the routable network for a request, honoring the caller's
    /// graph-mode and repair preferences.
    private func travelNetwork(layers: [String], space: SpaceID,
                               mode: TravelNetwork.CenterlineMode,
                               autoRepairFeet: Double) throws -> TravelNetwork.Prepared {
        let regen = try liveRegen()
        return TravelNetwork.prepare(layerNames: layers, document: regen.document,
                                     space: space, visibility: visibility,
                                     mode: mode, autoRepairFeet: autoRepairFeet)
    }

    /// Stages the in-memory repair connectors as reviewable geometry, so the
    /// bridges a measurement relied on can be seen and verified on canvas
    /// rather than being invisible assumptions inside a number.
    private func stageRepairGeometry(_ prepared: TravelNetwork.Prepared,
                                     space: SpaceID, layerName: String) {
        guard !prepared.bridges.isEmpty else { return }
        let target = "AI-AISLE-REPAIRS"
        let totalFt = prepared.bridges.reduce(0.0) { $0 + $1.length } / Self.inchesPerFoot
        stagedGeometry.append(AIProposedGeometry(
            kind: .aisleRepair,
            summary: "Aisle repairs used for measurement: \(prepared.bridges.count) connector(s), "
                + "\(String(format: "%.0f", totalFt)) ft total (\(prepared.componentsBefore) → \(prepared.componentsAfter) components)",
            targetLayerName: target,
            lines: prepared.bridges.map { AIProposedGeometry.LineSegmentDTO($0.a, $0.b) },
            space: space,
            replaceExistingLayerContent: true))
    }

    private func routeAlongAisles(aisleLayerName: String, connectorLayerName: String?, space: SpaceID,
                                  origin: CGPoint, originLabel: String,
                                  destination: CGPoint, destinationLabel: String,
                                  tripType: TravelNetwork.TripType,
                                  mode: TravelNetwork.CenterlineMode,
                                  autoRepairFeet: Double,
                                  measureOnly: Bool,
                                  routeLayerName: String?) throws -> String {
        var layers = [aisleLayerName]
        if let connectorLayerName, !connectorLayerName.isEmpty { layers.append(connectorLayerName) }
        let prepared = try travelNetwork(layers: layers, space: space,
                                         mode: mode, autoRepairFeet: autoRepairFeet)
        guard !prepared.isEmpty else {
            let regen = try liveRegen()
            let candidates = AisleNetwork.candidateAisleLayers(document: regen.document, visibility: visibility)
            var msg = "No aisle geometry found on layer '\(aisleLayerName)'."
            if !candidates.isEmpty { msg += " Layers that look like aisle layers: \(candidates.joined(separator: ", "))." }
            return msg
        }

        switch TravelNetwork.measure(from: origin, to: destination, in: prepared) {
        case .failure(let failure):
            return "Routing failed: \(failure.explanation).\n\n\(prepared.diagnostics)"
        case .success(let trip):
            let direct = TravelNetwork.directFeet(from: origin, to: destination)
            var msg = "Route \(originLabel) → \(destinationLabel)\n"
            msg += "  ONE WAY:    \(String(format: "%.0f", trip.oneWayFeet)) ft\n"
            msg += "  ROUND TRIP: \(String(format: "%.0f", trip.roundTripFeet)) ft\n"
            msg += "  (requested trip type: \(tripType.label) = \(String(format: "%.0f", trip.feet(for: tripType))) ft)\n"
            msg += "  Breakdown (one way): \(String(format: "%.0f", trip.aisleLengthFeet)) ft along aisles"
                + " + \(String(format: "%.0f", trip.originConnectorFeet)) ft leaving the origin"
                + " + \(String(format: "%.0f", trip.destinationConnectorFeet)) ft reaching the destination.\n"
            msg += "  Straight-line distance is \(String(format: "%.0f", direct)) ft"
                + " (detour ratio \(String(format: "%.2f", trip.oneWayFeet / max(direct, 1)))x).\n"
            msg += prepared.diagnostics

            if measureOnly {
                msg += "\n(measure-only — no geometry staged)"
                return msg
            }

            // ONE connected polyline for the whole walked path (not N
            // disjoint LINEs) so the user can grip-drag a waypoint and have
            // the route stay continuous — see `AIProposedGeometry.polylines`.
            let targetLayer = (routeLayerName?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
                $0.isEmpty ? nil : $0
            } ?? Self.defaultRouteLayer
            stagedGeometry.append(AIProposedGeometry(
                kind: .route,
                summary: "Route: \(originLabel) → \(destinationLabel) "
                    + "(\(String(format: "%.0f", trip.oneWayFeet)) ft one way / \(String(format: "%.0f", trip.roundTripFeet)) ft round trip)",
                targetLayerName: targetLayer,
                polylines: [AIProposedGeometry.PolylineDTO(trip.path)],
                space: space,
                replaceExistingLayerContent: false))
            stageRepairGeometry(prepared, space: space, layerName: aisleLayerName)
            msg += "\nStaged as ONE editable polyline on '\(targetLayer)' — drag its vertices or STRETCH it like any other object."
            return msg
        }
    }

    private func shadeAisleNetwork(layerName: String, space: SpaceID, fallbackWidthFeet: Double) throws -> String {
        let regen = try liveRegen()
        let segs = AisleNetwork.segments(onLayerNamed: layerName, document: regen.document,
                                        space: space, visibility: visibility)
        guard !segs.isEmpty else { return "No aisle geometry found on layer '\(layerName)'." }
        let (corridors, unpaired) = AisleNetwork.detectCorridors(from: segs)
        let anns = AisleNetwork.widthAnnotations(onLayerNamed: layerName, document: regen.document,
                                                 space: space, visibility: visibility)
        let filled = AisleNetwork.applyWidthAnnotations(anns, to: corridors, maxDistance: 600)
        // Unpaired centerlines have no measured width at all — treat them as
        // corridors of unknown width so they still get shaded (using the
        // fallback), rather than silently omitted from the shaded network.
        let unpairedCorridors = unpaired.map { AisleNetwork.Corridor(centerline: $0, width: nil) }
        let allCorridors = filled + AisleNetwork.applyWidthAnnotations(anns, to: unpairedCorridors, maxDistance: 600)
        let ribbons = AisleNetwork.ribbons(for: allCorridors, fallbackWidth: fallbackWidthFeet * Self.inchesPerFoot)
        guard !ribbons.isEmpty else { return "No shadable aisle geometry found on layer '\(layerName)'." }

        // Rounding disks at every junction (2+ meeting corridors) close the
        // corner gap a plain rectangle-per-corridor scheme leaves at any
        // bend/T/X — see AisleNetwork's own "Junction rounding" doc comment
        // for why a filled circle (matching a stroke-rendering "round join")
        // rather than a real polygon union.
        let junctions = AisleNetwork.junctions(for: allCorridors, fallbackWidth: fallbackWidthFeet * Self.inchesPerFoot)
        let disks = AisleNetwork.junctionDisks(for: junctions)

        var bySource: [AisleNetwork.Corridor.WidthSource: Int] = [:]
        for r in ribbons { bySource[r.widthSource, default: 0] += 1 }
        let targetLayer = "\(layerName)-SHADED"
        var polygons = ribbons.map { AIProposedGeometry.PolygonDTO($0.points) }
        polygons += disks.compactMap { disk -> AIProposedGeometry.PolygonDTO? in
            let poly = AisleNetwork.polygon(for: disk)
            return poly.isEmpty ? nil : AIProposedGeometry.PolygonDTO(poly)
        }
        let action = AIProposedGeometry(kind: .aisleShading,
                                        summary: "Shade \(ribbons.count) aisle segment(s) + \(disks.count) rounded junction(s) on '\(targetLayer)'",
                                        targetLayerName: targetLayer, polygons: polygons, space: space)
        stagedGeometry.append(action)

        var msg = "Staged: shading for \(ribbons.count) aisle segment(s) plus \(disks.count) rounded junction(s) on new layer '\(targetLayer)'.\n"
        msg += "  width source: \(bySource[.measuredFromBoundaries] ?? 0) measured from boundary pairs, "
            + "\(bySource[.textAnnotation] ?? 0) from text annotations, \(bySource[.assumed] ?? 0) assumed (\(String(format: "%.1f", fallbackWidthFeet)) ft fallback).\n"
        msg += "  Junction disks round every bend/T/X so aisles read as one continuous smooth shape rather than a jagged union of rectangles.\n"
        msg += "  IMPORTANT: shapes overlap by design (ribbons at junctions, and junction disks over ribbon ends). After applying, right-click the '\(targetLayer)' layer in the Layers panel -> Layer Settings… and raise its transparency (try around 40-60%) so overlaps don't compound into dark blotches."
        return msg
    }

    private func shadeDockAprons(space: SpaceID, depthFeet: Double, endPaddingFeet: Double,
                                 aisleLayerNameForSuggestion: String?) throws -> String {
        let regen = try liveRegen()
        let doors = DockAprons.detectDockDoors(document: regen.document, space: space, visibility: visibility)
        guard !doors.isEmpty else { return "No dock door labels (\"DOCK <n>\") found in \(space == .paper ? "paper" : "model") space." }
        let banks = DockAprons.groupIntoBanks(doors)
        let hint = AisleNetwork.centroid(of: doors.map(\.position))

        var suggestionNote = ""
        if let aisleLayerName = aisleLayerNameForSuggestion {
            let aisleSegs = AisleNetwork.segments(onLayerNamed: aisleLayerName, document: regen.document,
                                                  space: space, visibility: visibility)
            if !aisleSegs.isEmpty {
                var withSuggestion = 0
                var suggestions: [String] = []
                for b in banks {
                    guard let d = DockAprons.suggestedDepth(for: b, aisleSegments: aisleSegs) else { continue }
                    withSuggestion += 1
                    let nums = b.numbers
                    suggestions.append("docks \(nums.first ?? 0)-\(nums.last ?? 0): \(String(format: "%.0f", d / Self.inchesPerFoot)) ft to nearest parallel aisle")
                }
                if withSuggestion > 0 {
                    suggestionNote = "\nSuggested depths from nearby parallel aisles (for reference — the depth actually used is the depthFeet argument, \(String(format: "%.0f", depthFeet)) ft):\n  "
                        + suggestions.prefix(10).joined(separator: "\n  ")
                }
            }
        }

        let aprons = DockAprons.aprons(for: banks, depth: depthFeet * Self.inchesPerFoot,
                                       endPadding: endPaddingFeet * Self.inchesPerFoot, interiorHint: hint)
        guard !aprons.isEmpty else {
            return "Found \(doors.count) dock door(s) in \(banks.count) bank(s), but none could be oriented into an apron (each bank needs at least 2 doors to establish a dock-face direction)."
        }
        let targetLayer = "Dock Apron-AI"
        let action = AIProposedGeometry(kind: .dockAprons,
                                        summary: "Shade \(aprons.count) dock apron(s) at \(String(format: "%.0f", depthFeet)) ft depth on '\(targetLayer)'",
                                         targetLayerName: targetLayer,
                                         polygons: aprons.map { AIProposedGeometry.PolygonDTO($0.points) },
                                         space: space)
        stagedGeometry.append(action)

        var msg = "Found \(doors.count) dock door(s) grouped into \(banks.count) bank(s). Staged \(aprons.count) apron(s) at \(String(format: "%.0f", depthFeet)) ft depth on new layer '\(targetLayer)'."
        msg += suggestionNote
        msg += "\nAprons regenerate deterministically — call this tool again after docks move/shift to redraw them on the same layer."
        return msg
    }

    // MARK: - Large drawing data and route export

    private struct LayerInsert {
        var insert: InsertInstance
        var label: String
        var bounds: CGRect
    }

    private struct InsertRow: Encodable {
        var entityId: Int32
        var blockName: String
        var displayName: String
        var referenceX: Double
        var referenceY: Double
        var minX: Double
        var minY: Double
        var maxX: Double
        var maxY: Double
    }

    private struct InsertList: Encodable {
        var layer: String
        var count: Int
        var offset: Int
        var returned: Int
        var nextOffset: Int?
        var inserts: [InsertRow]
    }

    private func inserts(onLayer layerName: String, space: SpaceID) throws -> [LayerInsert] {
        let regen = try liveRegen()
        let document = regen.document
        let groups = space == .paper ? document.paperGroups : document.modelGroups
        let boundsByIndex = DrawingReader.insertContentBoundsByIndex(groups: groups)
        let range = space == .paper
            ? document.modelInsertCount..<document.inserts.count
            : 0..<document.modelInsertCount
        let wanted = layerName.lowercased()
        var result: [LayerInsert] = []
        result.reserveCapacity(range.count)
        for index in range {
            let insert = document.inserts[index]
            let layerIndex = Int(insert.layerId)
            guard layerIndex >= 0, layerIndex < document.layers.count,
                  !visibility.hiddenLayerIds.contains(layerIndex) else { continue }
            let full = document.layers[layerIndex].name.lowercased()
            let bare = full.split(separator: "|").last.map(String.init) ?? full
            guard full == wanted || bare == wanted else { continue }
            let label: String
            if insert.entityId >= 0,
               let display = BlockEditor.displayName(of: EntityID(raw: insert.entityId), in: regen.parsed.store) {
                label = display
            } else {
                label = insert.name
            }
            let bounds = boundsByIndex[Int32(index)] ?? CGRect(origin: insert.position, size: .zero)
            result.append(LayerInsert(insert: insert, label: label, bounds: bounds))
        }
        return result.sorted {
            if $0.label != $1.label { return $0.label.localizedStandardCompare($1.label) == .orderedAscending }
            return $0.insert.entityId < $1.insert.entityId
        }
    }

    /// Resolves the shared origin for a batch travel measurement.
    ///
    /// Three sources, in precedence order — explicit coordinates, the user's
    /// live canvas selection, then a name lookup. Selection is the primary
    /// path for a marketplace: it is a large area object that often has no
    /// single searchable name, and pointing at it is far more direct than
    /// describing it.
    private func resolveOrigin(useSelection: Bool, originQuery: String?,
                               originX: Double?, originY: Double?,
                               anchor: TravelNetwork.Anchor, space: SpaceID,
                               network: [AisleNetwork.Segment]) throws -> (point: CGPoint, label: String) {
        let regen = try liveRegen()

        if let x = originX, let y = originY {
            return (CGPoint(x: x, y: y), originQuery ?? "coordinate origin")
        }

        if useSelection {
            guard let provider = selectionProvider else { throw AIToolError.nothingSelected }
            let selection = provider()
            guard !selection.isEmpty else { throw AIToolError.nothingSelected }
            guard let bounds = AISelectionReader.combinedBounds(for: selection, document: regen.document,
                                                                store: regen.parsed.store, space: space) else {
                throw AIToolError.nothingSelected
            }
            let label = AISelectionReader.label(for: selection, document: regen.document,
                                                store: regen.parsed.store, space: space)
            // A marketplace is a large AREA. Anchoring at the point of its
            // footprint nearest the aisle network models how a forklift
            // actually leaves it; a centroid would add a phantom leg through
            // the building's interior.
            let point = TravelNetwork.anchorPoint(for: bounds, insertionPoint: CGPoint(x: bounds.midX, y: bounds.midY),
                                                  anchor: anchor, network: network)
            return (point, label)
        }

        if let query = originQuery, !query.trimmingCharacters(in: .whitespaces).isEmpty {
            let matches = AisleRoutingReader.findEndpoints(matching: query, document: regen.document,
                                                           space: space, visibility: visibility,
                                                           store: regen.parsed.store)
            guard let match = matches.first else {
                throw AIToolError.invalidArgument("no object matching originQuery '\(query)' was found")
            }
            // Prefer the matched object's real footprint over its reference
            // point, for the same reason as the selection case above.
            if let minX = match.minX, let minY = match.minY, let maxX = match.maxX, let maxY = match.maxY {
                let bounds = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                let point = TravelNetwork.anchorPoint(for: bounds, insertionPoint: CGPoint(x: match.x, y: match.y),
                                                      anchor: anchor, network: network)
                return (point, match.label)
            }
            return (CGPoint(x: match.x, y: match.y), match.label)
        }

        throw AIToolError.missingArgument("useSelection, originQuery, or originX/originY")
    }

    /// Batch travel measurement from ONE origin (a marketplace, dock, or the
    /// current selection) to EVERY destination object on a layer — the
    /// "quantify travel from the marketplace to each point of fit" workflow.
    ///
    /// Writes a CSV carrying BOTH one-way and round-trip distances on every
    /// row, so the same export answers either question without being re-run,
    /// and retains unroutable destinations with a status explaining why
    /// rather than silently dropping them (a dropped row is indistinguishable
    /// from a destination that doesn't exist, which hides real drawing
    /// defects).
    private func exportTravelDistances(
        destinationLayerName: String, aisleLayerName: String, connectorLayerName: String?,
        space: SpaceID, useSelection: Bool, originQuery: String?, originX: Double?, originY: Double?,
        tripType: TravelNetwork.TripType, mode: TravelNetwork.CenterlineMode,
        autoRepairFeet: Double, anchor: TravelNetwork.Anchor,
        drawPaths: Bool, routeLayerName: String?, filename: String?
    ) throws -> String {
        var layers = [aisleLayerName]
        if let connectorLayerName, !connectorLayerName.isEmpty { layers.append(connectorLayerName) }
        let prepared = try travelNetwork(layers: layers, space: space,
                                         mode: mode, autoRepairFeet: autoRepairFeet)
        guard !prepared.isEmpty else {
            return "No aisle geometry was found on '\(aisleLayerName)'. No CSV was created."
        }

        let origin = try resolveOrigin(useSelection: useSelection, originQuery: originQuery,
                                       originX: originX, originY: originY, anchor: anchor,
                                       space: space, network: prepared.segments)

        let destinations = try inserts(onLayer: destinationLayerName, space: space)
        guard !destinations.isEmpty else {
            return "No block references were found on layer '\(destinationLayerName)'. No CSV was created."
        }

        let columns = ["destination", "block_name", "entity_id", "origin",
                       "origin_x", "origin_y", "delivery_x", "delivery_y",
                       "one_way_ft", "round_trip_ft",
                       "on_aisle_ft", "origin_connector_ft", "delivery_connector_ft",
                       "straight_line_ft", "detour_ratio", "status"]
        var rows: [[String]] = []
        rows.reserveCapacity(destinations.count)

        var routePaths: [[CGPoint]] = []
        var succeeded = 0
        var oneWayTotal = 0.0
        var longest: (label: String, feet: Double)?
        var shortest: (label: String, feet: Double)?

        for destination in destinations {
            let delivery = TravelNetwork.anchorPoint(for: destination.bounds,
                                                     insertionPoint: destination.insert.position,
                                                     anchor: anchor, network: prepared.segments)
            let prefix = [destination.label, destination.insert.name, String(destination.insert.entityId),
                          origin.label, number(origin.point.x), number(origin.point.y),
                          number(delivery.x), number(delivery.y)]

            switch TravelNetwork.measure(from: origin.point, to: delivery, in: prepared) {
            case .success(let trip):
                succeeded += 1
                oneWayTotal += trip.oneWayFeet
                let direct = TravelNetwork.directFeet(from: origin.point, to: delivery)
                rows.append(prefix + [
                    String(format: "%.2f", trip.oneWayFeet),
                    String(format: "%.2f", trip.roundTripFeet),
                    String(format: "%.2f", trip.aisleLengthFeet),
                    String(format: "%.2f", trip.originConnectorFeet),
                    String(format: "%.2f", trip.destinationConnectorFeet),
                    String(format: "%.2f", direct),
                    String(format: "%.2f", trip.oneWayFeet / max(direct, 0.001)),
                    "ok"])
                if longest == nil || trip.oneWayFeet > longest!.feet {
                    longest = (destination.label, trip.oneWayFeet)
                }
                if shortest == nil || trip.oneWayFeet < shortest!.feet {
                    shortest = (destination.label, trip.oneWayFeet)
                }
                if drawPaths { routePaths.append(trip.path) }
            case .failure(let failure):
                rows.append(prefix + ["", "", "", "", "", "", "", failure.explanation])
            }
        }

        let url = try AIDataExport.writeCSV(columns: columns, rows: rows,
                                            filename: filename ?? "Travel-Distances")

        if drawPaths, !routePaths.isEmpty {
            let target = (routeLayerName?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
                $0.isEmpty ? nil : $0
            } ?? Self.defaultRouteLayer
            // ALL paths from one batch go on ONE layer as ONE staged action,
            // so the whole set can be toggled/reviewed/deleted together — the
            // explicit requirement for visually verifying a batch of routes.
            stagedGeometry.append(AIProposedGeometry(
                kind: .route,
                summary: "\(routePaths.count) travel path(s) from \(origin.label) to '\(destinationLayerName)'",
                targetLayerName: target,
                polylines: routePaths.map { AIProposedGeometry.PolylineDTO($0) },
                space: space,
                replaceExistingLayerContent: true))
        }
        stageRepairGeometry(prepared, space: space, layerName: aisleLayerName)

        let failed = destinations.count - succeeded
        var msg = "Exported travel distances for \(destinations.count) object(s) on '\(destinationLayerName)' to \(url.path)\n"
        msg += "  Origin: \(origin.label) at (\(number(origin.point.x)), \(number(origin.point.y)))\n"
        msg += "  \(succeeded) routed successfully"
        msg += failed > 0 ? ", \(failed) unroutable (kept in the CSV with a status column explaining why).\n" : ".\n"
        if succeeded > 0 {
            let meanOneWay = oneWayTotal / Double(succeeded)
            msg += "  Mean one-way \(String(format: "%.0f", meanOneWay)) ft"
                + " / round trip \(String(format: "%.0f", meanOneWay * 2)) ft.\n"
            if let s = shortest { msg += "  Closest: \(s.label) at \(String(format: "%.0f", s.feet)) ft one way.\n" }
            if let l = longest { msg += "  Farthest: \(l.label) at \(String(format: "%.0f", l.feet)) ft one way.\n" }
            msg += "  Every row carries BOTH one_way_ft and round_trip_ft"
                + " (the user asked for \(tripType.label); quote that column unless told otherwise).\n"
        }
        msg += prepared.diagnostics
        if drawPaths, !routePaths.isEmpty {
            msg += "\nStaged \(routePaths.count) travel path(s) as editable polylines for visual verification."
        }
        return msg
    }

    // MARK: - Selection

    /// Reports what the user currently has selected on canvas, so the
    /// assistant can act on "use THIS as the origin" without the user having
    /// to name or locate the object any other way.
    private func selectedObjects(space: SpaceID) throws -> String {
        let regen = try liveRegen()
        guard let provider = selectionProvider else {
            return "Selection isn't available in this context."
        }
        let report = AISelectionReader.report(for: provider(), document: regen.document,
                                              store: regen.parsed.store, space: space)
        return Self.jsonString(report) ?? "{\"error\":\"failed to encode selection\"}"
    }

    // MARK: - Drawing travel paths

    /// Default layer for AI-drawn travel paths. One shared layer per batch is
    /// deliberate: it lets the user toggle, recolor, or delete an entire set
    /// of routes at once while verifying them.
    static let defaultRouteLayer = "AI-TRAVEL-PATHS"

    /// Draws explicit polylines from a caller-supplied point list — the
    /// general-purpose "show me this path" primitive, separate from the
    /// routing tools that generate paths themselves.
    private func drawPolylines(pathsJSON: String, layerName: String?, space: SpaceID,
                               replaceExisting: Bool, closed: Bool, aci: Int16) throws -> String {
        guard let data = pathsJSON.data(using: .utf8) else {
            throw AIToolError.invalidArgument("pathsJSON is not valid UTF-8")
        }
        let object = try? JSONSerialization.jsonObject(with: data)

        // Accept either a bare array of paths, or {"paths": [...]}.
        let rawPaths: [Any]
        if let array = object as? [Any] {
            rawPaths = array
        } else if let dict = object as? [String: Any], let array = dict["paths"] as? [Any] {
            rawPaths = array
        } else {
            throw AIToolError.invalidArgument(
                "pathsJSON must be a JSON array of paths, or {\"paths\":[...]}; each path is "
                + "either [[x,y],[x,y],...] or {\"points\":[[x,y],...]}")
        }

        var polylines: [AIProposedGeometry.PolylineDTO] = []
        var polygons: [AIProposedGeometry.PolygonDTO] = []
        var skipped = 0
        for raw in rawPaths {
            let pointList: [Any]
            if let list = raw as? [Any] {
                pointList = list
            } else if let dict = raw as? [String: Any], let list = dict["points"] as? [Any] {
                pointList = list
            } else { skipped += 1; continue }

            var points: [CGPoint] = []
            for entry in pointList {
                if let pair = entry as? [Any], pair.count >= 2,
                   let x = doubleArgument(pair[0]), let y = doubleArgument(pair[1]) {
                    points.append(CGPoint(x: x, y: y))
                } else if let dict = entry as? [String: Any],
                          let x = doubleArgument(dict["x"]), let y = doubleArgument(dict["y"]) {
                    points.append(CGPoint(x: x, y: y))
                }
            }
            guard points.count >= 2 else { skipped += 1; continue }
            if closed && points.count >= 3 {
                polygons.append(AIProposedGeometry.PolygonDTO(points))
            } else {
                polylines.append(AIProposedGeometry.PolylineDTO(points))
            }
        }

        let total = polylines.count + polygons.count
        guard total > 0 else {
            throw AIToolError.invalidArgument("no path with at least 2 valid points was found in pathsJSON")
        }

        let target = (layerName?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
            $0.isEmpty ? nil : $0
        } ?? Self.defaultRouteLayer
        stagedGeometry.append(AIProposedGeometry(
            kind: .route,
            summary: "Draw \(total) path(s) on '\(target)'",
            targetLayerName: target,
            polygons: polygons,
            polylines: polylines,
            space: space,
            aci: aci,
            replaceExistingLayerContent: replaceExisting))

        var msg = "Staged \(total) path(s) on layer '\(target)' for review"
        msg += replaceExisting ? " (existing content on that layer will be replaced)." : " (appended to that layer)."
        if skipped > 0 { msg += " \(skipped) malformed path(s) were skipped." }
        msg += " Once applied these are ordinary editable polylines — drag their vertices, STRETCH, move, recolor, or delete them."
        return msg
    }

    // MARK: - Large-drawing entity query

    /// Filtered, paged entity search for drawings far too large to summarize.
    ///
    /// Counts the whole filtered set but sends only a bounded page, so large
    /// drawings remain searchable without filling the provider context.
    private func queryEntities(types: [String]?, sheetName: String?, layerContains: String?, nameContains: String?,
                               textContains: String?, space: SpaceID,
                               offset: Int, limit: Int, countOnly: Bool) throws -> String {
        let regen = try liveRegen()
        var document = regen.document
        if let sheetName {
            guard space == .paper,
                  let sheet = regen.parsed.paperLayouts.first(where: { $0.name.caseInsensitiveCompare(sheetName) == .orderedSame }) else {
                throw AIToolError.invalidArgument("Use space: paper and an exact sheetName from read_drawing")
            }
            if sheet.id != regen.parsed.activePaperLayoutID {
                if inspectedSheet?.id != sheet.id || inspectedSheet?.revision != regen.revision {
                    inspectedSheet = (sheet.id, regen.revision,
                        Regenerator.build(from: regen.parsed, parseSeconds: 0, paperLayoutID: sheet.id) { _ in })
                }
                document = inspectedSheet!.document
            }
        }
        let store = regen.parsed.store
        let groups = space == .paper ? document.paperGroups : document.modelGroups

        let wantedTypes = Set((types ?? []).map { $0.lowercased() })
        let layerNeedle = layerContains?.lowercased()
        let nameNeedle = nameContains?.lowercased()
        let textNeedle = textContains?.lowercased()
        let wantsInserts = wantedTypes.isEmpty || wantedTypes.contains("insert")
        let wantsText = wantedTypes.isEmpty || !wantedTypes.isDisjoint(with: ["text", "mtext", "attrib"])

        func layerMatches(_ layerId: Int) -> Bool {
            let idx = layerId
            guard idx >= 0, idx < document.layers.count else { return false }
            if visibility.hiddenLayerIds.contains(idx) { return false }
            guard let layerNeedle else { return true }
            let full = document.layers[idx].name.lowercased()
            let bare = full.split(separator: "|").last.map(String.init) ?? full
            return full.contains(layerNeedle) || bare.contains(layerNeedle)
        }
        func layerName(_ layerId: Int) -> String {
            let idx = layerId
            guard idx >= 0, idx < document.layers.count else { return "" }
            return document.layers[idx].name
        }

        struct Row: Encodable {
            var entityId: Int32
            var type: String
            var layer: String
            var name: String?
            var text: String?
            var textTruncated: Bool = false
            var x: Double
            var y: Double
            var minX: Double, minY: Double, maxX: Double, maxY: Double
        }

        var matches: [Row] = []
        var totalMatched = 0
        var rowBytes = 0
        var pageFull = false
        func append(_ row: Row) {
            guard !pageFull else { return }
            let bytes = (try? JSONEncoder().encode(row).count) ?? AIContextBudget.toolBytes
            guard rowBytes + bytes < 10_000 else { pageFull = true; return }
            rowBytes += bytes
            matches.append(row)
        }

        // ---- INSERTs (the common case for stations/marketplaces) ----
        if wantsInserts {
            // Guard the model/paper split explicitly: a desynced document
            // where `modelInsertCount` exceeds `inserts.count` would trap on
            // an invalid Range rather than reporting a problem.
            let insertCount = document.inserts.count
            let modelCount = min(document.modelInsertCount, insertCount)
            let range = space == .paper ? modelCount..<insertCount : 0..<modelCount
            let boundsByIndex = DrawingReader.insertContentBoundsByIndex(groups: groups)
            for index in range {
                let insert = document.inserts[index]
                guard layerMatches(Int(insert.layerId)) else { continue }
                var label = insert.name
                if insert.entityId >= 0,
                   let shown = BlockEditor.displayName(of: EntityID(raw: insert.entityId), in: store) {
                    label = shown
                }
                if let nameNeedle {
                    guard label.lowercased().contains(nameNeedle)
                            || insert.name.lowercased().contains(nameNeedle) else { continue }
                }
                if textNeedle != nil { continue }   // text filters don't apply to INSERTs
                totalMatched += 1
                guard !countOnly, totalMatched > offset, matches.count < limit else { continue }
                let bounds = boundsByIndex[Int32(index)] ?? CGRect(origin: insert.position, size: .zero)
                append(Row(entityId: insert.entityId, type: "insert",
                                   layer: AIContextBudget.clipped(layerName(Int(insert.layerId)), bytes: 160), name: AIContextBudget.clipped(label, bytes: 256), text: nil,
                                   x: Double(insert.position.x), y: Double(insert.position.y),
                                   minX: Double(bounds.minX), minY: Double(bounds.minY),
                                   maxX: Double(bounds.maxX), maxY: Double(bounds.maxY)))
            }
        }

        // ---- TEXT/MTEXT/ATTRIB ----
        if wantsText {
            for group in groups {
                guard layerMatches(group.layerId) else { continue }
                for (index, item) in group.texts.enumerated() {
                    if GroupTombstoneRegistry.tombstones(for: group)?.isDead(.text, Int32(index)) == true { continue }
                    let kind = item.kind == .mtext ? "mtext" : item.kind == .attrib ? "attrib" : "text"
                    guard wantedTypes.isEmpty || wantedTypes.contains(kind) || wantedTypes.contains("text") else { continue }
                    if let textNeedle {
                        guard item.text.lowercased().contains(textNeedle) else { continue }
                    } else if nameNeedle != nil {
                        continue   // name filters target INSERTs
                    }
                    totalMatched += 1
                    guard !countOnly, totalMatched > offset, matches.count < limit else { continue }
                    append(Row(entityId: item.entityId, type: kind,
                                       layer: AIContextBudget.clipped(layerName(group.layerId), bytes: 160), name: nil,
                                       text: AIContextBudget.clipped(item.text, bytes: 768), textTruncated: item.text.utf8.count > 768,
                                       x: Double(item.position.x), y: Double(item.position.y),
                                       minX: Double(item.position.x), minY: Double(item.position.y),
                                       maxX: Double(item.position.x), maxY: Double(item.position.y)))
                }
            }
        }

        struct Result: Encodable {
            var space: String
            var sheetName: String?
            var totalMatched: Int
            var offset: Int
            var returned: Int
            var hasMore: Bool
            var nextOffset: Int?
            var rows: [Row]
        }
        let hasMore = offset + matches.count < totalMatched
        let result = Result(space: space == .paper ? "paper" : "model",
                            sheetName: space == .paper ? (sheetName ?? regen.parsed.paperLayouts.first { $0.id == regen.parsed.activePaperLayoutID }?.name) : nil,
                            totalMatched: totalMatched, offset: offset, returned: matches.count,
                            hasMore: hasMore, nextOffset: hasMore && !countOnly ? offset + matches.count : nil,
                            rows: countOnly ? [] : matches)
        return Self.jsonString(result) ?? "{\"error\":\"failed to encode query result\"}"
    }

    // MARK: - Xrefs

    /// Inventories the drawing's external references and how their content is
    /// addressed, so the assistant can work with xref'd geometry without
    /// loading or enumerating the (typically very large) referenced files.
    ///
    /// The key practical fact this surfaces: NovaCAD has ALREADY resolved and
    /// merged xref content into the live render model at load time, with
    /// layers renamed to `XREFNAME|layer`. So xref geometry needs no special
    /// tool to reach — every existing layer-based tool already sees it,
    /// provided the caller knows the qualified layer name. Reporting the
    /// layer inventory per xref is therefore far more useful than a
    /// file-level dump.
    private func inspectXrefs(nameContains: String?, includeLayers: Bool) throws -> String {
        let regen = try liveRegen()
        let document = regen.document

        struct XrefRow: Encodable {
            var xrefId: Int
            var name: String
            var sourceDrawing: String?
            var layerPrefix: String
            var layerCount: Int
            var layers: [String]?
            var entityCount: Int
        }

        let needle = nameContains?.lowercased()
        var entityCountByXref: [Int: Int] = [:]
        for group in document.modelGroups + document.paperGroups {
            guard group.xrefId >= 0 else { continue }
            entityCountByXref[Int(group.xrefId), default: 0] += group.entityCount
        }

        var rows: [XrefRow] = []
        for xref in document.xrefs {
            if let needle, !xref.blockName.lowercased().contains(needle) { continue }
            let owned = document.layers.filter { xref.owns(layerNamed: $0.name) }.map(\.name)
            rows.append(XrefRow(xrefId: xref.id, name: xref.blockName,
                                sourceDrawing: xref.sourceDrawingName,
                                layerPrefix: xref.layerPrefix,
                                layerCount: owned.count,
                                layers: includeLayers ? Array(owned.prefix(400)) : nil,
                                entityCount: entityCountByXref[xref.id] ?? 0))
        }

        struct Report: Encodable {
            var xrefCount: Int
            var rows: [XrefRow]
            var guidance: String
        }
        let report = Report(
            xrefCount: rows.count,
            rows: rows,
            guidance: rows.isEmpty
                ? "This drawing has no external references; all geometry is native."
                : "Xref content is ALREADY merged into the live drawing — you do NOT need to open the "
                    + "referenced files. Its layers appear as '<XREFNAME>|<layer>'. Every layer-based tool "
                    + "(list_inserts_on_layer, query_entities, analyze_aisle_network, route_along_aisles, "
                    + "export_travel_distances) accepts EITHER the fully qualified name or the bare layer "
                    + "name after the '|', so aisles or stations living inside an xref are routed and "
                    + "measured exactly like native geometry.")
        return Self.jsonString(report) ?? "{\"error\":\"failed to encode xref report\"}"
    }

    private func feet(_ drawingUnits: Double) -> String { String(format: "%.2f", drawingUnits / Self.inchesPerFoot) }
    private func number(_ value: CGFloat) -> String { String(format: "%.3f", Double(value)) }

    // MARK: - Argument coercion helpers
    //
    // Anthropic's tool_use `input` is decoded through `AnthropicJSONValue`
    // (see `AIClient.swift`) into plain `Any` — numbers can surface as
    // `Double` even for a schema-declared "integer," so these helpers accept
    // either.

    /// Parses the routing graph mode, defaulting to `.auto`.
    ///
    /// `.auto` is the right default because it is correct for BOTH shapes a
    /// real aisle layer takes: a layer of boundary edge pairs collapses to
    /// centerlines, while a layer that is already clean centerlines finds no
    /// pairs and falls through unchanged (see `TravelNetwork.prepare`).
    private static func centerlineMode(_ value: Any?) -> TravelNetwork.CenterlineMode {
        guard let raw = (value as? String)?.lowercased() else { return .auto }
        let key = raw.filter { $0.isLetter }
        if key.contains("raw") || key.contains("verbatim") { return .raw }
        if key.contains("only") || key == "centerlines" { return .centerlinesOnly }
        return .auto
    }

    private func intArgument(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let d = value as? Double { return Int(d) }
        if let s = value as? String { return Int(s) }
        return nil
    }

    private func doubleArgument(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        if let s = value as? String { return Double(s) }
        return nil
    }

    private static func jsonString<T: Encodable>(_ value: T) -> String? {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

enum AIToolError: LocalizedError {
    case unknownTool(String)
    case missingArgument(String)
    case invalidArgument(String)
    /// The drawing this executor was bound to has been closed (or the tab
    /// reloaded) since the tool call was dispatched. Reported as a normal
    /// tool failure rather than crashing on a dangling reference — see
    /// `AIToolExecutor.regenRef`'s doc comment.
    case documentUnavailable
    case nothingSelected

    var errorDescription: String? {
        switch self {
        case .unknownTool(let name): return "Unknown tool '\(name)'"
        case .missingArgument(let name): return "Missing required argument '\(name)'"
        case .invalidArgument(let detail): return "Invalid argument: \(detail)"
        case .documentUnavailable:
            return "The drawing is no longer open, so this tool can't read it. Ask the user to reopen the drawing."
        case .nothingSelected:
            return "Nothing is selected in the drawing. Ask the user to select the object(s) on canvas first, then try again."
        }
    }
}
