import XCTest
import SwiftUI
import CADCore
@testable import DWGViewer

final class ReviewCorrectionsTests: XCTestCase {
    func testStaleLayoutNameUsesOwnerForBothNavigationAndRendering() throws {
        let regen = try RegenCoordinator.loadPackage(url: TestFixtures.url("multiple_layouts.dxf"))
        let id = try XCTUnwrap(regen.parsed.store.entity(forHandle: 0x202))
        regen.parsed.store.residualPairs[id.raw] = RawPairBlob(pairs: [(410, "Old layout name"), (330, "1B")])
        let ownership = PaperLayoutOwnership(regen.parsed)
        XCTAssertEqual(ownership.ownerSheetID(for: id, in: regen.parsed.store), 0x1B)
        XCTAssertTrue(PaperLayout.navigableSheets(in: regen.parsed).contains { $0.id == 0x1B })
        regen.fullRebuild()
        XCTAssertEqual(regen.document.paperBounds.minX, 10)
        XCTAssertEqual(regen.document.paperBounds.maxX, 11)
    }

    func testOwnershipPrecedenceAndUnknownOwnerDoNotLeakAcrossSheets() throws {
        let parsed = try EntityStoreParser.parse(url: TestFixtures.url("multiple_layouts.dxf"))
        let id = try XCTUnwrap(parsed.store.entity(forHandle: 0x202))
        let ownership = PaperLayoutOwnership(parsed)
        let cases: [([(code: Int16, value: String)], UInt64?)] = [
            ([(410, "fUrNiTuRe"), (330, "1B")], 0x23),
            ([(410, "Stale"), (330, "23")], 0x23),
            ([(410, "Stale"), (330, "DEADBEEF")], nil),
            ([(102, "{ACAD_REACTORS"), (330, "DEADBEEF"), (102, "}"), (330, "1B")], 0x1B),
            ([], 0x1B)
        ]
        for (pairs, expected) in cases {
            parsed.store.residualPairs[id.raw] = RawPairBlob(pairs: pairs)
            XCTAssertEqual(ownership.ownerSheetID(for: id, in: parsed.store), expected)
            for sheet in ownership.sheets {
                XCTAssertEqual(sheet.contains(id, in: parsed.store, ownership: ownership), sheet.id == expected)
            }
        }
    }

    func testFrozenAndInvisibleContentStillCountsForNavigation() throws {
        let parsed = try EntityStoreParser.parse(url: TestFixtures.url("multiple_layouts.dxf"))
        parsed.layers[0].isFrozen = true
        parsed.layers[0].isOffByDefault = true
        for i in parsed.store.headers.indices {
            parsed.store.setHeader(EntityID(raw: Int32(i))) { $0.flags.insert(.invisible) }
        }
        XCTAssertEqual(PaperLayout.navigableSheets(in: parsed).map(\.name), ["Construction", "Furniture"])
    }

    func testPackageLoadSeedsNavigationCacheAndCommittedEditsInvalidateIt() throws {
        let regen = try RegenCoordinator.loadPackage(url: TestFixtures.url("multiple_layouts.dxf"))
        let cache = try XCTUnwrap(regen.navigationSheetsCache)
        XCTAssertEqual(cache.0, regen.parsed.document.revision)
        XCTAssertEqual(cache.1, regen.parsed.store.count)
        XCTAssertEqual(cache.2, regen.navigationPaperLayouts)
        regen.parsed.document.transact("Remove fixture content") { tx in
            for i in regen.parsed.store.headers.indices { tx.delete(EntityID(raw: Int32(i))) }
        }
        XCTAssertTrue(regen.navigationPaperLayouts.isEmpty)
        XCTAssertNotEqual(regen.navigationSheetsCache?.0, cache.0)
    }

    func testLegacyWorkspaceLoadsAndResavesAllExistingFields() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let drawing = URL(fileURLWithPath: "/fixtures/legacy.dwg")
        let json = #"{"lastView":{"space":"Paper","sheetName":"Furniture","zoom":3.5,"centerX":12,"centerY":-8,"hiddenLayers":["HIDDEN"],"lockedLayers":["LOCKED"],"hiddenXrefs":["BASE"]},"resourceDirectories":["file:///fixtures/resources/"],"presets":[{"id":"D1313CF0-461D-40CA-9B16-F1735EF68A3C","name":"Review","workspace":{"space":"Model","zoom":2,"centerX":4,"centerY":6,"hiddenLayers":[],"lockedLayers":[],"hiddenXrefs":[]}}]}"#
        try Data(json.utf8).write(to: directory.appendingPathComponent(WorkspaceStore.key(for: drawing) + ".json"))
        var record = WorkspaceStore.load(drawing, directory: directory)
        let view = try XCTUnwrap(record.lastView)
        let resources = try XCTUnwrap(record.resourceDirectories)
        let preset = try XCTUnwrap(record.presets.first)
        XCTAssertNil(record.sheetViewports)
        XCTAssertEqual(view.zoom, 3.5)
        XCTAssertEqual(view.hiddenLayers, ["HIDDEN"])
        record.sheetViewports = ["model": DrawingViewport(zoom: 2, centerX: 4, centerY: 6)]
        try WorkspaceStore.save(record, for: drawing, directory: directory)
        let restored = WorkspaceStore.load(drawing, directory: directory)
        XCTAssertEqual(restored.lastView, view)
        XCTAssertEqual(restored.resourceDirectories, resources)
        XCTAssertEqual(restored.presets.first?.id, preset.id)
        XCTAssertEqual(restored.presets.first?.name, "Review")
        XCTAssertEqual(restored.presets.first?.workspace, preset.workspace)
        XCTAssertEqual(restored.sheetViewports, record.sheetViewports)
    }

    func testResizePriorityPreservesPendingRestoreBeforeSearchAndFirstFit() {
        let full = CGSize(width: 800, height: 600)
        func action(_ old: CGSize, _ pending: Bool, _ searching: Bool, _ match: Bool) -> CanvasResizeAction {
            .decide(previous: old, next: full, hasPendingWorkspace: pending, searchVisible: searching, hasSearchMatch: match)
        }
        XCTAssertEqual(action(.zero, true, true, true), .restoreWorkspace)
        XCTAssertEqual(action(.zero, false, true, true), .frameSearchMatch)
        XCTAssertEqual(action(.zero, false, true, false), .initialFit)
        XCTAssertEqual(action(full, false, true, false), .resizeViewport)
        XCTAssertEqual(action(full, false, false, true), .resizeViewport)
        XCTAssertEqual(action(CGSize(width: 800, height: 0), false, false, false), .initialFit)
        XCTAssertEqual(CanvasResizeAction.decide(previous: full, next: .zero,
            hasPendingWorkspace: true, searchVisible: true, hasSearchMatch: true), .waitForSize)
    }

    /// Exercise the actual SwiftUI preference propagation, including both the
    /// parent transform and sibling reduce calls. No fabricated Anchor values.
    @MainActor func testStatusBarAnchorPreservesBothChildButtonAnchors() async throws {
        let delivered = expectation(description: "Anchors resolved")
        delivered.assertForOverFulfill = false
        var resolved: [WorkspaceAnchor: CGRect] = [:]
        let probe = GeometryReader { proxy in
            HStack {
                Color.clear.frame(width: 60, height: 24).workspaceAnchor(.button(.issues))
                Color.clear.frame(width: 80, height: 24).workspaceAnchor(.button(.quality))
            }.workspaceAnchor(.statusBar)
                .overlayPreferenceValue(WorkspaceAnchorPreference.self) { anchors in
                    Color.clear.onAppear {
                        resolved = anchors.mapValues { proxy[$0] }
                        delivered.fulfill()
                    }
                }
        }
        let host = NSHostingView(rootView: probe)
        host.frame = CGRect(x: 0, y: 0, width: 400, height: 200)
        host.layoutSubtreeIfNeeded()
        await fulfillment(of: [delivered], timeout: 2)
        let status = try XCTUnwrap(resolved[.statusBar])
        XCTAssertEqual(resolved.count, 3)
        XCTAssertTrue(status.contains(try XCTUnwrap(resolved[.button(.issues)])))
        XCTAssertTrue(status.contains(try XCTUnwrap(resolved[.button(.quality)])))
        withExtendedLifetime(host) {}
    }

    func testSmallInspectorViewportKeepsStatusControlsClear() {
        let container = CGSize(width: 300, height: 200)
        let status = CGRect(x: 0, y: 174, width: 300, height: 26)
        let frame = InspectorPlacement.frame(anchor: status, size: CGSize(width: 390, height: 700),
            container: container, statusBar: status)
        XCTAssertTrue(CGRect(origin: .zero, size: container).contains(frame))
        XCTAssertFalse(frame.intersects(status))
        XCTAssertLessThan(frame.height, 700) // AnchoredInspector scrolls this smaller viewport.
    }

    @MainActor func testOversizedInspectorCanScrollToItsBottomAndRightEdge() async throws {
        let host = NSHostingView(rootView: AnchoredInspector(anchor: CGRect(x: 250, y: 175, width: 40, height: 20),
            container: CGSize(width: 300, height: 220), statusBar: CGRect(x: 0, y: 180, width: 300, height: 40)) {
                Color.blue.frame(width: 390, height: 700)
            })
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 220),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.frame = CGRect(x: 0, y: 0, width: 300, height: 220)
        host.layoutSubtreeIfNeeded()
        // Allow the content-size preference to update the scroll viewport.
        try await Task.sleep(for: .milliseconds(60))
        host.layoutSubtreeIfNeeded()
        func scrollView(in view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
        }
        let scroll = try XCTUnwrap(scrollView(in: host))
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertGreaterThan(document.frame.width, scroll.contentSize.width)
        XCTAssertGreaterThan(document.frame.height, scroll.contentSize.height)
        let maxX = document.frame.width - scroll.contentSize.width
        let maxY = document.frame.height - scroll.contentSize.height
        scroll.contentView.scroll(to: CGPoint(x: maxX, y: maxY))
        scroll.reflectScrolledClipView(scroll.contentView)
        XCTAssertEqual(scroll.contentView.bounds.maxX, document.frame.maxX, accuracy: 1)
        XCTAssertEqual(scroll.contentView.bounds.maxY, document.frame.maxY, accuracy: 1)
    }
}
