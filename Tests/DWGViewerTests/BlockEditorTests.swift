import XCTest
@testable import DWGViewer
import CADCore

/// Phase 6.1: BlockEditor unit tests. Uses hand-constructed
/// `EditableParsedDocument`s (no file I/O) — the same minimal-setup pattern
/// `RoundTripTests` uses for its own from-scratch `EditableParsedDocument`
/// construction (a real LAYER 0/CONTINUOUS linetype registered so
/// PropertyResolver/layer lookups behave exactly as they would against a
/// real parsed file).
final class BlockEditorTests: XCTestCase {

    private func makeParsed() -> EditableParsedDocument {
        let parsed = EditableParsedDocument()
        parsed.layers.append(DXFLayer(id: 0, name: "0"))
        parsed.layerIdByName["0"] = 0
        parsed.layers.append(DXFLayer(id: 1, name: "SYMBOLS"))
        parsed.layerIdByName["SYMBOLS"] = 1
        parsed.linetypes.append(DXFLinetype(name: "CONTINUOUS", dashes: []))
        parsed.linetypeIdByName["CONTINUOUS"] = 0
        return parsed
    }

    private func lineProto(_ a: Vec3, _ b: Vec3, layerId: Int32 = 0, owner: OwnerRef = .model) -> EntityPrototype {
        EntityPrototype(type: .line, layerId: layerId, owner: owner, payload: .line(LinePayload(a: a, b: b)))
    }

    private func circleProto(_ center: Vec3, _ radius: Double, layerId: Int32 = 0, owner: OwnerRef = .model) -> EntityPrototype {
        EntityPrototype(type: .circle, layerId: layerId, owner: owner, payload: .circle(CirclePayload(center: center, radius: radius)))
    }

    // MARK: - createBlock

    func testCreateBlockRebasesEntitiesAndSubstitutesOneInsert() throws {
        let parsed = makeParsed()
        let doc = parsed.document
        var lineId: EntityID!, circleId: EntityID!
        doc.transact("Draw") { tx in
            lineId = tx.add(self.lineProto(Vec3(x: 100, y: 100), Vec3(x: 110, y: 100)))
            circleId = tx.add(self.circleProto(Vec3(x: 105, y: 105), 3))
        }

        var result: BlockEditor.CreateBlockResult?
        doc.transact("Block") { tx in
            result = BlockEditor.createBlock(name: "MYBLOCK", basePoint: CGPoint(x: 100, y: 100),
                                             from: [lineId, circleId], insertLayerId: 0,
                                             in: parsed, tx: tx)
        }
        let r = try XCTUnwrap(result)

        // Block registered with the right index/entity count.
        let block = try XCTUnwrap(parsed.blocks["MYBLOCK"])
        XCTAssertEqual(block.blockIndex, r.blockIndex)
        XCTAssertEqual(block.entityCount, 2)

        // Original entities are gone (tombstoned by tx.replace's delete).
        XCTAssertTrue(doc.store.isDeleted(lineId))
        XCTAssertTrue(doc.store.isDeleted(circleId))

        // New block-owned entities exist, rebased to the block-local origin
        // (basePoint subtracted): line (100,100)-(110,100) -> (0,0)-(10,0);
        // circle center (105,105) -> (5,5), radius unchanged.
        var foundLine = false, foundCircle = false
        for i in Int(block.entityStart)..<Int(block.entityStart + block.entityCount) {
            let id = EntityID(raw: Int32(i))
            let h = try XCTUnwrap(doc.store.header(id))
            XCTAssertEqual(h.owner, OwnerRef.block(block.blockIndex))
            if h.type == .line {
                let l = doc.store.lines[Int(h.payload)]
                XCTAssertEqual(l.a, Vec3(x: 0, y: 0))
                XCTAssertEqual(l.b, Vec3(x: 10, y: 0))
                foundLine = true
            } else if h.type == .circle {
                let c = doc.store.circles[Int(h.payload)]
                XCTAssertEqual(c.center, Vec3(x: 5, y: 5))
                XCTAssertEqual(c.radius, 3)
                foundCircle = true
            }
        }
        XCTAssertTrue(foundLine && foundCircle)

        // The substituted INSERT sits at the original world position (basePoint).
        let insertHeader = try XCTUnwrap(doc.store.header(r.insertId))
        XCTAssertEqual(insertHeader.type, .insert)
        let ip = doc.store.inserts[Int(insertHeader.payload)]
        XCTAssertEqual(ip.position, Vec3(x: 100, y: 100))
        XCTAssertEqual(doc.store.strings.string(for: ip.blockNameId), "MYBLOCK")
    }

    func testCreateBlockRoundTripsGeometryThroughRegenerator() throws {
        // Cross-check per the plan's own gate wording: the substituted
        // INSERT, once expanded by Regenerator, must reproduce EXACTLY the
        // original world-space geometry that was blockified — proves
        // createBlock's rebasing + the substituted insert's position
        // together form a correct, lossless round-trip.
        let parsed = makeParsed()
        let doc = parsed.document
        var lineId: EntityID!
        doc.transact("Draw") { tx in
            lineId = tx.add(self.lineProto(Vec3(x: 50, y: 20), Vec3(x: 70, y: 40)))
        }
        doc.transact("Block") { tx in
            _ = BlockEditor.createBlock(name: "B1", basePoint: CGPoint(x: 50, y: 20),
                                        from: [lineId], insertLayerId: 0, in: parsed, tx: tx)
        }

        let built = Regenerator.build(from: parsed, parseSeconds: 0) { _ in }
        // Find the expanded line primitive and confirm its world coordinates
        // match the ORIGINAL (pre-block) line exactly.
        var foundMatchingRun = false
        for g in built.modelGroups {
            for run in g.strokes.runs where run.kind == .line {
                let a = g.strokes.points[Int(run.start)]
                let b = g.strokes.points[Int(run.start) + 1]
                if (abs(a.x - 50) < 1e-9 && abs(a.y - 20) < 1e-9 && abs(b.x - 70) < 1e-9 && abs(b.y - 40) < 1e-9) ||
                   (abs(b.x - 50) < 1e-9 && abs(b.y - 20) < 1e-9 && abs(a.x - 70) < 1e-9 && abs(a.y - 40) < 1e-9) {
                    foundMatchingRun = true
                }
            }
        }
        XCTAssertTrue(foundMatchingRun, "the blockified line must render at exactly its original world position")
    }

    func testCreateBlockUndoRestoresAllMovedEntities() throws {
        // BLOCK creation moves MULTIPLE entities in one transaction — undo
        // must restore ALL of them, not just one (the adversarial-review
        // concern the brief calls out explicitly).
        let parsed = makeParsed()
        let doc = parsed.document
        var lineId: EntityID!, circleId: EntityID!
        doc.transact("Draw") { tx in
            lineId = tx.add(self.lineProto(Vec3(x: 100, y: 100), Vec3(x: 110, y: 100)))
            circleId = tx.add(self.circleProto(Vec3(x: 105, y: 105), 3))
        }
        doc.transact("Block") { tx in
            _ = BlockEditor.createBlock(name: "MYBLOCK", basePoint: CGPoint(x: 100, y: 100),
                                        from: [lineId, circleId], insertLayerId: 0, in: parsed, tx: tx)
        }
        XCTAssertTrue(doc.store.isDeleted(lineId))
        XCTAssertTrue(doc.store.isDeleted(circleId))

        doc.undo()

        XCTAssertFalse(doc.store.isDeleted(lineId), "undo must restore the LINE")
        XCTAssertFalse(doc.store.isDeleted(circleId), "undo must restore the CIRCLE")
        let lh = try XCTUnwrap(doc.store.header(lineId))
        let l = doc.store.lines[Int(lh.payload)]
        XCTAssertEqual(l.a, Vec3(x: 100, y: 100), "restored line must be back at its ORIGINAL (pre-block) position")
        let ch = try XCTUnwrap(doc.store.header(circleId))
        let c = doc.store.circles[Int(ch.payload)]
        XCTAssertEqual(c.center, Vec3(x: 105, y: 105))

        // The new block-owned entities and the substituted insert must be
        // gone again after undo.
        var liveBlockOwnedCount = 0
        for h in doc.store.headers where h.owner == OwnerRef.block(0) && !h.flags.contains(.deleted) {
            liveBlockOwnedCount += 1
        }
        XCTAssertEqual(liveBlockOwnedCount, 0, "undo must also remove the entities that were added into the block definition")
    }

    func testCreateBlockRejectsEmptySelection() {
        let parsed = makeParsed()
        let doc = parsed.document
        var result: BlockEditor.CreateBlockResult??
        doc.transact("Block") { tx in
            result = BlockEditor.createBlock(name: "EMPTY", basePoint: .zero, from: [],
                                             insertLayerId: 0, in: parsed, tx: tx)
        }
        XCTAssertNil(result ?? nil)
        XCTAssertNil(parsed.blocks["EMPTY"])
    }

    func testCreateBlockRejectsDuplicateName() throws {
        let parsed = makeParsed()
        let doc = parsed.document
        var lineId: EntityID!
        doc.transact("Draw") { tx in
            lineId = tx.add(self.lineProto(Vec3(x: 0, y: 0), Vec3(x: 1, y: 1)))
        }
        doc.transact("Block") { tx in
            _ = BlockEditor.createBlock(name: "DUP", basePoint: .zero, from: [lineId], insertLayerId: 0, in: parsed, tx: tx)
        }
        var lineId2: EntityID!
        doc.transact("Draw") { tx in
            lineId2 = tx.add(self.lineProto(Vec3(x: 5, y: 5), Vec3(x: 6, y: 6)))
        }
        var secondResult: BlockEditor.CreateBlockResult?
        doc.transact("Block2") { tx in
            secondResult = BlockEditor.createBlock(name: "DUP", basePoint: .zero, from: [lineId2],
                                                   insertLayerId: 0, in: parsed, tx: tx)
        }
        XCTAssertNil(secondResult, "creating a block with an already-used name must fail")
        XCTAssertFalse(doc.store.isDeleted(lineId2), "the rejected call must not have touched the second line")
    }

    /// Adversarial-review regression: `EditableBlockDef`/`parsed.blocks`
    /// live entirely outside `EntityStore`/`Transaction`'s own undo system
    /// — undoing a `createBlock` must remove the dangling block-definition
    /// dictionary entry too, not just restore the relocated entities.
    /// Without the fix, `parsed.blocks["UNDOME"]` would still exist after
    /// undo, pointing at a range of now-entirely-tombstoned entities, and a
    /// subsequent `insert(blockName: "UNDOME", ...)` would wrongly succeed
    /// against that stale definition.
    func testCreateBlockUndoRemovesBlockDefinitionEntry() throws {
        let parsed = makeParsed()
        let doc = parsed.document
        var lineId: EntityID!
        doc.transact("Draw") { tx in
            lineId = tx.add(self.lineProto(Vec3(x: 0, y: 0), Vec3(x: 1, y: 1)))
        }
        doc.transact("Block") { tx in
            _ = BlockEditor.createBlock(name: "UNDOME", basePoint: .zero, from: [lineId], insertLayerId: 0, in: parsed, tx: tx)
        }
        XCTAssertNotNil(parsed.blocks["UNDOME"])

        doc.undo()

        XCTAssertNil(parsed.blocks["UNDOME"], "undo must remove the dangling block definition entry")

        // A subsequent createBlock with the SAME name must succeed (proves
        // the name is genuinely free again, not just cosmetically absent).
        var lineId2: EntityID!
        doc.transact("Draw again") { tx in
            lineId2 = tx.add(self.lineProto(Vec3(x: 10, y: 10), Vec3(x: 11, y: 11)))
        }
        var secondResult: BlockEditor.CreateBlockResult?
        doc.transact("Block again") { tx in
            secondResult = BlockEditor.createBlock(name: "UNDOME", basePoint: .zero, from: [lineId2], insertLayerId: 0, in: parsed, tx: tx)
        }
        XCTAssertNotNil(secondResult, "the block name must be reusable after undo")
    }

    /// Redo must restore the block definition entry exactly as it was
    /// before undo.
    func testCreateBlockRedoRestoresBlockDefinitionEntry() throws {
        let parsed = makeParsed()
        let doc = parsed.document
        var lineId: EntityID!
        doc.transact("Draw") { tx in
            lineId = tx.add(self.lineProto(Vec3(x: 0, y: 0), Vec3(x: 1, y: 1)))
        }
        var result: BlockEditor.CreateBlockResult?
        doc.transact("Block") { tx in
            result = BlockEditor.createBlock(name: "REDOME", basePoint: .zero, from: [lineId], insertLayerId: 0, in: parsed, tx: tx)
        }
        let expectedIndex = try XCTUnwrap(result?.blockIndex)

        doc.undo()
        XCTAssertNil(parsed.blocks["REDOME"])

        doc.redo()
        let restored = try XCTUnwrap(parsed.blocks["REDOME"])
        XCTAssertEqual(restored.blockIndex, expectedIndex)
        XCTAssertEqual(restored.entityCount, 1)
    }

    /// Adversarial-review regression: `redefineBlock`'s `entityStart`/
    /// `entityCount` mutation must be undoable, restoring the block
    /// definition's metadata to point at the ORIGINAL (pre-redefinition)
    /// entity range, not leave it pointing at the new (now-deleted-by-undo)
    /// range.
    func testRedefineBlockUndoRestoresOriginalEntityRange() throws {
        let parsed = makeParsed()
        let doc = parsed.document
        var lineId: EntityID!
        doc.transact("Draw") { tx in
            lineId = tx.add(self.lineProto(Vec3(x: 0, y: 0), Vec3(x: 1, y: 0)))
        }
        var blockResult: BlockEditor.CreateBlockResult?
        doc.transact("Block") { tx in
            blockResult = BlockEditor.createBlock(name: "RB2", basePoint: .zero, from: [lineId],
                                                  insertLayerId: 0, in: parsed, tx: tx)
        }
        _ = try XCTUnwrap(blockResult)
        let originalStart = parsed.blocks["RB2"]!.entityStart
        let originalCount = parsed.blocks["RB2"]!.entityCount

        let regen = RegenCoordinator(parsed: parsed, document: Regenerator.build(from: parsed, parseSeconds: 0) { _ in })
        doc.transact("Redefine") { tx in
            _ = BlockEditor.redefineBlock(name: "RB2", with: [self.circleProto(Vec3(x: 2, y: 2), 5)],
                                          in: parsed, tx: tx, regen: regen)
        }
        XCTAssertNotEqual(parsed.blocks["RB2"]!.entityStart, originalStart)

        doc.undo()

        XCTAssertEqual(parsed.blocks["RB2"]!.entityStart, originalStart, "undo must restore the ORIGINAL entityStart")
        XCTAssertEqual(parsed.blocks["RB2"]!.entityCount, originalCount, "undo must restore the ORIGINAL entityCount")
        // The original LINE (not the CIRCLE) must be the live content again.
        for i in Int(parsed.blocks["RB2"]!.entityStart)..<Int(parsed.blocks["RB2"]!.entityStart + parsed.blocks["RB2"]!.entityCount) {
            let h = doc.store.header(EntityID(raw: Int32(i)))
            XCTAssertEqual(h?.type, .line)
            XCTAssertFalse(h?.flags.contains(.deleted) ?? true)
        }
    }

    /// Adversarial-review regression: `createAttdef`'s relocate-to-stay-
    /// contiguous path also mutates `entityStart`/`entityCount` in place —
    /// undo must restore the block's PRE-ATTDEF entity range.
    func testCreateAttdefUndoRestoresOriginalEntityRange() throws {
        let parsed = makeParsed()
        let doc = parsed.document
        var lineId: EntityID!
        doc.transact("Draw") { tx in
            lineId = tx.add(self.lineProto(Vec3(x: 0, y: 0), Vec3(x: 1, y: 0)))
        }
        var blockResult: BlockEditor.CreateBlockResult?
        doc.transact("Block") { tx in
            blockResult = BlockEditor.createBlock(name: "ATTB", basePoint: .zero, from: [lineId],
                                                  insertLayerId: 0, in: parsed, tx: tx)
        }
        _ = try XCTUnwrap(blockResult)
        let originalStart = parsed.blocks["ATTB"]!.entityStart
        let originalCount = parsed.blocks["ATTB"]!.entityCount
        XCTAssertEqual(originalCount, 1)

        doc.transact("Add attdef") { tx in
            _ = BlockEditor.createAttdef(tag: "X", prompt: "", defaultValue: "0",
                                        at: .zero, height: 1, layerId: 0, inBlockNamed: "ATTB", in: parsed, tx: tx)
        }
        XCTAssertEqual(parsed.blocks["ATTB"]!.entityCount, 2)
        XCTAssertNotEqual(parsed.blocks["ATTB"]!.entityStart, originalStart)

        doc.undo()

        XCTAssertEqual(parsed.blocks["ATTB"]!.entityStart, originalStart, "undo must restore the PRE-ATTDEF entityStart")
        XCTAssertEqual(parsed.blocks["ATTB"]!.entityCount, originalCount, "undo must restore the PRE-ATTDEF entityCount (1, not 2)")
        // The block's content must be exactly the original LINE again, no ATTDEF.
        var sawLine = false, sawAttdef = false
        for i in Int(parsed.blocks["ATTB"]!.entityStart)..<Int(parsed.blocks["ATTB"]!.entityStart + parsed.blocks["ATTB"]!.entityCount) {
            let h = doc.store.header(EntityID(raw: Int32(i)))
            if h?.type == .line, h?.flags.contains(.deleted) == false { sawLine = true }
            if h?.type == .attdef, h?.flags.contains(.deleted) == false { sawAttdef = true }
        }
        XCTAssertTrue(sawLine)
        XCTAssertFalse(sawAttdef, "the ATTDEF must not be live in the block's range after undo")
    }

    /// Redo must re-apply createAttdef's block-range change.
    func testCreateAttdefRedoReappliesEntityRange() throws {
        let parsed = makeParsed()
        let doc = parsed.document
        var lineId: EntityID!
        doc.transact("Draw") { tx in
            lineId = tx.add(self.lineProto(Vec3(x: 0, y: 0), Vec3(x: 1, y: 0)))
        }
        var blockResult: BlockEditor.CreateBlockResult?
        doc.transact("Block") { tx in
            blockResult = BlockEditor.createBlock(name: "ATTB2", basePoint: .zero, from: [lineId],
                                                  insertLayerId: 0, in: parsed, tx: tx)
        }
        _ = try XCTUnwrap(blockResult)

        doc.transact("Add attdef") { tx in
            _ = BlockEditor.createAttdef(tag: "X", prompt: "", defaultValue: "0",
                                        at: .zero, height: 1, layerId: 0, inBlockNamed: "ATTB2", in: parsed, tx: tx)
        }
        let afterAddCount = parsed.blocks["ATTB2"]!.entityCount
        XCTAssertEqual(afterAddCount, 2)

        doc.undo()
        XCTAssertEqual(parsed.blocks["ATTB2"]!.entityCount, 1)

        doc.redo()
        XCTAssertEqual(parsed.blocks["ATTB2"]!.entityCount, 2, "redo must restore the post-ATTDEF entityCount")
    }

    // MARK: - insert / ATTDEF / ATTRIB

    /// `createAttdef` requires the block to already exist (mirrors AutoCAD:
    /// ATTDEF is placed INSIDE an already-open block-edit context, never
    /// implicitly creating one) — verified separately by
    /// `testCreateAttdefReturnsNilForUnknownBlock` below. Register an empty
    /// starter block by hand here (this session's `createBlock` always
    /// populates a block FROM existing entities, so an empty starter is the
    /// realistic shape for "define a title-block template from scratch,"
    /// which isn't itself in Phase 6.1's scope — only ATTDEF-into-an-
    /// existing-block is).
    func testInsertCreatesAttribChildPerAttdefWith66Semantics() throws {
        let parsed = makeParsed()
        let doc = parsed.document

        let emptyBlock = EditableBlockDef()
        emptyBlock.name = "TITLEBLK"
        emptyBlock.blockIndex = BlockEditor.nextBlockIndex(in: parsed)
        emptyBlock.entityStart = 0
        emptyBlock.entityCount = 0
        parsed.blocks["TITLEBLK"] = emptyBlock

        var attdefId: EntityID!
        doc.transact("Add attdef") { tx in
            attdefId = BlockEditor.createAttdef(tag: "NAME", prompt: "Enter name", defaultValue: "N/A",
                                                at: CGPoint(x: 1, y: 1), height: 2.5, layerId: 0,
                                                inBlockNamed: "TITLEBLK", in: parsed, tx: tx)
        }
        XCTAssertNotNil(attdefId)
        let block = try XCTUnwrap(parsed.blocks["TITLEBLK"])
        XCTAssertEqual(block.entityCount, 1)

        // Now INSERT it with an explicit attribute value.
        var insertId: EntityID?
        doc.transact("Insert") { tx in
            insertId = BlockEditor.insert(blockName: "TITLEBLK", at: CGPoint(x: 100, y: 200),
                                          layerId: 0, attributeValues: ["NAME": "Ryan"],
                                          in: parsed, tx: tx)
        }
        let iid = try XCTUnwrap(insertId)

        let attrs = BlockEditor.attributes(of: iid, in: doc.store)
        XCTAssertEqual(attrs.count, 1)
        XCTAssertEqual(attrs[0].tag, "NAME")
        XCTAssertEqual(attrs[0].value, "Ryan")

        // Verify owner is .parentEntity(insertId) — the load-bearing linkage
        // `store.children(of:)` depends on.
        let childHeader = try XCTUnwrap(doc.store.header(attrs[0].id))
        XCTAssertEqual(childHeader.owner, OwnerRef.parentEntity(iid))
        XCTAssertEqual(childHeader.type, .attrib)

        // Anchor transformed by the insert matrix: ATTDEF local (1,1) with
        // insert at (100,200), no rotation/scale -> world (101,201).
        let attribPayload = doc.store.texts[Int(childHeader.payload)]
        XCTAssertEqual(attribPayload.position.x, 101, accuracy: 1e-9)
        XCTAssertEqual(attribPayload.position.y, 201, accuracy: 1e-9)
    }

    func testCreateAttdefReturnsNilForUnknownBlock() {
        let parsed = makeParsed()
        let doc = parsed.document
        var attdefId: EntityID?
        doc.transact("Add attdef") { tx in
            attdefId = BlockEditor.createAttdef(tag: "X", prompt: "", defaultValue: "0",
                                                at: .zero, height: 1, layerId: 0,
                                                inBlockNamed: "NOPE", in: parsed, tx: tx)
        }
        XCTAssertNil(attdefId, "createAttdef must not implicitly create a missing block")
    }

    func testInsertUsesAttdefDefaultWhenNoValueSupplied() throws {
        let parsed = makeParsed()
        let doc = parsed.document
        let block = EditableBlockDef()
        block.name = "B"
        block.blockIndex = BlockEditor.nextBlockIndex(in: parsed)
        parsed.blocks["B"] = block
        doc.transact("Add attdef") { tx in
            _ = BlockEditor.createAttdef(tag: "QTY", prompt: "", defaultValue: "1",
                                        at: .zero, height: 1, layerId: 0,
                                        inBlockNamed: "B", in: parsed, tx: tx)
        }
        var insertId: EntityID?
        doc.transact("Insert") { tx in
            insertId = BlockEditor.insert(blockName: "B", at: CGPoint(x: 0, y: 0), layerId: 0, in: parsed, tx: tx)
        }
        let iid = try XCTUnwrap(insertId)
        let attrs = BlockEditor.attributes(of: iid, in: doc.store)
        XCTAssertEqual(attrs.first?.value, "1", "no attributeValues entry for QTY must fall back to the ATTDEF's own default")
    }

    func testInsertAppliesScaleAndRotationToAttribAnchor() throws {
        let parsed = makeParsed()
        let doc = parsed.document
        let block = EditableBlockDef()
        block.name = "R"
        block.blockIndex = BlockEditor.nextBlockIndex(in: parsed)
        parsed.blocks["R"] = block
        doc.transact("Add attdef") { tx in
            _ = BlockEditor.createAttdef(tag: "T", prompt: "", defaultValue: "x",
                                        at: CGPoint(x: 1, y: 0), height: 1, layerId: 0,
                                        inBlockNamed: "R", in: parsed, tx: tx)
        }
        var insertId: EntityID?
        doc.transact("Insert") { tx in
            // 90-degree rotation: local (1,0) -> (0,1); insert at (10,10).
            insertId = BlockEditor.insert(blockName: "R", at: CGPoint(x: 10, y: 10),
                                          rotationDeg: 90, layerId: 0, in: parsed, tx: tx)
        }
        let iid = try XCTUnwrap(insertId)
        let attrs = BlockEditor.attributes(of: iid, in: doc.store)
        let childId = try XCTUnwrap(attrs.first?.id)
        let h = try XCTUnwrap(doc.store.header(childId))
        let p = doc.store.texts[Int(h.payload)]
        XCTAssertEqual(p.position.x, 10, accuracy: 1e-9)
        XCTAssertEqual(p.position.y, 11, accuracy: 1e-9)
    }

    func testInsertReturnsNilForUnknownBlock() {
        let parsed = makeParsed()
        let doc = parsed.document
        var insertId: EntityID?
        doc.transact("Insert") { tx in
            insertId = BlockEditor.insert(blockName: "NOPE", at: .zero, layerId: 0, in: parsed, tx: tx)
        }
        XCTAssertNil(insertId)
    }

    func testInsertReturnsNilForEmptyBlock() {
        let parsed = makeParsed()
        let doc = parsed.document
        let block = EditableBlockDef()
        block.name = "EMPTY"
        block.blockIndex = BlockEditor.nextBlockIndex(in: parsed)
        block.entityCount = 0
        parsed.blocks["EMPTY"] = block
        var insertId: EntityID?
        doc.transact("Insert") { tx in
            insertId = BlockEditor.insert(blockName: "EMPTY", at: .zero, layerId: 0, in: parsed, tx: tx)
        }
        XCTAssertNil(insertId, "INSERT of a registered-but-empty block must fail like an unknown block")
    }

    // MARK: - setAttribute (ATTEDIT)

    func testSetAttributeUpdatesMatchingTagOnly() throws {
        let parsed = makeParsed()
        let doc = parsed.document
        let block = EditableBlockDef()
        block.name = "B"
        block.blockIndex = BlockEditor.nextBlockIndex(in: parsed)
        parsed.blocks["B"] = block
        doc.transact("Attdefs") { tx in
            _ = BlockEditor.createAttdef(tag: "A", prompt: "", defaultValue: "a0",
                                        at: .zero, height: 1, layerId: 0, inBlockNamed: "B", in: parsed, tx: tx)
            _ = BlockEditor.createAttdef(tag: "B", prompt: "", defaultValue: "b0",
                                        at: .zero, height: 1, layerId: 0, inBlockNamed: "B", in: parsed, tx: tx)
        }
        var insertId: EntityID?
        doc.transact("Insert") { tx in
            insertId = BlockEditor.insert(blockName: "B", at: .zero, layerId: 0, in: parsed, tx: tx)
        }
        let iid = try XCTUnwrap(insertId)

        var ok = false
        doc.transact("Edit attr") { tx in
            ok = BlockEditor.setAttribute(iid, tag: "B", value: "b1", in: parsed, tx: tx)
        }
        XCTAssertTrue(ok)
        let attrs = Dictionary(uniqueKeysWithValues: BlockEditor.attributes(of: iid, in: doc.store).map { ($0.tag, $0.value) })
        XCTAssertEqual(attrs["A"], "a0", "unrelated tag must be untouched")
        XCTAssertEqual(attrs["B"], "b1")
    }

    func testSetAttributeReturnsFalseForUnknownTag() throws {
        let parsed = makeParsed()
        let doc = parsed.document
        let block = EditableBlockDef()
        block.name = "B"
        block.blockIndex = BlockEditor.nextBlockIndex(in: parsed)
        parsed.blocks["B"] = block
        doc.transact("Attdef") { tx in
            _ = BlockEditor.createAttdef(tag: "A", prompt: "", defaultValue: "a0",
                                        at: .zero, height: 1, layerId: 0, inBlockNamed: "B", in: parsed, tx: tx)
        }
        var insertId: EntityID?
        doc.transact("Insert") { tx in
            insertId = BlockEditor.insert(blockName: "B", at: .zero, layerId: 0, in: parsed, tx: tx)
        }
        let iid = try XCTUnwrap(insertId)
        var ok = true
        doc.transact("Edit attr") { tx in
            ok = BlockEditor.setAttribute(iid, tag: "NOPE", value: "x", in: parsed, tx: tx)
        }
        XCTAssertFalse(ok)
    }

    // MARK: - redefineBlock

    func testRedefineBlockReplacesContentAndMarksDirty() throws {
        let parsed = makeParsed()
        let doc = parsed.document
        var lineId: EntityID!
        doc.transact("Draw") { tx in
            lineId = tx.add(self.lineProto(Vec3(x: 0, y: 0), Vec3(x: 1, y: 0)))
        }
        var blockResult: BlockEditor.CreateBlockResult?
        doc.transact("Block") { tx in
            blockResult = BlockEditor.createBlock(name: "RB", basePoint: .zero, from: [lineId],
                                                  insertLayerId: 0, in: parsed, tx: tx)
        }
        _ = try XCTUnwrap(blockResult)

        let regen = RegenCoordinator(parsed: parsed, document: Regenerator.build(from: parsed, parseSeconds: 0) { _ in })

        var ok = false
        doc.transact("Redefine") { tx in
            ok = BlockEditor.redefineBlock(name: "RB",
                                           with: [self.circleProto(Vec3(x: 2, y: 2), 5)],
                                           in: parsed, tx: tx, regen: regen)
        }
        XCTAssertTrue(ok)
        let block = try XCTUnwrap(parsed.blocks["RB"])
        XCTAssertEqual(block.entityCount, 1)
        let newId = EntityID(raw: block.entityStart)
        let h = try XCTUnwrap(doc.store.header(newId))
        XCTAssertEqual(h.type, .circle)
        XCTAssertEqual(h.owner, OwnerRef.block(block.blockIndex))
        XCTAssertTrue(regen.dirtyBlocks.contains("RB"), "redefineBlock must mark the block dirty for regen")
    }

    func testRedefineBlockReturnsFalseForUnknownName() {
        let parsed = makeParsed()
        let doc = parsed.document
        let regen = RegenCoordinator(parsed: parsed, document: Regenerator.build(from: parsed, parseSeconds: 0) { _ in })
        var ok = true
        doc.transact("Redefine") { tx in
            ok = BlockEditor.redefineBlock(name: "NOPE", with: [], in: parsed, tx: tx, regen: regen)
        }
        XCTAssertFalse(ok)
    }
}
