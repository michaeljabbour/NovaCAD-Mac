import XCTest
@testable import DWGViewer
import CADCore
import CoreGraphics

/// Tests for editable BLOCK REFERENCE properties — the typed-entry path
/// behind "edit block attributes ... including the 'Name', and manually typing
/// the position x, position y, rotation, etc."
///
/// Split into two halves, both of which matter:
///
/// 1. `UnitInput` parsing — the layer that decides whether what the user typed
///    is a number at all. Getting this wrong either silently refuses valid
///    input (the field appears broken) or commits a nonsense coordinate that
///    teleports a block somewhere off-drawing.
/// 2. The actual store mutations (payload edits + attribute writes), asserted
///    through real `Transaction`s so undo grouping is covered too.
final class BlockPropertiesEditorTests: XCTestCase {

    // MARK: - Plain number parsing

    func testParseNumberAcceptsPlainDecimalsAndNegatives() {
        XCTAssertEqual(UnitInput.parseNumber("90"), 90)
        XCTAssertEqual(UnitInput.parseNumber("-12.5"), -12.5)
        XCTAssertEqual(UnitInput.parseNumber("0"), 0)
        XCTAssertEqual(UnitInput.parseNumber("  42.25  "), 42.25, "surrounding whitespace must be tolerated")
    }

    func testParseNumberAcceptsItsOwnDisplayedFormatting() {
        // The rotation field displays a degree sign; pasting that same string
        // back in must work rather than being rejected as unparseable.
        XCTAssertEqual(UnitInput.parseNumber("90\u{00B0}"), 90)
        XCTAssertEqual(UnitInput.parseNumber("45 deg"), 45)
        XCTAssertEqual(UnitInput.parseNumber("1,250.5"), 1250.5, "thousands separators must be tolerated")
    }

    func testParseNumberRejectsIncompleteOrJunkInput() {
        // These are exactly the intermediate states a per-keystroke binding
        // would have committed — each must be refused, not coerced to 0.
        XCTAssertNil(UnitInput.parseNumber(""))
        XCTAssertNil(UnitInput.parseNumber("-"))
        XCTAssertNil(UnitInput.parseNumber("   "))
        XCTAssertNil(UnitInput.parseNumber("abc"))
        XCTAssertNil(UnitInput.parseNumber("12abc"))
    }

    func testPlainNumberFormattingTrimsPointlessDecimals() {
        XCTAssertEqual(UnitInput.plainNumber(90), "90", "a whole number must not display as 90.000000")
        XCTAssertEqual(UnitInput.plainNumber(-1), "-1")
        XCTAssertEqual(UnitInput.plainNumber(1.5), "1.5", "real precision must survive")
    }

    // MARK: - Fraction / mixed-number parsing

    func testParseFractionHandlesDecimalsBareFractionsAndMixedNumbers() {
        XCTAssertEqual(UnitInput.parseFraction("6"), 6)
        XCTAssertEqual(UnitInput.parseFraction("6.5"), 6.5)
        XCTAssertEqual(try XCTUnwrap(UnitInput.parseFraction("1/2")), 0.5, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(UnitInput.parseFraction("6 1/2")), 6.5, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(UnitInput.parseFraction("-6 1/2")), -6.5, accuracy: 1e-12,
                       "the sign must apply to the WHOLE mixed number, not just its integer part")
    }

    func testParseFractionRejectsDivisionByZeroAndJunk() {
        XCTAssertNil(UnitInput.parseFraction("1/0"))
        XCTAssertNil(UnitInput.parseFraction("1/2/3"))
        XCTAssertNil(UnitInput.parseFraction(""))
    }

    // MARK: - Length parsing (unit-aware)

    private func inchFormat() -> MeasureFormat {
        MeasureFormat(system: .imperial, style: .architectural, precision: 4, insUnits: 1)
    }

    func testParseLengthAcceptsAPlainNumberAsDrawingUnits() {
        let f = inchFormat()
        XCTAssertEqual(try XCTUnwrap(UnitInput.parseLength("150", format: f)), 150, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(UnitInput.parseLength("1,250.5", format: f)), 1250.5, accuracy: 1e-9)
    }

    func testParseLengthAcceptsFeetInchesForms() throws {
        // Drawing units ARE inches here, so 12'-6" == 150 units.
        let f = inchFormat()
        XCTAssertEqual(try XCTUnwrap(UnitInput.parseLength("12'-6\"", format: f)), 150, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(UnitInput.parseLength("12' 6\"", format: f)), 150, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(UnitInput.parseLength("12'", format: f)), 144, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(UnitInput.parseLength("6\"", format: f)), 6, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(UnitInput.parseLength("12'-6 1/2\"", format: f)), 150.5, accuracy: 1e-9)
    }

    func testParseLengthConvertsThroughInsUnits() throws {
        // Drawing units are FEET: 12'-6" is 12.5 units, not 150.
        let feet = MeasureFormat(system: .imperial, style: .architectural, precision: 4, insUnits: 2)
        XCTAssertEqual(try XCTUnwrap(UnitInput.parseLength("12'-6\"", format: feet)), 12.5, accuracy: 1e-9)
        // Drawing units are MILLIMETRES: 1" is 25.4 units.
        let mm = MeasureFormat(system: .metric, style: .decimal, precision: 2, insUnits: 4)
        XCTAssertEqual(try XCTUnwrap(UnitInput.parseLength("1\"", format: mm)), 25.4, accuracy: 1e-6)
    }

    func testUnknownInsUnitsIsTreatedAsInchesRatherThanScalingWildly() {
        // Mirrors CADCore's own fallback. A drawing that declares no units
        // must round-trip 1:1 instead of silently scaling by some default.
        let unknown = MeasureFormat(system: .imperial, style: .architectural, precision: 4, insUnits: 0)
        XCTAssertEqual(UnitInput.inchesPerUnit(unknown), 1, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(UnitInput.parseLength("12'", format: unknown)), 144, accuracy: 1e-9)
    }

    /// The invariant that keeps `UnitInput.inchesPerUnit`'s locally-duplicated
    /// unit table honest against CADCore's private one: whatever
    /// `MeasureFormat.length` PRINTS must parse back to the value it came
    /// from. If the two tables ever drift, this fails.
    func testLengthDisplayRoundTripsBackThroughTheParser() throws {
        let formats = [
            MeasureFormat(system: .imperial, style: .architectural, precision: 4, insUnits: 1),
            MeasureFormat(system: .imperial, style: .architectural, precision: 4, insUnits: 2),
            MeasureFormat(system: .imperial, style: .engineering, precision: 3, insUnits: 1),
        ]
        for f in formats {
            for value in [0.0, 6.0, 12.0, 144.0, 150.5, 1234.0] {
                let shown = f.length(CGFloat(value))
                let parsed = try XCTUnwrap(UnitInput.parseLength(shown, format: f),
                                          "\"\(shown)\" (from \(value), insUnits \(f.insUnits)) must parse back")
                XCTAssertEqual(parsed, value, accuracy: 0.02,
                               "round trip drifted for \(value) shown as \"\(shown)\" (insUnits \(f.insUnits))")
            }
        }
    }

    func testParseLengthRejectsIncompleteInput() {
        let f = inchFormat()
        XCTAssertNil(UnitInput.parseLength("", format: f))
        XCTAssertNil(UnitInput.parseLength("-", format: f))
        XCTAssertNil(UnitInput.parseLength("ft", format: f))
        XCTAssertNil(UnitInput.parseLength("abc'", format: f))
    }

    // MARK: - Real store edits

    private func makeParsedWithInsert() -> (EditableParsedDocument, EntityID) {
        let parsed = EditableParsedDocument()
        parsed.layers.append(DXFLayer(id: 0, name: "0"))
        parsed.layerIdByName["0"] = 0
        let store = parsed.store
        let nameId = store.strings.intern("WORKSTATION")
        let id = store.append(EntityPrototype(
            type: .insert, layerId: 0, owner: .model,
            payload: .insert(InsertPayload(blockNameId: nameId,
                                           position: Vec3(x: 10, y: 20),
                                           scale: Vec3(x: 1, y: 1, z: 1),
                                           rotationDeg: 0))))
        return (parsed, id)
    }

    private func insertPayload(_ parsed: EditableParsedDocument, _ id: EntityID) throws -> InsertPayload {
        let h = try XCTUnwrap(parsed.store.header(id))
        return parsed.store.inserts[Int(h.payload)]
    }

    func testTypingAPositionMovesTheBlockExactly() throws {
        let (parsed, id) = makeParsedWithInsert()
        parsed.document.transact("Change Position X") { tx in
            tx.modifyPayload(id) { copy in
                guard case .insert(var p) = copy else { return }
                p.position.x = 250
                copy = .insert(p)
            }
        }
        let p = try insertPayload(parsed, id)
        XCTAssertEqual(p.position.x, 250, accuracy: 1e-9)
        XCTAssertEqual(p.position.y, 20, accuracy: 1e-9, "editing X must not disturb Y")
    }

    func testTypingARotationIsUndoableAsOneStep() throws {
        let (parsed, id) = makeParsedWithInsert()
        let before = parsed.document.undoStack.count
        parsed.document.transact("Change Rotation") { tx in
            tx.modifyPayload(id) { copy in
                guard case .insert(var p) = copy else { return }
                p.rotationDeg = 90
                copy = .insert(p)
            }
        }
        XCTAssertEqual(parsed.document.undoStack.count, before + 1,
                       "one committed field edit must be exactly one undo step")
        XCTAssertEqual(try insertPayload(parsed, id).rotationDeg, 90, accuracy: 1e-9)
        parsed.document.undo()
        XCTAssertEqual(try insertPayload(parsed, id).rotationDeg, 0, accuracy: 1e-9)
    }

    func testRetargetingTheBlockNameChangesWhichDefinitionIsDrawn() throws {
        let (parsed, id) = makeParsedWithInsert()
        let newNameId = parsed.store.strings.intern("PALLET")
        parsed.document.transact("Change Block") { tx in
            tx.modifyPayload(id) { copy in
                guard case .insert(var p) = copy else { return }
                p.blockNameId = newNameId
                copy = .insert(p)
            }
        }
        let p = try insertPayload(parsed, id)
        XCTAssertEqual(parsed.store.strings.string(for: p.blockNameId), "PALLET")
        XCTAssertEqual(p.displayNameId, -1,
                       "retargeting the real block must not invent a cosmetic display-name override")
    }

    func testDisplayNameOverrideDoesNotChangeTheDrawnBlock() throws {
        let (parsed, id) = makeParsedWithInsert()
        parsed.document.transact("Rename Object") { tx in
            _ = BlockEditor.setDisplayName(id, to: "STN-4", in: parsed, tx: tx)
        }
        let p = try insertPayload(parsed, id)
        XCTAssertEqual(BlockEditor.displayName(of: id, in: parsed.store), "STN-4")
        XCTAssertEqual(parsed.store.strings.string(for: p.blockNameId), "WORKSTATION",
                       "the cosmetic label must never retarget the geometry")
    }

    func testClearingTheDisplayNameFallsBackToTheRealBlockName() throws {
        let (parsed, id) = makeParsedWithInsert()
        parsed.document.transact("Rename") { tx in
            _ = BlockEditor.setDisplayName(id, to: "STN-4", in: parsed, tx: tx)
        }
        parsed.document.transact("Clear") { tx in
            _ = BlockEditor.setDisplayName(id, to: "", in: parsed, tx: tx)
        }
        XCTAssertEqual(try insertPayload(parsed, id).displayNameId, -1)
        XCTAssertEqual(BlockEditor.displayName(of: id, in: parsed.store), "WORKSTATION")
    }

    // MARK: - Attribute editing from the panel

    /// Adds an ATTRIB child to `insertId`, the way a real parsed drawing links
    /// them (owner `.parentEntity`) — see AGENTS.md on that invariant.
    private func appendAttrib(to insertId: EntityID, tag: String, value: String,
                              in parsed: EditableParsedDocument) -> EntityID {
        let store = parsed.store
        var payload = TextPayload(position: Vec3(x: 0, y: 0), height: 1,
                                  stringId: store.strings.intern(value))
        payload.tagStringId = store.strings.intern(tag)
        return store.append(EntityPrototype(type: .attrib, layerId: 0,
                                            owner: .parentEntity(insertId),
                                            payload: .text(payload)))
    }

    func testPanelListsEveryAttributeWithItsRealTag() {
        let (parsed, id) = makeParsedWithInsert()
        _ = appendAttrib(to: id, tag: "PART_NUM", value: "ABC-123", in: parsed)
        _ = appendAttrib(to: id, tag: "QTY", value: "4", in: parsed)
        let attrs = BlockEditor.attributes(of: id, in: parsed.store)
        XCTAssertEqual(attrs.map(\.tag), ["PART_NUM", "QTY"])
        XCTAssertEqual(attrs.map(\.value), ["ABC-123", "4"])
    }

    func testEditingAnAttributeValueFromThePanelPersists() throws {
        let (parsed, id) = makeParsedWithInsert()
        _ = appendAttrib(to: id, tag: "PART_NUM", value: "ABC-123", in: parsed)
        parsed.document.transact("Edit PART_NUM") { tx in
            _ = BlockEditor.setAttribute(id, tag: "PART_NUM", value: "XYZ-999",
                                         in: parsed, tx: tx)
        }
        let attrs = BlockEditor.attributes(of: id, in: parsed.store)
        XCTAssertEqual(attrs.first?.value, "XYZ-999")
    }

    func testEditingOneAttributeLeavesTheOthersAlone() throws {
        let (parsed, id) = makeParsedWithInsert()
        _ = appendAttrib(to: id, tag: "PART_NUM", value: "ABC-123", in: parsed)
        _ = appendAttrib(to: id, tag: "QTY", value: "4", in: parsed)
        parsed.document.transact("Edit QTY") { tx in
            _ = BlockEditor.setAttribute(id, tag: "QTY", value: "12", in: parsed, tx: tx)
        }
        let byTag = Dictionary(uniqueKeysWithValues:
            BlockEditor.attributes(of: id, in: parsed.store).map { ($0.tag, $0.value) })
        XCTAssertEqual(byTag["QTY"], "12")
        XCTAssertEqual(byTag["PART_NUM"], "ABC-123")
    }

    func testAttributeEditIsUndoable() throws {
        let (parsed, id) = makeParsedWithInsert()
        _ = appendAttrib(to: id, tag: "PART_NUM", value: "ABC-123", in: parsed)
        parsed.document.transact("Edit PART_NUM") { tx in
            _ = BlockEditor.setAttribute(id, tag: "PART_NUM", value: "XYZ-999",
                                         in: parsed, tx: tx)
        }
        parsed.document.undo()
        XCTAssertEqual(BlockEditor.attributes(of: id, in: parsed.store).first?.value, "ABC-123")
    }

    /// An invisible ATTRIB (DXF group-70 bit 1) is retained in the store and
    /// data-bearing — see AGENTS.md invariant #2. It must therefore still be
    /// listed and editable in the Properties panel, even though it isn't drawn.
    func testInvisibleAttributesAreStillListedAndEditable() throws {
        let (parsed, id) = makeParsedWithInsert()
        let attribId = appendAttrib(to: id, tag: "CARRIER_ROUTE", value: "R-7", in: parsed)
        parsed.document.transact("Hide") { tx in
            tx.modifyHeader(attribId) { $0.flags.insert(.invisible) }
        }
        XCTAssertEqual(BlockEditor.attributes(of: id, in: parsed.store).first?.tag, "CARRIER_ROUTE",
                       "an invisible but data-bearing attribute must remain editable")
        parsed.document.transact("Edit") { tx in
            _ = BlockEditor.setAttribute(id, tag: "CARRIER_ROUTE", value: "R-9", in: parsed, tx: tx)
        }
        XCTAssertEqual(BlockEditor.attributes(of: id, in: parsed.store).first?.value, "R-9")
    }

    // MARK: - Re-render guarantee

    /// Editing an INSERT's payload must reach the already-built render groups,
    /// or a typed position/rotation would change the data while the canvas kept
    /// showing the block in its old place. `RegenCoordinator.apply` forces a
    /// full rebuild for any INSERT modify (its own documented "ambiguous
    /// incremental case -> full rebuild" rule) — asserted here so a future
    /// optimization can't silently drop that and desync the view.
    @MainActor
    func testEditingAnInsertPayloadForcesARebuildSoTheCanvasUpdates() throws {
        let (parsed, id) = makeParsedWithInsert()
        let doc = Regenerator.build(from: parsed, parseSeconds: 0) { _ in }
        let rc = RegenCoordinator(parsed: parsed, document: doc)
        parsed.document.transact("Change Position") { tx in
            tx.modifyPayload(id) { copy in
                guard case .insert(var p) = copy else { return }
                p.position.x = 999
                copy = .insert(p)
            }
        }
        let delta = rc.apply(try XCTUnwrap(parsed.document.undoStack.last).ops)
        XCTAssertTrue(delta.fullRebuild,
                      "an INSERT payload edit must rebuild, else the canvas shows a stale position")
    }
}
