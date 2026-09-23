import XCTest
import SwiftUI
import CADCore
@testable import DWGViewer

final class AIGeometryEditingTests: XCTestCase {
    @MainActor private func fixture() -> (DocumentSession, RegenCoordinator, AIToolExecutor, EntityID) {
        let parsed = EditableParsedDocument()
        parsed.layers = [DXFLayer(id: 0, name: "Glass")]
        parsed.layerIdByName = ["Glass": 0]
        let id = parsed.store.append(EntityPrototype(type: .lwpolyline, layerId: 0, aci: 5,
            trueColor: 0x123456, lineweight: 25, ltScale: 2,
            payload: .polyline(PolylinePayload(closed: false),
                vertices: [Vec3(x: 10, y: 0), Vec3(x: 8, y: 6), Vec3(x: 0, y: 10)], bulges: [0, 0, 0])))
        let rc = RegenCoordinator(parsed: parsed, document: Regenerator.build(from: parsed, parseSeconds: 0) { _ in })
        let session = DocumentSession(); session.regen = rc; session.selection = [id]
        let executor = AIToolExecutor(regen: rc, visibility: session.visibility,
            selectionProvider: { [weak session] in session?.selection ?? [] },
            spaceProvider: { [weak session] in session?.space == .paper ? .paper : .model },
            visibilityProvider: { [weak session] in session?.visibility ?? VisibilityState() })
        return (session, rc, executor, id)
    }

    private func replacement(_ raw: Int32) -> String {
        "[{\"entityIds\":[\(raw)],\"replacements\":[{\"type\":\"arc\",\"points\":[[10,0],[8,6],[0,10]]}]}]"
    }

    @MainActor func testInspectStageApplyUndoRedoAndDXFRoundTrip() throws {
        let (session, rc, executor, id) = fixture()
        let inspection = try executor.execute(tool: "inspect_geometry", arguments: [:])
        XCTAssertTrue(inspection.contains("bulges"))
        let revision = rc.parsed.document.revision, count = rc.parsed.store.count
        let reply = try executor.execute(tool: "propose_geometry_edits", arguments: ["editsJSON": replacement(id.raw)])
        XCTAssertTrue(reply.contains("unchanged until"))
        XCTAssertEqual(rc.parsed.document.revision, revision)
        XCTAssertEqual(rc.parsed.store.count, count)
        let plan = try XCTUnwrap(executor.stagedGeometry.first?.editPlan)
        let arc = try XCTUnwrap(plan.edits.first?.replacements.first)
        XCTAssertEqual(try XCTUnwrap(arc.radius), 10, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(arc.center?.first), 0, accuracy: 1e-9)
        XCTAssertEqual(arc.previewPoints.first!.x, 10, accuracy: 1e-9)
        XCTAssertEqual(arc.previewPoints.last!.y, 10, accuracy: 1e-9)
        let rendered = ImageRenderer(content: AIGeometryPreview(plan: plan).frame(width: 260, height: 120))
        let image = try XCTUnwrap(rendered.nsImage, "The real proposal preview must render")
        if let path = ProcessInfo.processInfo.environment["NOVACAD_AI_PREVIEW_SNAPSHOT"],
           let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            try png.write(to: URL(fileURLWithPath: path))
        }
        XCTAssertEqual(try AIProposedGeometryApplier.apply(executor.stagedGeometry, session: session, regen: rc), 1)
        XCTAssertTrue(rc.parsed.store.header(id)!.flags.contains(.deleted))
        let new = try XCTUnwrap(rc.parsed.store.headers.last)
        XCTAssertEqual(new.type, .arc); XCTAssertEqual(new.aci, 5)
        XCTAssertEqual(new.trueColor, 0x123456); XCTAssertEqual(new.lineweight, 25); XCTAssertEqual(new.ltScale, 2)
        XCTAssertEqual(session.editableDocument?.undoStack.count, 1)
        session.undo()
        XCTAssertFalse(rc.parsed.store.header(id)!.flags.contains(.deleted))
        XCTAssertTrue(rc.parsed.store.headers.last!.flags.contains(.deleted))
        session.redo()
        XCTAssertTrue(rc.parsed.store.header(id)!.flags.contains(.deleted))
        XCTAssertFalse(rc.parsed.store.headers.last!.flags.contains(.deleted))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ai-curve-\(UUID()).dxf")
        defer { try? FileManager.default.removeItem(at: url) }
        try DXFStructuralWriter.write(rc.parsed, to: url)
        let loaded = try PackageLoader.loadIntoStore(url: url)
        XCTAssertEqual(loaded.store.headers.filter { $0.type == .arc && !$0.flags.contains(.deleted) }.count, 1)
        XCTAssertEqual(loaded.store.arcs.first!.radius, 10, accuracy: 1e-9)
    }

    @MainActor func testRequiresFreshInspectionAndRejectsStaleOrDifferentDocumentAtomically() throws {
        let (session, rc, executor, id) = fixture()
        XCTAssertThrowsError(try executor.execute(tool: "propose_geometry_edits", arguments: ["editsJSON": replacement(id.raw)]))
        _ = try executor.execute(tool: "inspect_geometry", arguments: [:])
        _ = try executor.execute(tool: "propose_geometry_edits", arguments: ["editsJSON": replacement(id.raw)])
        let (other, otherRC, _, _) = fixture()
        XCTAssertThrowsError(try AIProposedGeometryApplier.apply(executor.stagedGeometry, session: other, regen: otherRC))
        session.performEdit("Move source") { $0.modifyPayload(id) { $0.translate(dx: 2, dy: 0) } }
        let count = rc.parsed.store.count, revision = rc.parsed.document.revision
        let creation = AIProposedGeometry(kind: .route, summary: "Route", targetLayerName: "NEW", lines: [.init(.zero, CGPoint(x: 1, y: 1))])
        XCTAssertThrowsError(try AIProposedGeometryApplier.apply([creation] + executor.stagedGeometry, session: session, regen: rc))
        XCTAssertEqual(rc.parsed.store.count, count); XCTAssertEqual(rc.parsed.document.revision, revision)
        XCTAssertNil(rc.parsed.layerIdByName["NEW"])
        XCTAssertThrowsError(try executor.execute(tool: "propose_geometry_edits", arguments: ["editsJSON": replacement(id.raw)]))
    }

    @MainActor func testLockedHiddenAndDuplicateProposalsCannotApply() throws {
        let (session, rc, executor, id) = fixture()
        _ = try executor.execute(tool: "inspect_geometry", arguments: [:])
        _ = try executor.execute(tool: "propose_geometry_edits", arguments: ["editsJSON": replacement(id.raw)])
        session.visibility.lockedLayerIds = [0]
        XCTAssertThrowsError(try AIProposedGeometryApplier.apply(executor.stagedGeometry, session: session, regen: rc))
        session.visibility.lockedLayerIds = []; session.visibility.hiddenLayerIds = [0]
        XCTAssertThrowsError(try AIProposedGeometryApplier.apply(executor.stagedGeometry, session: session, regen: rc))
        session.visibility.hiddenLayerIds = []
        XCTAssertThrowsError(try AIProposedGeometryApplier.apply(executor.stagedGeometry + executor.stagedGeometry, session: session, regen: rc))
        XCTAssertFalse(rc.parsed.store.header(id)!.flags.contains(.deleted))
    }

    @MainActor func testPaperEditPreservesSheetThroughSaveAndWrongSheetRejects() throws {
        let rc = try RegenCoordinator.loadPackage(url: TestFixtures.url("multiple_layouts.dxf"))
        rc.selectPaperLayout(0x23)
        let session = DocumentSession(); session.regen = rc; session.space = .paper
        let id = try XCTUnwrap(rc.parsed.store.headers.indices.first { i in
            let h = rc.parsed.store.headers[i]
            return h.type == .line && PaperLayoutOwnership(rc.parsed).ownerSheetID(for: EntityID(raw: Int32(i)), in: rc.parsed.store) == 0x23
        }).convertedID
        session.selection = [id]
        let executor = AIToolExecutor(regen: rc, visibility: VisibilityState(), selectionProvider: { [id] }, spaceProvider: { .paper })
        _ = try executor.execute(tool: "inspect_geometry", arguments: [:])
        _ = try executor.execute(tool: "propose_geometry_edits", arguments: ["editsJSON": replacement(id.raw)])
        rc.selectPaperLayout(0x1B)
        XCTAssertThrowsError(try AIProposedGeometryApplier.apply(executor.stagedGeometry, session: session, regen: rc))
        rc.selectPaperLayout(0x23)
        _ = try AIProposedGeometryApplier.apply(executor.stagedGeometry, session: session, regen: rc)
        let newID = EntityID(raw: Int32(rc.parsed.store.count - 1))
        XCTAssertEqual(PaperLayoutOwnership(rc.parsed).ownerSheetID(for: newID, in: rc.parsed.store), 0x23)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ai-paper-\(UUID()).dxf")
        defer { try? FileManager.default.removeItem(at: url) }
        try DXFStructuralWriter.write(rc.parsed, to: url)
        let loaded = try RegenCoordinator.loadPackage(url: url)
        XCTAssertFalse(loaded.document.paperGroups.contains { !$0.strokes.arcs.isEmpty })
        loaded.selectPaperLayout(0x23)
        XCTAssertTrue(loaded.document.paperGroups.contains { !$0.strokes.arcs.isEmpty })
        session.undo(); XCTAssertFalse(rc.parsed.store.header(id)!.flags.contains(.deleted))
    }

    func testCurveValidationAndCurvedClosedBoundaryPreview() throws {
        XCTAssertThrowsError(try AIGeometryShape(type: "arc", points: [[0,0],[1,0],[2,0]]).normalized())
        XCTAssertThrowsError(try AIGeometryShape(type: "circle", center: [0,0], radius: -.infinity).normalized())
        XCTAssertThrowsError(try AIGeometryShape(type: "polyline", points: [[0,0],[1,0]], bulges: [0,1]).normalized())
        XCTAssertThrowsError(try AIGeometryShape(type: "line", points: [[0,0],[0,0]]).normalized())
        let boundary = try AIGeometryShape(type: "polyline", points: [[10,0],[0,10],[0,9],[9,0]],
            bulges: [tan(.pi/8),0,-tan(.pi/8),0], closed: true).normalized()
        XCTAssertEqual(boundary.previewPoints.first, boundary.previewPoints.last)
        XCTAssertTrue(boundary.previewPoints.contains { abs($0.x - sqrt(50)) < 1e-6 && abs($0.y - sqrt(50)) < 1e-6 })
        // Clockwise input still yields a CCW DXF arc passing through the intended middle point.
        let clockwise = try AIGeometryShape(type: "arc", points: [[0,10],[8,6],[10,0]]).normalized()
        XCTAssertEqual(clockwise.startAngle!, 0, accuracy: 1e-9)
        XCTAssertEqual(clockwise.endAngle!, 90, accuracy: 1e-9)
    }

    @MainActor func testDeleteIsStagedAndUndoableAndUnsupportedMetadataIsRejected() throws {
        let (session, rc, executor, id) = fixture()
        _ = try executor.execute(tool: "inspect_geometry", arguments: [:])
        _ = try executor.execute(tool: "propose_geometry_edits", arguments: ["editsJSON": "[{\"entityIds\":[\(id.raw)],\"replacements\":[]}]"])
        XCTAssertFalse(rc.parsed.store.header(id)!.flags.contains(.deleted))
        _ = try AIProposedGeometryApplier.apply(executor.stagedGeometry, session: session, regen: rc)
        XCTAssertTrue(rc.parsed.store.header(id)!.flags.contains(.deleted)); session.undo()
        rc.parsed.store.residualPairs[id.raw] = RawPairBlob(pairs: [(102, "{ACAD_REACTORS"), (330, "42"), (102, "}")])
        XCTAssertThrowsError(try AIGeometryEditing.inspect(id, regen: rc, visibility: session.visibility, space: .model))
    }

    @MainActor func testUnpackOneBlockLeavesOtherInstancesAndSupportsUndo() throws {
        let parsed = EditableParsedDocument()
        parsed.layers = [DXFLayer(id: 0, name: "Glass")]; parsed.layerIdByName = ["Glass":0]
        let child = parsed.store.append(EntityPrototype(type: .line, layerId: 0, owner: .block(0),
            payload: .line(LinePayload(a: Vec3(x: 0, y: 0), b: Vec3(x: 10, y: 0)))))
        let block = EditableBlockDef(); block.name = "Panel"; block.blockIndex = 0
        block.entityStart = child.raw; block.entityCount = 1; parsed.blocks[block.name] = block
        let name = parsed.store.strings.intern(block.name)
        let first = parsed.store.append(EntityPrototype(type: .insert, layerId: 0,
            payload: .insert(InsertPayload(blockNameId: name, position: Vec3(x: 20, y: 5)))))
        let other = parsed.store.append(EntityPrototype(type: .insert, layerId: 0,
            payload: .insert(InsertPayload(blockNameId: name, position: Vec3(x: 50, y: 5)))))
        let rc = RegenCoordinator(parsed: parsed, document: Regenerator.build(from: parsed, parseSeconds: 0) { _ in })
        let session = DocumentSession(); session.regen = rc
        let executor = AIToolExecutor(regen: rc, visibility: VisibilityState())
        XCTAssertThrowsError(try AIGeometryEditing.inspect(child, regen: rc, visibility: VisibilityState(), space: .model))
        _ = try executor.execute(tool: "propose_explode_block", arguments: ["entityId": Int(first.raw)])
        XCTAssertFalse(parsed.store.header(first)!.flags.contains(.deleted))
        _ = try AIProposedGeometryApplier.apply(executor.stagedGeometry, session: session, regen: rc)
        XCTAssertTrue(parsed.store.header(first)!.flags.contains(.deleted))
        XCTAssertFalse(parsed.store.header(other)!.flags.contains(.deleted))
        XCTAssertFalse(parsed.store.header(child)!.flags.contains(.deleted))
        let shape = try AIGeometryEditing.inspect(EntityID(raw: Int32(parsed.store.count - 1)), regen: rc, visibility: VisibilityState(), space: .model)
        XCTAssertEqual(shape.points, [[20,5],[30,5]])
        session.undo(); XCTAssertFalse(parsed.store.header(first)!.flags.contains(.deleted))
        session.redo(); XCTAssertTrue(parsed.store.header(first)!.flags.contains(.deleted))
        executor.clearStaged()
        _ = try executor.execute(tool: "propose_explode_block", arguments: ["entityId": Int(other.raw)])
        _ = try AIProposedGeometryApplier.apply(executor.stagedGeometry, session: session, regen: rc)
        XCTAssertNil(parsed.blocks[block.name], "An unused source block must not reappear as recovered model content")
        XCTAssertGreaterThanOrEqual(rc.document.modelBounds.minX, 20)
        let secondCurve = EntityID(raw: Int32(parsed.store.count - 1))
        session.performEdit("Reuse retired block index") { tx in
            _ = BlockEditor.createBlock(name: "ReusedIndex", basePoint: .zero, from: [secondCurve],
                insertLayerId: 0, in: parsed, tx: tx)
        }
        XCTAssertEqual(parsed.blocks["ReusedIndex"]?.blockIndex, block.blockIndex)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ai-unpacked-model-\(UUID()).dxf")
        defer { try? FileManager.default.removeItem(at: url) }
        try DXFStructuralWriter.write(parsed, to: url)
        let restored = try RegenCoordinator.loadPackage(url: url)
        XCTAssertGreaterThanOrEqual(restored.document.modelBounds.minX, 20)
        XCTAssertEqual(restored.parsed.store.headers.filter { $0.type == .line && !$0.flags.contains(.deleted) }.count, 2,
            "Retired block content must not resurrect when its owner index is reused")
        session.undo(); session.undo()
        XCTAssertNotNil(parsed.blocks[block.name]); XCTAssertFalse(parsed.store.isDeleted(child))
        XCTAssertFalse(parsed.store.isDeleted(other))
    }

    @MainActor func testUnpackPreservesPaperNotesAndPatternDataThroughUndoRedoAndSave() throws {
        let rc = try RegenCoordinator.loadPackage(url: TestFixtures.url("multiple_layouts.dxf"))
        rc.selectPaperLayout(0x23)
        let parsed = rc.parsed, store = parsed.store
        let block = EditableBlockDef(); block.name = "FacadeWithNotes"
        block.blockIndex = (parsed.blocks.values.map(\.blockIndex).max() ?? -1) + 1
        block.entityStart = Int32(store.count); block.entityCount = 4
        let curve = store.append(EntityPrototype(type: .line, layerId: 0, lineweight: 25, owner: .block(block.blockIndex),
            payload: .line(LinePayload(a: Vec3(x: 0, y: 0), b: Vec3(x: 10, y: 0)))))
        let untouchedCurve = store.append(EntityPrototype(type: .line, layerId: 0, owner: .block(block.blockIndex),
            payload: .line(LinePayload(a: Vec3(x: 20, y: 0), b: Vec3(x: 30, y: 0)))))
        let text = store.append(EntityPrototype(type: .mtext, layerId: 0, lineweight: 15, owner: .block(block.blockIndex),
            payload: .mtext(MTextPayload(insertion: Vec3(x: 2, y: 3), height: 1, stringId: store.strings.intern("Keep this note")))))
        let hatch = store.append(EntityPrototype(type: .hatch, layerId: 0, owner: .block(block.blockIndex),
            payload: .hatch(HatchPayload(isSolid: true, angle: 20, scale: 2, origin: Vec3(x: 1, y: 1)),
                loops: [[Vec3(x: 0, y: 0), Vec3(x: 1, y: 0), Vec3(x: 1, y: 1)]])))
        store.residualPairs[hatch.raw] = RawPairBlob(pairs: [(43,"1.25"),(44,"2.5"),(53,"30")])
        store.setHeader(hatch) { $0.flags.insert(.hasResidual) }
        parsed.blocks[block.name] = block
        let session = DocumentSession(); session.regen = rc; session.space = .paper
        var root = EntityID(raw: -1)
        session.performEdit("Fixture block") { tx in
            root = tx.add(EntityPrototype(type: .insert, layerId: 0, lineweight: 40, owner: .paper,
                payload: .insert(InsertPayload(blockNameId: store.strings.intern(block.name),
                    position: Vec3(x: 50, y: 20), scale: Vec3(x: 2, y: 2, z: 1), rotationDeg: 90))))
        }
        let executor = AIToolExecutor(regen: rc, visibility: VisibilityState(), spaceProvider: { .paper })
        let beforeBlockCount = parsed.blocks.count
        _ = try executor.execute(tool: "propose_explode_block", arguments: ["entityId": Int(root.raw), "curveEntityIdsJSON": "[\(curve.raw)]"])
        _ = try AIProposedGeometryApplier.apply(executor.stagedGeometry, session: session, regen: rc)
        XCTAssertEqual(parsed.blocks.count, beforeBlockCount)
        let remainder = try XCTUnwrap(parsed.blocks.values.first { $0.name.hasPrefix("NOVACAD-REMAINDER-") })
        XCTAssertEqual(remainder.entityCount, 3)
        XCTAssertEqual(store.header(EntityID(raw: remainder.entityStart))?.type, .line)
        XCTAssertTrue(store.isDeleted(untouchedCurve))
        XCTAssertEqual(store.header(EntityID(raw: remainder.entityStart + 1))?.type, .mtext)
        XCTAssertEqual(store.header(EntityID(raw: remainder.entityStart + 1))?.lineweight, 15)
        XCTAssertEqual(store.residualPairs[remainder.entityStart + 2]?.pairs.map(\.value), ["1.25","2.5","30"])
        let extracted = EntityID(raw: Int32(store.count - 1))
        let shape = try AIGeometryEditing.inspect(extracted, regen: rc, visibility: VisibilityState(), space: .paper)
        XCTAssertEqual(shape.points[0][0], 50, accuracy: 1e-9); XCTAssertEqual(shape.points[1][1], 40, accuracy: 1e-9)
        XCTAssertEqual(store.header(extracted)?.lineweight, 25)
        XCTAssertTrue(store.isDeleted(curve)); XCTAssertTrue(store.isDeleted(text)); XCTAssertTrue(store.isDeleted(hatch))
        XCTAssertTrue(rc.document.paperGroups.flatMap(\.texts).contains { $0.text == "Keep this note" })
        session.undo(); XCTAssertEqual(parsed.blocks.count, beforeBlockCount)
        XCTAssertFalse(store.isDeleted(root))
        session.redo(); XCTAssertEqual(parsed.blocks.count, beforeBlockCount)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ai-unpack-\(UUID()).dxf")
        defer { try? FileManager.default.removeItem(at: url) }
        try DXFStructuralWriter.write(parsed, to: url)
        let restored = try RegenCoordinator.loadPackage(url: url)
        restored.selectPaperLayout(0x23)
        XCTAssertTrue(restored.document.paperGroups.flatMap(\.texts).contains { $0.text == "Keep this note" })
        let retained = try XCTUnwrap(restored.parsed.blocks.values.first { $0.name == remainder.name })
        XCTAssertEqual(restored.parsed.store.residualPairs[retained.entityStart + 2]?.pairs.filter { [43,44,53].contains(Int($0.code)) }.compactMap { Double($0.value) }, [1.25,2.5,30])
        restored.selectPaperLayout(0x1B)
        XCTAssertFalse(restored.document.paperGroups.flatMap(\.texts).contains { $0.text == "Keep this note" })
    }

    @MainActor func testLargeBlockRequiresSpecificCurvesAndRetainsByBlockAppearance() throws {
        let parsed = EditableParsedDocument()
        var parentLayer = DXFLayer(id: 0, name: "0", color: .rgb(0x663399))
        parentLayer.lineweight = 35; parentLayer.linetypeId = 1
        parsed.layers = [parentLayer, DXFLayer(id: 1, name: "Glass", color: .rgb(0x00FF00))]
        parsed.layerIdByName = ["0":0, "Glass":1]
        parsed.linetypes = [DXFLinetype(name: "CONTINUOUS", dashes: []), DXFLinetype(name: "DASHED", dashes: [2,-1])]
        let block = EditableBlockDef(); block.name = "ManyPanels"; block.blockIndex = 0
        block.entityStart = 0; block.entityCount = 65
        for i in 0..<65 {
            _ = parsed.store.append(EntityPrototype(type: .line, layerId: 1, aci: 0, linetypeId: -2, lineweight: -2, owner: .block(0),
                payload: .line(LinePayload(a: Vec3(x: Double(i), y: 0), b: Vec3(x: Double(i), y: 1)))))
        }
        parsed.blocks[block.name] = block
        let root = parsed.store.append(EntityPrototype(type: .insert, layerId: 0,
            payload: .insert(InsertPayload(blockNameId: parsed.store.strings.intern(block.name), position: Vec3(x: 20, y: 5)))))
        let rc = RegenCoordinator(parsed: parsed, document: Regenerator.build(from: parsed, parseSeconds: 0) { _ in })
        let session = DocumentSession(); session.regen = rc
        let executor = AIToolExecutor(regen: rc, visibility: VisibilityState())
        XCTAssertThrowsError(try executor.execute(tool: "propose_explode_block", arguments: ["entityId": Int(root.raw)]))
        XCTAssertThrowsError(try executor.execute(tool: "propose_explode_block", arguments: ["entityId": Int(root.raw), "curveEntityIdsJSON":"[999]"]))
        for invalid: Any in [Double.infinity, Double.nan, 1e100, 1.5, true, "65"] {
            XCTAssertThrowsError(try executor.execute(tool: "propose_explode_block", arguments: ["entityId": invalid]))
        }
        XCTAssertThrowsError(try executor.execute(tool: "get_insert_attributes", arguments: ["insertEntityId": Int.max]))
        XCTAssertThrowsError(try executor.execute(tool: "get_insert_attributes", arguments: ["insertEntityId": 1e300]))
        XCTAssertNoThrow(try executor.execute(tool: "query_entities", arguments: ["offset": 1e300, "limit": Double.infinity]))
        XCTAssertThrowsError(try executor.execute(tool: "draw_polylines", arguments: ["pathsJSON":"[[[0,0],[1,1]]]", "colorIndex": Int.max]))
        _ = try executor.execute(tool: "propose_attribute_edits", arguments: ["edits": ["{\"insertEntityId\":9223372036854775807,\"attributeTag\":\"TAG\",\"newValue\":\"VALUE\"}"]])
        XCTAssertTrue(executor.stagedEdits.isEmpty)
        XCTAssertTrue(executor.stagedGeometry.isEmpty)
        _ = try executor.execute(tool: "propose_explode_block", arguments: ["entityId": Int(root.raw), "curveEntityIdsJSON":"[0]"])
        session.visibility.hiddenLayerIds = [1]
        XCTAssertThrowsError(try AIProposedGeometryApplier.apply(executor.stagedGeometry, session: session, regen: rc))
        session.visibility.hiddenLayerIds = []
        _ = try AIProposedGeometryApplier.apply(executor.stagedGeometry, session: session, regen: rc)
        let extracted = try XCTUnwrap(parsed.store.headers.last)
        XCTAssertEqual(extracted.trueColor, 0x663399); XCTAssertEqual(extracted.lineweight, 35)
        XCTAssertEqual(extracted.linetypeId, 1); XCTAssertEqual(extracted.layerId, 1)
        XCTAssertTrue((0..<65).allSatisfy { parsed.store.isDeleted(EntityID(raw: Int32($0))) })
        let remainder = try XCTUnwrap(parsed.blocks.values.first)
        XCTAssertEqual(remainder.entityCount, 64)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ai-scoped-unpack-\(UUID()).dxf")
        defer { try? FileManager.default.removeItem(at: url) }
        try DXFStructuralWriter.write(parsed, to: url)
        let restored = try RegenCoordinator.loadPackage(url: url)
        XCTAssertEqual(restored.parsed.store.headers.filter { $0.type == .line && !$0.flags.contains(.deleted) }.count, 65)
    }

    @MainActor func testOptionalLiveAssistantStagesCurveOnSyntheticDrawing() async throws {
        guard ProcessInfo.processInfo.environment["NOVACAD_AI_LIVE_GEOMETRY"] == "1" else {
            throw XCTSkip("Live provider check is opt-in and uses only synthetic geometry")
        }
        // Read installed-app configuration without logging or persisting a copy.
        guard let data = UserDefaults(suiteName: "com.novacad.app")?.data(forKey: "novacad.aiAssistant.config") else {
            throw XCTSkip("Installed-app AI configuration unavailable")
        }
        let defaults = UserDefaults.standard
        let previous = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        var temporary = previous; temporary["novacad.aiAssistant.config"] = data
        defaults.setVolatileDomain(temporary, forName: UserDefaults.argumentDomain)
        defer { defaults.setVolatileDomain(previous, forName: UserDefaults.argumentDomain) }
        let (session, rc, _, id) = fixture()
        let ai = session.aiAssistant
        ai.selectionProvider = { [id] }; ai.spaceProvider = { .model }
        ai.viewportProvider = { CGRect(x: -2, y: -2, width: 15, height: 15) }
        ai.pendingInput = "Turn the selected faceted line into one smooth circular arc passing through its existing vertices. Please prepare the edit for me."
        ai.send(regen: rc, visibility: VisibilityState())
        let deadline = Date().addingTimeInterval(120)
        while ai.isThinking && Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
        if ai.isThinking { ai.cancel() }
        XCTAssertNil(ai.errorMessage)
        XCTAssertTrue(ai.stagedGeometry.contains { $0.editPlan?.edits.first?.replacements.first?.type == "arc" },
            "Live assistant should prepare an actual geometry edit")
        XCTAssertFalse(rc.parsed.store.isDeleted(id), "Provider calls must only stage changes")
        XCTAssertEqual(rc.parsed.document.revision, 0)
        let transcript = ai.history.map { entry in
            entry.toolCall.map { "Tool: \($0.name) \($0.status)" } ?? entry.text
        }.joined(separator: "\n")
        try transcript.write(toFile: "/tmp/novacad-synthetic-live-geometry.txt", atomically: true, encoding: .utf8)
    }

    @MainActor func testOptionalPrivateDrawingBlockPreflightReadOnly() throws {
        guard let path = ProcessInfo.processInfo.environment["NOVACAD_AI_SAMPLE"] else { throw XCTSkip("Private fixture is opt-in") }
        let rc = try RegenCoordinator.loadPackage(url: URL(fileURLWithPath: path))
        guard let sheet = rc.parsed.paperLayouts.first(where: { $0.name.hasPrefix("A-102") }) else { throw XCTSkip("Construction sheet unavailable") }
        rc.selectPaperLayout(sheet.id)
        let before = rc.parsed.document.revision
        let ownership = PaperLayoutOwnership(rc.parsed)
        var report: [String] = []
        for i in rc.parsed.store.headers.indices {
            let id = EntityID(raw: Int32(i)), h = rc.parsed.store.headers[i]
            guard h.type == .insert, ownership.ownerSheetID(for: id, in: rc.parsed.store) == sheet.id else { continue }
            do { report.append("\(id.raw): \(try AIGeometryEditing.inspectBlock(id, regen: rc, visibility: VisibilityState(), space: .paper)) children supported") }
            catch { report.append("\(id.raw): \(error.localizedDescription)") }
        }
        try report.joined(separator: "\n").write(toFile: "/tmp/novacad-private-block-preflight.txt", atomically: true, encoding: .utf8)
        XCTAssertEqual(rc.parsed.document.revision, before)
        XCTAssertTrue(report.contains { $0.contains("children supported") }, "At least one construction-sheet block must support curve extraction")
    }
}
private extension Int { var convertedID: EntityID { EntityID(raw: Int32(self)) } }
