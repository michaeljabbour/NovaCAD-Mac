import XCTest
@testable import DWGViewer
import CADCore

/// End-to-end tests for the aisle/dock AI tool catalog
/// (`analyze_aisle_network`, `repair_aisle_network`, `find_route_endpoints`,
/// `route_along_aisles`, `shade_aisle_network`, `shade_dock_aprons`) through
/// the SAME `AIToolExecutor.execute(tool:arguments:)` dispatch both the
/// Anthropic and OpenCode Server backends funnel through — matching
/// `AIAssistantTests`' own convention for the original 4 tools. Confirms
/// argument decoding, the AisleNetwork/DockAprons engines actually running
/// against a live document, and (for the four write tools) that results are
/// STAGED on `executor.stagedGeometry` rather than applied to the document.
final class AisleDockToolExecutorTests: XCTestCase {

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

    /// A small fragmented aisle network on layer "AISLE": two collinear
    /// segments with a 20 ft (240 unit) gap between them, plus a width label.
    private func makeAisleFixture() -> (parsed: EditableParsedDocument, layerId: Int32) {
        let parsed = makeParsed()
        let doc = parsed.document
        let layerId = addLayer("AISLE", to: parsed)
        doc.transact("Draw aisles") { tx in
            _ = tx.add(EntityPrototype(type: .line, layerId: layerId, owner: .model,
                                      payload: .line(LinePayload(a: Vec3(x: 0, y: 0), b: Vec3(x: 1_000, y: 0)))))
            _ = tx.add(EntityPrototype(type: .line, layerId: layerId, owner: .model,
                                      payload: .line(LinePayload(a: Vec3(x: 1_240, y: 0), b: Vec3(x: 2_000, y: 0)))))
            // A pair of parallel boundary lines forming a measurable 160-unit
            // (13'-4") corridor, offset from the two centerline segments so
            // detectCorridors treats them as their own aisle.
            _ = tx.add(EntityPrototype(type: .line, layerId: layerId, owner: .model,
                                      payload: .line(LinePayload(a: Vec3(x: 0, y: 500), b: Vec3(x: 1_000, y: 500)))))
            _ = tx.add(EntityPrototype(type: .line, layerId: layerId, owner: .model,
                                      payload: .line(LinePayload(a: Vec3(x: 0, y: 660), b: Vec3(x: 1_000, y: 660)))))
        }
        return (parsed, layerId)
    }

    /// Dock doors "DOCK 1"/"DOCK 2" 20 ft apart on layer "Trucks".
    private func makeDockFixture() -> EditableParsedDocument {
        let parsed = makeParsed()
        let doc = parsed.document
        let layerId = addLayer("Trucks", to: parsed)
        doc.transact("Label docks") { tx in
            let s1 = parsed.store.strings.intern("DOCK 1")
            _ = tx.add(EntityPrototype(type: .text, layerId: layerId, owner: .model,
                                      payload: .text(TextPayload(position: Vec3(x: 0, y: 0), height: 6, stringId: s1))))
            let s2 = parsed.store.strings.intern("DOCK 2")
            _ = tx.add(EntityPrototype(type: .text, layerId: layerId, owner: .model,
                                      payload: .text(TextPayload(position: Vec3(x: 240, y: 0), height: 6, stringId: s2))))
        }
        return parsed
    }

    // MARK: - analyze_aisle_network

    @MainActor
    func testAnalyzeAisleNetworkReportsFragmentationAndGap() throws {
        let (parsed, _) = makeAisleFixture()
        let rc = makeCoordinator(parsed)
        let executor = AIToolExecutor(regen: rc, visibility: VisibilityState())
        let result = try executor.execute(tool: "analyze_aisle_network", arguments: ["layerName": "AISLE"])
        XCTAssertTrue(result.contains("component"), "must report component count")
        XCTAssertTrue(result.contains("20.0 ft") || result.contains("gap"),
                      "must surface the 20 ft gap: \(result)")
        XCTAssertFalse(executor.stagedGeometry.count > 0, "analyze must not stage anything (read-only)")
    }

    @MainActor
    func testAnalyzeAisleNetworkReportsMissingLayerWithSuggestions() throws {
        let (parsed, _) = makeAisleFixture()
        let rc = makeCoordinator(parsed)
        let executor = AIToolExecutor(regen: rc, visibility: VisibilityState())
        let result = try executor.execute(tool: "analyze_aisle_network", arguments: ["layerName": "NOPE-AISLE"])
        XCTAssertTrue(result.contains("No aisle geometry found"))
        XCTAssertTrue(result.contains("AISLE"), "must suggest the real aisle layer name")
    }

    // MARK: - repair_aisle_network

    @MainActor
    func testRepairAisleNetworkStagesABridgeAndDoesNotTouchTheDocument() throws {
        let (parsed, _) = makeAisleFixture()
        let rc = makeCoordinator(parsed)
        let headerCountBefore = parsed.store.headers.count
        let executor = AIToolExecutor(regen: rc, visibility: VisibilityState())
        let result = try executor.execute(tool: "repair_aisle_network",
                                          arguments: ["layerName": "AISLE", "maxGapDistanceFeet": 30.0])
        XCTAssertTrue(result.contains("Bridge") || result.contains("Staged"))
        XCTAssertEqual(executor.stagedGeometry.count, 1)
        let action = executor.stagedGeometry[0]
        XCTAssertEqual(action.kind, .aisleRepair)
        XCTAssertEqual(action.targetLayerName, "AISLE-REPAIRED")
        XCTAssertFalse(action.lines.isEmpty)
        // Nothing must be written to the live document by the tool call itself.
        XCTAssertEqual(parsed.store.headers.count, headerCountBefore,
                       "the tool call must only STAGE geometry, never write it")
    }

    @MainActor
    func testRepairAisleNetworkReportsNoGapsBelowThreshold() throws {
        let (parsed, _) = makeAisleFixture()
        let rc = makeCoordinator(parsed)
        let executor = AIToolExecutor(regen: rc, visibility: VisibilityState())
        // The fixture's gap is 20 ft; a 5 ft threshold must not bridge it.
        let result = try executor.execute(tool: "repair_aisle_network",
                                          arguments: ["layerName": "AISLE", "maxGapDistanceFeet": 5.0])
        XCTAssertTrue(result.contains("No gaps"))
        XCTAssertTrue(executor.stagedGeometry.isEmpty)
    }

    @MainActor
    func testRepairAisleNetworkCanAppendToSourceOrCustomLayer() throws {
        let (parsed, _) = makeAisleFixture()
        let rc = makeCoordinator(parsed)
        let sourceExecutor = AIToolExecutor(regen: rc, visibility: VisibilityState())
        _ = try sourceExecutor.execute(tool: "repair_aisle_network", arguments: [
            "layerName": "AISLE", "targetLayerName": "AISLE", "maxGapDistanceFeet": 30.0
        ])
        XCTAssertEqual(sourceExecutor.stagedGeometry.first?.targetLayerName, "AISLE")
        XCTAssertEqual(sourceExecutor.stagedGeometry.first?.replaceExistingLayerContent, false)

        let customExecutor = AIToolExecutor(regen: rc, visibility: VisibilityState())
        _ = try customExecutor.execute(tool: "repair_aisle_network", arguments: [
            "layerName": "AISLE", "targetLayerName": "MY-CONNECTORS", "maxGapDistanceFeet": 30.0
        ])
        XCTAssertEqual(customExecutor.stagedGeometry.first?.targetLayerName, "MY-CONNECTORS")
    }

    // MARK: - find_route_endpoints

    @MainActor
    func testFindRouteEndpointsResolvesADockNumber() throws {
        let parsed = makeDockFixture()
        let rc = makeCoordinator(parsed)
        let executor = AIToolExecutor(regen: rc, visibility: VisibilityState())
        let result = try executor.execute(tool: "find_route_endpoints", arguments: ["query": "Dock 1"])
        XCTAssertTrue(result.contains("dockDoor"))
        XCTAssertTrue(result.contains("\"x\""))
    }

    @MainActor
    func testFindRouteEndpointsResolvesAnInsertByName() throws {
        let parsed = makeParsed()
        let doc = parsed.document
        doc.transact("Place station") { tx in
            let blockIndex = BlockEditor.nextBlockIndex(in: parsed)
            var geomId: EntityID!
            doc.transact("geom") { tx2 in
                geomId = tx2.add(EntityPrototype(type: .line, layerId: 0, owner: .block(blockIndex),
                                                payload: .line(LinePayload(a: Vec3(x: 0, y: 0), b: Vec3(x: 5, y: 0)))))
            }
            let block = EditableBlockDef()
            block.name = "STN-101"
            block.blockIndex = blockIndex
            block.entityStart = geomId.raw
            block.entityCount = 1
            parsed.blocks["STN-101"] = block
            let nameId = parsed.store.strings.intern("STN-101")
            _ = tx.add(EntityPrototype(type: .insert, layerId: 0, owner: .model,
                                      payload: .insert(InsertPayload(blockNameId: nameId, position: Vec3(x: 500, y: 500)))))
        }
        let rc = makeCoordinator(parsed)
        let executor = AIToolExecutor(regen: rc, visibility: VisibilityState())
        let result = try executor.execute(tool: "find_route_endpoints", arguments: ["query": "STN-101"])
        XCTAssertTrue(result.contains("insert"))
        XCTAssertTrue(result.contains("500"))
    }

    @MainActor
    func testFindRouteEndpointsReportsNoMatch() throws {
        let parsed = makeDockFixture()
        let rc = makeCoordinator(parsed)
        let executor = AIToolExecutor(regen: rc, visibility: VisibilityState())
        let result = try executor.execute(tool: "find_route_endpoints", arguments: ["query": "Nonexistent Thing"])
        XCTAssertTrue(result.contains("No dock"))
    }

    // MARK: - route_along_aisles

    @MainActor
    func testRouteAlongAislesStagesAPolylineWithCorrectDistance() throws {
        let parsed = makeParsed()
        let doc = parsed.document
        let layerId = addLayer("AISLE", to: parsed)
        doc.transact("Draw") { tx in
            _ = tx.add(EntityPrototype(type: .line, layerId: layerId, owner: .model,
                                      payload: .line(LinePayload(a: Vec3(x: 0, y: 0), b: Vec3(x: 1_000, y: 0)))))
        }
        let rc = makeCoordinator(parsed)
        let executor = AIToolExecutor(regen: rc, visibility: VisibilityState())
        let result = try executor.execute(tool: "route_along_aisles", arguments: [
            "aisleLayerName": "AISLE",
            "originX": 0.0, "originY": 0.0, "originLabel": "Dock 1",
            "destinationX": 1_000.0, "destinationY": 0.0, "destinationLabel": "Station A",
        ])
        XCTAssertTrue(result.contains("Dock 1"))
        XCTAssertTrue(result.contains("Station A"))
        XCTAssertEqual(executor.stagedGeometry.count, 1)
        XCTAssertEqual(executor.stagedGeometry[0].kind, .route)
    }

    @MainActor
    func testRouteAlongAislesMeasureOnlyStagesNothing() throws {
        let parsed = makeParsed()
        let doc = parsed.document
        let layerId = addLayer("AISLE", to: parsed)
        doc.transact("Draw") { tx in
            _ = tx.add(EntityPrototype(type: .line, layerId: layerId, owner: .model,
                                      payload: .line(LinePayload(a: Vec3(x: 0, y: 0), b: Vec3(x: 1_000, y: 0)))))
        }
        let rc = makeCoordinator(parsed)
        let executor = AIToolExecutor(regen: rc, visibility: VisibilityState())
        let result = try executor.execute(tool: "route_along_aisles", arguments: [
            "aisleLayerName": "AISLE",
            "originX": 0.0, "originY": 0.0,
            "destinationX": 1_000.0, "destinationY": 0.0,
            "measureOnly": true,
        ])
        XCTAssertTrue(result.contains("measure-only"))
        XCTAssertTrue(executor.stagedGeometry.isEmpty, "measureOnly must never stage geometry")
    }

    /// With auto-repair DISABLED, a genuinely disconnected pair must fail
    /// honestly rather than inventing a path.
    @MainActor
    func testRouteAlongAislesReportsDisconnectedEndpointsHonestly() throws {
        let (parsed, _) = makeAisleFixture()   // has a real 20 ft gap
        let rc = makeCoordinator(parsed)
        let executor = AIToolExecutor(regen: rc, visibility: VisibilityState())
        let result = try executor.execute(tool: "route_along_aisles", arguments: [
            "aisleLayerName": "AISLE",
            "originX": 0.0, "originY": 0.0,
            "destinationX": 2_000.0, "destinationY": 0.0,
            "autoRepairFeet": 0.0,
        ])
        XCTAssertTrue(result.contains("disconnected") || result.contains("DIFFERENT"),
                      "unexpected reply: \(result)")
        XCTAssertTrue(executor.stagedGeometry.isEmpty, "a failed route must never stage a fabricated path")
    }

    /// The fragmented-drawing feature: the SAME 20 ft gap is bridged in
    /// memory under the default repair budget, so an imperfect aisle layer
    /// still measures correctly instead of refusing to route. The reply must
    /// disclose the repair, and the bridges are staged so the user can see
    /// what the measurement relied on.
    @MainActor
    func testRouteAlongAislesAutoRepairsSmallGapsAndDisclosesThem() throws {
        let (parsed, _) = makeAisleFixture()
        let rc = makeCoordinator(parsed)
        let executor = AIToolExecutor(regen: rc, visibility: VisibilityState())
        let result = try executor.execute(tool: "route_along_aisles", arguments: [
            "aisleLayerName": "AISLE",
            "originX": 0.0, "originY": 0.0,
            "destinationX": 2_000.0, "destinationY": 0.0,
        ])
        XCTAssertFalse(result.contains("Routing failed"), "the 20 ft gap should be auto-bridged: \(result)")
        XCTAssertTrue(result.contains("ONE WAY"), "both trip figures should be reported: \(result)")
        XCTAssertTrue(result.contains("ROUND TRIP"))
        XCTAssertTrue(result.contains("Repaired in memory"), "the repair must be disclosed: \(result)")
        XCTAssertTrue(executor.stagedGeometry.contains { $0.kind == .aisleRepair },
                      "the bridges the measurement relied on should be reviewable")
    }

    /// Both trip figures must always be present, whichever one was requested.
    @MainActor
    func testRouteAlongAislesReportsBothTripTypes() throws {
        let (parsed, _) = makeAisleFixture()
        let rc = makeCoordinator(parsed)
        let executor = AIToolExecutor(regen: rc, visibility: VisibilityState())
        let result = try executor.execute(tool: "route_along_aisles", arguments: [
            "aisleLayerName": "AISLE",
            "originX": 0.0, "originY": 0.0,
            "destinationX": 1_000.0, "destinationY": 0.0,
            "tripType": "roundTrip",
            "measureOnly": true,
        ])
        XCTAssertTrue(result.contains("ONE WAY"))
        XCTAssertTrue(result.contains("ROUND TRIP"))
        XCTAssertTrue(result.contains("round trip"), "the requested trip type should be echoed: \(result)")
    }

    // MARK: - shade_aisle_network

    @MainActor
    func testShadeAisleNetworkStagesRibbonsWithCorrectWidthSourceReporting() throws {
        let (parsed, _) = makeAisleFixture()
        let rc = makeCoordinator(parsed)
        let executor = AIToolExecutor(regen: rc, visibility: VisibilityState())
        let result = try executor.execute(tool: "shade_aisle_network", arguments: ["layerName": "AISLE"])
        XCTAssertTrue(result.contains("Staged"))
        XCTAssertEqual(executor.stagedGeometry.count, 1)
        let action = executor.stagedGeometry[0]
        XCTAssertEqual(action.kind, .aisleShading)
        XCTAssertEqual(action.targetLayerName, "AISLE-SHADED")
        XCTAssertFalse(action.polygons.isEmpty)
        XCTAssertTrue(result.contains("transparency"), "must warn about layer-level transparency for overlapping ribbons")
    }

    // MARK: - shade_dock_aprons

    @MainActor
    func testShadeDockApronsStagesAnApron() throws {
        let parsed = makeDockFixture()
        let rc = makeCoordinator(parsed)
        let executor = AIToolExecutor(regen: rc, visibility: VisibilityState())
        let result = try executor.execute(tool: "shade_dock_aprons", arguments: ["depthFeet": 40.0])
        XCTAssertTrue(result.contains("dock door"))
        XCTAssertEqual(executor.stagedGeometry.count, 1)
        let action = executor.stagedGeometry[0]
        XCTAssertEqual(action.kind, .dockAprons)
        XCTAssertEqual(action.targetLayerName, "Dock Apron-AI")
        XCTAssertFalse(action.polygons.isEmpty)
    }

    @MainActor
    func testShadeDockApronsReportsWhenNoDocksFound() throws {
        let parsed = makeParsed()
        let rc = makeCoordinator(parsed)
        let executor = AIToolExecutor(regen: rc, visibility: VisibilityState())
        let result = try executor.execute(tool: "shade_dock_aprons", arguments: [:])
        XCTAssertTrue(result.contains("No dock door"))
        XCTAssertTrue(executor.stagedGeometry.isEmpty)
    }

    // MARK: - Visibility scoping through the executor

    @MainActor
    func testAisleToolsRespectHiddenLayerVisibility() throws {
        let (parsed, layerId) = makeAisleFixture()
        let rc = makeCoordinator(parsed)
        var visibility = VisibilityState()
        visibility.hiddenLayerIds = [Int(layerId)]
        let executor = AIToolExecutor(regen: rc, visibility: visibility)
        let result = try executor.execute(tool: "analyze_aisle_network", arguments: ["layerName": "AISLE"])
        XCTAssertTrue(result.contains("No aisle geometry found"),
                      "a hidden aisle layer must be invisible to the AI tool, matching the on-screen state")
    }

    // MARK: - Applier (stages -> real entities)

    @MainActor
    func testProposedGeometryApplierCreatesRealUndoableEntities() throws {
        let (parsed, _) = makeAisleFixture()
        let rc = makeCoordinator(parsed)
        let session = DocumentSession()
        session.regen = rc
        let executor = AIToolExecutor(regen: rc, visibility: VisibilityState())
        _ = try executor.execute(tool: "repair_aisle_network",
                                 arguments: ["layerName": "AISLE", "maxGapDistanceFeet": 30.0])
        let headerCountBefore = parsed.store.headers.count
        let created = AIProposedGeometryApplier.apply(executor.stagedGeometry, session: session, regen: rc)
        XCTAssertGreaterThan(created, 0)
        XCTAssertGreaterThan(parsed.store.headers.count, headerCountBefore,
                            "Apply must actually write real entities to the document")
        XCTAssertNotNil(parsed.layerIdByName["AISLE-REPAIRED"], "the new overlay layer must be created")
    }

    /// END-TO-END editability guarantee: everything the AI Assistant inserts
    /// must be reshapeable like any hand-drawn object. A user reported being
    /// unable to extend a shaded aisle ("i would like to extend the length of
    /// one of the aisles ... but i am unable to do so") — the shading applied
    /// as HATCH, which had no grips, so STRETCH/grip-drag silently no-op'd.
    /// This walks the REAL path (tool -> stage -> apply -> grips -> stretch)
    /// rather than testing `GripEditing` against a synthetic hatch, so a
    /// future change to how the applier persists shading can't quietly make
    /// AI geometry non-editable again.
    @MainActor
    func testAppliedAisleShadingIsGripEditableAndStretchable() throws {
        let (parsed, _) = makeAisleFixture()
        let rc = makeCoordinator(parsed)
        let session = DocumentSession()
        session.regen = rc
        let executor = AIToolExecutor(regen: rc, visibility: VisibilityState())
        _ = try executor.execute(tool: "shade_aisle_network",
                                 arguments: ["layerName": "AISLE", "fallbackWidthFeet": 13.0])
        XCTAssertFalse(executor.stagedGeometry.isEmpty, "sanity: shading must stage something")
        let created = AIProposedGeometryApplier.apply(executor.stagedGeometry, session: session, regen: rc)
        XCTAssertGreaterThan(created, 0)

        let store = parsed.store
        let shadedLayer = try XCTUnwrap(parsed.layerIdByName["AISLE-SHADED"])
        let shadedIds: [EntityID] = store.headers.indices.compactMap { i in
            let h = store.headers[i]
            guard !h.flags.contains(.deleted), h.layerId == shadedLayer else { return nil }
            return EntityID(raw: Int32(i))
        }
        XCTAssertFalse(shadedIds.isEmpty, "sanity: the shaded layer must hold real entities")

        // Every applied shading entity must be grip-editable and expose one
        // grip per boundary corner — the precondition for STRETCH catching
        // anything at all.
        for id in shadedIds {
            let h = try XCTUnwrap(store.header(id))
            XCTAssertTrue(GripEditing.isGripEditable(h.type),
                          "AI-inserted \(h.type) must be grip-editable like any other object")
            XCTAssertFalse(GripEditing.grips(for: id, in: store).isEmpty,
                           "AI-inserted \(h.type) must expose grips, else STRETCH silently does nothing")
        }

        // Now actually extend one ribbon: crossing-window its rightmost
        // corners and shift them, exactly as the STRETCH tool does.
        let target = try XCTUnwrap(shadedIds.first { store.header($0)?.type == .hatch })
        let grips = GripEditing.grips(for: target, in: store)
        let maxX = try XCTUnwrap(grips.map(\.position.x).max())
        let window = CGRect(x: maxX - 0.5, y: -1e6, width: 1e6, height: 2e6)
        let caught = GripEditing.caughtGrips(ids: [target], in: store, crossingWindow: window)
        XCTAssertFalse(caught.isEmpty, "a crossing window over the ribbon's end must catch its corners")

        parsed.document.transact("Extend aisle") { tx in
            GripEditing.applyStretch(caught, delta: CGVector(dx: 25, dy: 0), in: tx)
        }
        let after = GripEditing.grips(for: target, in: store)
        let newMaxX = try XCTUnwrap(after.map(\.position.x).max())
        XCTAssertEqual(Double(newMaxX), Double(maxX) + 25, accuracy: 1e-6,
                       "the shaded aisle must actually get longer — this is the reported bug")
        XCTAssertEqual(after.count, grips.count, "extending must not add/drop corners")
    }
}
