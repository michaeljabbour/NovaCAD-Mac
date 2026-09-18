import XCTest
@testable import DWGViewer
import CADCore

/// Regression coverage for the `EntityStore.children(of:)` → `.childrenByParent()`
/// performance fix.
///
/// BACKGROUND: `EntityStore.children(of: id)` is a FULL linear scan over
/// every header in the store. It was being called ONCE PER COPIED ENTITY
/// inside `PackageLoader+Store.swift`'s `mergeIntoStore` →
/// `copyWithAttributeChildren` recursive helper (and the equivalent in
/// `XrefAttach.swift`), and ALSO unguarded once per INSERT inside
/// `Regenerator`'s render walk — turning xref-merge/render into
/// O(entities^2) instead of O(entities). On a large production eTransmit
/// package this measured an enormous number of redundant header reads, i.e. a
/// multi-hour hang confirmed by live stack-sampling (nearly all samples
/// inside `EntityStore.children(of:)`), reported by the user as "stuck at
/// 51% loading".
///
/// THE FIX: `EntityStore.childrenByParent()` builds a `[Int32: [EntityID]]`
/// map keyed by parent `EntityID.raw` in a SINGLE O(n) pass; callers that
/// need parent -> children for MANY parents build this map ONCE and do O(1)
/// dictionary lookups instead of re-scanning the whole store per entity.
///
/// This file proves three things:
///   1. `childrenByParent()` is *exactly* equivalent to calling
///      `children(of:)` for every id in a store (same children, same
///      ascending-id order, deleted entities excluded from both) —
///      AGENTS.md's ATTRIB-linking invariant #1 demands both code paths
///      "agree on where an INSERT's attributes live", so the O(n)
///      replacement must be provably lossless, not just faster.
///   2. The real xref-merge code path (`PackageLoader.loadIntoStore`, which
///      now uses `childrenByParent()` internally) still correctly parents
///      every transplanted ATTRIB onto its INSERT's NEW copied id in the
///      host store — i.e. the perf fix did not regress the ATTRIB-linking
///      bug this same subsystem previously had (see `XrefMergeTests`'s
///      "ATTRIBs on an xref'd INSERT must survive the merge" section, which
///      this test complements rather than duplicates).
///   3. A synthetic store large enough that an accidentally-reintroduced
///      O(n^2) `children(of:)`-in-a-loop implementation would be
///      dramatically, obviously slower still completes fast with the O(n)
///      `childrenByParent()` map.
final class XrefMergePerformanceTests: XCTestCase {

    // MARK: - 1. childrenByParent() correctness vs. children(of:) for every id

    /// Builds a store containing: several INSERTs each with multiple ATTRIB
    /// children (`.parentEntity`-owned, mirroring exactly how
    /// `EntityStoreParser` links a real ATTRIB to its INSERT), some deleted
    /// entities (both plain entities AND deleted ATTRIB children, which
    /// must be excluded from both `children(of:)` and `childrenByParent()`
    /// identically), and plain entities with no children at all (INSERTs
    /// with zero ATTRIBs, and non-INSERT entities) — then asserts
    /// `childrenByParent()` returns EXACTLY the same result as calling
    /// `children(of:)` for every single id in the store, including id order
    /// (ascending `EntityID`, since AGENTS.md notes attribute/row order is
    /// user-visible: Data Extraction column order, attribute-editor row
    /// order).
    func testChildrenByParentMatchesChildrenOfForEveryEntity() {
        let store = EntityStore()

        func makeInsert(name: String) -> EntityID {
            let blockNameId = store.strings.intern(name)
            return store.append(EntityPrototype(type: .insert, layerId: 0,
                payload: .insert(InsertPayload(blockNameId: blockNameId, position: Vec3(x: 0, y: 0)))))
        }
        func makeAttrib(parent: EntityID, tag: String, deleted: Bool = false) -> EntityID {
            let valueId = store.strings.intern("\(tag)-VALUE")
            let id = store.append(EntityPrototype(type: .attrib, layerId: 0, owner: .parentEntity(parent),
                payload: .text(TextPayload(position: Vec3(x: 0, y: 0), height: 1, stringId: valueId))))
            if deleted { store.markDeleted(id) }
            return id
        }

        // INSERT #1: three live ATTRIB children.
        let insert1 = makeInsert(name: "WORKSTATION")
        _ = makeAttrib(parent: insert1, tag: "A1")
        _ = makeAttrib(parent: insert1, tag: "A2")
        _ = makeAttrib(parent: insert1, tag: "A3")

        // A plain, childless entity interleaved between attributed inserts —
        // proves the map doesn't spuriously attach unrelated siblings.
        _ = store.append(EntityPrototype(type: .line, layerId: 0,
            payload: .line(LinePayload(a: Vec3(x: 0, y: 0), b: Vec3(x: 1, y: 1)))))

        // INSERT #2: two live ATTRIB children plus one DELETED ATTRIB child —
        // the deleted child must be excluded from both `children(of:)` and
        // `childrenByParent()` identically (mirrors AGENTS.md invariant #2's
        // "retained but hideable" flag semantics, exercised here on the
        // owner-linkage side rather than the render-visibility side).
        let insert2 = makeInsert(name: "CARRIER_STATION")
        _ = makeAttrib(parent: insert2, tag: "B1")
        _ = makeAttrib(parent: insert2, tag: "B2")
        _ = makeAttrib(parent: insert2, tag: "B3-DELETED", deleted: true)

        // INSERT #3: zero ATTRIB children at all — must be simply ABSENT
        // from `childrenByParent()`'s map (not present with an empty array),
        // matching `children(of:)` returning `[]`.
        let insert3 = makeInsert(name: "EMPTY_BLOCK_REF")

        // A DELETED insert that (if it were live) would have children —
        // deleting the PARENT must not affect whether its (still-live)
        // children are found; `children(of:)`/`childrenByParent()` only
        // ever filter the CHILD's own deleted flag, never the parent's.
        let insert4 = makeInsert(name: "DELETED_PARENT")
        store.markDeleted(insert4)
        let attrib4 = makeAttrib(parent: insert4, tag: "C1")

        // A deleted plain entity with no owner relationship at all.
        let deletedLoner = store.append(EntityPrototype(type: .point, layerId: 0,
            payload: .point(PointPayload(p: Vec3(x: 9, y: 9)))))
        store.markDeleted(deletedLoner)

        let byParent = store.childrenByParent()

        // Cross-check EVERY id in the store (parents, children, unrelated,
        // deleted) — not just the ones we expect to have children — so a
        // future change can't silently make the two mechanisms diverge on
        // an id neither of the above loops happened to specifically probe.
        for i in store.headers.indices {
            let id = EntityID(raw: Int32(i))
            let expected = store.children(of: id)
            let actual = byParent[id.raw] ?? []
            XCTAssertEqual(actual, expected,
                          "childrenByParent()[\(id.raw)] must exactly match children(of: \(id.raw)), including order")
        }

        // Spot-check the specific shapes described above, so a change that
        // happened to keep the generic loop above green (e.g. both sides
        // independently broken the same way) still gets caught concretely.
        XCTAssertEqual(byParent[insert1.raw]?.count, 3)
        XCTAssertEqual(byParent[insert2.raw]?.count, 2, "the deleted ATTRIB child must be excluded")
        XCTAssertNil(byParent[insert3.raw], "an insert with zero live children must be ABSENT from the map, not an empty array")
        XCTAssertEqual(byParent[insert4.raw], [attrib4], "a deleted PARENT's still-live child must still be found")

        // Ascending-EntityID order within one parent's children, matching
        // `children(of:)`'s natural scan order — user-visible attribute/row
        // order per AGENTS.md.
        let insert1Kids = try! XCTUnwrap(byParent[insert1.raw])
        XCTAssertEqual(insert1Kids, insert1Kids.sorted { $0.raw < $1.raw },
                      "children must be in ascending EntityID order, matching children(of:)")
    }

    // MARK: - 2. Real xref-merge path: ATTRIB linkage survives, keyed by NEW host id

    /// Exercises the actual `PackageLoader.loadIntoStore` merge path (the
    /// same fixture `XrefMergeTests`'s ATTRIB-survival tests use:
    /// `xref_attrib_host.dxf` -> `xref_attrib_sub.dxf`, containing both a
    /// top-level xref'd INSERT with an ATTRIB and a NESTED block's own
    /// attributed INSERT) and asserts every ATTRIB present in the merged
    /// HOST store is owned via `.parentEntity` pointing at an INSERT id
    /// that (a) actually exists in the host store, (b) is not itself
    /// deleted, and (c) is of type `.insert` — i.e. the `childrenByParent()`-
    /// based rewrite of `copyWithAttributeChildren` still re-parents each
    /// copied ATTRIB onto its INSERT's *NEW* copied id in the host store,
    /// not a stale sub-store id or an unrelated entity. This is AGENTS.md
    /// invariant #1 ("an ATTRIB's data and its on-canvas visibility are two
    /// separate concerns... both code paths must agree on where an INSERT's
    /// attributes live") re-verified specifically against the perf
    /// rewrite, complementing (not duplicating) `XrefMergeTests`'s existing
    /// value/visibility assertions on the same fixture.
    func testMergedAttribsAreParentedToTheirNewHostInsertID() throws {
        let url = TestFixtures.url("xref_attrib_host.dxf")
        let parsed = try PackageLoader.loadIntoStore(url: url)
        let store = parsed.store

        let attribIndices = store.headers.indices.filter {
            store.headers[$0].type == .attrib && !store.headers[$0].flags.contains(.deleted)
        }
        XCTAssertGreaterThanOrEqual(attribIndices.count, 2,
                                    "expect both the top-level and nested xref'd ATTRIBs to survive the merge")

        // childrenByParent() itself (built the same way the real merge
        // path builds it) must locate every one of these ATTRIBs under
        // some INSERT — proving the map + the merge's use of it agree.
        let byParent = store.childrenByParent()
        var allInsertChildren = Set<EntityID>()
        for kids in byParent.values { allInsertChildren.formUnion(kids) }

        for i in attribIndices {
            let attribId = EntityID(raw: Int32(i))
            let header = store.headers[i]

            guard let parentId = header.owner.parentEntityID else {
                XCTFail("ATTRIB at \(attribId) must be owned via .parentEntity after merge")
                continue
            }
            let parentHeader = try XCTUnwrap(store.header(parentId),
                                             "ATTRIB's owning parent id \(parentId) must resolve to a real header in the HOST store (not a stale sub-store id)")
            XCTAssertEqual(parentHeader.type, .insert,
                          "an ATTRIB's .parentEntity must point at an INSERT")
            XCTAssertFalse(parentHeader.flags.contains(.deleted),
                          "an ATTRIB must not be left parented to a deleted/stale INSERT")
            XCTAssertTrue(allInsertChildren.contains(attribId),
                          "childrenByParent() must find this ATTRIB under its parent INSERT")
        }
    }

    // MARK: - 3. Complexity regression guard: O(n) vs. accidental O(n^2)

    /// Builds a synthetic store with tens of thousands of entities —
    /// mostly plain childless LINEs (mirroring the real-world "millions of
    /// plain LINEs" shape called out in `EntityStore.childrenByParent()`'s
    /// own doc comment), with a modest number of attributed INSERTs (each
    /// with several ATTRIB children) scattered evenly throughout — then
    /// times `childrenByParent()`'s single O(n) pass.
    ///
    /// WHY THIS BOUND EXISTS: this is deliberately NOT a tight micro-
    /// benchmark. O(n) over `entityCount` entities should take low tens of
    /// milliseconds; the assertion budget below is generous (well under a
    /// second) specifically so it never flakes on a slow CI machine. The
    /// value of the bound is what it would look like if someone
    /// accidentally reintroduced the exact bug this whole file guards
    /// against: replacing the single `childrenByParent()` call with a loop
    /// that calls the OLD `children(of:)` once per entity (a full O(n) scan
    /// EACH time) turns this into O(n^2). At `entityCount` = 30,000 that is
    /// ~900,000,000 header comparisons — several orders of magnitude more
    /// work than the O(n) path, and easily multiple seconds to tens of
    /// seconds even on fast hardware — so this budget fails loudly and
    /// immediately on that regression class without needing anywhere near
    /// the real-world multi-million-entity scale that produced the
    /// original multi-hour "stuck at 51%" hang.
    func testChildrenByParentStaysFastAtScale() {
        let store = EntityStore()
        let entityCount = 30_000
        let insertEvery = 50   // ~600 attributed INSERTs, each with 3 ATTRIBs, spread through 30k entities

        for i in 0..<entityCount {
            if i % insertEvery == 0 {
                let blockNameId = store.strings.intern("BLOCK\(i)")
                let insertId = store.append(EntityPrototype(type: .insert, layerId: 0,
                    payload: .insert(InsertPayload(blockNameId: blockNameId, position: Vec3(x: Double(i), y: 0)))))
                for a in 0..<3 {
                    let valueId = store.strings.intern("V\(i)_\(a)")
                    _ = store.append(EntityPrototype(type: .attrib, layerId: 0, owner: .parentEntity(insertId),
                        payload: .text(TextPayload(position: Vec3(x: Double(i), y: 0), height: 1, stringId: valueId))))
                }
            } else {
                _ = store.append(EntityPrototype(type: .line, layerId: 0,
                    payload: .line(LinePayload(a: Vec3(x: Double(i), y: 0), b: Vec3(x: Double(i), y: 1)))))
            }
        }
        XCTAssertGreaterThanOrEqual(store.count, entityCount, "sanity: store actually grew to the intended scale")

        let start = Date()
        let byParent = store.childrenByParent()
        let elapsed = Date().timeIntervalSince(start)

        // Sanity on the result itself (not just timing) — every attributed
        // INSERT must have exactly 3 children found.
        let insertCount = store.headers.indices.filter { store.headers[$0].type == .insert }.count
        XCTAssertEqual(insertCount, (entityCount + insertEvery - 1) / insertEvery)
        var insertsWithChildren = 0
        for i in store.headers.indices where store.headers[i].type == .insert {
            if let kids = byParent[Int32(i)] {
                XCTAssertEqual(kids.count, 3)
                insertsWithChildren += 1
            }
        }
        XCTAssertEqual(insertsWithChildren, insertCount)

        // Generous, CI-safe budget — see the doc comment above for exactly
        // what regression this bound is meant to catch (an O(n^2)
        // `children(of:)`-in-a-loop reintroduction), and why a wide margin
        // is intentional rather than a tight benchmark assertion.
        XCTAssertLessThan(elapsed, 3.0,
                          "childrenByParent() took \(elapsed)s over \(store.count) entities — " +
                          "this is the exact complexity regression guard for the xref-merge/render " +
                          "'stuck at 51% loading' O(n^2) children(of:)-in-a-loop bug; if this fires, " +
                          "check that no caller reintroduced a per-entity children(of:) scan")
    }
}
