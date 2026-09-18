import XCTest
@testable import DWGViewer
import CADCore

/// Phase 1.7: round-trip correctness for the DrawnEntity <-> EntityStore
/// markup conversion — the mechanism that lets markup live as ordinary
/// EntityStore entities (per the plan's "markup unification") while
/// `DXFWriter`'s existing [DrawnEntity]-based export functions, and
/// `ReloadSnapshot`'s reload-preservation, keep working unchanged.
final class MarkupStoreTests: XCTestCase {

    private func makeStore() -> EntityStore { EntityStore() }

    private func roundTrip(_ e: DrawnEntity, layerId: Int32 = 5) -> DrawnEntity? {
        let store = makeStore()
        let proto = MarkupStore.prototype(for: e, layerId: layerId, store: store)
        _ = store.append(proto)
        let back = MarkupStore.drawnEntities(in: store, layerId: layerId)
        return back.first
    }

    func testLineRoundTrips() {
        let e = DrawnEntity(shape: .line(a: CGPoint(x: 1, y: 2), b: CGPoint(x: 30, y: 40)))
        guard let back = roundTrip(e) else { return XCTFail("expected one entity back") }
        guard case .line(let a, let b) = back.shape else { return XCTFail("expected .line") }
        XCTAssertEqual(a, CGPoint(x: 1, y: 2))
        XCTAssertEqual(b, CGPoint(x: 30, y: 40))
    }

    func testOpenPolylineRoundTrips() {
        let pts = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10)]
        let e = DrawnEntity(shape: .polyline(pts: pts, closed: false))
        guard let back = roundTrip(e) else { return XCTFail("expected one entity back") }
        guard case .polyline(let outPts, let closed) = back.shape else { return XCTFail("expected .polyline") }
        XCTAssertEqual(outPts, pts)
        XCTAssertFalse(closed)
    }

    func testClosedPolylineRoundTrips() {
        let pts = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10), CGPoint(x: 0, y: 10)]
        let e = DrawnEntity(shape: .polyline(pts: pts, closed: true))
        guard let back = roundTrip(e) else { return XCTFail("expected one entity back") }
        guard case .polyline(let outPts, let closed) = back.shape else { return XCTFail("expected .polyline") }
        XCTAssertEqual(outPts, pts)
        XCTAssertTrue(closed)
    }

    func testCircleRoundTrips() {
        let e = DrawnEntity(shape: .circle(center: CGPoint(x: 5, y: 5), radius: 12.5))
        guard let back = roundTrip(e) else { return XCTFail("expected one entity back") }
        guard case .circle(let c, let r) = back.shape else { return XCTFail("expected .circle") }
        XCTAssertEqual(c, CGPoint(x: 5, y: 5))
        XCTAssertEqual(r, 12.5)
    }

    func testArcRoundTrips() {
        let e = DrawnEntity(shape: .arc(center: CGPoint(x: 1, y: 1), radius: 7, startDeg: 10, endDeg: 190))
        guard let back = roundTrip(e) else { return XCTFail("expected one entity back") }
        guard case .arc(let c, let r, let s, let en) = back.shape else { return XCTFail("expected .arc") }
        XCTAssertEqual(c, CGPoint(x: 1, y: 1))
        XCTAssertEqual(r, 7)
        XCTAssertEqual(s, 10, accuracy: 1e-9)
        XCTAssertEqual(en, 190, accuracy: 1e-9)
    }

    /// `.rect` isn't a distinct DXFEntityType — it's stored (and read back)
    /// as a closed 4-vertex polyline, which is behaviorally identical for
    /// every downstream consumer (export, reload, hit-test, OSNAP).
    func testRectRoundTripsAsClosedPolyline() {
        let e = DrawnEntity(shape: .rect(a: CGPoint(x: 0, y: 0), b: CGPoint(x: 10, y: 20)))
        guard let back = roundTrip(e) else { return XCTFail("expected one entity back") }
        guard case .polyline(let pts, let closed) = back.shape else { return XCTFail("expected .polyline") }
        XCTAssertTrue(closed)
        let expected = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0),
                        CGPoint(x: 10, y: 20), CGPoint(x: 0, y: 20)]
        XCTAssertEqual(pts.count, expected.count)
        for p in expected { XCTAssertTrue(pts.contains(p), "missing corner \(p)") }
    }

    func testTextRoundTrips() {
        let e = DrawnEntity(shape: .text(position: CGPoint(x: 3, y: 4), height: 2.5, string: "Hello world"))
        guard let back = roundTrip(e) else { return XCTFail("expected one entity back") }
        guard case .text(let pos, let h, let str) = back.shape else { return XCTFail("expected .text") }
        XCTAssertEqual(pos, CGPoint(x: 3, y: 4))
        XCTAssertEqual(h, 2.5)
        XCTAssertEqual(str, "Hello world")
    }

    func testColorAndPaperFlagRoundTrip() {
        var e = DrawnEntity(shape: .line(a: .zero, b: CGPoint(x: 1, y: 1)))
        e.aci = 3
        e.isPaper = true
        guard let back = roundTrip(e) else { return XCTFail("expected one entity back") }
        XCTAssertEqual(back.aci, 3)
        XCTAssertTrue(back.isPaper)
    }

    func testModelSpaceEntityIsNotPaper() {
        var e = DrawnEntity(shape: .line(a: .zero, b: CGPoint(x: 1, y: 1)))
        e.isPaper = false
        guard let back = roundTrip(e) else { return XCTFail("expected one entity back") }
        XCTAssertFalse(back.isPaper)
    }

    /// Deleted markup entities must not resurrect on export/reload-capture.
    func testDeletedMarkupEntityIsExcluded() {
        let store = makeStore()
        let layerId: Int32 = 5
        let proto = MarkupStore.prototype(for: DrawnEntity(shape: .circle(center: .zero, radius: 1)),
                                          layerId: layerId, store: store)
        let id = store.append(proto)
        store.markDeleted(id)
        XCTAssertTrue(MarkupStore.drawnEntities(in: store, layerId: layerId).isEmpty)
    }

    /// Entities on a DIFFERENT layer must not be picked up as markup, even if
    /// their type matches something `prototype(for:)` could have produced —
    /// export/reload-capture must only ever touch the markup layer.
    func testEntityOnDifferentLayerIsExcluded() {
        let store = makeStore()
        let markupLayer: Int32 = 5
        let otherLayer: Int32 = 2
        _ = store.append(MarkupStore.prototype(for: DrawnEntity(shape: .circle(center: .zero, radius: 1)),
                                               layerId: otherLayer, store: store))
        XCTAssertTrue(MarkupStore.drawnEntities(in: store, layerId: markupLayer).isEmpty)
    }

    /// Multiple markup entities preserve insertion order and each other's
    /// independent geometry/color — a stamped batch or a multi-entity
    /// polyline session should read back exactly as drawn.
    func testMultipleEntitiesRoundTripIndependently() {
        let store = makeStore()
        let layerId: Int32 = 5
        var e1 = DrawnEntity(shape: .line(a: .zero, b: CGPoint(x: 1, y: 1)))
        e1.aci = 1
        var e2 = DrawnEntity(shape: .circle(center: CGPoint(x: 5, y: 5), radius: 2))
        e2.aci = 3
        _ = store.append(MarkupStore.prototype(for: e1, layerId: layerId, store: store))
        _ = store.append(MarkupStore.prototype(for: e2, layerId: layerId, store: store))
        let back = MarkupStore.drawnEntities(in: store, layerId: layerId)
        XCTAssertEqual(back.count, 2)
        guard case .line = back[0].shape else { return XCTFail("expected first entity to be .line") }
        guard case .circle = back[1].shape else { return XCTFail("expected second entity to be .circle") }
        XCTAssertEqual(back[0].aci, 1)
        XCTAssertEqual(back[1].aci, 3)
    }

    // MARK: - ensureMarkupLayer

    func testEnsureMarkupLayerCreatesLayerOnce() throws {
        let parsed = try EntityStoreParser.parse(url: TestFixtures.url("basic_entities.dxf"))
        let countBefore = parsed.layers.count
        let id1 = MarkupStore.ensureMarkupLayer(in: parsed)
        XCTAssertEqual(parsed.layers.count, countBefore + 1)
        XCTAssertEqual(parsed.layers.last?.name, MarkupStore.layerName)

        // Idempotent: calling again must not create a second layer.
        let id2 = MarkupStore.ensureMarkupLayer(in: parsed)
        XCTAssertEqual(id1, id2)
        XCTAssertEqual(parsed.layers.count, countBefore + 1)
    }

    /// End-to-end: register the markup layer, add a markup entity via a real
    /// transaction, regenerate, and confirm the entity is hit-testable and
    /// the layer shows a nonzero entity count after a full rebuild — proving
    /// the layer pre-registration + Regenerator.build interaction actually
    /// works, not just the isolated conversion functions.
    func testMarkupEntityIsRenderedAndHitTestableAfterRegen() throws {
        let parsed = try EntityStoreParser.parse(url: TestFixtures.url("basic_entities.dxf"))
        let layerId = MarkupStore.ensureMarkupLayer(in: parsed)
        var addedId: EntityID!
        parsed.document.transact("Draw") { tx in
            let proto = MarkupStore.prototype(
                for: DrawnEntity(shape: .circle(center: CGPoint(x: 900, y: 900), radius: 5)),
                layerId: layerId, store: parsed.store)
            addedId = tx.add(proto)
        }
        let doc = Regenerator.build(from: parsed, parseSeconds: 0) { _ in }
        XCTAssertGreaterThan(doc.layers[Int(layerId)].entityCount, 0)

        let hit = HitTester.hitTestEntityID(document: doc, usePaperSpace: false,
                                            at: CGPoint(x: 905, y: 900), tolerance: 0.5,
                                            visibility: VisibilityState())
        XCTAssertEqual(hit, addedId)
    }

    /// Phase 3.2/"New Layer" regression: `ensureLayer` alone creates the
    /// layer in `parsed.layers`, but `RegenCoordinator.document.layers` is a
    /// snapshot built once by `Regenerator.build` — it does NOT pick up a
    /// layer added to `parsed.layers` after that build, unlike
    /// `appendGroup`'s incremental growth of `modelGroups`/`paperGroups`.
    /// `ContentView.createLayer` relies on calling `regen.fullRebuild()`
    /// immediately after `ensureLayer` to resync `document.layers` — this
    /// proves both halves: the staleness WITHOUT a rebuild, and the fix
    /// WITH one.
    func testEnsureLayerAloneDoesNotAppearInDocumentUntilFullRebuild() throws {
        let parsed = try EntityStoreParser.parse(url: TestFixtures.url("basic_entities.dxf"))
        let regen = RegenCoordinator(parsed: parsed,
                                      document: Regenerator.build(from: parsed, parseSeconds: 0) { _ in })
        let countBefore = regen.document.layers.count

        let newId = MarkupStore.ensureLayer(named: "MY-NEW-LAYER", in: parsed)
        XCTAssertTrue(parsed.layers.contains { $0.name == "MY-NEW-LAYER" },
                      "ensureLayer must register the layer in parsed.layers immediately")
        XCTAssertEqual(regen.document.layers.count, countBefore,
                       "document.layers must NOT change from ensureLayer alone (proves the staleness this test guards)")

        regen.fullRebuild()
        XCTAssertEqual(regen.document.layers.count, countBefore + 1,
                       "fullRebuild() must resync document.layers to include the new layer")
        XCTAssertTrue(regen.document.layers.contains { $0.id == Int(newId) && $0.name == "MY-NEW-LAYER" })
        XCTAssertEqual(regen.document.layers.first { $0.id == Int(newId) }?.entityCount, 0,
                       "a freshly created layer has zero entities on it")
    }

    // MARK: - RegenCoordinator.loadPackage (live app's real "Open File" entry point)

    /// `loadPackage` must (a) match `PackageLoader.loadIntoStore` +
    /// `Regenerator.build`'s output exactly for a plain single-file fixture
    /// (no xrefs) and (b) pre-register the NOVACAD-MARKUP layer so it's
    /// immediately usable — this is the exact path `ContentView.openFile`
    /// now calls, so a regression here would silently break every "Open
    /// File" in the live app.
    func testLoadPackagePreRegistersMarkupLayer() throws {
        let coordinator = try RegenCoordinator.loadPackage(url: TestFixtures.url("basic_entities.dxf"))
        let markupId = coordinator.parsed.layerIdByName[MarkupStore.layerName]
        XCTAssertNotNil(markupId, "loadPackage must pre-register the markup layer before the first build")
        guard let markupId else { return }
        XCTAssertEqual(coordinator.document.layers[Int(markupId)].name, MarkupStore.layerName)
    }

    /// `loadPackage` must resolve xrefs exactly like the old
    /// `PackageLoader.load` (this is the whole point of routing through
    /// `PackageLoader.loadIntoStore` instead of the narrower
    /// `EntityStoreParser.parse` that `RegenCoordinator.load` uses).
    func testLoadPackageResolvesXrefs() throws {
        let coordinator = try RegenCoordinator.loadPackage(url: TestFixtures.url("resolved_xref.dxf"))
        XCTAssertFalse(coordinator.document.xrefs.isEmpty, "loadPackage must resolve xrefs like PackageLoader.load does")
        XCTAssertTrue(coordinator.document.xrefs.allSatisfy(\.isResolved))
    }

    /// A markup entity added AFTER `loadPackage` must be drawable/exportable
    /// end to end through the exact same `performEdit`-shaped sequence
    /// `ContentView.commitDrawn` uses — the full live-app "Draw a line"
    /// story, minus the SwiftUI view layer itself.
    func testLoadPackageThenDrawThenExportRoundTrips() throws {
        let coordinator = try RegenCoordinator.loadPackage(url: TestFixtures.url("basic_entities.dxf"))
        guard let layerId = coordinator.parsed.layerIdByName[MarkupStore.layerName] else {
            return XCTFail("markup layer must exist")
        }
        let e = DrawnEntity(shape: .line(a: CGPoint(x: 1, y: 1), b: CGPoint(x: 50, y: 50)))
        let store = coordinator.parsed.store
        coordinator.parsed.document.transact("Draw") { tx in
            _ = tx.add(MarkupStore.prototype(for: e, layerId: layerId, store: store))
        }
        let ops = coordinator.parsed.document.undoStack.last!.ops
        let delta = coordinator.apply(ops)
        XCTAssertFalse(delta.fullRebuild)

        let exported = MarkupStore.drawnEntities(in: store, layerId: layerId)
        XCTAssertEqual(exported.count, 1)
        guard case .line(let a, let b) = exported[0].shape else { return XCTFail("expected .line") }
        XCTAssertEqual(a, CGPoint(x: 1, y: 1))
        XCTAssertEqual(b, CGPoint(x: 50, y: 50))
    }

    // MARK: - Osnap.snap `excluding` (Move tool must not snap to itself)

    /// `basic_entities.dxf`'s LINE runs (0,0)-(100,50) — snapping near its
    /// endpoint ordinarily finds it; `excluding` that line's own EntityID
    /// must suppress the hit, which is exactly what the Move tool's
    /// destination-pick needs (never snap to the pre-move position of the
    /// object(s) currently being moved).
    func testOsnapSnapExcludingSuppressesCandidateEntity() throws {
        let coordinator = try RegenCoordinator.loadPackage(url: TestFixtures.url("basic_entities.dxf"))
        let doc = coordinator.document
        let near = CGPoint(x: 100, y: 50)   // the LINE's own endpoint

        let unexcluded = Osnap.snap(document: doc, usePaperSpace: false, near: near,
                                    tolerance: 1.0, visibility: VisibilityState())
        XCTAssertNotNil(unexcluded, "sanity check: the endpoint is snappable when nothing is excluded")
        guard let hitId = HitTester.hitTestEntityID(document: doc, usePaperSpace: false,
                                                     at: CGPoint(x: 50, y: 25), tolerance: 30,
                                                     visibility: VisibilityState())
        else { return XCTFail("expected to find the LINE entity to exclude") }

        let excluded = Osnap.snap(document: doc, usePaperSpace: false, near: near,
                                  tolerance: 1.0, visibility: VisibilityState(),
                                  excluding: [hitId])
        // Excluding the LINE's endpoint/midpoint candidates must not
        // silently fall back to some OTHER nearby object's geometry at the
        // exact same point in this fixture (there is none within
        // tolerance), so the result must be nil.
        XCTAssertNil(excluded, "excluding the line's own entity must suppress its endpoint as a snap candidate")
    }
}
