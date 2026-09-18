import XCTest
import CoreGraphics
@testable import DWGViewer
import CADCore

/// Phase 3.1 verification: parse -> write(DXFStructuralWriter) -> re-parse ->
/// assert semantic equality, for both AC1015 (the common case: handles,
/// lineweight, true color all fine) and AC1009/R12 (the degrade path).
final class RoundTripTests: XCTestCase {

    private func parse(_ name: String) throws -> EditableParsedDocument {
        try PackageLoader.loadIntoStore(url: TestFixtures.url(name))
    }

    /// Writes `parsed` at `version` to a fresh temp file and re-parses it,
    /// returning the re-parsed document for assertions.
    private func roundTrip(_ parsed: EditableParsedDocument, version: DXFVersion = .r2000) throws
        -> (reparsed: EditableParsedDocument, warnings: [WriteWarning], url: URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("roundtrip-\(UUID().uuidString).dxf")
        let warnings = try DXFStructuralWriter.write(parsed, to: tmp, options: DXFWriteOptions(version: version))
        let reparsed = try PackageLoader.loadIntoStore(url: tmp)
        return (reparsed, warnings, tmp)
    }

    private func countsByType(_ store: EntityStore) -> [DXFEntityType: Int] {
        var counts: [DXFEntityType: Int] = [:]
        for h in store.headers where !h.flags.contains(.deleted) {
            counts[h.type, default: 0] += 1
        }
        return counts
    }

    // MARK: - Phase 3.2: Save persists LIVE EDITS, not just a fresh parse
    //
    // Every other test in this file round-trips a document straight off
    // disk. `ContentView.saveDrawing`/`saveDrawingAs` instead call
    // `DXFStructuralWriter.write` on `session.regen.parsed` AFTER the user
    // has made live edits via the ordinary `EditableDocument.transact`
    // path (MOVE/COPY/ARRAY/new entities/etc) — this test exercises that
    // exact shape (parse a real fixture, mutate its `parsed.document` via a
    // transaction exactly like a live edit would, THEN write+reparse),
    // which nothing else here covers.
    func testEditAppliedAfterParseSurvivesWriteAndReparse() throws {
        let parsed = try parse("roundtrip_core.dxf")
        let before = countsByType(parsed.store)[.line] ?? 0
        // This fixture also has 2 face3d edge-fragments that themselves
        // round-trip AS lines (see `testFace3DEdgeFragmentsRoundTripAsLines`'s
        // doc comment) — account for those separately so this test isn't
        // coupled to that unrelated, already-covered quirk.
        let face3dAsLines = countsByType(parsed.store)[.face3d] ?? 0

        parsed.document.transact("add line") { tx in
            _ = tx.add(EntityPrototype(type: .line, layerId: 0,
                payload: .line(LinePayload(a: Vec3(x: 111, y: 222), b: Vec3(x: 333, y: 444)))))
        }
        XCTAssertEqual(countsByType(parsed.store)[.line] ?? 0, before + 1,
                       "sanity check: the transaction itself must have added exactly one live LINE")

        let (reparsed, warnings, url) = try roundTrip(parsed)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(warnings.isEmpty)
        XCTAssertEqual(countsByType(reparsed.store)[.line] ?? 0, before + 1 + face3dAsLines,
                       "a LINE added via a live transaction AFTER parse must still be in the file post-save")
        XCTAssertTrue(reparsed.store.headers.contains { h in
            guard h.type == .line, !h.flags.contains(.deleted) else { return false }
            let p = reparsed.store.lines[Int(h.payload)]
            return p.a.x == 111 && p.a.y == 222 && p.b.x == 333 && p.b.y == 444
        }, "the specific line's coordinates must survive the write+reparse exactly")
    }

    // MARK: - AC1015 round trip: entity counts per type

    func testCoreFixtureEntityCountsMatchAfterRoundTrip() throws {
        let parsed = try parse("roundtrip_core.dxf")
        var before = countsByType(parsed.store)
        let (reparsed, warnings, url) = try roundTrip(parsed)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(warnings.isEmpty, "AC1015 write should not need any degrade warnings: \(warnings)")
        let after = countsByType(reparsed.store)
        // Known, INTENTIONAL type change (see `testFace3DEdgeFragmentsRoundTripAsLines`'s
        // doc comment): a face3d entity with fewer than 3 vertices (a
        // per-edge-invisibility fragment) has no valid 3DFACE DXF
        // representation, so it's written — and therefore reparses — as a
        // LINE. Adjust the expected counts to reflect that single
        // documented exception before comparing everything else exactly.
        let face3dCount = before[.face3d] ?? 0
        before.removeValue(forKey: .face3d)
        if face3dCount > 0 { before[.line, default: 0] += face3dCount }
        let afterNonZero = after.filter { $0.value != 0 }
        XCTAssertEqual(before, afterNonZero, "per-type entity counts must match exactly after an AC1015 round trip "
                       + "(modulo the documented face3d-fragment -> line exception)")
    }

    /// Regression test for a real bug found via `--roundtrip` on the 731MB
    /// production file: a 3DFACE with per-edge invisibility (group 70) gets
    /// split at PARSE time into independent 2-vertex `.face3d`-typed
    /// fragments (see EntityStoreParser.swift's `invisible != 0` branch).
    /// Writing one of those fragments back out as a "3DFACE" record (which
    /// needs >= 3 vertices) silently failed to reparse — ~19,855 of ~19,971
    /// face3d entities vanished on the real file, almost entirely from one
    /// dense edge-fragment mesh. Fixed by writing a 2-vertex face3d fragment
    /// as a LINE instead. `roundtrip_core.dxf`'s 3DFACE (handle 112, group
    /// 70 = 3 -> edges 1,2 invisible, edges 0,3 visible) exercises exactly
    /// this path: it must parse into 2 face3d-typed fragments, and BOTH must
    /// survive an AC1015 round trip.
    func testFace3DEdgeFragmentsRoundTripAsLines() throws {
        let parsed = try parse("roundtrip_core.dxf")
        let before = parsed.store.headers.filter { $0.type == .face3d && !$0.flags.contains(.deleted) }.count
        XCTAssertEqual(before, 2, "fixture's invisible-edge 3DFACE must parse into 2 visible-edge fragments")
        let linesBefore = parsed.store.headers.filter { $0.type == .line && !$0.flags.contains(.deleted) }.count

        let (reparsed, warnings, url) = try roundTrip(parsed)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(warnings.isEmpty)
        // A 2-vertex face3d fragment's only faithful DXF shape IS a LINE
        // (a "3DFACE" record needs >= 3 vertices to even be valid) — so
        // this writer deliberately emits it as one, meaning it reparses as
        // `.line`, not `.face3d`. That's a correct, intentional type change
        // on round trip (not a bug): what matters is the GEOMETRY (2 extra
        // line segments) survives, not that the original internal type
        // label is preserved for a shape DXF has no valid record for.
        let linesAfter = reparsed.store.headers.filter { $0.type == .line && !$0.flags.contains(.deleted) }.count
        XCTAssertEqual(linesAfter, linesBefore + 2, "both face3d edge fragments must survive an AC1015 round trip, as LINEs")
        let face3dAfter = reparsed.store.headers.filter { $0.type == .face3d && !$0.flags.contains(.deleted) }.count
        XCTAssertEqual(face3dAfter, 0, "no genuine (>=3-vertex) face3d in this fixture, so none should remain")
    }

    // MARK: - Resolved xref content must round-trip (not stub out real content)

    /// Regression test for a second real bug found via `--roundtrip` on the
    /// 731MB production file: a RESOLVED xref block (content actually
    /// loaded via `PackageLoader.mergeIntoStore`, `wasResolved == true`)
    /// was being treated identically to an UNRESOLVED one and written as an
    /// empty stub, silently discarding 10,483 polylines belonging to a
    /// single resolved xref block. Uses the existing xref fixture pair
    /// (`xref_host.dxf` + `resolved_xref.dxf`, sibling files so
    /// `PackageLoader.loadIntoStore`'s xref resolution finds the xref
    /// automatically) already used by `XrefMergeTests`.
    func testResolvedXrefBlockContentSurvivesRoundTrip() throws {
        let parsed = try PackageLoader.loadIntoStore(url: TestFixtures.url("xref_host.dxf"))
        let resolvedBlock = try XCTUnwrap(parsed.blocks.first { $0.value.isXref && $0.value.wasResolved }?.value,
                                         "fixture must have at least one resolved xref block")
        XCTAssertGreaterThan(resolvedBlock.entityCount, 0, "the resolved xref block must actually carry content before the round trip")

        let (reparsed, warnings, url) = try roundTrip(parsed)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(warnings.isEmpty)

        let reparsedBlock = try XCTUnwrap(reparsed.blocks[resolvedBlock.name],
                                          "the resolved xref block must still exist under the same name after round trip")
        XCTAssertEqual(reparsedBlock.entityCount, resolvedBlock.entityCount,
                      "resolved xref content must NOT be discarded as an empty stub on write")
    }

    // MARK: - Coordinate fidelity (|delta| < 1e-9)

    func testLineCoordinatesRoundTripExactly() throws {
        let parsed = try parse("roundtrip_core.dxf")
        let (reparsed, _, url) = try roundTrip(parsed)
        defer { try? FileManager.default.removeItem(at: url) }

        guard let lineID = reparsed.store.headers.indices.first(where: { reparsed.store.headers[$0].type == .line }) else {
            return XCTFail("no LINE found after round trip")
        }
        let h = reparsed.store.headers[lineID]
        let p = reparsed.store.lines[Int(h.payload)]
        XCTAssertEqual(p.a.x, 0, accuracy: 1e-9)
        XCTAssertEqual(p.a.y, 0, accuracy: 1e-9)
        XCTAssertEqual(p.b.x, 100, accuracy: 1e-9)
        XCTAssertEqual(p.b.y, 50, accuracy: 1e-9)
    }

    func testCircleCenterAndRadiusRoundTripExactly() throws {
        let parsed = try parse("roundtrip_core.dxf")
        let (reparsed, _, url) = try roundTrip(parsed)
        defer { try? FileManager.default.removeItem(at: url) }

        let circles = reparsed.store.headers.indices.filter { reparsed.store.headers[$0].type == .circle }
        XCTAssertEqual(circles.count, 2, "one top-level CIRCLE + one inside the SYM1 block")
        // The model-space (non-block-owned) circle should be the (50,25) r=20 one.
        let modelCircle = circles.first { reparsed.store.headers[$0].owner.isModel }
        let h = try XCTUnwrap(modelCircle.map { reparsed.store.headers[$0] })
        let p = reparsed.store.circles[Int(h.payload)]
        XCTAssertEqual(p.center.x, 50, accuracy: 1e-9)
        XCTAssertEqual(p.center.y, 25, accuracy: 1e-9)
        XCTAssertEqual(p.radius, 20, accuracy: 1e-9)
        // Its ACI 3 (green) color must also survive.
        XCTAssertEqual(h.aci, 3)
    }

    func testLwpolylineVerticesAndBulgeRoundTripExactly() throws {
        let parsed = try parse("roundtrip_core.dxf")
        let (reparsed, _, url) = try roundTrip(parsed)
        defer { try? FileManager.default.removeItem(at: url) }

        guard let idx = reparsed.store.headers.indices.first(where: { reparsed.store.headers[$0].type == .lwpolyline }) else {
            return XCTFail("no LWPOLYLINE found after round trip")
        }
        let h = reparsed.store.headers[idx]
        let p = reparsed.store.polylines[Int(h.payload)]
        XCTAssertEqual(Int(p.vertsCount), 4)
        XCTAssertTrue(p.closed)
        let verts = Array(reparsed.store.vertexArena[Int(p.vertsStart)..<Int(p.vertsStart + p.vertsCount)])
        let bulges = Array(reparsed.store.scalarArena[Int(p.bulgesStart)..<Int(p.bulgesStart) + Int(p.vertsCount)])
        XCTAssertEqual(verts[0].x, 0, accuracy: 1e-9)
        XCTAssertEqual(verts[0].y, 150, accuracy: 1e-9)
        XCTAssertEqual(bulges[0], 1.0, accuracy: 1e-9)
    }

    func testSplineControlPointsKnotsWeightsRoundTripExactly() throws {
        let parsed = try parse("roundtrip_core.dxf")
        let (reparsed, _, url) = try roundTrip(parsed)
        defer { try? FileManager.default.removeItem(at: url) }

        guard let idx = reparsed.store.headers.indices.first(where: { reparsed.store.headers[$0].type == .spline }) else {
            return XCTFail("no SPLINE found after round trip")
        }
        let h = reparsed.store.headers[idx]
        let p = reparsed.store.splines[Int(h.payload)]
        XCTAssertEqual(Int(p.controlCount), 4)
        XCTAssertEqual(Int(p.knotCount), 8)
        let control = Array(reparsed.store.vertexArena[Int(p.controlStart)..<Int(p.controlStart + p.controlCount)])
        XCTAssertEqual(control[1].x, 10, accuracy: 1e-9)
        XCTAssertEqual(control[1].y, 20, accuracy: 1e-9)
    }

    func testHatchLoopRoundTripsExactly() throws {
        let parsed = try parse("roundtrip_core.dxf")
        let (reparsed, _, url) = try roundTrip(parsed)
        defer { try? FileManager.default.removeItem(at: url) }

        guard let idx = reparsed.store.headers.indices.first(where: { reparsed.store.headers[$0].type == .hatch }) else {
            return XCTFail("no HATCH found after round trip")
        }
        let h = reparsed.store.headers[idx]
        let p = reparsed.store.hatches[Int(h.payload)]
        XCTAssertTrue(p.isSolid)
        XCTAssertEqual(Int(p.loopRangeCount), 1)
        let range = reparsed.store.hatchLoopRanges[Int(p.loopRangeStart)]
        XCTAssertEqual(Int(range.vertCount), 4)
    }

    func testTextAndMTextStringsSurvive() throws {
        let parsed = try parse("roundtrip_core.dxf")
        let (reparsed, _, url) = try roundTrip(parsed)
        defer { try? FileManager.default.removeItem(at: url) }

        guard let textIdx = reparsed.store.headers.indices.first(where: { reparsed.store.headers[$0].type == .text }) else {
            return XCTFail("no TEXT found after round trip")
        }
        let th = reparsed.store.headers[textIdx]
        let tp = reparsed.store.texts[Int(th.payload)]
        XCTAssertEqual(reparsed.store.strings.string(for: tp.stringId), "FIXTURE TEXT")

        guard let mtextIdx = reparsed.store.headers.indices.first(where: { reparsed.store.headers[$0].type == .mtext }) else {
            return XCTFail("no MTEXT found after round trip")
        }
        let mh = reparsed.store.headers[mtextIdx]
        let mp = reparsed.store.mtexts[Int(mh.payload)]
        let text = reparsed.store.strings.string(for: mp.stringId)
        XCTAssertTrue(text.contains("Line one"))
        XCTAssertTrue(text.contains("Line two"))
    }

    func testInsertWithAttribRoundTrips() throws {
        let parsed = try parse("roundtrip_core.dxf")
        let (reparsed, _, url) = try roundTrip(parsed)
        defer { try? FileManager.default.removeItem(at: url) }

        guard let insIdx = reparsed.store.headers.indices.first(where: { reparsed.store.headers[$0].type == .insert }) else {
            return XCTFail("no INSERT found after round trip")
        }
        let insertId = EntityID(raw: Int32(insIdx))
        let ih = reparsed.store.headers[insIdx]
        let ip = reparsed.store.inserts[Int(ih.payload)]
        XCTAssertEqual(reparsed.store.strings.string(for: ip.blockNameId), "SYM1")
        XCTAssertEqual(ip.position.x, 5, accuracy: 1e-9)
        XCTAssertEqual(ip.scale.x, 2, accuracy: 1e-9)
        XCTAssertEqual(ip.rotationDeg, 45, accuracy: 1e-9)

        // Regression coverage for a real bug this session fixed: an ATTRIB
        // immediately following an INSERT in a REAL PARSED FILE (this
        // fixture's own INSERT/ATTRIB/SEQEND sequence — see
        // `EntityStoreParser.swift`'s `lastInsertId` and its "ATTRIB" case)
        // must now be wired up with `owner: .parentEntity(insertId)`, exactly
        // like `BlockEditor.insert(...)` already does for interactively-
        // created attributes — NOT left as an unrelated top-level entity.
        // Without this, `BlockEditor.attributes(of:in:)`/`EntityStore
        // .children(of:)` (both keyed on `owner.parentEntityID`) silently
        // returned EMPTY for every INSERT parsed from a file, which is what
        // caused Data Extraction's `attr:<TAG>` columns (e.g. a "Contents"
        // attribute) to come back blank for real drawings.
        let children = reparsed.store.children(of: insertId)
        XCTAssertEqual(children.count, 1, "the parsed ATTRIB must resolve as this INSERT's child via owner.parentEntityID")
        let attrs = BlockEditor.attributes(of: insertId, in: reparsed.store)
        XCTAssertEqual(attrs.count, 1)
        XCTAssertEqual(attrs.first?.value, "ATTVAL", "the fixture's ATTRIB value (see roundtrip_core.dxf) must be readable via BlockEditor.attributes")

        // The round trip through the writer (which only emits INSERT's
        // attribute children inline via `graph.childrenByParent`, populated
        // solely from `.parentEntity` owners) must ALSO preserve this —
        // i.e. it survives a SECOND parse, not just the in-memory link from
        // the first parse.
        XCTAssertTrue(reparsed.store.headers.contains { $0.type == .attrib && !$0.flags.contains(.deleted) },
                      "ATTRIB following the INSERT must still round-trip as an entity")
    }

    // MARK: - Display name persistence (BlockEditor.setDisplayName's XDATA)
    //
    // Regression coverage for a real user request: "make 'display name' of
    // objects persist between saves and included in the saved dxf. i want to
    // use this attribute/value to map the location to a delivery point in
    // simulations." `InsertPayload.displayNameId` previously lived ONLY in
    // memory — `EntityRecordWriter.writeInsert` never wrote it at all, so it
    // silently reverted to the real block name on every save/reload. It now
    // round-trips as XDATA under `BlockEditor.displayNameXDataAppId`
    // ("NOVACAD_DISPLAYNAME") — group 1001 naming the app-id, followed by
    // group 1000 carrying the override string — on the INSERT entity itself.
    // THIS IS THE ATTRIBUTE EXTERNAL CONSUMERS READ to map an object's
    // display name to a simulation delivery point: scan the INSERT's XDATA
    // for a 1001 pair
    // whose string is "NOVACAD_DISPLAYNAME", then read the immediately
    // following 1000 pair as the display name string.

    func testDisplayNameSurvivesSaveAndReload() throws {
        let parsed = try parse("roundtrip_core.dxf")
        guard let insIdx = parsed.store.headers.indices.first(where: { parsed.store.headers[$0].type == .insert }) else {
            return XCTFail("fixture must have an INSERT")
        }
        let insertId = EntityID(raw: Int32(insIdx))
        parsed.document.transact("Rename") { tx in
            _ = BlockEditor.setDisplayName(insertId, to: "Station 7", in: parsed, tx: tx)
        }
        let (reparsed, _, url) = try roundTrip(parsed)
        defer { try? FileManager.default.removeItem(at: url) }

        guard let reIdx = reparsed.store.headers.indices.first(where: { reparsed.store.headers[$0].type == .insert }) else {
            return XCTFail("INSERT must survive the round trip")
        }
        let reInsertId = EntityID(raw: Int32(reIdx))
        XCTAssertEqual(BlockEditor.displayName(of: reInsertId, in: reparsed.store), "Station 7",
                      "a display name override must survive save + reload, not silently revert to the real block name")
    }

    func testDisplayNameXDataUsesTheDocumentedWireFormat() throws {
        // Locks in the EXACT wire shape external consumers read back
        // directly from the saved DXF: group 1001 = "NOVACAD_DISPLAYNAME",
        // immediately followed by group 1000 = the override string.
        let parsed = try parse("roundtrip_core.dxf")
        let insertId = EntityID(raw: Int32(try XCTUnwrap(
            parsed.store.headers.indices.first { parsed.store.headers[$0].type == .insert })))
        parsed.document.transact("Rename") { tx in
            _ = BlockEditor.setDisplayName(insertId, to: "Station 7", in: parsed, tx: tx)
        }
        let (_, _, url) = try roundTrip(parsed)
        defer { try? FileManager.default.removeItem(at: url) }
        let contents = try String(contentsOf: url, encoding: .utf8)
        let lines = contents.components(separatedBy: .newlines)
        guard let markerIdx = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "NOVACAD_DISPLAYNAME" }) else {
            return XCTFail("NOVACAD_DISPLAYNAME XDATA group must be present in the written file")
        }
        XCTAssertEqual(lines[markerIdx - 1].trimmingCharacters(in: .whitespaces), "1001",
                      "the app-id marker must be group 1001")
        XCTAssertEqual(lines[markerIdx + 1].trimmingCharacters(in: .whitespaces), "1000",
                      "the display name value must be group 1000, immediately following the app-id marker")
        XCTAssertEqual(lines[markerIdx + 2].trimmingCharacters(in: .whitespaces), "Station 7")
    }

    func testClearingDisplayNameRemovesTheXDataOnReload() throws {
        let parsed = try parse("roundtrip_core.dxf")
        let insertId = EntityID(raw: Int32(try XCTUnwrap(
            parsed.store.headers.indices.first { parsed.store.headers[$0].type == .insert })))
        parsed.document.transact("Rename") { tx in
            _ = BlockEditor.setDisplayName(insertId, to: "Station 7", in: parsed, tx: tx)
        }
        parsed.document.transact("Clear") { tx in
            _ = BlockEditor.setDisplayName(insertId, to: "", in: parsed, tx: tx)
        }
        let (reparsed, _, url) = try roundTrip(parsed)
        defer { try? FileManager.default.removeItem(at: url) }
        let reInsertId = EntityID(raw: Int32(try XCTUnwrap(
            reparsed.store.headers.indices.first { reparsed.store.headers[$0].type == .insert })))
        let realBlockName = reparsed.store.strings.string(for: reparsed.store.inserts[
            Int(reparsed.store.header(reInsertId)!.payload)].blockNameId)
        XCTAssertEqual(BlockEditor.displayName(of: reInsertId, in: reparsed.store), realBlockName,
                      "clearing the override must fall back to the real block name after reload, not leave a stale one")
    }

    func testUnrenamedInsertHasNoDisplayNameXDataAfterRoundTrip() throws {
        // The overwhelming common case (never renamed) must not grow a
        // spurious XDATA group at all.
        let parsed = try parse("roundtrip_core.dxf")
        let (reparsed, _, url) = try roundTrip(parsed)
        defer { try? FileManager.default.removeItem(at: url) }
        for i in reparsed.store.headers.indices {
            let h = reparsed.store.headers[i]
            guard h.type == .insert, !h.flags.contains(.deleted) else { continue }
            XCTAssertNotEqual(reparsed.store.xdata[Int32(i)]?.appId, BlockEditor.displayNameXDataAppId)
        }
        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(contents.contains("NOVACAD_DISPLAYNAME"))
    }

    /// `BlockEditor.mergeDisplayName` must never destroy a REAL, unrelated
    /// XDATA app-id group already on the entity (e.g. from the authoring CAD
    /// tool) when setting/clearing a display name — the merge-safety this
    /// feature's whole persistence design depends on, since `EntityStore
    /// .xdata` holds only one blob per entity.
    func testMergeDisplayNamePreservesUnrelatedXData() {
        let existing = XDataBlob(appId: "SOME_OTHER_APP", pairs: [(1000, .string("unrelated"))])
        let merged = try! XCTUnwrap(BlockEditor.mergeDisplayName("Station 7", into: existing))
        XCTAssertEqual(merged.appId, BlockEditor.displayNameXDataAppId)
        // The unrelated pair must still be present in the merged blob (see
        // `mergeDisplayName`'s own doc comment on the one-blob-per-entity
        // limitation this inherits).
        XCTAssertTrue(merged.pairs.contains { if case .string("unrelated") = $0.value { return true }; return false })
    }

    func testMergeDisplayNameClearingWithNoOtherXDataDropsTheBlobEntirely() {
        XCTAssertNil(BlockEditor.mergeDisplayName(nil, into: nil))
        let ownBlobOnly = XDataBlob(appId: BlockEditor.displayNameXDataAppId, pairs: [(1000, .string("old"))])
        XCTAssertNil(BlockEditor.mergeDisplayName(nil, into: ownBlobOnly))
    }

    func testMergeDisplayNameClearingKeepsUnrelatedXData() {
        let existing = XDataBlob(appId: "SOME_OTHER_APP", pairs: [(1000, .string("keep me"))])
        let cleared = try! XCTUnwrap(BlockEditor.mergeDisplayName(nil, into: existing))
        XCTAssertEqual(cleared.appId, "SOME_OTHER_APP")
    }

    func testSettingDisplayNameIsUndoableIncludingItsXData() throws {
        let parsed = try parse("roundtrip_core.dxf")
        let insertId = EntityID(raw: Int32(try XCTUnwrap(
            parsed.store.headers.indices.first { parsed.store.headers[$0].type == .insert })))
        let before = parsed.document.undoStack.count
        parsed.document.transact("Rename") { tx in
            _ = BlockEditor.setDisplayName(insertId, to: "Station 7", in: parsed, tx: tx)
        }
        XCTAssertEqual(parsed.document.undoStack.count, before + 1)
        XCTAssertEqual(parsed.store.xdata[insertId.raw]?.appId, BlockEditor.displayNameXDataAppId)
        parsed.document.undo()
        XCTAssertNil(parsed.store.xdata[insertId.raw],
                    "undo must restore the pre-rename XDATA state (none, for this fixture's INSERT), not just the in-memory displayNameId")
        XCTAssertNil(BlockEditor.displayName(of: insertId, in: parsed.store).flatMap { $0 == "Station 7" ? $0 : nil })
    }

    /// Exercises the writer's OTHER ATTRIB path: an entity explicitly given
    /// `OwnerRef.parentEntity(insertID)` (as a future in-app "add attribute"
    /// editing command would produce) must round-trip AS a child — inline
    /// after its parent INSERT, closed with its own SEQEND, and re-resolve
    /// via `EntityStore.children(of:)` after reparse.
    func testHandBuiltParentChildAttribRoundTripsAsChild() throws {
        let doc = EditableDocument()
        let blockName = doc.store.strings.intern("SYM1")
        var insertID: EntityID!
        doc.transact("build") { tx in
            insertID = tx.add(EntityPrototype(type: .insert, layerId: 0,
                payload: .insert(InsertPayload(blockNameId: blockName, position: Vec3(x: 1, y: 2)))))
            tx.add(EntityPrototype(type: .attrib, layerId: 0, owner: .parentEntity(insertID),
                payload: .text(TextPayload(position: Vec3(x: 1, y: 2), height: 1,
                                          stringId: doc.store.strings.intern("VAL")))))
        }
        let parsed = EditableParsedDocument()
        parsed.layers.append(DXFLayer(id: 0, name: "0"))
        parsed.layerIdByName["0"] = 0
        parsed.linetypes.append(DXFLinetype(name: "CONTINUOUS", dashes: []))
        parsed.linetypeIdByName["CONTINUOUS"] = 0
        for h in doc.store.headers { parsed.document.store.appendHeader(h) }
        parsed.document.store.inserts = doc.store.inserts
        parsed.document.store.texts = doc.store.texts
        parsed.document.store.strings.replaceContents(with: doc.store.strings.clone())

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("roundtrip-parentchild-\(UUID().uuidString).dxf")
        defer { try? FileManager.default.removeItem(at: tmp) }
        _ = try DXFStructuralWriter.write(parsed, to: tmp)
        let reparsed = try PackageLoader.loadIntoStore(url: tmp)

        // Reparsed via the REAL parser: the written file's ATTRIB appears
        // INLINE after the INSERT with its own SEQEND (verified textually
        // below) — and, since `EntityStoreParser` now wires a parsed
        // INSERT+ATTRIB run into a real `owner.parentEntityID` link (see
        // `testInsertWithAttribRoundTrips`'s own doc comment for the bug
        // this fixed), the parent/child relationship survives the full
        // write-then-reparse round trip too, not just the original in-memory
        // hand-built document.
        XCTAssertTrue(reparsed.store.headers.contains { $0.type == .insert })
        XCTAssertTrue(reparsed.store.headers.contains { $0.type == .attrib })
        if let reparsedInsertIdx = reparsed.store.headers.indices.first(where: { reparsed.store.headers[$0].type == .insert }) {
            let reparsedInsertId = EntityID(raw: Int32(reparsedInsertIdx))
            XCTAssertEqual(BlockEditor.attributes(of: reparsedInsertId, in: reparsed.store).first?.value, "VAL")
        }
        let text = try String(contentsOf: tmp, encoding: .utf8)
        guard let insertRange = text.range(of: "\nINSERT\n"), let attribRange = text.range(of: "\nATTRIB\n"),
              let seqendRange = text.range(of: "\nSEQEND\n") else {
            return XCTFail("expected INSERT, ATTRIB, and SEQEND records in the output")
        }
        XCTAssertTrue(insertRange.lowerBound < attribRange.lowerBound, "ATTRIB must follow its parent INSERT")
        XCTAssertTrue(attribRange.lowerBound < seqendRange.lowerBound, "SEQEND must follow the ATTRIB child")

        // Regression check (adversarial-review finding): an INSERT with
        // ATTRIB children must carry DXF group 66 = 1 ("attributes follow")
        // — `writeInsert` had no visibility into `graph.childrenByParent`
        // (that adjacency lives entirely in the CALLER,
        // `DXFBlocksEntitiesEmitter.writeOneEntityAndChildren`) and never
        // emitted it at all before this fix threaded `hasAttribChildren`
        // through. The INSERT record body (between its own "0/INSERT" line
        // and the next record's "0/ATTRIB" line, which we already located
        // above) is exactly `insertRange.upperBound..<attribRange.lowerBound`
        // — using `attribRange` here (rather than a generic "next 0/<TYPE>"
        // search) avoids false-matching the "8\n0\n" layer-name-"0" group
        // code pair that also appears inside this very record.
        let insertRecordBody = text[insertRange.upperBound..<attribRange.lowerBound]
        XCTAssertTrue(insertRecordBody.contains("\n66\n1\n"),
            "an INSERT with ATTRIB children must carry group 66 = 1 (\"attributes follow\"); record body was: \(insertRecordBody)")
    }

    /// Sibling check to `testHandBuiltParentChildAttribRoundTripsAsChild`:
    /// an INSERT with NO attribute children must NOT claim group 66 = 1 —
    /// confirms the fix is conditional on `hasAttribChildren`, not a blanket
    /// "always emit 66=1 for every INSERT" regression.
    func testInsertWithoutAttribChildrenOmitsGroup66() throws {
        let doc = EditableDocument()
        let blockName = doc.store.strings.intern("SYM1")
        doc.transact("build") { tx in
            tx.add(EntityPrototype(type: .insert, layerId: 0,
                payload: .insert(InsertPayload(blockNameId: blockName, position: Vec3(x: 1, y: 2)))))
        }
        let parsed = makeMinimalParsedDocument()
        transplant(doc, into: parsed)

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("roundtrip-insert-no-attrib-\(UUID().uuidString).dxf")
        defer { try? FileManager.default.removeItem(at: tmp) }
        _ = try DXFStructuralWriter.write(parsed, to: tmp)
        let text = try String(contentsOf: tmp, encoding: .utf8)

        guard let insertRange = text.range(of: "\nINSERT\n") else {
            return XCTFail("expected an INSERT record in the output")
        }
        // This INSERT is the only entity in ENTITIES (no ATTRIB children),
        // so the next record boundary is the section's own "0/ENDSEC" line
        // — using that (rather than a generic "next 0/<TYPE>" search) avoids
        // false-matching the "8\n0\n" layer-name-"0" group code pair that
        // also appears inside this very record (the pitfall the sibling
        // test above hit and fixed the same way).
        guard let endSecRange = text.range(of: "\nENDSEC\n", range: insertRange.upperBound..<text.endIndex) else {
            return XCTFail("expected an ENDSEC to close the ENTITIES section")
        }
        let insertRecordBody = text[insertRange.upperBound..<endSecRange.lowerBound]
        XCTAssertFalse(insertRecordBody.contains("\n66\n1\n"),
            "an INSERT with no ATTRIB children must not claim group 66 = 1; record body was: \(insertRecordBody)")
    }

    // MARK: - ATTRIB/ATTDEF justification (adversarial-review finding)
    //
    // `writeAttribLike` shares the exact same `TextPayload.hAlign`/`vAlign`
    // fields as `writeText`, but used to drop horizontal justification
    // (group 72) entirely and could emit a bare group 74 (vertical
    // justification) with no accompanying 11/21/31 alignment point — the
    // DXF spec requires that point whenever either justification is
    // non-default, since a reader has no defined fallback position without
    // it. `writeText` already handled both fields correctly; this is a "fix
    // applied to one entity type, not its sibling" gap.

    /// Builds an ATTRIB (or ATTDEF) with non-default horizontal AND vertical
    /// justification, writes it, and inspects the raw output text for BOTH
    /// group 72 and a complete group 74 + 11/21/31 alignment point — the
    /// same fields `writeText` would produce for the identical TextPayload
    /// values, per this function's own construction below.
    private func attribJustificationRecordBody(isAttdef: Bool) throws -> Substring {
        let doc = EditableDocument()
        let stringId = doc.store.strings.intern("VAL")
        doc.transact("build") { tx in
            tx.add(EntityPrototype(type: isAttdef ? .attdef : .attrib, layerId: 0,
                payload: .text(TextPayload(position: Vec3(x: 1, y: 2), alignPosition: Vec3(x: 3, y: 4),
                                          height: 1, stringId: stringId, hAlign: 2, vAlign: 3))))
        }
        let parsed = makeMinimalParsedDocument()
        transplant(doc, into: parsed)

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("roundtrip-attrib-align-\(UUID().uuidString).dxf")
        defer { try? FileManager.default.removeItem(at: tmp) }
        _ = try DXFStructuralWriter.write(parsed, to: tmp)
        let text = try String(contentsOf: tmp, encoding: .utf8)

        let marker = isAttdef ? "\nATTDEF\n" : "\nATTRIB\n"
        guard let recordRange = text.range(of: marker) else {
            throw XCTSkip("expected a \(marker.trimmingCharacters(in: .whitespacesAndNewlines)) record in the output")
        }
        guard let endSecRange = text.range(of: "\nENDSEC\n", range: recordRange.upperBound..<text.endIndex) else {
            throw XCTSkip("expected an ENDSEC to close the ENTITIES section")
        }
        return text[recordRange.upperBound..<endSecRange.lowerBound]
    }

    func testAttribNonDefaultJustificationSurvivesRoundTrip() throws {
        let body = try attribJustificationRecordBody(isAttdef: false)
        XCTAssertTrue(body.contains("\n72\n2\n"), "group 72 (horizontal justification) must be written; body: \(body)")
        XCTAssertTrue(body.contains("\n74\n3\n"), "group 74 (vertical justification) must be written; body: \(body)")
        // The DXF spec requires the 11/21/31 alignment point whenever either
        // justification is non-default — assert the actual coordinate
        // values (3, 4) from `alignPosition` above, not just the presence
        // of SOME 11/21/31 triple.
        XCTAssertTrue(body.contains("\n11\n3.0\n"), "group 11 (alignment point X) must be written; body: \(body)")
        XCTAssertTrue(body.contains("\n21\n4.0\n"), "group 21 (alignment point Y) must be written; body: \(body)")
    }

    func testAttdefNonDefaultJustificationSurvivesRoundTrip() throws {
        let body = try attribJustificationRecordBody(isAttdef: true)
        XCTAssertTrue(body.contains("\n72\n2\n"), "group 72 (horizontal justification) must be written; body: \(body)")
        XCTAssertTrue(body.contains("\n74\n3\n"), "group 74 (vertical justification) must be written; body: \(body)")
        XCTAssertTrue(body.contains("\n11\n3.0\n"), "group 11 (alignment point X) must be written; body: \(body)")
        XCTAssertTrue(body.contains("\n21\n4.0\n"), "group 21 (alignment point Y) must be written; body: \(body)")
    }

    /// Sanity check the other direction: DEFAULT justification (hAlign=0,
    /// vAlign=0, matching most real-world ATTRIB usage) must NOT gain a
    /// spurious 72/74/11/21/31 it didn't have before — confirms the fix is
    /// conditional, mirroring writeText's own "only when non-default" gate.
    func testAttribDefaultJustificationOmitsGroup72And74() throws {
        let doc = EditableDocument()
        let stringId = doc.store.strings.intern("VAL")
        doc.transact("build") { tx in
            tx.add(EntityPrototype(type: .attrib, layerId: 0,
                payload: .text(TextPayload(position: Vec3(x: 1, y: 2), height: 1, stringId: stringId))))
        }
        let parsed = makeMinimalParsedDocument()
        transplant(doc, into: parsed)

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("roundtrip-attrib-default-align-\(UUID().uuidString).dxf")
        defer { try? FileManager.default.removeItem(at: tmp) }
        _ = try DXFStructuralWriter.write(parsed, to: tmp)
        let text = try String(contentsOf: tmp, encoding: .utf8)

        guard let recordRange = text.range(of: "\nATTRIB\n") else {
            return XCTFail("expected an ATTRIB record in the output")
        }
        guard let endSecRange = text.range(of: "\nENDSEC\n", range: recordRange.upperBound..<text.endIndex) else {
            return XCTFail("expected an ENDSEC to close the ENTITIES section")
        }
        let body = text[recordRange.upperBound..<endSecRange.lowerBound]
        XCTAssertFalse(body.contains("\n72\n"), "default hAlign must not emit group 72; body: \(body)")
        XCTAssertFalse(body.contains("\n74\n"), "default vAlign must not emit group 74; body: \(body)")
    }

    // MARK: - Layer/linetype tables match

    func testLayerAndLinetypeTablesMatch() throws {
        let parsed = try parse("roundtrip_core.dxf")
        let (reparsed, _, url) = try roundTrip(parsed)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(Set(parsed.layers.map(\.name)), Set(reparsed.layers.map(\.name)))
        XCTAssertEqual(Set(parsed.linetypes.map(\.name)), Set(reparsed.linetypes.map(\.name)))
        XCTAssertTrue(reparsed.layers.contains { $0.name == "WALLS" })
        XCTAssertTrue(reparsed.linetypes.contains { $0.name.uppercased() == "DASHED" })
    }

    // MARK: - Layer transparency (DXF group 440) round trip
    //
    // `l.transparency` (0-100%, AutoCAD's convention) round-trips through DXF
    // group 440 on the LAYER table entry: `0x02000000 | alpha`, where alpha
    // is 0 (100% transparent) ... 255 (opaque). Only R2004+ (AC1018) actually
    // supports it — same version gate as true color (group 420), since both
    // were introduced together.

    func testLayerTransparencySurvivesRoundTripAtR2004() throws {
        let parsed = try parse("roundtrip_core.dxf")
        guard let wallsIdx = parsed.layers.firstIndex(where: { $0.name == "WALLS" }) else {
            return XCTFail("fixture must have a WALLS layer")
        }
        parsed.layers[wallsIdx].transparency = 40
        let (reparsed, _, url) = try roundTrip(parsed, version: .r2004)
        defer { try? FileManager.default.removeItem(at: url) }

        let reparsedWalls = try XCTUnwrap(reparsed.layers.first { $0.name == "WALLS" })
        XCTAssertEqual(reparsedWalls.transparency, 40, accuracy: 1,
                      "transparency must survive up to integer-percent rounding")
    }

    func testLayerTransparencyRoundTripsAcrossTheFullRange() throws {
        // Every value from 0 to 100 must decode back within 1% — the alpha
        // byte is only 8 bits, so exact fractional-percent fidelity isn't
        // possible, but no value should drift by more than one integer
        // percent of rounding error.
        let parsed = try parse("roundtrip_core.dxf")
        guard let idx = parsed.layers.firstIndex(where: { $0.name == "WALLS" }) else {
            return XCTFail("fixture must have a WALLS layer")
        }
        for pct in stride(from: 0.0, through: 100.0, by: 7.0) {
            parsed.layers[idx].transparency = pct
            let (reparsed, _, url) = try roundTrip(parsed, version: .r2004)
            defer { try? FileManager.default.removeItem(at: url) }
            let walls = try XCTUnwrap(reparsed.layers.first { $0.name == "WALLS" })
            XCTAssertEqual(walls.transparency, pct, accuracy: 1, "drifted at \(pct)%")
        }
    }

    func testOpaqueLayerOmitsGroup440Entirely() throws {
        // The overwhelming common case (no transparency ever set) must not
        // grow every LAYER record with a redundant "opaque" group — matches
        // this file's approach for optional fields elsewhere (e.g. group 420
        // omitted for a plain ACI color).
        let parsed = try parse("roundtrip_core.dxf")
        let (reparsed, _, url) = try roundTrip(parsed, version: .r2004)
        defer { try? FileManager.default.removeItem(at: url) }
        for layer in reparsed.layers {
            XCTAssertEqual(layer.transparency, 0, "layer '\(layer.name)' must default to opaque, no group 440 present")
        }
        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(contents.contains("\n440\n"), "no group-440 pair should be written when every layer is opaque")
    }

    // MARK: - HATCH's OWN transparency (entity group 440, distinct from the
    // layer's group 440) round trip

    func testHatchOwnTransparencySurvivesRoundTrip() throws {
        let parsed = try parse("roundtrip_core.dxf")
        guard let hIdx = parsed.store.headers.indices.first(where: { parsed.store.headers[$0].type == .hatch }) else {
            return XCTFail("fixture must have a HATCH")
        }
        let hatchId = EntityID(raw: Int32(hIdx))
        parsed.document.transact("Set hatch transparency") { tx in
            tx.modifyPayload(hatchId) { copy in
                guard case .hatch(var p, let loops) = copy else { return }
                p.transparency = 65
                copy = .hatch(p, loops: loops)
            }
        }
        let (reparsed, _, url) = try roundTrip(parsed, version: .r2004)
        defer { try? FileManager.default.removeItem(at: url) }

        guard let reIdx = reparsed.store.headers.indices.first(where: { reparsed.store.headers[$0].type == .hatch }) else {
            return XCTFail("HATCH must survive the round trip")
        }
        let reHatch = reparsed.store.hatches[Int(reparsed.store.headers[reIdx].payload)]
        XCTAssertEqual(reHatch.transparency, 65, accuracy: 1)
    }

    func testHatchOwnTransparencyIsIndependentOfLayerTransparencyOnDisk() throws {
        // The hatch's own value and its LAYER's value are two SEPARATE group
        // 440s in two different places in the file (entity vs. LAYER table) —
        // setting one must not disturb the other on either write or reparse.
        let parsed = try parse("roundtrip_core.dxf")
        guard let hIdx = parsed.store.headers.indices.first(where: { parsed.store.headers[$0].type == .hatch }) else {
            return XCTFail("fixture must have a HATCH")
        }
        let hatchId = EntityID(raw: Int32(hIdx))
        let hatchLayerId = Int(parsed.store.header(hatchId)!.layerId)
        parsed.layers[hatchLayerId].transparency = 30
        parsed.document.transact("Set hatch transparency") { tx in
            tx.modifyPayload(hatchId) { copy in
                guard case .hatch(var p, let loops) = copy else { return }
                p.transparency = 70
                copy = .hatch(p, loops: loops)
            }
        }
        let (reparsed, _, url) = try roundTrip(parsed, version: .r2004)
        defer { try? FileManager.default.removeItem(at: url) }

        let reIdx = try XCTUnwrap(reparsed.store.headers.indices.first { reparsed.store.headers[$0].type == .hatch })
        let reHatch = reparsed.store.hatches[Int(reparsed.store.headers[reIdx].payload)]
        XCTAssertEqual(reHatch.transparency, 70, accuracy: 1, "the hatch's OWN transparency")
        XCTAssertEqual(reparsed.layers[hatchLayerId].transparency, 30, accuracy: 1, "its LAYER's transparency, unaffected")
    }

    func testOpaqueHatchOmitsEntityGroup440() throws {
        let parsed = try parse("roundtrip_core.dxf")
        let (reparsed, _, url) = try roundTrip(parsed, version: .r2004)
        defer { try? FileManager.default.removeItem(at: url) }
        for h in reparsed.store.headers where h.type == .hatch && !h.flags.contains(.deleted) {
            XCTAssertEqual(reparsed.store.hatches[Int(h.payload)].transparency, 0)
        }
    }

    func testLayerTransparencyIsOmittedBelowR2004() throws {
        // R2004 is when true color/transparency were introduced; an older
        // target version must not emit group 440 at all (matches the
        // existing `supportsTrueColor` gate group 420 already uses).
        let parsed = try parse("roundtrip_core.dxf")
        guard let idx = parsed.layers.firstIndex(where: { $0.name == "WALLS" }) else {
            return XCTFail("fixture must have a WALLS layer")
        }
        parsed.layers[idx].transparency = 50
        let (reparsed, _, url) = try roundTrip(parsed, version: .r2000)
        defer { try? FileManager.default.removeItem(at: url) }
        let walls = try XCTUnwrap(reparsed.layers.first { $0.name == "WALLS" })
        XCTAssertEqual(walls.transparency, 0, "an R2000 target must not carry transparency at all")
    }

    // MARK: - Handle uniqueness + pointer resolution

    func testAllHandlesAreUniqueAfterRoundTrip() throws {
        let parsed = try parse("roundtrip_core.dxf")
        let (_, _, url) = try roundTrip(parsed)
        defer { try? FileManager.default.removeItem(at: url) }

        let handles = try collectAllHandles(url: url)
        XCTAssertEqual(handles.count, Set(handles).count, "every handle in the written file must be unique")
        XCTAssertFalse(handles.contains(0), "no emitted record should carry handle 0")
    }

    /// Regression test for a gap found by adversarial review of Phase 3.1:
    /// the handle-uniqueness dedup (`claimedHandles`, added to fix a
    /// documented 3DFACE-fragment collision — see
    /// `testFace3DEdgeFragmentsRoundTripAsLines`) was originally scoped ONLY
    /// to the entity loop in `DXFHandleGraphBuilder.buildHandleGraph`. Every
    /// OTHER `reuseOrAllocate` call site — layers, linetypes, the generic
    /// symbol tables, VPORT, and every block's handles — called
    /// `reuseOrAllocate(existing)` independently with no cross-check against
    /// entity handles or each other. `handle_collision_layer_entity.dxf`
    /// hand-authors exactly this: a LAYER (`0`, handle 5=20) and a LINE
    /// (handle 5=20) that intentionally share one source handle — illegal
    /// in a well-formed AutoCAD file, but not defended against by this
    /// codebase's parser. Before the fix, pass 1's layer loop and entity
    /// loop each independently called `reuseOrAllocate(0x20)`, both got
    /// `0x20` back unchanged, and the written file ended up with the LAYER
    /// table entry and the LINE entity sharing one `5`/handle — exactly the
    /// invariant AutoCAD polices strictly. The fix centralizes claim
    /// tracking inside `HandleGraph.reuseOrAllocate` itself so it applies
    /// uniformly across every call site.
    func testLayerEntityHandleCollisionIsResolvedNotPropagated() throws {
        let parsed = try parse("handle_collision_layer_entity.dxf")
        // Sanity-check the fixture actually encodes the intended collision
        // before asserting anything about the writer's behavior.
        let collidingLayer = parsed.layers.first { $0.name == "0" }
        XCTAssertEqual(collidingLayer?.handle, 0x20, "fixture must have LAYER \"0\" at handle 0x20")
        let collidingLine = parsed.store.headers.first { $0.type == .line }
        XCTAssertEqual(collidingLine?.handle, 0x20, "fixture must have the LINE entity at handle 0x20 too")

        let (reparsed, _, url) = try roundTrip(parsed)
        defer { try? FileManager.default.removeItem(at: url) }

        let handles = try collectAllHandles(url: url)
        XCTAssertEqual(handles.count, Set(handles).count,
            "the written file must give the colliding LAYER and LINE distinct handles, not propagate the collision")

        // Both records must still be present after re-parsing — the
        // resolution should just change the DUPLICATE's on-disk handle
        // value, not drop either record.
        XCTAssertEqual(reparsed.layers.count, parsed.layers.count, "the LAYER must still round-trip")
        XCTAssertEqual(countsByType(reparsed.store)[.line], 1, "the LINE entity must still round-trip")
        XCTAssertEqual(countsByType(reparsed.store)[.circle], 1, "the CIRCLE entity must still round-trip")
    }

    func testEvery330PointerResolvesToAnExistingHandle() throws {
        let parsed = try parse("roundtrip_core.dxf")
        let (_, _, url) = try roundTrip(parsed)
        defer { try? FileManager.default.removeItem(at: url) }

        let (handles, owners) = try collectHandlesAndOwnerPointers(url: url)
        for owner in owners where owner != 0 {
            XCTAssertTrue(handles.contains(owner), "330 pointer \(String(owner, radix: 16)) must resolve to a handle that exists in the written file")
        }
    }

    // MARK: - R12 degrade path

    func testR12DegradeProducesExpectedWarningsAndParses() throws {
        let parsed = try parse("roundtrip_core.dxf")
        let (reparsed, warnings, url) = try roundTrip(parsed, version: .r12)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertTrue(warnings.contains { $0.message.contains("LWPOLYLINE degraded to POLYLINE") })
        XCTAssertTrue(warnings.contains { $0.message.contains("MTEXT degraded") })
        XCTAssertTrue(warnings.contains { $0.message.contains("SPLINE tessellated") })
        XCTAssertTrue(warnings.contains { $0.message.contains("HATCH degraded") })

        // The degraded file must still be well-formed enough to re-parse.
        let counts = countsByType(reparsed.store)
        // LWPOLYLINE degrades into legacy `.lwpolyline`-shaped storage too
        // (EntityStoreParser always builds POLYLINE/VERTEX chains back into
        // `.lwpolyline` payload shape — see its POLYLINE/SEQEND handling) —
        // so the degrade is round-trip-stable at the PARSE level even though
        // the on-disk record type changed from LWPOLYLINE to POLYLINE/VERTEX.
        XCTAssertGreaterThan(counts[.lwpolyline] ?? 0, 0, "degraded POLYLINE must still parse back as a polyline shape")
        XCTAssertGreaterThan(counts[.text] ?? 0, 0, "degraded MTEXT must parse back as TEXT entities")
        XCTAssertNil(reparsed.store.headers.first { $0.type == .mtext }, "no MTEXT should remain in an R12 write")
        XCTAssertNil(reparsed.store.headers.first { $0.type == .hatch }, "no HATCH should remain in an R12 write")
    }

    func testR12FileHasNoHandles() throws {
        let parsed = try parse("roundtrip_core.dxf")
        let (_, _, url) = try roundTrip(parsed, version: .r12)
        defer { try? FileManager.default.removeItem(at: url) }
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("$HANDSEED"), "R12 output must not carry $HANDSEED")
    }

    // MARK: - $MEASUREMENT derived from $INSUNITS (SHOULD-FIX item 8)
    //
    // `$MEASUREMENT` used to be hardcoded to 0 (imperial) in
    // DXFHeaderTemplate's default template, independent of the computed
    // `$INSUNITS` — a metric drawing built from a minimal/synthetic source
    // (one with $INSUNITS but no $MEASUREMENT of its own) would get the
    // wrong default. Fixed by deriving $MEASUREMENT from $INSUNITS via
    // `DXFHeaderTemplate.measurementValue(forInsUnits:)`, used only when the
    // source doesn't already specify $MEASUREMENT itself.

    func testMeasurementDefaultsToMetricForMillimeterInsUnits() throws {
        let parsed = makeMinimalParsedDocument()
        parsed.insUnits = 4   // millimeters
        XCTAssertNil(parsed.headerVars.intValue("$MEASUREMENT"), "test setup: source must not already specify $MEASUREMENT")

        let reparsed = try writeAndReparse(parsed)
        XCTAssertEqual(reparsed.headerVars.intValue("$MEASUREMENT"), 1,
            "a millimeter ($INSUNITS=4) drawing with no source $MEASUREMENT must default to metric (1), not the old hardcoded imperial (0)")
    }

    func testMeasurementDefaultsToImperialForInchInsUnits() throws {
        let parsed = makeMinimalParsedDocument()
        parsed.insUnits = 1   // inches
        XCTAssertNil(parsed.headerVars.intValue("$MEASUREMENT"))

        let reparsed = try writeAndReparse(parsed)
        XCTAssertEqual(reparsed.headerVars.intValue("$MEASUREMENT"), 0,
            "an inch ($INSUNITS=1) drawing with no source $MEASUREMENT must default to imperial (0)")
    }

    func testMeasurementDefaultsToImperialForUnitlessInsUnits() throws {
        let parsed = makeMinimalParsedDocument()
        parsed.insUnits = 0   // unitless/unknown
        XCTAssertNil(parsed.headerVars.intValue("$MEASUREMENT"))

        let reparsed = try writeAndReparse(parsed)
        XCTAssertEqual(reparsed.headerVars.intValue("$MEASUREMENT"), 0,
            "unitless ($INSUNITS=0) must keep the historical imperial-default fallback (0)")
    }

    /// Confirms the "source vars always win" rule still holds: an explicit
    /// source $MEASUREMENT must survive unchanged even if it looks
    /// "wrong" relative to $INSUNITS (e.g. a metric-unit drawing that
    /// explicitly opts into imperial hatch/linetype defaults) — this fix
    /// must only supply a MISSING $MEASUREMENT, never override an existing one.
    func testExplicitSourceMeasurementIsNotOverriddenByInsUnitsDerivation() throws {
        let parsed = try parse("roundtrip_core.dxf")   // $INSUNITS=4 (mm) in this fixture
        // Explicitly imperial (0), "wrong" relative to mm units — the point
        // of this test is that the writer must NOT second-guess an explicit
        // source value.
        parsed.headerVars.append(HeaderVar(name: "$MEASUREMENT", pairs: [RawGroupPair(code: 70, value: .int(0))]))
        let (reparsed, _, url) = try roundTrip(parsed)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(reparsed.headerVars.intValue("$MEASUREMENT"), 0,
            "an explicit source $MEASUREMENT must be echoed verbatim, not overridden by the $INSUNITS-derived default")
    }

    // MARK: - Large-ish stress: many entities, verify write completes and counts hold

    func testManyEntitiesRoundTripCountsMatch() throws {
        let doc = EditableDocument()
        let store = doc.store
        var expectedLines = 0
        doc.transact("bulk") { tx in
            for i in 0..<500 {
                tx.add(EntityPrototype(type: .line, layerId: 0,
                    payload: .line(LinePayload(a: Vec3(x: Double(i), y: 0), b: Vec3(x: Double(i), y: 10)))))
                expectedLines += 1
            }
        }
        _ = store
        let parsed = EditableParsedDocument()
        // Swap in our manually-built document (EditableParsedDocument's
        // `document` is a `let`, so build the layers/linetypes bookkeeping
        // by hand instead — this is a from-scratch in-memory document, not
        // a parsed file, exercising the writer's "brand-new document" path.)
        parsed.layers.append(DXFLayer(id: 0, name: "0"))
        parsed.layerIdByName["0"] = 0
        parsed.linetypes.append(DXFLinetype(name: "CONTINUOUS", dashes: []))
        parsed.linetypeIdByName["CONTINUOUS"] = 0
        for h in doc.store.headers { parsed.document.store.appendHeader(h) }
        parsed.document.store.lines = doc.store.lines

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("roundtrip-bulk-\(UUID().uuidString).dxf")
        defer { try? FileManager.default.removeItem(at: tmp) }
        _ = try DXFStructuralWriter.write(parsed, to: tmp)
        let reparsed = try PackageLoader.loadIntoStore(url: tmp)
        let lineCount = reparsed.store.headers.filter { $0.type == .line && !$0.flags.contains(.deleted) }.count
        XCTAssertEqual(lineCount, expectedLines)
    }

    // MARK: - Orphaned-block entities get a warning, not silence (SHOULD-FIX item 9)
    //
    // A malformed source BLOCK record with an empty/missing name (group 2
    // AND group 3 both blank) is never registered into `parsed.blocks` by
    // EntityStoreParser's ENDBLK handler (`if let b = inBlockDef,
    // !b.name.isEmpty` — see that file, out of scope to touch this
    // session), but entities parsed inside it still get a valid
    // `owner: .block(blockIndex)`. `writeBlocksSection` only iterates
    // `parsed.blocks`, so those entities are silently never emitted. This
    // test constructs that scenario directly (bypassing the parser, since
    // there's no way to trigger it through a normal fixture without
    // touching the out-of-scope parser file) and asserts the writer at
    // least surfaces a WriteWarning instead of staying silent.

    func testOrphanedBlockEntitiesProduceWarningNotSilentLoss() throws {
        let parsed = makeMinimalParsedDocument()
        // Simulate EntityStoreParser's exact failure mode: an entity owned
        // by block index 99, but index 99 was NEVER registered into
        // `parsed.blocks` (as would happen for a source BLOCK with no name).
        let orphanBlockIndex: Int32 = 99
        let header = EntityHeader(handle: 0, type: .line, layerId: 0, owner: .block(orphanBlockIndex), payload: 0)
        parsed.document.store.lines.append(LinePayload(a: Vec3(x: 0, y: 0, z: 0), b: Vec3(x: 1, y: 1, z: 0)))
        _ = parsed.document.store.appendHeader(header)
        // Confirm the test setup actually matches the real bug: this block
        // index must NOT appear in `parsed.blocks` (mirroring the parser
        // never registering an empty-named block).
        XCTAssertFalse(parsed.blocks.values.contains { $0.blockIndex == orphanBlockIndex },
            "test setup: block index \(orphanBlockIndex) must be unregistered, matching the real parser bug")

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("roundtrip-orphan-block-\(UUID().uuidString).dxf")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let warnings = try DXFStructuralWriter.write(parsed, to: tmp)

        XCTAssertTrue(warnings.contains { $0.kind == .dropped && $0.message.contains("unnamed/malformed block") },
            "expected a .dropped warning naming the orphaned/unnamed block; got: \(warnings)")

        // Document the current (accepted, per the task brief) limitation:
        // the orphaned entity's content is NOT recovered — only surfaced via
        // the warning above. This assertion exists so a future fix that DOES
        // recover the content changes this test deliberately, rather than
        // the recovery silently regressing unnoticed.
        let text = try String(contentsOf: tmp, encoding: .utf8)
        XCTAssertFalse(text.contains("\nLINE\n"), "the orphaned LINE is still not written today — only warned about")
    }

    /// Sanity check the other direction: a NORMAL, well-named block must NOT
    /// trigger this warning — confirms the detection is specific to the
    /// orphaned case, not a false positive on every block.
    func testNormalBlockEntitiesProduceNoOrphanWarning() throws {
        let parsed = try parse("roundtrip_core.dxf")
        let (_, warnings, url) = try roundTrip(parsed)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertFalse(warnings.contains { $0.message.contains("unnamed/malformed block") },
            "a well-formed fixture with no orphaned blocks must not trigger this warning; got: \(warnings)")
    }

    // MARK: - Hand-built document helper (from-scratch, not parsed-from-file)

    /// Minimal `EditableParsedDocument` with layer "0" + linetype CONTINUOUS
    /// registered — the bare bookkeeping every write needs — ready for a
    /// caller to append entities directly into `.document.store`. Used by
    /// tests exercising entity types with no real-world hand-authored
    /// fixture (DIMENSION/VIEWPORT/IMAGE are stub/best-effort per this
    /// session's scope — see the final report — so a synthetic round trip
    /// is the only practical coverage available).
    private func makeMinimalParsedDocument() -> EditableParsedDocument {
        let parsed = EditableParsedDocument()
        parsed.layers.append(DXFLayer(id: 0, name: "0"))
        parsed.layerIdByName["0"] = 0
        parsed.linetypes.append(DXFLinetype(name: "CONTINUOUS", dashes: []))
        parsed.linetypeIdByName["CONTINUOUS"] = 0
        return parsed
    }

    /// Copies every header + the SPECIFIC payload arrays referenced by
    /// `types` from `doc.store` into `parsed.document.store` — bulk swap-in
    /// for a hand-built `EditableDocument`'s content, mirroring the pattern
    /// `testManyEntitiesRoundTripCountsMatch`/`testHandBuiltParentChildAttribRoundTripsAsChild`
    /// established inline before this helper existed.
    private func transplant(_ doc: EditableDocument, into parsed: EditableParsedDocument) {
        for h in doc.store.headers { parsed.document.store.appendHeader(h) }
        parsed.document.store.lines = doc.store.lines
        parsed.document.store.points = doc.store.points
        parsed.document.store.circles = doc.store.circles
        parsed.document.store.arcs = doc.store.arcs
        parsed.document.store.dimensions = doc.store.dimensions
        parsed.document.store.viewports = doc.store.viewports
        parsed.document.store.images = doc.store.images
        parsed.document.store.inserts = doc.store.inserts
        parsed.document.store.texts = doc.store.texts
        parsed.document.store.strings.replaceContents(with: doc.store.strings.clone())
    }

    private func writeAndReparse(_ parsed: EditableParsedDocument, version: DXFVersion = .r2000) throws -> EditableParsedDocument {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("roundtrip-handbuilt-\(UUID().uuidString).dxf")
        defer { try? FileManager.default.removeItem(at: tmp) }
        _ = try DXFStructuralWriter.write(parsed, to: tmp, options: DXFWriteOptions(version: version))
        return try PackageLoader.loadIntoStore(url: tmp)
    }

    // MARK: - Best-effort entity types: DIMENSION / VIEWPORT / IMAGE
    //
    // These three are explicitly documented as stub/best-effort in this
    // session's final report (DIMENSION retains only a minimal INSERT-like
    // reference per EntityStore's own DimensionPayload doc comment; VIEWPORT
    // and IMAGE have no real-world fixture available since nothing in this
    // codebase's own test corpus authors them). Coverage here is a basic
    // "does it at least survive a round trip without crashing or vanishing"
    // smoke test, not a claim of full-fidelity round-tripping.

    func testDimensionRoundTripsAsMinimalReference() throws {
        let doc = EditableDocument()
        let blockName = doc.store.strings.intern("*D1")
        doc.transact("build") { tx in
            tx.add(EntityPrototype(type: .dimension, layerId: 0,
                payload: .dimension(DimensionPayload(blockNameId: blockName, defPoint: Vec3(x: 3, y: 4, z: 0)))))
        }
        let parsed = makeMinimalParsedDocument()
        transplant(doc, into: parsed)

        let reparsed = try writeAndReparse(parsed)
        let dims = reparsed.store.headers.filter { $0.type == .dimension && !$0.flags.contains(.deleted) }
        XCTAssertEqual(dims.count, 1)
        let dp = reparsed.store.dimensions[Int(dims[0].payload)]
        XCTAssertEqual(reparsed.store.strings.string(for: dp.blockNameId), "*D1")
        XCTAssertEqual(dp.defPoint.x, 3, accuracy: 1e-9)
        XCTAssertEqual(dp.defPoint.y, 4, accuracy: 1e-9)
    }

    func testViewportRoundTripsWithoutCrashing() throws {
        let doc = EditableDocument()
        doc.transact("build") { tx in
            tx.add(EntityPrototype(type: .viewport, layerId: 0, owner: .paper,
                payload: .viewport(ViewportPayload(centerPaper: Vec3(x: 100, y: 50), widthPaper: 200, heightPaper: 100,
                                                   viewCenter: Vec3(x: 10, y: 10), viewHeight: 500))))
        }
        let parsed = makeMinimalParsedDocument()
        transplant(doc, into: parsed)

        let reparsed = try writeAndReparse(parsed)
        // VIEWPORT is in EntityStoreParser's discard list (see that file's
        // ATTDEF/VIEWPORT/... "nothing useful to draw" comment) — it is
        // NEVER retained on re-parse. This is a PRE-EXISTING, out-of-scope
        // parser limitation, not a writer bug: the assertion here is
        // deliberately just "the write completes and the rest of the file
        // still parses cleanly", not "the VIEWPORT itself survives".
        XCTAssertEqual(reparsed.store.headers.filter { !$0.flags.contains(.deleted) }.count, 0)
    }

    /// Regression test (SHOULD-FIX item 7): `writeViewport` used to hardcode
    /// DXF group 69 ("viewport ID") to a bare `1` for EVERY viewport it
    /// wrote, so a layout with more than one floating viewport got
    /// duplicate, spec-violating IDs. Fixed by threading a per-space
    /// sequential counter through from `DXFBlocksEntitiesEmitter`. Since
    /// VIEWPORT isn't retained by `EntityStoreParser` on reparse (same
    /// pre-existing limitation `testViewportRoundTripsWithoutCrashing`
    /// documents above), this inspects the raw written text directly.
    func testMultipleViewportsInSameLayoutGetDistinctGroup69() throws {
        let doc = EditableDocument()
        doc.transact("build") { tx in
            tx.add(EntityPrototype(type: .viewport, layerId: 0, owner: .paper,
                payload: .viewport(ViewportPayload(centerPaper: Vec3(x: 100, y: 50), widthPaper: 200, heightPaper: 100,
                                                   viewCenter: Vec3(x: 10, y: 10), viewHeight: 500))))
            tx.add(EntityPrototype(type: .viewport, layerId: 0, owner: .paper,
                payload: .viewport(ViewportPayload(centerPaper: Vec3(x: 300, y: 50), widthPaper: 200, heightPaper: 100,
                                                   viewCenter: Vec3(x: 20, y: 20), viewHeight: 500))))
            tx.add(EntityPrototype(type: .viewport, layerId: 0, owner: .paper,
                payload: .viewport(ViewportPayload(centerPaper: Vec3(x: 500, y: 50), widthPaper: 200, heightPaper: 100,
                                                   viewCenter: Vec3(x: 30, y: 30), viewHeight: 500))))
        }
        let parsed = makeMinimalParsedDocument()
        transplant(doc, into: parsed)

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("roundtrip-multi-viewport-\(UUID().uuidString).dxf")
        defer { try? FileManager.default.removeItem(at: tmp) }
        _ = try DXFStructuralWriter.write(parsed, to: tmp)
        let text = try String(contentsOf: tmp, encoding: .utf8)

        // Collect every group-69 value in the file (VIEWPORT is the only
        // entity type this writer ever emits group 69 for).
        var group69Values: [Int] = []
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var i = 0
        while i + 1 < lines.count {
            if lines[i].trimmingCharacters(in: .whitespaces) == "69", let v = Int(lines[i + 1].trimmingCharacters(in: .whitespaces)) {
                group69Values.append(v)
            }
            i += 1
        }
        XCTAssertEqual(group69Values.count, 3, "expected one group-69 value per VIEWPORT; found \(group69Values)")
        XCTAssertEqual(group69Values.count, Set(group69Values).count,
            "all three VIEWPORTs in the same paper-space layout must get DISTINCT group-69 IDs, not duplicates; got \(group69Values)")
        XCTAssertEqual(Set(group69Values), Set([1, 2, 3]), "expected sequential IDs 1, 2, 3; got \(group69Values)")
    }

    func testImageRoundTripsAtR14PlusOrDropsWithWarningAtR12() throws {
        let doc = EditableDocument()
        doc.transact("build") { tx in
            tx.add(EntityPrototype(type: .image, layerId: 0,
                payload: .image(ImagePayload(origin: Vec3(x: 0, y: 0), uVector: Vec3(x: 1, y: 0), vVector: Vec3(x: 0, y: 1),
                                             sizePxWidth: 640, sizePxHeight: 480))))
        }
        let parsed = makeMinimalParsedDocument()
        transplant(doc, into: parsed)

        let reparsedR2000 = try writeAndReparse(parsed, version: .r2000)
        // IMAGE isn't in EntityStoreParser's typed-entity switch at all
        // (also in its discard list) — same pre-existing parser limitation
        // as VIEWPORT above: the WRITE succeeds (verified by inspecting the
        // raw text below), but re-parsing this codebase's own output can't
        // observe the IMAGE entity coming back, only that nothing else broke.
        XCTAssertEqual(reparsedR2000.store.headers.filter { !$0.flags.contains(.deleted) }.count, 0)

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("roundtrip-image-\(UUID().uuidString).dxf")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let warningsR2000 = try DXFStructuralWriter.write(parsed, to: tmp, options: DXFWriteOptions(version: .r2000))
        XCTAssertTrue(warningsR2000.isEmpty)
        let text = try String(contentsOf: tmp, encoding: .utf8)
        XCTAssertTrue(text.contains("IMAGE"), "AC1015 output must contain a written IMAGE record")

        let tmpR12 = FileManager.default.temporaryDirectory.appendingPathComponent("roundtrip-image-r12-\(UUID().uuidString).dxf")
        defer { try? FileManager.default.removeItem(at: tmpR12) }
        let warningsR12 = try DXFStructuralWriter.write(parsed, to: tmpR12, options: DXFWriteOptions(version: .r12))
        XCTAssertTrue(warningsR12.contains { $0.message.contains("IMAGE entity dropped") })
    }

    // MARK: - XDATA-without-residual / discarded-type XDATA (adversarial-review findings)
    //
    // `.unknown` and the `.xline`/`.ray`/`.wipeout`/`.mleader`/`.acadTable`
    // group are never actually produced by `EntityStoreParser` today (see
    // that file's "ATTDEF, VIEWPORT, MLEADER... case ... return" discard
    // list and its `default: out.skippedTypes[...] += 1; return` fallback —
    // both silently drop the entity before it ever reaches `EntityStore`).
    // That means these `EntityRecordWriter` branches are unreachable via the
    // live parse path TODAY, but the writer must still behave correctly if
    // an entity of one of these types ever reaches it by another route
    // (`EditScriptRunner`'s `unknown` type alias already treats it as a
    // legitimate type name; a future parser change could plausibly retain
    // these types instead of discarding them). These tests construct such
    // entities directly via `EntityStore.appendHeader` + `store.xdata`,
    // bypassing the parser entirely, which is the only way to exercise
    // these branches at all right now.

    /// Regression test: an `.unknown` entity with XDATA but NO residual
    /// pairs used to write NOTHING for its owning record (`writeResidualOnly`
    /// early-returned on `guard let residual = ... else { return }`) while
    /// its caller unconditionally called `writeXData` right after — orphaning
    /// group 1001+ codes with no preceding "0/<TYPE>" record header, which
    /// desyncs the file for any reparse. Fixed by making `writeResidualOnly`
    /// always write the header (empty residual loop is fine), so XDATA can
    /// safely follow it.
    func testUnknownEntityWithXDataButNoResidualPairsWritesWellFormedRecord() throws {
        let parsed = makeMinimalParsedDocument()
        let header = EntityHeader(handle: 0x999, type: .unknown, layerId: 0, owner: .model, payload: -1)
        let id = parsed.document.store.appendHeader(header)
        parsed.document.store.xdata[id.raw] = XDataBlob(appId: "MY_APP", pairs: [(1000, .string("hello"))])
        // Deliberately do NOT populate residualPairs for this entity.
        XCTAssertNil(parsed.document.store.residualPairs[id.raw], "test setup: this entity must have no residual pairs")

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("roundtrip-unknown-xdata-\(UUID().uuidString).dxf")
        defer { try? FileManager.default.removeItem(at: tmp) }
        _ = try DXFStructuralWriter.write(parsed, to: tmp, options: DXFWriteOptions(version: .r2000))
        let text = try String(contentsOf: tmp, encoding: .utf8)

        // The XDATA app-id string must appear...
        XCTAssertTrue(text.contains("MY_APP"), "XDATA app-id must be written")
        XCTAssertTrue(text.contains("hello"), "XDATA payload must be written")
        // ...and it must be preceded by a well-formed "0/<TYPE>" record
        // header carrying this entity's own handle (999 hex), not floating
        // with no owning record ahead of it.
        guard let recordStart = text.range(of: "0\nACAD_PROXY_ENTITY\n") else {
            return XCTFail("expected a synthesized owning record (\"0/ACAD_PROXY_ENTITY\") ahead of the orphaned XDATA")
        }
        guard let xdataStart = text.range(of: "1001\nMY_APP\n") else {
            return XCTFail("expected XDATA group 1001/MY_APP in the output")
        }
        XCTAssertTrue(recordStart.lowerBound < xdataStart.lowerBound,
            "the owning record header must be written BEFORE the XDATA that belongs to it")
        // The handle group (5/999) must appear between the record start and
        // the XDATA, confirming this is genuinely ONE well-formed record
        // rather than two unrelated fragments that happen to be in order.
        let recordToXData = text[recordStart.upperBound..<xdataStart.lowerBound]
        XCTAssertTrue(recordToXData.contains("999"), "the synthesized record must carry this entity's own handle (0x999)")
    }

    /// Regression test: the `.xline`/`.ray`/`.wipeout`/`.mleader`/`.acadTable`
    /// branch set `needsGenericExtras = false` and, unlike the adjacent
    /// `.unknown` case, never called `writeXData` at all — any entity typed
    /// this way with XDATA silently lost it entirely. Fixed by writing the
    /// owning record + XDATA whenever either residual pairs or XDATA exist,
    /// mirroring `.unknown`'s handling.
    func testDiscardedTypeWithXDataSurvivesRoundTrip() throws {
        let parsed = makeMinimalParsedDocument()
        let header = EntityHeader(handle: 0xABC, type: .xline, layerId: 0, owner: .model, payload: -1)
        let id = parsed.document.store.appendHeader(header)
        parsed.document.store.xdata[id.raw] = XDataBlob(appId: "XLINE_APP", pairs: [(1000, .string("xline-xdata"))])
        XCTAssertNil(parsed.document.store.residualPairs[id.raw], "test setup: this entity must have no residual pairs")

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("roundtrip-xline-xdata-\(UUID().uuidString).dxf")
        defer { try? FileManager.default.removeItem(at: tmp) }
        _ = try DXFStructuralWriter.write(parsed, to: tmp, options: DXFWriteOptions(version: .r2000))
        let text = try String(contentsOf: tmp, encoding: .utf8)

        XCTAssertTrue(text.contains("XLINE_APP"), "XDATA app-id for a discarded-type (.xline) entity must be written, not dropped")
        XCTAssertTrue(text.contains("xline-xdata"), "XDATA payload must be written")
        guard let recordStart = text.range(of: "0\nXLINE\n") else {
            return XCTFail("expected an owning \"0/XLINE\" record ahead of the XDATA")
        }
        guard let xdataStart = text.range(of: "1001\nXLINE_APP\n") else {
            return XCTFail("expected XDATA group 1001/XLINE_APP in the output")
        }
        XCTAssertTrue(recordStart.lowerBound < xdataStart.lowerBound,
            "the owning XLINE record must be written before its XDATA")
    }

    // MARK: - Raw-line handle scanning helpers

    private func collectAllHandles(url: URL) throws -> [UInt64] {
        let text = try String(contentsOf: url, encoding: .utf8)
        var handles: [UInt64] = []
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var i = 0
        while i + 1 < lines.count {
            let code = lines[i].trimmingCharacters(in: .whitespaces)
            if code == "5" || code == "105" {
                let value = lines[i + 1].trimmingCharacters(in: .whitespaces)
                if let h = UInt64(value, radix: 16) { handles.append(h) }
            }
            i += 2
        }
        return handles
    }

    private func collectHandlesAndOwnerPointers(url: URL) throws -> (handles: Set<UInt64>, owners: [UInt64]) {
        let text = try String(contentsOf: url, encoding: .utf8)
        var handles: Set<UInt64> = []
        var owners: [UInt64] = []
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var i = 0
        while i + 1 < lines.count {
            let code = lines[i].trimmingCharacters(in: .whitespaces)
            let value = lines[i + 1].trimmingCharacters(in: .whitespaces)
            if code == "5" || code == "105", let h = UInt64(value, radix: 16) { handles.insert(h) }
            if code == "330", let h = UInt64(value, radix: 16) { owners.append(h) }
            i += 2
        }
        return (handles, owners)
    }
}
