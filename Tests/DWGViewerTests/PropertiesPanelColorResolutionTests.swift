import XCTest
@testable import DWGViewer
import CADCore

/// Tests for the Properties panel's Color swatch resolution — the mechanism
/// behind a reported bug: "when you click an object, the color drop-down
/// shows white as the thumbnail/square that should be colored to match the
/// color selection."
///
/// This is the SAME bug class as `PropertiesPanelLayerResolutionTests`' "the
/// layer always says 0 in properties": the panel read a RAW
/// `EntityHeader` field instead of the RESOLVED/effective value the renderer
/// actually paints with, so anything whose appearance is inherited rather
/// than stored locally displayed a wrong (default-looking) value.
///
/// Two distinct root causes are covered:
///
///  1. **`ResolvedColor.foreground` maps to `swatchRGB == 0xFFFFFF` (white).**
///     Every entity that is BYLAYER on a layer whose own color is
///     `.foreground` — the overwhelmingly common case, since ACI 7 is the
///     default layer color in essentially every real drawing — therefore
///     painted a WHITE swatch, which is invisible against the panel's light
///     background and reads as "no color". `foreground` means "whatever
///     contrasts with the canvas", so it must resolve against the CURRENT
///     theme for display, not to a hardcoded white.
///  2. **Block-internal / xref content resolves its color through the
///     owning INSERT.** Reading `header.aci`/`header.layerId` raw ignores
///     BYLAYER layer-0 substitution and BYBLOCK inheritance, so such an
///     entity reported its authoring-time placeholder rather than what it
///     renders as.
final class PropertiesPanelColorResolutionTests: XCTestCase {

    // MARK: - swatch display color

    /// The direct cause of the reported symptom: `.foreground` must NOT be
    /// displayed as flat white in panel UI.
    func testForegroundSwatchIsNotWhiteOnLightBackground() {
        let shown = ResolvedColor.foreground.swatchDisplayRGB(darkBackground: false)
        XCTAssertNotEqual(shown, 0xFFFFFF,
                          "a white swatch on a light panel is invisible — the exact reported bug")
        XCTAssertEqual(shown, 0x000000, "on a light theme, foreground should read as black")
    }

    func testForegroundSwatchIsWhiteOnDarkBackground() {
        XCTAssertEqual(ResolvedColor.foreground.swatchDisplayRGB(darkBackground: true), 0xFFFFFF,
                       "on a dark theme, foreground legitimately IS white")
    }

    /// An explicit color must be shown verbatim regardless of theme — only
    /// `.foreground` is theme-dependent.
    func testExplicitColorsAreShownVerbatim() {
        let red = ResolvedColor.rgb(0xFF0000)
        XCTAssertEqual(red.swatchDisplayRGB(darkBackground: false), 0xFF0000)
        XCTAssertEqual(red.swatchDisplayRGB(darkBackground: true), 0xFF0000)
    }

    /// Pure black is invisible on a dark canvas, so the renderer flips it to
    /// white (see `ResolvedColor.cgColor`). The swatch must apply the SAME
    /// rule, or the panel disagrees with what the user sees on screen.
    func testPureBlackFlipsOnDarkBackgroundMatchingTheRenderer() {
        let black = ResolvedColor.rgb(0x000000)
        XCTAssertEqual(black.swatchDisplayRGB(darkBackground: false), 0x000000)
        XCTAssertEqual(black.swatchDisplayRGB(darkBackground: true), 0xFFFFFF,
                       "must match the renderer's own black-on-dark flip")
    }

    // MARK: - resolved color for a selection

    private func makeFixture() -> (parsed: EditableParsedDocument, doc: DXFDocument,
                                   insertId: EntityID, blockLineId: EntityID,
                                   redLineId: EntityID, byLayerLineId: EntityID) {
        let parsed = EditableParsedDocument()
        parsed.layers.append(DXFLayer(id: 0, name: "0"))
        parsed.layerIdByName["0"] = 0
        // A layer with an explicit GREEN color.
        var green = DXFLayer(id: 1, name: "GREENLAYER")
        green.color = .rgb(0x00FF00)
        parsed.layers.append(green)
        parsed.layerIdByName["GREENLAYER"] = 1
        parsed.linetypes.append(DXFLinetype(name: "CONTINUOUS", dashes: []))
        parsed.linetypeIdByName["CONTINUOUS"] = 0

        let store = parsed.store
        let blockIndex: Int32 = 0
        let blockDef = EditableBlockDef()
        blockDef.name = "PARTBLOCK"
        blockDef.blockIndex = blockIndex
        blockDef.entityStart = Int32(store.count)
        // Block content authored on layer 0, BYLAYER — the standard
        // convention so it inherits the owning INSERT's layer/color.
        let blockLineId = store.append(EntityPrototype(
            type: .line, layerId: 0, aci: 256, owner: .block(blockIndex),
            payload: .line(LinePayload(a: Vec3(x: 0, y: 0), b: Vec3(x: 5, y: 5)))))
        blockDef.entityCount = Int32(store.count) - blockDef.entityStart
        parsed.blocks["PARTBLOCK"] = blockDef

        // An INSERT of that block placed on the GREEN layer.
        let nameId = store.strings.intern("PARTBLOCK")
        let insertId = store.append(EntityPrototype(
            type: .insert, layerId: 1, aci: 256, owner: .model,
            payload: .insert(InsertPayload(blockNameId: nameId, position: Vec3(x: 100, y: 100)))))

        // A top-level line with an EXPLICIT red index color (ACI 1).
        let redLineId = store.append(EntityPrototype(
            type: .line, layerId: 0, aci: 1, owner: .model,
            payload: .line(LinePayload(a: Vec3(x: 0, y: 0), b: Vec3(x: 10, y: 0)))))

        // A top-level BYLAYER line on the GREEN layer.
        let byLayerLineId = store.append(EntityPrototype(
            type: .line, layerId: 1, aci: 256, owner: .model,
            payload: .line(LinePayload(a: Vec3(x: 0, y: 20), b: Vec3(x: 10, y: 20)))))

        let doc = Regenerator.build(from: parsed, parseSeconds: 0) { _ in }
        return (parsed, doc, insertId, blockLineId, redLineId, byLayerLineId)
    }

    func testExplicitIndexColorResolves() {
        let f = makeFixture()
        let color = PropertiesColorResolver.color(for: [f.redLineId], parsed: f.parsed,
                                                  document: f.doc, space: .model)
        XCTAssertEqual(color, .rgb(ACIPalette.rgb(forACI: 1)), "ACI 1 is red")
    }

    /// A BYLAYER entity must report its LAYER's color, not a default.
    func testByLayerEntityResolvesToItsLayerColor() {
        let f = makeFixture()
        let color = PropertiesColorResolver.color(for: [f.byLayerLineId], parsed: f.parsed,
                                                  document: f.doc, space: .model)
        XCTAssertEqual(color, .rgb(0x00FF00), "should show the layer's green, not white")
    }

    /// The block/xref case: content stored on layer 0 must resolve through
    /// the owning INSERT's layer, so it shows GREEN rather than layer 0's
    /// default.
    func testBlockContentResolvesThroughOwningInsert() {
        let f = makeFixture()
        let color = PropertiesColorResolver.color(for: [f.blockLineId], parsed: f.parsed,
                                                  document: f.doc, space: .model)
        XCTAssertEqual(color, .rgb(0x00FF00),
                       "block content on layer 0 inherits the INSERT's layer color")
    }

    func testInsertItselfResolvesToItsLayerColor() {
        let f = makeFixture()
        let color = PropertiesColorResolver.color(for: [f.insertId], parsed: f.parsed,
                                                  document: f.doc, space: .model)
        XCTAssertEqual(color, .rgb(0x00FF00))
    }

    /// A true color must win over any index color.
    func testTrueColorWinsOverIndexColor() {
        let parsed = EditableParsedDocument()
        parsed.layers.append(DXFLayer(id: 0, name: "0"))
        parsed.layerIdByName["0"] = 0
        parsed.linetypes.append(DXFLinetype(name: "CONTINUOUS", dashes: []))
        parsed.linetypeIdByName["CONTINUOUS"] = 0
        let id = parsed.store.append(EntityPrototype(
            type: .line, layerId: 0, aci: 1, trueColor: 0x0012_3456, owner: .model,
            payload: .line(LinePayload(a: Vec3(x: 0, y: 0), b: Vec3(x: 1, y: 0)))))
        let doc = Regenerator.build(from: parsed, parseSeconds: 0) { _ in }
        let color = PropertiesColorResolver.color(for: [id], parsed: parsed,
                                                  document: doc, space: .model)
        XCTAssertEqual(color, .rgb(0x0012_3456))
    }

    func testEmptySelectionFallsBackToForeground() {
        let f = makeFixture()
        XCTAssertEqual(PropertiesColorResolver.color(for: [], parsed: f.parsed,
                                                     document: f.doc, space: .model),
                       .foreground)
    }

    /// A mixed selection has no single answer; it must report nil-equivalent
    /// (foreground) rather than silently showing just the first entity's
    /// color as if it applied to everything.
    func testMixedSelectionIsReportedAsMixed() {
        let f = makeFixture()
        XCTAssertTrue(PropertiesColorResolver.isMixed(for: [f.redLineId, f.byLayerLineId],
                                                      parsed: f.parsed, document: f.doc, space: .model),
                      "red + green is genuinely mixed")
        XCTAssertFalse(PropertiesColorResolver.isMixed(for: [f.redLineId],
                                                       parsed: f.parsed, document: f.doc, space: .model))
    }

    /// A deleted entity must not contribute a phantom color.
    func testDeletedEntityIsIgnored() {
        let f = makeFixture()
        f.parsed.document.transact("delete") { tx in tx.delete(f.redLineId) }
        let color = PropertiesColorResolver.color(for: [f.redLineId], parsed: f.parsed,
                                                  document: f.doc, space: .model)
        XCTAssertEqual(color, .foreground, "a deleted entity has no color to report")
    }
}
