import XCTest
@testable import DWGViewer
import CADCore

/// Tests for grip editing (`GripEditing.swift`) — the pure geometry/data-
/// model layer behind "drag a vertex to reshape one section of an enclosed
/// object" and STRETCH's crossing-window multi-vertex move. UI wiring
/// (hit-testing screen coordinates, canvas rendering) is exercised manually;
/// these tests cover the underlying `EntityStore`/`Transaction` mutations,
/// which is where correctness actually matters.
final class GripEditingTests: XCTestCase {

    private func makeStore() -> EntityStore { EntityStore() }

    // MARK: - grips(for:in:)

    func testLineHasTwoGrips() {
        let store = makeStore()
        let id = store.append(EntityPrototype(type: .line, layerId: 0,
            payload: .line(LinePayload(a: Vec3(x: 0, y: 0), b: Vec3(x: 10, y: 0)))))
        let grips = GripEditing.grips(for: id, in: store)
        XCTAssertEqual(grips.count, 2)
        XCTAssertEqual(grips[0].position, CGPoint(x: 0, y: 0))
        XCTAssertEqual(grips[1].position, CGPoint(x: 10, y: 0))
    }

    func testClosedPolylineHasOneGripPerVertex() {
        let store = makeStore()
        let id = store.append(EntityPrototype(type: .lwpolyline, layerId: 0,
            payload: .polyline(PolylinePayload(closed: true),
                               vertices: [Vec3(x: 0, y: 0), Vec3(x: 10, y: 0), Vec3(x: 10, y: 10), Vec3(x: 0, y: 10)],
                               bulges: [0, 0, 0, 0])))
        let grips = GripEditing.grips(for: id, in: store)
        XCTAssertEqual(grips.count, 4)
        XCTAssertEqual(grips.map(\.position), [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0),
                                               CGPoint(x: 10, y: 10), CGPoint(x: 0, y: 10)])
    }

    func testCircleHasCenterAndRadiusGrip() {
        let store = makeStore()
        let id = store.append(EntityPrototype(type: .circle, layerId: 0,
            payload: .circle(CirclePayload(center: Vec3(x: 5, y: 5), radius: 3))))
        let grips = GripEditing.grips(for: id, in: store)
        XCTAssertEqual(grips.count, 2)
        XCTAssertEqual(grips[0].position, CGPoint(x: 5, y: 5), "index 0 = center")
        XCTAssertEqual(grips[1].position, CGPoint(x: 8, y: 5), "index 1 = point at 0° on the circle")
    }

    func testArcHasStartEndAndMidpointGrips() {
        let store = makeStore()
        let id = store.append(EntityPrototype(type: .arc, layerId: 0,
            payload: .arc(ArcPayload(center: Vec3(x: 0, y: 0), radius: 10, startAngleDeg: 0, endAngleDeg: 90))))
        let grips = GripEditing.grips(for: id, in: store)
        XCTAssertEqual(grips.count, 3)
        XCTAssertEqual(grips[0].position.x, 10, accuracy: 1e-9)
        XCTAssertEqual(grips[0].position.y, 0, accuracy: 1e-9)
        XCTAssertEqual(grips[1].position.x, 0, accuracy: 1e-9)
        XCTAssertEqual(grips[1].position.y, 10, accuracy: 1e-9)
        // Midpoint of a 0->90 sweep is at 45°.
        XCTAssertEqual(grips[2].position.x, 10 * cos(45 * .pi / 180), accuracy: 1e-6)
        XCTAssertEqual(grips[2].position.y, 10 * sin(45 * .pi / 180), accuracy: 1e-6)
    }

    func testArcMidpointHandlesWrapAroundZeroDegrees() {
        // Sweep from 350° to 10° (through 0°) — midpoint must be at 0°, not
        // the naive (350+10)/2 = 180° (the WRONG answer for a wrapping sweep).
        let store = makeStore()
        let id = store.append(EntityPrototype(type: .arc, layerId: 0,
            payload: .arc(ArcPayload(center: Vec3(x: 0, y: 0), radius: 10, startAngleDeg: 350, endAngleDeg: 10))))
        let grips = GripEditing.grips(for: id, in: store)
        XCTAssertEqual(grips[2].position.x, 10, accuracy: 1e-6, "midpoint of a 350->10 sweep must be at 0°, not 180°")
        XCTAssertEqual(grips[2].position.y, 0, accuracy: 1e-6)
    }

    func testUnsupportedTypeHasNoGrips() {
        let store = makeStore()
        let stringId = store.strings.intern("hi")
        let id = store.append(EntityPrototype(type: .text, layerId: 0,
            payload: .text(TextPayload(position: Vec3(x: 0, y: 0), height: 1, stringId: stringId))))
        XCTAssertTrue(GripEditing.grips(for: id, in: store).isEmpty)
    }

    func testIsGripEditableMatchesGripsSupport() {
        XCTAssertTrue(GripEditing.isGripEditable(.line))
        XCTAssertTrue(GripEditing.isGripEditable(.lwpolyline))
        XCTAssertTrue(GripEditing.isGripEditable(.circle))
        XCTAssertTrue(GripEditing.isGripEditable(.arc))
        XCTAssertFalse(GripEditing.isGripEditable(.text))
        XCTAssertFalse(GripEditing.isGripEditable(.insert))
    }

    // MARK: - nearestGrip: hover/click hit-testing

    func testNearestGripFindsClosestGripWithinTolerance() {
        let store = makeStore()
        let id = store.append(EntityPrototype(type: .line, layerId: 0,
            payload: .line(LinePayload(a: Vec3(x: 0, y: 0), b: Vec3(x: 10, y: 0)))))
        let hit = GripEditing.nearestGrip(candidateIds: [id], in: store, to: CGPoint(x: 0.5, y: 0.5), tolerance: 2)
        XCTAssertEqual(hit?.entityId, id)
        XCTAssertEqual(hit?.gripIndex, 0)
        XCTAssertEqual(hit?.position, CGPoint(x: 0, y: 0))
    }

    func testNearestGripReturnsNilOutsideTolerance() {
        let store = makeStore()
        let id = store.append(EntityPrototype(type: .line, layerId: 0,
            payload: .line(LinePayload(a: Vec3(x: 0, y: 0), b: Vec3(x: 10, y: 0)))))
        XCTAssertNil(GripEditing.nearestGrip(candidateIds: [id], in: store, to: CGPoint(x: 5, y: 5), tolerance: 2))
    }

    func testNearestGripPicksTheCloserOfTwoNearbyGripsAcrossEntities() {
        let store = makeStore()
        let id1 = store.append(EntityPrototype(type: .line, layerId: 0,
            payload: .line(LinePayload(a: Vec3(x: 0, y: 0), b: Vec3(x: 100, y: 100)))))
        let id2 = store.append(EntityPrototype(type: .line, layerId: 0,
            payload: .line(LinePayload(a: Vec3(x: 1, y: 0), b: Vec3(x: 200, y: 200)))))
        // Probe point is closer to id2's (1,0) endpoint than id1's (0,0).
        let hit = GripEditing.nearestGrip(candidateIds: [id1, id2], in: store, to: CGPoint(x: 1.1, y: 0), tolerance: 5)
        XCTAssertEqual(hit?.entityId, id2)
        XCTAssertEqual(hit?.gripIndex, 0)
    }

    // MARK: - previewShape: live drag ghost (no store mutation)

    func testPreviewShapeForLineMovesOnlyDraggedEndpoint() throws {
        let store = makeStore()
        let id = store.append(EntityPrototype(type: .line, layerId: 0,
            payload: .line(LinePayload(a: Vec3(x: 0, y: 0), b: Vec3(x: 10, y: 0)))))
        let shape = try XCTUnwrap(GripEditing.previewShape(for: id, in: store, gripIndex: 0,
                                                            candidatePosition: CGPoint(x: -5, y: 5)))
        guard case .line(let a, let b) = shape else { return XCTFail("expected .line") }
        XCTAssertEqual(a, CGPoint(x: -5, y: 5))
        XCTAssertEqual(b, CGPoint(x: 10, y: 0))
    }

    func testPreviewShapeDoesNotMutateTheStore() throws {
        let store = makeStore()
        let id = store.append(EntityPrototype(type: .line, layerId: 0,
            payload: .line(LinePayload(a: Vec3(x: 0, y: 0), b: Vec3(x: 10, y: 0)))))
        _ = GripEditing.previewShape(for: id, in: store, gripIndex: 0, candidatePosition: CGPoint(x: 99, y: 99))
        let h = try XCTUnwrap(store.header(id))
        XCTAssertEqual(store.lines[Int(h.payload)].a.cgPoint, CGPoint(x: 0, y: 0), "preview must not mutate the store")
    }

    func testPreviewShapeForPolylineMovesOnlyOneVertex() throws {
        let store = makeStore()
        let id = store.append(EntityPrototype(type: .lwpolyline, layerId: 0,
            payload: .polyline(PolylinePayload(closed: true),
                               vertices: [Vec3(x: 0, y: 0), Vec3(x: 10, y: 0), Vec3(x: 10, y: 10), Vec3(x: 0, y: 10)],
                               bulges: [0, 0, 0, 0])))
        let shape = try XCTUnwrap(GripEditing.previewShape(for: id, in: store, gripIndex: 1,
                                                            candidatePosition: CGPoint(x: 20, y: -5)))
        guard case .polyline(let pts, let closed) = shape else { return XCTFail("expected .polyline") }
        XCTAssertTrue(closed)
        XCTAssertEqual(pts, [CGPoint(x: 0, y: 0), CGPoint(x: 20, y: -5), CGPoint(x: 10, y: 10), CGPoint(x: 0, y: 10)])
    }

    func testPreviewShapeForCircleRadiusGripResizes() throws {
        let store = makeStore()
        let id = store.append(EntityPrototype(type: .circle, layerId: 0,
            payload: .circle(CirclePayload(center: Vec3(x: 0, y: 0), radius: 5))))
        let shape = try XCTUnwrap(GripEditing.previewShape(for: id, in: store, gripIndex: 1,
                                                            candidatePosition: CGPoint(x: 0, y: 10)))
        guard case .circle(let center, let radius) = shape else { return XCTFail("expected .circle") }
        XCTAssertEqual(center, CGPoint(x: 0, y: 0))
        XCTAssertEqual(radius, 10, accuracy: 1e-9)
    }

    func testPreviewShapeReturnsNilForUnsupportedType() {
        let store = makeStore()
        let stringId = store.strings.intern("hi")
        let id = store.append(EntityPrototype(type: .text, layerId: 0,
            payload: .text(TextPayload(position: Vec3(x: 0, y: 0), height: 1, stringId: stringId))))
        XCTAssertNil(GripEditing.previewShape(for: id, in: store, gripIndex: 0, candidatePosition: .zero))
    }

    // MARK: - moveGrip: reshapes ONE point, leaves the rest fixed

    func testMoveGripOnLineMovesOnlyThatEndpoint() throws {
        let doc = EditableDocument()
        let id = doc.store.append(EntityPrototype(type: .line, layerId: 0,
            payload: .line(LinePayload(a: Vec3(x: 0, y: 0), b: Vec3(x: 10, y: 0)))))
        doc.transact("Drag grip") { tx in
            GripEditing.moveGrip(id, index: 0, to: CGPoint(x: -5, y: 5), in: tx)
        }
        let h = try XCTUnwrap(doc.store.header(id))
        let line = doc.store.lines[Int(h.payload)]
        XCTAssertEqual(line.a.cgPoint, CGPoint(x: -5, y: 5))
        XCTAssertEqual(line.b.cgPoint, CGPoint(x: 10, y: 0), "the OTHER endpoint must be untouched")
    }

    func testMoveGripOnPolylineMovesOnlyOneVertexKeepingOthersConnected() throws {
        // THE core "extrude a section" scenario: a square, drag one corner
        // out — the two ADJACENT edges must still connect to the moved
        // corner (they share its vertex data), and the far edge is untouched.
        let doc = EditableDocument()
        let id = doc.store.append(EntityPrototype(type: .lwpolyline, layerId: 0,
            payload: .polyline(PolylinePayload(closed: true),
                               vertices: [Vec3(x: 0, y: 0), Vec3(x: 10, y: 0), Vec3(x: 10, y: 10), Vec3(x: 0, y: 10)],
                               bulges: [0, 0, 0, 0])))
        doc.transact("Drag grip") { tx in
            GripEditing.moveGrip(id, index: 1, to: CGPoint(x: 20, y: -5), in: tx)
        }
        let h = try XCTUnwrap(doc.store.header(id))
        let pl = doc.store.polylines[Int(h.payload)]
        let verts = (0..<Int(pl.vertsCount)).map { doc.store.vertexArena[Int(pl.vertsStart) + $0].cgPoint }
        XCTAssertEqual(verts[0], CGPoint(x: 0, y: 0), "untouched vertex")
        XCTAssertEqual(verts[1], CGPoint(x: 20, y: -5), "the dragged vertex moved")
        XCTAssertEqual(verts[2], CGPoint(x: 10, y: 10), "untouched vertex")
        XCTAssertEqual(verts[3], CGPoint(x: 0, y: 10), "untouched vertex")
    }

    func testMoveGripOnCircleCenterMovesWholeCircle() throws {
        let doc = EditableDocument()
        let id = doc.store.append(EntityPrototype(type: .circle, layerId: 0,
            payload: .circle(CirclePayload(center: Vec3(x: 0, y: 0), radius: 5))))
        doc.transact("Drag grip") { tx in
            GripEditing.moveGrip(id, index: 0, to: CGPoint(x: 3, y: 4), in: tx)
        }
        let h = try XCTUnwrap(doc.store.header(id))
        let circle = doc.store.circles[Int(h.payload)]
        XCTAssertEqual(circle.center.cgPoint, CGPoint(x: 3, y: 4))
        XCTAssertEqual(circle.radius, 5, accuracy: 1e-9, "radius must be unaffected by moving the CENTER grip")
    }

    func testMoveGripOnCircleRadiusPointResizesWithoutMovingCenter() throws {
        let doc = EditableDocument()
        let id = doc.store.append(EntityPrototype(type: .circle, layerId: 0,
            payload: .circle(CirclePayload(center: Vec3(x: 0, y: 0), radius: 5))))
        doc.transact("Drag grip") { tx in
            GripEditing.moveGrip(id, index: 1, to: CGPoint(x: 0, y: 10), in: tx)
        }
        let h = try XCTUnwrap(doc.store.header(id))
        let circle = doc.store.circles[Int(h.payload)]
        XCTAssertEqual(circle.center.cgPoint, CGPoint(x: 0, y: 0), "center must be unaffected by moving the RADIUS grip")
        XCTAssertEqual(circle.radius, 10, accuracy: 1e-9)
    }

    func testMoveGripIsUndoable() throws {
        let doc = EditableDocument()
        let id = doc.store.append(EntityPrototype(type: .line, layerId: 0,
            payload: .line(LinePayload(a: Vec3(x: 0, y: 0), b: Vec3(x: 10, y: 0)))))
        doc.transact("Drag grip") { tx in
            GripEditing.moveGrip(id, index: 0, to: CGPoint(x: -5, y: 5), in: tx)
        }
        doc.undo()
        let h = try XCTUnwrap(doc.store.header(id))
        XCTAssertEqual(doc.store.lines[Int(h.payload)].a.cgPoint, CGPoint(x: 0, y: 0))
    }

    // MARK: - addVertex / nearestEdge

    func testAddVertexInsertsANewVertexBetweenTwoExisting() throws {
        let doc = EditableDocument()
        let id = doc.store.append(EntityPrototype(type: .lwpolyline, layerId: 0,
            payload: .polyline(PolylinePayload(closed: true),
                               vertices: [Vec3(x: 0, y: 0), Vec3(x: 10, y: 0), Vec3(x: 10, y: 10), Vec3(x: 0, y: 10)],
                               bulges: [0, 0, 0, 0])))
        doc.transact("Add vertex") { tx in
            GripEditing.addVertex(id, afterIndex: 0, at: CGPoint(x: 5, y: 0), in: tx)
        }
        let h = try XCTUnwrap(doc.store.header(id))
        let pl = doc.store.polylines[Int(h.payload)]
        XCTAssertEqual(pl.vertsCount, 5)
        let verts = (0..<Int(pl.vertsCount)).map { doc.store.vertexArena[Int(pl.vertsStart) + $0].cgPoint }
        XCTAssertEqual(verts, [CGPoint(x: 0, y: 0), CGPoint(x: 5, y: 0), CGPoint(x: 10, y: 0),
                              CGPoint(x: 10, y: 10), CGPoint(x: 0, y: 10)])
    }

    func testAddVertexIsUndoable() throws {
        let doc = EditableDocument()
        let id = doc.store.append(EntityPrototype(type: .lwpolyline, layerId: 0,
            payload: .polyline(PolylinePayload(closed: true),
                               vertices: [Vec3(x: 0, y: 0), Vec3(x: 10, y: 0), Vec3(x: 10, y: 10), Vec3(x: 0, y: 10)],
                               bulges: [0, 0, 0, 0])))
        doc.transact("Add vertex") { tx in
            GripEditing.addVertex(id, afterIndex: 0, at: CGPoint(x: 5, y: 0), in: tx)
        }
        doc.undo()
        let h = try XCTUnwrap(doc.store.header(id))
        XCTAssertEqual(doc.store.polylines[Int(h.payload)].vertsCount, 4)
    }

    func testNearestEdgeFindsTheClosestSegmentWithinTolerance() throws {
        let store = makeStore()
        let id = store.append(EntityPrototype(type: .lwpolyline, layerId: 0,
            payload: .polyline(PolylinePayload(closed: true),
                               vertices: [Vec3(x: 0, y: 0), Vec3(x: 10, y: 0), Vec3(x: 10, y: 10), Vec3(x: 0, y: 10)],
                               bulges: [0, 0, 0, 0])))
        // Point near the middle of the bottom edge (vertex 0 -> 1).
        let result = try XCTUnwrap(GripEditing.nearestEdge(of: id, in: store, to: CGPoint(x: 5, y: 0.5), tolerance: 2))
        XCTAssertEqual(result.afterIndex, 0)
        XCTAssertEqual(result.point.x, 5, accuracy: 1e-6)
        XCTAssertEqual(result.point.y, 0, accuracy: 1e-6)
    }

    func testNearestEdgeReturnsNilWhenOutsideTolerance() {
        let store = makeStore()
        let id = store.append(EntityPrototype(type: .lwpolyline, layerId: 0,
            payload: .polyline(PolylinePayload(closed: true),
                               vertices: [Vec3(x: 0, y: 0), Vec3(x: 10, y: 0), Vec3(x: 10, y: 10), Vec3(x: 0, y: 10)],
                               bulges: [0, 0, 0, 0])))
        XCTAssertNil(GripEditing.nearestEdge(of: id, in: store, to: CGPoint(x: 5, y: 50), tolerance: 2))
    }

    func testNearestEdgeFindsTheClosingEdgeOfAClosedPolyline() throws {
        // The edge from the LAST vertex back to vertex 0 — only exists
        // because the polyline is closed.
        let store = makeStore()
        let id = store.append(EntityPrototype(type: .lwpolyline, layerId: 0,
            payload: .polyline(PolylinePayload(closed: true),
                               vertices: [Vec3(x: 0, y: 0), Vec3(x: 10, y: 0), Vec3(x: 10, y: 10), Vec3(x: 0, y: 10)],
                               bulges: [0, 0, 0, 0])))
        // Midpoint of the left edge: vertex 3 (0,10) -> vertex 0 (0,0).
        let result = try XCTUnwrap(GripEditing.nearestEdge(of: id, in: store, to: CGPoint(x: 0, y: 5), tolerance: 2))
        XCTAssertEqual(result.afterIndex, 3)
    }

    func testNearestEdgeDoesNotFindTheClosingEdgeOfAnOpenPolyline() {
        let store = makeStore()
        let id = store.append(EntityPrototype(type: .lwpolyline, layerId: 0,
            payload: .polyline(PolylinePayload(closed: false),
                               vertices: [Vec3(x: 0, y: 0), Vec3(x: 10, y: 0), Vec3(x: 10, y: 10), Vec3(x: 0, y: 10)],
                               bulges: [0, 0, 0, 0])))
        XCTAssertNil(GripEditing.nearestEdge(of: id, in: store, to: CGPoint(x: 0, y: 5), tolerance: 2),
                    "an OPEN polyline has no edge from the last vertex back to the first")
    }

    // MARK: - previewStretchShape: multi-vertex STRETCH ghost (no store mutation)

    func testPreviewStretchShapeMovesOnlyCaughtVertices() throws {
        let store = makeStore()
        let id = store.append(EntityPrototype(type: .lwpolyline, layerId: 0,
            payload: .polyline(PolylinePayload(closed: true),
                               vertices: [Vec3(x: 0, y: 0), Vec3(x: 10, y: 0), Vec3(x: 10, y: 10), Vec3(x: 0, y: 10)],
                               bulges: [0, 0, 0, 0])))
        let shape = try XCTUnwrap(GripEditing.previewStretchShape(for: id, in: store, caughtIndices: [1, 2],
                                                                   delta: CGVector(dx: 5, dy: 0)))
        guard case .polyline(let pts, let closed) = shape else { return XCTFail("expected .polyline") }
        XCTAssertTrue(closed)
        XCTAssertEqual(pts, [CGPoint(x: 0, y: 0), CGPoint(x: 15, y: 0), CGPoint(x: 15, y: 10), CGPoint(x: 0, y: 10)])
    }

    func testPreviewStretchShapeReturnsNilForEmptyCaughtIndices() {
        let store = makeStore()
        let id = store.append(EntityPrototype(type: .line, layerId: 0,
            payload: .line(LinePayload(a: Vec3(x: 0, y: 0), b: Vec3(x: 10, y: 0)))))
        XCTAssertNil(GripEditing.previewStretchShape(for: id, in: store, caughtIndices: [], delta: CGVector(dx: 1, dy: 1)))
    }

    func testPreviewStretchShapeDoesNotMutateTheStore() throws {
        let store = makeStore()
        let id = store.append(EntityPrototype(type: .line, layerId: 0,
            payload: .line(LinePayload(a: Vec3(x: 0, y: 0), b: Vec3(x: 10, y: 0)))))
        _ = GripEditing.previewStretchShape(for: id, in: store, caughtIndices: [0], delta: CGVector(dx: 99, dy: 99))
        let h = try XCTUnwrap(store.header(id))
        XCTAssertEqual(store.lines[Int(h.payload)].a.cgPoint, CGPoint(x: 0, y: 0))
    }

    // MARK: - STRETCH: caughtGrips + applyStretch

    func testCaughtGripsOnlyCatchesGripsInsideTheCrossingWindow() {
        let store = makeStore()
        let id = store.append(EntityPrototype(type: .lwpolyline, layerId: 0,
            payload: .polyline(PolylinePayload(closed: true),
                               vertices: [Vec3(x: 0, y: 0), Vec3(x: 10, y: 0), Vec3(x: 10, y: 10), Vec3(x: 0, y: 10)],
                               bulges: [0, 0, 0, 0])))
        // Window only covers the right two corners (10,0) and (10,10).
        let window = CGRect(x: 8, y: -1, width: 4, height: 12)
        let caught = GripEditing.caughtGrips(ids: [id], in: store, crossingWindow: window)
        XCTAssertEqual(Set(caught.map(\.gripIndex)), [1, 2])
    }

    func testApplyStretchMovesOnlyCaughtGripsAndKeepsTheRestConnected() throws {
        // THE actual STRETCH scenario: crossing-select the right edge of a
        // square, move it right by 5 — left edge (vertices 0, 3) stays put,
        // right edge (vertices 1, 2) moves, top/bottom edges stretch to
        // connect them (they share the SAME vertex data, so this falls out
        // automatically — no separate "reconnect" step needed).
        let doc = EditableDocument()
        let id = doc.store.append(EntityPrototype(type: .lwpolyline, layerId: 0,
            payload: .polyline(PolylinePayload(closed: true),
                               vertices: [Vec3(x: 0, y: 0), Vec3(x: 10, y: 0), Vec3(x: 10, y: 10), Vec3(x: 0, y: 10)],
                               bulges: [0, 0, 0, 0])))
        let window = CGRect(x: 8, y: -1, width: 4, height: 12)
        let caught = GripEditing.caughtGrips(ids: [id], in: doc.store, crossingWindow: window)
        XCTAssertEqual(caught.count, 2)

        doc.transact("Stretch") { tx in
            GripEditing.applyStretch(caught, delta: CGVector(dx: 5, dy: 0), in: tx)
        }
        let h = try XCTUnwrap(doc.store.header(id))
        let pl = doc.store.polylines[Int(h.payload)]
        let verts = (0..<Int(pl.vertsCount)).map { doc.store.vertexArena[Int(pl.vertsStart) + $0].cgPoint }
        XCTAssertEqual(verts[0], CGPoint(x: 0, y: 0), "left edge vertex must stay put")
        XCTAssertEqual(verts[1], CGPoint(x: 15, y: 0), "caught vertex moved by the delta")
        XCTAssertEqual(verts[2], CGPoint(x: 15, y: 10), "caught vertex moved by the delta")
        XCTAssertEqual(verts[3], CGPoint(x: 0, y: 10), "left edge vertex must stay put")
    }

    func testApplyStretchAcrossMultipleEntitiesMovesEachIndependently() throws {
        let doc = EditableDocument()
        let lineId = doc.store.append(EntityPrototype(type: .line, layerId: 0,
            payload: .line(LinePayload(a: Vec3(x: 0, y: 0), b: Vec3(x: 100, y: 100)))))
        let polyId = doc.store.append(EntityPrototype(type: .lwpolyline, layerId: 0,
            payload: .polyline(PolylinePayload(closed: false),
                               vertices: [Vec3(x: 0, y: 0), Vec3(x: 1, y: 1)], bulges: [0, 0])))
        // Window catches ONLY the line's (0,0) endpoint and the polyline's
        // (0,0) vertex, not their far points.
        let window = CGRect(x: -1, y: -1, width: 2, height: 2)
        let caught = GripEditing.caughtGrips(ids: [lineId, polyId], in: doc.store, crossingWindow: window)
        XCTAssertEqual(caught.count, 2)

        doc.transact("Stretch") { tx in
            GripEditing.applyStretch(caught, delta: CGVector(dx: -1, dy: -1), in: tx)
        }
        let lineHeader = try XCTUnwrap(doc.store.header(lineId))
        let line = doc.store.lines[Int(lineHeader.payload)]
        XCTAssertEqual(line.a.cgPoint, CGPoint(x: -1, y: -1))
        XCTAssertEqual(line.b.cgPoint, CGPoint(x: 100, y: 100), "untouched")

        let polyHeader = try XCTUnwrap(doc.store.header(polyId))
        let pl = doc.store.polylines[Int(polyHeader.payload)]
        let verts = (0..<Int(pl.vertsCount)).map { doc.store.vertexArena[Int(pl.vertsStart) + $0].cgPoint }
        XCTAssertEqual(verts[0], CGPoint(x: -1, y: -1))
        XCTAssertEqual(verts[1], CGPoint(x: 1, y: 1), "untouched")
    }

    func testApplyStretchIsUndoableAsOneStep() throws {
        let doc = EditableDocument()
        let id = doc.store.append(EntityPrototype(type: .lwpolyline, layerId: 0,
            payload: .polyline(PolylinePayload(closed: true),
                               vertices: [Vec3(x: 0, y: 0), Vec3(x: 10, y: 0), Vec3(x: 10, y: 10), Vec3(x: 0, y: 10)],
                               bulges: [0, 0, 0, 0])))
        let window = CGRect(x: 8, y: -1, width: 4, height: 12)
        let caught = GripEditing.caughtGrips(ids: [id], in: doc.store, crossingWindow: window)
        let undoCountBefore = doc.undoStack.count
        doc.transact("Stretch") { tx in
            GripEditing.applyStretch(caught, delta: CGVector(dx: 5, dy: 0), in: tx)
        }
        XCTAssertEqual(doc.undoStack.count, undoCountBefore + 1, "the whole stretch must be ONE undo step")
        doc.undo()
        let h = try XCTUnwrap(doc.store.header(id))
        let pl = doc.store.polylines[Int(h.payload)]
        let verts = (0..<Int(pl.vertsCount)).map { doc.store.vertexArena[Int(pl.vertsStart) + $0].cgPoint }
        XCTAssertEqual(verts[1], CGPoint(x: 10, y: 0))
        XCTAssertEqual(verts[2], CGPoint(x: 10, y: 10))
    }

    // MARK: - HATCH grips (shaded areas: ShadeLayer solid fill + AI aisle/dock shading)
    //
    // A user report ("i would like to extend the length of one of the aisles
    // ... but i am unable to do so") traced to HATCH falling through
    // `grips(for:in:)`'s `default: return []`. Because STRETCH, grip-drag,
    // Add Vertex and grip DISPLAY all funnel through `GripEditing`, a hatch
    // had zero grips and every one of those silently no-op'd — even though
    // it selected, moved, rotated, scaled, mirrored and exploded fine. These
    // tests lock in that a filled area is reshapeable like any other object.

    /// A hatch shaped like one aisle "ribbon" (the exact geometry
    /// `AisleNetwork.ribbon`/`shade_aisle_network` produces): a 4-corner
    /// rectangle, 100 long x 20 wide.
    private func appendRibbonHatch(to store: EntityStore, length: Double = 100,
                                   width: Double = 20) -> EntityID {
        store.append(EntityPrototype(type: .hatch, layerId: 0,
            payload: .hatch(HatchPayload(isSolid: true),
                            loops: [[Vec3(x: 0, y: 0), Vec3(x: length, y: 0),
                                     Vec3(x: length, y: width), Vec3(x: 0, y: width)]])))
    }

    private func hatchLoop0(_ store: EntityStore, _ id: EntityID) throws -> [CGPoint] {
        let h = try XCTUnwrap(store.header(id))
        let hp = store.hatches[Int(h.payload)]
        let range = store.hatchLoopRanges[Int(hp.loopRangeStart)]
        let start = Int(range.vertStart)
        return (0..<Int(range.vertCount)).map { store.vertexArena[start + $0].cgPoint }
    }

    func testHatchIsGripEditable() {
        XCTAssertTrue(GripEditing.isGripEditable(.hatch),
                      "a shaded area must be grip-editable or STRETCH/grip-drag silently do nothing")
    }

    func testHatchHasOneGripPerBoundaryVertex() {
        let store = makeStore()
        let id = appendRibbonHatch(to: store)
        let grips = GripEditing.grips(for: id, in: store)
        XCTAssertEqual(grips.count, 4)
        XCTAssertEqual(grips.map(\.position), [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0),
                                               CGPoint(x: 100, y: 20), CGPoint(x: 0, y: 20)])
        XCTAssertEqual(grips.map(\.index), [0, 1, 2, 3], "flat, contiguous indices")
    }

    func testMultiLoopHatchGripsAreFlattenedContiguously() {
        // A hatch with an island: outer 4-vertex loop + inner 3-vertex loop.
        // Grip indices must run 0..6 across BOTH loops, matching the order
        // `EntityPayloadCopy.hatch(_, loops:)` presents them in.
        let store = makeStore()
        let id = store.append(EntityPrototype(type: .hatch, layerId: 0,
            payload: .hatch(HatchPayload(isSolid: true),
                            loops: [[Vec3(x: 0, y: 0), Vec3(x: 10, y: 0), Vec3(x: 10, y: 10), Vec3(x: 0, y: 10)],
                                    [Vec3(x: 2, y: 2), Vec3(x: 4, y: 2), Vec3(x: 3, y: 4)]])))
        let grips = GripEditing.grips(for: id, in: store)
        XCTAssertEqual(grips.count, 7)
        XCTAssertEqual(grips.map(\.index), [0, 1, 2, 3, 4, 5, 6])
        XCTAssertEqual(grips[4].position, CGPoint(x: 2, y: 2), "index 4 = inner loop's vertex 0")
        XCTAssertEqual(grips[6].position, CGPoint(x: 3, y: 4), "index 6 = inner loop's vertex 2")
    }

    func testHatchLoopIndexResolvesAcrossLoops() {
        let loops = [[Vec3(x: 0, y: 0), Vec3(x: 1, y: 0), Vec3(x: 1, y: 1)],
                     [Vec3(x: 5, y: 5), Vec3(x: 6, y: 5)]]
        XCTAssertEqual(GripEditing.hatchLoopIndex(0, loops: loops)?.loop, 0)
        XCTAssertEqual(GripEditing.hatchLoopIndex(2, loops: loops)?.vertex, 2)
        XCTAssertEqual(GripEditing.hatchLoopIndex(3, loops: loops)?.loop, 1, "index 3 crosses into loop 1")
        XCTAssertEqual(GripEditing.hatchLoopIndex(3, loops: loops)?.vertex, 0)
        XCTAssertNil(GripEditing.hatchLoopIndex(5, loops: loops), "past the end")
        XCTAssertNil(GripEditing.hatchLoopIndex(-1, loops: loops))
    }

    func testMoveGripOnHatchMovesOnlyThatCornerOfTheFill() throws {
        let doc = EditableDocument()
        let id = appendRibbonHatch(to: doc.store)
        doc.transact("Drag corner") { tx in
            GripEditing.moveGrip(id, index: 1, to: CGPoint(x: 140, y: 0), in: tx)
        }
        let loop = try hatchLoop0(doc.store, id)
        XCTAssertEqual(loop[1], CGPoint(x: 140, y: 0), "the dragged corner moved")
        XCTAssertEqual(loop[0], CGPoint(x: 0, y: 0), "untouched")
        XCTAssertEqual(loop[2], CGPoint(x: 100, y: 20), "untouched")
        XCTAssertEqual(loop[3], CGPoint(x: 0, y: 20), "untouched")
    }

    /// THE headline scenario: extend a shaded aisle's length by crossing-
    /// window STRETCHing its end cap — both far corners caught together, so
    /// the ribbon gets longer while its start stays anchored. This is exactly
    /// what the user could not do before hatch grips existed.
    func testStretchExtendsAShadedAisleRibbonsLength() throws {
        let doc = EditableDocument()
        let id = appendRibbonHatch(to: doc.store, length: 100, width: 20)
        // A crossing window over the ribbon's right-hand end cap only.
        let window = CGRect(x: 95, y: -5, width: 20, height: 30)
        let caught = GripEditing.caughtGrips(ids: [id], in: doc.store, crossingWindow: window)
        XCTAssertEqual(caught.count, 2, "the end cap's two corners must both be caught")
        XCTAssertEqual(Set(caught.map(\.gripIndex)), [1, 2])

        doc.transact("Stretch aisle") { tx in
            GripEditing.applyStretch(caught, delta: CGVector(dx: 40, dy: 0), in: tx)
        }
        let loop = try hatchLoop0(doc.store, id)
        XCTAssertEqual(loop[0], CGPoint(x: 0, y: 0), "start of the aisle stays anchored")
        XCTAssertEqual(loop[3], CGPoint(x: 0, y: 20), "start of the aisle stays anchored")
        XCTAssertEqual(loop[1], CGPoint(x: 140, y: 0), "end cap extended by 40")
        XCTAssertEqual(loop[2], CGPoint(x: 140, y: 20), "end cap extended by 40")
    }

    func testStretchOnHatchIsUndoableAsOneStep() throws {
        let doc = EditableDocument()
        let id = appendRibbonHatch(to: doc.store)
        let caught = GripEditing.caughtGrips(ids: [id], in: doc.store,
                                             crossingWindow: CGRect(x: 95, y: -5, width: 20, height: 30))
        let before = doc.undoStack.count
        doc.transact("Stretch aisle") { tx in
            GripEditing.applyStretch(caught, delta: CGVector(dx: 40, dy: 0), in: tx)
        }
        XCTAssertEqual(doc.undoStack.count, before + 1, "extending an aisle must be ONE undo step")
        doc.undo()
        let loop = try hatchLoop0(doc.store, id)
        XCTAssertEqual(loop[1], CGPoint(x: 100, y: 0), "undo restores the original length")
        XCTAssertEqual(loop[2], CGPoint(x: 100, y: 20))
    }

    func testHatchGripPreservesVertexZ() throws {
        let doc = EditableDocument()
        let id = doc.store.append(EntityPrototype(type: .hatch, layerId: 0,
            payload: .hatch(HatchPayload(isSolid: true),
                            loops: [[Vec3(x: 0, y: 0, z: 7), Vec3(x: 10, y: 0, z: 7),
                                     Vec3(x: 10, y: 10, z: 7)]])))
        doc.transact("Drag") { tx in
            GripEditing.moveGrip(id, index: 1, to: CGPoint(x: 20, y: 0), in: tx)
        }
        let h = try XCTUnwrap(doc.store.header(id))
        let hp = doc.store.hatches[Int(h.payload)]
        let range = doc.store.hatchLoopRanges[Int(hp.loopRangeStart)]
        XCTAssertEqual(doc.store.vertexArena[Int(range.vertStart) + 1].z, 7,
                       "a boundary vertex's elevation must survive a grip drag")
    }

    func testHatchPreviewShapeIsAClosedOutline() throws {
        let store = makeStore()
        let id = appendRibbonHatch(to: store)
        let shape = try XCTUnwrap(GripEditing.previewShape(for: id, in: store, gripIndex: 1,
                                                           candidatePosition: CGPoint(x: 140, y: 0)))
        guard case .polyline(let pts, let closed) = shape else {
            return XCTFail("a hatch ghost must preview as a closed polyline outline, got \(shape)")
        }
        XCTAssertTrue(closed)
        XCTAssertEqual(pts.count, 4)
        XCTAssertEqual(pts[1], CGPoint(x: 140, y: 0), "the ghost reflects the dragged corner")
        XCTAssertEqual(pts[2], CGPoint(x: 100, y: 20), "other corners unchanged in the ghost")
    }

    func testHatchStretchPreviewReflectsEveryCaughtCorner() throws {
        let store = makeStore()
        let id = appendRibbonHatch(to: store)
        let shape = try XCTUnwrap(GripEditing.previewStretchShape(for: id, in: store,
                                                                  caughtIndices: [1, 2],
                                                                  delta: CGVector(dx: 40, dy: 0)))
        guard case .polyline(let pts, let closed) = shape else {
            return XCTFail("expected a closed polyline ghost, got \(shape)")
        }
        XCTAssertTrue(closed)
        XCTAssertEqual(pts[1], CGPoint(x: 140, y: 0))
        XCTAssertEqual(pts[2], CGPoint(x: 140, y: 20))
        XCTAssertEqual(pts[0], CGPoint(x: 0, y: 0), "uncaught corner stays put in the ghost")
    }

    func testAddVertexOnHatchInsertsANewCorner() throws {
        let doc = EditableDocument()
        let id = appendRibbonHatch(to: doc.store)
        // Insert a corner midway along the bottom edge (vertex 0 -> 1).
        doc.transact("Add Vertex") { tx in
            GripEditing.addVertex(id, afterIndex: 0, at: CGPoint(x: 50, y: 0), in: tx)
        }
        let loop = try hatchLoop0(doc.store, id)
        XCTAssertEqual(loop.count, 5, "the boundary gained a corner")
        XCTAssertEqual(loop[1], CGPoint(x: 50, y: 0))
        XCTAssertEqual(loop[2], CGPoint(x: 100, y: 0), "the old vertex 1 shifted along")
        // ...and the new corner is itself draggable, which is the point.
        doc.transact("Drag new corner") { tx in
            GripEditing.moveGrip(id, index: 1, to: CGPoint(x: 50, y: -15), in: tx)
        }
        XCTAssertEqual(try hatchLoop0(doc.store, id)[1], CGPoint(x: 50, y: -15))
    }

    func testNearestEdgeOnHatchFindsTheWrapAroundEdge() throws {
        let store = makeStore()
        let id = appendRibbonHatch(to: store)
        // Near the middle of the CLOSING edge (vertex 3 -> vertex 0, the left
        // end cap) — a hatch loop is always closed, so this edge must be a
        // candidate even though there's no explicit `closed` flag to consult.
        let edge = try XCTUnwrap(GripEditing.nearestEdge(of: id, in: store,
                                                         to: CGPoint(x: 0, y: 10), tolerance: 2))
        XCTAssertEqual(edge.afterIndex, 3, "the wrap-around edge starts at the last vertex")
        XCTAssertEqual(edge.point, CGPoint(x: 0, y: 10))
    }

    func testHatchLoopsReadsEveryLoopAndRejectsNonHatch() {
        let store = makeStore()
        let hatchId = store.append(EntityPrototype(type: .hatch, layerId: 0,
            payload: .hatch(HatchPayload(isSolid: true),
                            loops: [[Vec3(x: 0, y: 0), Vec3(x: 1, y: 0), Vec3(x: 1, y: 1)],
                                    [Vec3(x: 5, y: 5), Vec3(x: 6, y: 5), Vec3(x: 6, y: 6)]])))
        let loops = GripEditing.hatchLoops(of: hatchId, in: store)
        XCTAssertEqual(loops.count, 2)
        XCTAssertEqual(loops[1][0], CGPoint(x: 5, y: 5))

        let lineId = store.append(EntityPrototype(type: .line, layerId: 0,
            payload: .line(LinePayload(a: Vec3(x: 0, y: 0), b: Vec3(x: 1, y: 1)))))
        XCTAssertTrue(GripEditing.hatchLoops(of: lineId, in: store).isEmpty,
                      "non-hatch ids must return no loops rather than misreading the payload index")
    }

    func testDeletedHatchHasNoGrips() {
        let doc = EditableDocument()
        let id = appendRibbonHatch(to: doc.store)
        doc.transact("Delete") { tx in tx.delete(id) }
        XCTAssertTrue(GripEditing.grips(for: id, in: doc.store).isEmpty)
    }

    /// A shaded area's Move/Modify GHOST must be visible — the fill itself
    /// can't be represented by `DrawnEntity.Shape`, so it previews as its
    /// boundary outline. Before this, dragging shading showed nothing at all
    /// mid-drag (even though the drop committed), which reads as "broken."
    func testShapeForGhostPreviewsAHatchAsItsClosedBoundary() throws {
        let store = makeStore()
        let id = appendRibbonHatch(to: store)
        let shape = try XCTUnwrap(MarkupStore.shapeForGhost(id: id, store: store))
        guard case .polyline(let pts, let closed) = shape else {
            return XCTFail("expected a closed boundary outline ghost, got \(shape)")
        }
        XCTAssertTrue(closed)
        XCTAssertEqual(pts, [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0),
                             CGPoint(x: 100, y: 20), CGPoint(x: 0, y: 20)])
    }
}
