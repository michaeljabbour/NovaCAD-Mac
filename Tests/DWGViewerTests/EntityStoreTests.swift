import XCTest
@testable import DWGViewer

final class EntityStoreTests: XCTestCase {

    // MARK: - append / header / bounds per type

    func testLineAppendHeaderBounds() throws {
        let store = EntityStore()
        let proto = EntityPrototype(type: .line, layerId: 0,
                                    payload: .line(LinePayload(a: Vec3(x: 0, y: 0), b: Vec3(x: 10, y: 20))))
        let id = store.append(proto)
        XCTAssertEqual(store.count, 1)
        let h = try XCTUnwrap(store.header(id))
        XCTAssertEqual(h.type, .line)
        XCTAssertFalse(h.flags.contains(.deleted))
        let b = store.bounds(id)
        XCTAssertEqual(b, CGRect(x: 0, y: 0, width: 10, height: 20))
    }

    func testCircleAndArcBounds() {
        let store = EntityStore()
        let circleID = store.append(EntityPrototype(type: .circle, layerId: 0,
            payload: .circle(CirclePayload(center: Vec3(x: 5, y: 5), radius: 3))))
        XCTAssertEqual(store.bounds(circleID), CGRect(x: 2, y: 2, width: 6, height: 6))

        let arcID = store.append(EntityPrototype(type: .arc, layerId: 0,
            payload: .arc(ArcPayload(center: Vec3(x: 0, y: 0), radius: 10, startAngleDeg: 0, endAngleDeg: 90))))
        // Conservative full-circle bbox by design.
        XCTAssertEqual(store.bounds(arcID), CGRect(x: -10, y: -10, width: 20, height: 20))
    }

    func testPolylineVertexArenaRoundTrip() {
        let store = EntityStore()
        let verts = [Vec3(x: 0, y: 0), Vec3(x: 10, y: 0), Vec3(x: 10, y: 10), Vec3(x: 0, y: 10)]
        let bulges = [0.0, 0.0, 0.0, 0.0]
        let proto = EntityPrototype(type: .lwpolyline, layerId: 0,
            payload: .polyline(PolylinePayload(closed: true), vertices: verts, bulges: bulges))
        let id = store.append(proto)
        XCTAssertEqual(store.bounds(id), CGRect(x: 0, y: 0, width: 10, height: 10))
        let h = try? XCTUnwrap(store.header(id))
        let payload = store.polylines[Int(h!.payload)]
        XCTAssertEqual(Int(payload.vertsCount), 4)
        XCTAssertTrue(payload.closed)
        for i in 0..<4 {
            XCTAssertEqual(store.vertexArena[Int(payload.vertsStart) + i], verts[i])
        }
    }

    func testSplineArenaRoundTrip() {
        let store = EntityStore()
        let control = [Vec3(x: 0, y: 0), Vec3(x: 5, y: 10), Vec3(x: 10, y: 0)]
        let knots: [Double] = [0, 0, 0, 1, 1, 1]
        let weights: [Double] = [1, 1, 1]
        let id = store.append(EntityPrototype(type: .spline, layerId: 0,
            payload: .spline(SplinePayload(degree: 2), control: control, knots: knots, weights: weights)))
        let h = try! XCTUnwrap(store.header(id))
        let p = store.splines[Int(h.payload)]
        XCTAssertEqual(Int(p.controlCount), 3)
        XCTAssertEqual(Int(p.knotCount), 6)
        XCTAssertEqual(Int(p.weightCount), 3)
    }

    func testHatchLoopsRoundTrip() {
        let store = EntityStore()
        let loop1: [Vec3] = [Vec3(x: 0, y: 0), Vec3(x: 10, y: 0), Vec3(x: 10, y: 10), Vec3(x: 0, y: 10)]
        let id = store.append(EntityPrototype(type: .hatch, layerId: 0,
            payload: .hatch(HatchPayload(isSolid: true), loops: [loop1])))
        XCTAssertEqual(store.bounds(id), CGRect(x: 0, y: 0, width: 10, height: 10))
        let h = try! XCTUnwrap(store.header(id))
        XCTAssertEqual(Int(store.hatches[Int(h.payload)].loopRangeCount), 1)
    }

    func testTextPayloadUsesStringTable() {
        let store = EntityStore()
        let sid = store.strings.intern("HELLO")
        let id = store.append(EntityPrototype(type: .text, layerId: 0,
            payload: .text(TextPayload(position: Vec3(x: 1, y: 2), height: 5, stringId: sid))))
        let h = try! XCTUnwrap(store.header(id))
        let t = store.texts[Int(h.payload)]
        XCTAssertEqual(store.strings.string(for: t.stringId), "HELLO")
    }

    // MARK: - handle lookup

    func testHandleLookup() {
        let store = EntityStore()
        let proto = EntityPrototype(type: .point, layerId: 0, payload: .point(PointPayload(p: Vec3(x: 1, y: 1))))
        let id = store.append(proto)
        store.setHeader(id) { $0.handle = 0xABCD }
        XCTAssertEqual(store.entity(forHandle: 0xABCD), id)
        XCTAssertNil(store.entity(forHandle: 0xFFFF))
        XCTAssertNil(store.entity(forHandle: 0))   // 0 = "no handle", never resolves
    }

    // MARK: - spatial query & children

    func testEntitiesInRegionAndSpaceFiltering() {
        let store = EntityStore()
        let modelID = store.append(EntityPrototype(type: .point, layerId: 0, owner: .model,
            payload: .point(PointPayload(p: Vec3(x: 5, y: 5)))))
        let paperID = store.append(EntityPrototype(type: .point, layerId: 0, owner: .paper,
            payload: .point(PointPayload(p: Vec3(x: 5, y: 5)))))
        let farID = store.append(EntityPrototype(type: .point, layerId: 0, owner: .model,
            payload: .point(PointPayload(p: Vec3(x: 1000, y: 1000)))))

        let region = CGRect(x: 0, y: 0, width: 10, height: 10)
        let modelHits = store.entities(in: region, space: .model)
        XCTAssertTrue(modelHits.contains(modelID))
        XCTAssertFalse(modelHits.contains(farID))
        XCTAssertFalse(modelHits.contains(paperID))

        let paperHits = store.entities(in: region, space: .paper)
        XCTAssertEqual(paperHits, [paperID])
    }

    func testEntitiesInRegionExcludesDeleted() {
        let store = EntityStore()
        let id = store.append(EntityPrototype(type: .point, layerId: 0,
            payload: .point(PointPayload(p: Vec3(x: 1, y: 1)))))
        store.markDeleted(id)
        let hits = store.entities(in: CGRect(x: 0, y: 0, width: 10, height: 10), space: .model)
        XCTAssertTrue(hits.isEmpty)
    }

    func testChildrenOfParent() {
        let store = EntityStore()
        let blockName = store.strings.intern("SYM")
        let insertID = store.append(EntityPrototype(type: .insert, layerId: 0,
            payload: .insert(InsertPayload(blockNameId: blockName, position: Vec3(x: 0, y: 0)))))
        let attrib1 = store.append(EntityPrototype(type: .attrib, layerId: 0, owner: .parentEntity(insertID),
            payload: .text(TextPayload(position: Vec3(x: 0, y: 0), height: 1, stringId: store.strings.intern("A")))))
        let attrib2 = store.append(EntityPrototype(type: .attrib, layerId: 0, owner: .parentEntity(insertID),
            payload: .text(TextPayload(position: Vec3(x: 0, y: 0), height: 1, stringId: store.strings.intern("B")))))
        let unrelated = store.append(EntityPrototype(type: .point, layerId: 0,
            payload: .point(PointPayload(p: Vec3(x: 0, y: 0)))))

        let kids = Set(store.children(of: insertID))
        XCTAssertEqual(kids, Set([attrib1, attrib2]))
        XCTAssertFalse(kids.contains(unrelated))
        XCTAssertTrue(store.children(of: unrelated).isEmpty)
    }

    // MARK: - OwnerRef encoding

    func testOwnerRefEncoding() {
        XCTAssertTrue(OwnerRef.model.isModel)
        XCTAssertTrue(OwnerRef.paper.isPaper)
        XCTAssertTrue(OwnerRef.block(3).isBlock)
        let parent = EntityID(raw: 42)
        let ref = OwnerRef.parentEntity(parent)
        XCTAssertEqual(ref.parentEntityID, parent)
        XCTAssertFalse(ref.isModel); XCTAssertFalse(ref.isPaper); XCTAssertFalse(ref.isBlock)
    }

    // MARK: - ATTRIB/ATTDEF snapshot/restore (regression: Phase 1.6 found this)
    //
    // ATTRIB/ATTDEF share `TextPayload` storage with TEXT (see
    // EntityStoreParser: `finish(type == "ATTRIB" ? .attrib : .text,
    // .text(payload), ...)`), but `EntityStore.copyPayload`/`writePayload`/
    // `bounds` originally only matched `.text` in their switches — an ATTRIB/
    // ATTDEF's `snapshot()` silently returned `.unknown`, and `restore()`ing
    // an `.unknown` payload zeroes the entity's `payload` index via
    // `storePayload(.unknown) -> -1`, permanently discarding its geometry.
    // This was invisible to every prior test because none of them ever
    // snapshotted/restored an ATTRIB or ATTDEF — it surfaced only once Phase
    // 1.6's incremental regen exercised a bulk `Transaction.modifyPayload` +
    // undo cycle over a real file containing ATTRIB entities inside a block.

    func testAttribSnapshotRestoreRoundTrip() throws {
        let store = EntityStore()
        let sid = store.strings.intern("ATTRIB-VALUE")
        let id = store.append(EntityPrototype(type: .attrib, layerId: 0, owner: .block(0),
            payload: .text(TextPayload(position: Vec3(x: 1, y: 2), height: 3, stringId: sid))))

        let image = try XCTUnwrap(store.snapshot(id), "snapshot must not be nil for ATTRIB")
        guard case .text(let captured) = image.payloadCopy else {
            return XCTFail("ATTRIB snapshot returned \(image.payloadCopy) instead of .text(...)")
        }
        XCTAssertEqual(captured.position, Vec3(x: 1, y: 2))

        // A no-op restore (the shape of what undo does) must not corrupt the
        // entity's payload pointer.
        store.restore(id, image)
        let h = try XCTUnwrap(store.header(id))
        XCTAssertGreaterThanOrEqual(h.payload, 0, "restore must not zero out ATTRIB's payload index")
        XCTAssertEqual(store.texts[Int(h.payload)].position, Vec3(x: 1, y: 2))
        XCTAssertEqual(store.bounds(id), CGRect(x: 1, y: 2, width: 0, height: 0))
    }

    func testAttdefSnapshotRestoreRoundTrip() throws {
        let store = EntityStore()
        let sid = store.strings.intern("TAG")
        let id = store.append(EntityPrototype(type: .attdef, layerId: 0,
            payload: .text(TextPayload(position: Vec3(x: 5, y: 6), height: 1, stringId: sid))))
        let image = try XCTUnwrap(store.snapshot(id))
        guard case .text = image.payloadCopy else {
            return XCTFail("ATTDEF snapshot returned \(image.payloadCopy) instead of .text(...)")
        }
        store.restore(id, image)
        let h = try XCTUnwrap(store.header(id))
        XCTAssertGreaterThanOrEqual(h.payload, 0, "restore must not zero out ATTDEF's payload index")
    }

    /// End-to-end through `Transaction`: modify + undo an ATTRIB must restore
    /// its exact prior position, exercising the same code path a real
    /// modifyPayload-based command (e.g. a bulk `move`) uses.
    func testAttribTransactionModifyUndoRestoresPosition() throws {
        let doc = EditableDocument()
        let sid = doc.store.strings.intern("VAL")
        var id: EntityID!
        doc.transact("Draw") { tx in
            id = tx.add(EntityPrototype(type: .attrib, layerId: 0, owner: .block(0),
                payload: .text(TextPayload(position: Vec3(x: 0, y: 0), height: 1, stringId: sid))))
        }
        doc.transact("Move") { tx in
            tx.modifyPayload(id) { copy in
                guard case .text(var t) = copy else { return }
                t.position.x += 10
                copy = .text(t)
            }
        }
        XCTAssertEqual(doc.store.texts[Int(doc.store.header(id)!.payload)].position, Vec3(x: 10, y: 0))
        doc.undo()
        let h = try XCTUnwrap(doc.store.header(id))
        XCTAssertGreaterThanOrEqual(h.payload, 0, "undo must not zero out ATTRIB's payload index")
        XCTAssertEqual(doc.store.texts[Int(h.payload)].position, Vec3(x: 0, y: 0),
                      "undo must restore the ATTRIB's exact pre-move position")
    }

    // MARK: - appendCopy (cross-EntityStore transplant — xref attach/merge, cross-drawing paste)

    /// Regression test for a bug this session found: `appendCopy` only ever
    /// remapped INSERT's `blockNameId` through the SOURCE store's
    /// `StringTable` into the DESTINATION's — every other string-table
    /// reference a payload can carry (TEXT/ATTRIB/ATTDEF's value/style/tag/
    /// prompt, MTEXT's raw string/style, HATCH's pattern name) was left as
    /// a raw index into the SOURCE table, which is meaningless (or
    /// corrupts to a DIFFERENT string, or empty-string-falls-back) once
    /// read back against the destination's own, unrelated table. No
    /// existing xref fixture happened to contain a TEXT/MTEXT/ATTRIB entity,
    /// so this went uncaught until the cross-drawing-paste feature's
    /// research surfaced it.
    func testAppendCopyReinternsTextStringIdIntoDestinationTable() throws {
        let source = EntityStore()
        let dest = EntityStore()
        // Force the two tables' indices to visibly disagree: intern a
        // decoy string into `dest` FIRST so "TEXT VALUE"'s id in `source`
        // (0) would collide with something else entirely in `dest` if left
        // unremapped.
        _ = dest.strings.intern("DECOY — wrong string if unremapped")
        let sourceStringId = source.strings.intern("TEXT VALUE")
        let srcId = source.append(EntityPrototype(type: .text, layerId: 0,
            payload: .text(TextPayload(position: Vec3(x: 1, y: 2), height: 1, stringId: sourceStringId))))

        let newId = try XCTUnwrap(dest.appendCopy(of: srcId, from: source,
                                                  remapLayer: { $0 }, remapLinetype: { $0 }, owner: .model))
        let destHeader = try XCTUnwrap(dest.header(newId))
        let destText = dest.texts[Int(destHeader.payload)]
        XCTAssertEqual(dest.strings.string(for: destText.stringId), "TEXT VALUE",
                      "TEXT's stringId must be re-interned into the DESTINATION store's own StringTable")
    }

    func testAppendCopyReinternsMTextStringIdIntoDestinationTable() throws {
        let source = EntityStore()
        let dest = EntityStore()
        _ = dest.strings.intern("DECOY")
        let sourceStringId = source.strings.intern("MTEXT \\Pcontent")
        let srcId = source.append(EntityPrototype(type: .mtext, layerId: 0,
            payload: .mtext(MTextPayload(insertion: Vec3(x: 0, y: 0), height: 1, stringId: sourceStringId))))

        let newId = try XCTUnwrap(dest.appendCopy(of: srcId, from: source,
                                                  remapLayer: { $0 }, remapLinetype: { $0 }, owner: .model))
        let destHeader = try XCTUnwrap(dest.header(newId))
        let destMText = dest.mtexts[Int(destHeader.payload)]
        XCTAssertEqual(dest.strings.string(for: destMText.stringId), "MTEXT \\Pcontent")
    }

    func testAppendCopyReinternsAttribTagAndValue() throws {
        let source = EntityStore()
        let dest = EntityStore()
        _ = dest.strings.intern("DECOY")
        let valueId = source.strings.intern("Ryan")
        let tagId = source.strings.intern("NAME")
        let srcId = source.append(EntityPrototype(type: .attrib, layerId: 0, owner: .block(0),
            payload: .text(TextPayload(position: Vec3(x: 0, y: 0), height: 1, stringId: valueId, tagStringId: tagId))))

        let newId = try XCTUnwrap(dest.appendCopy(of: srcId, from: source,
                                                  remapLayer: { $0 }, remapLinetype: { $0 }, owner: .parentEntity(EntityID(raw: 0))))
        let destHeader = try XCTUnwrap(dest.header(newId))
        let destText = dest.texts[Int(destHeader.payload)]
        XCTAssertEqual(dest.strings.string(for: destText.stringId), "Ryan")
        XCTAssertEqual(dest.strings.string(for: destText.tagStringId), "NAME")
    }

    func testAppendCopyRemapsBlockNameForInsert() throws {
        let source = EntityStore()
        let dest = EntityStore()
        let blockNameId = source.strings.intern("WORKSTATION")
        let srcId = source.append(EntityPrototype(type: .insert, layerId: 0,
            payload: .insert(InsertPayload(blockNameId: blockNameId, position: Vec3(x: 0, y: 0)))))

        let newId = try XCTUnwrap(dest.appendCopy(of: srcId, from: source,
                                                  remapLayer: { $0 }, remapLinetype: { $0 },
                                                  remapBlockName: { "PASTED$\($0)" }, owner: .model))
        let destHeader = try XCTUnwrap(dest.header(newId))
        let destInsert = dest.inserts[Int(destHeader.payload)]
        XCTAssertEqual(dest.strings.string(for: destInsert.blockNameId), "PASTED$WORKSTATION")
    }

    /// Regression coverage for the SAME class of bug the `stringId`/`tagStringId`
    /// fixes above address, caught proactively when `InsertPayload
    /// .displayNameId` (the cosmetic per-instance display-name override —
    /// see that field's own doc comment) was added: it's ANOTHER
    /// string-table reference on `.insert`'s payload, so it needed the same
    /// re-interning `appendCopy` already does for `blockNameId`/TEXT/ATTRIB
    /// fields — otherwise a display-name override would silently corrupt
    /// (or point at the destination's own unrelated string) across any
    /// cross-document transplant (xref attach, cross-drawing paste).
    func testAppendCopyReinternsDisplayNameIdIntoDestinationTable() throws {
        let source = EntityStore()
        let dest = EntityStore()
        _ = dest.strings.intern("DECOY — wrong string if unremapped")
        let blockNameId = source.strings.intern("WORKSTATION")
        let displayNameId = source.strings.intern("Station 7")
        var payload = InsertPayload(blockNameId: blockNameId, position: Vec3(x: 0, y: 0))
        payload.displayNameId = displayNameId
        let srcId = source.append(EntityPrototype(type: .insert, layerId: 0, payload: .insert(payload)))

        let newId = try XCTUnwrap(dest.appendCopy(of: srcId, from: source,
                                                  remapLayer: { $0 }, remapLinetype: { $0 }, owner: .model))
        let destHeader = try XCTUnwrap(dest.header(newId))
        let destInsert = dest.inserts[Int(destHeader.payload)]
        XCTAssertEqual(dest.strings.string(for: destInsert.displayNameId), "Station 7",
                      "displayNameId must be re-interned into the DESTINATION store's own StringTable")
    }

    func testAppendCopyLeavesDisplayNameIdUnsetWhenSourceHasNoOverride() throws {
        let source = EntityStore()
        let dest = EntityStore()
        let blockNameId = source.strings.intern("WORKSTATION")
        let srcId = source.append(EntityPrototype(type: .insert, layerId: 0,
            payload: .insert(InsertPayload(blockNameId: blockNameId, position: Vec3(x: 0, y: 0)))))

        let newId = try XCTUnwrap(dest.appendCopy(of: srcId, from: source,
                                                  remapLayer: { $0 }, remapLinetype: { $0 }, owner: .model))
        let destHeader = try XCTUnwrap(dest.header(newId))
        XCTAssertEqual(dest.inserts[Int(destHeader.payload)].displayNameId, -1)
    }

    func testAppendCopyRemapsLayerAndLinetype() throws {
        let source = EntityStore()
        let dest = EntityStore()
        let srcId = source.append(EntityPrototype(type: .line, layerId: 3, linetypeId: 2,
            payload: .line(LinePayload(a: Vec3(x: 0, y: 0), b: Vec3(x: 1, y: 1)))))

        let newId = try XCTUnwrap(dest.appendCopy(of: srcId, from: source,
                                                  remapLayer: { _ in 99 }, remapLinetype: { _ in 42 }, owner: .model))
        let destHeader = try XCTUnwrap(dest.header(newId))
        XCTAssertEqual(destHeader.layerId, 99)
        XCTAssertEqual(destHeader.linetypeId, 42)
    }

    func testAppendCopyLeavesByLayerByBlockLinetypeUnmapped() throws {
        let source = EntityStore()
        let dest = EntityStore()
        let srcId = source.append(EntityPrototype(type: .line, layerId: 0, linetypeId: -1,
            payload: .line(LinePayload(a: Vec3(x: 0, y: 0), b: Vec3(x: 1, y: 1)))))

        let newId = try XCTUnwrap(dest.appendCopy(of: srcId, from: source,
                                                  remapLayer: { $0 }, remapLinetype: { _ in 999 }, owner: .model))
        let destHeader = try XCTUnwrap(dest.header(newId))
        XCTAssertEqual(destHeader.linetypeId, -1, "BYLAYER (-1) must not be run through remapLinetype")
    }
}
