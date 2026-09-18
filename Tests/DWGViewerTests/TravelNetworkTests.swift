import XCTest
@testable import DWGViewer
import CoreGraphics
import CADCore

/// Covers `TravelNetwork` — the centerline-derived, self-repairing routing
/// graph behind the AI Assistant's travel-distance tools.
///
/// The headline case is `testBoundaryLineRoutingInflatesDistance`, which
/// reproduces the reported "estimates were almost double the expected
/// results" defect on a synthetic corridor pair and proves `.auto` mode fixes
/// it. Everything else guards the pieces that make that work on real,
/// imperfect drawings.
final class TravelNetworkTests: XCTestCase {

    private func seg(_ ax: Double, _ ay: Double, _ bx: Double, _ by: Double) -> AisleNetwork.Segment {
        AisleNetwork.Segment(a: CGPoint(x: ax, y: ay), b: CGPoint(x: bx, y: by))
    }

    // MARK: - The doubling defect

    /// Two perpendicular aisles drawn as BOUNDARY EDGE PAIRS (the real-world
    /// shape: each aisle is two parallel lines 160 units / 13'-4" apart),
    /// forming a cross.
    ///
    /// Routing the raw edge lines cannot cut through the intersection and
    /// cannot change sides mid-aisle, so it detours. Routing derived
    /// centerlines goes straight through. This is the mechanism behind the
    /// reported ~2x inflation.
    private func crossingAislesAsBoundaryPairs() -> [AisleNetwork.Segment] {
        let half = 80.0   // 160-unit (13'-4") aisle, half-width
        let span = 4000.0
        return [
            // Horizontal aisle centred on y = 0: two edges at y = ±80.
            seg(-span, half, span, half),
            seg(-span, -half, span, -half),
            // Vertical aisle centred on x = 0: two edges at x = ±80.
            seg(-half, -span, -half, span),
            seg(half, -span, half, span),
        ]
    }

    func testBoundaryLineRoutingInflatesDistance() {
        // A destination on the OPPOSITE SIDE of the aisle from the origin.
        // This is the decisive case: with only edge lines in the graph there
        // is no way to cross the aisle except by travelling to a place where
        // the two edges join, so the trip becomes an out-and-back. With a
        // centerline it is a short hop.
        let raw = crossingAislesAsBoundaryPairs()
        let origin = CGPoint(x: -3000, y: 200)        // north of the horizontal aisle
        let destination = CGPoint(x: -2800, y: -200)  // south of it, nearly opposite

        let rawNet = TravelNetwork.prepare(rawSegments: raw, mode: .raw, autoRepairFeet: 0)
        let autoNet = TravelNetwork.prepare(rawSegments: raw, mode: .auto, autoRepairFeet: 0)

        guard case .success(let rawTrip) = TravelNetwork.measure(from: origin, to: destination, in: rawNet) else {
            return XCTFail("raw-mode routing should still produce some path")
        }
        guard case .success(let autoTrip) = TravelNetwork.measure(from: origin, to: destination, in: autoNet) else {
            return XCTFail("centerline routing should succeed")
        }

        XCTAssertGreaterThan(rawTrip.oneWayFeet, autoTrip.oneWayFeet * 1.5,
                             "routing boundary edges must detour badly when crossing to the other side of an aisle")
        let direct = TravelNetwork.directFeet(from: origin, to: destination)
        XCTAssertLessThan(autoTrip.oneWayFeet, direct * 2.0,
                          "centerline routing should stay close to the straight-line distance here")

        print(String(format: "cross-aisle trip: direct=%.0f ft, raw=%.0f ft, centerline=%.0f ft (inflation %.2fx)",
                     direct, rawTrip.oneWayFeet, autoTrip.oneWayFeet,
                     rawTrip.oneWayFeet / autoTrip.oneWayFeet))
    }

    /// The infinite loop that made `repair` never return on the real
    /// reference layout: a gap whose bridge is degenerate (both ends
    /// quantizing to one node) was counted as applied while leaving the
    /// segment set unchanged, so the same gap was re-found forever.
    func testRepairTerminatesOnDegenerateBridges() {
        // Many pieces separated by sub-quantum gaps — every candidate bridge
        // is degenerate.
        var segments: [AisleNetwork.Segment] = []
        for i in 0..<60 {
            let x = Double(i) * 100
            segments.append(seg(x, 0, x + 99.9, 0))
        }
        let expectation = XCTestExpectation(description: "repair returns")
        DispatchQueue.global().async {
            _ = AisleNetwork.repair(segments: segments, autoBridgeUpTo: 25 * 12)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 20)
    }

    func testRepairIsBoundedByMaxPasses() {
        // A long chain of separated pieces: repair must converge, not spin.
        var segments: [AisleNetwork.Segment] = []
        for i in 0..<40 {
            let x = Double(i) * 1100
            segments.append(seg(x, 0, x + 1000, 0))
        }
        let result = AisleNetwork.repair(segments: segments, autoBridgeUpTo: 25 * 12)
        XCTAssertEqual(result.after.components.count, 1, "the whole chain should reconnect")
        XCTAssertFalse(result.applied.isEmpty)
    }

    func testCenterlineDerivationCollapsesBoundaryPairs() {
        let prepared = TravelNetwork.prepare(rawSegments: crossingAislesAsBoundaryPairs(),
                                             mode: .auto, autoRepairFeet: 0)
        XCTAssertEqual(prepared.collapsedPairCount, 2, "both aisles should collapse to one centerline each")
        XCTAssertEqual(prepared.mode, .auto)
        XCTAssertTrue(prepared.diagnostics.contains("collapsed into single centerlines"))
    }

    // MARK: - Trip type

    func testRoundTripIsExactlyTwiceOneWay() {
        let prepared = TravelNetwork.prepare(rawSegments: crossingAislesAsBoundaryPairs(),
                                             mode: .auto, autoRepairFeet: 0)
        guard case .success(let trip) = TravelNetwork.measure(from: CGPoint(x: -4000, y: 0),
                                                              to: CGPoint(x: 0, y: 4000),
                                                              in: prepared) else {
            return XCTFail("expected a route")
        }
        XCTAssertEqual(trip.roundTripFeet, trip.oneWayFeet * 2, accuracy: 0.001)
        XCTAssertEqual(trip.feet(for: .oneWay), trip.oneWayFeet, accuracy: 0.001)
        XCTAssertEqual(trip.feet(for: .roundTrip), trip.roundTripFeet, accuracy: 0.001)
    }

    func testTripTypeParsingAcceptsNaturalPhrasing() {
        XCTAssertEqual(TravelNetwork.TripType.parse("round trip"), .roundTrip)
        XCTAssertEqual(TravelNetwork.TripType.parse("round_trip"), .roundTrip)
        XCTAssertEqual(TravelNetwork.TripType.parse("RoundTrip"), .roundTrip)
        XCTAssertEqual(TravelNetwork.TripType.parse("one-way"), .oneWay)
        XCTAssertEqual(TravelNetwork.TripType.parse("oneWay"), .oneWay)
        XCTAssertNil(TravelNetwork.TripType.parse("banana"))
        XCTAssertNil(TravelNetwork.TripType.parse(nil))
    }

    // MARK: - Fragmented / imperfect drawings

    func testAutoRepairReconnectsFragmentedNetwork() {
        // One straight aisle drawn as three pieces with small drafting gaps.
        let broken = [
            seg(0, 0, 1000, 0),
            seg(1060, 0, 2000, 0),     // 60-unit (5 ft) gap
            seg(2090, 0, 3000, 0),     // 90-unit (7.5 ft) gap
        ]
        let unrepaired = TravelNetwork.prepare(rawSegments: broken, mode: .auto, autoRepairFeet: 0)
        XCTAssertGreaterThan(unrepaired.componentsAfter, 1, "gaps should leave the network fragmented")

        let repaired = TravelNetwork.prepare(rawSegments: broken, mode: .auto, autoRepairFeet: 25)
        XCTAssertEqual(repaired.componentsAfter, 1, "both small gaps should be bridged")
        XCTAssertEqual(repaired.bridges.count, 2)

        guard case .success(let trip) = TravelNetwork.measure(from: CGPoint(x: 0, y: 0),
                                                              to: CGPoint(x: 3000, y: 0),
                                                              in: repaired) else {
            return XCTFail("repaired network should route end to end")
        }
        XCTAssertEqual(trip.oneWayFeet, 3000 / TravelNetwork.inchesPerFoot, accuracy: 1)
    }

    func testLargeSeparationsAreNotBridged() {
        // A genuine physical separation (a wall) must NOT be auto-joined.
        let split = [
            seg(0, 0, 1000, 0),
            seg(20_000, 0, 21_000, 0),
        ]
        let prepared = TravelNetwork.prepare(rawSegments: split, mode: .auto, autoRepairFeet: 25)
        XCTAssertEqual(prepared.componentsAfter, 2, "a wall-scale separation must stay separate")
        XCTAssertTrue(prepared.bridges.isEmpty)
        XCTAssertFalse(prepared.deferredGaps.isEmpty)

        let result = TravelNetwork.measure(from: CGPoint(x: 0, y: 0),
                                           to: CGPoint(x: 21_000, y: 0), in: prepared)
        guard case .failure(let failure) = result else {
            return XCTFail("routing across a wall should fail honestly, not invent a path")
        }
        if case .disconnected = failure {} else { XCTFail("expected a disconnected failure") }
    }

    func testEmptyNetworkIsHandledGracefully() {
        let prepared = TravelNetwork.prepare(rawSegments: [], mode: .auto)
        XCTAssertTrue(prepared.isEmpty)
        let result = TravelNetwork.measure(from: .zero, to: CGPoint(x: 10, y: 10), in: prepared)
        guard case .failure(.emptyNetwork) = result else {
            return XCTFail("expected emptyNetwork")
        }
    }

    func testPureCenterlineLayerIsNotDestroyedByDerivation() {
        // A layer that is ALREADY clean centerlines has no boundary pairs to
        // collapse; derivation must fall back to the raw geometry rather than
        // routing an empty graph.
        let clean = [seg(0, 0, 5000, 0), seg(2500, 0, 2500, 5000)]
        let prepared = TravelNetwork.prepare(rawSegments: clean, mode: .auto, autoRepairFeet: 0)
        XCTAssertFalse(prepared.isEmpty)
        guard case .success(let trip) = TravelNetwork.measure(from: CGPoint(x: 0, y: 0),
                                                              to: CGPoint(x: 2500, y: 5000),
                                                              in: prepared) else {
            return XCTFail("clean centerline layer should route")
        }
        XCTAssertEqual(trip.oneWayFeet, 7500 / TravelNetwork.inchesPerFoot, accuracy: 1)
    }

    func testDeduplicateCollinearRemovesRedundantParallelCenterlines() {
        let duplicated = [
            seg(0, 0, 1000, 0),
            seg(0, 1, 1000, 1),        // 1 unit apart — same physical aisle
            seg(0, 500, 1000, 500),    // genuinely separate aisle
        ]
        let kept = TravelNetwork.deduplicateCollinear(duplicated)
        XCTAssertEqual(kept.count, 2, "near-coincident duplicates collapse; distinct aisles survive")
    }

    // MARK: - Anchors

    func testNearestEdgeAnchorBeatsCentroidForLargeFootprints() {
        // A large marketplace footprint beside an aisle running along y = 0.
        let network = [seg(-5000, 0, 5000, 0)]
        let footprint = CGRect(x: 1000, y: 500, width: 2000, height: 2000)
        let edge = TravelNetwork.anchorPoint(for: footprint, insertionPoint: .zero,
                                             anchor: .nearestEdge, network: network)
        let centroid = TravelNetwork.anchorPoint(for: footprint, insertionPoint: .zero,
                                                 anchor: .centroid, network: network)
        XCTAssertEqual(Double(edge.y), 500, accuracy: 1, "edge anchor sits on the footprint side facing the aisle")
        XCTAssertEqual(Double(centroid.y), 1500, accuracy: 1)
        XCTAssertLessThan(abs(edge.y), abs(centroid.y),
                          "edge anchor must be closer to the aisle than the centroid")
    }

    func testInsertionPointAnchorIsHonored() {
        let network = [seg(-100, 0, 100, 0)]
        let datum = CGPoint(x: 42, y: 99)
        let p = TravelNetwork.anchorPoint(for: CGRect(x: 0, y: 0, width: 10, height: 10),
                                          insertionPoint: datum, anchor: .insertionPoint, network: network)
        XCTAssertEqual(p, datum)
    }

    func testAnchorParsingAcceptsNaturalPhrasing() {
        XCTAssertEqual(TravelNetwork.Anchor.parse("nearest edge"), .nearestEdge)
        XCTAssertEqual(TravelNetwork.Anchor.parse("centroid"), .centroid)
        XCTAssertEqual(TravelNetwork.Anchor.parse("center"), .centroid)
        XCTAssertEqual(TravelNetwork.Anchor.parse("insertionPoint"), .insertionPoint)
        XCTAssertNil(TravelNetwork.Anchor.parse("nonsense"))
    }

    // MARK: - Diagnostics

    func testDiagnosticsReportRepairsAndMode() {
        let broken = [seg(0, 0, 1000, 0), seg(1060, 0, 2000, 0)]
        let prepared = TravelNetwork.prepare(rawSegments: broken, mode: .auto, autoRepairFeet: 25)
        let text = prepared.diagnostics
        XCTAssertTrue(text.contains("Graph mode: auto"))
        XCTAssertTrue(text.contains("Repaired in memory"))
        XCTAssertTrue(text.contains("drawing is unchanged"))
    }

    func testDirectFeetSanityCheck() {
        let d = TravelNetwork.directFeet(from: .zero, to: CGPoint(x: 120, y: 0))
        XCTAssertEqual(d, 10, accuracy: 0.001, "120 inches is 10 feet")
    }
}

// MARK: - Real reference layout

/// Measures the raw-vs-centerline difference on the ACTUAL production layout,
/// so the fix is validated against real drafting practice rather than only
/// synthetic fixtures. Skips when the fixture isn't present.
final class RealTravelNetworkValidationTests: XCTestCase {
    private var fixtureURL: URL? {
        guard let path = ProcessInfo.processInfo.environment["NOVACAD_SAMPLE_LAYOUT"] else { return nil }
        return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    func testRealLayoutCenterlineDerivationReducesRoutedDistance() throws {
        guard let url = fixtureURL else { throw XCTSkip("reference layout not present") }
        let rc = try RegenCoordinator.load(url: url)

        let rawNet = TravelNetwork.prepare(layerNames: ["AISLE"], document: rc.document,
                                           space: .model, visibility: nil,
                                           mode: .raw, autoRepairFeet: 25)
        let autoNet = TravelNetwork.prepare(layerNames: ["AISLE"], document: rc.document,
                                            space: .model, visibility: nil,
                                            mode: .auto, autoRepairFeet: 25)

        print("=== REAL FILE: travel network derivation ===")
        print("--- raw mode ---")
        print(rawNet.diagnostics)
        print("--- auto (centerline) mode ---")
        print(autoNet.diagnostics)

        XCTAssertGreaterThan(autoNet.collapsedPairCount, 50,
                             "the real aisle layer should yield many boundary pairs")
        XCTAssertLessThan(autoNet.componentsAfter, autoNet.componentsBefore / 4,
                          "in-memory repair should substantially reconnect the fragmented network")

        // Sample real endpoints ON the network (rather than arbitrary
        // bounding-box coordinates, which land in unreachable pockets), so
        // both modes measure the same physical trips.
        //
        // The decisive metric is the DETOUR RATIO: routed distance divided by
        // straight-line distance. On an open plant floor a sane aisle network
        // yields roughly 1.2-1.5x. Routing boundary edge lines inflates this
        // because it cannot cut through intersections or change sides
        // mid-aisle — which is the reported "almost double" defect.
        let anchors = stride(from: 0, to: autoNet.segments.count, by: max(1, autoNet.segments.count / 40))
            .map { autoNet.segments[$0].a }
        var pairs: [(CGPoint, CGPoint)] = []
        var i = 0
        while i + 1 < anchors.count && pairs.count < 20 {
            pairs.append((anchors[i], anchors[anchors.count - 1 - i]))
            i += 1
        }

        // Aggregate totals rather than a mean of per-trip ratios: a short
        // trip has an inherently high ratio (the fixed cost of reaching the
        // aisle at all is a large fraction of a 100 ft journey), so averaging
        // raw ratios over-weights exactly the trips that matter least.
        // Summing distances weights each trip by its length, which is also
        // how a real material-flow total is computed.
        var autoRoutedTotal = 0.0, autoDirectTotal = 0.0, autoRoutable = 0
        var rawRoutedTotal = 0.0, rawDirectTotal = 0.0, rawRoutable = 0
        var headToHead: [Double] = []

        for pair in pairs {
            let direct = TravelNetwork.directFeet(from: pair.0, to: pair.1)
            guard direct > 50 else { continue }
            guard case .success(let a) = TravelNetwork.measure(from: pair.0, to: pair.1, in: autoNet) else { continue }
            autoRoutable += 1
            autoRoutedTotal += a.oneWayFeet
            autoDirectTotal += direct

            if case .success(let r) = TravelNetwork.measure(from: pair.0, to: pair.1, in: rawNet) {
                rawRoutable += 1
                rawRoutedTotal += r.oneWayFeet
                rawDirectTotal += direct
                headToHead.append(r.oneWayFeet / max(a.oneWayFeet, 1))
                print(String(format: "  direct=%7.0f ft   raw=%8.0f ft (%5.2fx)   centerline=%7.0f ft (%.2fx)",
                             direct, r.oneWayFeet, r.oneWayFeet / direct,
                             a.oneWayFeet, a.oneWayFeet / direct))
            }
        }

        let autoAggregate = autoRoutedTotal / max(autoDirectTotal, 1)
        let rawAggregate = rawRoutedTotal / max(rawDirectTotal, 1)
        print(String(format: "routable trips: centerline=%d  raw=%d", autoRoutable, rawRoutable))
        print(String(format: "length-weighted detour ratio:  raw=%.2fx   centerline=%.2fx",
                     rawAggregate, autoAggregate))
        if !headToHead.isEmpty {
            let m = headToHead.reduce(0, +) / Double(headToHead.count)
            print(String(format: "raw/centerline on identical trips: %.2fx mean", m))
        }

        XCTAssertGreaterThanOrEqual(autoRoutable, rawRoutable,
                                    "centerline mode should route at least as many real trips as raw mode")

        // These samples are deliberately DIAGONAL cross-plant pairs, and
        // aisles are rectilinear, so pure Manhattan routing already costs
        // ~1.41x straight-line before any detour. A ceiling of 3.0x therefore
        // still catches a systematically broken graph (raw mode scores ~15x
        // here) without failing on geometry that is simply grid-shaped.
        XCTAssertLessThan(autoAggregate, 3.0,
                          "centerline routing should stay within a plausible detour of straight-line distance")
        if rawRoutable >= 3 {
            XCTAssertGreaterThan(rawAggregate, autoAggregate * 1.5,
                                 "raw boundary-line routing should be measurably worse than centerline routing")
        }
    }
}
