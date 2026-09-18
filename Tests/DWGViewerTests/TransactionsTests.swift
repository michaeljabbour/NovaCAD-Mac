import XCTest
@testable import DWGViewer
import CADCore

final class TransactionsTests: XCTestCase {

    private func linePrototype(_ a: Vec3, _ b: Vec3) -> EntityPrototype {
        EntityPrototype(type: .line, layerId: 0, payload: .line(LinePayload(a: a, b: b)))
    }

    // MARK: - add / commit / undo / redo

    func testAddCommitUndoRedo() {
        let doc = EditableDocument()
        var id: EntityID!
        doc.transact("Draw Line") { tx in
            id = tx.add(self.linePrototype(Vec3(x: 0, y: 0), Vec3(x: 10, y: 10)))
        }
        XCTAssertFalse(doc.store.isDeleted(id))
        XCTAssertEqual(doc.undoStack.count, 1)

        doc.undo()
        XCTAssertTrue(doc.store.isDeleted(id), "undo of an add tombstones the entity")
        XCTAssertEqual(doc.redoStack.count, 1)

        doc.redo()
        XCTAssertFalse(doc.store.isDeleted(id), "redo of the add un-tombstones it")
        XCTAssertEqual(doc.undoStack.count, 1)
    }

    // MARK: - delete / undo restores exact prior state

    func testDeleteUndoRestoresPriorState() {
        let doc = EditableDocument()
        var id: EntityID!
        doc.transact("Draw") { tx in
            id = tx.add(self.linePrototype(Vec3(x: 1, y: 2), Vec3(x: 3, y: 4)))
        }
        doc.transact("Erase") { tx in tx.delete(id) }
        XCTAssertTrue(doc.store.isDeleted(id))

        doc.undo()
        XCTAssertFalse(doc.store.isDeleted(id))
        let h = try! XCTUnwrap(doc.store.header(id))
        let line = doc.store.lines[Int(h.payload)]
        XCTAssertEqual(line.a, Vec3(x: 1, y: 2))
        XCTAssertEqual(line.b, Vec3(x: 3, y: 4))
    }

    // MARK: - modify + undo/redo, including payload arena in-place overwrite

    func testModifyPayloadUndoRedo() {
        let doc = EditableDocument()
        var id: EntityID!
        doc.transact("Draw") { tx in
            id = tx.add(self.linePrototype(Vec3(x: 0, y: 0), Vec3(x: 10, y: 0)))
        }
        let payloadIndexBefore = doc.store.header(id)!.payload

        doc.transact("Move") { tx in
            tx.modifyPayload(id) { copy in
                guard case .line(var l) = copy else { return }
                l.a.x += 5; l.b.x += 5
                copy = .line(l)
            }
        }
        let payloadIndexAfter = doc.store.header(id)!.payload
        XCTAssertEqual(payloadIndexBefore, payloadIndexAfter,
                      "same-shape payload edits overwrite the existing arena slot rather than leaking a new one")
        XCTAssertEqual(doc.store.lines[Int(payloadIndexAfter)].a, Vec3(x: 5, y: 0))

        doc.undo()
        XCTAssertEqual(doc.store.lines[Int(doc.store.header(id)!.payload)].a, Vec3(x: 0, y: 0),
                      "undo restores the pre-move coordinates")

        doc.redo()
        XCTAssertEqual(doc.store.lines[Int(doc.store.header(id)!.payload)].a, Vec3(x: 5, y: 0))
    }

    /// Multiple `modifyPayload` calls on the same entity within ONE
    /// transaction (e.g. a live drag updating position every frame) must
    /// coalesce into a single before/after pair — undo should jump straight
    /// back to the state before the transaction started, not to some
    /// intermediate frame.
    func testRepeatedModifyWithinOneTransactionCoalesces() {
        let doc = EditableDocument()
        var id: EntityID!
        doc.transact("Draw") { tx in
            id = tx.add(self.linePrototype(Vec3(x: 0, y: 0), Vec3(x: 1, y: 0)))
        }

        doc.transact("Drag") { tx in
            for step in 1...5 {
                tx.modifyPayload(id) { copy in
                    guard case .line(var l) = copy else { return }
                    l.a.x = Double(step); l.b.x = Double(step) + 1
                    copy = .line(l)
                }
            }
        }
        XCTAssertEqual(doc.store.lines[Int(doc.store.header(id)!.payload)].a.x, 5)
        // One "Drag" transaction, not five.
        XCTAssertEqual(doc.undoStack.last?.name, "Drag")

        doc.undo()
        XCTAssertEqual(doc.store.lines[Int(doc.store.header(id)!.payload)].a.x, 0,
                      "undo jumps to the pre-transaction state, not an intermediate drag frame")
    }

    // MARK: - modifyHeader

    func testModifyHeaderUndoRedo() {
        let doc = EditableDocument()
        var id: EntityID!
        doc.transact("Draw") { tx in
            id = tx.add(self.linePrototype(Vec3(x: 0, y: 0), Vec3(x: 1, y: 1)))
        }
        doc.transact("Change Layer") { tx in
            tx.modifyHeader(id) { $0.layerId = 3 }
        }
        XCTAssertEqual(doc.store.header(id)!.layerId, 3)
        doc.undo()
        XCTAssertEqual(doc.store.header(id)!.layerId, 0)
        doc.redo()
        XCTAssertEqual(doc.store.header(id)!.layerId, 3)
    }

    // MARK: - replace (TRIM/EXPLODE-style structural change)

    func testReplaceDeletesOriginalAndAddsNewPreservingLayer() {
        let doc = EditableDocument()
        var originalID: EntityID!
        doc.transact("Draw") { tx in
            var proto = self.linePrototype(Vec3(x: 0, y: 0), Vec3(x: 10, y: 0))
            proto.layerId = 7
            originalID = tx.add(proto)
        }
        var newIDs: [EntityID] = []
        doc.transact("Trim") { tx in
            newIDs = tx.replace(originalID, with: [
                EntityPrototype(type: .line, layerId: -1, payload: .line(LinePayload(a: Vec3(x: 0, y: 0), b: Vec3(x: 4, y: 0)))),
                EntityPrototype(type: .line, layerId: -1, payload: .line(LinePayload(a: Vec3(x: 6, y: 0), b: Vec3(x: 10, y: 0))))
            ])
        }
        XCTAssertTrue(doc.store.isDeleted(originalID))
        XCTAssertEqual(newIDs.count, 2)
        for id in newIDs {
            XCTAssertEqual(doc.store.header(id)!.layerId, 7, "replacement entities inherit the original's layer")
        }

        doc.undo()
        XCTAssertFalse(doc.store.isDeleted(originalID))
        for id in newIDs { XCTAssertTrue(doc.store.isDeleted(id)) }
    }

    // MARK: - cancel (abort mid-transaction without publishing to undo)

    func testCancelRevertsWithoutPublishing() {
        let doc = EditableDocument()
        var id: EntityID!
        doc.transact("Draw") { tx in
            id = tx.add(self.linePrototype(Vec3(x: 0, y: 0), Vec3(x: 1, y: 1)))
        }
        let stackDepthBefore = doc.undoStack.count

        let tx = doc.begin("Aborted edit")
        tx.modifyHeader(id) { $0.layerId = 99 }
        doc.cancel(tx)

        XCTAssertEqual(doc.store.header(id)!.layerId, 0, "cancel reverts the in-flight edit")
        XCTAssertEqual(doc.undoStack.count, stackDepthBefore, "cancel must not push an undo entry")
    }

    func testTransactWithThrowingBodyCancelsAutomatically() {
        struct Boom: Error {}
        let doc = EditableDocument()
        var id: EntityID!
        doc.transact("Draw") { tx in
            id = tx.add(self.linePrototype(Vec3(x: 0, y: 0), Vec3(x: 1, y: 1)))
        }
        let stackDepthBefore = doc.undoStack.count

        XCTAssertThrowsError(try doc.transact("Bad edit") { tx in
            tx.modifyHeader(id) { $0.layerId = 42 }
            throw Boom()
        })
        XCTAssertEqual(doc.store.header(id)!.layerId, 0)
        XCTAssertEqual(doc.undoStack.count, stackDepthBefore)
    }

    // MARK: - empty transaction is a no-op, not a blank undo step

    func testEmptyTransactionDoesNotPushUndoEntry() {
        let doc = EditableDocument()
        let before = doc.undoStack.count
        doc.transact("Nothing") { _ in }
        XCTAssertEqual(doc.undoStack.count, before)
    }

    // MARK: - undo/redo stack depth cap

    func testUndoStackIsCapped() {
        let doc = EditableDocument()
        for i in 0..<150 {
            doc.transact("Draw \(i)") { tx in
                _ = tx.add(self.linePrototype(Vec3(x: Double(i), y: 0), Vec3(x: Double(i) + 1, y: 0)))
            }
        }
        XCTAssertLessThanOrEqual(doc.undoStack.count, 100)
    }

    // MARK: - Phase 4.2: transform(_:by:mirrtext:) — MOVE/ROTATE/SCALE/MIRROR primitive

    func testTransformRotateUndoRedo() {
        let doc = EditableDocument()
        var id: EntityID!
        doc.transact("Draw") { tx in
            id = tx.add(self.linePrototype(Vec3(x: 1, y: 0), Vec3(x: 2, y: 0)))
        }
        let t = Transform2.rotation(about: Vec2(0, 0), angleRad: .pi / 2)
        doc.transact("Rotate") { tx in tx.transform(id, by: t, mirrtext: false) }

        let line = doc.store.lines[Int(doc.store.header(id)!.payload)]
        XCTAssertEqual(line.a.x, 0, accuracy: 1e-9)
        XCTAssertEqual(line.a.y, 1, accuracy: 1e-9)

        doc.undo()
        let restored = doc.store.lines[Int(doc.store.header(id)!.payload)]
        XCTAssertEqual(restored.a.x, 1, accuracy: 1e-9)
        XCTAssertEqual(restored.a.y, 0, accuracy: 1e-9)

        doc.redo()
        let redone = doc.store.lines[Int(doc.store.header(id)!.payload)]
        XCTAssertEqual(redone.a.x, 0, accuracy: 1e-9)
        XCTAssertEqual(redone.a.y, 1, accuracy: 1e-9)
    }

    func testTransformMultipleEntitiesInOneTransaction() {
        let doc = EditableDocument()
        var ids: [EntityID] = []
        doc.transact("Draw") { tx in
            ids.append(tx.add(self.linePrototype(Vec3(x: 0, y: 0), Vec3(x: 1, y: 0))))
            ids.append(tx.add(self.linePrototype(Vec3(x: 5, y: 5), Vec3(x: 6, y: 5))))
        }
        let t = Transform2.translation(dx: 10, dy: 10)
        doc.transact("Move 2") { tx in
            for id in ids { tx.transform(id, by: t, mirrtext: false) }
        }
        XCTAssertEqual(doc.undoStack.last?.name, "Move 2")
        let l0 = doc.store.lines[Int(doc.store.header(ids[0])!.payload)]
        let l1 = doc.store.lines[Int(doc.store.header(ids[1])!.payload)]
        XCTAssertEqual(l0.a.x, 10); XCTAssertEqual(l0.a.y, 10)
        XCTAssertEqual(l1.a.x, 15); XCTAssertEqual(l1.a.y, 15)

        doc.undo()
        let restored0 = doc.store.lines[Int(doc.store.header(ids[0])!.payload)]
        let restored1 = doc.store.lines[Int(doc.store.header(ids[1])!.payload)]
        XCTAssertEqual(restored0.a.x, 0); XCTAssertEqual(restored0.a.y, 0)
        XCTAssertEqual(restored1.a.x, 5); XCTAssertEqual(restored1.a.y, 5)
    }

    // MARK: - Phase 4.2: copyTransformed(_:by:mirrtext:owner:) — COPY primitive

    func testCopyTransformedCreatesNewEntityLeavingOriginalUntouched() {
        let doc = EditableDocument()
        var originalId: EntityID!
        doc.transact("Draw") { tx in
            originalId = tx.add(self.linePrototype(Vec3(x: 0, y: 0), Vec3(x: 1, y: 0)))
        }
        var copyId: EntityID!
        let t = Transform2.translation(dx: 100, dy: 0)
        doc.transact("Copy") { tx in
            copyId = tx.copyTransformed(originalId, by: t, mirrtext: false)
        }
        XCTAssertNotEqual(copyId, originalId)
        let original = doc.store.lines[Int(doc.store.header(originalId)!.payload)]
        XCTAssertEqual(original.a.x, 0, "the source entity must be untouched by COPY")
        let copy = doc.store.lines[Int(doc.store.header(copyId)!.payload)]
        XCTAssertEqual(copy.a.x, 100)
        XCTAssertEqual(copy.b.x, 101)
    }

    func testCopyTransformedPreservesLayerAndColor() {
        let doc = EditableDocument()
        var originalId: EntityID!
        doc.transact("Draw") { tx in
            originalId = tx.add(EntityPrototype(type: .line, layerId: 3, aci: 5,
                                                owner: .model,
                                                payload: .line(LinePayload(a: Vec3(x: 0, y: 0), b: Vec3(x: 1, y: 0)))))
        }
        var copyId: EntityID!
        doc.transact("Copy") { tx in
            copyId = tx.copyTransformed(originalId, by: Transform2.translation(dx: 5, dy: 5), mirrtext: false)
        }
        let h = doc.store.header(copyId)!
        XCTAssertEqual(h.layerId, 3)
        XCTAssertEqual(h.aci, 5)
    }

    func testCopyTransformedUndoRemovesOnlyTheCopy() {
        let doc = EditableDocument()
        var originalId: EntityID!
        doc.transact("Draw") { tx in
            originalId = tx.add(self.linePrototype(Vec3(x: 0, y: 0), Vec3(x: 1, y: 0)))
        }
        var copyId: EntityID!
        doc.transact("Copy") { tx in
            copyId = tx.copyTransformed(originalId, by: Transform2.translation(dx: 1, dy: 1), mirrtext: false)
        }
        doc.undo()
        XCTAssertTrue(doc.store.isDeleted(copyId), "undo of Copy tombstones the new entity")
        XCTAssertFalse(doc.store.isDeleted(originalId), "the source entity must survive undo of Copy")
    }

    func testCopyTransformedIdentityIsPlainDuplicate() {
        let doc = EditableDocument()
        var originalId: EntityID!
        doc.transact("Draw") { tx in
            originalId = tx.add(self.linePrototype(Vec3(x: 3, y: 4), Vec3(x: 5, y: 6)))
        }
        var copyId: EntityID!
        doc.transact("Copy") { tx in
            copyId = tx.copyTransformed(originalId)
        }
        let original = doc.store.lines[Int(doc.store.header(originalId)!.payload)]
        let copy = doc.store.lines[Int(doc.store.header(copyId)!.payload)]
        XCTAssertEqual(original.a, copy.a)
        XCTAssertEqual(original.b, copy.b)
    }

    func testCopyTransformedOfNonexistentEntityReturnsNil() {
        let doc = EditableDocument()
        doc.transact("Copy nothing") { tx in
            let result = tx.copyTransformed(EntityID(raw: 999))
            XCTAssertNil(result)
        }
    }
}
