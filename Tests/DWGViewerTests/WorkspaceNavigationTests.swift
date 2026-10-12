import XCTest
import CADCore
@testable import DWGViewer

final class SheetNavigationContentTests: XCTestCase {
    private func onlyViewport(_ id: Int) throws -> RegenCoordinator {
        let regen = try RegenCoordinator.loadPackage(url: TestFixtures.url("multiple_layouts.dxf"))
        let sheet = try XCTUnwrap(regen.parsed.paperLayouts.first)
        let store = regen.parsed.store
        let ownership = PaperLayoutOwnership(regen.parsed)
        let blocks = Set(sheet.blockNames.compactMap { regen.parsed.blocks[$0]?.blockIndex })
        let tx = regen.parsed.document.begin("Empty sheet fixture")
        for (i, h) in store.headers.enumerated() where
            blocks.contains(h.owner.raw) || (h.owner.isPaper && sheet.contains(EntityID(raw: Int32(i)), in: store, ownership: ownership)) {
            tx.delete(EntityID(raw: Int32(i)))
        }
        let added = tx.add(EntityPrototype(type: .viewport, layerId: 0, owner: .paper,
            payload: .viewport(ViewportPayload(centerPaper: Vec3(x: 0, y: 0), widthPaper: 100, heightPaper: 100,
                viewCenter: Vec3(x: 0, y: 0), viewHeight: 100, viewportID: id))))
        store.residualPairs[added.raw] = RawPairBlob(pairs: [(330, String(sheet.id, radix: 16))])
        regen.parsed.document.commit(tx)
        return regen
    }

    func testDefaultViewportOnlyLayoutIsOmittedButRetainedInDrawing() throws {
        let regen = try onlyViewport(1)
        let count = regen.parsed.store.count
        XCTAssertEqual(regen.navigationPaperLayouts.map(\.name), ["Furniture"])
        XCTAssertEqual(regen.parsed.paperLayouts.map(\.name), ["Construction", "Furniture"])
        XCTAssertEqual(regen.parsed.store.count, count)
    }

    func testActualModelViewportCountsAsSheetContent() throws {
        let regen = try onlyViewport(2)
        XCTAssertEqual(regen.navigationPaperLayouts.map(\.name), ["Construction", "Furniture"])
    }

    @MainActor func testRememberedEmptyLayoutFallsBackToFirstPopulatedSheet() throws {
        let session = DocumentSession()
        session.regen = try onlyViewport(1)
        session.viewSize = CGSize(width: 1000, height: 700)
        let old = DrawingWorkspace(space: "Paper", sheetName: "Construction", zoom: 50,
            centerX: 900, centerY: 900, hiddenLayers: [], lockedLayers: [], hiddenXrefs: [])
        XCTAssertTrue(session.restoreWorkspace(old))
        XCTAssertEqual(session.regen?.parsed.activePaperLayoutID, 0x23)
        XCTAssertEqual(session.viewport.centerX, session.viewBounds.midX, accuracy: 1e-10)
        XCTAssertNotEqual(session.viewport.zoom, old.zoom)
    }

    func testSheetReturnsToNavigationWhenContentIsAdded() throws {
        let regen = try onlyViewport(1)
        XCTAssertEqual(regen.navigationPaperLayouts.count, 1)
        let tx = regen.parsed.document.begin("Add content")
        let id = tx.add(EntityPrototype(type: .line, layerId: 0, owner: .paper,
            payload: .line(LinePayload(a: Vec3(x: 0, y: 0), b: Vec3(x: 10, y: 10)))))
        regen.parsed.store.residualPairs[id.raw] = RawPairBlob(pairs: [(330, "1B")])
        regen.parsed.document.commit(tx)
        XCTAssertEqual(regen.navigationPaperLayouts.map(\.name), ["Construction", "Furniture"])
    }
}

final class SearchViewportTests: XCTestCase {
    func testWideAndTallMatchesTake28PercentOfTheAvailableView() {
        let size = CGSize(width: 1200, height: 800)
        for box in [CGRect(x: 100, y: 200, width: 80, height: 4), CGRect(x: -10, y: 2, width: 4, height: 80)] {
            let hit = SearchHit(id: 0, label: "Match", sublabel: "MText", position: box.origin,
                screenHeightHint: 4, ref: .primitive(group: 0, store: .text, index: 0), isPaper: true, bounds: box)
            let view = SearchFraming.viewport(for: hit, size: size)
            XCTAssertEqual(max(box.width * view.zoom / size.width, box.height * view.zoom / size.height), 0.28, accuracy: 1e-10)
            XCTAssertEqual(view.centerX, box.midX)
            XCTAssertEqual(view.centerY, box.midY)
        }
    }

    @MainActor func testClosingSearchRestoresOriginalCameraSheetAndSelectionAfterResize() throws {
        let session = DocumentSession()
        session.regen = try RegenCoordinator.loadPackage(url: TestFixtures.url("multiple_layouts.dxf"))
        session.viewSize = CGSize(width: 1000, height: 700)
        session.switchSpace(to: .paper, sheetID: 0x23)
        let original = DrawingViewport(zoom: 3.75, centerX: 27, centerY: 11)
        session.restoreViewport(original)
        session.selection = [EntityID(raw: 0)]
        session.beginSearch()
        session.beginSearch() // Re-focusing search must not overwrite its origin.
        session.regen?.selectPaperLayout(0x1B)
        session.space = .model
        session.zoom = 18; session.pan = .zero; session.selection = []
        session.viewSize = CGSize(width: 700, height: 600)
        session.endSearch()
        XCTAssertEqual(session.space, .paper)
        XCTAssertEqual(session.regen?.parsed.activePaperLayoutID, 0x23)
        XCTAssertEqual(session.viewport.zoom, original.zoom)
        XCTAssertEqual(session.viewport.centerX, original.centerX, accuracy: 1e-10)
        XCTAssertEqual(session.viewport.centerY, original.centerY, accuracy: 1e-10)
        XCTAssertEqual(session.selection, [EntityID(raw: 0)])
        XCTAssertFalse(session.searchVisible)
        XCTAssertNil(session.searchOrigin)
    }
}

final class SheetViewportMemoryTests: XCTestCase {
    @MainActor func testEachSheetAndModelKeepIndependentZoomAndPosition() throws {
        let session = DocumentSession()
        session.regen = try RegenCoordinator.loadPackage(url: TestFixtures.url("multiple_layouts.dxf"))
        session.viewSize = CGSize(width: 1000, height: 700)
        let model = DrawingViewport(zoom: 4, centerX: -5, centerY: 20)
        let first = DrawingViewport(zoom: 7, centerX: 12, centerY: 1)
        let second = DrawingViewport(zoom: 2.25, centerX: 26, centerY: -10)
        session.restoreViewport(model)
        session.switchSpace(to: .paper, sheetID: 0x1B); session.restoreViewport(first)
        session.switchSpace(to: .paper, sheetID: 0x23); session.restoreViewport(second)
        session.switchSpace(to: .model)
        XCTAssertEqual(session.viewport, model)
        session.viewSize = CGSize(width: 800, height: 500)
        session.switchSpace(to: .paper)
        XCTAssertEqual(session.viewport, second)
        session.switchSpace(to: .paper, sheetID: 0x1B)
        XCTAssertEqual(session.viewport, first)
        session.switchSpace(to: .paper, sheetID: 0x23)
        XCTAssertEqual(session.viewport, second)
    }

    func testPerSheetViewsRoundTripInWorkspaceRecord() throws {
        let views = ["paper:35": DrawingViewport(zoom: 8, centerX: 30, centerY: 40),
                     "model": DrawingViewport(zoom: 2, centerX: 0, centerY: 0)]
        let record = WorkspaceRecord(sheetViewports: views)
        let restored = try JSONDecoder().decode(WorkspaceRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(restored.sheetViewports, views)
        XCTAssertNil(try JSONDecoder().decode(WorkspaceRecord.self, from: Data(#"{"presets":[]}"#.utf8)).sheetViewports)
    }
}

final class ViewportResizeTests: XCTestCase {
    func testFitFollowsPanelOpenAndCloseIncludingTitleBlockExtents() {
        let drawing = CGRect(x: 100, y: 200, width: 500, height: 250)
        let withTitleBlock = CGRect(x: 100, y: 200, width: 700, height: 400)
        let fullSize = CGSize(width: 1200, height: 800)
        let withPanel = CGSize(width: 900, height: 800)
        for target in [drawing, withTitleBlock] {
            let original = DrawingViewport.fitted(to: target, size: fullSize)
            let resized = original.resized(from: fullSize, to: withPanel, fitBounds: [withTitleBlock, drawing])
            XCTAssertEqual(resized, .fitted(to: target, size: withPanel))
            XCTAssertLessThanOrEqual(target.width * resized.zoom, withPanel.width)
            XCTAssertLessThanOrEqual(target.height * resized.zoom, withPanel.height)
            XCTAssertEqual(resized.resized(from: withPanel, to: fullSize, fitBounds: [withTitleBlock, drawing]), original)
        }
    }

    func testManualZoomAndPanSurvivePanelResize() {
        let bounds = CGRect(x: -100, y: 80, width: 600, height: 300)
        let oldSize = CGSize(width: 1200, height: 800)
        let newSize = CGSize(width: 900, height: 800)
        let fitted = DrawingViewport.fitted(to: bounds, size: oldSize)
        let zoomed = DrawingViewport(zoom: fitted.zoom * 1.7, centerX: fitted.centerX, centerY: fitted.centerY)
        let panned = DrawingViewport(zoom: fitted.zoom, centerX: fitted.centerX + 20, centerY: fitted.centerY - 30)
        for manual in [zoomed, panned] {
            XCTAssertEqual(manual.resized(from: oldSize, to: newSize, fitBounds: [bounds]), manual)
        }
    }

    func testRestoredFitToleratesSmallToolbarSizeChanges() {
        let bounds = CGRect(x: 100, y: 200, width: 700, height: 400)
        let oldSize = CGSize(width: 1200, height: 700)
        let newSize = CGSize(width: 900, height: 700)
        var restored = DrawingViewport.fitted(to: bounds, size: oldSize)
        restored.zoom *= 1.005
        XCTAssertEqual(restored.resized(from: oldSize, to: newSize, fitBounds: [bounds]),
                       .fitted(to: bounds, size: newSize))
    }
}

final class InspectorPlacementTests: XCTestCase {
    func testCardsStayBesideTheirAnchorsAndAboveStatusButtons() {
        let size = CGSize(width: 1000, height: 650)
        let status = CGRect(x: 300, y: 598, width: 700, height: 28)
        let top = CGRect(x: 250, y: 65, width: 130, height: 29)
        let bottom = CGRect(x: 920, y: 600, width: 70, height: 24)
        for anchor in [top, bottom] {
            let frame = InspectorPlacement.frame(anchor: anchor, size: CGSize(width: 390, height: 300), container: size, statusBar: status)
            XCTAssertTrue(CGRect(origin: .zero, size: size).contains(frame))
            XCTAssertFalse(frame.intersects(status))
            XCTAssertFalse(frame.intersects(anchor))
            if anchor == top { XCTAssertEqual(frame.minY, top.maxY + 8) }
            else { XCTAssertLessThan(frame.maxY, status.minY) }
        }
    }
}
