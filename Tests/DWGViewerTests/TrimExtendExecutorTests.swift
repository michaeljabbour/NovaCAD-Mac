//
//  TrimExtendExecutorTests.swift
//  DWGViewerTests
//
//  Integration-level tests for TrimExtendExecutor: real RegenCoordinator +
//  DXFDocument (not just direct EntityStore construction) so boundary
//  resolution, fence-batch trim, and the end-to-end apply-through-Transaction
//  path are exercised against the SAME render-group machinery the live app
//  uses (HitTester/SelectionEngine's group-bounds-first pruning).
//

import XCTest
import CoreGraphics
@testable import DWGViewer
import CADCore

final class TrimExtendExecutorTests: XCTestCase {

    let tol = Tolerance(linear: 1e-6)

    private func makeCoordinator() throws -> RegenCoordinator {
        try RegenCoordinator.load(url: TestFixtures.url("basic_entities.dxf"))
    }

    @discardableResult
    private func addLine(_ rc: RegenCoordinator, _ a: CGPoint, _ b: CGPoint) -> EntityID {
        var id: EntityID!
        rc.parsed.document.transact("Line") { tx in
            id = tx.add(EntityPrototype(type: .line, layerId: 0, payload: .line(LinePayload(a: Vec3(x: Double(a.x), y: Double(a.y)), b: Vec3(x: Double(b.x), y: Double(b.y))))))
        }
        _ = rc.apply(rc.parsed.document.undoStack.last!.ops)
        return id
    }

    // MARK: - resolveClick

    func testResolveClickFindsNearestPointOnLine() throws {
        let rc = try makeCoordinator()
        let id = addLine(rc, CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0))
        let resolution = TrimExtendExecutor.resolveClick(targetId: id, clickWorld: CGPoint(x: 3, y: 1), store: rc.parsed.store, tol: tol)
        XCTAssertNotNil(resolution)
        XCTAssertEqual(resolution?.param ?? -1, 0.3, accuracy: 1e-6)
        XCTAssertNil(resolution?.segment)
    }

    // MARK: - Explicit-boundary trim end-to-end (via apply -> Transaction -> RegenCoordinator)

    func testTrimAtClickEndToEndCommitsThroughTransaction() throws {
        let rc = try makeCoordinator()
        let target = addLine(rc, CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0))
        let cutter = addLine(rc, CGPoint(x: 5, y: -5), CGPoint(x: 5, y: 5))
        let boundaries = TrimExtendExecutor.resolveExplicitBoundaryCurves([cutter], store: rc.parsed.store)

        guard let resolution = TrimExtendExecutor.resolveClick(targetId: target, clickWorld: CGPoint(x: 8, y: 0), store: rc.parsed.store, tol: tol) else {
            return XCTFail("expected click resolution")
        }
        guard let outcome = TrimExtendExecutor.trimAtClick(resolution, boundaries: boundaries, extendBoundaries: false, store: rc.parsed.store, tol: tol) else {
            return XCTFail("expected a trim outcome")
        }

        rc.parsed.document.transact("Trim") { tx in
            TrimExtendExecutor.apply(outcome, to: tx)
        }
        _ = rc.apply(rc.parsed.document.undoStack.last!.ops)

        // Original line entity is now deleted; a new shorter line survives at [0,5].
        XCTAssertTrue(rc.parsed.store.isDeleted(target))
        var found = false
        for i in 0..<rc.parsed.store.count {
            let id = EntityID(raw: Int32(i))
            guard let h = rc.parsed.store.header(id), h.type == .line, !h.flags.contains(.deleted) else { continue }
            let l = rc.parsed.store.lines[Int(h.payload)]
            if abs(l.a.x - 0) < 1e-6, abs(l.b.x - 5) < 1e-6 { found = true }
        }
        XCTAssertTrue(found, "expected a surviving trimmed line from (0,0) to (5,0)")
    }

    // MARK: - Lazy "all visible" boundary resolution

    func testAllVisibleBoundaryResolutionFindsNearbyBoundaryWithoutExplicitSelection() throws {
        let rc = try makeCoordinator()
        let target = addLine(rc, CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0))
        addLine(rc, CGPoint(x: 5, y: -5), CGPoint(x: 5, y: 5))   // cutter, never explicitly selected

        var state = TrimExtendToolState.begin(.trim)
        state.withAcquiredBoundaries(nil)   // Enter with nothing picked -> "all visible"
        XCTAssertTrue(state.usedAllVisible)

        let boundaries = TrimExtendExecutor.boundaryCurves(for: target, state: state, explicitBoundaryCurves: [],
                                                            document: rc.document, usePaperSpace: false,
                                                            store: rc.parsed.store, visibility: VisibilityState())
        XCTAssertFalse(boundaries.isEmpty, "lazy 'all visible' resolution must find the nearby cutter without it being explicitly selected")

        guard let resolution = TrimExtendExecutor.resolveClick(targetId: target, clickWorld: CGPoint(x: 8, y: 0), store: rc.parsed.store, tol: tol) else {
            return XCTFail("expected click resolution")
        }
        guard let outcome = TrimExtendExecutor.trimAtClick(resolution, boundaries: boundaries, extendBoundaries: false, store: rc.parsed.store, tol: tol) else {
            return XCTFail("expected a trim outcome via lazily-resolved boundary")
        }
        guard case .replaceStandalone = outcome.action else { return XCTFail("expected replaceStandalone") }
    }

    /// Confirms the lazy path does NOT pick up a boundary FAR from the
    /// target (outside the margin) — i.e. it's actually bounded, not a
    /// disguised full-document scan that happens to work by coincidence.
    func testAllVisibleBoundaryResolutionIgnoresFarAwayEntities() throws {
        let rc = try makeCoordinator()
        let target = addLine(rc, CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0))
        addLine(rc, CGPoint(x: 1_000_000, y: -5), CGPoint(x: 1_000_000, y: 5))   // absurdly far away

        var state = TrimExtendToolState.begin(.trim)
        state.withAcquiredBoundaries(nil)
        let boundaries = TrimExtendExecutor.boundaryCurves(for: target, state: state, explicitBoundaryCurves: [],
                                                            document: rc.document, usePaperSpace: false,
                                                            store: rc.parsed.store, visibility: VisibilityState())
        // The far-away line's own bbox is nowhere near target's inflated
        // bbox, so it must not appear as a candidate boundary at all.
        for c in boundaries {
            let bb = c.bbox()
            XCTAssertLessThan(bb.min.x, 100_000, "a boundary 1,000,000 units away must not be resolved as a candidate for a target near the origin")
        }
    }

    // MARK: - Fence batch trim

    func testFenceBatchTrimsEveryCrossedEntityAtIndicatedSide() throws {
        let rc = try makeCoordinator()
        // 3 parallel vertical lines, all crossed by one horizontal fence.
        // Placed far from `basic_entities.dxf`'s own fixture geometry (its
        // diagonal LINE 100 spans roughly (0,0)-(100,50), which would
        // otherwise ALSO cross a fence drawn near the origin) so this test
        // exercises exactly the 3 entities it constructs, not an incidental
        // 4th crossing from unrelated fixture content.
        let ox: Double = 1000
        let l1 = addLine(rc, CGPoint(x: ox + 0, y: -10), CGPoint(x: ox + 0, y: 10))
        let l2 = addLine(rc, CGPoint(x: ox + 5, y: -10), CGPoint(x: ox + 5, y: 10))
        let l3 = addLine(rc, CGPoint(x: ox + 10, y: -10), CGPoint(x: ox + 10, y: 10))
        // A single boundary crossing all 3 lines, so each gets an interval to remove.
        let boundary = addLine(rc, CGPoint(x: ox - 20, y: 3), CGPoint(x: ox + 20, y: 3))
        let boundaryCurves = TrimExtendExecutor.resolveExplicitBoundaryCurves([boundary], store: rc.parsed.store)

        var state = TrimExtendToolState.begin(.trim)
        state.withAcquiredBoundaries([boundary])

        // Fence drawn just below the boundary (y=1), crossing all 3 verticals
        // there — the "indicated side" is below y=3, so that portion should
        // be removed, leaving each line's ABOVE-y=3 portion.
        let fence = [CGPoint(x: ox - 5, y: 1), CGPoint(x: ox + 15, y: 1)]
        let outcomes = TrimExtendExecutor.trimFenceBatch(fencePoints: fence, boundaryState: state,
                                                         explicitBoundaryCurves: boundaryCurves,
                                                         document: rc.document, usePaperSpace: false,
                                                         store: rc.parsed.store, visibility: VisibilityState(), tol: tol)
        XCTAssertEqual(outcomes.count, 3, "fence crossing 3 lines, each with a valid boundary, should produce 3 outcomes")

        rc.parsed.document.transact("FenceTrim") { tx in
            for o in outcomes { TrimExtendExecutor.apply(o, to: tx) }
        }
        _ = rc.apply(rc.parsed.document.undoStack.last!.ops)

        for orig in [l1, l2, l3] {
            XCTAssertTrue(rc.parsed.store.isDeleted(orig), "original vertical line should be replaced by its trimmed remnant")
        }
        // Every surviving trimmed line must span from y=3 to y=10 (the ABOVE
        // portion, since the fence clicked below the boundary at y=1).
        var survivorCount = 0
        for i in 0..<rc.parsed.store.count {
            let id = EntityID(raw: Int32(i))
            guard let h = rc.parsed.store.header(id), h.type == .line, !h.flags.contains(.deleted) else { continue }
            let l = rc.parsed.store.lines[Int(h.payload)]
            guard abs(l.a.x - l.b.x) < 1e-6 else { continue }   // vertical lines only (skip the boundary/fixture lines)
            let x = l.a.x
            if x == ox || x == ox + 5 || x == ox + 10 {
                survivorCount += 1
                let minY = min(l.a.y, l.b.y), maxY = max(l.a.y, l.b.y)
                XCTAssertEqual(minY, 3, accuracy: 1e-6)
                XCTAssertEqual(maxY, 10, accuracy: 1e-6)
            }
        }
        XCTAssertEqual(survivorCount, 3)
    }

    // MARK: - EXTEND via click resolution

    func testExtendAtClickPicksNearerEnd() throws {
        let rc = try makeCoordinator()
        let target = addLine(rc, CGPoint(x: 0, y: 0), CGPoint(x: 5, y: 0))
        let boundary = addLine(rc, CGPoint(x: 10, y: -5), CGPoint(x: 10, y: 5))
        let boundaries = TrimExtendExecutor.resolveExplicitBoundaryCurves([boundary], store: rc.parsed.store)

        // Click near the FAR end (x=5) so nearStart resolves to false.
        guard let resolution = TrimExtendExecutor.resolveClick(targetId: target, clickWorld: CGPoint(x: 4.9, y: 0), store: rc.parsed.store, tol: tol) else {
            return XCTFail("expected click resolution")
        }
        guard let outcome = TrimExtendExecutor.extendAtClick(resolution, boundaries: boundaries, extendBoundaries: false, store: rc.parsed.store, tol: tol) else {
            return XCTFail("expected an extend outcome")
        }
        guard case .modifyInPlace(let payload) = outcome.action, case .line(let l) = payload else {
            return XCTFail("expected modifyInPlace line")
        }
        XCTAssertEqual(l.b.x, 10, accuracy: 1e-6)
    }
}
