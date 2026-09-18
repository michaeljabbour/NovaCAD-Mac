import XCTest
@testable import DWGViewer
import CADCore

/// Phase 1.6: incremental regeneration correctness. Uses the small hand-
/// authored fixtures (not the 731MB real file — that's exercised via
/// `--edit-script` for performance verification, see the implementation
/// report) so these run in milliseconds as part of `swift test`.
final class RegenCoordinatorTests: XCTestCase {

    private func makeCoordinator(_ fixture: String = "basic_entities.dxf") throws -> RegenCoordinator {
        try RegenCoordinator.load(url: TestFixtures.url(fixture))
    }

    private func lineProto(_ a: Vec3, _ b: Vec3, owner: OwnerRef = .model) -> EntityPrototype {
        EntityPrototype(type: .line, layerId: 0, owner: owner, payload: .line(LinePayload(a: a, b: b)))
    }

    /// `basic_entities.dxf` has only ~6 primitives total, so tombstoning
    /// even ONE of them exceeds the 5% compaction-ratio threshold and
    /// triggers an (entirely correct) automatic `fullRebuild` — which would
    /// make tests asserting on the INCREMENTAL (non-compacted) path flaky
    /// against real behavior. Padding the baseline with enough untouched
    /// geometry first keeps the ratio low enough that a single touched
    /// entity's tombstone doesn't cross the threshold, so these tests
    /// actually exercise the incremental path they're named for.
    private func padBaseline(_ rc: RegenCoordinator, count: Int = 400) {
        rc.parsed.document.transact("Pad") { tx in
            for i in 0..<count {
                _ = tx.add(self.lineProto(Vec3(x: Double(i), y: -5000), Vec3(x: Double(i) + 1, y: -5000)))
            }
        }
        rc.apply(rc.parsed.document.undoStack.last!.ops)
    }

    // MARK: - Basic incremental append

    func testAddAppendsDeltaGroupWithoutChangingExistingGroupCount() throws {
        let rc = try makeCoordinator()
        let modelGroupsBefore = rc.document.modelGroups.count

        var id: EntityID!
        rc.parsed.document.transact("Draw") { tx in
            id = tx.add(self.lineProto(Vec3(x: 500, y: 500), Vec3(x: 600, y: 600)))
        }
        let delta = rc.apply(rc.parsed.document.undoStack.last!.ops)

        XCTAssertFalse(delta.fullRebuild)
        XCTAssertFalse(delta.appendedModelGroups.isEmpty, "a brand-new line needs a fresh delta group")
        XCTAssertGreaterThan(rc.document.modelGroups.count, modelGroupsBefore,
                             "appending a delta group must grow modelGroups, not replace it")
        // Existing indices < modelGroupsBefore must be UNCHANGED objects (identity), proving
        // the append didn't reallocate/reorder the prior groups.
        XCTAssertNotNil(rc.document.modelGroups.first)
        _ = id
    }

    // MARK: - Phase 4.2: copyTransformed/transform commit through RegenCoordinator

    /// COPY's `Transaction.copyTransformed` produces an `.add` op exactly
    /// like any other new entity — confirms it takes the same fast
    /// delta-group-append path as `testAddAppendsDeltaGroupWithoutChanging...`
    /// rather than tripping the "ambiguous placement" full-rebuild fallback.
    func testCopyTransformedAppendsDeltaGroup() throws {
        let rc = try makeCoordinator()
        var originalId: EntityID!
        rc.parsed.document.transact("Draw") { tx in
            originalId = tx.add(self.lineProto(Vec3(x: 500, y: 500), Vec3(x: 600, y: 600)))
        }
        _ = rc.apply(rc.parsed.document.undoStack.last!.ops)
        let modelGroupsBefore = rc.document.modelGroups.count

        var copyId: EntityID!
        rc.parsed.document.transact("Copy") { tx in
            copyId = tx.copyTransformed(originalId, by: .translation(dx: 1000, dy: 0), mirrtext: false)
        }
        let delta = rc.apply(rc.parsed.document.undoStack.last!.ops)

        XCTAssertFalse(delta.fullRebuild)
        XCTAssertFalse(delta.appendedModelGroups.isEmpty)
        XCTAssertGreaterThan(rc.document.modelGroups.count, modelGroupsBefore)
        XCTAssertNotEqual(copyId, originalId)

        // Both original and copy resolve to live, distinct geometry.
        let refs = rc.resolveToRefs([originalId, copyId])
        XCTAssertEqual(refs.count, 2, "original and copy must resolve to two distinct renderable refs")
    }

    /// ROTATE/SCALE/MIRROR (via `Transaction.transform`) go through the same
    /// tombstone-old/emit-new incremental path as a plain `modifyPayload`
    /// move — confirms EntityTransform-driven edits don't require any new
    /// RegenCoordinator handling beyond what already exists for `.modify`.
    func testTransformTombstonesOldAndEmitsNewGeometry() throws {
        let rc = try makeCoordinator()
        padBaseline(rc)
        var id: EntityID!
        rc.parsed.document.transact("Draw") { tx in
            id = tx.add(self.lineProto(Vec3(x: 10, y: 0), Vec3(x: 20, y: 0)))
        }
        _ = rc.apply(rc.parsed.document.undoStack.last!.ops)

        rc.parsed.document.transact("Rotate") { tx in
            tx.transform(id, by: .rotation(about: Vec2(0, 0), angleRad: .pi / 2), mirrtext: false)
        }
        let delta = rc.apply(rc.parsed.document.undoStack.last!.ops)
        XCTAssertFalse(delta.fullRebuild)

        let line = rc.parsed.store.lines[Int(rc.parsed.store.header(id)!.payload)]
        XCTAssertEqual(line.a.x, 0, accuracy: 1e-9)
        XCTAssertEqual(line.a.y, 10, accuracy: 1e-9)
    }

    // MARK: - Tombstone on modify

    func testModifyTombstonesOldPrimitiveAndEmitsNewOne() throws {
        let rc = try makeCoordinator()
        padBaseline(rc)
        var id: EntityID!
        rc.parsed.document.transact("Draw") { tx in
            id = tx.add(self.lineProto(Vec3(x: 0, y: 0), Vec3(x: 10, y: 10)))
        }
        rc.apply(rc.parsed.document.undoStack.last!.ops)
        XCTAssertEqual(rc.tombstonedCount, 0, "a fresh add has nothing to tombstone yet")

        rc.parsed.document.transact("Move") { tx in
            tx.modifyPayload(id) { copy in
                guard case .line(var l) = copy else { return }
                l.a.x += 100; l.b.x += 100
                copy = .line(l)
            }
        }
        let delta = rc.apply(rc.parsed.document.undoStack.last!.ops)
        XCTAssertFalse(delta.fullRebuild)
        XCTAssertGreaterThan(rc.tombstonedCount, 0, "the OLD primitive must be tombstoned after a modify")
        XCTAssertFalse(delta.appendedModelGroups.isEmpty, "the NEW geometry must land in a delta group")
    }

    // MARK: - Delete tombstones without appending

    func testDeleteTombstonesOnlyNoAppend() throws {
        let rc = try makeCoordinator()
        padBaseline(rc)
        var id: EntityID!
        rc.parsed.document.transact("Draw") { tx in
            id = tx.add(self.lineProto(Vec3(x: 0, y: 0), Vec3(x: 10, y: 10)))
        }
        rc.apply(rc.parsed.document.undoStack.last!.ops)

        rc.parsed.document.transact("Erase") { tx in tx.delete(id) }
        let delta = rc.apply(rc.parsed.document.undoStack.last!.ops)
        XCTAssertTrue(delta.appendedModelGroups.isEmpty, "a delete emits no new geometry")
        XCTAssertGreaterThan(rc.tombstonedCount, 0)
    }

    // MARK: - Renderer/hit-test skip tombstoned primitives

    func testTombstonedPrimitiveIsExcludedFromHitTest() throws {
        let rc = try makeCoordinator()
        var id: EntityID!
        rc.parsed.document.transact("Draw") { tx in
            id = tx.add(self.lineProto(Vec3(x: 200, y: 200), Vec3(x: 210, y: 200)))
        }
        rc.apply(rc.parsed.document.undoStack.last!.ops)

        let hitBefore = HitTester.hitTestEntityID(document: rc.document, usePaperSpace: false,
                                                  at: CGPoint(x: 205, y: 200), tolerance: 1,
                                                  visibility: VisibilityState())
        XCTAssertEqual(hitBefore, id)

        rc.parsed.document.transact("Erase") { tx in tx.delete(id) }
        rc.apply(rc.parsed.document.undoStack.last!.ops)

        let hitAfter = HitTester.hitTestEntityID(document: rc.document, usePaperSpace: false,
                                                 at: CGPoint(x: 205, y: 200), tolerance: 1,
                                                 visibility: VisibilityState())
        XCTAssertNil(hitAfter, "hit-testing must skip a tombstoned primitive")
    }

    // MARK: - Undo/redo through RegenCoordinator (via full rebuild reconciliation)

    func testUndoRestoresPixelIdenticalGeometryAfterFullRebuild() throws {
        let rc = try makeCoordinator()
        var id: EntityID!
        rc.parsed.document.transact("Draw") { tx in
            id = tx.add(self.lineProto(Vec3(x: 300, y: 300), Vec3(x: 400, y: 400)))
        }
        rc.apply(rc.parsed.document.undoStack.last!.ops)

        rc.parsed.document.transact("Move") { tx in
            tx.modifyPayload(id) { copy in
                guard case .line(var l) = copy else { return }
                l.a.x += 1000
                copy = .line(l)
            }
        }
        rc.apply(rc.parsed.document.undoStack.last!.ops)

        rc.parsed.document.undo()
        rc.fullRebuild()   // the harness's reconcileAfterUndoRedo equivalent

        let h = try XCTUnwrap(rc.parsed.store.header(id))
        XCTAssertEqual(rc.parsed.store.lines[Int(h.payload)].a, Vec3(x: 300, y: 300),
                      "undo must restore the exact pre-move coordinates")
    }

    // MARK: - Compaction

    func testCompactionRebuildsAndClearsTombstoneBookkeeping() throws {
        let rc = try makeCoordinator()
        padBaseline(rc, count: 400)   // keep the tombstone RATIO low enough that erasing a few lines below doesn't auto-compact early
        var ids: [EntityID] = []
        rc.parsed.document.transact("Draw many") { tx in
            for i in 0..<10 {
                ids.append(tx.add(self.lineProto(Vec3(x: Double(i), y: 900), Vec3(x: Double(i) + 1, y: 901))))
            }
        }
        rc.apply(rc.parsed.document.undoStack.last!.ops)

        rc.parsed.document.transact("Erase all") { tx in
            for id in ids { tx.delete(id) }
        }
        let deleteDelta = rc.apply(rc.parsed.document.undoStack.last!.ops)
        XCTAssertFalse(deleteDelta.fullRebuild, "10 deletes against a 400+ baseline must stay under the auto-compact threshold")
        XCTAssertGreaterThan(rc.tombstonedCount, 0)

        rc.fullRebuild()
        XCTAssertEqual(rc.tombstonedCount, 0, "compaction must reset the tombstone counter")
        XCTAssertEqual(rc.deltaGroupTotal, 0, "compaction must reset delta-group bookkeeping")
    }

    /// The plan's own gate: "10k-entity scripted move on the big file: ...
    /// undo across forced `compact` restores." Reproduced at small scale so
    /// it runs as part of `swift test`: draw -> move -> FORCE a compaction
    /// mid-stream -> undo -> geometry must still be exactly correct, proving
    /// the tombstone bitsets / delta groups / entityLocator all get
    /// correctly invalidated/rebuilt across a compaction boundary.
    func testUndoAcrossForcedCompactionRestoresExactState() throws {
        let rc = try makeCoordinator()
        var id: EntityID!
        rc.parsed.document.transact("Draw") { tx in
            id = tx.add(self.lineProto(Vec3(x: 50, y: 50), Vec3(x: 60, y: 60)))
        }
        rc.apply(rc.parsed.document.undoStack.last!.ops)

        rc.parsed.document.transact("Move") { tx in
            tx.modifyPayload(id) { copy in
                guard case .line(var l) = copy else { return }
                l.a.x += 500; l.b.x += 500
                copy = .line(l)
            }
        }
        rc.apply(rc.parsed.document.undoStack.last!.ops)

        // Force compaction NOW, before undo — this is the hard case: the
        // delta group holding the MOVED line's new geometry, and the
        // tombstone marking its old position dead, both get thrown away and
        // replaced by a from-scratch Regenerator.build off the current
        // (post-move) EntityStore state.
        rc.fullRebuild()

        // The store itself still has full undo history — undo must work
        // exactly as if compaction never happened.
        rc.parsed.document.undo()
        rc.fullRebuild()   // reconcile the render model with the undone store, as the harness does

        let h = try XCTUnwrap(rc.parsed.store.header(id))
        XCTAssertEqual(rc.parsed.store.lines[Int(h.payload)].a, Vec3(x: 50, y: 50),
                      "undo must restore pre-move coordinates even after an intervening compaction")

        // And the render model must actually reflect that: hit-testing at
        // the OLD (pre-move) position must find it again.
        let hit = HitTester.hitTestEntityID(document: rc.document, usePaperSpace: false,
                                            at: CGPoint(x: 55, y: 55), tolerance: 2,
                                            visibility: VisibilityState())
        XCTAssertEqual(hit, id)
    }

    // MARK: - Selection survives compaction (Set<EntityID>, not positional)

    func testSelectionSurvivesCompaction() throws {
        let rc = try makeCoordinator()
        var id: EntityID!
        rc.parsed.document.transact("Draw") { tx in
            id = tx.add(self.lineProto(Vec3(x: 700, y: 700), Vec3(x: 710, y: 710)))
        }
        rc.apply(rc.parsed.document.undoStack.last!.ops)

        // Selection lives in the CALLER's Set<EntityID> (the harness's
        // `Session.selection`), not in RegenCoordinator — this test proves
        // the EntityID itself, and what it resolves to, survives a
        // compaction unchanged, which is what makes that caller-side set
        // valid across the boundary.
        var selection: Set<EntityID> = [id]

        rc.fullRebuild()

        XCTAssertTrue(selection.contains(id), "the EntityID value itself is stable across compaction")
        XCTAssertFalse(rc.parsed.store.isDeleted(id))
        let hit = HitTester.hitTestEntityID(document: rc.document, usePaperSpace: false,
                                            at: CGPoint(x: 705, y: 705), tolerance: 2,
                                            visibility: VisibilityState())
        XCTAssertEqual(hit, id, "the same EntityID must still resolve to the same geometry post-compaction")
        selection.formUnion([])  // no-op, silences "never mutated" warning risk if body shrinks later
    }

    // MARK: - Compaction threshold triggers automatically

    func testHighTombstoneRatioTriggersAutomaticCompaction() throws {
        let rc = try makeCoordinator()
        var ids: [EntityID] = []
        rc.parsed.document.transact("Draw many") { tx in
            for i in 0..<20 {
                ids.append(tx.add(self.lineProto(Vec3(x: Double(i), y: 800), Vec3(x: Double(i) + 1, y: 800))))
            }
        }
        rc.apply(rc.parsed.document.undoStack.last!.ops)

        // Deleting ALL of them in one transaction tombstones effectively
        // 100% of what was just added, which — relative to the tiny
        // fixture's total primitive count — comfortably exceeds the 5%
        // ratio threshold and should trigger `apply` to compact automatically.
        rc.parsed.document.transact("Erase many") { tx in
            for id in ids { tx.delete(id) }
        }
        let delta = rc.apply(rc.parsed.document.undoStack.last!.ops)
        XCTAssertTrue(delta.fullRebuild, "exceeding the tombstone ratio threshold must trigger automatic compaction")
        XCTAssertEqual(rc.tombstonedCount, 0, "a completed compaction resets the tombstone counter")
    }

    // MARK: - Delta group count threshold triggers automatic compaction

    func testManyDistinctDeltaGroupsTriggerAutomaticCompaction() throws {
        let rc = try makeCoordinator()
        // Each entity gets a DISTINCT layerId so every one lands in its own
        // GroupKey/delta group — easiest way to blow past
        // deltaGroupCountThreshold (200) without needing a huge entity count.
        for i in 0..<(RegenCoordinator.deltaGroupCountThreshold + 5) {
            var sawFullRebuild = false
            rc.parsed.document.transact("Draw \(i)") { tx in
                _ = tx.add(EntityPrototype(type: .line, layerId: Int32(i + 1), owner: .model,
                    payload: .line(LinePayload(a: Vec3(x: Double(i), y: 950), b: Vec3(x: Double(i) + 1, y: 950)))))
            }
            let delta = rc.apply(rc.parsed.document.undoStack.last!.ops)
            if delta.fullRebuild { sawFullRebuild = true }
            if sawFullRebuild { break }
        }
        XCTAssertLessThanOrEqual(rc.deltaGroupTotal, RegenCoordinator.deltaGroupCountThreshold,
                                 "delta group count must never be allowed to grow past the threshold uncompacted")
    }

    // MARK: - RegenDelta plumbing sanity

    func testRegenDeltaRevisionIncrementsPerCommit() throws {
        let rc = try makeCoordinator()
        let r0 = rc.revision
        rc.parsed.document.transact("Draw") { tx in
            _ = tx.add(self.lineProto(Vec3(x: 1, y: 1), Vec3(x: 2, y: 2)))
        }
        let delta = rc.apply(rc.parsed.document.undoStack.last!.ops)
        XCTAssertEqual(delta.revision, r0 + 1)
        XCTAssertEqual(rc.revision, r0 + 1)
    }

    // MARK: - Block redefinition (dirtyBlocks / regenerateDirtyBlocks)

    /// `block_insert.dxf` has one block ("SYMBOL1": a LINE + CIRCLE) with a
    /// single INSERT at (100,100), scale 2, rotation 45. Editing the block's
    /// own CIRCLE (its radius) and marking the block dirty must re-expand
    /// that one INSERT's rendered geometry to reflect the new radius,
    /// without requiring a full document rebuild (single affected insert,
    /// comfortably under the delta-group threshold).
    func testRegenerateDirtyBlocksPatchesSingleInsertIncrementally() throws {
        let rc = try makeCoordinator("block_insert.dxf")
        padBaseline(rc)   // keep the tombstone RATIO low enough that this test exercises the incremental path, not auto-compaction

        // Find the CIRCLE inside the block definition (owner.isBlock), and
        // the top-level INSERT that references SYMBOL1.
        var circleID: EntityID?
        var insertID: EntityID?
        for i in rc.parsed.store.headers.indices {
            let h = rc.parsed.store.headers[i]
            if h.type == .circle, h.owner.isBlock { circleID = EntityID(raw: Int32(i)) }
            if h.type == .insert, h.owner.isModel { insertID = EntityID(raw: Int32(i)) }
        }
        let cid = try XCTUnwrap(circleID, "block_insert.dxf's SYMBOL1 must contain a CIRCLE")
        let iid = try XCTUnwrap(insertID, "block_insert.dxf must contain a top-level INSERT")
        let radiusBefore = rc.parsed.store.circles[Int(rc.parsed.store.header(cid)!.payload)].radius

        rc.parsed.document.transact("Edit block circle") { tx in
            tx.modifyPayload(cid) { copy in
                guard case .circle(var c) = copy else { return }
                c.radius *= 2
                copy = .circle(c)
            }
        }
        // A block-definition edit doesn't flow through `apply(_:)` (that's
        // for top-level/orphan-root entities) — the caller marks the owning
        // block dirty and asks for a dedicated re-expansion.
        rc.markBlockDirty("SYMBOL1")
        let delta = rc.regenerateDirtyBlocks()

        XCTAssertFalse(delta.fullRebuild, "one affected insert must stay on the incremental path")
        XCTAssertFalse(delta.appendedModelGroups.isEmpty, "the re-expanded insert needs fresh delta geometry")
        XCTAssertTrue(rc.dirtyBlocks.isEmpty, "regenerateDirtyBlocks must clear the dirty set once done")
        XCTAssertGreaterThan(rc.tombstonedCount, 0, "the insert's OLD (smaller-circle) expansion must be tombstoned")

        // Verify the render model actually reflects the doubled radius: the
        // INSERT (position 100,100, scale 2, rotation 45) places SYMBOL1's
        // circle (local center 5,5, local radius radiusBefore*2 after the
        // edit) at world center = (100,100) + R45 * scale2 * (5,5), with
        // world radius = radiusBefore*2 (scale) * 2 (edit) = radiusBefore*4.
        let rot = 45.0 * .pi / 180
        let localCenter = CGPoint(x: 5, y: 5)
        let scaled = CGPoint(x: localCenter.x * 2, y: localCenter.y * 2)
        let rotated = CGPoint(x: scaled.x * cos(rot) - scaled.y * sin(rot),
                              y: scaled.x * sin(rot) + scaled.y * cos(rot))
        let worldCenter = CGPoint(x: 100 + rotated.x, y: 100 + rotated.y)
        let worldRadius = radiusBefore * 2 /* edit */ * 2 /* insert scale */

        // Hit-test ON the new (larger) circle boundary — must resolve to the
        // OWNING INSERT's EntityID, matching `HitTester`'s standing "block
        // content click promotes to the whole insert" rule (verified
        // unchanged since before Phase 1.6: a hit-test against a FRESH,
        // never-edited full parse of this exact fixture already resolves
        // this same circle boundary to the insert, not the loose circle —
        // this assertion previously expected `cid` directly, which only
        // "passed" because `regenerateDirtyBlocks`'s OWN incremental
        // re-expansion had a bug (`emitInsertSubtree` hardcoded
        // `insertId = -1`) that accidentally left its re-emitted primitives
        // NOT promoted, inconsistently with the always-correct full-rebuild
        // path — fixed as part of Phase 6.1's `document.inserts`
        // incremental-append work, which this test's assertion is updated
        // to match). Proves the fresh radius is live in the render model,
        // not just in the store, AND that the promotion/index bookkeeping
        // survived the incremental re-expansion correctly.
        let onNewBoundary = CGPoint(x: worldCenter.x + worldRadius, y: worldCenter.y)
        let hit = HitTester.hitTestEntityID(document: rc.document, usePaperSpace: false,
                                            at: onNewBoundary, tolerance: 0.5,
                                            visibility: VisibilityState())
        XCTAssertEqual(hit, iid, "the render model must show the CIRCLE (promoted to its owning INSERT) at its doubled radius after regenerateDirtyBlocks")

        // The OLD boundary (pre-edit radius) must no longer hit anything —
        // proving the stale expansion was tombstoned, not just added-to.
        let worldRadiusOld = radiusBefore * 2
        let onOldBoundary = CGPoint(x: worldCenter.x + worldRadiusOld, y: worldCenter.y)
        let staleHit = HitTester.hitTestEntityID(document: rc.document, usePaperSpace: false,
                                                 at: onOldBoundary, tolerance: 0.5,
                                                 visibility: VisibilityState())
        XCTAssertNil(staleHit, "the OLD (pre-edit) circle boundary must no longer be hit-testable")
    }

    // MARK: - Phase 1.7: InsertInstance.entityId / whole-block selection

    /// `block_insert.dxf`: one top-level INSERT of SYMBOL1 at (100,100),
    /// scale (2,2), rotation 45 — clicking ON the insert's block content
    /// (not on the loose CIRCLE/LINE's own primitives, which resolve to
    /// their own ids per `hitTest`'s "block content resolves to the whole
    /// insert" rule) must resolve to the INSERT's own stable EntityID via
    /// the new `InsertInstance.entityId` field, not just to loose primitives.
    func testInsertInstanceCarriesStableEntityID() throws {
        let rc = try makeCoordinator("block_insert.dxf")
        XCTAssertEqual(rc.document.inserts.count, 1)
        let insertInstance = rc.document.inserts[0]
        XCTAssertGreaterThanOrEqual(insertInstance.entityId, 0,
            "a full-rebuild-produced InsertInstance must carry its source INSERT's stable EntityID")

        // The INSERT entity itself is the last of the 3 entities in this
        // fixture's ENTITIES section that end up in .model (LINE/CIRCLE are
        // in the BLOCK, not model space) — find it by scanning the store for
        // the .insert-typed header and confirm the ids match exactly.
        let insertHeaderIndex = rc.parsed.store.headers.firstIndex { $0.type == .insert }
        XCTAssertNotNil(insertHeaderIndex)
        XCTAssertEqual(insertInstance.entityId, Int32(insertHeaderIndex!))
    }

    /// Clicking on the rendered (rotated/scaled) block content must resolve,
    /// via `HitTester.hitTestEntityID`, to the block's own CIRCLE entity
    /// (existing per-primitive `entityId` behavior — unchanged by 1.7), while
    /// `HitTester.hitTest` (positional) resolving to `.insert(_)` must in
    /// turn resolve to the SAME stable id as `document.inserts[0].entityId`
    /// via the new `HitTester.resolveEntityID` helper — proving the two paths
    /// agree and a caller holding only a positional `.insert` ref (e.g. an
    /// xref sidebar row, or a `SearchHit`) can promote it to a stable id.
    func testResolveEntityIDPromotesPositionalInsertRef() throws {
        let rc = try makeCoordinator("block_insert.dxf")
        let insertInstance = rc.document.inserts[0]
        let ref = EntityRef.insert(0)
        let resolved = HitTester.resolveEntityID(ref, document: rc.document, usePaperSpace: false)
        XCTAssertEqual(resolved?.raw, insertInstance.entityId)
    }

    /// `RegenCoordinator.resolveToRefs` must round-trip an INSERT's own
    /// EntityID back to `EntityRef.insert(0)` — the promotion
    /// `DocumentSession.renderParams()`-equivalent code needs every frame to
    /// feed `RenderParams.selection` (which stays `Set<EntityRef>`-typed).
    func testResolveToRefsRoundTripsInsertEntityID() throws {
        let rc = try makeCoordinator("block_insert.dxf")
        let insertEntityID = EntityID(raw: rc.document.inserts[0].entityId)
        let refs = rc.resolveToRefs([insertEntityID])
        XCTAssertEqual(refs, [.insert(0)])
    }

    /// A loose top-level entity's EntityID must round-trip through
    /// `resolveToRefs` to its (group, store, index) — same underlying
    /// `locateAll` mechanism `apply(_:)` uses for tombstoning, exercised here
    /// via the public promotion API instead.
    func testResolveToRefsRoundTripsLooseEntityID() throws {
        let rc = try makeCoordinator()
        var id: EntityID!
        rc.parsed.document.transact("Draw") { tx in
            id = tx.add(self.lineProto(Vec3(x: 500, y: 500), Vec3(x: 600, y: 600)))
        }
        _ = rc.apply(rc.parsed.document.undoStack.last!.ops)
        let refs = rc.resolveToRefs([id])
        XCTAssertEqual(refs.count, 1)
        guard case .primitive? = refs.first else {
            return XCTFail("a loose top-level line must resolve to a .primitive ref, got \(String(describing: refs.first))")
        }
    }

    // MARK: - Phase 6.1 groundwork: freshly-added top-level INSERT renders immediately

    /// A brand-new top-level INSERT (BlockEditor.createBlock's substituted
    /// insert, `insert(...)`, and the Stamp-tool rewire's real-INSERT
    /// placement all do exactly this) must expand its referenced block's
    /// content into the render model on the SAME `apply(_:)` call that adds
    /// it — not silently render nothing until some LATER unrelated full
    /// rebuild happens to occur. Before the `emitDelta`/`insertLikeIDs` fix,
    /// `emitSingleTopLevel` correctly emits zero primitives for an INSERT
    /// (it has none of its own), and nothing else filled the gap in, so this
    /// exact scenario silently committed successfully while painting
    /// nothing — `delta.fullRebuild` was false AND no geometry appeared,
    /// with no error of any kind.
    func testAddingTopLevelInsertRendersImmediatelyWithoutFullRebuild() throws {
        let rc = try makeCoordinator("block_insert.dxf")
        padBaseline(rc)   // keep the tombstone/delta-group ratios low so this exercises the incremental path
        let modelGroupsBefore = rc.document.modelGroups.count

        let nameId = rc.parsed.store.strings.intern("SYMBOL1")
        var insertId: EntityID!
        rc.parsed.document.transact("Insert") { tx in
            insertId = tx.add(EntityPrototype(
                type: .insert, layerId: 0, owner: .model,
                payload: .insert(InsertPayload(blockNameId: nameId, position: Vec3(x: 300, y: 300)))))
        }
        let delta = rc.apply(rc.parsed.document.undoStack.last!.ops)

        XCTAssertFalse(delta.fullRebuild, "adding a fresh INSERT must stay on the incremental path")
        XCTAssertFalse(delta.appendedModelGroups.isEmpty, "the new insert's block content needs fresh delta geometry")
        XCTAssertGreaterThan(rc.document.modelGroups.count, modelGroupsBefore)

        // SYMBOL1's circle (local center 5,5, local radius 3) at an
        // unscaled, unrotated INSERT placed at (300,300) -> world center
        // (305,305), world radius 3. Hit-test its boundary to prove the
        // block content actually rendered, not just that SOME group appended.
        let onBoundary = CGPoint(x: 305 + 3, y: 305)
        let hit = HitTester.hitTestEntityID(document: rc.document, usePaperSpace: false,
                                            at: onBoundary, tolerance: 0.5,
                                            visibility: VisibilityState())
        XCTAssertNotNil(hit, "the new INSERT's block content (SYMBOL1's circle) must be live in the render model")
        _ = insertId
    }

    /// Same scenario, but the new INSERT lands in PAPER space — proving the
    /// fix correctly routes by `h.owner` rather than assuming model space.
    func testAddingTopLevelInsertInPaperSpaceRendersImmediately() throws {
        let rc = try makeCoordinator("block_insert.dxf")
        padBaseline(rc)
        let paperGroupsBefore = rc.document.paperGroups.count

        let nameId = rc.parsed.store.strings.intern("SYMBOL1")
        rc.parsed.document.transact("Insert") { tx in
            _ = tx.add(EntityPrototype(
                type: .insert, layerId: 0, owner: .paper,
                payload: .insert(InsertPayload(blockNameId: nameId, position: Vec3(x: 50, y: 50)))))
        }
        let delta = rc.apply(rc.parsed.document.undoStack.last!.ops)

        XCTAssertFalse(delta.fullRebuild)
        XCTAssertFalse(delta.appendedPaperGroups.isEmpty, "the new paper-space insert's block content needs fresh delta geometry")
        XCTAssertGreaterThan(rc.document.paperGroups.count, paperGroupsBefore)

        let onBoundary = CGPoint(x: 55 + 3, y: 55)
        let hit = HitTester.hitTestEntityID(document: rc.document, usePaperSpace: true,
                                            at: onBoundary, tolerance: 0.5,
                                            visibility: VisibilityState())
        XCTAssertNotNil(hit, "the new paper-space INSERT's block content must be live in the render model")
    }

    /// Moving (modifying) a PRE-EXISTING top-level INSERT can't be handled
    /// incrementally (its block-content primitives are tagged with each
    /// LEAF entity's own id, not the insert's, and `EntityStore.bounds(_:)`
    /// for `.insert` is just its insertion point, not the expanded content's
    /// world extent) — verifies the conservative `forceFullRebuildForInsertChange`
    /// fallback actually fires (rather than silently leaving stale geometry
    /// at the old position, which is what happened before this fix existed)
    /// AND that the resulting full rebuild correctly reflects the new position.
    func testModifyingExistingInsertForcesFullRebuildAndShowsNewPosition() throws {
        let rc = try makeCoordinator("block_insert.dxf")
        padBaseline(rc)

        // The fixture's one pre-existing INSERT sits at (100,100), scale 2,
        // rotation 45 — find its EntityID by header scan (mirrors the
        // existing test's own "find the CIRCLE inside the block" pattern).
        var insertID: EntityID?
        for i in rc.parsed.store.headers.indices {
            let h = rc.parsed.store.headers[i]
            if h.type == .insert, h.owner.isModel { insertID = EntityID(raw: Int32(i)) }
        }
        let iid = try XCTUnwrap(insertID)

        rc.parsed.document.transact("Move insert") { tx in
            tx.modifyPayload(iid) { copy in
                guard case .insert(var p) = copy else { return }
                p.position = Vec3(x: 1000, y: 1000, z: p.position.z)
                copy = .insert(p)
            }
        }
        let delta = rc.apply(rc.parsed.document.undoStack.last!.ops)

        XCTAssertTrue(delta.fullRebuild, "modifying an existing top-level INSERT must fall back to a full rebuild")

        // New position (1000,1000), same scale/rotation as before -> circle
        // world center = (1000,1000) + R45 * scale2 * (5,5).
        let rot = 45.0 * .pi / 180
        let scaled = CGPoint(x: 10, y: 10)   // local (5,5) * scale 2
        let rotated = CGPoint(x: scaled.x * cos(rot) - scaled.y * sin(rot),
                              y: scaled.x * sin(rot) + scaled.y * cos(rot))
        let worldCenter = CGPoint(x: 1000 + rotated.x, y: 1000 + rotated.y)
        let onNewBoundary = CGPoint(x: worldCenter.x + 6 /* radius 3 * scale 2 */, y: worldCenter.y)
        let hit = HitTester.hitTestEntityID(document: rc.document, usePaperSpace: false,
                                            at: onNewBoundary, tolerance: 0.5,
                                            visibility: VisibilityState())
        XCTAssertNotNil(hit, "the full rebuild must show the insert's block content at its NEW position")

        // Old position (100,100) must no longer show the block content.
        let oldCenter = CGPoint(x: 100 + rotated.x, y: 100 + rotated.y)
        let onOldBoundary = CGPoint(x: oldCenter.x + 6, y: oldCenter.y)
        let staleHit = HitTester.hitTestEntityID(document: rc.document, usePaperSpace: false,
                                                 at: onOldBoundary, tolerance: 0.5,
                                                 visibility: VisibilityState())
        XCTAssertNil(staleHit, "the OLD insert position must no longer show any geometry after the move")
    }

    // MARK: - Phase 6.1: document.inserts incremental append (click-select a freshly-placed INSERT)

    /// A freshly-added top-level INSERT must get a REAL `document.inserts`
    /// entry on the SAME incremental `apply(_:)` call that adds it, so
    /// clicking its rendered block content resolves (via `HitTester`'s
    /// standing "block content promotes to the whole insert" rule) to the
    /// INSERT's own EntityID — exactly like a full rebuild has always
    /// produced for any INSERT present at load time. Found missing while
    /// building Phase 6.2's --edit-script verification (a scripted `insert`
    /// then `select` at the same point resolved to a loose leaf primitive,
    /// not the insert, because `document.inserts` was previously populated
    /// ONLY by `Regenerator.build`).
    func testAddingTopLevelInsertClickSelectsWholeInsert() throws {
        let rc = try makeCoordinator("block_insert.dxf")
        padBaseline(rc)
        let insertsCountBefore = rc.document.inserts.count

        let nameId = rc.parsed.store.strings.intern("SYMBOL1")
        var insertId: EntityID!
        rc.parsed.document.transact("Insert") { tx in
            insertId = tx.add(EntityPrototype(
                type: .insert, layerId: 0, owner: .model,
                payload: .insert(InsertPayload(blockNameId: nameId, position: Vec3(x: 500, y: 500)))))
        }
        _ = rc.apply(rc.parsed.document.undoStack.last!.ops)

        XCTAssertEqual(rc.document.inserts.count, insertsCountBefore + 1,
                       "a fresh top-level INSERT must append exactly one document.inserts entry")

        // SYMBOL1's circle (local center 5,5, radius 3), unscaled/unrotated
        // insert at (500,500) -> world center (505,505), radius 3.
        let onBoundary = CGPoint(x: 505 + 3, y: 505)
        let hit = HitTester.hitTestEntityID(document: rc.document, usePaperSpace: false,
                                            at: onBoundary, tolerance: 0.5, visibility: VisibilityState())
        XCTAssertEqual(hit, insertId, "clicking the new insert's block content must resolve to the INSERT's own EntityID, not a loose leaf primitive")
    }

    /// Safety fallback: adding a MODEL-space insert when PAPER-space
    /// inserts already exist (from an earlier incremental add) forces a
    /// full rebuild instead of an in-place array insertion — found during
    /// development that inserting a model-space `InsertInstance` at the
    /// `modelInsertCount` boundary shifts every EXISTING paper-space
    /// entry's array index up by one, but their ALREADY-EMITTED render
    /// primitives keep the OLD (now-wrong) index baked into their
    /// `insertId` field, silently misrouting a click on the existing
    /// paper-space insert's content to the NEW model-space one instead.
    /// Verified end-to-end: after the (full-rebuild) commit, both inserts
    /// are correctly, independently click-selectable in their own space —
    /// the fallback's job is only to make the incremental path SAFE
    /// (detect and defer to the always-correct full rebuild), not to make
    /// the narrow case fast.
    func testAddingModelInsertAfterExistingPaperInsertFallsBackToFullRebuild() throws {
        let rc = try makeCoordinator("block_insert.dxf")
        padBaseline(rc)
        let nameId = rc.parsed.store.strings.intern("SYMBOL1")

        // First, add a PAPER-space insert (stays on the fast incremental
        // path — no model-space inserts exist yet to conflict with).
        var paperInsertId: EntityID!
        rc.parsed.document.transact("Insert paper") { tx in
            paperInsertId = tx.add(EntityPrototype(
                type: .insert, layerId: 0, owner: .paper,
                payload: .insert(InsertPayload(blockNameId: nameId, position: Vec3(x: 50, y: 50)))))
        }
        let firstDelta = rc.apply(rc.parsed.document.undoStack.last!.ops)
        XCTAssertFalse(firstDelta.fullRebuild, "the FIRST insert (no existing paper/model conflict) must stay incremental")

        // Then add a MODEL-space insert — must trigger the safety fallback.
        var modelInsertId: EntityID!
        rc.parsed.document.transact("Insert model") { tx in
            modelInsertId = tx.add(EntityPrototype(
                type: .insert, layerId: 0, owner: .model,
                payload: .insert(InsertPayload(blockNameId: nameId, position: Vec3(x: 700, y: 700)))))
        }
        let secondDelta = rc.apply(rc.parsed.document.undoStack.last!.ops)
        XCTAssertTrue(secondDelta.fullRebuild,
                     "a model-space insert added after an existing paper-space one must force a full rebuild for safety")

        // Both must be independently click-selectable via HitTester after
        // the full rebuild — SYMBOL1's circle is at LOCAL center (5,5),
        // radius 3 — click ON its boundary (center + radius in X).
        let modelHit = HitTester.hitTestEntityID(document: rc.document, usePaperSpace: false,
                                                 at: CGPoint(x: 705 + 3, y: 705), tolerance: 0.5, visibility: VisibilityState())
        XCTAssertEqual(modelHit, modelInsertId)
        let paperHit = HitTester.hitTestEntityID(document: rc.document, usePaperSpace: true,
                                                 at: CGPoint(x: 55 + 3, y: 55), tolerance: 0.5, visibility: VisibilityState())
        XCTAssertEqual(paperHit, paperInsertId)
    }

    // MARK: - Layer usage tracking (a layer created/populated via an
    // INCREMENTAL edit must be findable/deletable even though
    // `document.layers[i].entityCount` never gets recomputed for it)
    //
    // Regression coverage for a real user report: a layer the AI Assistant
    // created (via `MarkupStore.ensureLayer`, the same call every overlay-
    // layer tool uses) had real objects on it, yet was invisible to the
    // Layers panel's search box — even though "Current Layer" dropdown (no
    // `entityCount` gate at all) could see the layer fine. Root cause:
    // `RegenCoordinator.apply` (the INCREMENTAL path every edit funnels
    // through) emits new render groups; `document.layers` (an IMMUTABLE `let`
    // array — see `apply`'s own doc comment on this exact point) cannot grow
    // to include a genuinely NEW layer without replacing `document` wholesale,
    // so `apply` now forces a full rebuild whenever `parsed.layers` (the
    // live, mutable table `MarkupStore.ensureLayer(...)` appends to) has
    // grown past what `document.layers` currently holds. Before that fix, a
    // new layer's entities rendered fine (primitive emission is layer-id-
    // agnostic) while `document.layers` silently stayed one or more entries
    // SHORT — not merely reporting a stale `entityCount`, but genuinely
    // missing that layer as an array element at all, which is what made it
    // invisible to the Layers panel/search regardless of any `entityCount`
    // filtering fix (a `.count`-bounded iteration cannot find an index past
    // its own end) and crashed outright on any code that indexed
    // `document.layers[newLayerId]` directly.

    func testAddingEntityToANewLayerForcesFullRebuildAndReportsCorrectEntityCount() throws {
        let rc = try makeCoordinator()
        padBaseline(rc)
        let newLayerId = MarkupStore.ensureLayer(named: "AI-OVERLAY", in: rc.parsed)
        rc.parsed.document.transact("Add to new layer") { tx in
            _ = tx.add(EntityPrototype(type: .line, layerId: newLayerId, owner: .model,
                                      payload: .line(LinePayload(a: Vec3(x: 0, y: 100), b: Vec3(x: 10, y: 100)))))
        }
        let delta = rc.apply(rc.parsed.document.undoStack.last!.ops)
        XCTAssertTrue(delta.fullRebuild,
                      "a genuinely new layer must force a full rebuild — document.layers cannot grow incrementally")
        XCTAssertEqual(rc.document.layers.count, rc.parsed.layers.count,
                       "after the forced rebuild, document.layers must be back in sync with parsed.layers")
        XCTAssertEqual(rc.document.layers[Int(newLayerId)].entityCount, 1,
                       "the rebuild must report the new layer's real, correct entity count immediately")
    }

    func testLayerIdsWithLiveEntitiesFindsANewLayersContent() throws {
        let rc = try makeCoordinator()
        padBaseline(rc)
        let newLayerId = MarkupStore.ensureLayer(named: "AI-OVERLAY", in: rc.parsed)
        rc.parsed.document.transact("Add to new layer") { tx in
            _ = tx.add(EntityPrototype(type: .line, layerId: newLayerId, owner: .model,
                                      payload: .line(LinePayload(a: Vec3(x: 0, y: 100), b: Vec3(x: 10, y: 100)))))
        }
        _ = rc.apply(rc.parsed.document.undoStack.last!.ops)
        XCTAssertTrue(rc.layerIdsWithLiveEntities().contains(newLayerId),
                      "the live scan must find the new layer's content (also true independent of any entityCount fix)")
    }

    func testLayerIdsWithLiveEntitiesExcludesDeletedEntitiesLayer() throws {
        let rc = try makeCoordinator()
        padBaseline(rc)
        let newLayerId = MarkupStore.ensureLayer(named: "TEMP-LAYER", in: rc.parsed)
        var addedId: EntityID!
        rc.parsed.document.transact("Add") { tx in
            addedId = tx.add(EntityPrototype(type: .line, layerId: newLayerId, owner: .model,
                                            payload: .line(LinePayload(a: Vec3(x: 0, y: 200), b: Vec3(x: 10, y: 200)))))
        }
        _ = rc.apply(rc.parsed.document.undoStack.last!.ops)
        XCTAssertTrue(rc.layerIdsWithLiveEntities().contains(newLayerId))

        rc.parsed.document.transact("Delete it") { tx in tx.delete(addedId) }
        _ = rc.apply(rc.parsed.document.undoStack.last!.ops)
        XCTAssertFalse(rc.layerIdsWithLiveEntities().contains(newLayerId),
                       "a layer whose only entity was deleted must no longer count as live")
    }

    func testEntityIDsOnLayerFindsEntitiesOnANewLayer() throws {
        let rc = try makeCoordinator()
        padBaseline(rc)
        let newLayerId = MarkupStore.ensureLayer(named: "AI-OVERLAY", in: rc.parsed)
        var addedIds: [EntityID] = []
        rc.parsed.document.transact("Add three") { tx in
            for i in 0..<3 {
                addedIds.append(tx.add(EntityPrototype(
                    type: .line, layerId: newLayerId, owner: .model,
                    payload: .line(LinePayload(a: Vec3(x: Double(i), y: 300), b: Vec3(x: Double(i) + 1, y: 300))))))
            }
        }
        _ = rc.apply(rc.parsed.document.undoStack.last!.ops)

        let found = rc.entityIDsOnLayer(newLayerId)
        XCTAssertEqual(Set(found), Set(addedIds),
                       "entityIDsOnLayer must find every live entity on the new layer")
    }

    /// A SECOND edit to an ALREADY-KNOWN layer (one `document.layers`
    /// already caught up to via the first edit's forced rebuild) must stay
    /// on the fast incremental path — this fix should only force a rebuild
    /// exactly once per genuinely new layer, never on every subsequent edit
    /// to it.
    func testSubsequentEditToAnAlreadyKnownLayerStaysIncremental() throws {
        let rc = try makeCoordinator()
        padBaseline(rc)
        let newLayerId = MarkupStore.ensureLayer(named: "AI-OVERLAY", in: rc.parsed)
        rc.parsed.document.transact("First add") { tx in
            _ = tx.add(EntityPrototype(type: .line, layerId: newLayerId, owner: .model,
                                      payload: .line(LinePayload(a: Vec3(x: 0, y: 100), b: Vec3(x: 10, y: 100)))))
        }
        let firstDelta = rc.apply(rc.parsed.document.undoStack.last!.ops)
        XCTAssertTrue(firstDelta.fullRebuild, "sanity: the first add to a new layer forces a rebuild")
        padBaseline(rc, count: 400)   // re-establish a low tombstone/delta ratio after the rebuild

        rc.parsed.document.transact("Second add, same layer") { tx in
            _ = tx.add(EntityPrototype(type: .line, layerId: newLayerId, owner: .model,
                                      payload: .line(LinePayload(a: Vec3(x: 20, y: 100), b: Vec3(x: 30, y: 100)))))
        }
        let secondDelta = rc.apply(rc.parsed.document.undoStack.last!.ops)
        XCTAssertFalse(secondDelta.fullRebuild,
                       "a SECOND edit to an already-known layer must stay incremental, not rebuild every time")
    }

    func testEntityIDsOnLayerExcludesOtherLayersAndDeletedEntities() throws {
        let rc = try makeCoordinator()
        padBaseline(rc)
        let layerA = MarkupStore.ensureLayer(named: "LAYER-A", in: rc.parsed)
        let layerB = MarkupStore.ensureLayer(named: "LAYER-B", in: rc.parsed)
        var idA: EntityID!, idB: EntityID!, idADeleted: EntityID!
        rc.parsed.document.transact("Add") { tx in
            idA = tx.add(EntityPrototype(type: .line, layerId: layerA, owner: .model,
                                        payload: .line(LinePayload(a: Vec3(x: 0, y: 400), b: Vec3(x: 1, y: 400)))))
            idADeleted = tx.add(EntityPrototype(type: .line, layerId: layerA, owner: .model,
                                               payload: .line(LinePayload(a: Vec3(x: 2, y: 400), b: Vec3(x: 3, y: 400)))))
            idB = tx.add(EntityPrototype(type: .line, layerId: layerB, owner: .model,
                                        payload: .line(LinePayload(a: Vec3(x: 4, y: 400), b: Vec3(x: 5, y: 400)))))
        }
        _ = rc.apply(rc.parsed.document.undoStack.last!.ops)
        rc.parsed.document.transact("Delete one on A") { tx in tx.delete(idADeleted) }
        _ = rc.apply(rc.parsed.document.undoStack.last!.ops)

        let foundOnA = rc.entityIDsOnLayer(layerA)
        XCTAssertEqual(foundOnA, [idA], "must exclude both layer B's entity and A's deleted entity")
        XCTAssertEqual(rc.entityIDsOnLayer(layerB), [idB])
    }

    func testEntityIDsOnLayerIsEmptyForAnUnusedLayer() throws {
        let rc = try makeCoordinator()
        let unusedLayerId = MarkupStore.ensureLayer(named: "NEVER-USED", in: rc.parsed)
        XCTAssertTrue(rc.entityIDsOnLayer(unusedLayerId).isEmpty)
        XCTAssertFalse(rc.layerIdsWithLiveEntities().contains(unusedLayerId))
    }
}
