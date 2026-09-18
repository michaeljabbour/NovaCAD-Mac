import XCTest
@testable import DWGViewer
import CADCore

/// Tests for `RegenCoordinator.resolveToRefs`'s layer resolution against
/// block-internal content authored on layer "0" — the exact mechanism
/// `PropertiesPanel.layerBinding`'s getter now uses, fixing a real bug: "the
/// layer always says '0' in properties" for xref (and any block-content)
/// objects.
///
/// Root cause this locks in: block-internal geometry drawn on layer "0" in
/// its SOURCE file (the standard AutoCAD authoring convention so it inherits
/// the owning INSERT's layer via BYLAYER substitution — extremely common in
/// xref content specifically) genuinely has `EntityHeader.layerId == 0` in
/// the store; that part is correct. But `PropertiesPanel`'s old getter read
/// that raw stored value directly instead of the RESOLVED/effective layer
/// (`InsertInstance.layerId`/`RenderGroup.layerId`, which apply
/// `PropertyResolver`'s layer-0-substitution) — so the dropdown showed "0"
/// for every such object regardless of which layer it was actually on, while
/// `HitTester.properties(for:)`'s read-only "Layer" row (reading the SAME
/// resolved value) showed the correct name the whole time. This file tests
/// the shared resolution mechanism directly; `PropertiesPanel`'s getter isn't
/// independently unit-testable (private computed property on a SwiftUI View
/// struct), but it now delegates entirely to this same path.
final class PropertiesPanelLayerResolutionTests: XCTestCase {

    /// One document with:
    ///   - layer "0" (id 0) and layer "REALLAYER" (id 1)
    ///   - a block "PARTBLOCK" whose OWN internal content (a LINE) sits on
    ///     layer "0" — the authoring convention block/xref content commonly
    ///     uses so it inherits whatever layer the INSERT ends up on.
    ///   - a top-level INSERT of PARTBLOCK placed on "REALLAYER" — mirrors
    ///     an xref'd block reference whose HOST-visible layer is
    ///     "REALLAYER", even though its own drawn content is nominally "0".
    private func makeFixture() -> (parsed: EditableParsedDocument, doc: DXFDocument,
                                   insertId: EntityID, lineId: EntityID) {
        let parsed = EditableParsedDocument()
        parsed.layers.append(DXFLayer(id: 0, name: "0"))
        parsed.layerIdByName["0"] = 0
        parsed.layers.append(DXFLayer(id: 1, name: "REALLAYER"))
        parsed.layerIdByName["REALLAYER"] = 1

        let store = parsed.store
        let blockIndex: Int32 = 0
        let blockDef = EditableBlockDef()
        blockDef.name = "PARTBLOCK"
        blockDef.blockIndex = blockIndex
        blockDef.entityStart = Int32(store.count)

        let lineId = store.append(EntityPrototype(
            type: .line, layerId: 0, owner: .block(blockIndex),
            payload: .line(LinePayload(a: Vec3(x: 0, y: 0), b: Vec3(x: 5, y: 5)))))
        blockDef.entityCount = Int32(store.count) - blockDef.entityStart
        parsed.blocks["PARTBLOCK"] = blockDef

        let nameId = store.strings.intern("PARTBLOCK")
        let insertId = store.append(EntityPrototype(
            type: .insert, layerId: 1, owner: .model,
            payload: .insert(InsertPayload(blockNameId: nameId, position: Vec3(x: 100, y: 100)))))

        let doc = Regenerator.build(from: parsed, parseSeconds: 0) { _ in }
        return (parsed, doc, insertId, lineId)
    }

    // MARK: - The INSERT itself resolves to its own real layer (sanity)

    @MainActor
    func testInsertResolvesToTheLayerItIsActuallyOn() throws {
        let (parsed, doc, insertId, _) = makeFixture()
        let rc = RegenCoordinator(parsed: parsed, document: doc)
        let refs = rc.resolveToRefs([insertId])
        guard case .insert(let idx) = try XCTUnwrap(refs.first) else {
            return XCTFail("expected an .insert ref")
        }
        let layerId = Int(doc.inserts[Int(idx)].layerId)
        XCTAssertEqual(doc.layers[layerId].name, "REALLAYER",
                       "an INSERT's own resolved layer must be whatever layer IT is on, not its block content's")
    }

    /// THE headline regression: block-internal content authored on layer
    /// "0" must resolve to the layer its OWNING INSERT is actually on — not
    /// literal layer "0" — when read through the exact mechanism
    /// `PropertiesPanel.layerBinding` now uses. Before the fix, the
    /// Properties panel's dropdown read `EntityHeader.layerId` directly
    /// (genuinely 0 for this LINE) and showed "0"; the fix instead resolves
    /// through `RenderGroup.layerId`, matching this test's expectation.
    @MainActor
    func testBlockContentOnLayerZeroResolvesToItsInsertsRealLayer() throws {
        let (parsed, doc, _, lineId) = makeFixture()
        let rc = RegenCoordinator(parsed: parsed, document: doc)
        let refs = rc.resolveToRefs([lineId])
        guard case .primitive(let groupIndex, _, _) = try XCTUnwrap(refs.first) else {
            return XCTFail("expected a .primitive ref for the block-internal LINE")
        }
        let group = doc.modelGroups[Int(groupIndex)]
        XCTAssertEqual(doc.layers[Int(group.layerId)].name, "REALLAYER",
                      "layer-0-authored block content must resolve to its INSERT's real layer, not literal '0' — this is exactly the reported bug")
        XCTAssertNotEqual(doc.layers[Int(group.layerId)].name, "0",
                          "must NOT show the raw stored layerId's name")
    }

    /// Confirms `HitTester.properties(for:)`'s read-only Layer row (already
    /// correct — see this session's investigation) and the resolution
    /// `PropertiesPanel.layerBinding` now uses AGREE — the whole point of
    /// the fix is eliminating the divergence between the two, not just
    /// making the dropdown correct in isolation.
    @MainActor
    func testResolvedLayerMatchesTheReadOnlyPropertiesPanelRow() throws {
        let (parsed, doc, _, lineId) = makeFixture()
        let rc = RegenCoordinator(parsed: parsed, document: doc)
        let refs = rc.resolveToRefs([lineId])
        let ref = try XCTUnwrap(refs.first)
        let props = HitTester.properties(for: ref, document: doc, usePaperSpace: false, store: parsed.store)
        let readOnlyLayer = try XCTUnwrap(props.first { $0.name == "Layer" }?.value)

        guard case .primitive(let groupIndex, _, _) = ref else {
            return XCTFail("expected a .primitive ref")
        }
        let resolvedName = doc.layers[Int(doc.modelGroups[Int(groupIndex)].layerId)].name
        XCTAssertEqual(readOnlyLayer, resolvedName,
                      "the editable dropdown's resolution and the read-only row must agree exactly")
    }

    /// A multi-selection mixing block-internal (layer-0-authored) content
    /// with an ordinary top-level entity that's ALSO genuinely on
    /// "REALLAYER" must still collapse to one agreed-upon name, not
    /// spuriously show "Various" just because their STORED layerIds differ
    /// (0 vs 1) — the merge must happen on the RESOLVED name.
    @MainActor
    func testMultiSelectionOfBlockContentAndTopLevelEntityOnSameResolvedLayerAgree() throws {
        let (parsed, _, _, lineId) = makeFixture()
        var topLevelId: EntityID!
        parsed.document.transact("Add") { tx in
            topLevelId = tx.add(EntityPrototype(
                type: .line, layerId: 1, owner: .model,
                payload: .line(LinePayload(a: Vec3(x: 200, y: 200), b: Vec3(x: 210, y: 210)))))
        }
        let doc = Regenerator.build(from: parsed, parseSeconds: 0) { _ in }
        let rc = RegenCoordinator(parsed: parsed, document: doc)

        let refs = rc.resolveToRefs([lineId, topLevelId])
        var names: Set<String> = []
        for ref in refs {
            if case .primitive(let gi, _, _) = ref {
                names.insert(doc.layers[Int(doc.modelGroups[Int(gi)].layerId)].name)
            }
        }
        XCTAssertEqual(names, ["REALLAYER"],
                      "both entities resolve to the SAME real layer despite different stored layerIds (0 vs 1)")
    }
}
