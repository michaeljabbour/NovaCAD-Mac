import XCTest
@testable import DWGViewer

/// Phase 6.3: REGION (fallback scope) tests.
final class RegionToolTests: XCTestCase {

    private func makeStore() -> EntityStore { EntityStore() }

    func testMakeRegionFromClosedPolylineComputesShoelaceArea() throws {
        let store = makeStore()
        // A 10x4 rectangle: area 40, perimeter 28.
        let verts = [Vec3(x: 0, y: 0), Vec3(x: 10, y: 0), Vec3(x: 10, y: 4), Vec3(x: 0, y: 4)]
        let proto = EntityPrototype(type: .lwpolyline, layerId: 0,
                                    payload: .polyline(PolylinePayload(closed: true), vertices: verts,
                                                       bulges: [0, 0, 0, 0]))
        let id = store.append(proto)
        let region = try XCTUnwrap(RegionTool.makeRegion(from: id, store: store))
        XCTAssertEqual(abs(region.area), 40, accuracy: 1e-6)
        XCTAssertEqual(region.perimeter, 28, accuracy: 1e-6)
    }

    func testMakeRegionRejectsOpenPolyline() {
        let store = makeStore()
        let verts = [Vec3(x: 0, y: 0), Vec3(x: 10, y: 0), Vec3(x: 10, y: 4)]
        let proto = EntityPrototype(type: .lwpolyline, layerId: 0,
                                    payload: .polyline(PolylinePayload(closed: false), vertices: verts,
                                                       bulges: [0, 0, 0]))
        let id = store.append(proto)
        XCTAssertNil(RegionTool.makeRegion(from: id, store: store))
    }

    func testMakeRegionFromCircleComputesPiRSquared() throws {
        let store = makeStore()
        let proto = EntityPrototype(type: .circle, layerId: 0,
                                    payload: .circle(CirclePayload(center: Vec3(x: 0, y: 0), radius: 5)))
        let id = store.append(proto)
        let region = try XCTUnwrap(RegionTool.makeRegion(from: id, store: store))
        XCTAssertEqual(region.area, .pi * 25, accuracy: 1e-6)
        XCTAssertEqual(region.perimeter, 2 * .pi * 5, accuracy: 1e-6)
    }

    func testMakeRegionFromFullSweepEllipseComputesPiAB() throws {
        let store = makeStore()
        let proto = EntityPrototype(type: .ellipse, layerId: 0,
                                    payload: .ellipse(EllipsePayload(center: Vec3(x: 0, y: 0),
                                                                     majorAxisEndpoint: Vec3(x: 10, y: 0),
                                                                     ratio: 0.5, startParam: 0, endParam: 2 * .pi)))
        let id = store.append(proto)
        let region = try XCTUnwrap(RegionTool.makeRegion(from: id, store: store))
        // major=10, minor=5 -> area = pi*10*5 = 50pi.
        XCTAssertEqual(region.area, .pi * 50, accuracy: 1e-6)
    }

    func testMakeRegionRejectsPartialEllipticalArc() {
        let store = makeStore()
        let proto = EntityPrototype(type: .ellipse, layerId: 0,
                                    payload: .ellipse(EllipsePayload(center: Vec3(x: 0, y: 0),
                                                                     majorAxisEndpoint: Vec3(x: 10, y: 0),
                                                                     ratio: 0.5, startParam: 0, endParam: .pi)))
        let id = store.append(proto)
        XCTAssertNil(RegionTool.makeRegion(from: id, store: store))
    }

    func testMakeRegionRejectsUnsupportedEntityType() {
        let store = makeStore()
        let proto = EntityPrototype(type: .line, layerId: 0,
                                    payload: .line(LinePayload(a: Vec3(x: 0, y: 0), b: Vec3(x: 1, y: 1))))
        let id = store.append(proto)
        XCTAssertNil(RegionTool.makeRegion(from: id, store: store))
    }

    func testTagAsRegionXDataAddsMarkerOnceAndIsIdempotent() throws {
        let store = makeStore()
        let proto = EntityPrototype(type: .circle, layerId: 0,
                                    payload: .circle(CirclePayload(center: Vec3(x: 0, y: 0), radius: 1)))
        let id = store.append(proto)
        RegionTool.tagAsRegionXData(id, store: store)
        RegionTool.tagAsRegionXData(id, store: store)   // idempotent — no duplicate pair
        let blob = try XCTUnwrap(store.xdata[id.raw])
        let markerCount = blob.pairs.filter {
            if case .string(let s) = $0.value { return s.hasPrefix("REGION") }
            return false
        }.count
        XCTAssertEqual(markerCount, 1)
    }
}
