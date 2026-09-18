import XCTest
@testable import DWGViewer
import CADCore
import CoreGraphics

/// Tests for `HatchTool` ("Fill / Hatch…" — the Properties panel's
/// single-entity counterpart to `ShadeLayer`'s whole-layer bulk fill) and the
/// general per-entity color-editing logic backing `PropertiesPanel`'s new
/// "Color" row.
final class HatchToolTests: XCTestCase {

    private func makeParsed() -> EditableParsedDocument {
        let parsed = EditableParsedDocument()
        parsed.layers.append(DXFLayer(id: 0, name: "0"))
        parsed.layerIdByName["0"] = 0
        return parsed
    }

    private func appendClosedRect(to parsed: EditableParsedDocument, layerId: Int32 = 0) -> EntityID {
        parsed.store.append(EntityPrototype(
            type: .lwpolyline, layerId: layerId, owner: .model,
            payload: .polyline(PolylinePayload(closed: true),
                               vertices: [Vec3(x: 0, y: 0), Vec3(x: 10, y: 0),
                                          Vec3(x: 10, y: 10), Vec3(x: 0, y: 10)],
                               bulges: [0, 0, 0, 0])))
    }

    private func appendOpenPolyline(to parsed: EditableParsedDocument) -> EntityID {
        parsed.store.append(EntityPrototype(
            type: .lwpolyline, layerId: 0, owner: .model,
            payload: .polyline(PolylinePayload(closed: false),
                               vertices: [Vec3(x: 0, y: 0), Vec3(x: 10, y: 0), Vec3(x: 10, y: 10)],
                               bulges: [0, 0, 0])))
    }

    // MARK: - isFillable

    func testClosedPolylineIsFillable() {
        let parsed = makeParsed()
        let id = appendClosedRect(to: parsed)
        XCTAssertTrue(HatchTool.isFillable(id, in: parsed.store))
    }

    func testOpenPolylineIsNotFillable() {
        let parsed = makeParsed()
        let id = appendOpenPolyline(to: parsed)
        XCTAssertFalse(HatchTool.isFillable(id, in: parsed.store))
    }

    func testCircleIsFillable() {
        let parsed = makeParsed()
        let id = parsed.store.append(EntityPrototype(
            type: .circle, layerId: 0, owner: .model,
            payload: .circle(CirclePayload(center: Vec3(x: 0, y: 0), radius: 5))))
        XCTAssertTrue(HatchTool.isFillable(id, in: parsed.store))
    }

    func testHatchItselfIsNotFillable() {
        // Hatching a hatch is meaningless — its own color/transparency
        // controls are the relevant action there, not a second fill.
        let parsed = makeParsed()
        let id = parsed.store.append(EntityPrototype(
            type: .hatch, layerId: 0, owner: .model,
            payload: .hatch(HatchPayload(isSolid: true),
                            loops: [[Vec3(x: 0, y: 0), Vec3(x: 10, y: 0), Vec3(x: 10, y: 10)]])))
        XCTAssertFalse(HatchTool.isFillable(id, in: parsed.store))
    }

    func testDeletedEntityIsNotFillable() {
        let parsed = makeParsed()
        let id = appendClosedRect(to: parsed)
        parsed.document.transact("Delete") { tx in tx.delete(id) }
        XCTAssertFalse(HatchTool.isFillable(id, in: parsed.store))
    }

    func testBlockOwnedEntityIsNotFillable() {
        // Only top-level model/paper-space shapes are fillable — a shape
        // living inside a block DEFINITION isn't directly selectable/
        // fillable the way a top-level one is.
        let parsed = makeParsed()
        let blockIndex = BlockEditor.nextBlockIndex(in: parsed)
        var id: EntityID!
        parsed.document.transact("Define block") { tx in
            id = tx.add(EntityPrototype(
                type: .lwpolyline, layerId: 0, owner: .block(blockIndex),
                payload: .polyline(PolylinePayload(closed: true),
                                   vertices: [Vec3(x: 0, y: 0), Vec3(x: 10, y: 0), Vec3(x: 10, y: 10)],
                                   bulges: [0, 0, 0])))
        }
        XCTAssertFalse(HatchTool.isFillable(id, in: parsed.store))
    }

    // MARK: - hatch(_:in:tx:)

    func testHatchCreatesANewSolidHatchOnTheSameLayer() throws {
        let parsed = makeParsed()
        parsed.layers.append(DXFLayer(id: 1, name: "ROOMS"))
        parsed.layerIdByName["ROOMS"] = 1
        let id = appendClosedRect(to: parsed, layerId: 1)
        var newId: EntityID?
        parsed.document.transact("Fill / Hatch") { tx in
            newId = HatchTool.hatch(id, in: parsed, tx: tx)
        }
        let hatchId = try XCTUnwrap(newId)
        let h = try XCTUnwrap(parsed.store.header(hatchId))
        XCTAssertEqual(h.type, .hatch)
        XCTAssertEqual(h.layerId, 1, "the new hatch must land on the SOURCE shape's own layer")
        let hp = parsed.store.hatches[Int(h.payload)]
        XCTAssertTrue(hp.isSolid)
    }

    func testHatchBoundaryMatchesTheSourceShape() throws {
        let parsed = makeParsed()
        let id = appendClosedRect(to: parsed)
        var newId: EntityID?
        parsed.document.transact("Fill") { tx in newId = HatchTool.hatch(id, in: parsed, tx: tx) }
        let hatchId = try XCTUnwrap(newId)
        let h = try XCTUnwrap(parsed.store.header(hatchId))
        let hp = parsed.store.hatches[Int(h.payload)]
        let range = parsed.store.hatchLoopRanges[Int(hp.loopRangeStart)]
        XCTAssertEqual(Int(range.vertCount), 4)
        let pts = (0..<4).map { parsed.store.vertexArena[Int(range.vertStart) + $0].cgPoint }
        XCTAssertEqual(Set(pts), Set([CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0),
                                      CGPoint(x: 10, y: 10), CGPoint(x: 0, y: 10)]))
    }

    func testHatchPreservesTheSourceShapesColor() throws {
        let parsed = makeParsed()
        let id = appendClosedRect(to: parsed)
        parsed.document.transact("Recolor source") { tx in
            tx.modifyHeader(id) { $0.aci = 1 }   // red
        }
        var newId: EntityID?
        parsed.document.transact("Fill") { tx in newId = HatchTool.hatch(id, in: parsed, tx: tx) }
        let h = try XCTUnwrap(parsed.store.header(try XCTUnwrap(newId)))
        XCTAssertEqual(h.aci, 1, "the new hatch should inherit the source shape's color as a sensible starting point")
    }

    func testHatchReturnsNilForANonFillableTarget() throws {
        let parsed = makeParsed()
        let id = appendOpenPolyline(to: parsed)
        var newId: EntityID? = EntityID(raw: 999)   // sentinel, must become nil
        parsed.document.transact("Try") { tx in newId = HatchTool.hatch(id, in: parsed, tx: tx) }
        XCTAssertNil(newId)
    }

    func testHatchIsUndoable() throws {
        let parsed = makeParsed()
        let id = appendClosedRect(to: parsed)
        let before = parsed.document.undoStack.count
        var newId: EntityID?
        parsed.document.transact("Fill") { tx in newId = HatchTool.hatch(id, in: parsed, tx: tx) }
        XCTAssertEqual(parsed.document.undoStack.count, before + 1)
        let hatchId = try XCTUnwrap(newId)
        parsed.document.undo()
        XCTAssertTrue(parsed.store.header(hatchId)?.flags.contains(.deleted) ?? true)
    }

    /// The end-to-end path a click on "Fill / Hatch…" actually exercises:
    /// isFillable gates the button, hatch(...) creates it, and the result is
    /// itself grip-editable (via `GripEditing`'s `.hatch` case) exactly like
    /// any other hatch — closing the loop back to the original "extend a
    /// shaded aisle" editability fix earlier this session.
    func testCreatedHatchIsGripEditable() throws {
        let parsed = makeParsed()
        let id = appendClosedRect(to: parsed)
        var newId: EntityID?
        parsed.document.transact("Fill") { tx in newId = HatchTool.hatch(id, in: parsed, tx: tx) }
        let hatchId = try XCTUnwrap(newId)
        XCTAssertFalse(GripEditing.grips(for: hatchId, in: parsed.store).isEmpty)
    }
}
