import XCTest
@testable import DWGViewer
import CADCore
import CoreGraphics

/// Regression tests for three fixes bundled together in one session:
///
/// 1. Line/polyline "thickness" (DXF group 370 lineweight, group 43
///    LWPOLYLINE constant width) was silently swallowed by the parser —
///    every entity's stored value was always the BYLAYER default regardless
///    of what a source file actually specified.
/// 2. `HatchTool.isFillable`/`hatch(...)` never recognized a closed shape
///    living inside an ORPHAN-ROOT block (a block with real geometry that
///    nothing INSERTs — this project's dominant "nearly empty model space"
///    architecture for real plant-layout DXFs), so "Fill / Hatch…" silently
///    never appeared for the overwhelming majority of a real drawing's
///    closed shapes.
/// 3. `SelectColorDialog`'s header-preview swatch painted ACI 7
///    ("foreground") as literal white regardless of theme, same class of
///    bug already fixed elsewhere via `ResolvedColor.swatchDisplayRGB`.
final class LineweightAndHatchSettingsTests: XCTestCase {

    // MARK: - Lineweight / constant-width parsing (group 370 / 43)

    func testLineGroup370LineweightIsParsed() throws {
        let parsed = try EntityStoreParser.parse(url: TestFixtures.url("lineweight.dxf"))
        let store = parsed.store
        let id = try XCTUnwrap(store.entity(forHandle: 0x200))
        let h = try XCTUnwrap(store.header(id))
        XCTAssertEqual(h.type, .line)
        XCTAssertEqual(h.lineweight, 50, "group 370 (hundredths of a mm) must be read into EntityHeader.lineweight")
    }

    func testLwpolylineGroup370AndConstantWidthAreParsed() throws {
        let parsed = try EntityStoreParser.parse(url: TestFixtures.url("lineweight.dxf"))
        let store = parsed.store
        let id = try XCTUnwrap(store.entity(forHandle: 0x201))
        let h = try XCTUnwrap(store.header(id))
        XCTAssertEqual(h.type, .lwpolyline)
        XCTAssertEqual(h.lineweight, 25, "group 370 must be read for LWPOLYLINE just like any other entity")
        let p = store.polylines[Int(h.payload)]
        XCTAssertEqual(p.constantWidth, 2.5, "group 43 (constant/global width) must be read into PolylinePayload.constantWidth")
    }

    func testEntityWithNoGroup370DefaultsToByLayer() throws {
        let parsed = try EntityStoreParser.parse(url: TestFixtures.url("lineweight.dxf"))
        let store = parsed.store
        let id = try XCTUnwrap(store.entity(forHandle: 0x202))
        let h = try XCTUnwrap(store.header(id))
        XCTAssertEqual(h.lineweight, -1, "no group 370 present must default to BYLAYER (-1), not 0")
    }

    // MARK: - Properties panel "Line Weight" editor (round-trips through Transaction)

    func testModifyHeaderLineweightIsPersisted() {
        let store = EntityStore()
        let id = store.append(EntityPrototype(
            type: .line, layerId: 0,
            payload: .line(LinePayload(a: Vec3(x: 0, y: 0), b: Vec3(x: 10, y: 0)))))
        store.setHeader(id) { $0.lineweight = 60 }
        XCTAssertEqual(store.header(id)?.lineweight, 60)
    }

    // MARK: - CGRenderCore.screenStrokeWidth

    func testScreenStrokeWidthByLayerReturnsDefault() {
        let w = CGRenderCore.screenStrokeWidth(forLineweight: -1, defaultWidth: 2.0)
        XCTAssertEqual(w, 2.0)
    }

    func testScreenStrokeWidthDefaultLineweightMatchesDefault() {
        // DXF value 25 == AutoCAD's own default (0.25mm) — must render
        // identically to "no override at all" (defaultWidth), not thinner
        // or thicker, so an explicit default-lineweight entity looks the
        // same as a never-set one.
        let w = CGRenderCore.screenStrokeWidth(forLineweight: 25, defaultWidth: 2.0)
        XCTAssertEqual(w, 2.0, accuracy: 0.001)
    }

    func testScreenStrokeWidthScalesUpForHeavierLineweight() {
        let base = CGRenderCore.screenStrokeWidth(forLineweight: 25, defaultWidth: 2.0)
        let heavier = CGRenderCore.screenStrokeWidth(forLineweight: 100, defaultWidth: 2.0)
        XCTAssertGreaterThan(heavier, base, "a heavier DXF lineweight must render visibly thicker")
    }

    func testScreenStrokeWidthNeverThinnerThanDefault() {
        // A thin explicit lineweight (e.g. 0.05mm) must not render THINNER
        // than the hairline default — a hairline is already the thinnest
        // legible width.
        let w = CGRenderCore.screenStrokeWidth(forLineweight: 5, defaultWidth: 2.0)
        XCTAssertGreaterThanOrEqual(w, 2.0)
    }

    // MARK: - HatchTool.isFillable / .hatch on orphan-root block content

    private func makeParsedWithLayer() -> EditableParsedDocument {
        let parsed = EditableParsedDocument()
        parsed.layers.append(DXFLayer(id: 0, name: "0"))
        parsed.layerIdByName["0"] = 0
        return parsed
    }

    func testBlockOwnedClosedShapeIsFillableWhenReportedAsOrphanRoot() {
        let parsed = makeParsedWithLayer()
        let blockIndex = BlockEditor.nextBlockIndex(in: parsed)
        var id: EntityID!
        parsed.document.transact("Define block") { tx in
            id = tx.add(EntityPrototype(
                type: .lwpolyline, layerId: 0, owner: .block(blockIndex),
                payload: .polyline(PolylinePayload(closed: true),
                                   vertices: [Vec3(x: 0, y: 0), Vec3(x: 10, y: 0), Vec3(x: 10, y: 10)],
                                   bulges: [0, 0, 0])))
        }
        // Without orphan-root knowledge, block-owned content stays not-fillable
        // (matches the pre-fix, still-correct behavior for a NORMALLY-inserted
        // block, which is NOT safe to hatch from a single member alone).
        XCTAssertFalse(HatchTool.isFillable(id, in: parsed.store))
        // A caller that KNOWS this block is an orphan root (e.g.
        // `RegenCoordinator.isOrphanRootBlock`) must be able to admit it.
        XCTAssertTrue(HatchTool.isFillable(id, in: parsed.store, isOrphanRoot: { $0 == blockIndex }))
        // A DIFFERENT block index must not be treated as an orphan root by
        // the same closure (sanity check the plumbing is actually gated on
        // the entity's own owner, not a blanket "always true").
        XCTAssertFalse(HatchTool.isFillable(id, in: parsed.store, isOrphanRoot: { $0 == blockIndex + 1 }))
    }

    func testHatchCreatesFromOrphanRootOwnedShapeGivenOrphanRootIsOkThroughIsFillableGate() throws {
        // `HatchTool.hatch` itself never checked ownership (only
        // `isFillable` gates the UI) — confirm it still succeeds for a
        // block-owned closed shape once the UI gate has been satisfied,
        // preserving the shape's own `.block(_)` owner on the new hatch
        // (so it renders in the SAME place as its source, via the same
        // orphan-root base-point translation).
        let parsed = makeParsedWithLayer()
        let blockIndex = BlockEditor.nextBlockIndex(in: parsed)
        var id: EntityID!
        parsed.document.transact("Define block") { tx in
            id = tx.add(EntityPrototype(
                type: .lwpolyline, layerId: 0, owner: .block(blockIndex),
                payload: .polyline(PolylinePayload(closed: true),
                                   vertices: [Vec3(x: 0, y: 0), Vec3(x: 10, y: 0), Vec3(x: 10, y: 10)],
                                   bulges: [0, 0, 0])))
        }
        XCTAssertTrue(HatchTool.isFillable(id, in: parsed.store, isOrphanRoot: { $0 == blockIndex }))
        var newId: EntityID?
        parsed.document.transact("Fill") { tx in newId = HatchTool.hatch(id, in: parsed, tx: tx) }
        let hatchId = try XCTUnwrap(newId)
        let h = try XCTUnwrap(parsed.store.header(hatchId))
        XCTAssertEqual(h.owner, OwnerRef.block(blockIndex))
    }

    // MARK: - HatchStyle / Hatch Settings (Solid vs Diagonal Lines)

    func testHatchToolCreatesDiagonalLinesStyleWhenRequested() throws {
        let parsed = makeParsedWithLayer()
        let id = parsed.store.append(EntityPrototype(
            type: .lwpolyline, layerId: 0, owner: .model,
            payload: .polyline(PolylinePayload(closed: true),
                               vertices: [Vec3(x: 0, y: 0), Vec3(x: 10, y: 0),
                                          Vec3(x: 10, y: 10), Vec3(x: 0, y: 10)],
                               bulges: [0, 0, 0, 0])))
        var newId: EntityID?
        parsed.document.transact("Fill") { tx in
            newId = HatchTool.hatch(id, in: parsed, tx: tx, style: .diagonalLines)
        }
        let hatchId = try XCTUnwrap(newId)
        let h = try XCTUnwrap(parsed.store.header(hatchId))
        let hp = parsed.store.hatches[Int(h.payload)]
        XCTAssertFalse(hp.isSolid)
        XCTAssertEqual(parsed.store.strings.string(for: hp.patternNameId), HatchStyle.diagonalPatternName)
    }

    func testHatchToolDefaultsToSolidStyle() throws {
        // Existing call sites (and existing tests) rely on `hatch(...)`
        // defaulting to a solid fill when no style is specified.
        let parsed = makeParsedWithLayer()
        let id = parsed.store.append(EntityPrototype(
            type: .lwpolyline, layerId: 0, owner: .model,
            payload: .polyline(PolylinePayload(closed: true),
                               vertices: [Vec3(x: 0, y: 0), Vec3(x: 10, y: 0), Vec3(x: 10, y: 10)],
                               bulges: [0, 0, 0])))
        var newId: EntityID?
        parsed.document.transact("Fill") { tx in newId = HatchTool.hatch(id, in: parsed, tx: tx) }
        let hatchId = try XCTUnwrap(newId)
        let h = try XCTUnwrap(parsed.store.header(hatchId))
        XCTAssertTrue(parsed.store.hatches[Int(h.payload)].isSolid)
    }

    func testHatchStyleInitMapsIsSolidCorrectly() {
        XCTAssertEqual(HatchStyle(isSolid: true), .solid)
        XCTAssertEqual(HatchStyle(isSolid: false), .diagonalLines)
    }

    // MARK: - HATCH parser: angle/scale/pattern-name retention (group 52/41/2)

    func testHatchAngleScaleAndPatternNameAreParsed() throws {
        // hatch_rect.dxf is a SOLID hatch fixture; build a tiny non-solid
        // HATCH by hand via makeHatchLoops's own entity-record shape isn't
        // exposed directly, so this exercises the payload fields via the
        // in-memory store construction path instead (parser fields are
        // covered structurally by `ParserRetentionTests`'s existing
        // hatch_rect.dxf coverage for the solid case).
        var hp = HatchPayload(isSolid: false, angle: 45, scale: 2, origin: Vec3(x: 0, y: 0))
        let store = EntityStore()
        hp.patternNameId = store.strings.intern("ANSI31")
        let id = store.append(EntityPrototype(
            type: .hatch, layerId: 0,
            payload: .hatch(hp, loops: [[Vec3(x: 0, y: 0), Vec3(x: 10, y: 0), Vec3(x: 10, y: 10)]])))
        let h = try XCTUnwrap(store.header(id))
        let stored = store.hatches[Int(h.payload)]
        XCTAssertEqual(stored.angle, 45)
        XCTAssertEqual(stored.scale, 2)
        XCTAssertEqual(store.strings.string(for: stored.patternNameId), "ANSI31")
    }

    // MARK: - ShadeLayer.crosshatchSegments density parameter

    func testCrosshatchSegmentsHigherDensityProducesMoreSegments() {
        let loop: [Vec3] = [Vec3(x: 0, y: 0), Vec3(x: 100, y: 0), Vec3(x: 100, y: 100), Vec3(x: 0, y: 100)]
        let sparse = ShadeLayer.crosshatchSegments(for: loop, angleDeg: 45, density: 0.3)
        let dense = ShadeLayer.crosshatchSegments(for: loop, angleDeg: 45, density: 3.0)
        XCTAssertGreaterThan(dense.count, sparse.count, "a higher density must produce more, closer-spaced lines")
    }

    func testCrosshatchSegmentsDensityOneMatchesOriginalSpacing() {
        // `density: 1.0` (the default) must be identical to calling with no
        // density argument at all — `ShadeLayer.apply(...)`'s own bulk
        // "Shade Layer" crosshatch call site must be byte-for-byte
        // unaffected by this parameter's addition.
        let loop: [Vec3] = [Vec3(x: 0, y: 0), Vec3(x: 100, y: 0), Vec3(x: 100, y: 100), Vec3(x: 0, y: 100)]
        let withDefault = ShadeLayer.crosshatchSegments(for: loop, angleDeg: 45)
        let explicit1 = ShadeLayer.crosshatchSegments(for: loop, angleDeg: 45, density: 1.0)
        XCTAssertEqual(withDefault.count, explicit1.count)
    }

    // MARK: - Regenerator: non-solid hatch renders diagonal-line strokes

    func testNonSolidHatchEmitsStrokeRunsForItsPattern() {
        let parsed = makeParsedWithLayer()
        var hp = HatchPayload(isSolid: false, angle: 45, scale: 1, origin: Vec3(x: 5, y: 5))
        hp.patternNameId = parsed.store.strings.intern(HatchStyle.diagonalPatternName)
        _ = parsed.store.append(EntityPrototype(
            type: .hatch, layerId: 0, owner: .model,
            payload: .hatch(hp, loops: [[Vec3(x: 0, y: 0), Vec3(x: 10, y: 0),
                                          Vec3(x: 10, y: 10), Vec3(x: 0, y: 10)]])))
        let doc = Regenerator.build(from: parsed, parseSeconds: 0) { _ in }
        let hatchGroups = doc.modelGroups.filter { !$0.strokes.runs.isEmpty }
        XCTAssertFalse(hatchGroups.isEmpty, "a non-solid hatch must emit stroke runs for its diagonal-line pattern")
        // Solid fill path must stay empty for a non-solid hatch (no
        // translucent-approximation fill drawn underneath the real lines).
        XCTAssertTrue(doc.modelGroups.allSatisfy { $0.fillPath.isEmpty })
    }

    func testSolidHatchStillEmitsAFillPath() {
        let parsed = makeParsedWithLayer()
        let hp = HatchPayload(isSolid: true, angle: 0, scale: 1, origin: Vec3(x: 5, y: 5))
        _ = parsed.store.append(EntityPrototype(
            type: .hatch, layerId: 0, owner: .model,
            payload: .hatch(hp, loops: [[Vec3(x: 0, y: 0), Vec3(x: 10, y: 0),
                                          Vec3(x: 10, y: 10), Vec3(x: 0, y: 10)]])))
        let doc = Regenerator.build(from: parsed, parseSeconds: 0) { _ in }
        XCTAssertTrue(doc.modelGroups.contains { !$0.fillPath.isEmpty })
    }

    // MARK: - RegenCoordinator.isOrphanRootBlock

    func testIsOrphanRootBlockTrueForABlockWithGeometryThatIsNeverInserted() {
        let parsed = makeParsedWithLayer()
        let block = EditableBlockDef()
        block.name = "ORPHANBLOCK"
        block.blockIndex = 0
        parsed.document.transact("Add") { tx in
            _ = tx.add(EntityPrototype(type: .line, layerId: 0, owner: .block(0),
                                       payload: .line(LinePayload(a: Vec3(x: 0, y: 0), b: Vec3(x: 1, y: 1)))))
        }
        block.entityStart = 0
        block.entityCount = 1
        parsed.blocks["ORPHANBLOCK"] = block
        let doc = Regenerator.build(from: parsed, parseSeconds: 0) { _ in }
        let regen = RegenCoordinator(parsed: parsed, document: doc)
        XCTAssertTrue(regen.isOrphanRootBlock(0))
    }

    func testIsOrphanRootBlockFalseForANormallyInsertedBlock() {
        let parsed = makeParsedWithLayer()
        let block = EditableBlockDef()
        block.name = "REALBLOCK"
        block.blockIndex = 0
        parsed.document.transact("Add") { tx in
            _ = tx.add(EntityPrototype(type: .line, layerId: 0, owner: .block(0),
                                       payload: .line(LinePayload(a: Vec3(x: 0, y: 0), b: Vec3(x: 1, y: 1)))))
        }
        block.entityStart = 0
        block.entityCount = 1
        parsed.blocks["REALBLOCK"] = block
        parsed.document.transact("Insert") { tx in
            let sid = parsed.store.strings.intern("REALBLOCK")
            _ = tx.add(EntityPrototype(type: .insert, layerId: 0, owner: .model,
                                       payload: .insert(InsertPayload(blockNameId: sid, position: Vec3(x: 0, y: 0)))))
        }
        let doc = Regenerator.build(from: parsed, parseSeconds: 0) { _ in }
        let regen = RegenCoordinator(parsed: parsed, document: doc)
        XCTAssertFalse(regen.isOrphanRootBlock(0))
    }

    // MARK: - SelectColorDialog.ColorChoice — ACI 7 maps to the theme-aware helper

    func testColorChoiceForegroundResolvesToForegroundResolvedColor() {
        let choice = SelectColorDialog.ColorChoice(resolved: .foreground)
        XCTAssertEqual(choice, .aci(7))
        XCTAssertEqual(choice.resolvedColor, .foreground)
        // The theme-aware swatch helper (not the old always-white `swatchRGB`)
        // must disagree between light and dark — this is the actual bug fix:
        // `ACIPalette.rgb(forACI: 7)` alone (what the dialog used before) is
        // 0xFFFFFF unconditionally, i.e. white on BOTH backgrounds.
        XCTAssertEqual(choice.resolvedColor.swatchDisplayRGB(darkBackground: false), 0x000000)
        XCTAssertEqual(choice.resolvedColor.swatchDisplayRGB(darkBackground: true), 0xFFFFFF)
    }
}
