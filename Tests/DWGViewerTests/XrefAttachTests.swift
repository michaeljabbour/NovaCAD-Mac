import XCTest
@testable import DWGViewer
import CADCore

/// Verifies `XrefAttach.prepareAttach`/`commitAttach`/`commitDetach` — the
/// new "Attach Xref…" / "Detach" feature (attach a NEW xref block from an
/// arbitrary file at runtime, with a user-chosen layer subset; detach it
/// again). Reuses the small hand-authored xref fixtures already living in
/// `Tests/Fixtures/` (see `XrefMergeTests`'s own header comment for what
/// each contains) rather than adding new ones — `resolved_xref.dxf` is a
/// convenient attach SOURCE on its own (two layers: "0" and "XREF_LAYER",
/// a local block DECOR + its INSERT, a dangling INSERT of "GHOST", and a
/// nested xref block NESTED_XREF), and `xref_host.dxf` is a convenient HOST
/// (its own pre-existing RESOLVED_XREF/MISSING_XREF stay irrelevant/
/// untouched by these tests, confirming attach doesn't disturb them).
final class XrefAttachTests: XCTestCase {

    private func makeHost() throws -> RegenCoordinator {
        try RegenCoordinator.load(url: TestFixtures.url("xref_host.dxf"))
    }

    private func attach(_ rc: RegenCoordinator, layers: Set<String>,
                        at point: CGPoint = .zero) throws -> (id: EntityID?, blockName: String) {
        let pending = try XrefAttach.prepareAttach(
            url: TestFixtures.url("resolved_xref.dxf"), hostBlockNames: Set(rc.parsed.blocks.keys))
        var newId: EntityID?
        rc.parsed.document.transact("Attach Xref") { tx in
            newId = XrefAttach.commitAttach(pending, selectedLayerNames: layers, at: point,
                                            layerId: 0, in: rc.parsed, tx: tx)
        }
        rc.apply(rc.parsed.document.undoStack.last?.ops ?? [])
        return (newId, pending.suggestedBlockName)
    }

    // MARK: - prepareAttach

    func testPrepareAttachParsesCandidateAndSuggestsUnusedBlockName() throws {
        let host = try makeHost()
        let pending = try XrefAttach.prepareAttach(
            url: TestFixtures.url("resolved_xref.dxf"), hostBlockNames: Set(host.parsed.blocks.keys))
        // xref_host.dxf's OWN block table already has an (unresolved) block
        // named "RESOLVED_XREF" — case-insensitive dedup (see
        // `dedupedBlockName`'s doc comment) means the candidate's own
        // basename collides and must be suffixed.
        XCTAssertEqual(pending.suggestedBlockName, "resolved_xref_2")
        XCTAssertEqual(Set(pending.availableLayerNames), ["0", "XREF_LAYER"])
    }

    func testPrepareAttachDedupesBlockNameAgainstHost() throws {
        let host = try makeHost()
        var names = Set(host.parsed.blocks.keys)
        names.insert("resolved_xref")
        let pending = try XrefAttach.prepareAttach(url: TestFixtures.url("resolved_xref.dxf"), hostBlockNames: names)
        XCTAssertEqual(pending.suggestedBlockName, "resolved_xref_2")
    }

    // MARK: - commitAttach: layer filtering

    func testAttachWithNoLayersSelectedImportsNothingButRegistersTheBlock() throws {
        let host = try makeHost()
        let (id, blockName) = try attach(host, layers: [])
        XCTAssertNotNil(id, "the host INSERT itself is always created regardless of layer selection")
        let block = try XCTUnwrap(host.parsed.blocks[blockName])
        XCTAssertEqual(block.entityCount, 0, "no top-level content selected -> empty block content")
    }

    func testAttachWithOnlyLayerZeroSelectedImportsOnlyLayerZeroContent() throws {
        let host = try makeHost()
        let (_, blockName) = try attach(host, layers: ["0"])
        let block = try XCTUnwrap(host.parsed.blocks[blockName])
        // resolved_xref.dxf's model space: LINE(layer 0), CIRCLE(XREF_LAYER),
        // INSERT(DECOR, layer 0), INSERT(GHOST, XREF_LAYER), INSERT(NESTED_XREF, layer 0)
        // -> layer "0" only keeps 3 of the 5.
        XCTAssertEqual(block.entityCount, 3)
    }

    func testAttachWithAllLayersSelectedImportsEveryTopLevelEntity() throws {
        let host = try makeHost()
        let (_, blockName) = try attach(host, layers: ["0", "XREF_LAYER"])
        let block = try XCTUnwrap(host.parsed.blocks[blockName])
        XCTAssertEqual(block.entityCount, 5, "every one of the 5 model-space entities, unfiltered")
    }

    // MARK: - commitAttach: block/layer naming + nested content fidelity

    func testAttachRegistersDependentLayerNamesForNonZeroLayers() throws {
        let host = try makeHost()
        let (_, blockName) = try attach(host, layers: ["0", "XREF_LAYER"])
        XCTAssertNotNil(host.parsed.layerIdByName["\(blockName)|XREF_LAYER"])
        // Layer 0 must NOT be renamed.
        XCTAssertEqual(host.parsed.layerIdByName["0"], 0)
    }

    func testAttachTransplantsLocalBlockDefinitionVerbatimUnfiltered() throws {
        let host = try makeHost()
        // Even with ZERO top-level layers selected, DECOR (a block
        // definition, not top-level content) must still be transplanted —
        // block content isn't layer-filtered (see XrefAttach.swift's header
        // comment).
        let (_, blockName) = try attach(host, layers: [])
        let decorName = "\(blockName)$DECOR"
        let decor = try XCTUnwrap(host.parsed.blocks[decorName])
        XCTAssertEqual(decor.entityCount, 1, "DECOR's own LINE")
    }

    func testAttachRegistersNestedXrefAsUnresolvedStub() throws {
        let host = try makeHost()
        let (_, blockName) = try attach(host, layers: ["0", "XREF_LAYER"])
        let nestedName = "\(blockName)$NESTED_XREF"
        let nested = try XCTUnwrap(host.parsed.blocks[nestedName])
        XCTAssertTrue(nested.isXref)
        XCTAssertFalse(nested.wasResolved, "per this feature's documented scope, nested xrefs are NOT auto-resolved")
    }

    func testAttachedInsertRendersAtRequestedPoint() throws {
        let host = try makeHost()
        let (id, _) = try attach(host, layers: ["0", "XREF_LAYER"], at: CGPoint(x: 123, y: 456))
        let insertId = try XCTUnwrap(id)
        guard case .insert(let payload) = host.parsed.store.snapshot(insertId)?.payloadCopy else {
            return XCTFail("expected an insert payload")
        }
        XCTAssertEqual(payload.position.x, 123, accuracy: 1e-9)
        XCTAssertEqual(payload.position.y, 456, accuracy: 1e-9)
    }

    func testAttachIsUndoable() throws {
        let host = try makeHost()
        let blocksBefore = host.parsed.blocks.count
        _ = try attach(host, layers: ["0", "XREF_LAYER"])
        XCTAssertGreaterThan(host.parsed.blocks.count, blocksBefore)
        host.parsed.document.undo()
        host.fullRebuild()
        XCTAssertEqual(host.parsed.blocks.count, blocksBefore, "undo must remove every block def this attach registered")
    }

    // MARK: - Detach

    func testDetachRemovesInsertAndBlockDefinition() throws {
        let host = try makeHost()
        let (id, blockName) = try attach(host, layers: ["0", "XREF_LAYER"])
        let insertId = try XCTUnwrap(id)
        let doc = host.document
        let xref = try XCTUnwrap(doc.xrefs.first { $0.blockName == blockName })

        var removed = false
        host.parsed.document.transact("Detach") { tx in
            removed = XrefAttach.commitDetach([xref], in: host.parsed, regen: host, tx: tx)
        }
        host.apply(host.parsed.document.undoStack.last?.ops ?? [])

        XCTAssertTrue(removed)
        XCTAssertNil(host.parsed.blocks[blockName], "block definition must be unregistered")
        XCTAssertTrue(host.parsed.store.isDeleted(insertId), "the host INSERT must be tombstoned")
    }

    func testDetachAlsoRemovesNestedBlockDefinitions() throws {
        let host = try makeHost()
        let (_, blockName) = try attach(host, layers: ["0", "XREF_LAYER"])
        let nestedName = "\(blockName)$NESTED_XREF"
        let decorName = "\(blockName)$DECOR"
        XCTAssertNotNil(host.parsed.blocks[nestedName])
        XCTAssertNotNil(host.parsed.blocks[decorName])

        let doc = host.document
        let xref = try XCTUnwrap(doc.xrefs.first { $0.blockName == blockName })
        host.parsed.document.transact("Detach") { tx in
            _ = XrefAttach.commitDetach([xref], in: host.parsed, regen: host, tx: tx)
        }
        host.apply(host.parsed.document.undoStack.last?.ops ?? [])

        XCTAssertNil(host.parsed.blocks[nestedName])
        XCTAssertNil(host.parsed.blocks[decorName])
    }

    func testDetachIsUndoable() throws {
        let host = try makeHost()
        let (id, blockName) = try attach(host, layers: ["0", "XREF_LAYER"])
        let insertId = try XCTUnwrap(id)
        let blocksAfterAttach = host.parsed.blocks.count

        let doc = host.document
        let xref = try XCTUnwrap(doc.xrefs.first { $0.blockName == blockName })
        host.parsed.document.transact("Detach") { tx in
            _ = XrefAttach.commitDetach([xref], in: host.parsed, regen: host, tx: tx)
        }
        host.apply(host.parsed.document.undoStack.last?.ops ?? [])
        XCTAssertNil(host.parsed.blocks[blockName])

        host.parsed.document.undo()
        host.fullRebuild()
        XCTAssertEqual(host.parsed.blocks.count, blocksAfterAttach, "undo must re-register every removed block def")
        XCTAssertFalse(host.parsed.store.isDeleted(insertId), "undo must restore the detached INSERT")
    }

    /// Regression coverage for the "detached xref must not linger in the
    /// External References list" requirement: `document.xrefs` is fully
    /// re-derived by `fullRebuild()` from `parsed.blocks` (see
    /// `Regenerator.build`'s xref-identification pass), so once
    /// `commitDetach` unregisters the block definition, the NEXT
    /// `fullRebuild()` must not resurrect it — verified explicitly here
    /// (every existing Detach test only asserted on `parsed.blocks`/the
    /// store directly, not on the re-derived `document.xrefs` a real
    /// Layers-panel re-render actually reads).
    func testDetachedXrefDisappearsFromDocumentXrefsList() throws {
        let host = try makeHost()
        let (_, blockName) = try attach(host, layers: ["0", "XREF_LAYER"])
        XCTAssertTrue(host.document.xrefs.contains { $0.blockName == blockName },
                     "sanity check: the attach must be visible in document.xrefs before detaching")

        let xref = try XCTUnwrap(host.document.xrefs.first { $0.blockName == blockName })
        host.parsed.document.transact("Detach") { tx in
            _ = XrefAttach.commitDetach([xref], in: host.parsed, regen: host, tx: tx)
        }
        host.apply(host.parsed.document.undoStack.last?.ops ?? [])
        host.fullRebuild()

        XCTAssertFalse(host.document.xrefs.contains { $0.blockName == blockName },
                       "a detached xref must not reappear in document.xrefs")
    }

    /// Multi-select detach (new Layers-panel feature): the Layers panel can
    /// pass MULTIPLE xrefs to detach in one call when the user has
    /// Shift-clicked several rows — verify `commitDetach` handles a list
    /// spanning genuinely UNRELATED source drawings (not just the existing
    /// shared-source de-dup case `testDetachAlsoRemovesNestedBlockDefinitions`
    /// etc. already cover), removing both in one transaction/undo step.
    func testCommitDetachHandlesMultipleUnrelatedXrefsInOneCall() throws {
        let host = try makeHost()
        let doc = host.document
        // xref_host.dxf's own two pre-existing, UNRELATED stub xrefs (see
        // this file's header comment) — different block names, different
        // source drawings, no shared-source relationship at all.
        let resolvedXref = try XCTUnwrap(doc.xrefs.first { $0.blockName == "RESOLVED_XREF" })
        let missingXref = try XCTUnwrap(doc.xrefs.first { $0.blockName == "MISSING_XREF" })
        XCTAssertNotEqual(resolvedXref.sourceDrawingKey, missingXref.sourceDrawingKey)

        var removed = false
        host.parsed.document.transact("Detach") { tx in
            removed = XrefAttach.commitDetach([resolvedXref, missingXref], in: host.parsed, regen: host, tx: tx)
        }
        let undoCountBefore = host.parsed.document.undoStack.count
        host.apply(host.parsed.document.undoStack.last?.ops ?? [])
        host.fullRebuild()

        XCTAssertTrue(removed)
        XCTAssertNil(host.parsed.blocks["RESOLVED_XREF"])
        XCTAssertNil(host.parsed.blocks["MISSING_XREF"])
        XCTAssertFalse(host.document.xrefs.contains { $0.blockName == "RESOLVED_XREF" })
        XCTAssertFalse(host.document.xrefs.contains { $0.blockName == "MISSING_XREF" })
        XCTAssertEqual(host.parsed.document.undoStack.count, undoCountBefore,
                      "both removals must land in the SAME undo step (one Detach transaction)")

        host.parsed.document.undo()
        host.fullRebuild()
        XCTAssertNotNil(host.parsed.blocks["RESOLVED_XREF"], "undo must restore BOTH detached xrefs")
        XCTAssertNotNil(host.parsed.blocks["MISSING_XREF"])
    }

    // MARK: - Attached xref's ATTRIBs must survive (mirrors XrefMergeTests'
    // ordinary-xref-resolution regression coverage for the SAME real bug in
    // the SEPARATE "Attach Xref…" commit path — see that file's own header
    // comment for the full root-cause writeup).

    private func attachAttribFixture(_ rc: RegenCoordinator, layers: Set<String>) throws -> String {
        let pending = try XrefAttach.prepareAttach(
            url: TestFixtures.url("xref_attrib_sub.dxf"), hostBlockNames: Set(rc.parsed.blocks.keys))
        rc.parsed.document.transact("Attach Xref") { tx in
            _ = XrefAttach.commitAttach(pending, selectedLayerNames: layers, at: .zero,
                                        layerId: 0, in: rc.parsed, tx: tx)
        }
        rc.apply(rc.parsed.document.undoStack.last?.ops ?? [])
        return pending.suggestedBlockName
    }

    func testAttachedXrefsTopLevelInsertAttributeSurvives() throws {
        let host = try makeHost()
        _ = try attachAttribFixture(host, layers: ["0"])
        let values = host.parsed.store.headers.indices.compactMap { i -> String? in
            let h = host.parsed.store.headers[i]
            guard h.type == .attrib, !h.flags.contains(.deleted), h.payload >= 0 else { return nil }
            return host.parsed.store.strings.string(for: host.parsed.store.texts[Int(h.payload)].stringId)
        }
        XCTAssertTrue(values.contains("TOP-LEVEL-PART-42"),
                      "Attach Xref must not drop a top-level xref'd INSERT's ATTRIB, got \(values)")
    }

    func testAttachedXrefsNestedBlockInsertAttributeAlsoSurvives() throws {
        let host = try makeHost()
        _ = try attachAttribFixture(host, layers: ["0"])
        let values = host.parsed.store.headers.indices.compactMap { i -> String? in
            let h = host.parsed.store.headers[i]
            guard h.type == .attrib, !h.flags.contains(.deleted), h.payload >= 0 else { return nil }
            return host.parsed.store.strings.string(for: host.parsed.store.texts[Int(h.payload)].stringId)
        }
        XCTAssertTrue(values.contains("NESTED-PART-99"),
                      "Attach Xref must not drop a NESTED block's attributed INSERT's ATTRIB either, got \(values)")
    }

    func testAttachedXrefAttribsStayParentedNotFlattenedToBlockContent() throws {
        let host = try makeHost()
        _ = try attachAttribFixture(host, layers: ["0"])
        for i in host.parsed.store.headers.indices {
            let h = host.parsed.store.headers[i]
            guard h.type == .attrib, !h.flags.contains(.deleted) else { continue }
            XCTAssertNotNil(h.owner.parentEntityID,
                            "every attached xref's ATTRIB must stay owned via .parentEntity")
        }
    }

    func testXrefsAffectedByDetachListsOnlyMatchingSourceDrawing() throws {
        let host = try makeHost()
        _ = try attach(host, layers: ["0", "XREF_LAYER"])
        let doc = host.document
        let preExisting = try XCTUnwrap(doc.xrefs.first { $0.blockName == "RESOLVED_XREF" })
        let affected = XrefAttach.xrefsAffectedByDetach(preExisting, in: doc)
        XCTAssertTrue(affected.allSatisfy { $0.sourceDrawingKey == preExisting.sourceDrawingKey })
        XCTAssertTrue(affected.contains { $0.blockName == "RESOLVED_XREF" })
        // The freshly-attached "resolved_xref" xref shares the SAME source
        // drawing (both point at resolved_xref.dxf) — the whole point of
        // `xrefsAffectedByDetach`'s de-dup scoping (see its own doc comment).
        XCTAssertTrue(affected.contains { $0.blockName.lowercased() == "resolved_xref" },
                     "attaching the same source drawing a second (differently-named) time must show up as sharing the source")
    }
}
