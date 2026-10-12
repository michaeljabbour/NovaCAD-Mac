import XCTest
import CADCore
@testable import DWGViewer

final class WorkspaceRecoveryTests: XCTestCase {
    func testWorkspacesArePerFileAndCorruptRecordsAreIgnored() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = URL(fileURLWithPath: "/one/plan.dwg"), b = URL(fileURLWithPath: "/two/plan.dwg")
        let view = DrawingWorkspace(space: "Paper", sheetName: "Furniture", zoom: 2, centerX: 10, centerY: 30,
                                    hiddenLayers: ["МЕБЕЛЬ"], lockedLayers: ["0"], hiddenXrefs: [])
        let record = WorkspaceRecord(lastView: view, presets: [WorkspacePreset(name: "Review", workspace: view)])
        try WorkspaceStore.save(record, for: a, directory: dir)
        XCTAssertEqual(WorkspaceStore.load(a, directory: dir).lastView, view)
        XCTAssertEqual(WorkspaceStore.load(a, directory: dir).presets.first?.name, "Review")
        XCTAssertNil(WorkspaceStore.load(b, directory: dir).lastView)
        try Data("broken".utf8).write(to: dir.appendingPathComponent(WorkspaceStore.key(for: a) + ".json"))
        XCTAssertNil(WorkspaceStore.load(a, directory: dir).lastView)
    }

    @MainActor func testRestoreWorkspaceUsesNamesAndCameraSurvivesResize() throws {
        let session = DocumentSession()
        session.regen = try RegenCoordinator.loadPackage(url: TestFixtures.url("multiple_layouts.dxf"))
        session.viewSize = CGSize(width: 1000, height: 600)
        let view = DrawingWorkspace(space: "Paper", sheetName: "Furniture", zoom: 2, centerX: 25, centerY: 15,
                                    hiddenLayers: ["0", "Removed"], lockedLayers: ["0"], hiddenXrefs: [])
        XCTAssertTrue(session.restoreWorkspace(view))
        XCTAssertEqual(session.regen?.parsed.activePaperLayoutID, 0x23)
        XCTAssertEqual(session.visibility.hiddenLayerIds, [0])
        let first = try XCTUnwrap(session.captureWorkspace())
        XCTAssertEqual(first.centerX, 25, accuracy: 1e-8)
        session.viewSize = CGSize(width: 800, height: 400)
        XCTAssertTrue(session.restoreWorkspace(first))
        XCTAssertEqual(session.captureWorkspace()?.centerX, first.centerX)
        XCTAssertEqual(session.captureWorkspace()?.centerY, first.centerY)
        var invalid = view; invalid.zoom = .nan
        XCTAssertFalse(session.restoreWorkspace(invalid))
    }

    func testDetachedSnapshotDoesNotFollowFurtherEdits() throws {
        let parsed = try EntityStoreParser.parse(url: TestFixtures.url("multiple_layouts.dxf"))
        let snapshot = parsed.detachedSnapshot()
        let before = snapshot.store.count
        _ = parsed.store.append(EntityPrototype(type: .line, layerId: 0, owner: .model,
            payload: .line(LinePayload(a: Vec3(x: 100, y: 0), b: Vec3(x: 200, y: 0)))))
        parsed.blocks["*Paper_Space"]?.name = "Changed"
        _ = parsed.store.strings.intern("new string after snapshot")
        XCTAssertEqual(snapshot.store.count, before)
        XCTAssertNotEqual(snapshot.blocks["*Paper_Space"]?.name, "Changed")
        XCTAssertNotEqual(snapshot.store.strings.strings, parsed.store.strings.strings)
    }

    func testRecoveryKeepsSheetsAndNeverTouchesSource() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = TestFixtures.url("multiple_layouts.dxf")
        let original = try Data(contentsOf: source)
        let parsed = try EntityStoreParser.parse(url: source)
        parsed.activePaperLayoutID = 0x23
        let id = UUID()
        var entry = RecoveryEntry(id: id, sourceURL: source, savedAt: Date(), snapshotName: "first.dxf",
                                  workspace: nil, resourceDirectories: parsed.resourceDirectories, warnings: [])
        try RecoveryStore.write(parsed, entry: entry, directory: root)
        XCTAssertEqual(RecoveryStore.entries(directory: root).count, 1)
        let recovered = try RegenCoordinator.loadPackage(url: root.appendingPathComponent("first.dxf"))
        XCTAssertEqual(recovered.parsed.paperLayouts.count, 2)
        recovered.selectPaperLayout(0x23)
        XCTAssertEqual(recovered.document.paperBounds.maxX, 27)
        entry.snapshotName = "second.dxf"
        try RecoveryStore.write(parsed, entry: entry, directory: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("first.dxf").path))
        XCTAssertEqual(try Data(contentsOf: source), original)
        RecoveryStore.discard(id, directory: root)
        XCTAssertTrue(RecoveryStore.entries(directory: root).isEmpty)
    }

    func testLayerUsageChangesWhenSheetChanges() throws {
        let regen = try RegenCoordinator.loadPackage(url: TestFixtures.url("multiple_layouts.dxf"))
        let a = LayerUsage.summary(document: regen.document, paper: true)
        regen.selectPaperLayout(0x23)
        let b = LayerUsage.summary(document: regen.document, paper: true)
        XCTAssertEqual(a[0]?.bounds.minX, 10)
        XCTAssertEqual(b[0]?.bounds.minX, 20)
        XCTAssertNotEqual(a[0]?.count, b[0]?.count)
    }
}
