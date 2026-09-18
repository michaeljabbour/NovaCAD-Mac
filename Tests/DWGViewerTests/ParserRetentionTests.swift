import XCTest
@testable import DWGViewer
import CADCore

/// Verifies the NEW eager `EntityStoreParser` + `Regenerator` path (Phase
/// 1.2/1.3) against the existing fixtures and the OLD `DXFParser`/
/// `GeometryBuilder` path it must match: entity counts, handle round-
/// tripping, layer-0-in-block inheritance, hatch fills, and the retention
/// additions (Z coordinates, XDATA) this phase adds on top of the parser's
/// existing entity-type coverage.
final class ParserRetentionTests: XCTestCase {

    // MARK: - Entity counts match the old path, per fixture

    func testBasicEntitiesFixtureEntityCountMatchesOldPath() throws {
        let oldDoc = try PackageLoader.load(url: TestFixtures.url("basic_entities.dxf"))
        let parsed = try EntityStoreParser.parse(url: TestFixtures.url("basic_entities.dxf"))
        // Old path counts post-expansion entities; for a fixture with no
        // block INSERTs, that equals the raw parsed entity count, so the
        // store's raw count should match `stats.totalEntities` directly.
        XCTAssertEqual(parsed.store.count, oldDoc.stats.totalEntities)
    }

    func testBlockInsertFixtureEntityCountMatchesOldPath() throws {
        // Old path's stats.totalEntities is POST-expansion (the block's LINE
        // + CIRCLE counted once for the one INSERT); the new path's raw
        // store count is PRE-expansion (LINE + CIRCLE in the block def, plus
        // the INSERT entity itself) — compare against the Regenerator's own
        // post-expansion stats instead, which is the number that must match.
        let oldDoc = try PackageLoader.load(url: TestFixtures.url("block_insert.dxf"))
        let parsed = try EntityStoreParser.parse(url: TestFixtures.url("block_insert.dxf"))
        let newDoc = Regenerator.build(from: parsed, parseSeconds: 0) { _ in }
        XCTAssertEqual(newDoc.stats.totalEntities, oldDoc.stats.totalEntities)
    }

    func testHatchFixtureEntityCountMatchesOldPath() throws {
        let oldDoc = try PackageLoader.load(url: TestFixtures.url("hatch_rect.dxf"))
        let parsed = try EntityStoreParser.parse(url: TestFixtures.url("hatch_rect.dxf"))
        let newDoc = Regenerator.build(from: parsed, parseSeconds: 0) { _ in }
        XCTAssertEqual(newDoc.stats.totalEntities, oldDoc.stats.totalEntities)
    }

    // MARK: - Handles: non-zero, unique, round-trip via entity(forHandle:)

    func testHandlesAreNonZeroUniqueAndRoundTrip() throws {
        for name in ["basic_entities.dxf", "block_insert.dxf", "hatch_rect.dxf", "z_and_xdata.dxf"] {
            let parsed = try EntityStoreParser.parse(url: TestFixtures.url(name))
            let store = parsed.store
            var seen = Set<UInt64>()
            for h in store.headers {
                XCTAssertNotEqual(h.handle, 0, "\(name): every entity in a real DXF file carries a handle (group code 5)")
                XCTAssertFalse(seen.contains(h.handle), "\(name): handles must be unique within a document")
                seen.insert(h.handle)
            }
            // Round-trip: forHandle(_:) resolves back to the exact same slot.
            for i in store.headers.indices {
                let id = EntityID(raw: Int32(i))
                let handle = store.headers[i].handle
                XCTAssertEqual(store.entity(forHandle: handle), id, "\(name): handle round-trip mismatch")
            }
        }
    }

    func testHandleRoundTripOnExplicitHandleFixture() throws {
        let parsed = try EntityStoreParser.parse(url: TestFixtures.url("z_and_xdata.dxf"))
        let store = parsed.store
        let lineHandle = UInt64(0x2A1)
        let circleHandle = UInt64(0x2A2)
        let lineID = try XCTUnwrap(store.entity(forHandle: lineHandle))
        let circleID = try XCTUnwrap(store.entity(forHandle: circleHandle))
        XCTAssertEqual(store.header(lineID)?.type, .line)
        XCTAssertEqual(store.header(circleID)?.type, .circle)
        XCTAssertNil(store.entity(forHandle: 0xDEAD_BEEF), "an unassigned handle must not resolve to any entity")
    }

    // MARK: - Z coordinate retention (does not disturb 2D projection)

    func testZCoordinatesAreRetainedOnLineAndCircle() throws {
        let parsed = try EntityStoreParser.parse(url: TestFixtures.url("z_and_xdata.dxf"))
        let store = parsed.store
        let lineID = try XCTUnwrap(store.entity(forHandle: 0x2A1))
        let lineHeader = try XCTUnwrap(store.header(lineID))
        let line = store.lines[Int(lineHeader.payload)]
        XCTAssertEqual(line.a, Vec3(x: 0, y: 0, z: 5))
        XCTAssertEqual(line.b, Vec3(x: 10, y: 0, z: 15))

        let circleID = try XCTUnwrap(store.entity(forHandle: 0x2A2))
        let circleHeader = try XCTUnwrap(store.header(circleID))
        let circle = store.circles[Int(circleHeader.payload)]
        XCTAssertEqual(circle.center, Vec3(x: 20, y: 20, z: 7.5))
        XCTAssertEqual(circle.radius, 3.0)
    }

    /// Z retention must not perturb the 2D pipeline: the Regenerator's
    /// world-space projection is XY-only, so a snapshot of this Z-bearing
    /// fixture must show the same 2D geometry (line from (0,0) to (10,0),
    /// circle at (20,20) r=3) regardless of the entities' Z values.
    func testZCoordinatesDoNotAffect2DBounds() throws {
        let parsed = try EntityStoreParser.parse(url: TestFixtures.url("z_and_xdata.dxf"))
        let doc = Regenerator.build(from: parsed, parseSeconds: 0) { _ in }
        // fullBounds must reflect XY only: x in [0, 23] (circle right edge
        // 20+3), y in [0, 23] (circle top edge 20+3) — no Z leaking into the
        // 2D projection.
        XCTAssertEqual(doc.modelBounds.minX, 0, accuracy: 1e-9)
        XCTAssertEqual(doc.modelBounds.minY, 0, accuracy: 1e-9)
        XCTAssertEqual(doc.modelBounds.maxX, 23, accuracy: 1e-9)
        XCTAssertEqual(doc.modelBounds.maxY, 23, accuracy: 1e-9)
    }

    // MARK: - XDATA round-trip

    func testXDataRoundTrip() throws {
        let parsed = try EntityStoreParser.parse(url: TestFixtures.url("z_and_xdata.dxf"))
        let store = parsed.store
        let lineID = try XCTUnwrap(store.entity(forHandle: 0x2A1))
        let header = try XCTUnwrap(store.header(lineID))
        XCTAssertTrue(header.flags.contains(.hasXData))
        let blob = try XCTUnwrap(store.xdata[lineID.raw])
        XCTAssertEqual(blob.appId, "NOVACAD_TEST")
        XCTAssertEqual(blob.pairs.count, 3)
        XCTAssertEqual(blob.pairs[0].code, 1000)
        if case .string(let s) = blob.pairs[0].value { XCTAssertEqual(s, "hello") }
        else { XCTFail("expected .string XDATA value for code 1000") }
        XCTAssertEqual(blob.pairs[1].code, 1040)
        if case .double(let d) = blob.pairs[1].value { XCTAssertEqual(d, 3.5) }
        else { XCTFail("expected .double XDATA value for code 1040") }
        XCTAssertEqual(blob.pairs[2].code, 1070)
        if case .int(let i) = blob.pairs[2].value { XCTAssertEqual(i, 42) }
        else { XCTFail("expected .int XDATA value for code 1070") }

        // The circle has no XDATA — must not have an entry or the flag set.
        let circleID = try XCTUnwrap(store.entity(forHandle: 0x2A2))
        XCTAssertNil(store.xdata[circleID.raw])
        XCTAssertFalse(store.header(circleID)!.flags.contains(.hasXData))
    }

    // MARK: - Layer-0-in-block inheritance (load-bearing; GeometryBuilder/Regenerator parity)

    func testBlockInsertLayerZeroInheritanceMatchesOldPath() throws {
        let parsed = try EntityStoreParser.parse(url: TestFixtures.url("block_insert.dxf"))
        let doc = Regenerator.build(from: parsed, parseSeconds: 0) { _ in }
        XCTAssertEqual(doc.inserts.count, 1)
        let insert = try XCTUnwrap(doc.inserts.first)
        XCTAssertEqual(insert.name, "SYMBOL1")
        XCTAssertEqual(insert.scaleX, 2.0)
        XCTAssertEqual(insert.rotationDegrees, 45.0)

        // The block's LINE + CIRCLE (both on layer "0" inside the block
        // definition) must appear tagged with the INSERT's layer (SYMBOLS),
        // not layer "0" — the same assertion FixtureLoadTests makes against
        // the OLD path, now against the NEW path's regenerated output.
        let symbolsLayerId = try XCTUnwrap(doc.layers.first { $0.name == "SYMBOLS" }?.id)
        let group = try XCTUnwrap(doc.modelGroups.first { $0.layerId == symbolsLayerId })
        XCTAssertGreaterThanOrEqual(group.strokes.runs.count, 1)
        XCTAssertGreaterThanOrEqual(group.strokes.arcs.count, 1)

        // Every emitted primitive in this group carries a stable entityId
        // (Work Package 2's requirement) — for expanded block content that's
        // the top-level INSERT's own EntityID, mirroring `insertId`.
        for run in group.strokes.runs {
            XCTAssertGreaterThanOrEqual(run.entityId, 0, "expanded block content must carry a stable entityId")
        }
        for arc in group.strokes.arcs {
            XCTAssertGreaterThanOrEqual(arc.entityId, 0, "expanded block content must carry a stable entityId")
        }
    }

    // MARK: - Hatch still produces a fillable path

    func testHatchFixtureProducesFillableFillPath() throws {
        let parsed = try EntityStoreParser.parse(url: TestFixtures.url("hatch_rect.dxf"))
        let doc = Regenerator.build(from: parsed, parseSeconds: 0) { _ in }
        XCTAssertEqual(doc.modelGroups.count, 1)
        let g = doc.modelGroups[0]
        XCTAssertFalse(g.fillPath.isEmpty, "solid HATCH must produce a fillable path")
        XCTAssertFalse(g.strokes.fillRuns.isEmpty, "boundary must be retained for hit-testing")
    }

    // MARK: - Pixel parity end-to-end (old PackageLoader path vs new EntityStoreParser+Regenerator path)

    func testNewPathProducesIdenticalBoundsToOldPathAcrossAllFixtures() throws {
        for name in ["basic_entities.dxf", "block_insert.dxf", "hatch_rect.dxf", "z_and_xdata.dxf"] {
            let oldDoc = try PackageLoader.load(url: TestFixtures.url(name))
            let parsed = try EntityStoreParser.parse(url: TestFixtures.url(name))
            let newDoc = Regenerator.build(from: parsed, parseSeconds: 0) { _ in }
            XCTAssertEqual(newDoc.modelBounds, oldDoc.modelBounds, "modelBounds mismatch for \(name)")
            XCTAssertEqual(newDoc.paperBounds, oldDoc.paperBounds, "paperBounds mismatch for \(name)")
            XCTAssertEqual(newDoc.modelGroups.count, oldDoc.modelGroups.count, "model group count mismatch for \(name)")
            XCTAssertEqual(newDoc.paperGroups.count, oldDoc.paperGroups.count, "paper group count mismatch for \(name)")
        }
    }
}
