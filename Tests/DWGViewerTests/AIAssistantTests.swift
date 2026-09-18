import XCTest
@testable import DWGViewer
import CADCore

/// Tests for the AI Assistant's drawing-read (`DrawingReader`), tool-
/// dispatch (`AIToolExecutor`), and bulk-edit-apply (`AIProposedEditApplier`)
/// layers — the parts of the feature that don't require a live network call.
/// `AIClient`'s wire format itself isn't covered here (no test doubles
/// for `URLSession` exist in this codebase yet — out of scope for this
/// pass); these tests exercise everything downstream of "the model decided
/// to call tool X with arguments Y."
final class AIAssistantTests: XCTestCase {

    private func makeParsed() -> EditableParsedDocument {
        let parsed = EditableParsedDocument()
        parsed.layers.append(DXFLayer(id: 0, name: "0"))
        parsed.layerIdByName["0"] = 0
        parsed.layers.append(DXFLayer(id: 1, name: "LABELS"))
        parsed.layerIdByName["LABELS"] = 1
        parsed.linetypes.append(DXFLinetype(name: "CONTINUOUS", dashes: []))
        parsed.linetypeIdByName["CONTINUOUS"] = 0
        return parsed
    }

    private func makeCoordinator(_ parsed: EditableParsedDocument) -> RegenCoordinator {
        let doc = Regenerator.build(from: parsed, parseSeconds: 0) { _ in }
        return RegenCoordinator(parsed: parsed, document: doc)
    }

    /// Builds a small drawing with: a plain LINE on layer 0, a plain TEXT
    /// label ("STN-4") on layer LABELS sitting inside a WORKSTATION block's
    /// footprint, and one INSERT of a WORKSTATION block (containing a
    /// rectangle + a NAME attdef) at a known position — the exact shape the
    /// "read the label, find its enclosing block, rename the block's NAME
    /// attribute to match" workflow needs.
    private func makeWorkstationFixture() -> (parsed: EditableParsedDocument, insertId: EntityID, labelId: EntityID) {
        let parsed = makeParsed()
        let doc = parsed.document

        // WORKSTATION block: a 10x10 rectangle (LWPOLYLINE) + a NAME attdef.
        let blockIndex = BlockEditor.nextBlockIndex(in: parsed)
        var rectId: EntityID!
        doc.transact("Define block content") { tx in
            rectId = tx.add(EntityPrototype(
                type: .lwpolyline, layerId: 0, owner: .block(blockIndex),
                payload: .polyline(PolylinePayload(closed: true),
                                   vertices: [Vec3(x: 0, y: 0), Vec3(x: 10, y: 0), Vec3(x: 10, y: 10), Vec3(x: 0, y: 10)],
                                   bulges: [0, 0, 0, 0])))
        }
        let block = EditableBlockDef()
        block.name = "WORKSTATION"
        block.blockIndex = blockIndex
        block.entityStart = rectId.raw
        block.entityCount = 1
        parsed.blocks["WORKSTATION"] = block

        var attdefId: EntityID!
        doc.transact("Add NAME attdef") { tx in
            attdefId = BlockEditor.createAttdef(tag: "NAME", prompt: "", defaultValue: "UNNAMED",
                                                at: CGPoint(x: 5, y: 5), height: 1, layerId: 0,
                                                inBlockNamed: "WORKSTATION", in: parsed, tx: tx)
        }
        XCTAssertNotNil(attdefId)

        // INSERT the block at (100, 200) — its footprint is therefore
        // (100,200)-(110,210) in world space.
        var insertId: EntityID!
        doc.transact("Insert") { tx in
            insertId = BlockEditor.insert(blockName: "WORKSTATION", at: CGPoint(x: 100, y: 200),
                                          layerId: 0, in: parsed, tx: tx)
        }

        // A loose label TEXT (not an ATTRIB — just drawn near/inside the
        // block's footprint) reading "STN-4", positioned inside the
        // INSERT's world-space bounds.
        var labelId: EntityID!
        doc.transact("Draw label") { tx in
            let stringId = parsed.store.strings.intern("STN-4")
            labelId = tx.add(EntityPrototype(
                type: .text, layerId: 1, owner: .model,
                payload: .text(TextPayload(position: Vec3(x: 103, y: 203), height: 1, stringId: stringId))))
        }

        return (parsed, insertId, labelId)
    }

    // MARK: - DrawingReader.summarize

    func testSummarizeIncludesEveryTopLevelEntityWithLayerAndBounds() throws {
        let (parsed, insertId, labelId) = makeWorkstationFixture()
        let rc = makeCoordinator(parsed)
        let summary = DrawingReader.summarize(document: rc.document, space: .model, visibility: VisibilityState())

        XCTAssertFalse(summary.truncated)
        let insertRow = try XCTUnwrap(summary.entities.first { $0.entityId == insertId.raw })
        XCTAssertEqual(insertRow.type, "insert")
        XCTAssertEqual(insertRow.blockName, "WORKSTATION")
        XCTAssertEqual(insertRow.layer, "0")

        let labelRow = try XCTUnwrap(summary.entities.first { $0.entityId == labelId.raw })
        XCTAssertEqual(labelRow.type, "text")
        XCTAssertEqual(labelRow.text, "STN-4")
        XCTAssertEqual(labelRow.layer, "LABELS")
        XCTAssertEqual(labelRow.minX, 103, accuracy: 1e-6)
        XCTAssertEqual(labelRow.minY, 203, accuracy: 1e-6)
    }

    func testSummarizeOmitsEntitiesOnHiddenLayers() throws {
        let (parsed, _, labelId) = makeWorkstationFixture()
        let rc = makeCoordinator(parsed)
        var visibility = VisibilityState()
        visibility.hiddenLayerIds = [1]   // LABELS
        let summary = DrawingReader.summarize(document: rc.document, space: .model, visibility: visibility)
        XCTAssertFalse(summary.entities.contains { $0.entityId == labelId.raw })
    }

    func testSummarizeIsJSONEncodable() throws {
        let (parsed, _, _) = makeWorkstationFixture()
        let rc = makeCoordinator(parsed)
        let summary = DrawingReader.summarize(document: rc.document, space: .model, visibility: VisibilityState())
        let data = try JSONEncoder().encode(summary)
        XCTAssertGreaterThan(data.count, 0)
    }

    // MARK: - DrawingReader.insertContaining / insertContentBounds

    func testInsertContainingFindsTheEnclosingBlockForAPointInsideIt() throws {
        let (parsed, insertId, _) = makeWorkstationFixture()
        let rc = makeCoordinator(parsed)
        // (103, 203) is inside the WORKSTATION insert's (100,200)-(110,210) footprint.
        let found = DrawingReader.insertContaining(worldPoint: CGPoint(x: 103, y: 203),
                                                    document: rc.document, space: .model)
        let insert = try XCTUnwrap(found)
        XCTAssertEqual(insert.entityId, insertId.raw)
        XCTAssertEqual(insert.name, "WORKSTATION")
    }

    func testInsertContainingReturnsNilForAPointOutsideEveryInsert() throws {
        let (parsed, _, _) = makeWorkstationFixture()
        let rc = makeCoordinator(parsed)
        let found = DrawingReader.insertContaining(worldPoint: CGPoint(x: -500, y: -500),
                                                    document: rc.document, space: .model)
        XCTAssertNil(found)
    }

    // MARK: - AIToolExecutor

    @MainActor
    func testReadDrawingToolReturnsValidJSONSummary() throws {
        let (parsed, insertId, _) = makeWorkstationFixture()
        let rc = makeCoordinator(parsed)
        let executor = AIToolExecutor(regen: rc, visibility: VisibilityState())
        let result = try executor.execute(tool: "read_drawing", arguments: [:])
        XCTAssertTrue(result.contains("\"entityId\":\(insertId.raw)"))
        XCTAssertTrue(result.contains("WORKSTATION"))
    }

    @MainActor
    func testGetInsertAttributesToolListsTagAndValue() throws {
        let (parsed, insertId, _) = makeWorkstationFixture()
        let rc = makeCoordinator(parsed)
        let executor = AIToolExecutor(regen: rc, visibility: VisibilityState())
        let result = try executor.execute(tool: "get_insert_attributes",
                                          arguments: ["insertEntityId": Double(insertId.raw)])
        XCTAssertTrue(result.contains("NAME: UNNAMED"))
    }

    @MainActor
    func testFindInsertAtPointToolReportsEntityIdAndBlockName() throws {
        let (parsed, insertId, _) = makeWorkstationFixture()
        let rc = makeCoordinator(parsed)
        let executor = AIToolExecutor(regen: rc, visibility: VisibilityState())
        let result = try executor.execute(tool: "find_insert_at_point", arguments: ["x": 103.0, "y": 203.0])
        XCTAssertTrue(result.contains("entityId=\(insertId.raw)"))
        XCTAssertTrue(result.contains("blockName=WORKSTATION"))
    }

    @MainActor
    func testProposeAttributeEditsStagesAnEditWithOldValueResolved() throws {
        let (parsed, insertId, _) = makeWorkstationFixture()
        let rc = makeCoordinator(parsed)
        let executor = AIToolExecutor(regen: rc, visibility: VisibilityState())
        let editJSON = "{\"insertEntityId\":\(insertId.raw),\"attributeTag\":\"NAME\",\"newValue\":\"STN-4\"}"
        let result = try executor.execute(tool: "propose_attribute_edits", arguments: ["edits": [editJSON]])

        XCTAssertEqual(executor.stagedEdits.count, 1)
        let edit = try XCTUnwrap(executor.stagedEdits.first)
        XCTAssertEqual(edit.insertEntityId, insertId.raw)
        XCTAssertEqual(edit.attributeTag, "NAME")
        XCTAssertEqual(edit.oldValue, "UNNAMED")
        XCTAssertEqual(edit.newValue, "STN-4")
        XCTAssertTrue(result.contains("UNNAMED"))
        XCTAssertTrue(result.contains("STN-4"))
    }

    @MainActor
    func testProposeAttributeEditsDoesNotMutateTheStore() throws {
        let (parsed, insertId, _) = makeWorkstationFixture()
        let rc = makeCoordinator(parsed)
        let executor = AIToolExecutor(regen: rc, visibility: VisibilityState())
        let editJSON = "{\"insertEntityId\":\(insertId.raw),\"attributeTag\":\"NAME\",\"newValue\":\"STN-4\"}"
        _ = try executor.execute(tool: "propose_attribute_edits", arguments: ["edits": [editJSON]])

        // The tool call must be side-effect-free on the document — only
        // `AIProposedEditApplier.apply` (a separate, user-triggered step)
        // may actually write to the store.
        let attrs = BlockEditor.attributes(of: insertId, in: rc.parsed.store)
        XCTAssertEqual(attrs.first { $0.tag == "NAME" }?.value, "UNNAMED")
    }

    @MainActor
    func testExecuteThrowsForUnknownTool() {
        let (parsed, _, _) = makeWorkstationFixture()
        let rc = makeCoordinator(parsed)
        let executor = AIToolExecutor(regen: rc, visibility: VisibilityState())
        XCTAssertThrowsError(try executor.execute(tool: "delete_everything", arguments: [:])) { error in
            XCTAssertTrue(error is AIToolError)
        }
    }

    // MARK: - AIProposedEditApplier (the real, user-triggered write path)

    @MainActor
    func testApplierWritesTheAttributeValueAsOneUndoableTransaction() throws {
        let (parsed, insertId, _) = makeWorkstationFixture()
        let rc = makeCoordinator(parsed)
        let session = DocumentSession()
        session.regen = rc

        let edit = AIProposedEdit(insertEntityId: insertId.raw, attributeTag: "NAME",
                                  oldValue: "UNNAMED", newValue: "STN-4")
        let applied = AIProposedEditApplier.apply([edit], session: session, regen: rc)

        XCTAssertEqual(applied, 1)
        let attrs = BlockEditor.attributes(of: insertId, in: rc.parsed.store)
        XCTAssertEqual(attrs.first { $0.tag == "NAME" }?.value, "STN-4")
        XCTAssertTrue(session.canUndo)

        session.undo()
        let attrsAfterUndo = BlockEditor.attributes(of: insertId, in: rc.parsed.store)
        XCTAssertEqual(attrsAfterUndo.first { $0.tag == "NAME" }?.value, "UNNAMED")
    }

    @MainActor
    func testApplierBatchesMultipleEditsIntoOneUndoStep() throws {
        let (parsed, insertId, _) = makeWorkstationFixture()
        let rc = makeCoordinator(parsed)
        let session = DocumentSession()
        session.regen = rc

        // A second workstation, so the batch spans two distinct INSERTs.
        var secondInsertId: EntityID!
        rc.parsed.document.transact("Insert 2nd") { tx in
            secondInsertId = BlockEditor.insert(blockName: "WORKSTATION", at: CGPoint(x: 300, y: 400),
                                                layerId: 0, in: parsed, tx: tx)
        }
        rc.apply(rc.parsed.document.undoStack.last!.ops)

        let edits = [
            AIProposedEdit(insertEntityId: insertId.raw, attributeTag: "NAME", oldValue: "UNNAMED", newValue: "STN-4"),
            AIProposedEdit(insertEntityId: secondInsertId.raw, attributeTag: "NAME", oldValue: "UNNAMED", newValue: "STN-9")
        ]
        let undoCountBefore = rc.parsed.document.undoStack.count
        let applied = AIProposedEditApplier.apply(edits, session: session, regen: rc)

        XCTAssertEqual(applied, 2)
        XCTAssertEqual(rc.parsed.document.undoStack.count, undoCountBefore + 1,
                      "the whole batch must be ONE undo step, not one per edit")

        session.undo()
        XCTAssertEqual(BlockEditor.attributes(of: insertId, in: rc.parsed.store).first { $0.tag == "NAME" }?.value, "UNNAMED")
        XCTAssertEqual(BlockEditor.attributes(of: secondInsertId, in: rc.parsed.store).first { $0.tag == "NAME" }?.value, "UNNAMED")
    }

    @MainActor
    func testApplierSkipsAnEditWhoseTargetNoLongerResolves() throws {
        let (parsed, _, _) = makeWorkstationFixture()
        let rc = makeCoordinator(parsed)
        let session = DocumentSession()
        session.regen = rc

        let bogusEdit = AIProposedEdit(insertEntityId: 99_999, attributeTag: "NAME", oldValue: nil, newValue: "X")
        let applied = AIProposedEditApplier.apply([bogusEdit], session: session, regen: rc)
        XCTAssertEqual(applied, 0)
    }

    // MARK: - BlockEditor.setOrCreateAttribute — the primitive behind bulk
    // attribute creation, per the user's request to be able to "add an
    // attribute called 'x' and give it a value equal to 'y' ... on all
    // objects on layer 'z'." Plain `setAttribute` only updates an EXISTING
    // tag (matching real ATTEDIT); this is the create-or-update variant that
    // makes "give every object a tag it doesn't have yet" possible at all.

    @MainActor
    func testSetOrCreateAttributeUpdatesAnExistingTag() throws {
        let (parsed, insertId, _) = makeWorkstationFixture()
        parsed.document.transact("Set") { tx in
            let result = BlockEditor.setOrCreateAttribute(insertId, tag: "NAME", value: "STN-4",
                                                          in: parsed, tx: tx)
            XCTAssertEqual(result, .updated)
        }
        XCTAssertEqual(BlockEditor.attributes(of: insertId, in: parsed.store).first { $0.tag == "NAME" }?.value, "STN-4")
    }

    @MainActor
    func testSetOrCreateAttributeCreatesABrandNewTag() throws {
        let (parsed, insertId, _) = makeWorkstationFixture()
        XCTAssertNil(BlockEditor.attributes(of: insertId, in: parsed.store).first { $0.tag == "ROUTE" },
                    "sanity: this INSERT has no ROUTE tag yet")
        parsed.document.transact("Add") { tx in
            let result = BlockEditor.setOrCreateAttribute(insertId, tag: "ROUTE", value: "R-7",
                                                          in: parsed, tx: tx)
            XCTAssertEqual(result, .created)
        }
        let attrs = BlockEditor.attributes(of: insertId, in: parsed.store)
        XCTAssertEqual(attrs.first { $0.tag == "ROUTE" }?.value, "R-7")
        XCTAssertEqual(attrs.first { $0.tag == "NAME" }?.value, "UNNAMED",
                      "creating a new tag must not disturb the existing one")
    }

    @MainActor
    func testSetOrCreateAttributeReportsUnchangedWhenTheValueAlreadyMatches() throws {
        let (parsed, insertId, _) = makeWorkstationFixture()
        parsed.document.transact("No-op") { tx in
            let result = BlockEditor.setOrCreateAttribute(insertId, tag: "NAME", value: "UNNAMED",
                                                          in: parsed, tx: tx)
            XCTAssertEqual(result, .unchanged)
        }
    }

    @MainActor
    func testSetOrCreateAttributeCreatedTagIsInvisibleByDefault() throws {
        // Bulk metadata tags (BOM/routing/material fields) are routinely
        // authored invisible in real DXFs — see AGENTS.md invariant #2. A
        // freshly created attribute defaults invisible so tagging a whole
        // layer with new metadata doesn't visually clutter the drawing with a
        // new label on every object; the value remains fully data-extractable
        // regardless (invariant #2's whole point).
        let (parsed, insertId, _) = makeWorkstationFixture()
        var newAttribId: EntityID?
        parsed.document.transact("Add") { tx in
            _ = BlockEditor.setOrCreateAttribute(insertId, tag: "ROUTE", value: "R-7", in: parsed, tx: tx)
        }
        for childId in parsed.store.children(of: insertId) {
            guard let h = parsed.store.header(childId), h.type == .attrib, h.payload >= 0,
                  parsed.store.texts[Int(h.payload)].tagStringId >= 0,
                  parsed.store.strings.string(for: parsed.store.texts[Int(h.payload)].tagStringId) == "ROUTE"
            else { continue }
            newAttribId = childId
        }
        let h = try XCTUnwrap(parsed.store.header(try XCTUnwrap(newAttribId)))
        XCTAssertTrue(h.flags.contains(.invisible))
    }

    @MainActor
    func testSetOrCreateAttributeIsUndoable() throws {
        let (parsed, insertId, _) = makeWorkstationFixture()
        let before = parsed.document.undoStack.count
        parsed.document.transact("Add") { tx in
            _ = BlockEditor.setOrCreateAttribute(insertId, tag: "ROUTE", value: "R-7", in: parsed, tx: tx)
        }
        XCTAssertEqual(parsed.document.undoStack.count, before + 1)
        parsed.document.undo()
        XCTAssertNil(BlockEditor.attributes(of: insertId, in: parsed.store).first { $0.tag == "ROUTE" })
    }

    @MainActor
    func testSetOrCreateAttributeReturnsNilForANonInsert() throws {
        let (parsed, _, labelId) = makeWorkstationFixture()
        parsed.document.transact("Try") { tx in
            let result = BlockEditor.setOrCreateAttribute(labelId, tag: "X", value: "Y", in: parsed, tx: tx)
            XCTAssertNil(result)
        }
    }

    // MARK: - AIProposedEditApplier: willCreate honored correctly

    @MainActor
    func testApplierCreatesANewAttributeWhenWillCreateIsSet() throws {
        let (parsed, insertId, _) = makeWorkstationFixture()
        let rc = makeCoordinator(parsed)
        let session = DocumentSession()
        session.regen = rc

        let edit = AIProposedEdit(insertEntityId: insertId.raw, attributeTag: "ROUTE",
                                  oldValue: nil, newValue: "R-7", willCreate: true)
        let applied = AIProposedEditApplier.apply([edit], session: session, regen: rc)
        XCTAssertEqual(applied, 1)
        XCTAssertEqual(BlockEditor.attributes(of: insertId, in: rc.parsed.store).first { $0.tag == "ROUTE" }?.value, "R-7")
    }

    // MARK: - bulk_set_attribute_on_layer

    /// Two WORKSTATION inserts on layer 0 (from `makeWorkstationFixture`) plus
    /// a third insert this helper adds on a DIFFERENT layer, so bulk tests can
    /// assert the layer scoping is real.
    private func makeBulkFixture() -> (parsed: EditableParsedDocument, layer0Ids: [EntityID], otherLayerId: EntityID) {
        let (parsed, firstId, _) = makeWorkstationFixture()
        var secondId: EntityID!
        var otherLayerInsertId: EntityID!
        parsed.layers.append(DXFLayer(id: 2, name: "OTHER"))
        parsed.layerIdByName["OTHER"] = 2
        parsed.document.transact("Insert more") { tx in
            secondId = BlockEditor.insert(blockName: "WORKSTATION", at: CGPoint(x: 300, y: 400),
                                          layerId: 0, in: parsed, tx: tx)
            otherLayerInsertId = BlockEditor.insert(blockName: "WORKSTATION", at: CGPoint(x: 500, y: 600),
                                                    layerId: 2, in: parsed, tx: tx)
        }
        return (parsed, [firstId, secondId], otherLayerInsertId)
    }

    @MainActor
    func testBulkSetAttributeOnLayerStagesEveryInsertOnThatLayerOnly() throws {
        let (parsed, layer0Ids, otherLayerId) = makeBulkFixture()
        let rc = makeCoordinator(parsed)
        let executor = AIToolExecutor(regen: rc, visibility: VisibilityState())
        let result = try executor.execute(tool: "bulk_set_attribute_on_layer",
                                          arguments: ["layerName": "0", "attributeTag": "ROUTE", "value": "R-7"])

        XCTAssertEqual(executor.stagedEdits.count, 2, "only the two INSERTs on layer '0' must be staged")
        let targetedIds = Set(executor.stagedEdits.map(\.insertEntityId))
        XCTAssertEqual(targetedIds, Set(layer0Ids.map(\.raw)))
        XCTAssertFalse(targetedIds.contains(otherLayerId.raw), "the OTHER-layer insert must not be touched")
        XCTAssertTrue(executor.stagedEdits.allSatisfy { $0.willCreate },
                     "none of these inserts has a ROUTE tag yet — every staged edit must be a creation")
        XCTAssertTrue(result.contains("2"))
    }

    @MainActor
    func testBulkSetAttributeOnLayerDoesNotMutateTheStore() throws {
        let (parsed, layer0Ids, _) = makeBulkFixture()
        let rc = makeCoordinator(parsed)
        let executor = AIToolExecutor(regen: rc, visibility: VisibilityState())
        _ = try executor.execute(tool: "bulk_set_attribute_on_layer",
                                 arguments: ["layerName": "0", "attributeTag": "ROUTE", "value": "R-7"])
        for id in layer0Ids {
            XCTAssertNil(BlockEditor.attributes(of: id, in: rc.parsed.store).first { $0.tag == "ROUTE" },
                        "staging must never write to the store — only Apply may")
        }
    }

    @MainActor
    func testBulkSetAttributeOnLayerReportsExistingVsNewCorrectly() throws {
        let (parsed, layer0Ids, _) = makeBulkFixture()
        // Give the FIRST insert a ROUTE value already; the second has none.
        parsed.document.transact("Pre-set") { tx in
            _ = BlockEditor.setOrCreateAttribute(layer0Ids[0], tag: "ROUTE", value: "OLD", in: parsed, tx: tx)
        }
        let rc = makeCoordinator(parsed)
        let executor = AIToolExecutor(regen: rc, visibility: VisibilityState())
        _ = try executor.execute(tool: "bulk_set_attribute_on_layer",
                                 arguments: ["layerName": "0", "attributeTag": "ROUTE", "value": "R-7"])
        let byId = Dictionary(uniqueKeysWithValues: executor.stagedEdits.map { ($0.insertEntityId, $0) })
        XCTAssertEqual(byId[layer0Ids[0].raw]?.willCreate, false, "already had the tag -> update, not create")
        XCTAssertEqual(byId[layer0Ids[0].raw]?.oldValue, "OLD")
        XCTAssertEqual(byId[layer0Ids[1].raw]?.willCreate, true, "no tag yet -> create")
    }

    @MainActor
    func testBulkSetAttributeOnLayerSkipsObjectsAlreadyAtTheTargetValue() throws {
        let (parsed, layer0Ids, _) = makeBulkFixture()
        parsed.document.transact("Pre-set") { tx in
            _ = BlockEditor.setOrCreateAttribute(layer0Ids[0], tag: "ROUTE", value: "R-7", in: parsed, tx: tx)
        }
        let rc = makeCoordinator(parsed)
        let executor = AIToolExecutor(regen: rc, visibility: VisibilityState())
        let result = try executor.execute(tool: "bulk_set_attribute_on_layer",
                                          arguments: ["layerName": "0", "attributeTag": "ROUTE", "value": "R-7"])
        XCTAssertEqual(executor.stagedEdits.count, 1, "the object already at R-7 must be skipped, not restaged as a no-op")
        XCTAssertEqual(executor.stagedEdits.first?.insertEntityId, layer0Ids[1].raw)
        XCTAssertTrue(result.contains("1 object"))
    }

    @MainActor
    func testBulkSetAttributeOnLayerReportsNoMatchesForAnUnknownLayer() throws {
        let (parsed, _, _) = makeBulkFixture()
        let rc = makeCoordinator(parsed)
        let executor = AIToolExecutor(regen: rc, visibility: VisibilityState())
        let result = try executor.execute(tool: "bulk_set_attribute_on_layer",
                                          arguments: ["layerName": "NO-SUCH-LAYER", "attributeTag": "ROUTE", "value": "R-7"])
        XCTAssertTrue(result.contains("No block references"))
        XCTAssertTrue(executor.stagedEdits.isEmpty)
    }

    @MainActor
    func testBulkSetAttributeOnLayerRespectsHiddenLayerVisibility() throws {
        let (parsed, layer0Ids, _) = makeBulkFixture()
        var visibility = VisibilityState()
        visibility.hiddenLayerIds = [0]
        let rc = makeCoordinator(parsed)
        let executor = AIToolExecutor(regen: rc, visibility: visibility)
        let result = try executor.execute(tool: "bulk_set_attribute_on_layer",
                                          arguments: ["layerName": "0", "attributeTag": "ROUTE", "value": "R-7"])
        XCTAssertTrue(executor.stagedEdits.isEmpty, "a hidden layer's objects must be invisible to the bulk tool too")
        XCTAssertTrue(result.contains("No block references"))
        _ = layer0Ids
    }

    @MainActor
    func testApplyingABulkStagedPlanCreatesAndUpdatesCorrectly() throws {
        let (parsed, layer0Ids, _) = makeBulkFixture()
        parsed.document.transact("Pre-set") { tx in
            _ = BlockEditor.setOrCreateAttribute(layer0Ids[0], tag: "ROUTE", value: "OLD", in: parsed, tx: tx)
        }
        let rc = makeCoordinator(parsed)
        let session = DocumentSession()
        session.regen = rc
        let executor = AIToolExecutor(regen: rc, visibility: VisibilityState())
        _ = try executor.execute(tool: "bulk_set_attribute_on_layer",
                                 arguments: ["layerName": "0", "attributeTag": "ROUTE", "value": "R-7"])

        let applied = AIProposedEditApplier.apply(executor.stagedEdits, session: session, regen: rc)
        XCTAssertEqual(applied, 2)
        XCTAssertEqual(BlockEditor.attributes(of: layer0Ids[0], in: rc.parsed.store).first { $0.tag == "ROUTE" }?.value, "R-7")
        XCTAssertEqual(BlockEditor.attributes(of: layer0Ids[1], in: rc.parsed.store).first { $0.tag == "ROUTE" }?.value, "R-7")
    }

    // MARK: - AIConfig persistence

    func testAIConfigSaveAndLoadRoundTrips() throws {
        AIConfig.clear()
        defer { AIConfig.clear() }
        let config = AIConfig.anthropicDefaults(apiKey: "test-key-123")
        config.save()
        let loaded = try XCTUnwrap(AIConfig.load())
        XCTAssertEqual(loaded, config)
    }

    func testAIConfigClearRemovesPersistedValue() throws {
        AIConfig.anthropicDefaults(apiKey: "x").save()
        AIConfig.clear()
        XCTAssertNil(AIConfig.load())
    }

    func testOnlyAnthropicSupportsTools() {
        XCTAssertTrue(AIConfig.Provider.anthropic.supportsTools)
        XCTAssertFalse(AIConfig.Provider.openAICompatible.supportsTools)
        XCTAssertFalse(AIConfig.Provider.opencode.supportsTools)
    }

    // MARK: - Transcript reconciliation ("the AI Assistant is repeating itself")
    //
    // `.completed` carries the turn's FULL final text, while `.textDelta` has
    // usually ALREADY streamed that same text into the trailing assistant
    // bubble. Appending `.completed` unconditionally therefore rendered the
    // entire reply twice — a duplicated-reply bug that looks like the model
    // repeating itself but is purely this event pair being additive. Both
    // events must stay handled (some backends/fallback paths emit only
    // `.completed`), so the two are reconciled instead.

    @MainActor
    func testCompletedAfterStreamingTheSameTextDoesNotDuplicateTheReply() {
        let session = AIAssistantSession()
        session.apply(.textDelta("The drawing has "))
        session.apply(.textDelta("42 layers."))
        session.apply(.completed("The drawing has 42 layers."))
        XCTAssertEqual(session.history.count, 1, "the streamed reply must NOT be appended a second time")
        XCTAssertEqual(session.history[0].text, "The drawing has 42 layers.")
    }

    @MainActor
    func testCompletedWithNoPriorStreamingBecomesTheReply() {
        // The non-streaming path (e.g. AIClient's plain Anthropic completion,
        // or an OpenCode fallback that refetched the message server-side).
        let session = AIAssistantSession()
        session.apply(.completed("Only the final text arrived."))
        XCTAssertEqual(session.history.count, 1)
        XCTAssertEqual(session.history[0].text, "Only the final text arrived.")
    }

    @MainActor
    func testCompletedSupersedesATruncatedStream() {
        // A stream cut short then completed by a server-side refetch: the user
        // must end up with the WHOLE reply exactly once, not a truncated copy
        // followed by a complete one.
        let session = AIAssistantSession()
        session.apply(.textDelta("Staged 42 ribbons"))
        session.apply(.completed("Staged 42 ribbons on AISLE-SHADED."))
        XCTAssertEqual(session.history.count, 1)
        XCTAssertEqual(session.history[0].text, "Staged 42 ribbons on AISLE-SHADED.")
    }

    @MainActor
    func testCompletedKeepsTheLongerTextWhenStreamOverran() {
        // Inverse of the above: whichever is longer wins, so a shorter
        // `.completed` never truncates what the user already saw.
        let session = AIAssistantSession()
        session.apply(.textDelta("Staged 42 ribbons on AISLE-SHADED."))
        session.apply(.completed("Staged 42 ribbons"))
        XCTAssertEqual(session.history.count, 1)
        XCTAssertEqual(session.history[0].text, "Staged 42 ribbons on AISLE-SHADED.")
    }

    @MainActor
    func testGenuinelyDifferentCompletedTextIsAppendedAsItsOwnBubble() {
        // A real second paragraph (e.g. the model's follow-up after a tool
        // call) must still appear — de-duplication must not swallow new prose.
        let session = AIAssistantSession()
        session.apply(.textDelta("Let me check the layers."))
        session.apply(.completed("There are 42 layers, 3 of them empty."))
        XCTAssertEqual(session.history.count, 2)
        XCTAssertEqual(session.history[1].text, "There are 42 layers, 3 of them empty.")
    }

    @MainActor
    func testEmptyCompletedIsIgnored() {
        let session = AIAssistantSession()
        session.apply(.textDelta("Answer."))
        session.apply(.completed("   "))
        XCTAssertEqual(session.history.count, 1)
        XCTAssertEqual(session.history[0].text, "Answer.")
    }

    @MainActor
    func testStreamingDeltasCoalesceIntoOneBubbleButANewBubbleStartsAfterAToolCall() {
        // Pre-existing behavior, locked in here because the `.completed`
        // reconciliation above depends on `history.last?.role` still flipping
        // away from `.assistant` when a tool call interrupts the stream.
        let session = AIAssistantSession()
        session.apply(.textDelta("Checking"))
        session.apply(.textDelta(" the drawing."))
        XCTAssertEqual(session.history.count, 1)
        session.apply(.toolCall(AIToolCallEvent(id: "t1", name: "read_drawing",
                                               argumentSummary: "", status: .completed,
                                               resultSummary: "ok")))
        session.apply(.textDelta("Found 42 layers."))
        XCTAssertEqual(session.history.count, 3, "a tool call must break the stream into a new bubble")
        XCTAssertEqual(session.history[2].text, "Found 42 layers.")
    }

    @MainActor
    func testToolCallRowsUpsertRatherThanDuplicating() {
        // A running -> completed transition for the SAME tool id must replace
        // the existing timeline row, not append a second one (another shape of
        // visible "repetition" in the transcript).
        let session = AIAssistantSession()
        session.apply(.toolCall(AIToolCallEvent(id: "t1", name: "shade_aisle_network",
                                               argumentSummary: "layerName: AISLE",
                                               status: .running, resultSummary: nil)))
        session.apply(.toolCall(AIToolCallEvent(id: "t1", name: "shade_aisle_network",
                                               argumentSummary: "layerName: AISLE",
                                               status: .completed, resultSummary: "Staged 42")))
        XCTAssertEqual(session.history.count, 1)
        XCTAssertEqual(session.history[0].toolCall?.status, .completed)
    }
}
