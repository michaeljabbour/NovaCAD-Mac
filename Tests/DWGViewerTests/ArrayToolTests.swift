import XCTest
@testable import DWGViewer
import CADCore

/// Phase 6.4: ARRAY unit tests — rectangular/polar cell-transform math
/// (hand-verified concrete numeric examples, not just symmetric round-trips
/// per the task brief's explicit instruction) plus end-to-end commit/
/// regenerate tests against a real `EntityStore`/`Transaction`.
final class ArrayToolTests: XCTestCase {

    private func makeParsed() -> EditableParsedDocument {
        let parsed = EditableParsedDocument()
        parsed.layers.append(DXFLayer(id: 0, name: "0"))
        parsed.layerIdByName["0"] = 0
        parsed.linetypes.append(DXFLinetype(name: "CONTINUOUS", dashes: []))
        parsed.linetypeIdByName["CONTINUOUS"] = 0
        return parsed
    }

    private func pointProto(_ p: Vec3, layerId: Int32 = 0) -> EntityPrototype {
        EntityPrototype(type: .point, layerId: layerId, payload: .point(PointPayload(p: p)))
    }

    // MARK: - Rectangular cell transforms

    func testRectangularCellTransformsNoRotationGridOrder() {
        let transforms = ArrayTool.rectangularCellTransforms(
            rows: 2, cols: 3, rowSpacing: 10, colSpacing: 5, axisAngleDeg: 0)
        XCTAssertEqual(transforms.count, 6)
        // Row-major: (r,c) for r in 0..<2, c in 0..<3 -> offset (c*5, r*10).
        let expected: [(Double, Double)] = [
            (0, 0), (5, 0), (10, 0),      // row 0
            (0, 10), (5, 10), (10, 10),   // row 1
        ]
        for (i, (dx, dy)) in expected.enumerated() {
            let p = transforms[i].apply(Vec2(0, 0))
            XCTAssertEqual(p.x, dx, accuracy: 1e-9, "cell \(i) x")
            XCTAssertEqual(p.y, dy, accuracy: 1e-9, "cell \(i) y")
        }
        // Cell 0 is exactly identity.
        XCTAssertEqual(transforms[0], .identity)
    }

    /// Hand-verified: a 1x2 rectangular array (1 row, 2 columns, colSpacing
    /// 10) rotated 90 degrees (axisAngle) should place cell 1 at (0,10) —
    /// NOT (10,0) — because the grid's own column direction rotates with
    /// the axis angle. Rotating (10,0) by 90 degrees CCW gives (0,10) by
    /// the standard rotation matrix [cos -sin; sin cos] applied to (10,0):
    /// x' = 10*cos(90) - 0*sin(90) = 0, y' = 10*sin(90) + 0*cos(90) = 10.
    func testRectangularCellTransformsNonZeroAxisAngleRotatesGridDirection() {
        let transforms = ArrayTool.rectangularCellTransforms(
            rows: 1, cols: 2, rowSpacing: 0, colSpacing: 10, axisAngleDeg: 90)
        XCTAssertEqual(transforms.count, 2)
        let cell1 = transforms[1].apply(Vec2(0, 0))
        XCTAssertEqual(cell1.x, 0, accuracy: 1e-9)
        XCTAssertEqual(cell1.y, 10, accuracy: 1e-9)
        // A point OFFSET from the origin should translate rigidly (pure
        // translation, no additional rotation of the item's own shape) —
        // (3,4) + (0,10) = (3,14).
        let shifted = transforms[1].apply(Vec2(3, 4))
        XCTAssertEqual(shifted.x, 3, accuracy: 1e-9)
        XCTAssertEqual(shifted.y, 14, accuracy: 1e-9)
        // The transform must NOT itself rotate content — its linear part is
        // the identity matrix (m11=1, m12=0, m21=0, m22=1), only the
        // translation differs.
        XCTAssertEqual(transforms[1].m11, 1, accuracy: 1e-9)
        XCTAssertEqual(transforms[1].m12, 0, accuracy: 1e-9)
        XCTAssertEqual(transforms[1].m21, 0, accuracy: 1e-9)
        XCTAssertEqual(transforms[1].m22, 1, accuracy: 1e-9)
    }

    /// A second concrete non-45/90-degree example to rule out a sign error
    /// that a right-angle case could coincidentally hide: axisAngle = 30
    /// degrees, colSpacing = 10. Expected offset: (10*cos30, 10*sin30) =
    /// (8.660254, 5.0).
    func testRectangularCellTransforms30DegreeAxisAngle() {
        let transforms = ArrayTool.rectangularCellTransforms(
            rows: 1, cols: 2, rowSpacing: 0, colSpacing: 10, axisAngleDeg: 30)
        let cell1 = transforms[1].apply(Vec2(0, 0))
        XCTAssertEqual(cell1.x, 10 * cos(30 * .pi / 180), accuracy: 1e-9)
        XCTAssertEqual(cell1.y, 10 * sin(30 * .pi / 180), accuracy: 1e-9)
    }

    // MARK: - Polar cell transforms (rotateItems == true)

    func testPolarStepDegFullCircleUsesCountAsDivisor() {
        // 4 items, full 360 -> 90 degree step (4 gaps for 4 items around a
        // full circle, unlike a partial fill's count-1 gaps).
        XCTAssertEqual(ArrayTool.polarStepDeg(count: 4, fillAngleDeg: 360), 90, accuracy: 1e-9)
    }

    func testPolarStepDegPartialFillUsesCountMinusOneDivisor() {
        // 4 items spanning 90 degrees total -> 3 gaps of 30 degrees each
        // (AutoCAD: last item lands exactly at the fill angle).
        XCTAssertEqual(ArrayTool.polarStepDeg(count: 4, fillAngleDeg: 90), 30, accuracy: 1e-9)
    }

    func testPolarCellTransformsRotateItemsTrueOrbitsAndSpinsContent() {
        let center = Vec2(0, 0)
        let transforms = ArrayTool.polarCellTransforms(center: center, count: 4, fillAngleDeg: 360)
        XCTAssertEqual(transforms.count, 4)
        XCTAssertEqual(transforms[0], .identity)
        // Cell 1: source point (10,0) rotated 90 degrees CCW about origin -> (0,10).
        let p1 = transforms[1].apply(Vec2(10, 0))
        XCTAssertEqual(p1.x, 0, accuracy: 1e-9)
        XCTAssertEqual(p1.y, 10, accuracy: 1e-9)
        // Content itself rotates too: a point OFFSET from the source by
        // (1,0) (e.g. the "right edge" of a small square centered at
        // (10,0)) should map to offset (0,1) from the orbited center —
        // i.e. (0,10)+(0,1) = (0,11), NOT (1,10) (which would mean the
        // shape kept its original orientation, contradicting rotateItems=true).
        let p1Edge = transforms[1].apply(Vec2(11, 0))
        XCTAssertEqual(p1Edge.x, 0, accuracy: 1e-9)
        XCTAssertEqual(p1Edge.y, 11, accuracy: 1e-9)
    }

    // MARK: - Polar cell transforms (rotateItems == false) — the
    // "compose inverse item rotation" case, hand-derived per this file's
    // and ArrayTool.swift's own doc comments.

    /// Concrete numeric check: source entity anchor at (10,0), array center
    /// at origin, k=1 of a 4-item full-circle array (step 90 degrees).
    /// Expected: the anchor orbits to (0,10) (same as rotateItems=true), but
    /// a point OFFSET from the anchor by (1,0) must map to (0,10)+(1,0) =
    /// (1,10) — i.e. translation-only, the offset direction is UNCHANGED
    /// (proves content does NOT spin), unlike the rotateItems=true case
    /// above where the same offset point produces (0,11).
    func testPolarCellTransformKeepingUprightIsPureTranslation() {
        let anchor = Vec2(10, 0)
        let center = Vec2(0, 0)
        let t = ArrayTool.polarCellTransformKeepingUpright(anchor: anchor, center: center, k: 1, count: 4, fillAngleDeg: 360)
        let newAnchor = t.apply(anchor)
        XCTAssertEqual(newAnchor.x, 0, accuracy: 1e-9)
        XCTAssertEqual(newAnchor.y, 10, accuracy: 1e-9)
        let offsetPoint = t.apply(Vec2(11, 0))   // anchor + (1,0)
        XCTAssertEqual(offsetPoint.x, 1, accuracy: 1e-9, "content must not rotate — x offset preserved")
        XCTAssertEqual(offsetPoint.y, 10, accuracy: 1e-9, "content must not rotate — y stays at orbited anchor height")
        // The transform's own linear part must be the identity (pure
        // translation, no rotation component at all).
        XCTAssertEqual(t.m11, 1, accuracy: 1e-9)
        XCTAssertEqual(t.m12, 0, accuracy: 1e-9)
        XCTAssertEqual(t.m21, 0, accuracy: 1e-9)
        XCTAssertEqual(t.m22, 1, accuracy: 1e-9)
    }

    /// A second anchor/center combination (non-origin center, non-axis-
    /// aligned anchor) to rule out a coincidental cancellation in the first
    /// example. Anchor (13,7), center (3,7) (so anchor is 10 units along
    /// +X from center, same radius as before but offset), k=1 of a 4-item
    /// full circle (90 degree step): orbited anchor = center + R(90)*(anchor
    /// - center) = (3,7) + R(90)*(10,0) = (3,7) + (0,10) = (3,17).
    func testPolarCellTransformKeepingUprightWithOffsetCenter() {
        let anchor = Vec2(13, 7)
        let center = Vec2(3, 7)
        let t = ArrayTool.polarCellTransformKeepingUpright(anchor: anchor, center: center, k: 1, count: 4, fillAngleDeg: 360)
        let newAnchor = t.apply(anchor)
        XCTAssertEqual(newAnchor.x, 3, accuracy: 1e-9)
        XCTAssertEqual(newAnchor.y, 17, accuracy: 1e-9)
        // Content orientation preserved: offset (2,0) from anchor must
        // still read as offset (2,0) from the new anchor position.
        let offsetPoint = t.apply(Vec2(15, 7))
        XCTAssertEqual(offsetPoint.x, 5, accuracy: 1e-9)
        XCTAssertEqual(offsetPoint.y, 17, accuracy: 1e-9)
    }

    // MARK: - End-to-end commit (real EntityStore/Transaction)

    func testCommitRectangularCreatesExpectedMemberCountAndPositions() throws {
        let parsed = makeParsed()
        let doc = parsed.document
        var sourceId: EntityID!
        doc.transact("Draw") { tx in
            sourceId = tx.add(self.pointProto(Vec3(x: 0, y: 0)))
        }
        var def: ArrayDefinition?
        doc.transact("Array") { tx in
            def = ArrayTool.commitRectangular(sourceIDs: [sourceId], rows: 2, cols: 2, rowSpacing: 5,
                                              colSpacing: 5, axisAngleDeg: 0, store: parsed.store, tx: tx)
        }
        let d = try XCTUnwrap(def)
        XCTAssertEqual(d.memberHandles.count, 4)
        // Cell 0 is the ORIGINAL source entity (not a new copy).
        XCTAssertEqual(d.memberHandles[0], sourceId)
        // Every OTHER member is a genuinely new, non-deleted entity at the
        // expected offset.
        let positions = d.memberHandles.map { id -> Vec3 in
            let h = parsed.store.header(id)!
            return parsed.store.points[Int(h.payload)].p
        }
        let expected: [Vec3] = [Vec3(x: 0, y: 0), Vec3(x: 5, y: 0), Vec3(x: 0, y: 5), Vec3(x: 5, y: 5)]
        for (i, e) in expected.enumerated() {
            XCTAssertEqual(positions[i].x, e.x, accuracy: 1e-9, "member \(i) x")
            XCTAssertEqual(positions[i].y, e.y, accuracy: 1e-9, "member \(i) y")
        }
        for id in d.memberHandles { XCTAssertFalse(parsed.store.isDeleted(id)) }
    }

    func testCommitRectangularTagsMembersWithArrayDefXData() throws {
        let parsed = makeParsed()
        let doc = parsed.document
        var sourceId: EntityID!
        doc.transact("Draw") { tx in sourceId = tx.add(self.pointProto(Vec3(x: 0, y: 0))) }
        var def: ArrayDefinition?
        doc.transact("Array") { tx in
            def = ArrayTool.commitRectangular(sourceIDs: [sourceId], rows: 1, cols: 2, rowSpacing: 0,
                                              colSpacing: 5, axisAngleDeg: 0, store: parsed.store, tx: tx)
        }
        let d = try XCTUnwrap(def)
        for id in d.memberHandles {
            let blob = try XCTUnwrap(parsed.store.xdata[id.raw])
            XCTAssertEqual(blob.appId, "NOVACAD")
            XCTAssertTrue(blob.pairs.contains { pair in
                if case .string(let s) = pair.value { return s.hasPrefix("ARRAYDEF ") }
                return false
            })
        }
    }

    func testCommitPolarRotateItemsTrueProducesExpectedPositions() throws {
        let parsed = makeParsed()
        let doc = parsed.document
        var sourceId: EntityID!
        doc.transact("Draw") { tx in sourceId = tx.add(self.pointProto(Vec3(x: 10, y: 0))) }
        var def: ArrayDefinition?
        doc.transact("Array") { tx in
            def = ArrayTool.commitPolar(sourceIDs: [sourceId], center: CGPoint(x: 0, y: 0), count: 4,
                                        fillAngleDeg: 360, rotateItems: true, store: parsed.store, tx: tx)
        }
        let d = try XCTUnwrap(def)
        XCTAssertEqual(d.memberHandles.count, 4)
        let positions = d.memberHandles.map { id -> Vec3 in
            let h = parsed.store.header(id)!
            return parsed.store.points[Int(h.payload)].p
        }
        // 4 points around a circle of radius 10 at 0/90/180/270 degrees.
        let expected: [(Double, Double)] = [(10, 0), (0, 10), (-10, 0), (0, -10)]
        for (i, (ex, ey)) in expected.enumerated() {
            XCTAssertEqual(positions[i].x, ex, accuracy: 1e-6, "member \(i) x")
            XCTAssertEqual(positions[i].y, ey, accuracy: 1e-6, "member \(i) y")
        }
    }

    // MARK: - Regenerate (Edit Array)

    func testRegenerateReplacesMembersWithNewParameters() throws {
        let parsed = makeParsed()
        let doc = parsed.document
        var sourceId: EntityID!
        doc.transact("Draw") { tx in sourceId = tx.add(self.pointProto(Vec3(x: 0, y: 0))) }
        var def: ArrayDefinition?
        doc.transact("Array") { tx in
            def = ArrayTool.commitRectangular(sourceIDs: [sourceId], rows: 1, cols: 2, rowSpacing: 0,
                                              colSpacing: 5, axisAngleDeg: 0, store: parsed.store, tx: tx)
        }
        let original = try XCTUnwrap(def)
        XCTAssertEqual(original.memberHandles.count, 2)

        var regenerated: ArrayDefinition?
        doc.transact("Edit Array") { tx in
            regenerated = ArrayTool.regenerate(original, sourceIDs: [sourceId],
                                               newKindParams: .rectangular(rows: 1, cols: 3, rowSpacing: 0, colSpacing: 5, axisAngle: 0),
                                               store: parsed.store, tx: tx)
        }
        let r = try XCTUnwrap(regenerated)
        XCTAssertEqual(r.memberHandles.count, 3)
        // The OLD extra member (cell 1 of the 1x2 array) must now be deleted.
        let oldExtraMember = original.memberHandles[1]
        XCTAssertTrue(parsed.store.isDeleted(oldExtraMember))
        // The source entity itself survives (reused as cell 0 again).
        XCTAssertFalse(parsed.store.isDeleted(sourceId))
        XCTAssertEqual(r.memberHandles[0], sourceId)
    }

    func testRegenerateToleratesAlreadyUserDeletedMember() throws {
        let parsed = makeParsed()
        let doc = parsed.document
        var sourceId: EntityID!
        doc.transact("Draw") { tx in sourceId = tx.add(self.pointProto(Vec3(x: 0, y: 0))) }
        var def: ArrayDefinition?
        doc.transact("Array") { tx in
            def = ArrayTool.commitRectangular(sourceIDs: [sourceId], rows: 1, cols: 2, rowSpacing: 0,
                                              colSpacing: 5, axisAngleDeg: 0, store: parsed.store, tx: tx)
        }
        let original = try XCTUnwrap(def)
        // Simulate the user manually erasing one member BEFORE Edit Array.
        doc.transact("Erase") { tx in tx.delete(original.memberHandles[1]) }

        var regenerated: ArrayDefinition?
        doc.transact("Edit Array") { tx in
            regenerated = ArrayTool.regenerate(original, sourceIDs: [sourceId],
                                               newKindParams: .rectangular(rows: 1, cols: 2, rowSpacing: 0, colSpacing: 5, axisAngle: 0),
                                               store: parsed.store, tx: tx)
        }
        // Must not throw/crash on the already-deleted id — regenerate still
        // succeeds and produces a fresh full set of members.
        let r = try XCTUnwrap(regenerated)
        XCTAssertEqual(r.memberHandles.count, 2)
    }

    /// Regression test for an adversarial-review finding: `tagMembers`
    /// writes XDATA outside `Transaction`'s own snapshot/restore machinery
    /// (`EntityImage` only covers header+payload, not the sparse
    /// `EntityStore.xdata` dictionary) — undoing an Edit Array must restore
    /// the SOURCE entity's ORIGINAL ArrayDef XDATA (from before the edit),
    /// not leave the post-edit JSON permanently in place.
    func testUndoingEditArrayRestoresSourceEntitysOriginalArrayDefXData() throws {
        let parsed = makeParsed()
        let doc = parsed.document
        var sourceId: EntityID!
        doc.transact("Draw") { tx in sourceId = tx.add(self.pointProto(Vec3(x: 0, y: 0))) }

        func jsonPayload(_ blob: XDataBlob) -> String? {
            for pair in blob.pairs {
                if case .string(let s) = pair.value, s.hasPrefix(ArrayTool.arrayDefPrefix) { return s }
            }
            return nil
        }

        var original: ArrayDefinition?
        doc.transact("Array") { tx in
            original = ArrayTool.commitRectangular(sourceIDs: [sourceId], rows: 1, cols: 2, rowSpacing: 0,
                                                   colSpacing: 5, axisAngleDeg: 0, store: parsed.store, tx: tx)
        }
        let originalDef = try XCTUnwrap(original)
        let originalBlob = try XCTUnwrap(parsed.store.xdata[sourceId.raw])
        let originalJSON = try XCTUnwrap(jsonPayload(originalBlob))
        XCTAssertTrue(originalJSON.contains("\"cols\":2"))

        doc.transact("Edit Array") { tx in
            _ = ArrayTool.regenerate(originalDef, sourceIDs: [sourceId],
                                     newKindParams: .rectangular(rows: 3, cols: 3, rowSpacing: 1, colSpacing: 1, axisAngle: 0),
                                     store: parsed.store, tx: tx)
        }
        let editedBlob = try XCTUnwrap(parsed.store.xdata[sourceId.raw])
        let editedJSON = try XCTUnwrap(jsonPayload(editedBlob))
        XCTAssertTrue(editedJSON.contains("\"cols\":3"), "XDATA should reflect the NEW definition immediately after Edit Array")

        doc.undo()

        let afterUndoBlob = try XCTUnwrap(parsed.store.xdata[sourceId.raw])
        let afterUndoJSON = try XCTUnwrap(jsonPayload(afterUndoBlob))
        XCTAssertTrue(afterUndoJSON.contains("\"cols\":2"),
                     "undo must restore the source entity's PRE-edit ArrayDef XDATA, not leave the post-edit JSON in place")
    }
}
