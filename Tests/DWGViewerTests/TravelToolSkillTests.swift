import XCTest
@testable import DWGViewer
import CoreGraphics
import CADCore

/// End-to-end tests for the AI skills added for the travel-distance workflow,
/// driven through the SAME `AIToolExecutor.execute(tool:arguments:)` dispatch
/// both backends funnel through:
///
///  - `get_selected_objects` — act on what the user pointed at
///  - `export_travel_distances` — batch marketplace-to-every-destination CSV
///  - `draw_polylines` — visually verifiable paths
///  - `query_entities` — filtered/paged access for huge drawings
///  - `inspect_xrefs` — xref layer discovery
///
/// Also covers the crash-hardening: a released document must surface as a
/// tool error rather than a dangling-reference crash.
final class TravelToolSkillTests: XCTestCase {

    // MARK: - Fixtures

    private func makeParsed() -> EditableParsedDocument {
        let parsed = EditableParsedDocument()
        parsed.layers.append(DXFLayer(id: 0, name: "0"))
        parsed.layerIdByName["0"] = 0
        parsed.linetypes.append(DXFLinetype(name: "CONTINUOUS", dashes: []))
        parsed.linetypeIdByName["CONTINUOUS"] = 0
        return parsed
    }

    private func addLayer(_ name: String, to parsed: EditableParsedDocument) -> Int32 {
        let id = Int32(parsed.layers.count)
        parsed.layers.append(DXFLayer(id: Int(id), name: name))
        parsed.layerIdByName[name] = id
        return id
    }

    private func makeCoordinator(_ parsed: EditableParsedDocument) -> RegenCoordinator {
        let doc = Regenerator.build(from: parsed, parseSeconds: 0) { _ in }
        return RegenCoordinator(parsed: parsed, document: doc)
    }

    /// A straight 200 ft aisle along y = 0, plus three station blocks set
    /// back from it, plus a marketplace block at the west end. Distances are
    /// in inches (2,400 units = 200 ft).
    private func makeTravelFixture()
        -> (parsed: EditableParsedDocument, stationIds: [EntityID], marketplaceId: EntityID) {
        let parsed = makeParsed()
        let doc = parsed.document
        let aisleLayer = addLayer("AISLE", to: parsed)
        let stationLayer = addLayer("station blocks", to: parsed)
        let marketLayer = addLayer("marketplace", to: parsed)

        var stationIds: [EntityID] = []
        var marketplaceId = EntityID(raw: -1)

        // Block definitions with real geometry, so the render model gives
        // each INSERT a genuine footprint (the `nearestEdge` anchor and the
        // off-aisle connector leg both depend on it) — same construction the
        // sibling aisle/dock executor tests use.
        func defineBlock(named name: String, halfWidth: Double) {
            let blockIndex = BlockEditor.nextBlockIndex(in: parsed)
            var first: EntityID!
            doc.transact("define \(name)") { tx in
                first = tx.add(EntityPrototype(
                    type: .line, layerId: 0, owner: .block(blockIndex),
                    payload: .line(LinePayload(a: Vec3(x: -halfWidth, y: -halfWidth),
                                               b: Vec3(x: halfWidth, y: halfWidth)))))
            }
            let block = EditableBlockDef()
            block.name = name
            block.blockIndex = blockIndex
            block.entityStart = first.raw
            block.entityCount = 1
            parsed.blocks[name] = block
        }
        defineBlock(named: "STATION", halfWidth: 30)
        defineBlock(named: "MARKETPLACE", halfWidth: 60)

        doc.transact("Build travel fixture") { tx in
            // Aisle centerline: 2,400 units = 200 ft along y = 0.
            _ = tx.add(EntityPrototype(type: .line, layerId: aisleLayer, owner: .model,
                                       payload: .line(LinePayload(a: Vec3(x: 0, y: 0), b: Vec3(x: 2_400, y: 0)))))
            let stationNameId = parsed.store.strings.intern("STATION")
            for x in [600.0, 1_200.0, 1_800.0] {
                stationIds.append(tx.add(EntityPrototype(
                    type: .insert, layerId: stationLayer, owner: .model,
                    payload: .insert(InsertPayload(blockNameId: stationNameId,
                                                   position: Vec3(x: x, y: 120))))))
            }
            let marketNameId = parsed.store.strings.intern("MARKETPLACE")
            marketplaceId = tx.add(EntityPrototype(
                type: .insert, layerId: marketLayer, owner: .model,
                payload: .insert(InsertPayload(blockNameId: marketNameId,
                                               position: Vec3(x: 0, y: -120)))))
        }
        return (parsed, stationIds, marketplaceId)
    }

    // MARK: - get_selected_objects

    @MainActor
    func testSelectedObjectsReportsWhatTheUserPickedAt() throws {
        let fixture = makeTravelFixture()
        let rc = makeCoordinator(fixture.parsed)
        let selected: Set<EntityID> = [fixture.marketplaceId]
        let executor = AIToolExecutor(regen: rc, visibility: VisibilityState(),
                                      selectionProvider: { selected })

        let json = try executor.execute(tool: "get_selected_objects", arguments: [:])
        XCTAssertTrue(json.contains("\"count\":1"), "expected one selected object: \(json)")
        XCTAssertTrue(json.contains("centerX"), "the selection's centre must be reported for use as an origin")
    }

    @MainActor
    func testSelectedObjectsReportsEmptySelectionClearly() throws {
        let fixture = makeTravelFixture()
        let rc = makeCoordinator(fixture.parsed)
        let executor = AIToolExecutor(regen: rc, visibility: VisibilityState(),
                                      selectionProvider: { [] })
        let json = try executor.execute(tool: "get_selected_objects", arguments: [:])
        XCTAssertTrue(json.contains("\"count\":0"))
        XCTAssertTrue(json.contains("Nothing is selected"), "the model needs to be told plainly: \(json)")
    }

    /// The selection is read at CALL time, not captured when the executor was
    /// built — otherwise a mid-turn click would silently measure from the
    /// wrong object.
    @MainActor
    func testSelectionIsReadLiveRatherThanSnapshotted() throws {
        let fixture = makeTravelFixture()
        let rc = makeCoordinator(fixture.parsed)
        var current: Set<EntityID> = []
        let executor = AIToolExecutor(regen: rc, visibility: VisibilityState(),
                                      selectionProvider: { current })

        XCTAssertTrue(try executor.execute(tool: "get_selected_objects", arguments: [:])
            .contains("\"count\":0"))
        current = [fixture.marketplaceId]
        XCTAssertTrue(try executor.execute(tool: "get_selected_objects", arguments: [:])
            .contains("\"count\":1"), "the tool must observe the NEW selection")
    }

    // MARK: - export_travel_distances

    @MainActor
    func testExportTravelDistancesWritesBothTripColumns() throws {
        let fixture = makeTravelFixture()
        let rc = makeCoordinator(fixture.parsed)
        let executor = AIToolExecutor(regen: rc, visibility: VisibilityState(),
                                      selectionProvider: { [fixture.marketplaceId] })

        let filename = "UnitTest-Travel-\(UUID().uuidString.prefix(8))"
        let result = try executor.execute(tool: "export_travel_distances", arguments: [
            "destinationLayerName": "station blocks",
            "aisleLayerName": "AISLE",
            "useSelectionAsOrigin": true,
            "tripType": "roundTrip",
            "filename": filename,
        ])

        XCTAssertTrue(result.contains("Exported travel distances"), result)
        XCTAssertTrue(result.contains("3 object(s)"), "all three stations should be enumerated: \(result)")

        let url = AIDataExport.defaultDirectory.appendingPathComponent(filename + ".csv")
        defer { try? FileManager.default.removeItem(at: url) }
        let csv = try String(contentsOf: url, encoding: .utf8)
        let header = csv.components(separatedBy: "\r\n").first ?? ""
        XCTAssertTrue(header.contains("one_way_ft"), "header: \(header)")
        XCTAssertTrue(header.contains("round_trip_ft"),
                      "both trip types must always be present regardless of tripType: \(header)")
        XCTAssertTrue(header.contains("straight_line_ft"))
        XCTAssertTrue(header.contains("detour_ratio"), "a sanity-check column keeps bad numbers visible")
        XCTAssertTrue(header.contains("status"))

        // Round trip must be exactly twice one way on every routed row.
        let rows = csv.components(separatedBy: "\r\n").dropFirst().filter { !$0.isEmpty }
        XCTAssertEqual(rows.count, 3)
        let columns = header.components(separatedBy: ",")
        let oneWayIdx = columns.firstIndex(of: "one_way_ft")!
        let roundIdx = columns.firstIndex(of: "round_trip_ft")!
        for row in rows {
            let fields = row.components(separatedBy: ",")
            guard let oneWay = Double(fields[oneWayIdx]), let round = Double(fields[roundIdx]) else {
                continue   // an unroutable row leaves these blank by design
            }
            XCTAssertEqual(round, oneWay * 2, accuracy: 0.05)
            XCTAssertGreaterThan(oneWay, 0)
        }
    }

    /// Distances must be plausible: the fixture's geometry is known, so a
    /// doubling bug would show up here as a hard number mismatch.
    @MainActor
    func testExportTravelDistancesProducesGeometricallyCorrectDistances() throws {
        let fixture = makeTravelFixture()
        let rc = makeCoordinator(fixture.parsed)
        let executor = AIToolExecutor(regen: rc, visibility: VisibilityState())

        let filename = "UnitTest-Travel-Exact-\(UUID().uuidString.prefix(8))"
        _ = try executor.execute(tool: "export_travel_distances", arguments: [
            "destinationLayerName": "station blocks",
            "aisleLayerName": "AISLE",
            "originX": 0.0, "originY": 0.0,
            "filename": filename,
        ])
        let url = AIDataExport.defaultDirectory.appendingPathComponent(filename + ".csv")
        defer { try? FileManager.default.removeItem(at: url) }
        let csv = try String(contentsOf: url, encoding: .utf8)
        let lines = csv.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        let columns = lines[0].components(separatedBy: ",")
        let oneWayIdx = columns.firstIndex(of: "one_way_ft")!

        // Stations sit at 600/1,200/1,800 units along the aisle (50/100/150
        // ft) and are centred 120 units north of it. The `nearestEdge` anchor
        // measures to the near FACE of each station's footprint, not its
        // centre: the STATION block spans ±30 units, so the off-aisle leg is
        // 120 - 30 = 90 units = 7.5 ft. Totals are therefore 57.5/107.5/157.5
        // ft — the anchor rule is exactly what keeps these from being
        // overstated by the full centre offset.
        let measured = lines.dropFirst().compactMap { line -> Double? in
            Double(line.components(separatedBy: ",")[oneWayIdx])
        }.sorted()
        XCTAssertEqual(measured.count, 3)
        XCTAssertEqual(measured[0], 57.5, accuracy: 3)
        XCTAssertEqual(measured[1], 107.5, accuracy: 3)
        XCTAssertEqual(measured[2], 157.5, accuracy: 3)

        // Each successive station is exactly 50 ft further along the aisle —
        // the strongest available check that on-aisle travel is counted once
        // rather than doubled.
        XCTAssertEqual(measured[1] - measured[0], 50, accuracy: 0.5)
        XCTAssertEqual(measured[2] - measured[1], 50, accuracy: 0.5)
    }

    @MainActor
    func testExportTravelDistancesCanDrawEveryPathOnOneLayer() throws {
        let fixture = makeTravelFixture()
        let rc = makeCoordinator(fixture.parsed)
        let executor = AIToolExecutor(regen: rc, visibility: VisibilityState())

        let filename = "UnitTest-Travel-Paths-\(UUID().uuidString.prefix(8))"
        _ = try executor.execute(tool: "export_travel_distances", arguments: [
            "destinationLayerName": "station blocks",
            "aisleLayerName": "AISLE",
            "originX": 0.0, "originY": 0.0,
            "drawPaths": true,
            "filename": filename,
        ])
        defer {
            try? FileManager.default.removeItem(
                at: AIDataExport.defaultDirectory.appendingPathComponent(filename + ".csv"))
        }

        let routes = executor.stagedGeometry.filter { $0.kind == .route }
        XCTAssertEqual(routes.count, 1, "a batch should stage ONE action holding every path")
        XCTAssertEqual(routes.first?.polylines.count, 3, "one polyline per routed destination")
        XCTAssertEqual(routes.first?.targetLayerName, AIToolExecutor.defaultRouteLayer,
                       "batched paths share one layer so they can be reviewed together")
    }

    @MainActor
    func testExportTravelDistancesFailsClearlyWithNoOrigin() throws {
        let fixture = makeTravelFixture()
        let rc = makeCoordinator(fixture.parsed)
        let executor = AIToolExecutor(regen: rc, visibility: VisibilityState())
        XCTAssertThrowsError(try executor.execute(tool: "export_travel_distances", arguments: [
            "destinationLayerName": "station blocks",
            "aisleLayerName": "AISLE",
        ]), "an export with no resolvable origin must not silently pick one")
    }

    @MainActor
    func testExportTravelDistancesReportsNothingSelectedRatherThanGuessing() throws {
        let fixture = makeTravelFixture()
        let rc = makeCoordinator(fixture.parsed)
        let executor = AIToolExecutor(regen: rc, visibility: VisibilityState(),
                                      selectionProvider: { [] })
        do {
            _ = try executor.execute(tool: "export_travel_distances", arguments: [
                "destinationLayerName": "station blocks",
                "aisleLayerName": "AISLE",
                "useSelectionAsOrigin": true,
            ])
            XCTFail("expected a nothingSelected error")
        } catch let error as AIToolError {
            guard case .nothingSelected = error else { return XCTFail("wrong error: \(error)") }
            XCTAssertTrue((error.errorDescription ?? "").contains("select"),
                          "the message should tell the user what to do")
        }
    }

    /// The legacy tool name must keep working so an in-flight conversation
    /// (or a model that learned the old catalog) doesn't break.
    @MainActor
    func testLegacyExportToolNameStillRoutes() throws {
        let fixture = makeTravelFixture()
        let rc = makeCoordinator(fixture.parsed)
        let executor = AIToolExecutor(regen: rc, visibility: VisibilityState())
        let filename = "UnitTest-Legacy-\(UUID().uuidString.prefix(8))"
        let result = try executor.execute(tool: "export_workstation_travel_distances", arguments: [
            "stationLayerName": "station blocks",
            "aisleLayerName": "AISLE",
            "originX": 0.0, "originY": 0.0,
            "filename": filename,
        ])
        defer {
            try? FileManager.default.removeItem(
                at: AIDataExport.defaultDirectory.appendingPathComponent(filename + ".csv"))
        }
        XCTAssertTrue(result.contains("Exported travel distances"), result)
    }

    // MARK: - draw_polylines

    @MainActor
    func testDrawPolylinesStagesPathsOnOneLayer() throws {
        let fixture = makeTravelFixture()
        let rc = makeCoordinator(fixture.parsed)
        let executor = AIToolExecutor(regen: rc, visibility: VisibilityState())

        let result = try executor.execute(tool: "draw_polylines", arguments: [
            "pathsJSON": "[[[0,0],[100,0],[100,50]],[[0,200],[300,200]]]",
            "layerName": "MY-PATHS",
        ])
        XCTAssertTrue(result.contains("Staged 2 path(s)"), result)
        XCTAssertEqual(executor.stagedGeometry.count, 1, "one staged action per call")
        let action = executor.stagedGeometry[0]
        XCTAssertEqual(action.targetLayerName, "MY-PATHS")
        XCTAssertEqual(action.polylines.count, 2)
        XCTAssertEqual(action.polylines[0].points.count, 3)
    }

    @MainActor
    func testDrawPolylinesAcceptsObjectFormAndPathsWrapper() throws {
        let fixture = makeTravelFixture()
        let rc = makeCoordinator(fixture.parsed)
        let executor = AIToolExecutor(regen: rc, visibility: VisibilityState())
        _ = try executor.execute(tool: "draw_polylines", arguments: [
            "pathsJSON": "{\"paths\":[{\"points\":[{\"x\":0,\"y\":0},{\"x\":10,\"y\":10}]}]}",
        ])
        XCTAssertEqual(executor.stagedGeometry.first?.polylines.count, 1,
                       "the tolerant parser should accept the object form too")
    }

    @MainActor
    func testDrawPolylinesRejectsMalformedInput() throws {
        let fixture = makeTravelFixture()
        let rc = makeCoordinator(fixture.parsed)
        let executor = AIToolExecutor(regen: rc, visibility: VisibilityState())
        XCTAssertThrowsError(try executor.execute(tool: "draw_polylines", arguments: [
            "pathsJSON": "not json at all",
        ]))
        // A single-point "path" cannot be drawn and must be rejected, not
        // silently staged as an empty entity.
        XCTAssertThrowsError(try executor.execute(tool: "draw_polylines", arguments: [
            "pathsJSON": "[[[0,0]]]",
        ]))
    }

    @MainActor
    func testDrawPolylinesClosedProducesFilledShapes() throws {
        let fixture = makeTravelFixture()
        let rc = makeCoordinator(fixture.parsed)
        let executor = AIToolExecutor(regen: rc, visibility: VisibilityState())
        _ = try executor.execute(tool: "draw_polylines", arguments: [
            "pathsJSON": "[[[0,0],[100,0],[100,100]]]",
            "closed": true,
        ])
        XCTAssertEqual(executor.stagedGeometry.first?.polygons.count, 1)
        XCTAssertTrue(executor.stagedGeometry.first?.polylines.isEmpty ?? false)
    }

    // MARK: - query_entities

    @MainActor
    func testQueryEntitiesFiltersByLayerAndPages() throws {
        let fixture = makeTravelFixture()
        let rc = makeCoordinator(fixture.parsed)
        let executor = AIToolExecutor(regen: rc, visibility: VisibilityState())

        let all = try executor.execute(tool: "query_entities", arguments: [
            "types": ["insert"], "layerContains": "station",
        ])
        XCTAssertTrue(all.contains("\"totalMatched\":3"), all)

        // Paging: one row at a time, with a usable nextOffset.
        let firstPage = try executor.execute(tool: "query_entities", arguments: [
            "types": ["insert"], "layerContains": "station", "limit": 1,
        ])
        XCTAssertTrue(firstPage.contains("\"returned\":1"), firstPage)
        XCTAssertTrue(firstPage.contains("\"hasMore\":true"))
        XCTAssertTrue(firstPage.contains("\"nextOffset\":1"))

        let lastPage = try executor.execute(tool: "query_entities", arguments: [
            "types": ["insert"], "layerContains": "station", "offset": 2, "limit": 10,
        ])
        XCTAssertTrue(lastPage.contains("\"hasMore\":false"), lastPage)
    }

    @MainActor
    func testQueryEntitiesCountOnlySkipsRows() throws {
        let fixture = makeTravelFixture()
        let rc = makeCoordinator(fixture.parsed)
        let executor = AIToolExecutor(regen: rc, visibility: VisibilityState())
        let json = try executor.execute(tool: "query_entities", arguments: [
            "types": ["insert"], "countOnly": true,
        ])
        XCTAssertTrue(json.contains("\"rows\":[]"), "countOnly must not stream rows: \(json)")
        XCTAssertTrue(json.contains("\"totalMatched\":4"), "3 stations + 1 marketplace: \(json)")
    }

    @MainActor
    func testQueryEntitiesFiltersByBlockName() throws {
        let fixture = makeTravelFixture()
        let rc = makeCoordinator(fixture.parsed)
        let executor = AIToolExecutor(regen: rc, visibility: VisibilityState())
        let json = try executor.execute(tool: "query_entities", arguments: [
            "types": ["insert"], "nameContains": "marketplace",
        ])
        XCTAssertTrue(json.contains("\"totalMatched\":1"), json)
    }

    @MainActor
    func testQueryEntitiesAcceptsCommaSeparatedTypes() throws {
        let fixture = makeTravelFixture()
        let rc = makeCoordinator(fixture.parsed)
        let executor = AIToolExecutor(regen: rc, visibility: VisibilityState())
        // The OpenCode forwarder passes `types` as a plain string.
        let json = try executor.execute(tool: "query_entities", arguments: [
            "types": "insert", "layerContains": "station",
        ])
        XCTAssertTrue(json.contains("\"totalMatched\":3"), json)
    }

    // MARK: - inspect_xrefs

    @MainActor
    func testInspectXrefsOnNativeDrawingSaysSoPlainly() throws {
        let fixture = makeTravelFixture()
        let rc = makeCoordinator(fixture.parsed)
        let executor = AIToolExecutor(regen: rc, visibility: VisibilityState())
        let json = try executor.execute(tool: "inspect_xrefs", arguments: [:])
        XCTAssertTrue(json.contains("\"xrefCount\":0"), json)
        XCTAssertTrue(json.contains("no external references"),
                      "the model should be told plainly rather than inferring from an empty list")
    }

    // MARK: - Crash hardening

    /// A closed document must produce a tool ERROR, not a crash. The executor
    /// used to hold `unowned let regen`, so a bridge request arriving after
    /// the document closed was an immediate hard trap.
    @MainActor
    func testReleasedDocumentSurfacesAsToolErrorRatherThanCrashing() throws {
        var executor: AIToolExecutor?
        do {
            let fixture = makeTravelFixture()
            let rc = makeCoordinator(fixture.parsed)
            executor = AIToolExecutor(regen: rc, visibility: VisibilityState())
            // `rc` goes out of scope here; the executor holds it weakly.
        }
        guard let executor else { return XCTFail("executor should exist") }
        do {
            _ = try executor.execute(tool: "read_drawing", arguments: [:])
            // If the coordinator happened to stay alive (retained elsewhere),
            // the call legitimately succeeds — the point is that it must not
            // crash either way.
        } catch let error as AIToolError {
            guard case .documentUnavailable = error else {
                return XCTFail("expected documentUnavailable, got \(error)")
            }
            XCTAssertTrue((error.errorDescription ?? "").contains("no longer open"))
        }
    }
}
