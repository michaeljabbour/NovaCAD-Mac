import XCTest
import CADCore
@testable import DWGViewer

final class AIViewportTests: XCTestCase {
    func testCanvasBoundsFollowZoomPanAndAvailableCanvasSize() throws {
        let size = CGSize(width: 800, height: 600)
        let view = DrawingViewport.capture(zoom: 2, pan: CGSize(width: 300, height: 400),
            size: size, bounds: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertEqual(view.centerX, 100)
        XCTAssertEqual(view.centerY, 100)
        XCTAssertEqual(view.visibleBounds(size: size), CGRect(x: -100, y: -50, width: 400, height: 300))
        XCTAssertEqual(view.visibleBounds(size: CGSize(width: 400, height: 600))?.width, 200)
        XCTAssertNil(view.visibleBounds(size: .zero))
        XCTAssertNil(DrawingViewport(zoom: 0, centerX: 0, centerY: 0).visibleBounds(size: size))
        XCTAssertNil(DrawingViewport(zoom: .nan, centerX: 0, centerY: 0).visibleBounds(size: size))
    }

    @MainActor func testViewportQueriesReadLivePanAndLayerVisibilityAndIntersectTextBounds() throws {
        let parsed = EditableParsedDocument()
        parsed.layers = [DXFLayer(id: 0, name: "Annotations")]
        parsed.document.transact("Fixture") { tx in
            for (x, label) in [(0.0, "Visible glass wall"), (500.0, "Distant kitchen")] {
                let string = parsed.store.strings.intern(label)
                _ = tx.add(EntityPrototype(type: .text, layerId: 0, owner: .model,
                    payload: .text(TextPayload(position: Vec3(x: x, y: 0), height: 10, stringId: string))))
            }
        }
        let regen = RegenCoordinator(parsed: parsed, document: Regenerator.build(from: parsed, parseSeconds: 0) { _ in })
        // Text insertion point is offscreen, but its actual text bounds cross the edge.
        var bounds = CGRect(x: 5, y: -20, width: 150, height: 50)
        var visibility = VisibilityState()
        let executor = AIToolExecutor(regen: regen, visibility: visibility,
            selectionProvider: { [] }, spaceProvider: { .model }, viewportProvider: { bounds },
            visibilityProvider: { visibility })
        func labels() throws -> [String] {
            let result = try json(executor.execute(tool: "query_entities", arguments: ["visibleOnly": true, "types": ["text"]]))
            return (result["rows"] as? [[String: Any]])?.compactMap { $0["text"] as? String } ?? []
        }
        XCTAssertEqual(try labels(), ["Visible glass wall"])
        let context = try json(executor.workspaceContext())
        let viewport = try XCTUnwrap(context["viewport"] as? [String: Any])
        XCTAssertEqual(viewport["selectedObjectCount"] as? Int, 0)
        XCTAssertEqual(viewport["minX"] as? Double, 5)
        XCTAssertEqual((viewport["visibleText"] as? [String: Any])?["totalMatched"] as? Int, 1)
        bounds = CGRect(x: 490, y: -20, width: 180, height: 50)
        XCTAssertEqual(try labels(), ["Distant kitchen"])
        visibility.hiddenLayerIds = [0]
        XCTAssertEqual(try labels(), [])
        XCTAssertEqual((try json(executor.workspaceContext())["viewport"] as? [String: Any])?["selectedObjectCount"] as? Int, 0)
        bounds = .infinite
        XCTAssertThrowsError(try labels())
    }

    @MainActor func testVisibleGeometryIncludesBoundaryLinesAndPagesWithoutOffscreenObjects() throws {
        let parsed = EditableParsedDocument()
        parsed.layers = [DXFLayer(id: 0, name: "New walls")]
        parsed.document.transact("Fixture") { tx in
            for x in [0.0, 5, 500] {
                _ = tx.add(EntityPrototype(type: .line, layerId: 0, owner: .model,
                    payload: .line(LinePayload(a: Vec3(x: x, y: 0), b: Vec3(x: x, y: 10)))))
            }
            _ = tx.add(EntityPrototype(type: .arc, layerId: 0, owner: .model,
                payload: .arc(ArcPayload(center: Vec3(x: 5, y: 5), radius: 2, startAngleDeg: 0, endAngleDeg: 90))))
        }
        let regen = RegenCoordinator(parsed: parsed, document: Regenerator.build(from: parsed, parseSeconds: 0) { _ in })
        let executor = AIToolExecutor(regen: regen, visibility: VisibilityState(), spaceProvider: { .model },
            viewportProvider: { CGRect(x: 0, y: 0, width: 10, height: 10) })
        var ids = Set<Int>()
        for offset in 0..<3 {
            let result = try json(executor.execute(tool: "query_entities", arguments: ["visibleOnly": true, "limit": 1, "offset": offset]))
            XCTAssertEqual(result["totalMatched"] as? Int, 3)
            let row = try XCTUnwrap((result["rows"] as? [[String: Any]])?.first)
            XCTAssertTrue(ids.insert(try XCTUnwrap(row["entityId"] as? Int)).inserted)
        }
        let arcs = try json(executor.execute(tool: "query_entities", arguments: ["visibleOnly": true, "types": ["arc"]]))
        XCTAssertEqual(arcs["totalMatched"] as? Int, 1)
        XCTAssertEqual((arcs["rows"] as? [[String: Any]])?.first?["layer"] as? String, "New walls")
        let textFilter = try json(executor.execute(tool: "query_entities", arguments: ["visibleOnly": true, "textContains": "glass"]))
        XCTAssertEqual(textFilter["totalMatched"] as? Int, 0)
    }

    @MainActor func testViewportRejectsOtherSheetsAndUnavailableCanvas() throws {
        let regen = try RegenCoordinator.loadPackage(url: TestFixtures.url("multiple_layouts.dxf"))
        let executor = AIToolExecutor(regen: regen, visibility: VisibilityState(), spaceProvider: { .paper },
            viewportProvider: { CGRect(x: 0, y: 0, width: 100, height: 100) })
        XCTAssertThrowsError(try executor.execute(tool: "query_entities", arguments: ["visibleOnly": true, "space": "model"]))
        XCTAssertThrowsError(try executor.execute(tool: "query_entities", arguments: ["visibleOnly": true, "sheetName": "Furniture"]))
        XCTAssertNoThrow(try executor.execute(tool: "query_entities", arguments: ["visibleOnly": true, "sheetName": "Construction"]))
        let headless = AIToolExecutor(regen: regen, visibility: VisibilityState())
        XCTAssertThrowsError(try headless.execute(tool: "query_entities", arguments: ["visibleOnly": true]))
        XCTAssertEqual(try json(headless.workspaceContext())["viewportUnavailable"] as? Bool, true)
    }

    private func json(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
}
