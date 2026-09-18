import XCTest
@testable import DWGViewer
import CADCore

/// Verifies `PackageLoader.loadIntoStore` (the EntityStore-level xref merge,
/// added alongside the eager `EntityStoreParser`/`Regenerator` path) against
/// the OLD `PackageLoader.load`/`DXFParser`/`GeometryBuilder` path it must
/// match exactly, on a small hand-authored xref fixture set:
///
///   xref_host.dxf       — host: RESOLVED_XREF (resolvable sibling),
///                         MISSING_XREF (deliberately unresolvable), plus
///                         host-local geometry on layer 0 and HOST_LAYER.
///   resolved_xref.dxf   — the resolvable xref: model-space geometry on its
///                         own layer 0 and XREF_LAYER, a local block DECOR
///                         (+ INSERT of it), a DANGLING INSERT of "GHOST"
///                         (no such block defined anywhere in this file —
///                         exercises the "unconditional rename even when
///                         dangling" safety rule), and a nested xref block
///                         NESTED_XREF pointing at nested_xref.dxf.
///   nested_xref.dxf     — third file, only reachable through the nested
///                         xref chain: geometry on layer 0 and NESTED_LAYER.
///
/// Every assertion here is made against BOTH paths and checked equal, so a
/// regression in either path's merge logic fails loudly.
///
/// KNOWN, PRE-EXISTING, OUT-OF-SCOPE DIVERGENCE (not introduced by the xref
/// merge work, and not fixed here — see `testMissingXrefInsertCountDivergesFromOldPath`):
/// `GeometryBuilder.walk` (old path) registers an `InsertInstance` for ANY
/// INSERT whose named block merely EXISTS (`raw.blocks[ins.name] != nil`),
/// even one with zero entities (an unresolved xref stub, or any ordinary
/// empty block). `Regenerator.walk` (new path) additionally requires
/// `block.entityCount > 0`. This means `doc.inserts.count` can differ by
/// exactly the number of INSERTs referencing an empty/unresolved block —
/// reproducible on a single PLAIN file with an INSERT of a genuinely empty
/// local block, no xrefs involved at all, so it predates and is independent
/// of this phase's xref work. `Regenerator.swift` is out of scope for this
/// change (a parallel effort owns it) — flagged here rather than patched.
final class XrefMergeTests: XCTestCase {

    private func loadBoth() throws -> (old: DXFDocument, new: DXFDocument) {
        let url = TestFixtures.url("xref_host.dxf")
        let old = try PackageLoader.load(url: url)
        let parsed = try PackageLoader.loadIntoStore(url: url)
        let new = Regenerator.build(from: parsed, parseSeconds: 0) { _ in }
        return (old, new)
    }

    // MARK: - Entity / layer / group counts match exactly

    func testEntityCountsMatch() throws {
        let (old, new) = try loadBoth()
        XCTAssertEqual(new.stats.totalEntities, old.stats.totalEntities)
        XCTAssertGreaterThan(old.stats.totalEntities, 0)
    }

    func testLayerListsMatchExactly() throws {
        let (old, new) = try loadBoth()
        let oldNames = old.layers.map(\.name).sorted()
        let newNames = new.layers.map(\.name).sorted()
        XCTAssertEqual(oldNames, newNames)

        // AutoCAD dependent layer naming: sub layer 0 must NOT be renamed;
        // every other sub-layer becomes "XREFNAME|layer".
        XCTAssertTrue(oldNames.contains("0"))
        XCTAssertTrue(oldNames.contains("HOST_LAYER"))
        XCTAssertTrue(oldNames.contains("RESOLVED_XREF|XREF_LAYER"))
        // Nested-xref layer naming: the inner merge (resolved_xref.dxf
        // pulling in nested_xref.dxf) renames NESTED_LAYER to
        // "NESTED_XREF|NESTED_LAYER" INSIDE resolved_xref.dxf's own layer
        // table first; the outer merge (host pulling in resolved_xref.dxf)
        // then re-prefixes every one of its layers with "RESOLVED_XREF|",
        // landing on "RESOLVED_XREF|NESTED_XREF|NESTED_LAYER" — a chained
        // "|" prefix, not "$" (block names use "$", layer dependent-names
        // always use "|", regardless of nesting depth).
        XCTAssertTrue(oldNames.contains("RESOLVED_XREF|NESTED_XREF|NESTED_LAYER"),
                      "nested xref's layer must be chain-dependent-named through both merge levels")
        XCTAssertFalse(oldNames.contains("XREF_LAYER"), "sub-layer must never appear un-prefixed")
    }

    func testGroupCountsMatch() throws {
        let (old, new) = try loadBoth()
        XCTAssertEqual(new.modelGroups.count, old.modelGroups.count)
        XCTAssertEqual(new.paperGroups.count, old.paperGroups.count)
    }

    func testBoundsMatchExactly() throws {
        let (old, new) = try loadBoth()
        XCTAssertEqual(new.modelBounds, old.modelBounds)
        XCTAssertEqual(new.paperBounds, old.paperBounds)
    }

    // MARK: - Xref bookkeeping (resolved / unresolved / nested / block naming)

    func testResolvedXrefIsResolvedWithExpectedEntityCount() throws {
        let (old, new) = try loadBoth()
        for doc in [old, new] {
            let x = try XCTUnwrap(doc.xrefs.first { $0.blockName == "RESOLVED_XREF" })
            XCTAssertTrue(x.isResolved)
            // model space: LINE + CIRCLE + INSERT(DECOR) + INSERT(GHOST, dangling)
            // + INSERT(NESTED_XREF) = 5 raw entities transplanted as this
            // block's content (post-expansion counting happens elsewhere;
            // this is the raw transplanted content count Regenerator reports).
            XCTAssertEqual(x.entityCount, 5)
            XCTAssertEqual(x.insertCount, 1, "exactly one host INSERT references RESOLVED_XREF")
        }
    }

    func testMissingXrefStaysUnresolved() throws {
        let (old, new) = try loadBoth()
        for doc in [old, new] {
            let x = try XCTUnwrap(doc.xrefs.first { $0.blockName == "MISSING_XREF" })
            XCTAssertFalse(x.isResolved, "a file that genuinely doesn't exist must stay unresolved")
            XCTAssertEqual(x.entityCount, 0)
            XCTAssertEqual(x.insertCount, 1)
        }
    }

    func testNestedXrefResolvesRecursivelyWithDoublePrefixedBlockName() throws {
        let (old, new) = try loadBoth()
        for doc in [old, new] {
            let x = try XCTUnwrap(doc.xrefs.first { $0.blockName == "RESOLVED_XREF$NESTED_XREF" },
                                  "nested xref must be transplanted under the double-dependent name")
            XCTAssertTrue(x.isResolved)
            XCTAssertEqual(x.entityCount, 2, "nested_xref.dxf's model space: LINE + CIRCLE")
        }
    }

    func testLocalBlockInsideXrefGetsDependentBlockNameAndRenders() throws {
        let (old, new) = try loadBoth()
        // DECOR (a plain, non-xref local block defined inside resolved_xref.dxf)
        // must be transplanted as "RESOLVED_XREF$DECOR" and actually
        // contribute geometry when RESOLVED_XREF's INSERT expands — verified
        // via the already-asserted-equal modelBounds/stats.totalEntities
        // (both include DECOR's LINE at (30,30)-(32,32) local, transformed
        // through the RESOLVED_XREF insert) and, directly here, via the
        // per-layer expansion count on "0" (DECOR's LINE lands on layer 0,
        // same as the two direct-model-space entities on layer 0 inside
        // resolved_xref.dxf's LINE/CIRCLE... only LINE is on "0" there,
        // CIRCLE is on XREF_LAYER, so "0" picks up: host's own LINE (1) +
        // resolved_xref.dxf's LINE (1) + DECOR's LINE via its INSERT (1) +
        // nested_xref.dxf's LINE (1) = 4, matching `--layer-counts`'s
        // observed "layer: 0 = 4" for both paths).
        for doc in [old, new] {
            let zero = try XCTUnwrap(doc.layers.first { $0.name == "0" })
            XCTAssertEqual(zero.entityCount, 4)
        }
    }

    /// See the class-level doc comment: `doc.inserts.count` differs between
    /// the two paths for this fixture ONLY because of a pre-existing,
    /// out-of-scope `GeometryBuilder` vs `Regenerator` divergence on
    /// zero-entity blocks (MISSING_XREF, deliberately unresolvable) — not
    /// because of anything the xref-merge work changed. This test PINS that
    /// known difference (rather than silently asserting false equality) so
    /// a future fix to `Regenerator`/`GeometryBuilder` parity is visible as
    /// an intentional test update, not a silent regression.
    func testMissingXrefInsertCountDivergesFromOldPathPreExistingReason() throws {
        let (old, new) = try loadBoth()
        XCTAssertEqual(old.inserts.count, 2, "old path registers an InsertInstance for MISSING_XREF even though it has 0 entities")
        XCTAssertEqual(new.inserts.count, 1, "new path's Regenerator requires block.entityCount > 0 to register an InsertInstance (pre-existing Regenerator behavior, out of scope here)")
    }

    func testDanglingInsertInsideXrefDoesNotBindToUnrelatedHostBlock() throws {
        // "GHOST" is INSERTed inside resolved_xref.dxf but never defined
        // there. PackageLoader.merge's safety rule renames it unconditionally
        // to "RESOLVED_XREF$GHOST" — even though no such block definition
        // exists, so it silently fails to expand (renders nothing) instead of
        // ever being able to accidentally bind to some unrelated host block
        // literally named "GHOST". Both paths must agree there is no
        // "GHOST"-named block anywhere and no crash/hang resulted.
        let (old, new) = try loadBoth()
        XCTAssertEqual(new.stats.totalEntities, old.stats.totalEntities)
        // A resilient parse: dangling reference must not throw, hang, or
        // silently swallow the OTHER entities transplanted alongside it.
        for doc in [old, new] {
            let x = try XCTUnwrap(doc.xrefs.first { $0.blockName == "RESOLVED_XREF" })
            XCTAssertEqual(x.entityCount, 5, "the dangling INSERT still counts as transplanted content")
        }
    }

    // Pixel parity (old CLI path vs --new-path CLI path, same fixture) is
    // verified via the built binary's own `--snapshot`/`--compare
    // --tolerance 0` harness — see the process notes in the final report for
    // the exact command and result. Not re-implemented here since
    // `SnapshotMode`'s render/compare helpers are `exit()`-driven CLI
    // plumbing, not a reusable in-process API; the bounds/group-count/layer-
    // name/xref-bookkeeping assertions above are the in-process equivalent
    // (same technique `ParserRetentionTests` already uses for the
    // single-file case).

    // MARK: - Single-file (no-xref) case still reduces to a plain parse

    func testSingleFileFixtureStillLoadsWithLoadIntoStore() throws {
        // basic_entities.dxf has no xrefs at all — loadIntoStore must reduce
        // to a plain EntityStoreParser.parse with no merge overhead, and
        // still match the old path exactly (regression guard for the
        // existing single-file EntityStoreParser/Regenerator parity).
        let url = TestFixtures.url("basic_entities.dxf")
        let old = try PackageLoader.load(url: url)
        let parsed = try PackageLoader.loadIntoStore(url: url)
        let new = Regenerator.build(from: parsed, parseSeconds: 0) { _ in }
        XCTAssertEqual(new.stats.totalEntities, old.stats.totalEntities)
        XCTAssertEqual(new.modelBounds, old.modelBounds)
        XCTAssertTrue(new.xrefs.isEmpty)
    }

    // MARK: - ATTRIBs on an xref'd INSERT must survive the merge (real bug)
    //
    // A real user report: attribute text on a block reference (INSERT)
    // displayed correctly when the containing drawing was opened DIRECTLY,
    // but was missing entirely when the SAME drawing was viewed as an XREF
    // attached to a host. Root cause: `mergeIntoStore`'s top-level-content
    // copy loop only copied entities satisfying `owner.isModel` — an
    // ATTRIB owned via `.parentEntity(insertId)` (exactly how
    // `EntityStoreParser` already links ATTRIBs to their INSERT, correctly,
    // on a direct open) can never satisfy that test, so the ATTRIBs were
    // silently OMITTED from the host store entirely during the xref
    // transplant, before `Regenerator`'s (already-correct) render walk ever
    // ran. Fixture: xref_attrib_host.dxf (one INSERT of ATTR_XREF) ->
    // xref_attrib_sub.dxf, which has BOTH failure shapes in one file:
    //   - a TOP-LEVEL model-space INSERT of PARTBLOCK with one ATTRIB
    //     (tag PARTNO, value "TOP-LEVEL-PART-42") — the reported bug shape.
    //   - a NESTED block (CONTAINERBLOCK) containing its OWN INSERT of
    //     PARTBLOCK with its own ATTRIB (value "NESTED-PART-99") — the
    //     second failure shape found during investigation, where a
    //     contiguous-range `transplant` unconditionally overwrote every
    //     entity's owner to the fixed block-content owner, severing a
    //     nested attributed INSERT's link the same way.

    private func loadAttribFixture() throws -> (parsed: EditableParsedDocument, doc: DXFDocument) {
        let url = TestFixtures.url("xref_attrib_host.dxf")
        let parsed = try PackageLoader.loadIntoStore(url: url)
        let doc = Regenerator.build(from: parsed, parseSeconds: 0) { _ in }
        return (parsed, doc)
    }

    func testTopLevelXrefInsertsAttributeSurvivesTheMerge() throws {
        let (parsed, doc) = try loadAttribFixture()
        // The xref's block content must actually contain the ATTRIB
        // entity now (not just render it — the merge must have COPIED it
        // into the host store at all).
        let attribHeaders = parsed.store.headers.indices.filter { i in
            parsed.store.headers[i].type == .attrib && !parsed.store.headers[i].flags.contains(.deleted)
        }
        XCTAssertFalse(attribHeaders.isEmpty, "the xref's top-level INSERT's ATTRIB must be copied into the host store")

        // And it must be correctly PARENTED to its INSERT (not merely
        // present as orphaned block content) — `children(of:)` must find it.
        let insertHeaders = parsed.store.headers.indices.filter { i in
            parsed.store.headers[i].type == .insert && !parsed.store.headers[i].flags.contains(.deleted)
        }
        var foundParented = false
        for i in insertHeaders {
            let children = parsed.store.children(of: EntityID(raw: Int32(i)))
            if children.contains(where: { parsed.store.header($0)?.type == .attrib }) {
                foundParented = true
            }
        }
        XCTAssertTrue(foundParented, "at least one xref'd INSERT must have its ATTRIB correctly parented via .parentEntity")

        // The value itself must round-trip correctly, not just SOME attrib.
        let values = attribHeaders.compactMap { i -> String? in
            let h = parsed.store.headers[i]
            guard h.payload >= 0 else { return nil }
            return parsed.store.strings.string(for: parsed.store.texts[Int(h.payload)].stringId)
        }
        XCTAssertTrue(values.contains("TOP-LEVEL-PART-42"),
                      "the top-level xref'd INSERT's real ATTRIB value must survive the merge, got \(values)")

        // And it must actually be VISIBLE on canvas — this is what the user
        // experiences directly: Regenerator's render walk must find it via
        // the same store.children(of:) mechanism.
        XCTAssertGreaterThan(doc.modelGroups.reduce(0) { $0 + $1.texts.count }, 0,
                            "the xref'd attribute text must actually render, not just exist in the store")
    }

    func testNestedBlockXrefInsertsAttributeAlsoSurvivesTheMerge() throws {
        let (parsed, _) = try loadAttribFixture()
        let values = parsed.store.headers.indices.compactMap { i -> String? in
            let h = parsed.store.headers[i]
            guard h.type == .attrib, !h.flags.contains(.deleted), h.payload >= 0 else { return nil }
            return parsed.store.strings.string(for: parsed.store.texts[Int(h.payload)].stringId)
        }
        XCTAssertTrue(values.contains("NESTED-PART-99"),
                      "a NESTED block's own attributed INSERT must also survive the merge with its ATTRIB intact, got \(values)")
    }

    func testXrefAttribsAreNeverMisownedAsFlatBlockContent() throws {
        // The second failure shape's specific symptom: a nested attributed
        // INSERT's ATTRIB getting its owner silently overwritten from
        // `.parentEntity` to plain `.block(index)` content (present in the
        // store, but no longer linked to anything — `children(of:)` finds
        // nothing, `BlockEditor.attributes` returns empty). Confirms every
        // copied ATTRIB in the host store is STILL owned via `.parentEntity`,
        // never flattened to raw block geometry.
        let (parsed, _) = try loadAttribFixture()
        for i in parsed.store.headers.indices {
            let h = parsed.store.headers[i]
            guard h.type == .attrib, !h.flags.contains(.deleted) else { continue }
            XCTAssertNotNil(h.owner.parentEntityID,
                            "every ATTRIB in the host store must stay owned via .parentEntity, never flattened to block content")
        }
    }
}
