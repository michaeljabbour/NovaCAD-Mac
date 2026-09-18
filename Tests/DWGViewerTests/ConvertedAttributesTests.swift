import XCTest
@testable import DWGViewer
import CADCore

/// Regression tests for a real bug on DWG→DXF-converted 2D factory layouts:
/// "some data attributes are missing … specifically on layer MATERIAL-CARRIER".
///
/// Root causes (all fixed in `EntityStoreParser`'s TEXT/ATTRIB case):
///  1. **Invisible ATTRIBs were dropped entirely** (group-70 bit 1). Factory
///     material/carrier/BOM attributes are routinely stored invisible but still
///     data-bearing — they must be RETAINED (marked invisible so the renderer
///     skips them) so Data Extraction / `BlockEditor.attributes(of:)` can
///     read them.
///  2. **The ATTRIB tag (group 2) was never parsed** — every parsed-from-file
///     ATTRIB left `tagStringId = -1`, so tools derived a bogus "tag" from
///     the VALUE text. Real tags now round-trip.
///  3. **Multi-line ATTRIB values (group-3 continuation) were truncated** to
///     the final group-1 chunk.
///
/// The fixture `converted_attributes.dxf` mimics ODA/LibreDWG output: an
/// INSERT of block "CARRIER_STATION" on layer "MATERIAL-CARRIER" (note the embedded
/// space) with three ATTRIBs — a normal one (tag NAME), an INVISIBLE one
/// (tag CARRIER_ID, group-70 bit 1), and a MULTI-LINE one (tag NOTES, group-3
/// continuation).
final class ConvertedAttributesTests: XCTestCase {

    private func parsed() throws -> EditableParsedDocument {
        try EntityStoreParser.parse(url: TestFixtures.url("converted_attributes.dxf"))
    }

    private func insertID(in parsed: EditableParsedDocument) throws -> EntityID {
        let store = parsed.store
        for i in store.headers.indices where store.headers[i].type == .insert {
            return EntityID(raw: Int32(i))
        }
        throw XCTSkip("no INSERT parsed")
    }

    // MARK: - Root cause #2: real tag (group 2) is parsed

    func testAttributeTagsAreParsedFromGroupCode2() throws {
        let doc = try parsed()
        let insert = try insertID(in: doc)
        let attrs = BlockEditor.attributes(of: insert, in: doc.store)
        let tags = Set(attrs.map(\.tag))
        XCTAssertTrue(tags.contains("NAME"), "real group-2 tag NAME must be parsed, not derived from the value")
        XCTAssertTrue(tags.contains("CARRIER_ID"))
        XCTAssertTrue(tags.contains("NOTES"))
    }

    func testVisibleAttributeValueIsReadableByRealTag() throws {
        let doc = try parsed()
        let insert = try insertID(in: doc)
        let attrs = BlockEditor.attributes(of: insert, in: doc.store)
        XCTAssertEqual(attrs.first { $0.tag == "NAME" }?.value, "STN-4")
    }

    // MARK: - Root cause #1: invisible attributes retained (not dropped)

    func testInvisibleAttributeIsStillParsedAndReadable() throws {
        let doc = try parsed()
        let insert = try insertID(in: doc)
        let attrs = BlockEditor.attributes(of: insert, in: doc.store)
        // CARRIER_ID has group-70 bit 1 (invisible) — historically dropped
        // entirely; must now be present with its data intact.
        XCTAssertEqual(attrs.first { $0.tag == "CARRIER_ID" }?.value, "CARRIER-0042",
                       "an invisible ATTRIB must be retained so its data is extractable")
    }

    func testInvisibleAttributeIsFlaggedInvisibleInTheStore() throws {
        let doc = try parsed()
        let store = doc.store
        // Find the ATTRIB whose value is the invisible one and confirm the
        // flag is set (so the renderer skips drawing it).
        var found = false
        for i in store.headers.indices where store.headers[i].type == .attrib {
            let h = store.headers[i]
            guard h.payload >= 0 else { continue }
            let value = store.strings.string(for: store.texts[Int(h.payload)].stringId)
            if value == "CARRIER-0042" {
                XCTAssertTrue(h.flags.contains(.invisible), "the invisible ATTRIB must carry EntityFlags.invisible")
                found = true
            }
        }
        XCTAssertTrue(found, "the invisible ATTRIB entity must exist in the store")
    }

    func testVisibleAttributeIsNotFlaggedInvisible() throws {
        let doc = try parsed()
        let store = doc.store
        for i in store.headers.indices where store.headers[i].type == .attrib {
            let h = store.headers[i]
            guard h.payload >= 0 else { continue }
            if store.strings.string(for: store.texts[Int(h.payload)].stringId) == "STN-4" {
                XCTAssertFalse(h.flags.contains(.invisible), "a visible ATTRIB must not be flagged invisible")
            }
        }
    }

    // MARK: - Root cause #3: multi-line value (group-3 continuation)

    func testMultilineAttributeValueConcatenatesGroup3Continuation() throws {
        let doc = try parsed()
        let insert = try insertID(in: doc)
        let attrs = BlockEditor.attributes(of: insert, in: doc.store)
        // NOTES has group-3 "Line one" + group-1 " line two"; historically
        // only the group-1 chunk survived.
        XCTAssertEqual(attrs.first { $0.tag == "NOTES" }?.value, "Zone-7,Bay-3")
    }

    // MARK: - Layer name with an embedded space is preserved end-to-end

    func testLayerNameWithSpaceIsPreserved() throws {
        let doc = try parsed()
        XCTAssertNotNil(doc.layerIdByName["MATERIAL-CARRIER"],
                        "a layer name containing a space must be preserved verbatim")
        let insert = try insertID(in: doc)
        let layerId = doc.store.headers[Int(insert.raw)].layerId
        XCTAssertEqual(doc.layers[Int(layerId)].name, "MATERIAL-CARRIER")
    }

    // MARK: - All three attributes flow through to Data Extraction

    func testDataExtractionSurfacesEveryAttributeIncludingInvisible() throws {
        let doc = try parsed()
        let rows = DataExtraction.extractRows(from: doc)
        let insertRow = try XCTUnwrap(rows.first { $0.blockName == "CARRIER_STATION" })
        XCTAssertEqual(insertRow.attributes["NAME"], "STN-4")
        XCTAssertEqual(insertRow.attributes["CARRIER_ID"], "CARRIER-0042",
                       "the invisible attribute must appear in the extracted data, not be missing")
        XCTAssertEqual(insertRow.attributes["NOTES"], "Zone-7,Bay-3")

        // And in the emitted CSV header/body.
        let csv = DataExtraction.csv(for: rows)
        XCTAssertTrue(csv.contains("CARRIER_ID"), "the invisible attribute's real tag must be a CSV column")
        XCTAssertTrue(csv.contains("CARRIER-0042"))
    }

    // MARK: - Re-import round trip keyed on the real tag actually applies

    func testReimportEditKeyedOnRealTagApplies() throws {
        let doc = try parsed()
        let insert = try insertID(in: doc)
        // Before the tag fix, an edit keyed on "CARRIER_ID" would find no
        // matching tag (the tag was value-derived) and be silently skipped.
        let edit = DataExtraction.ParsedEdit(entityId: insert.raw, layer: nil, color: nil,
                                             text: nil, textPresent: false, blockNamePresent: false,
                                             attributes: ["CARRIER_ID": "CARRIER-9999"])
        var result = DataExtraction.ApplyResult()
        doc.document.transact("Import") { tx in
            result = DataExtraction.apply([edit], in: doc, tx: tx)
        }
        XCTAssertEqual(result.attributeEdits, 1, "an edit keyed on the real tag must match and apply")
        XCTAssertEqual(BlockEditor.attributes(of: insert, in: doc.store).first { $0.tag == "CARRIER_ID" }?.value, "CARRIER-9999")
    }

    // MARK: - Root cause #4 (regression): visible ATTRIBs must actually RENDER
    //
    // Fixing root cause #1 (retaining, not dropping, an ATTRIB — see this
    // file's own header) correctly links a parsed ATTRIB to its owning
    // INSERT via `OwnerRef.parentEntity` (matching `BlockEditor.insert`'s own
    // convention). But `Regenerator`'s render walk (`EntitySource` in
    // `Regenerator.swift`) only ever visits `.space(...)` (model/paper-owned
    // entities) and `.blockRange(...)` (a block DEFINITION's own content) —
    // NEITHER of which ever matches an entity owned via `.parentEntity`. So a
    // correctly-linked, VISIBLE ATTRIB (its per-instance attribute VALUE —
    // e.g. an actual workstation name) was parsed fine and extractable via
    // Data Extraction, yet never reached the canvas: the object itself
    // rendered, but its attribute label silently did not. Verified against a
    // real converted factory layout: only a small fraction of the expected
    // label/ATTRIB text parts rendered before this fix.
    //
    // The INSERT's own top-level walk in `Regenerator.swift` now also visits
    // `store.children(of: insertId)` for its ATTRIB children directly,
    // emitting each one (skipping any still flagged invisible) using the
    // INSERT's OWN placement transform — matching how AutoCAD stores an
    // ATTRIB instance's coordinates in absolute world space, not
    // block-definition-relative.

    func testVisibleAttributeValueAppearsInTheRenderedModel() throws {
        let doc = try parsed()
        let rc = RegenCoordinator(parsed: doc, document: Regenerator.build(from: doc, parseSeconds: 0) { _ in })
        let texts = rc.document.modelGroups.flatMap(\.texts) + rc.document.paperGroups.flatMap(\.texts)
        XCTAssertTrue(texts.contains { $0.text == "STN-4" },
                     "the visible NAME attribute's value must appear in the render model, not just be data-extractable")
    }

    func testInvisibleAttributeValueDoesNotAppearInTheRenderedModel() throws {
        let doc = try parsed()
        let rc = RegenCoordinator(parsed: doc, document: Regenerator.build(from: doc, parseSeconds: 0) { _ in })
        let texts = rc.document.modelGroups.flatMap(\.texts) + rc.document.paperGroups.flatMap(\.texts)
        XCTAssertFalse(texts.contains { $0.text == "CARRIER-0042" },
                       "an invisible attribute must still be data-extractable, but must NOT be drawn")
    }

    func testMultilineAttributeValueAppearsInTheRenderedModel() throws {
        let doc = try parsed()
        let rc = RegenCoordinator(parsed: doc, document: Regenerator.build(from: doc, parseSeconds: 0) { _ in })
        let texts = rc.document.modelGroups.flatMap(\.texts) + rc.document.paperGroups.flatMap(\.texts)
        XCTAssertTrue(texts.contains { $0.text == "Zone-7,Bay-3" })
    }

    // MARK: - Write → reparse round trip preserves the real tag + invisibility

    func testRealTagAndInvisibilitySurviveAWriteReparseRoundTrip() throws {
        let doc = try parsed()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("converted-roundtrip-\(UUID().uuidString).dxf")
        defer { try? FileManager.default.removeItem(at: tmp) }
        _ = try DXFStructuralWriter.write(doc, to: tmp, options: DXFWriteOptions(version: .r2018))

        let reparsed = try PackageLoader.loadIntoStore(url: tmp)
        let insert = try insertID(in: reparsed)
        let attrs = BlockEditor.attributes(of: insert, in: reparsed.store)
        // The real tags (not value-derived) must survive the save.
        XCTAssertEqual(attrs.first { $0.tag == "NAME" }?.value, "STN-4")
        XCTAssertEqual(attrs.first { $0.tag == "CARRIER_ID" }?.value, "CARRIER-0042")

        // The invisible attribute must still be flagged invisible after reload.
        var checkedInvisible = false
        for i in reparsed.store.headers.indices where reparsed.store.headers[i].type == .attrib {
            let h = reparsed.store.headers[i]
            guard h.payload >= 0 else { continue }
            if reparsed.store.strings.string(for: reparsed.store.texts[Int(h.payload)].stringId) == "CARRIER-0042" {
                XCTAssertTrue(h.flags.contains(.invisible), "invisibility must survive a write→reparse round trip")
                checkedInvisible = true
            }
        }
        XCTAssertTrue(checkedInvisible)
    }
}
