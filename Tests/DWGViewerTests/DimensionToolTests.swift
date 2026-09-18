import XCTest
@testable import DWGViewer
import CADCore

/// DIMENSION annotation tests: `DimensionTool.create` builds a real
/// DIMENSION entity + its own anonymous block, `Regenerator` must expand it
/// back to the correct on-screen geometry, and per-dimension format
/// metadata must round-trip through XDATA and support in-place reformatting.
final class DimensionToolTests: XCTestCase {

    private func makeParsed() -> EditableParsedDocument {
        let parsed = EditableParsedDocument()
        parsed.layers.append(DXFLayer(id: 0, name: "0"))
        parsed.layerIdByName["0"] = 0
        parsed.linetypes.append(DXFLinetype(name: "CONTINUOUS", dashes: []))
        parsed.linetypeIdByName["CONTINUOUS"] = 0
        return parsed
    }

    // MARK: - Aligned dimension

    func testAlignedDimensionMeasuresTrueDistanceAndCreatesBlock() throws {
        let parsed = makeParsed()
        let doc = parsed.document
        var dimId: EntityID!
        doc.transact("Dimension") { tx in
            dimId = DimensionTool.create(kind: .aligned,
                                        p1: CGPoint(x: 0, y: 0), p2: CGPoint(x: 30, y: 40),
                                        placement: CGPoint(x: 15, y: 30),
                                        layerId: 0, aci: 256, format: MeasureFormat(),
                                        owner: .model, parsed: parsed, tx: tx)
        }
        let id = try XCTUnwrap(dimId)

        let h = try XCTUnwrap(doc.store.header(id))
        XCTAssertEqual(h.type, .dimension)
        XCTAssertTrue(h.owner.isModel)

        let dp = doc.store.dimensions[Int(h.payload)]
        let blockName = doc.store.strings.string(for: dp.blockNameId)
        let block = try XCTUnwrap(parsed.blocks[blockName])
        XCTAssertGreaterThan(block.entityCount, 0)

        // 3-4-5 triangle scaled x10: distance from (0,0) to (30,40) is 50.
        let info = try XCTUnwrap(DimensionTool.readMetadata(id, store: doc.store))
        XCTAssertEqual(info.measuredValue, 50, accuracy: 1e-6)
    }

    func testLinearDimensionMeasuresOnlyTheDominantAxis() throws {
        let parsed = makeParsed()
        let doc = parsed.document
        var dimId: EntityID!
        // Placement far below in Y (large horizOffset) -> horizontal
        // dimension line, measures |Δx| = 30, NOT the diagonal distance.
        doc.transact("Dimension") { tx in
            dimId = DimensionTool.create(kind: .linear,
                                        p1: CGPoint(x: 0, y: 0), p2: CGPoint(x: 30, y: 40),
                                        placement: CGPoint(x: 15, y: -50),
                                        layerId: 0, aci: 256, format: MeasureFormat(),
                                        owner: .model, parsed: parsed, tx: tx)
        }
        let id = try XCTUnwrap(dimId)
        let info = try XCTUnwrap(DimensionTool.readMetadata(id, store: doc.store))
        XCTAssertEqual(info.measuredValue, 30, accuracy: 1e-6)
    }

    func testLinearDimensionPicksVerticalAxisWhenPlacementIsMostlyHorizontal() throws {
        let parsed = makeParsed()
        let doc = parsed.document
        var dimId: EntityID!
        // Placement far to the right in X (large vertOffset) -> vertical
        // dimension line, measures |Δy| = 40.
        doc.transact("Dimension") { tx in
            dimId = DimensionTool.create(kind: .linear,
                                        p1: CGPoint(x: 0, y: 0), p2: CGPoint(x: 30, y: 40),
                                        placement: CGPoint(x: 100, y: 20),
                                        layerId: 0, aci: 256, format: MeasureFormat(),
                                        owner: .model, parsed: parsed, tx: tx)
        }
        let id = try XCTUnwrap(dimId)
        let info = try XCTUnwrap(DimensionTool.readMetadata(id, store: doc.store))
        XCTAssertEqual(info.measuredValue, 40, accuracy: 1e-6)
    }

    func testDegenerateZeroLengthPickReturnsNil() {
        let parsed = makeParsed()
        let doc = parsed.document
        var dimId: EntityID?
        doc.transact("Dimension") { tx in
            dimId = DimensionTool.create(kind: .aligned,
                                        p1: CGPoint(x: 5, y: 5), p2: CGPoint(x: 5, y: 5),
                                        placement: CGPoint(x: 10, y: 10),
                                        layerId: 0, aci: 256, format: MeasureFormat(),
                                        owner: .model, parsed: parsed, tx: tx)
        }
        XCTAssertNil(dimId)
    }

    // MARK: - Regenerator round-trip (renders through the anonymous block)

    func testDimensionRendersItsAnonymousBlockGeometryAtWorldPosition() throws {
        let parsed = makeParsed()
        let doc = parsed.document
        doc.transact("Dimension") { tx in
            _ = DimensionTool.create(kind: .aligned,
                                     p1: CGPoint(x: 0, y: 0), p2: CGPoint(x: 100, y: 0),
                                     placement: CGPoint(x: 50, y: 20),
                                     layerId: 0, aci: 256, format: MeasureFormat(),
                                     owner: .model, parsed: parsed, tx: tx)
        }
        let built = Regenerator.build(from: parsed, parseSeconds: 0) { _ in }

        // Must find the dimension line itself (a LINE at y=20, from x=0 to
        // x=100) somewhere in the expanded model-space geometry — proves
        // the DIMENSION -> anonymous block -> Regenerator expansion path
        // (identity placement transform + block.base == .zero) actually
        // renders the member geometry at its authored absolute coordinates.
        var foundDimLine = false
        for g in built.modelGroups {
            for run in g.strokes.runs where run.kind == .line {
                let a = g.strokes.points[Int(run.start)]
                let b = g.strokes.points[Int(run.start) + 1]
                if abs(a.y - 20) < 1e-6, abs(b.y - 20) < 1e-6,
                   min(a.x, b.x) < 1, max(a.x, b.x) > 99 {
                    foundDimLine = true
                }
            }
        }
        XCTAssertTrue(foundDimLine, "the dimension line must render at the computed world-space offset")

        // Must also find the two solid-filled arrowhead triangles.
        var fillRunCount = 0
        for g in built.modelGroups { fillRunCount += g.strokes.fillRuns.count }
        XCTAssertEqual(fillRunCount, 2, "both arrowheads must render as solid fills")

        // And the text label somewhere in the model-space text items.
        var foundLabel = false
        for g in built.modelGroups {
            for t in g.texts where t.text.contains("100") { foundLabel = true }
        }
        XCTAssertTrue(foundLabel, "the measured-value label must render")
    }

    // MARK: - Format metadata round-trip + reformatting

    func testFormatMetadataRoundTripsThroughXData() throws {
        let parsed = makeParsed()
        let doc = parsed.document
        var dimId: EntityID!
        let fmt = MeasureFormat(system: .imperial, style: .architectural, precision: 4)
        doc.transact("Dimension") { tx in
            dimId = DimensionTool.create(kind: .aligned,
                                        p1: CGPoint(x: 0, y: 0), p2: CGPoint(x: 100, y: 0),
                                        placement: CGPoint(x: 50, y: 20),
                                        layerId: 0, aci: 256, format: fmt,
                                        owner: .model, parsed: parsed, tx: tx)
        }
        let id = try XCTUnwrap(dimId)
        let info = try XCTUnwrap(DimensionTool.readMetadata(id, store: doc.store))
        XCTAssertEqual(info.format.system, .imperial)
        XCTAssertEqual(info.format.style, .architectural)
        XCTAssertEqual(info.format.precision, 4)
        XCTAssertEqual(info.measuredValue, 100, accuracy: 1e-6)
    }

    func testSetFormatRewritesLabelTextAndMetadataWithoutMovingGeometry() throws {
        let parsed = makeParsed()
        let doc = parsed.document
        var dimId: EntityID!
        doc.transact("Dimension") { tx in
            dimId = DimensionTool.create(kind: .aligned,
                                        p1: CGPoint(x: 0, y: 0), p2: CGPoint(x: 100, y: 0),
                                        placement: CGPoint(x: 50, y: 20),
                                        layerId: 0, aci: 256, format: MeasureFormat(style: .decimal),
                                        owner: .model, parsed: parsed, tx: tx)
        }
        let id = try XCTUnwrap(dimId)
        let before = try XCTUnwrap(DimensionTool.readMetadata(id, store: doc.store))
        XCTAssertEqual(before.format.style, .decimal)

        var applied = false
        doc.transact("Reformat") { tx in
            applied = DimensionTool.setFormat(id, to: MeasureFormat(style: .fractional, precision: 2),
                                             parsed: parsed, tx: tx)
        }
        XCTAssertTrue(applied)

        let after = try XCTUnwrap(DimensionTool.readMetadata(id, store: doc.store))
        XCTAssertEqual(after.format.style, .fractional)
        // The measured VALUE itself must be unchanged — only the display
        // format changed.
        XCTAssertEqual(after.measuredValue, before.measuredValue, accuracy: 1e-9)

        // The block's TEXT member must show the NEW format's rendering.
        let h = try XCTUnwrap(doc.store.header(id))
        let dp = doc.store.dimensions[Int(h.payload)]
        let blockName = doc.store.strings.string(for: dp.blockNameId)
        let block = try XCTUnwrap(parsed.blocks[blockName])
        var labelText: String?
        for i in Int(block.entityStart)..<Int(block.entityStart + block.entityCount) {
            let mid = EntityID(raw: Int32(i))
            guard let mh = doc.store.header(mid), mh.type == .text else { continue }
            let tp = doc.store.texts[Int(mh.payload)]
            labelText = doc.store.strings.string(for: tp.stringId)
        }
        let expected = MeasureFormat(style: .fractional, precision: 2).length(100)
        XCTAssertEqual(labelText, expected)
    }

    func testSetFormatReturnsFalseForNonNovaCADDimension() throws {
        // A DIMENSION with NO NovaCAD XDATA metadata (e.g. round-tripped
        // from some other source) must not be editable via setFormat.
        let parsed = makeParsed()
        let doc = parsed.document
        var dimId: EntityID!
        doc.transact("Dimension") { tx in
            let nameId = doc.store.strings.intern("*D999")
            dimId = tx.add(EntityPrototype(type: .dimension, layerId: 0, owner: .model,
                                          payload: .dimension(DimensionPayload(blockNameId: nameId,
                                                                               defPoint: Vec3(x: 0, y: 0)))))
        }
        let id = try XCTUnwrap(dimId)
        var applied = true
        doc.transact("Reformat") { tx in
            applied = DimensionTool.setFormat(id, to: MeasureFormat(style: .fractional), parsed: parsed, tx: tx)
        }
        XCTAssertFalse(applied)
    }

    // MARK: - Save + reparse round-trip

    /// Confirms a NovaCAD-authored dimension survives a real DXF
    /// write-to-disk + reparse — proves the anonymous block + DIMENSION
    /// entity are correctly emitted by `DXFStructuralWriter`/
    /// `DXFBlocksEntitiesEmitter`/`EntityRecordWriter.writeDimension` (all
    /// pre-existing writer code this feature deliberately reuses rather
    /// than duplicating) and correctly re-read by `EntityStoreParser`'s
    /// existing DIMENSION/BLOCK parsing.
    func testDimensionSurvivesWriteAndReparse() throws {
        let parsed = makeParsed()
        let doc = parsed.document
        doc.transact("Dimension") { tx in
            _ = DimensionTool.create(kind: .aligned,
                                     p1: CGPoint(x: 0, y: 0), p2: CGPoint(x: 100, y: 0),
                                     placement: CGPoint(x: 50, y: 20),
                                     layerId: 0, aci: 256, format: MeasureFormat(),
                                     owner: .model, parsed: parsed, tx: tx)
        }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("dimension-roundtrip-\(UUID().uuidString).dxf")
        defer { try? FileManager.default.removeItem(at: tmp) }
        _ = try DXFStructuralWriter.write(parsed, to: tmp)

        let reparsed = try PackageLoader.loadIntoStore(url: tmp)
        var reparsedDimId: EntityID?
        for i in reparsed.store.headers.indices {
            let h = reparsed.store.headers[i]
            guard !h.flags.contains(.deleted), h.type == .dimension else { continue }
            reparsedDimId = EntityID(raw: Int32(i))
        }
        let dimId = try XCTUnwrap(reparsedDimId, "the re-parsed file must still contain a DIMENSION entity")

        let h = try XCTUnwrap(reparsed.store.header(dimId))
        let dp = reparsed.store.dimensions[Int(h.payload)]
        let blockName = reparsed.store.strings.string(for: dp.blockNameId)
        let block = try XCTUnwrap(reparsed.blocks[blockName], "the anonymous dimension block must also round-trip")
        XCTAssertGreaterThan(block.entityCount, 0)

        // The dimension still renders at the right world position after
        // the full write -> reparse -> regen cycle.
        let built = Regenerator.build(from: reparsed, parseSeconds: 0) { _ in }
        var foundDimLine = false
        for g in built.modelGroups {
            for run in g.strokes.runs where run.kind == .line {
                let a = g.strokes.points[Int(run.start)]
                let b = g.strokes.points[Int(run.start) + 1]
                if abs(a.y - 20) < 1e-6, abs(b.y - 20) < 1e-6,
                   min(a.x, b.x) < 1, max(a.x, b.x) > 99 {
                    foundDimLine = true
                }
            }
        }
        XCTAssertTrue(foundDimLine, "the re-parsed dimension must still render at its original world position")
    }

    // MARK: - Undo

    func testCreateDimensionIsFullyUndoable() throws {
        let parsed = makeParsed()
        let doc = parsed.document
        var dimId: EntityID!
        doc.transact("Dimension") { tx in
            dimId = DimensionTool.create(kind: .aligned,
                                        p1: CGPoint(x: 0, y: 0), p2: CGPoint(x: 100, y: 0),
                                        placement: CGPoint(x: 50, y: 20),
                                        layerId: 0, aci: 256, format: MeasureFormat(),
                                        owner: .model, parsed: parsed, tx: tx)
        }
        let id = try XCTUnwrap(dimId)
        let h = try XCTUnwrap(doc.store.header(id))
        let dp = doc.store.dimensions[Int(h.payload)]
        let blockName = doc.store.strings.string(for: dp.blockNameId)
        XCTAssertNotNil(parsed.blocks[blockName])

        doc.undo()
        XCTAssertTrue(doc.store.isDeleted(id))
        // The block-table registration side-effect must also be undone —
        // otherwise a dangling block definition survives pointing at
        // entirely tombstoned entities.
        XCTAssertNil(parsed.blocks[blockName])

        doc.redo()
        XCTAssertFalse(doc.store.isDeleted(id))
        XCTAssertNotNil(parsed.blocks[blockName])
    }
}
