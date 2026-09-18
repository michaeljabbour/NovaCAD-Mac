import XCTest
@testable import DWGViewer
import CADCore

/// Tests for cross-drawing Copy/Paste — `PasteboardSnapshot.capture`/`write`/
/// `read` (the pasteboard wire format) and `CrossDocumentPaste.commitPaste`
/// (the destination-side commit engine). Uses two independent, hand-
/// constructed `EditableParsedDocument`/`RegenCoordinator` pairs (never a
/// SHARED `EntityStore`) to model "two separate open drawings" faithfully —
/// the whole point of this feature is that the destination has its own,
/// unrelated layer/linetype/block tables.
final class CrossDocumentPasteTests: XCTestCase {

    private func makeParsed(layerNames: [String] = ["0"]) -> EditableParsedDocument {
        let parsed = EditableParsedDocument()
        for (i, name) in layerNames.enumerated() {
            parsed.layers.append(DXFLayer(id: i, name: name))
            parsed.layerIdByName[name] = Int32(i)
        }
        parsed.linetypes.append(DXFLinetype(name: "CONTINUOUS", dashes: []))
        parsed.linetypeIdByName["CONTINUOUS"] = 0
        return parsed
    }

    private func makeCoordinator(_ parsed: EditableParsedDocument) -> RegenCoordinator {
        let doc = Regenerator.build(from: parsed, parseSeconds: 0) { _ in }
        return RegenCoordinator(parsed: parsed, document: doc)
    }

    // MARK: - Capture (Copy)

    func testCaptureIncludesEveryTopLevelSelectedEntity() throws {
        let source = makeParsed(layerNames: ["0", "PIPING"])
        let doc = source.document
        var lineId: EntityID!, circleId: EntityID!
        doc.transact("Draw") { tx in
            lineId = tx.add(EntityPrototype(type: .line, layerId: 0,
                payload: .line(LinePayload(a: Vec3(x: 0, y: 0), b: Vec3(x: 10, y: 0)))))
            circleId = tx.add(EntityPrototype(type: .circle, layerId: 1,
                payload: .circle(CirclePayload(center: Vec3(x: 5, y: 5), radius: 2))))
        }
        let snapshot = try XCTUnwrap(PasteboardSnapshot.capture(ids: [lineId, circleId], from: source))
        XCTAssertEqual(snapshot.entities.count, 2)
        XCTAssertTrue(snapshot.entities.contains { if case .line = $0.payload { return true }; return false })
        XCTAssertTrue(snapshot.entities.contains { if case .circle = $0.payload { return true }; return false })
        XCTAssertTrue(snapshot.layers.contains { $0.name == "PIPING" })
    }

    func testCaptureReturnsNilForEmptyOrAllDeletedSelection() throws {
        let source = makeParsed()
        XCTAssertNil(PasteboardSnapshot.capture(ids: [], from: source))

        let doc = source.document
        var id: EntityID!
        doc.transact("Draw") { tx in
            id = tx.add(EntityPrototype(type: .line, layerId: 0,
                payload: .line(LinePayload(a: Vec3(x: 0, y: 0), b: Vec3(x: 1, y: 1)))))
        }
        doc.transact("Delete") { tx in tx.delete(id) }
        XCTAssertNil(PasteboardSnapshot.capture(ids: [id], from: source))
    }

    func testCaptureCarriesTextContentAndAttribChildrenOfAnInsert() throws {
        let source = makeParsed()
        let doc = source.document

        let blockIndex = BlockEditor.nextBlockIndex(in: source)
        var rectId: EntityID!
        doc.transact("Define block") { tx in
            rectId = tx.add(EntityPrototype(type: .lwpolyline, layerId: 0, owner: .block(blockIndex),
                payload: .polyline(PolylinePayload(closed: true),
                                   vertices: [Vec3(x: 0, y: 0), Vec3(x: 10, y: 0), Vec3(x: 10, y: 10), Vec3(x: 0, y: 10)],
                                   bulges: [0, 0, 0, 0])))
        }
        let block = EditableBlockDef()
        block.name = "WORKSTATION"
        block.blockIndex = blockIndex
        block.entityStart = rectId.raw
        block.entityCount = 1
        source.blocks["WORKSTATION"] = block

        doc.transact("Add NAME attdef") { tx in
            _ = BlockEditor.createAttdef(tag: "NAME", prompt: "", defaultValue: "UNNAMED",
                                        at: CGPoint(x: 5, y: 5), height: 1, layerId: 0,
                                        inBlockNamed: "WORKSTATION", in: source, tx: tx)
        }

        var insertId: EntityID!
        doc.transact("Insert") { tx in
            insertId = BlockEditor.insert(blockName: "WORKSTATION", at: CGPoint(x: 100, y: 200),
                                          layerId: 0, attributeValues: ["NAME": "STN-4"], in: source, tx: tx)
        }

        let snapshot = try XCTUnwrap(PasteboardSnapshot.capture(ids: [insertId], from: source))
        let insertEntity = try XCTUnwrap(snapshot.entities.first)
        guard case .insert(let blockName, _, _, _, _, _, _, _) = insertEntity.payload else {
            return XCTFail("expected an insert payload")
        }
        XCTAssertEqual(blockName, "WORKSTATION")
        XCTAssertEqual(insertEntity.children.count, 1, "the ATTRIB child must be captured")
        guard case .text(_, _, _, _, _, _, let value, _, _, _, _, _, let tag, _) = insertEntity.children[0].payload else {
            return XCTFail("expected a text payload for the ATTRIB")
        }
        XCTAssertEqual(value, "STN-4")
        XCTAssertEqual(tag, "NAME")

        XCTAssertEqual(snapshot.blocks.count, 1)
        XCTAssertEqual(snapshot.blocks.first?.name, "WORKSTATION")
        XCTAssertEqual(snapshot.blocks.first?.entities.count, 2, "the block's own rectangle + its ATTDEF")
    }

    // MARK: - Pasteboard write/read round-trip

    func testWriteAndReadRoundTripsThroughAPrivatePasteboard() throws {
        let source = makeParsed()
        let doc = source.document
        var id: EntityID!
        doc.transact("Draw") { tx in
            id = tx.add(EntityPrototype(type: .circle, layerId: 0,
                payload: .circle(CirclePayload(center: Vec3(x: 1, y: 2), radius: 3))))
        }
        let snapshot = try XCTUnwrap(PasteboardSnapshot.capture(ids: [id], from: source))

        let pb = NSPasteboard(name: .init("com.novacad.tests.\(UUID().uuidString)"))
        PasteboardSnapshot.write(snapshot, to: pb)
        let readBack = try XCTUnwrap(PasteboardSnapshot.read(from: pb))
        XCTAssertEqual(readBack.entities.count, 1)
        guard case .circle(let center, let radius, _) = readBack.entities[0].payload else {
            return XCTFail("expected a circle payload")
        }
        XCTAssertEqual(center, Vec3(x: 1, y: 2))
        XCTAssertEqual(radius, 3)
    }

    func testReadReturnsNilWhenPasteboardHasNoSnapshot() {
        let pb = NSPasteboard(name: .init("com.novacad.tests.empty.\(UUID().uuidString)"))
        pb.clearContents()
        pb.setString("just some text", forType: .string)
        XCTAssertNil(PasteboardSnapshot.read(from: pb))
    }

    // MARK: - commitPaste: cross-document layer/linetype registration

    func testCommitPasteCreatesMissingLayerByNameCarryingOverColor() throws {
        let source = makeParsed(layerNames: ["0", "PIPING"])
        let sourceDoc = source.document
        var id: EntityID!
        sourceDoc.transact("Draw") { tx in
            id = tx.add(EntityPrototype(type: .line, layerId: 1,
                payload: .line(LinePayload(a: Vec3(x: 0, y: 0), b: Vec3(x: 1, y: 1)))))
        }
        // Give the source's PIPING layer a distinct color to verify it
        // survives into the newly-created destination layer.
        source.layers[1].color = .rgb(0x00AAFF)
        let snapshot = try XCTUnwrap(PasteboardSnapshot.capture(ids: [id], from: source))

        let dest = makeParsed(layerNames: ["0"])   // no PIPING layer yet
        let destRC = makeCoordinator(dest)
        session_performPaste(snapshot, dx: 0, dy: 0, regen: destRC)

        let newLayerId = try XCTUnwrap(dest.layerIdByName["PIPING"])
        XCTAssertEqual(dest.layers[Int(newLayerId)].color, .rgb(0x00AAFF))
    }

    func testCommitPasteReusesExistingDestinationLayerByName() throws {
        let source = makeParsed(layerNames: ["0", "PIPING"])
        let sourceDoc = source.document
        var id: EntityID!
        sourceDoc.transact("Draw") { tx in
            id = tx.add(EntityPrototype(type: .line, layerId: 1,
                payload: .line(LinePayload(a: Vec3(x: 0, y: 0), b: Vec3(x: 1, y: 1)))))
        }
        let snapshot = try XCTUnwrap(PasteboardSnapshot.capture(ids: [id], from: source))

        let dest = makeParsed(layerNames: ["0", "PIPING"])   // ALREADY has PIPING
        let destRC = makeCoordinator(dest)
        let layerCountBefore = dest.layers.count
        let ids = session_performPaste(snapshot, dx: 0, dy: 0, regen: destRC)

        XCTAssertEqual(dest.layers.count, layerCountBefore, "must reuse the existing PIPING layer, not duplicate it")
        let newHeader = try XCTUnwrap(destRC.parsed.store.header(try XCTUnwrap(ids.first)))
        XCTAssertEqual(newHeader.layerId, dest.layerIdByName["PIPING"])
    }

    // MARK: - commitPaste: translation

    func testCommitPasteTranslatesGeometryByRequestedOffset() throws {
        let source = makeParsed()
        let sourceDoc = source.document
        var id: EntityID!
        sourceDoc.transact("Draw") { tx in
            id = tx.add(EntityPrototype(type: .line, layerId: 0,
                payload: .line(LinePayload(a: Vec3(x: 0, y: 0), b: Vec3(x: 10, y: 0)))))
        }
        let snapshot = try XCTUnwrap(PasteboardSnapshot.capture(ids: [id], from: source))

        let dest = makeParsed()
        let destRC = makeCoordinator(dest)
        let newIds = session_performPaste(snapshot, dx: 100, dy: 200, regen: destRC)
        let newId = try XCTUnwrap(newIds.first)
        let header = try XCTUnwrap(destRC.parsed.store.header(newId))
        let line = destRC.parsed.store.lines[Int(header.payload)]
        XCTAssertEqual(line.a, Vec3(x: 100, y: 200))
        XCTAssertEqual(line.b, Vec3(x: 110, y: 200))
    }

    func testCommitPasteAtOriginalCoordinatesUsesZeroTranslation() throws {
        let source = makeParsed()
        let sourceDoc = source.document
        var id: EntityID!
        sourceDoc.transact("Draw") { tx in
            id = tx.add(EntityPrototype(type: .point, layerId: 0, payload: .point(PointPayload(p: Vec3(x: 42, y: 7)))))
        }
        let snapshot = try XCTUnwrap(PasteboardSnapshot.capture(ids: [id], from: source))

        let dest = makeParsed()
        let destRC = makeCoordinator(dest)
        let newIds = session_performPaste(snapshot, dx: 0, dy: 0, regen: destRC)
        let newId = try XCTUnwrap(newIds.first)
        let header = try XCTUnwrap(destRC.parsed.store.header(newId))
        XCTAssertEqual(destRC.parsed.store.points[Int(header.payload)].p, Vec3(x: 42, y: 7))
    }

    // MARK: - commitPaste: INSERT + block registration + ATTRIB re-parenting

    func testCommitPasteRegistersMissingBlockAndReparentsAttribOntoNewInsert() throws {
        let source = makeParsed()
        let sourceDoc = source.document
        let blockIndex = BlockEditor.nextBlockIndex(in: source)
        var rectId: EntityID!
        sourceDoc.transact("Define block") { tx in
            rectId = tx.add(EntityPrototype(type: .lwpolyline, layerId: 0, owner: .block(blockIndex),
                payload: .polyline(PolylinePayload(closed: true),
                                   vertices: [Vec3(x: 0, y: 0), Vec3(x: 10, y: 0), Vec3(x: 10, y: 10), Vec3(x: 0, y: 10)],
                                   bulges: [0, 0, 0, 0])))
        }
        let block = EditableBlockDef()
        block.name = "WORKSTATION"
        block.blockIndex = blockIndex
        block.entityStart = rectId.raw
        block.entityCount = 1
        source.blocks["WORKSTATION"] = block
        sourceDoc.transact("Add NAME attdef") { tx in
            _ = BlockEditor.createAttdef(tag: "NAME", prompt: "", defaultValue: "UNNAMED",
                                        at: CGPoint(x: 5, y: 5), height: 1, layerId: 0,
                                        inBlockNamed: "WORKSTATION", in: source, tx: tx)
        }
        var insertId: EntityID!
        sourceDoc.transact("Insert") { tx in
            insertId = BlockEditor.insert(blockName: "WORKSTATION", at: CGPoint(x: 100, y: 200),
                                          layerId: 0, attributeValues: ["NAME": "STN-4"], in: source, tx: tx)
        }
        let snapshot = try XCTUnwrap(PasteboardSnapshot.capture(ids: [insertId], from: source))

        let dest = makeParsed()   // no WORKSTATION block at all
        let destRC = makeCoordinator(dest)
        XCTAssertNil(dest.blocks["WORKSTATION"])
        let newIds = session_performPaste(snapshot, dx: 0, dy: 0, regen: destRC)

        let newInsertId = try XCTUnwrap(newIds.first)
        XCTAssertNotNil(dest.blocks["WORKSTATION"], "the missing block definition must be registered")

        let children = destRC.parsed.store.children(of: newInsertId)
        XCTAssertEqual(children.count, 1, "the ATTRIB must be re-parented onto the NEW insert's id")
        let attrs = BlockEditor.attributes(of: newInsertId, in: destRC.parsed.store)
        XCTAssertEqual(attrs.first { $0.tag == "NAME" }?.value, "STN-4")
    }

    func testCommitPasteReusesExistingDestinationBlockByName() throws {
        let source = makeParsed()
        let sourceDoc = source.document
        let sourceBlockIndex = BlockEditor.nextBlockIndex(in: source)
        var sourceRectId: EntityID!
        sourceDoc.transact("Define block") { tx in
            sourceRectId = tx.add(EntityPrototype(type: .line, layerId: 0, owner: .block(sourceBlockIndex),
                payload: .line(LinePayload(a: Vec3(x: 0, y: 0), b: Vec3(x: 1, y: 1)))))
        }
        let sourceBlock = EditableBlockDef()
        sourceBlock.name = "SHARED"
        sourceBlock.blockIndex = sourceBlockIndex
        sourceBlock.entityStart = sourceRectId.raw
        sourceBlock.entityCount = 1
        source.blocks["SHARED"] = sourceBlock
        var insertId: EntityID!
        sourceDoc.transact("Insert") { tx in
            insertId = BlockEditor.insert(blockName: "SHARED", at: CGPoint(x: 0, y: 0), layerId: 0, in: source, tx: tx)
        }
        let snapshot = try XCTUnwrap(PasteboardSnapshot.capture(ids: [insertId], from: source))

        // Destination ALREADY has a block named SHARED.
        let dest = makeParsed()
        let destBlockIndex = BlockEditor.nextBlockIndex(in: dest)
        let destBlock = EditableBlockDef()
        destBlock.name = "SHARED"
        destBlock.blockIndex = destBlockIndex
        destBlock.entityStart = 0
        destBlock.entityCount = 0
        dest.blocks["SHARED"] = destBlock
        let destRC = makeCoordinator(dest)
        let blockCountBefore = dest.blocks.count

        _ = session_performPaste(snapshot, dx: 0, dy: 0, regen: destRC)
        XCTAssertEqual(dest.blocks.count, blockCountBefore, "must reuse the existing SHARED block, not register a second one")
    }

    // MARK: - commitPaste: undo

    func testCommitPasteIsUndoable() throws {
        let source = makeParsed(layerNames: ["0", "PIPING"])
        let sourceDoc = source.document
        var id: EntityID!
        sourceDoc.transact("Draw") { tx in
            id = tx.add(EntityPrototype(type: .line, layerId: 1,
                payload: .line(LinePayload(a: Vec3(x: 0, y: 0), b: Vec3(x: 1, y: 1)))))
        }
        let snapshot = try XCTUnwrap(PasteboardSnapshot.capture(ids: [id], from: source))

        let dest = makeParsed(layerNames: ["0"])
        let destRC = makeCoordinator(dest)
        let layersBefore = dest.layers.count
        let newIds = session_performPaste(snapshot, dx: 5, dy: 5, regen: destRC)
        let newId = try XCTUnwrap(newIds.first)

        XCTAssertFalse(destRC.parsed.store.isDeleted(newId))
        XCTAssertGreaterThan(dest.layers.count, layersBefore, "PIPING must have been newly registered")

        destRC.parsed.document.undo()
        destRC.fullRebuild()
        XCTAssertTrue(destRC.parsed.store.isDeleted(newId), "undo must tombstone the pasted entity")
    }

    // MARK: - Test helper

    /// Drives `CrossDocumentPaste.commitPaste` inside a real `Transaction`
    /// against `regen`'s own document, then applies the resulting ops to
    /// `regen`'s render model — mirroring exactly what `ContentView
    /// .commitClipboardPaste` does in the live app, without needing a full
    /// `DocumentSession`/`ContentView` instance for these unit tests.
    @discardableResult
    private func session_performPaste(_ snapshot: PasteboardSnapshot.Snapshot, dx: Double, dy: Double,
                                      regen: RegenCoordinator) -> [EntityID] {
        var newIds: [EntityID] = []
        regen.parsed.document.transact("Paste") { tx in
            newIds = CrossDocumentPaste.commitPaste(snapshot, dx: dx, dy: dy, owner: .model,
                                                    in: regen.parsed, tx: tx)
        }
        regen.apply(regen.parsed.document.undoStack.last?.ops ?? [])
        return newIds
    }
}
