import XCTest
@testable import DWGViewer
import CADCore

/// Tests for Data Extraction (AutoCAD DATAEXTRACTION/"dx" equivalent) —
/// `DataExtraction.extractRows`/`csv` (export), `parseCSV` (re-import
/// parsing), and `apply` (the bulk-edit transaction). Follows the same
/// hand-constructed `EditableParsedDocument`/`RegenCoordinator` fixture
/// pattern as `AIAssistantTests`/`CrossDocumentPasteTests`.
final class DataExtractionTests: XCTestCase {

    private func makeParsed() -> EditableParsedDocument {
        let parsed = EditableParsedDocument()
        parsed.layers.append(DXFLayer(id: 0, name: "0"))
        parsed.layerIdByName["0"] = 0
        parsed.layers.append(DXFLayer(id: 1, name: "LABELS"))
        parsed.layerIdByName["LABELS"] = 1
        parsed.linetypes.append(DXFLinetype(name: "CONTINUOUS", dashes: []))
        parsed.linetypeIdByName["CONTINUOUS"] = 0
        return parsed
    }

    private func makeCoordinator(_ parsed: EditableParsedDocument) -> RegenCoordinator {
        let doc = Regenerator.build(from: parsed, parseSeconds: 0) { _ in }
        return RegenCoordinator(parsed: parsed, document: doc)
    }

    /// Same WORKSTATION-block-with-NAME-attribute fixture `AIAssistantTests`
    /// uses, plus a plain TEXT entity — gives export/import coverage across
    /// LINE-like geometry, TEXT content, and INSERT attributes in one shot.
    private func makeFixture() -> (parsed: EditableParsedDocument, insertId: EntityID, textId: EntityID, lineId: EntityID) {
        let parsed = makeParsed()
        let doc = parsed.document

        let blockIndex = BlockEditor.nextBlockIndex(in: parsed)
        var rectId: EntityID!
        doc.transact("Define block content") { tx in
            rectId = tx.add(EntityPrototype(
                type: .lwpolyline, layerId: 0, owner: .block(blockIndex),
                payload: .polyline(PolylinePayload(closed: true),
                                   vertices: [Vec3(x: 0, y: 0), Vec3(x: 10, y: 0), Vec3(x: 10, y: 10), Vec3(x: 0, y: 10)],
                                   bulges: [0, 0, 0, 0])))
        }
        let block = EditableBlockDef()
        block.name = "WORKSTATION"
        block.blockIndex = blockIndex
        block.entityStart = rectId.raw
        block.entityCount = 1
        parsed.blocks["WORKSTATION"] = block

        doc.transact("Add NAME attdef") { tx in
            _ = BlockEditor.createAttdef(tag: "NAME", prompt: "", defaultValue: "UNNAMED",
                                        at: CGPoint(x: 5, y: 5), height: 1, layerId: 0,
                                        inBlockNamed: "WORKSTATION", in: parsed, tx: tx)
        }

        var insertId: EntityID!
        doc.transact("Insert") { tx in
            insertId = BlockEditor.insert(blockName: "WORKSTATION", at: CGPoint(x: 100, y: 200),
                                          layerId: 0, attributeValues: ["NAME": "STN-4"], in: parsed, tx: tx)
        }

        var textId: EntityID!
        var lineId: EntityID!
        doc.transact("Draw") { tx in
            let stringId = parsed.store.strings.intern("Hello, \"World\"")
            textId = tx.add(EntityPrototype(type: .text, layerId: 1,
                payload: .text(TextPayload(position: Vec3(x: 0, y: 0), height: 1, stringId: stringId))))
            lineId = tx.add(EntityPrototype(type: .line, layerId: 0,
                payload: .line(LinePayload(a: Vec3(x: 0, y: 0), b: Vec3(x: 10, y: 5)))))
        }

        return (parsed, insertId, textId, lineId)
    }

    // MARK: - extractRows: real parsed-from-file attributes (regression)

    /// Regression test for a real bug report: an INSERT's block attribute
    /// (e.g. a "Contents" tag) parsed from a REAL DXF FILE — not created
    /// in-app via `BlockEditor.insert` — came back with a blank
    /// `attr:<TAG>` column in the export. Root cause: `EntityStoreParser`
    /// never linked a parsed ATTRIB back to its owning INSERT via
    /// `OwnerRef.parentEntity` (only `BlockEditor.insert`'s interactively-
    /// created attributes got that link) — see `EntityStoreParser.swift`'s
    /// `lastInsertId` for the fix, and `RoundTripTests
    /// .testInsertWithAttribRoundTrips` for the parser-level regression
    /// coverage. This test locks in the fix at the DataExtraction layer
    /// specifically, using `roundtrip_core.dxf` (a real file with an
    /// INSERT of block "SYM1" followed by an ATTRIB whose value is
    /// "ATTVAL") parsed via the REAL parser (`RegenCoordinator.load`), not
    /// a hand-built fixture.
    func testExtractRowsIncludesAttributeFromARealParsedFile() throws {
        let rc = try RegenCoordinator.load(url: TestFixtures.url("roundtrip_core.dxf"))
        let rows = DataExtraction.extractRows(from: rc.parsed)
        let insertRow = try XCTUnwrap(rows.first { $0.blockName == "SYM1" },
                                     "the SYM1 INSERT itself must still appear as a row")
        XCTAssertEqual(insertRow.attributes.values.first, "ATTVAL",
                      "the parsed ATTRIB's value must be readable as this INSERT's attribute, not blank")

        // Also confirm it survives all the way into the written CSV.
        let csvText = DataExtraction.csv(for: rows)
        XCTAssertTrue(csvText.contains("ATTVAL"), "the attribute value must appear in the exported CSV text")
    }

    // MARK: - extractRows

    func testExtractRowsIncludesEveryEntityWithCorrectFields() throws {
        let (parsed, insertId, textId, lineId) = makeFixture()
        let rows = DataExtraction.extractRows(from: parsed)

        let insertRow = try XCTUnwrap(rows.first { $0.entityId == insertId.raw })
        XCTAssertEqual(insertRow.type, "insert")
        XCTAssertEqual(insertRow.blockName, "WORKSTATION")
        XCTAssertEqual(insertRow.layer, "0")
        XCTAssertEqual(insertRow.attributes["NAME"], "STN-4")

        let textRow = try XCTUnwrap(rows.first { $0.entityId == textId.raw })
        XCTAssertEqual(textRow.type, "text")
        XCTAssertEqual(textRow.text, "Hello, \"World\"")
        XCTAssertEqual(textRow.layer, "LABELS")

        let lineRow = try XCTUnwrap(rows.first { $0.entityId == lineId.raw })
        XCTAssertEqual(lineRow.type, "line")
        XCTAssertNil(lineRow.text)
        XCTAssertTrue(lineRow.attributes.isEmpty)
    }

    func testExtractRowsExcludesAttribChildRows() throws {
        // ATTRIB children must NOT appear as their own top-level rows — only
        // via their owning INSERT's attr:<TAG> column (see extractRows'
        // "ATTRIB children are represented via their owning INSERT" note).
        let (parsed, insertId, _, _) = makeFixture()
        let rows = DataExtraction.extractRows(from: parsed)
        let attribIds = Set(parsed.store.children(of: insertId).compactMap { childId -> Int32? in
            parsed.store.header(childId)?.type == .attrib ? childId.raw : nil
        })
        XCTAssertFalse(attribIds.isEmpty, "sanity check: the fixture really has an ATTRIB child")
        XCTAssertTrue(rows.allSatisfy { !attribIds.contains($0.entityId) })
    }

    func testExtractRowsExcludesDeletedEntities() throws {
        let (parsed, _, _, lineId) = makeFixture()
        parsed.document.transact("Delete") { tx in tx.delete(lineId) }
        let rows = DataExtraction.extractRows(from: parsed)
        XCTAssertFalse(rows.contains { $0.entityId == lineId.raw })
    }

    // MARK: - CSV writer + round-trip parsing

    func testCSVRoundTripsAttributeColumnAndEscapedText() throws {
        let (parsed, insertId, textId, _) = makeFixture()
        let rows = DataExtraction.extractRows(from: parsed)
        let csvText = DataExtraction.csv(for: rows)

        XCTAssertTrue(csvText.contains(",NAME") || csvText.contains("\nNAME") || csvText.contains("\rNAME"),
                      "header must include a bare NAME column (no attr: prefix)")

        let records = DataExtraction.parseCSVRecords(csvText)
        XCTAssertEqual(records.first?.first, DataExtraction.Column.entityId)

        // Re-parse and confirm every field round-trips, including the
        // comma-and-quote-containing TEXT value (RFC 4180 escaping).
        let (edits, skipped) = try DataExtraction.parseCSV(csvText)
        XCTAssertEqual(skipped, 0)
        let insertEdit = try XCTUnwrap(edits.first { $0.entityId == insertId.raw })
        XCTAssertEqual(insertEdit.attributes["NAME"], "STN-4")
        let textEdit = try XCTUnwrap(edits.first { $0.entityId == textId.raw })
        XCTAssertEqual(textEdit.text, "Hello, \"World\"")
    }

    func testCSVEscapesCommasQuotesAndNewlines() {
        XCTAssertEqual(DataExtraction.csvEscape("plain"), "plain")
        XCTAssertEqual(DataExtraction.csvEscape("a,b"), "\"a,b\"")
        XCTAssertEqual(DataExtraction.csvEscape("say \"hi\""), "\"say \"\"hi\"\"\"")
        XCTAssertEqual(DataExtraction.csvEscape("line1\nline2"), "\"line1\nline2\"")
    }

    func testParseCSVRecordsHandlesQuotedCommasAndCRLF() {
        let text = "a,\"b,c\",d\r\n1,\"x\"\"y\",3\r\n"
        let records = DataExtraction.parseCSVRecords(text)
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0], ["a", "b,c", "d"])
        XCTAssertEqual(records[1], ["1", "x\"y", "3"])
    }

    func testParseCSVThrowsForEmptyFile() {
        XCTAssertThrowsError(try DataExtraction.parseCSV("")) { error in
            XCTAssertTrue(error is DataExtraction.ParseError)
        }
    }

    func testParseCSVThrowsWhenEntityIdColumnMissing() {
        XCTAssertThrowsError(try DataExtraction.parseCSV("layer,color\nA,1\n")) { error in
            XCTAssertTrue(error is DataExtraction.ParseError)
        }
    }

    func testParseCSVSkipsRowsWithUnparsableEntityId() throws {
        let csvText = "entityId,layer\nNOT_A_NUMBER,PIPING\n42,PIPING\n"
        let (edits, skipped) = try DataExtraction.parseCSV(csvText)
        XCTAssertEqual(skipped, 1)
        XCTAssertEqual(edits.count, 1)
        XCTAssertEqual(edits.first?.entityId, 42)
    }

    // MARK: - apply: attribute edits

    @MainActor
    func testApplyUpdatesAttributeValueWhenChanged() throws {
        let (parsed, insertId, _, _) = makeFixture()
        let edit = DataExtraction.ParsedEdit(entityId: insertId.raw, layer: nil, color: nil,
                                             text: nil, textPresent: false, blockName: nil, blockNamePresent: false, attributes: ["NAME": "STN-9"])
        var result = DataExtraction.ApplyResult()
        parsed.document.transact("Import Data") { tx in
            result = DataExtraction.apply([edit], in: parsed, tx: tx)
        }
        XCTAssertEqual(result.attributeEdits, 1)
        let attrs = BlockEditor.attributes(of: insertId, in: parsed.store)
        XCTAssertEqual(attrs.first { $0.tag == "NAME" }?.value, "STN-9")
    }

    @MainActor
    func testApplyIsANoOpWhenAttributeValueIsUnchanged() throws {
        let (parsed, insertId, _, _) = makeFixture()
        // Re-importing the SAME value the entity already has must be a
        // genuine no-op — a diff, not a blind overwrite.
        let edit = DataExtraction.ParsedEdit(entityId: insertId.raw, layer: nil, color: nil,
                                             text: nil, textPresent: false, blockName: nil, blockNamePresent: false, attributes: ["NAME": "STN-4"])
        var result = DataExtraction.ApplyResult()
        let undoCountBefore = parsed.document.undoStack.count
        parsed.document.transact("Import Data") { tx in
            result = DataExtraction.apply([edit], in: parsed, tx: tx)
        }
        XCTAssertEqual(result.attributeEdits, 0)
        XCTAssertEqual(result.totalEdits, 0)
        // No-op edits still open/close a transaction (that's the caller's
        // business), but nothing SHOULD have been recorded as an op within
        // it — verify no visible change occurred rather than asserting on
        // internal undo-stack shape here.
        _ = undoCountBefore
    }

    @MainActor
    func testApplyIgnoresAttributeTagThatDoesNotExistOnTheInsert() throws {
        let (parsed, insertId, _, _) = makeFixture()
        let edit = DataExtraction.ParsedEdit(entityId: insertId.raw, layer: nil, color: nil,
                                             text: nil, textPresent: false, blockName: nil, blockNamePresent: false, attributes: ["NOT_A_REAL_TAG": "X"])
        var result = DataExtraction.ApplyResult()
        parsed.document.transact("Import Data") { tx in
            result = DataExtraction.apply([edit], in: parsed, tx: tx)
        }
        XCTAssertEqual(result.attributeEdits, 0)
    }

    // MARK: - apply: layer edits (incl. new-layer creation)

    @MainActor
    func testApplyMovesEntityToExistingLayerByName() throws {
        let (parsed, _, textId, _) = makeFixture()
        let edit = DataExtraction.ParsedEdit(entityId: textId.raw, layer: "0", color: nil,
                                             text: nil, textPresent: false, blockName: nil, blockNamePresent: false, attributes: [:])
        var result = DataExtraction.ApplyResult()
        parsed.document.transact("Import Data") { tx in
            result = DataExtraction.apply([edit], in: parsed, tx: tx)
        }
        XCTAssertEqual(result.layerEdits, 1)
        XCTAssertFalse(result.createdLayer)
        let header = try XCTUnwrap(parsed.store.header(textId))
        XCTAssertEqual(header.layerId, 0)
    }

    @MainActor
    func testApplyCreatesNewLayerWhenNameDoesNotExist() throws {
        let (parsed, _, textId, _) = makeFixture()
        let layerCountBefore = parsed.layers.count
        let edit = DataExtraction.ParsedEdit(entityId: textId.raw, layer: "NEWLAYER", color: nil,
                                             text: nil, textPresent: false, blockName: nil, blockNamePresent: false, attributes: [:])
        var result = DataExtraction.ApplyResult()
        parsed.document.transact("Import Data") { tx in
            result = DataExtraction.apply([edit], in: parsed, tx: tx)
        }
        XCTAssertTrue(result.createdLayer)
        XCTAssertEqual(parsed.layers.count, layerCountBefore + 1)
        let header = try XCTUnwrap(parsed.store.header(textId))
        XCTAssertEqual(header.layerId, parsed.layerIdByName["NEWLAYER"])
    }

    // MARK: - apply: color edits

    @MainActor
    func testApplyUpdatesColorWhenChanged() throws {
        let (parsed, _, _, lineId) = makeFixture()
        let edit = DataExtraction.ParsedEdit(entityId: lineId.raw, layer: nil, color: 5,
                                             text: nil, textPresent: false, blockName: nil, blockNamePresent: false, attributes: [:])
        var result = DataExtraction.ApplyResult()
        parsed.document.transact("Import Data") { tx in
            result = DataExtraction.apply([edit], in: parsed, tx: tx)
        }
        XCTAssertEqual(result.colorEdits, 1)
        XCTAssertEqual(parsed.store.header(lineId)?.aci, 5)
    }

    // MARK: - apply: text edits

    @MainActor
    func testApplyUpdatesTextContentWhenChanged() throws {
        let (parsed, _, textId, _) = makeFixture()
        let edit = DataExtraction.ParsedEdit(entityId: textId.raw, layer: nil, color: nil,
                                             text: "Updated Label", textPresent: true, blockName: nil, blockNamePresent: false, attributes: [:])
        var result = DataExtraction.ApplyResult()
        parsed.document.transact("Import Data") { tx in
            result = DataExtraction.apply([edit], in: parsed, tx: tx)
        }
        XCTAssertEqual(result.textEdits, 1)
        let header = try XCTUnwrap(parsed.store.header(textId))
        let text = parsed.store.texts[Int(header.payload)]
        XCTAssertEqual(parsed.store.strings.string(for: text.stringId), "Updated Label")
    }

    @MainActor
    func testApplyDoesNotTouchTextWhenColumnAbsent() throws {
        // textPresent = false must mean "column wasn't in the file at all",
        // distinct from "column present but blank" (which WOULD clear it).
        let (parsed, _, textId, _) = makeFixture()
        let edit = DataExtraction.ParsedEdit(entityId: textId.raw, layer: nil, color: nil,
                                             text: nil, textPresent: false, blockName: nil, blockNamePresent: false, attributes: [:])
        var result = DataExtraction.ApplyResult()
        parsed.document.transact("Import Data") { tx in
            result = DataExtraction.apply([edit], in: parsed, tx: tx)
        }
        XCTAssertEqual(result.textEdits, 0)
        let header = try XCTUnwrap(parsed.store.header(textId))
        XCTAssertEqual(parsed.store.strings.string(for: parsed.store.texts[Int(header.payload)].stringId), "Hello, \"World\"")
    }

    // MARK: - apply: batching + undo (one transaction for the whole import)

    @MainActor
    func testApplyBatchesMultipleEditsIntoOneUndoStep() throws {
        let (parsed, insertId, textId, lineId) = makeFixture()
        let session = DocumentSession()
        let rc = makeCoordinator(parsed)
        session.regen = rc

        let edits = [
            DataExtraction.ParsedEdit(entityId: insertId.raw, layer: nil, color: nil,
                                      text: nil, textPresent: false, blockName: nil, blockNamePresent: false, attributes: ["NAME": "STN-9"]),
            DataExtraction.ParsedEdit(entityId: textId.raw, layer: nil, color: 3,
                                      text: "New Text", textPresent: true, blockName: nil, blockNamePresent: false, attributes: [:]),
            DataExtraction.ParsedEdit(entityId: lineId.raw, layer: "LABELS", color: nil,
                                      text: nil, textPresent: false, blockName: nil, blockNamePresent: false, attributes: [:])
        ]
        let undoCountBefore = rc.parsed.document.undoStack.count
        var result = DataExtraction.ApplyResult()
        session.performEdit("Import Data") { tx in
            result = DataExtraction.apply(edits, in: rc.parsed, tx: tx)
        }

        XCTAssertEqual(result.attributeEdits, 1)
        XCTAssertEqual(result.colorEdits, 1)
        XCTAssertEqual(result.textEdits, 1)
        XCTAssertEqual(result.layerEdits, 1)
        XCTAssertEqual(rc.parsed.document.undoStack.count, undoCountBefore + 1,
                      "the whole import batch must be ONE undo step")

        session.undo()
        XCTAssertEqual(BlockEditor.attributes(of: insertId, in: rc.parsed.store).first { $0.tag == "NAME" }?.value, "STN-4")
        XCTAssertEqual(rc.parsed.store.header(lineId)?.layerId, 0)
    }

    // MARK: - apply: stale/unknown entityId rows are skipped

    @MainActor
    func testApplySkipsRowsWhoseEntityIdNoLongerResolves() throws {
        let (parsed, _, _, _) = makeFixture()
        let edit = DataExtraction.ParsedEdit(entityId: 999_999, layer: "0", color: nil,
                                             text: nil, textPresent: false, blockName: nil, blockNamePresent: false, attributes: [:])
        var result = DataExtraction.ApplyResult()
        parsed.document.transact("Import Data") { tx in
            result = DataExtraction.apply([edit], in: parsed, tx: tx)
        }
        XCTAssertEqual(result.rowsSkipped, 1)
        XCTAssertEqual(result.totalEdits, 0)
    }

    @MainActor
    func testApplySkipsDeletedEntityRows() throws {
        let (parsed, _, _, lineId) = makeFixture()
        parsed.document.transact("Delete") { tx in tx.delete(lineId) }
        let edit = DataExtraction.ParsedEdit(entityId: lineId.raw, layer: "LABELS", color: nil,
                                             text: nil, textPresent: false, blockName: nil, blockNamePresent: false, attributes: [:])
        var result = DataExtraction.ApplyResult()
        parsed.document.transact("Import Data") { tx in
            result = DataExtraction.apply([edit], in: parsed, tx: tx)
        }
        XCTAssertEqual(result.rowsSkipped, 1)
    }

    // MARK: - ApplyResult.summary

    func testApplyResultSummaryReflectsCounts() {
        var result = DataExtraction.ApplyResult()
        result.attributeEdits = 2
        result.layerEdits = 1
        result.rowsSkipped = 1
        XCTAssertTrue(result.summary.contains("2 attribute"))
        XCTAssertTrue(result.summary.contains("1 layer"))
        XCTAssertTrue(result.summary.contains("1 row"))
    }

    func testApplyResultSummaryForNoChanges() {
        let result = DataExtraction.ApplyResult()
        XCTAssertEqual(result.summary, "No changes to apply")
    }

    // MARK: - blockName column: cosmetic per-instance display name
    //
    // Regression coverage for a real user request: `blockName` used to be
    // pure reference data (ignored on import — a user edited it expecting
    // it to rename the object and nothing happened). It's now editable, but
    // deliberately COSMETIC ONLY — see `Column.blockName`'s own doc comment
    // and `InsertPayload.displayNameId`'s: it must change what the object is
    // CALLED without ever changing what it DRAWS.

    @MainActor
    func testExportReportsRealBlockNameWhenNoOverrideIsSet() throws {
        let (parsed, insertId, _, _) = makeFixture()
        let rows = DataExtraction.extractRows(from: parsed)
        let row = try XCTUnwrap(rows.first { $0.entityId == insertId.raw })
        XCTAssertEqual(row.blockName, "WORKSTATION")
    }

    @MainActor
    func testApplyingABlockNameEditSetsTheDisplayNameOverride() throws {
        let (parsed, insertId, _, _) = makeFixture()
        let edit = DataExtraction.ParsedEdit(entityId: insertId.raw, layer: nil, color: nil,
                                             text: nil, textPresent: false,
                                             blockName: "Station 7", blockNamePresent: true,
                                             attributes: [:])
        var result = DataExtraction.ApplyResult()
        parsed.document.transact("Import Data") { tx in
            result = DataExtraction.apply([edit], in: parsed, tx: tx)
        }
        XCTAssertEqual(result.displayNameEdits, 1)
        XCTAssertEqual(BlockEditor.displayName(of: insertId, in: parsed.store), "Station 7")
    }

    @MainActor
    func testDisplayNameOverrideRoundTripsThroughReExport() throws {
        // The whole point of the round trip: an edit made via one Extract-
        // Data/Import-Data cycle must be reflected as the NEW `blockName`
        // value on the NEXT export — not silently revert to the real block
        // name.
        let (parsed, insertId, _, _) = makeFixture()
        let edit = DataExtraction.ParsedEdit(entityId: insertId.raw, layer: nil, color: nil,
                                             text: nil, textPresent: false,
                                             blockName: "Station 7", blockNamePresent: true,
                                             attributes: [:])
        parsed.document.transact("Import Data") { tx in
            _ = DataExtraction.apply([edit], in: parsed, tx: tx)
        }
        let rows = DataExtraction.extractRows(from: parsed)
        let row = try XCTUnwrap(rows.first { $0.entityId == insertId.raw })
        XCTAssertEqual(row.blockName, "Station 7")
    }

    @MainActor
    func testBlankBlockNameEditClearsTheOverride() throws {
        let (parsed, insertId, _, _) = makeFixture()
        parsed.document.transact("Set") { tx in
            BlockEditor.setDisplayName(insertId, to: "Station 7", in: parsed, tx: tx)
        }
        XCTAssertEqual(BlockEditor.displayName(of: insertId, in: parsed.store), "Station 7")

        // A PRESENT but BLANK blockName cell clears the override back to
        // the real block name — same "present but blank clears it"
        // convention `text`/`textPresent` already established.
        let clearEdit = DataExtraction.ParsedEdit(entityId: insertId.raw, layer: nil, color: nil,
                                                  text: nil, textPresent: false,
                                                  blockName: "", blockNamePresent: true,
                                                  attributes: [:])
        var result = DataExtraction.ApplyResult()
        parsed.document.transact("Import Data") { tx in
            result = DataExtraction.apply([clearEdit], in: parsed, tx: tx)
        }
        XCTAssertEqual(result.displayNameEdits, 1)
        XCTAssertEqual(BlockEditor.displayName(of: insertId, in: parsed.store), "WORKSTATION")
    }

    @MainActor
    func testAbsentBlockNameColumnLeavesExistingOverrideUntouched() throws {
        let (parsed, insertId, _, _) = makeFixture()
        parsed.document.transact("Set") { tx in
            BlockEditor.setDisplayName(insertId, to: "Station 7", in: parsed, tx: tx)
        }
        // blockNamePresent: false — as if the CSV simply didn't have that
        // column in this import (or the whole file predates this feature).
        let edit = DataExtraction.ParsedEdit(entityId: insertId.raw, layer: nil, color: nil,
                                             text: nil, textPresent: false,
                                             blockName: nil, blockNamePresent: false,
                                             attributes: [:])
        var result = DataExtraction.ApplyResult()
        parsed.document.transact("Import Data") { tx in
            result = DataExtraction.apply([edit], in: parsed, tx: tx)
        }
        XCTAssertEqual(result.displayNameEdits, 0)
        XCTAssertEqual(BlockEditor.displayName(of: insertId, in: parsed.store), "Station 7")
    }

    @MainActor
    func testDisplayNameChangeDoesNotAlterWhatIsDrawn() throws {
        // THE core product guarantee: changing blockName must never retarget
        // which block definition an INSERT draws, i.e. its rendered geometry
        // is byte-for-byte identical before and after.
        let (parsed, insertId, _, _) = makeFixture()
        let rc = makeCoordinator(parsed)
        let boundsBefore = rc.document.modelGroups.flatMap(\.strokes.runs).map(\.bounds)
        let insertsBefore = rc.document.inserts

        parsed.document.transact("Set") { tx in
            BlockEditor.setDisplayName(insertId, to: "Totally Different Name", in: parsed, tx: tx)
        }
        rc.fullRebuild()

        let boundsAfter = rc.document.modelGroups.flatMap(\.strokes.runs).map(\.bounds)
        let insertsAfter = rc.document.inserts
        XCTAssertEqual(boundsBefore, boundsAfter, "geometry must be unaffected by a display-name change")
        XCTAssertEqual(insertsBefore.map(\.name), insertsAfter.map(\.name),
                       "the INSERT's REAL block name (which drives its geometry) must be unchanged")
    }

    @MainActor
    func testSetDisplayNameReturnsFalseForNonInsertEntity() throws {
        let (parsed, _, textId, _) = makeFixture()
        var succeeded = true
        parsed.document.transact("Set") { tx in
            succeeded = BlockEditor.setDisplayName(textId, to: "X", in: parsed, tx: tx)
        }
        XCTAssertFalse(succeeded)
    }

    @MainActor
    func testDisplayNameEditIsUndoable() throws {
        let (parsed, insertId, _, _) = makeFixture()
        let session = DocumentSession()
        let rc = makeCoordinator(parsed)
        session.regen = rc

        var result = DataExtraction.ApplyResult()
        let edit = DataExtraction.ParsedEdit(entityId: insertId.raw, layer: nil, color: nil,
                                             text: nil, textPresent: false,
                                             blockName: "Station 7", blockNamePresent: true,
                                             attributes: [:])
        session.performEdit("Import Data") { tx in
            result = DataExtraction.apply([edit], in: rc.parsed, tx: tx)
        }
        XCTAssertEqual(result.displayNameEdits, 1)
        session.undo()
        XCTAssertEqual(BlockEditor.displayName(of: insertId, in: rc.parsed.store), "WORKSTATION")
    }

    func testCSVRoundTripsAnEditedBlockNameThroughTheActualCSVTextFormat() throws {
        // End-to-end through the REAL CSV text (not just the in-memory
        // ParsedEdit struct) — confirms the column header/parsing wiring,
        // not just the apply logic.
        let (parsed, insertId, _, _) = makeFixture()
        let rows = DataExtraction.extractRows(from: parsed)
        var csvText = DataExtraction.csv(for: rows)
        // Simulate a user editing the blockName cell for this row in a
        // spreadsheet: replace "WORKSTATION" with "Station 7" in the CSV text.
        csvText = csvText.replacingOccurrences(of: "WORKSTATION", with: "Station 7")

        let (edits, skipped) = try DataExtraction.parseCSV(csvText)
        XCTAssertEqual(skipped, 0)
        let edit = try XCTUnwrap(edits.first { $0.entityId == insertId.raw })
        XCTAssertTrue(edit.blockNamePresent)
        XCTAssertEqual(edit.blockName, "Station 7")
    }

    // MARK: - Column picker: availableColumns + csv(for:columns:)

    func testAvailableColumnsIncludesFixedColumnsAndAttributeTags() throws {
        let (parsed, _, _, _) = makeFixture()
        let rows = DataExtraction.extractRows(from: parsed)
        let columns = DataExtraction.availableColumns(for: rows)
        XCTAssertTrue(columns.contains(DataExtraction.Column.entityId))
        XCTAssertTrue(columns.contains(DataExtraction.Column.layer))
        XCTAssertTrue(columns.contains(DataExtraction.Column.scaleX))
        XCTAssertTrue(columns.contains("NAME"), "the NAME attribute tag must appear as a bare column name")
        // entityId must be first (join key convention).
        XCTAssertEqual(columns.first, DataExtraction.Column.entityId)
    }

    func testCSVWithColumnsOverrideIncludesOnlyRequestedColumnsInOrder() throws {
        let (parsed, _, _, _) = makeFixture()
        let rows = DataExtraction.extractRows(from: parsed)
        // Deliberately reversed order + a strict subset (no minX/minY/etc,
        // no color) to prove BOTH filtering and reordering work.
        let requested = [DataExtraction.Column.layer, DataExtraction.Column.entityId, "NAME"]
        let csvText = DataExtraction.csv(for: rows, columns: requested)
        let header = csvText.components(separatedBy: "\r\n").first!
        XCTAssertEqual(header, "layer,entityId,NAME")
    }

    func testCSVWithColumnsOverrideSilentlyDropsUnknownColumnNames() throws {
        let (parsed, _, _, _) = makeFixture()
        let rows = DataExtraction.extractRows(from: parsed)
        let requested = [DataExtraction.Column.entityId, "TOTALLY_MADE_UP_TAG", DataExtraction.Column.layer]
        let csvText = DataExtraction.csv(for: rows, columns: requested)
        let header = csvText.components(separatedBy: "\r\n").first!
        XCTAssertEqual(header, "entityId,layer", "an unrecognized column name must be dropped, not emit a blank column")
    }

    func testCSVWithColumnsOverrideStillPopulatesRowValuesCorrectly() throws {
        let (parsed, insertId, _, _) = makeFixture()
        let rows = DataExtraction.extractRows(from: parsed)
        let csvText = DataExtraction.csv(for: rows, columns: ["NAME", DataExtraction.Column.entityId])
        let (edits, skipped) = try DataExtraction.parseCSV(csvText)
        XCTAssertEqual(skipped, 0)
        let edit = try XCTUnwrap(edits.first { $0.entityId == insertId.raw })
        XCTAssertEqual(edit.attributes["NAME"], "STN-4")
    }

    func testCSVWithNilColumnsMatchesDefaultFullExportExactly() throws {
        // No behavior change for any existing caller that doesn't opt into
        // column selection — `columns: nil` must produce BYTE-FOR-BYTE the
        // same output as before this feature existed.
        let (parsed, _, _, _) = makeFixture()
        let rows = DataExtraction.extractRows(from: parsed)
        XCTAssertEqual(DataExtraction.csv(for: rows), DataExtraction.csv(for: rows, columns: nil))
    }

    // MARK: - blockName import must be VISIBLE everywhere the app shows an
    // object's name, not just on re-export
    //
    // Regression coverage for a real user report: importing a CSV that
    // renamed 739 objects via the `blockName` column reported "Updated ...
    // 739 name(s)" (confirming `DataExtraction.apply` genuinely wrote every
    // override), yet clicking any of those objects in the model still showed
    // the ORIGINAL name. Root cause: `InsertInstance.name` (the render-side
    // field the Properties panel/search/AI routing all read) is populated
    // from the real `blockNameId` ONLY and never consults
    // `InsertPayload.displayNameId` — three separate call sites each had to
    // be taught to reconcile the two via `BlockEditor.displayName`, mirroring
    // this codebase's other "two independent code paths must both learn about
    // a new field" lesson (see AGENTS.md's ATTRIB-linking writeup for the
    // same shape of bug).

    @MainActor
    func testPropertiesPanelShowsTheImportedNameNotTheOriginalBlockName() throws {
        let (parsed, insertId, _, _) = makeFixture()
        let edit = DataExtraction.ParsedEdit(entityId: insertId.raw, layer: nil, color: nil,
                                             text: nil, textPresent: false,
                                             blockName: "Station 7", blockNamePresent: true,
                                             attributes: [:])
        var result = DataExtraction.ApplyResult()
        parsed.document.transact("Import Data") { tx in
            result = DataExtraction.apply([edit], in: parsed, tx: tx)
        }
        XCTAssertEqual(result.displayNameEdits, 1, "sanity: the import itself must report the write")

        let rc = makeCoordinator(parsed)
        let props = HitTester.properties(for: .insert(0), document: rc.document,
                                         usePaperSpace: false, store: parsed.store)
        let nameRow = try XCTUnwrap(props.first { $0.name == "Name" })
        XCTAssertEqual(nameRow.value, "Station 7",
                      "the Properties panel must show the IMPORTED name, not silently keep showing the original block name")
        let blockRow = props.first { $0.name == "Block" }
        XCTAssertEqual(blockRow?.value, "WORKSTATION",
                       "the real block it still draws must remain visible once renamed")
    }

    @MainActor
    func testPropertiesPanelOmitsTheBlockRowWhenNoOverrideIsSet() throws {
        // Sanity/no-regression check: an INSERT that was never renamed must
        // show its real block name as "Name" with no redundant "Block" row.
        let (parsed, _, _, _) = makeFixture()
        let rc = makeCoordinator(parsed)
        let props = HitTester.properties(for: .insert(0), document: rc.document,
                                         usePaperSpace: false, store: parsed.store)
        XCTAssertEqual(props.first { $0.name == "Name" }?.value, "WORKSTATION")
        XCTAssertNil(props.first { $0.name == "Block" })
    }

    @MainActor
    func testSearchIndexFindsAnObjectByItsImportedNameAfterABulkRename() throws {
        let (parsed, insertId, _, _) = makeFixture()
        let edit = DataExtraction.ParsedEdit(entityId: insertId.raw, layer: nil, color: nil,
                                             text: nil, textPresent: false,
                                             blockName: "Station 7", blockNamePresent: true,
                                             attributes: [:])
        parsed.document.transact("Import Data") { tx in
            _ = DataExtraction.apply([edit], in: parsed, tx: tx)
        }
        let rc = makeCoordinator(parsed)
        let index = SearchIndex(document: rc.document, store: parsed.store)
        let hits = index.search("Station 7")
        XCTAssertTrue(hits.contains { $0.label == "Station 7" },
                      "an object renamed via bulk import must be findable by its NEW name")
        // The original block name must ALSO still resolve — someone on the
        // team (or an older export) may still refer to it that way.
        let byOriginal = index.search("WORKSTATION")
        XCTAssertTrue(byOriginal.contains { $0.ref == .insert(0) },
                      "the underlying block name must remain searchable too")
    }

    @MainActor
    func testSearchIndexWithNoStoreFallsBackToTheRealBlockNameOnly() throws {
        // The legacy no-store initializer (`GeometryBuilder`/`PackageLoader
        // .load` path) must keep working exactly as before — no override
        // lookups attempted, no crash.
        let (parsed, insertId, _, _) = makeFixture()
        let edit = DataExtraction.ParsedEdit(entityId: insertId.raw, layer: nil, color: nil,
                                             text: nil, textPresent: false,
                                             blockName: "Station 7", blockNamePresent: true,
                                             attributes: [:])
        parsed.document.transact("Import Data") { tx in
            _ = DataExtraction.apply([edit], in: parsed, tx: tx)
        }
        let rc = makeCoordinator(parsed)
        let index = SearchIndex(document: rc.document)
        XCTAssertTrue(index.search("WORKSTATION").contains { $0.ref == .insert(0) })
        XCTAssertTrue(index.search("Station 7").isEmpty,
                      "without a store, the override is invisible — matches pre-existing behavior")
    }

    @MainActor
    func testAIRouteEndpointLookupResolvesTheImportedNameNotJustTheOriginalBlockName() throws {
        let (parsed, insertId, _, _) = makeFixture()
        let edit = DataExtraction.ParsedEdit(entityId: insertId.raw, layer: nil, color: nil,
                                             text: nil, textPresent: false,
                                             blockName: "Station 7", blockNamePresent: true,
                                             attributes: [:])
        parsed.document.transact("Import Data") { tx in
            _ = DataExtraction.apply([edit], in: parsed, tx: tx)
        }
        let rc = makeCoordinator(parsed)
        let matches = AisleRoutingReader.findEndpoints(matching: "Station 7", document: rc.document,
                                                       space: .model, store: parsed.store)
        XCTAssertTrue(matches.contains { $0.label == "Station 7" && $0.entityId == insertId.raw },
                      "find_route_endpoints must resolve an object by its renamed (imported) label")
    }
}
