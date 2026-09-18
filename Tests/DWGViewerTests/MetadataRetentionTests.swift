import XCTest
@testable import DWGViewer
import CADCore

/// Phase 3 groundwork: verifies HEADER/CLASSES/TABLES(beyond LAYER,LTYPE)/
/// OBJECTS retention added to `EntityStoreParser`/`EditableParsedDocument`
/// (see DXFMetadataModel.swift). These are round-trip-of-RETAINED-DATA
/// tests, not full file-to-file round trips — there is no DXF writer yet
/// (that's later, separate work); this only proves the in-memory model
/// faithfully captures what `Tests/Fixtures/full_metadata.dxf` contains,
/// verified by hand-inspection of that fixture's own raw group codes.
final class MetadataRetentionTests: XCTestCase {

    private func parseFixture() throws -> EditableParsedDocument {
        try EntityStoreParser.parse(url: TestFixtures.url("full_metadata.dxf"))
    }

    // MARK: - HEADER

    func testHeaderVarsCaptureOrderAndCount() throws {
        let parsed = try parseFixture()
        let names = parsed.headerVars.vars.map(\.name)
        // File order must be preserved exactly.
        XCTAssertEqual(names, [
            "$ACADVER", "$INSUNITS", "$LTSCALE", "$MEASUREMENT", "$ANGBASE",
            "$ANGDIR", "$CELTSCALE", "$PDMODE", "$PDSIZE", "$MIRRTEXT",
            "$TILEMODE", "$EXTMIN", "$EXTMAX", "$HANDSEED", "$CLAYER",
        ])
    }

    func testHeaderStringVarRawValue() throws {
        let parsed = try parseFixture()
        XCTAssertEqual(parsed.headerVars.stringValue("$ACADVER"), "AC1015")
        XCTAssertEqual(parsed.headerVars.acadver, "AC1015")
    }

    func testHeaderIntVarRawValue() throws {
        let parsed = try parseFixture()
        XCTAssertEqual(parsed.headerVars.intValue("$INSUNITS"), 4)
        XCTAssertEqual(parsed.headerVars.insunits, 4)
        XCTAssertEqual(parsed.headerVars.measurement, 1)
        XCTAssertEqual(parsed.headerVars.pdmode, 3)
        XCTAssertEqual(parsed.headerVars.mirrtext, 0)
        XCTAssertEqual(parsed.headerVars.tilemode, 1)
    }

    func testHeaderDoubleVarRawValue() throws {
        let parsed = try parseFixture()
        XCTAssertEqual(parsed.headerVars.ltscale, 1.0)
        XCTAssertEqual(parsed.headerVars.celtscale, 1.0)
        XCTAssertEqual(parsed.headerVars.pdsize, 2.5)
        XCTAssertEqual(parsed.headerVars.angbase, 0.0)
    }

    func testHeaderPointVarRawValue() throws {
        let parsed = try parseFixture()
        let extmin = try XCTUnwrap(parsed.headerVars.extmin)
        XCTAssertEqual(extmin.x, -5.5)
        XCTAssertEqual(extmin.y, -6.5)
        XCTAssertEqual(extmin.z, 0.0)
        let extmax = try XCTUnwrap(parsed.headerVars.extmax)
        XCTAssertEqual(extmax.x, 105.5)
        XCTAssertEqual(extmax.y, 205.5)
    }

    func testHeaderHandleVarRawValue() throws {
        let parsed = try parseFixture()
        // $HANDSEED is written as a bare handle-string (code 5) in the
        // fixture, matching real AutoCAD output.
        XCTAssertEqual(parsed.headerVars.handseed, "2000")
    }

    func testHeaderVarNotPresentReturnsNil() throws {
        let parsed = try parseFixture()
        XCTAssertNil(parsed.headerVars.variable("$DOESNOTEXIST"))
        XCTAssertNil(parsed.headerVars.doubleValue("$DOESNOTEXIST"))
    }

    /// Existing `$LTSCALE`/`$INSUNITS` fast-path fields on
    /// `EditableParsedDocument` must keep working unchanged (no duplicate/
    /// conflicting logic introduced by the new generic capture).
    func testExistingLtScaleAndInsUnitsFastPathsUnaffected() throws {
        let parsed = try parseFixture()
        XCTAssertEqual(parsed.ltScale, 1.0)
        XCTAssertEqual(parsed.insUnits, 4)
    }

    func testHeaderVarCaseAndDollarInsensitiveLookup() throws {
        let parsed = try parseFixture()
        XCTAssertEqual(parsed.headerVars.stringValue("acadver"), "AC1015")
        XCTAssertEqual(parsed.headerVars.stringValue("ACADVER"), "AC1015")
        XCTAssertEqual(parsed.headerVars.stringValue("$acadver"), "AC1015")
    }

    // MARK: - CLASSES

    func testClassesCapturedVerbatimInOrder() throws {
        let parsed = try parseFixture()
        XCTAssertEqual(parsed.classes.count, 2)
        XCTAssertEqual(parsed.classes[0].recordType, "CLASS")
        // Group 1 (the class DXF record name) is the first pair.
        guard case .string(let first0) = parsed.classes[0].pairs.first(where: { $0.code == 1 })?.value else {
            return XCTFail("expected code-1 string pair")
        }
        XCTAssertEqual(first0, "ACDBDICTIONARYWDFLT")
        guard case .string(let first1) = parsed.classes[1].pairs.first(where: { $0.code == 1 })?.value else {
            return XCTFail("expected code-1 string pair")
        }
        XCTAssertEqual(first1, "SORTENTSTABLE")
        // Every code from the fixture's CLASS records must round-trip,
        // including the int-typed 90/91/280/281 codes.
        func intValue(_ pairs: [RawGroupPair], _ code: Int32) -> Int64? {
            for p in pairs where p.code == code {
                if case .int(let i) = p.value { return i }
            }
            return nil
        }
        XCTAssertEqual(intValue(parsed.classes[0].pairs, 91), 1)
        XCTAssertEqual(intValue(parsed.classes[1].pairs, 91), 2)
    }

    // MARK: - TABLES (VPORT/STYLE/APPID/DIMSTYLE)

    func testVportRecordCapturedWithHandleOwnerNameAndRawPairs() throws {
        let parsed = try parseFixture()
        let vports = parsed.symbolTables["VPORT"] ?? []
        XCTAssertEqual(vports.count, 1)
        let v = try XCTUnwrap(vports.first)
        XCTAssertEqual(v.tableType, "VPORT")
        XCTAssertEqual(v.name, "*ACTIVE")
        XCTAssertEqual(v.handle, 0x31)
        XCTAssertEqual(v.ownerHandle, 0x30)
        // Raw pairs retain the view-center (12/22) and height (40) verbatim.
        func doubleValue(_ code: Int32) -> Double? {
            for p in v.rawPairs where p.code == code {
                if case .double(let d) = p.value { return d }
            }
            return nil
        }
        XCTAssertEqual(doubleValue(12), 50.0)
        XCTAssertEqual(doubleValue(40), 100.0)
    }

    func testStyleRecordCapturesFontAndBigFontTypedLift() throws {
        let parsed = try parseFixture()
        let styles = parsed.symbolTables["STYLE"] ?? []
        let standard = try XCTUnwrap(styles.first { $0.name == "STANDARD" })
        XCTAssertEqual(standard.handle, 0x41)
        XCTAssertEqual(standard.ownerHandle, 0x40)
        guard case .style(let font, let bigFont) = standard.typed else {
            return XCTFail("expected .style typed lift")
        }
        XCTAssertEqual(font, "txt.shx")
        XCTAssertEqual(bigFont, "")
    }

    func testAppidRecordCaptured() throws {
        let parsed = try parseFixture()
        let appids = parsed.symbolTables["APPID"] ?? []
        let acad = try XCTUnwrap(appids.first { $0.name == "ACAD" })
        XCTAssertEqual(acad.handle, 0x51)
        XCTAssertEqual(acad.ownerHandle, 0x50)
    }

    func testDimstyleRecordUsesGroup105ForHandleAndCapturesOverrides() throws {
        let parsed = try parseFixture()
        let dimstyles = parsed.symbolTables["DIMSTYLE"] ?? []
        let standard = try XCTUnwrap(dimstyles.first { $0.name == "STANDARD" })
        // DIMSTYLE is the one table type keying its handle off group 105,
        // not 5 — this assertion is the whole point of this test.
        XCTAssertEqual(standard.handle, 0x61)
        XCTAssertEqual(standard.ownerHandle, 0x60)
        guard case .dimstyle(let overrides) = standard.typed else {
            return XCTFail("expected .dimstyle typed lift")
        }
        func doubleValue(_ code: Int32) -> Double? {
            for p in overrides where p.code == code {
                if case .double(let d) = p.value { return d }
            }
            return nil
        }
        XCTAssertEqual(doubleValue(41), 0.18)
        XCTAssertEqual(doubleValue(147), 0.625)
        // Overrides must not duplicate the already-lifted handle/owner/name
        // codes, but rawPairs must still have them for full echo.
        XCTAssertFalse(overrides.contains { $0.code == 105 })
        XCTAssertTrue(standard.rawPairs.contains { $0.code == 105 })
    }

    func testLayerAndLtypeStillGoThroughOldPathUnaffected() throws {
        // LAYER/LTYPE must NOT appear in symbolTables — they stay exclusively
        // in `layers`/`linetypes` (render-facing, untouched by this phase).
        let parsed = try parseFixture()
        XCTAssertNil(parsed.symbolTables["LAYER"])
        XCTAssertNil(parsed.symbolTables["LTYPE"])
        XCTAssertEqual(parsed.layers.map(\.name), ["0"])
    }

    // MARK: - OBJECTS

    func testRootDictionaryFoundWithExpectedEntries() throws {
        let parsed = try parseFixture()
        let rootHandle = try XCTUnwrap(parsed.objects.rootDictionaryHandle)
        XCTAssertEqual(rootHandle, 0xC)
        let root = try XCTUnwrap(parsed.objects.dictionaries[rootHandle])
        XCTAssertEqual(root.ownerHandle, 0)
        XCTAssertEqual(root.hardOwnerFlag, 1)
        XCTAssertEqual(root.entries.map(\.key), ["ACAD_GROUP", "ACAD_LAYOUT", "ACAD_PLOTSETTINGS"])
        XCTAssertEqual(root.entries.first { $0.key == "ACAD_LAYOUT" }?.valueHandle, 0x1A)
    }

    func testAcadLayoutDictionaryEntryResolvesToTypedLayoutObject() throws {
        let parsed = try parseFixture()
        // Walk root -> ACAD_LAYOUT -> "Layout1" -> LAYOUT object, exactly the
        // graph traversal a later phase would perform.
        let root = try XCTUnwrap(parsed.objects.dictionaries[parsed.objects.rootDictionaryHandle!])
        let layoutDictHandle = try XCTUnwrap(root.entries.first { $0.key == "ACAD_LAYOUT" }?.valueHandle)
        let layoutDict = try XCTUnwrap(parsed.objects.dictionaries[layoutDictHandle])
        let layout1Handle = try XCTUnwrap(layoutDict.entries.first { $0.key == "Layout1" }?.valueHandle)
        let layout = try XCTUnwrap(parsed.objects.layouts[layout1Handle])
        XCTAssertEqual(layout.name, "Layout1")
        XCTAssertEqual(layout.handle, 0x1B)
        // Common-property owner (the ACAD_LAYOUT dictionary, 0x1A) must be
        // distinguished from the AcDbLayout-subclass block-record pointer
        // (0x70) even though the source file spells both as group 330 —
        // see EntityStoreParser.handleAndOwner's doc comment for why a naive
        // "first/any 330" scan would get this wrong on real AutoCAD output.
        XCTAssertEqual(layout.ownerHandle, 0x1A)
        XCTAssertEqual(layout.blockRecordHandle, 0x70)
        XCTAssertEqual(layout.tabOrder, 1)
    }

    func testAcadGroupDictionaryEntryResolvesToTypedGroupObject() throws {
        let parsed = try parseFixture()
        let root = try XCTUnwrap(parsed.objects.dictionaries[parsed.objects.rootDictionaryHandle!])
        let groupDictHandle = try XCTUnwrap(root.entries.first { $0.key == "ACAD_GROUP" }?.valueHandle)
        let groupDict = try XCTUnwrap(parsed.objects.dictionaries[groupDictHandle])
        let group1Handle = try XCTUnwrap(groupDict.entries.first { $0.key == "GROUP1" }?.valueHandle)
        let group = try XCTUnwrap(parsed.objects.groups[group1Handle])
        XCTAssertEqual(group.description, "Sample group description")
        XCTAssertTrue(group.isSelectable)
        XCTAssertEqual(group.memberHandles, [0x100])
    }

    /// The fixture's XRECORD has no typed lift built for it — proving the
    /// "nothing from OBJECTS is silently dropped" guarantee: it must still
    /// surface as a RawObject with its handle and every group code intact.
    func testUntypedObjectRoundTripsAsRawObjectWithHandleAndPairsIntact() throws {
        let parsed = try parseFixture()
        let xrecord = try XCTUnwrap(parsed.objects.rawObjects[0x99])
        XCTAssertEqual(xrecord.objectType, "XRECORD")
        XCTAssertEqual(xrecord.ownerHandle, 0xD)
        func stringValue(_ code: Int32) -> String? {
            for p in xrecord.rawPairs where p.code == code {
                if case .string(let s) = p.value { return s }
            }
            return nil
        }
        func doubleValue(_ code: Int32) -> Double? {
            for p in xrecord.rawPairs where p.code == code {
                if case .double(let d) = p.value { return d }
            }
            return nil
        }
        XCTAssertEqual(stringValue(1), "CustomVendorData")
        XCTAssertEqual(doubleValue(40), 3.14159)
    }

    func testObjectsModelCountsForOverview() throws {
        let parsed = try parseFixture()
        // 3 dictionaries (root, ACAD_GROUP's, ACAD_LAYOUT's) + 1 group +
        // 1 layout + 1 raw (XRECORD) = 6 objects total, 5 typed.
        XCTAssertEqual(parsed.objects.totalObjectCount, 6)
        XCTAssertEqual(parsed.objects.typedObjectCount, 5)
        XCTAssertFalse(parsed.objects.isEmpty)
    }

    // MARK: - Handles on LAYER/LTYPE/BLOCK (item 5: previously handle-less structs)

    func testLayerRecordRetainsOriginalHandle() throws {
        let parsed = try parseFixture()
        let layer0 = try XCTUnwrap(parsed.layers.first { $0.name == "0" })
        XCTAssertEqual(layer0.handle, 0x20)
    }

    func testLtypeRecordRetainsOriginalHandle() throws {
        let parsed = try parseFixture()
        let dashed = try XCTUnwrap(parsed.linetypes.first { $0.name == "DASHED" })
        XCTAssertEqual(dashed.handle, 0x21)
    }

    /// Pre-existing behavior (identical in the OLD `DXFParser` path too, not
    /// introduced by this phase): CONTINUOUS is synthesized at index 0
    /// before any real LTYPE record is parsed, and `flushLtypeRecord`'s
    /// dedup guard (`out.linetypeIdByName[upper] == nil`) skips applying a
    /// same-named record's fields once a name is already registered — so a
    /// real file's own CONTINUOUS record's handle (and dash list, and
    /// anything else about it) is UNREACHABLE, always overridden by the
    /// synthetic bootstrap. Documented here as a known, deliberate
    /// out-of-scope limitation rather than silently worked around — fixing
    /// the dedup guard's behavior is a change to existing parser logic this
    /// phase does not touch (retention-only scope).
    func testContinuousLinetypeHandleIsUnreachableDueToPreExistingBootstrapDedup() throws {
        let parsed = try parseFixture()
        let continuous = try XCTUnwrap(parsed.linetypes.first { $0.name == "CONTINUOUS" })
        XCTAssertEqual(continuous.handle, 0,
            "known limitation: the synthetic bootstrap linetype always wins over a real CONTINUOUS LTYPE record")
    }

    func testBlockRetainsOwnHandleAndCrossReferencedBlockRecordHandle() throws {
        let parsed = try parseFixture()
        let block = try XCTUnwrap(parsed.blocks["$MODEL_SPACE"])
        XCTAssertEqual(block.handle, 0x90)
        // Cross-referenced by name against the BLOCK_RECORD table parsed
        // earlier in file order (TABLES precedes BLOCKS in every DXF) —
        // this is the "handle -> ..." lookup a later writer needs to
        // reconnect a block definition to its BLOCK_RECORD table entry.
        XCTAssertEqual(block.blockRecordHandle, 0x81)
    }

    func testBlockRecordTableEntryItselfCapturedWithOwnerAndTypedLayoutLift() throws {
        let parsed = try parseFixture()
        let blockRecords = parsed.symbolTables["BLOCK_RECORD"] ?? []
        let rec = try XCTUnwrap(blockRecords.first { $0.name == "$MODEL_SPACE" })
        XCTAssertEqual(rec.handle, 0x81)
        XCTAssertEqual(rec.ownerHandle, 0x80)
        // No 340 (layout-handle) code on this fixture's BLOCK_RECORD, so
        // the typed lift must report nil rather than a bogus 0.
        guard case .blockRecord(let layoutHandle) = rec.typed else {
            return XCTFail("expected .blockRecord typed lift")
        }
        XCTAssertNil(layoutHandle)
    }

    /// A layer/linetype the parser SYNTHESIZES itself (not backed by any
    /// real LAYER/LTYPE record in the file) must not carry a bogus nonzero
    /// handle — e.g. a fixture with no explicit LTYPE table still gets a
    /// synthetic CONTINUOUS/BYLAYER/BYBLOCK bootstrap; the full_metadata
    /// fixture DOES define CONTINUOUS explicitly (tested above), so this
    /// checks the synthesized-only case using a fixture that has no LTYPE
    /// table of its own.
    func testSyntheticLinetypesHaveZeroHandleWhenFixtureHasNoLtypeTable() throws {
        let parsed = try EntityStoreParser.parse(url: TestFixtures.url("basic_entities.dxf"))
        let continuous = try XCTUnwrap(parsed.linetypes.first { $0.name == "CONTINUOUS" })
        XCTAssertEqual(continuous.handle, 0, "basic_entities.dxf defines no LTYPE table, so CONTINUOUS is synthesized with no handle")
    }

    // MARK: - Adversarial-review regressions

    /// A hand-edited/corrupted file can contain non-finite numeric text
    /// ("1e400") in an int-classified group code — `$MEASUREMENT` (group 70)
    /// here. `parseNum` returns `Double.infinity` for this via `strtod`, and
    /// a bare `Int64(Double)` conversion TRAPS (Swift fatal error, process
    /// abort) on non-finite input. This previously crashed the entire parse;
    /// `safeInt64` must clamp instead. Regression test for a bug an
    /// adversarial review found and reproduced against this exact scenario.
    func testMalformedNonFiniteHeaderValueDoesNotCrashParse() throws {
        let parsed = try EntityStoreParser.parse(url: TestFixtures.url("malformed_numeric.dxf"))
        // Must not trap; the clamped value (0, since infinity is out of
        // range) is what matters far less than "the process is still alive."
        XCTAssertEqual(parsed.headerVars.intValue("$MEASUREMENT"), 0)
    }

    /// OBJECTS records are stored in `[UInt64: T]` dictionaries keyed by
    /// handle, but handle 0 means "absent" (see `handleAndOwner`) — so two
    /// handle-less records of the same type used to collide at key 0 and
    /// silently lose all but the last one, violating the "nothing from
    /// OBJECTS is silently dropped" guarantee. Regression test for a bug an
    /// adversarial review found: both handle-less DICTIONARY objects in the
    /// fixture must survive under distinct (synthesized) storage keys.
    func testHandlelessObjectsOfTheSameTypeDoNotCollideAndBothSurvive() throws {
        let parsed = try EntityStoreParser.parse(url: TestFixtures.url("objects_handleless_collision.dxf"))
        XCTAssertEqual(parsed.objects.dictionaries.count, 2,
                       "both handle-less DICTIONARY objects must be retained under distinct keys, not collide at key 0")
        // Both source dictionaries' own reported `handle` field stays 0
        // (faithfully echoing "the file had none") even though each is
        // stored under a distinct synthetic key — the storage key is an
        // implementation detail, not part of the retained data.
        XCTAssertTrue(parsed.objects.dictionaries.values.allSatisfy { $0.handle == 0 })
        // The two dictionaries are distinguishable by their own content
        // (each has exactly one entry, with a different key) — proving
        // neither one silently overwrote the other.
        let entryKeys = Set(parsed.objects.dictionaries.values.compactMap { $0.entries.first?.key })
        XCTAssertEqual(entryKeys, ["FIRST_HANDLELESS", "SECOND_HANDLELESS"])
    }

    /// A CLASSES-section record whose type isn't "CLASS" (unreachable in a
    /// well-formed AutoCAD file, but this capture is meant to survive
    /// malformed/nonstandard files without silently losing data) must at
    /// least be counted in `skippedTypes` — the same fallback-accounting
    /// ENTITIES already uses for unrecognized types — rather than vanishing
    /// with zero accounting. Regression test for a gap an adversarial
    /// review found: CLASSES had no raw/fallback capture at all, unlike
    /// OBJECTS (RawObject) and ENTITIES (skippedTypes).
    func testUnexpectedClassesRecordTypeIsCountedNotSilentlyDropped() throws {
        // full_metadata.dxf's CLASSES section holds only well-formed CLASS
        // records, so this is a targeted check that the fallback path
        // exists and is wired to `skippedTypes` — exercised via a tiny
        // inline fixture rather than a new file, since it's a one-record
        // check. Unreachable in a well-formed AutoCAD file, but this
        // capture is meant to survive malformed/nonstandard files without
        // silently losing data.
        let data = "  0\nSECTION\n  2\nCLASSES\n  0\nNOTACLASS\n  1\nSomeValue\n  0\n"
            + "ENDSEC\n  0\nSECTION\n  2\nENTITIES\n  0\nENDSEC\n  0\nEOF\n"
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("classes-fallback-\(UUID().uuidString).dxf")
        try data.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let parsed = try EntityStoreParser.parse(url: tmp)
        XCTAssertEqual(parsed.skippedTypes["CLASSES:NOTACLASS"], 1)
    }
}
