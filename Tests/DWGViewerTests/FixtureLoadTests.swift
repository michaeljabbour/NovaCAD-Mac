import XCTest
@testable import DWGViewer
import CADCore

/// Smoke tests proving the SwiftPM test target + fixture wiring works
/// end-to-end, and pinning today's parser/geometry-builder behavior on a
/// small hand-authored fixture set. Grows with each later phase.
final class FixtureLoadTests: XCTestCase {

    func testBasicEntitiesFixtureLoads() throws {
        let doc = try PackageLoader.load(url: TestFixtures.url("basic_entities.dxf"))
        XCTAssertEqual(doc.layers.count, 1)
        XCTAssertEqual(doc.modelGroups.count, 1, "single layer/color/linetype -> one render group")
        let g = doc.modelGroups[0]

        // LINE + ARC + LWPOLYLINE(4 verts, one bulge -> extra tessellated points)
        // all land in `runs`; CIRCLE + the bulge corner become analytic `arcs`.
        XCTAssertEqual(g.strokes.runs.count, 2, "LINE run + LWPOLYLINE run")
        XCTAssertGreaterThanOrEqual(g.strokes.arcs.count, 2, "CIRCLE + ARC (+ possibly the bulge)")
        XCTAssertEqual(g.texts.count, 1)
        XCTAssertEqual(g.points.count, 1)
        XCTAssertEqual(g.texts.first?.text, "FIXTURE")
    }

    func testBlockInsertFixtureExpandsGeometry() throws {
        let doc = try PackageLoader.load(url: TestFixtures.url("block_insert.dxf"))
        XCTAssertEqual(doc.inserts.count, 1)
        let insert = try XCTUnwrap(doc.inserts.first)
        XCTAssertEqual(insert.name, "SYMBOL1")
        XCTAssertEqual(insert.scaleX, 2.0)
        XCTAssertEqual(insert.rotationDegrees, 45.0)

        // The block's LINE + CIRCLE must appear as expanded geometry tagged
        // with this insert's id, on the INSERT's layer (SYMBOLS) even though
        // both entities live on layer 0 inside the block definition —
        // load-bearing layer-0-in-block inheritance (GeometryBuilder.swift).
        let symbolsLayerId = try XCTUnwrap(doc.layers.first { $0.name == "SYMBOLS" }?.id)
        let group = try XCTUnwrap(doc.modelGroups.first { $0.layerId == symbolsLayerId })
        XCTAssertGreaterThanOrEqual(group.strokes.runs.count, 1)
        XCTAssertGreaterThanOrEqual(group.strokes.arcs.count, 1)
    }

    func testHatchFixtureProducesFill() throws {
        let doc = try PackageLoader.load(url: TestFixtures.url("hatch_rect.dxf"))
        XCTAssertEqual(doc.modelGroups.count, 1)
        let g = doc.modelGroups[0]
        XCTAssertFalse(g.fillPath.isEmpty, "solid HATCH must produce a fillable path")
        XCTAssertFalse(g.strokes.fillRuns.isEmpty, "boundary must be retained for hit-testing")
    }
}
