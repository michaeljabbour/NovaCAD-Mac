import XCTest
import CADCore
@testable import DWGViewer

final class PaperLayoutTests: XCTestCase {
    private func load() throws -> RegenCoordinator {
        try RegenCoordinator.loadPackage(url: TestFixtures.url("multiple_layouts.dxf"))
    }

    func testSheetsDoNotOverlayAndModelIsUnchanged() throws {
        let regen = try load()
        XCTAssertEqual(regen.parsed.paperLayouts.map(\.name), ["Construction", "Furniture"])
        XCTAssertEqual(regen.document.paperBounds.minX, 10)
        XCTAssertEqual(regen.document.paperBounds.maxX, 11)
        let modelBounds = regen.document.modelBounds
        let count = regen.parsed.store.count
        let revision = regen.revision
        regen.selectPaperLayout(0x23)
        XCTAssertEqual(regen.document.paperBounds.minX, 20)
        XCTAssertEqual(regen.document.paperBounds.maxX, 27)
        XCTAssertEqual(regen.document.modelBounds, modelBounds)
        XCTAssertEqual(regen.parsed.store.count, count)
        XCTAssertGreaterThan(regen.revision, revision)
        regen.selectPaperLayout(0x1B)
        XCTAssertEqual(regen.document.paperBounds.maxX, 11)
    }

    func testReactorHandleIsNotMistakenForLayoutOwner() throws {
        let regen = try load()
        let id = try XCTUnwrap(regen.parsed.store.entity(forHandle: 0x202))
        XCTAssertEqual(regen.parsed.store.residualPairs[id.raw]?.pairs.first(where: { $0.code == 330 })?.value, "1B")
    }

    func testAllSheetsSurviveSaveWhileOneIsSelected() throws {
        let regen = try load()
        regen.selectPaperLayout(0x23)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("sheets-\(UUID()).dxf")
        defer { try? FileManager.default.removeItem(at: output) }
        try DXFStructuralWriter.write(regen.parsed, to: output)
        let restored = try RegenCoordinator.loadPackage(url: output)
        XCTAssertEqual(restored.parsed.paperLayouts.map(\.name), ["Construction", "Furniture"])
        XCTAssertEqual(restored.document.paperBounds.minX, 10)
        restored.selectPaperLayout(0x23)
        XCTAssertEqual(restored.document.paperBounds.minX, 20)
        XCTAssertEqual(restored.document.paperBounds.maxX, 27)
    }

    func testNewPaperGeometryStaysOnItsSheetAfterSwitchAndSave() throws {
        let regen = try load()
        regen.selectPaperLayout(0x23)
        let tx = regen.parsed.document.begin("Paper markup")
        _ = tx.add(EntityPrototype(type: .line, layerId: 0, owner: .paper,
                                  payload: .line(LinePayload(a: Vec3(x: 30, y: 1), b: Vec3(x: 31, y: 2)))))
        regen.parsed.document.commit(tx)
        regen.apply(try XCTUnwrap(regen.parsed.document.undoStack.last).ops)
        XCTAssertEqual(regen.document.paperBounds.maxX, 31)
        regen.selectPaperLayout(0x1B)
        XCTAssertEqual(regen.document.paperBounds.maxX, 11)
        regen.selectPaperLayout(0x23)
        XCTAssertEqual(regen.document.paperBounds.maxX, 31)
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("sheet-edit-\(UUID()).dxf")
        defer { try? FileManager.default.removeItem(at: output) }
        try DXFStructuralWriter.write(regen.parsed, to: output)
        let restored = try RegenCoordinator.loadPackage(url: output)
        XCTAssertEqual(restored.document.paperBounds.maxX, 11)
        restored.selectPaperLayout(0x23)
        XCTAssertEqual(restored.document.paperBounds.maxX, 31)
    }
}
