import XCTest
@testable import DWGViewer
import CoreGraphics

/// Unit tests for `AisleNetwork` — the graph/routing engine behind the AI
/// Assistant's aisle-routing tools. All fixtures are hand-built so the
/// expected topology is unambiguous (the real reference file's network is
/// fragmented into 43 components, which is useful for validation but useless
/// for asserting exact behavior).
final class AisleNetworkTests: XCTestCase {

    private typealias Seg = AisleNetwork.Segment

    private func seg(_ ax: Double, _ ay: Double, _ bx: Double, _ by: Double) -> Seg {
        Seg(a: CGPoint(x: ax, y: ay), b: CGPoint(x: bx, y: by))
    }

    // MARK: - Intersection splitting (the T-junction fix)

    func testCrossingSegmentsAreSplitIntoFourAtTheIntersection() {
        // A plus sign: horizontal and vertical segments crossing at (0,0).
        // Neither shares an endpoint, so WITHOUT splitting they'd be two
        // disconnected components despite visually intersecting.
        let raw = [seg(-100, 0, 100, 0), seg(0, -100, 0, 100)]
        XCTAssertEqual(AisleNetwork.buildGraph(from: raw).componentCount, 2,
                       "unsplit crossing segments must appear disconnected")

        let split = AisleNetwork.splitAtIntersections(raw)
        XCTAssertEqual(split.count, 4, "each segment must be cut at the crossing")
        let graph = AisleNetwork.buildGraph(from: split)
        XCTAssertEqual(graph.componentCount, 1, "splitting must connect them")
    }

    func testTJunctionBecomesConnected() {
        // A T: the vertical stem ENDS on the horizontal bar's interior.
        // This is the dominant real-world defect shape.
        let raw = [seg(-100, 0, 100, 0), seg(0, 0, 0, 100)]
        let split = AisleNetwork.splitAtIntersections(raw)
        let graph = AisleNetwork.buildGraph(from: split)
        XCTAssertEqual(graph.componentCount, 1)
        // The stem's base is now a real junction node with degree 3.
        let analysis = AisleNetwork.analyze(segments: raw)
        XCTAssertTrue(analysis.isFullyConnected)
        XCTAssertEqual(analysis.components.count, 1)
    }

    func testParallelNonTouchingSegmentsStaySeparate() {
        let raw = [seg(0, 0, 100, 0), seg(0, 50, 100, 50)]
        let analysis = AisleNetwork.analyze(segments: raw)
        XCTAssertEqual(analysis.components.count, 2, "parallel aisles must not be fused")
        XCTAssertFalse(analysis.isFullyConnected)
    }

    func testDegenerateZeroLengthSegmentsAreDropped() {
        let raw = [seg(0, 0, 0, 0), seg(0, 0, 100, 0)]
        let split = AisleNetwork.splitAtIntersections(raw)
        XCTAssertTrue(split.allSatisfy { $0.length > AisleNetwork.minSegmentLength })
    }

    // MARK: - Gap detection

    func testNearMissEndpointGapIsDetectedWithCorrectDistance() {
        // Two collinear aisles with a 40-unit gap between their facing ends.
        let raw = [seg(0, 0, 100, 0), seg(140, 0, 240, 0)]
        let analysis = AisleNetwork.analyze(segments: raw)
        XCTAssertEqual(analysis.components.count, 2)
        let gap = try? XCTUnwrap(analysis.gaps.first)
        XCTAssertNotNil(gap)
        XCTAssertEqual(gap!.distance, 40, accuracy: 1e-6)
        XCTAssertEqual(gap!.kind, .endpoint)
    }

    func testTJunctionStyleGapIsClassifiedAsTJunction() {
        // Vertical stem stops 30 units short of the horizontal bar's INTERIOR
        // (not its endpoint) — so the nearest connection point is mid-segment.
        let raw = [seg(-100, 0, 100, 0), seg(0, 30, 0, 130)]
        let analysis = AisleNetwork.analyze(segments: raw)
        XCTAssertEqual(analysis.components.count, 2)
        let gap = try? XCTUnwrap(analysis.gaps.first { $0.distance <= 31 })
        XCTAssertNotNil(gap, "the 30-unit stem gap must be found")
        XCTAssertEqual(gap!.distance, 30, accuracy: 1e-6)
        XCTAssertEqual(gap!.kind, .tJunction,
                       "connecting to a segment interior must be reported as a T-junction")
    }

    func testMirroredDuplicateGapsAreCollapsed() {
        // Two ends facing each other yield the same physical gap from both
        // sides; the inventory must list it once.
        let raw = [seg(0, 0, 100, 0), seg(140, 0, 240, 0)]
        let analysis = AisleNetwork.analyze(segments: raw)
        XCTAssertEqual(analysis.gaps.count, 1, "a symmetric gap must be deduplicated")
    }

    func testGapsAreSortedAscendingByDistance() {
        let raw = [
            seg(0, 0, 100, 0),
            seg(150, 0, 250, 0),      // 50-unit gap
            seg(0, 500, 100, 500),
            seg(110, 500, 210, 500),  // 10-unit gap
        ]
        let analysis = AisleNetwork.analyze(segments: raw)
        let distances = analysis.gaps.map(\.distance)
        XCTAssertEqual(distances, distances.sorted(),
                       "gaps must be ordered smallest-first so thresholding is trivial")
    }

    func testFullyConnectedNetworkReportsNoGaps() {
        let raw = [seg(0, 0, 100, 0), seg(100, 0, 100, 100)]
        let analysis = AisleNetwork.analyze(segments: raw)
        XCTAssertTrue(analysis.isFullyConnected)
        XCTAssertTrue(analysis.gaps.isEmpty)
    }

    // MARK: - Component reporting

    func testComponentsAreRankedByLengthNotNodeCount() {
        // One long 2-node aisle vs. a short many-node zigzag: length must win,
        // since node count is a poor proxy for network significance.
        var raw = [seg(0, 0, 10_000, 0)]                    // 10,000 units, 2 nodes
        var x = 0.0
        for _ in 0..<10 {                                    // ~100 units, 11 nodes
            raw.append(seg(x, 5_000, x + 10, 5_000))
            x += 10
        }
        let analysis = AisleNetwork.analyze(segments: raw)
        XCTAssertEqual(analysis.components.count, 2)
        XCTAssertEqual(analysis.components[0].length, 10_000, accuracy: 1e-6,
                       "the longest component must rank first")
        XCTAssertGreaterThan(analysis.components[1].nodeCount, analysis.components[0].nodeCount,
                             "and it must outrank a component with MORE nodes but less length")
    }

    func testLargestComponentShareReflectsFragmentation() {
        let raw = [seg(0, 0, 750, 0), seg(0, 1_000, 250, 1_000)]
        let analysis = AisleNetwork.analyze(segments: raw)
        XCTAssertEqual(analysis.totalLength, 1_000, accuracy: 1e-6)
        XCTAssertEqual(analysis.largestComponentShare, 0.75, accuracy: 1e-9)
    }

    // MARK: - Repair

    func testRepairBridgesOnlyGapsWithinThreshold() {
        let raw = [
            seg(0, 0, 100, 0),
            seg(120, 0, 220, 0),        // 20-unit gap  -> should bridge
            seg(0, 900, 100, 900),
            seg(1_100, 900, 1_200, 900) // 1000-unit gap -> must NOT bridge
        ]
        let result = AisleNetwork.repair(segments: raw, autoBridgeUpTo: 100)
        XCTAssertEqual(result.applied.count, 1)
        XCTAssertEqual(result.applied[0].distance, 20, accuracy: 1e-6)
        XCTAssertTrue(result.deferred.contains { $0.distance > 900 },
                      "the large gap must be deferred for human review, never auto-joined")
        XCTAssertLessThan(result.after.components.count, result.before.components.count,
                          "repair must reduce fragmentation")
    }

    func testRepairLeavesInputUntouchedAndReturnsNewSegments() {
        let raw = [seg(0, 0, 100, 0), seg(120, 0, 220, 0)]
        let originalCount = raw.count
        let result = AisleNetwork.repair(segments: raw, autoBridgeUpTo: 50)
        XCTAssertEqual(raw.count, originalCount, "input array must not be mutated")
        XCTAssertGreaterThan(result.segments.count, originalCount,
                             "repaired set must include the new bridge segment")
    }

    func testBridgingASingleGapFullyConnectsTwoComponents() {
        let raw = [seg(0, 0, 100, 0), seg(130, 0, 230, 0)]
        let result = AisleNetwork.repair(segments: raw, autoBridgeUpTo: 50)
        XCTAssertTrue(result.after.isFullyConnected)
        XCTAssertTrue(result.after.gaps.isEmpty)
    }

    /// Regression: `repair`'s `applied` list must name the gap that was
    /// ACTUALLY bridged, not whichever gap happens to occupy the same
    /// array position.
    ///
    /// `bridgeSegments(for:)` uses `compactMap`, which drops a gap whose
    /// endpoints are so close (\u2264 `minSegmentLength`, i.e. essentially
    /// already touching but landing on different quantized graph nodes)
    /// that its "bridge" would be a zero-length segment. `repair`'s pass
    /// loop used to compute `bridges = bridgeSegments(for: actionable)`
    /// and then assume the first `bridges.count` entries of `actionable`
    /// were the ones that produced them
    /// (`applied.append(contentsOf: actionable.prefix(bridges.count))`).
    /// Since `current.gaps`/`actionable` are sorted ASCENDING by distance,
    /// a near-zero-distance degenerate gap always sorts to the FRONT — so
    /// whenever one exists alongside a real, larger, genuinely-bridged
    /// gap, `prefix(bridges.count)` recorded the DROPPED degenerate gap in
    /// `applied` and silently omitted the gap that was actually bridged.
    ///
    /// This fixture reproduces exactly that shape with three isolated
    /// segments (three components):
    ///   - A and B's facing ends sit 0.0000004 units apart AND straddle a
    ///     node-quantization bin boundary (`AisleNetwork.nodeQuantum` is
    ///     2.0; 0.9999998 rounds down, 1.0000002 rounds up), so they
    ///     register as a genuine (if inch-fraction) gap between two
    ///     separate graph components rather than merging into one at
    ///     graph-build time — but that gap's distance (4e-7) is far below
    ///     `AisleNetwork.minSegmentLength` (1e-6), so its "bridge" is
    ///     degenerate and gets dropped.
    ///   - A and C are 20 units apart — comfortably real, well under the
    ///     45-unit threshold, and NOT degenerate.
    ///   - B and C are ~1021 units apart — over threshold, correctly
    ///     deferred, not part of this scenario at all.
    /// Sorted ascending, `actionable` is exactly `[gap(A,B)~4e-7,
    /// gap(A,C)=20]` — the shape that broke the old positional-prefix
    /// logic. `applied` must contain ONLY the real 20-unit gap.
    func testRepairAppliedNamesTheGapThatWasActuallyBridgedNotAPositionalGuess() {
        let threshold = 45.0
        let raw = [
            seg(-1_000, 0, 0.9999998, 0),      // Component A
            seg(1.0000002, 0, 1_000, 0),       // Component B (near-touches A; degenerate gap)
            seg(-1_020, 0, -1_500, 0),         // Component C (real 20-unit gap from A)
        ]

        let before = AisleNetwork.analyze(segments: raw)
        XCTAssertEqual(before.components.count, 3, "sanity: three separate components to start")

        let degenerateGap = before.gaps.first { $0.distance < AisleNetwork.minSegmentLength }
        let realGap = before.gaps.first { abs($0.distance - 20) < 1e-6 }
        XCTAssertNotNil(degenerateGap, "sanity: the near-zero A/B gap must actually be detected")
        XCTAssertNotNil(realGap, "sanity: the real 20-unit A/C gap must actually be detected")
        XCTAssertEqual(before.gaps.first?.distance, degenerateGap?.distance,
                       "sanity: gaps are sorted ascending, so the degenerate gap must sort FIRST — this is what defeats a positional prefix() match")

        let result = AisleNetwork.repair(segments: raw, autoBridgeUpTo: threshold)

        XCTAssertEqual(result.applied.count, 1,
                       "only the one real, non-degenerate gap should be recorded as applied")
        XCTAssertEqual(result.applied.first?.distance ?? -1, 20, accuracy: 1e-6,
                       "applied must name the REAL bridged gap (distance 20), not the degenerate near-zero gap that was actually dropped")
        XCTAssertFalse(result.applied.contains { $0.distance < AisleNetwork.minSegmentLength },
                       "the degenerate gap must never appear in applied — it was never actually bridged")

        // The staged/rendered bridge geometry (both real call sites re-derive
        // it from `applied` via a fresh `bridgeSegments(for:)` call) must
        // therefore also be exactly one real connector, not zero.
        let rebuiltBridges = AisleNetwork.bridgeSegments(for: result.applied)
        XCTAssertEqual(rebuiltBridges.count, 1)
    }

    // MARK: - Routing

    func testRouteFollowsAislesRatherThanStraightLine() {
        // L-shaped aisle. Origin near one end, destination near the other.
        // A straight line between them would cut the corner; the route must
        // travel the full L (which is strictly longer).
        let raw = [seg(0, 0, 1_000, 0), seg(1_000, 0, 1_000, 1_000)]
        let origin = CGPoint(x: 0, y: 50)
        let destination = CGPoint(x: 1_050, y: 1_000)
        guard case .success(let route) = AisleNetwork.route(from: origin, to: destination, segments: raw) else {
            return XCTFail("route should succeed on a connected L")
        }
        let straight = hypot(destination.x - origin.x, destination.y - origin.y)
        XCTAssertGreaterThan(route.aisleLength, Double(straight) * 0.9,
                             "on-aisle travel must reflect the L path, not the diagonal shortcut")
        XCTAssertEqual(route.aisleLength, 2_000, accuracy: 1.0)
    }

    func testRouteReportsConnectorLegsSeparatelyFromAisleTravel() {
        let raw = [seg(0, 0, 1_000, 0)]
        // Origin 50 units off the aisle at one end, destination 30 off at the other.
        guard case .success(let route) = AisleNetwork.route(
            from: CGPoint(x: 0, y: 50), to: CGPoint(x: 1_000, y: -30), segments: raw) else {
            return XCTFail("route should succeed")
        }
        XCTAssertEqual(route.startConnectorLength, 50, accuracy: 1e-6)
        XCTAssertEqual(route.endConnectorLength, 30, accuracy: 1e-6)
        XCTAssertEqual(route.aisleLength, 1_000, accuracy: 1e-6)
        XCTAssertEqual(route.totalLength, 1_080, accuracy: 1e-6)
    }

    func testRouteSnapsToInteriorOfLongSegment() {
        let raw = [seg(0, 0, 1_000, 0)]
        guard case .success(let route) = AisleNetwork.route(
            from: CGPoint(x: 200, y: 100), to: CGPoint(x: 800, y: -50), segments: raw) else {
            return XCTFail("route should succeed")
        }
        XCTAssertEqual(route.startConnectorLength, 100, accuracy: 1e-6)
        XCTAssertEqual(route.endConnectorLength, 50, accuracy: 1e-6)
        XCTAssertEqual(route.aisleLength, 600, accuracy: 1e-6)
        XCTAssertEqual(route.totalLength, 750, accuracy: 1e-6)
        XCTAssertTrue(route.points.contains { abs($0.x - 200) < 1e-6 && abs($0.y) < 1e-6 })
        XCTAssertTrue(route.points.contains { abs($0.x - 800) < 1e-6 && abs($0.y) < 1e-6 })
    }

    func testRouteChoosesTheShorterOfTwoAlternatePaths() {
        // Two parallel routes between the same pair of junctions: a short
        // direct link and a long detour. A* must pick the short one.
        let raw = [
            seg(0, 0, 100, 0),          // short link
            seg(0, 0, 0, 500),          // detour leg 1
            seg(0, 500, 100, 500),      // detour leg 2
            seg(100, 500, 100, 0),      // detour leg 3
        ]
        guard case .success(let route) = AisleNetwork.route(
            from: CGPoint(x: 0, y: 0), to: CGPoint(x: 100, y: 0), segments: raw) else {
            return XCTFail("route should succeed")
        }
        XCTAssertEqual(route.aisleLength, 100, accuracy: 1.0,
                       "A* must take the 100-unit direct link, not the 1100-unit detour")
    }

    func testRouteFailsHonestlyWhenEndpointsAreInDifferentComponents() {
        // Deliberately far apart so no bridging is implied.
        let raw = [seg(0, 0, 100, 0), seg(0, 50_000, 100, 50_000)]
        let result = AisleNetwork.route(from: CGPoint(x: 0, y: 0),
                                       to: CGPoint(x: 100, y: 50_000), segments: raw)
        guard case .failure(let failure) = result else {
            return XCTFail("routing across disconnected components must FAIL, not invent a path")
        }
        guard case .disconnected(let a, let b) = failure else {
            return XCTFail("expected .disconnected, got \(failure)")
        }
        XCTAssertNotEqual(a, b, "failure must name the two distinct components")
    }

    func testRouteFailsOnEmptyNetwork() {
        let result = AisleNetwork.route(from: .zero, to: CGPoint(x: 100, y: 100), segments: [])
        guard case .failure(.emptyNetwork) = result else {
            return XCTFail("an empty aisle layer must report .emptyNetwork")
        }
    }

    func testRoutePathStartsAtOriginAndEndsAtDestination() {
        let raw = [seg(0, 0, 1_000, 0)]
        let origin = CGPoint(x: -20, y: 40)
        let destination = CGPoint(x: 1_020, y: -40)
        guard case .success(let route) = AisleNetwork.route(from: origin, to: destination, segments: raw) else {
            return XCTFail("route should succeed")
        }
        XCTAssertEqual(route.points.first!.x, origin.x, accuracy: 1e-9)
        XCTAssertEqual(route.points.first!.y, origin.y, accuracy: 1e-9)
        XCTAssertEqual(route.points.last!.x, destination.x, accuracy: 1e-9)
        XCTAssertEqual(route.points.last!.y, destination.y, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(route.points.count, 3,
                                    "path must include origin, at least one aisle node, and destination")
    }

    func testRoutingWorksAfterRepairingAGapThatPreviouslyBlockedIt() {
        // End-to-end: a 40-unit gap splits the aisle, routing fails, repair
        // bridges it, routing then succeeds. This is the whole feature's
        // value proposition in one test.
        let raw = [seg(0, 0, 500, 0), seg(540, 0, 1_000, 0)]
        let origin = CGPoint(x: 0, y: 10)
        let destination = CGPoint(x: 1_000, y: 10)

        guard case .failure = AisleNetwork.route(from: origin, to: destination, segments: raw) else {
            return XCTFail("routing must fail across the unrepaired gap")
        }
        let repaired = AisleNetwork.repair(segments: raw, autoBridgeUpTo: 100)
        XCTAssertTrue(repaired.after.isFullyConnected)
        guard case .success(let route) = AisleNetwork.route(from: origin, to: destination,
                                                           segments: repaired.segments) else {
            return XCTFail("routing must succeed once the gap is bridged")
        }
        XCTAssertEqual(route.aisleLength, 1_000, accuracy: 1.0)
    }

    // MARK: - Dock-group centroid

    func testCentroidOfDockGroupIsTheirMidpoint() {
        let docks = [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0),
                     CGPoint(x: 0, y: 100), CGPoint(x: 100, y: 100)]
        let c = try? XCTUnwrap(AisleNetwork.centroid(of: docks))
        XCTAssertEqual(c!.x, 50, accuracy: 1e-9)
        XCTAssertEqual(c!.y, 50, accuracy: 1e-9)
    }

    func testCentroidOfSingleDockIsItself() {
        let c = AisleNetwork.centroid(of: [CGPoint(x: 42, y: -7)])
        XCTAssertEqual(c?.x, 42)
        XCTAssertEqual(c?.y, -7)
    }

    func testCentroidOfEmptyGroupIsNil() {
        XCTAssertNil(AisleNetwork.centroid(of: []))
    }

    func testDockGroupCentroidRoutesFromNearestAisleAccess() {
        // A dock bank whose centroid sits 200 units off the aisle: the route
        // must still succeed, reporting that 200 as the connector leg.
        let raw = [seg(0, 0, 1_000, 0)]
        let docks = [CGPoint(x: 400, y: 200), CGPoint(x: 500, y: 200), CGPoint(x: 600, y: 200)]
        let origin = try? XCTUnwrap(AisleNetwork.centroid(of: docks))
        guard case .success(let route) = AisleNetwork.route(
            from: origin!, to: CGPoint(x: 1_000, y: 0), segments: raw) else {
            return XCTFail("dock-group route should succeed")
        }
        XCTAssertEqual(origin!.x, 500, accuracy: 1e-9)
        XCTAssertEqual(route.startConnectorLength, 200, accuracy: 1e-6)
    }

    // MARK: - Width annotation parsing

    func testParsesFeetAndInchesAisleAnnotation() {
        let r = AisleNetwork.parseWidthAnnotation("13'-4\" AISLE")
        XCTAssertNotNil(r)
        XCTAssertEqual(r!.width, 13 * 12 + 4, accuracy: 1e-9)
        XCTAssertFalse(r!.isOneWay)
    }

    func testParsesWholeFootAisleAnnotation() {
        let r = AisleNetwork.parseWidthAnnotation("14'-0\" AISLE")
        XCTAssertEqual(r?.width, 14 * 12)
    }

    func testParsesAnnotationWithLeadingQualifier() {
        // Real form found in the reference file.
        let r = AisleNetwork.parseWidthAnnotation("9'-0\" - MAINTENANCE AISLE")
        XCTAssertEqual(r?.width, 9 * 12)
    }

    func testParsesAnnotationWithTrailingParagraphQualifier() {
        // MTEXT paragraph break: the width prefix must still parse and the
        // trailing qualifier's digits must NOT be read as inches.
        let r = AisleNetwork.parseWidthAnnotation("17'-4\" AISLE\\PMANUAL FORK AREA")
        XCTAssertEqual(r?.width, 17 * 12 + 4)
    }

    func testCapturesOneWayMarker() {
        let r = AisleNetwork.parseWidthAnnotation("10'-0\" AISLE - ONE WAY")
        XCTAssertNotNil(r)
        XCTAssertEqual(r!.width, 120, accuracy: 1e-9)
        XCTAssertTrue(r!.isOneWay, "directionality stated in the label must be captured")
    }

    func testRejectsNonAisleTextOnAisleLayers() {
        // These appear on aisle layers in production drawings.
        for junk in ["DOCK\\A1", "DOCK-GROUP-B\\A2", "TRASH ROOM", "CANOPY", "XXX"] {
            XCTAssertNil(AisleNetwork.parseWidthAnnotation(junk),
                         "\(junk) must not be read as an aisle width")
        }
    }

    func testRejectsImplausiblyWideAnnotation() {
        // Beyond the 24 ft ceiling -> not a real aisle.
        XCTAssertNil(AisleNetwork.parseWidthAnnotation("60'-0\" AISLE"))
    }

    func testParsesOpeningAndAccessVariants() {
        XCTAssertNotNil(AisleNetwork.parseWidthAnnotation("12'-6\" OPENING"))
        XCTAssertNotNil(AisleNetwork.parseWidthAnnotation("4'-0\" WALKING ACCESS"))
    }

    // MARK: - Corridor detection (boundary pairs -> centerline + width)

    func testDetectsParallelBoundaryPairAsOneCorridorWithMeasuredWidth() {
        // Two 1000-unit boundary lines 160 units (13'-4") apart.
        let raw = [seg(0, 0, 1_000, 0), seg(0, 160, 1_000, 160)]
        let result = AisleNetwork.detectCorridors(from: raw)
        XCTAssertEqual(result.corridors.count, 1, "a boundary pair must collapse to ONE corridor")
        XCTAssertTrue(result.unpaired.isEmpty, "both sides must be consumed by the corridor")
        let c = result.corridors[0]
        XCTAssertEqual(c.width!, 160, accuracy: 1e-6)
        XCTAssertEqual(c.widthSource, .measuredFromBoundaries)
        // Derived centerline must run midway between the two sides.
        XCTAssertEqual(c.centerline.a.y, 80, accuracy: 1e-6)
        XCTAssertEqual(c.centerline.b.y, 80, accuracy: 1e-6)
    }

    func testDerivedCenterlineIsUsedForRoutingNotTheBoundaries() {
        // Routing on the raw boundaries would travel along an EDGE (y=0 or
        // y=160); routing the derived corridor travels the middle (y=80).
        let raw = [seg(0, 0, 1_000, 0), seg(0, 160, 1_000, 160)]
        let corridors = AisleNetwork.detectCorridors(from: raw).corridors
        let centerlines = corridors.map(\.centerline)
        guard case .success(let route) = AisleNetwork.route(
            from: CGPoint(x: 0, y: 80), to: CGPoint(x: 1_000, y: 80), segments: centerlines) else {
            return XCTFail("routing along the derived centerline should succeed")
        }
        XCTAssertEqual(route.aisleLength, 1_000, accuracy: 1.0)
        XCTAssertEqual(route.startConnectorLength, 0, accuracy: 1e-6,
                       "origin already on the centerline needs no connector leg")
    }

    func testConvergingLinesAreNotTreatedAsACorridor() {
        // Ends 160 apart at one end, 400 at the other: not constant width.
        let raw = [seg(0, 0, 1_000, 0), seg(0, 160, 1_000, 400)]
        let result = AisleNetwork.detectCorridors(from: raw)
        XCTAssertTrue(result.corridors.isEmpty, "non-parallel lines must not form a corridor")
        XCTAssertEqual(result.unpaired.count, 2)
    }

    func testNonOverlappingParallelSegmentsAreNotPaired() {
        // Parallel and correctly spaced, but end-to-end rather than side-by-side.
        let raw = [seg(0, 0, 500, 0), seg(2_000, 160, 2_500, 160)]
        let result = AisleNetwork.detectCorridors(from: raw)
        XCTAssertTrue(result.corridors.isEmpty)
    }

    func testTooWideSeparationIsRejectedAsNotAnAisle() {
        // 40 ft apart — beyond the 24 ft plausibility ceiling.
        let raw = [seg(0, 0, 1_000, 0), seg(0, 40 * 12, 1_000, 40 * 12)]
        let result = AisleNetwork.detectCorridors(from: raw)
        XCTAssertTrue(result.corridors.isEmpty, "coincidental wide parallelism is not an aisle")
    }

    func testShortStubsAreNotPairedAsCorridorSides() {
        let raw = [seg(0, 0, 50, 0), seg(0, 160, 50, 160)]
        let result = AisleNetwork.detectCorridors(from: raw)
        XCTAssertTrue(result.corridors.isEmpty, "short stubs pair spuriously and must be excluded")
    }

    func testEachBoundaryIsConsumedByAtMostOneCorridor() {
        // Three stacked parallel lines: the two closest should pair, and the
        // third must be left unpaired rather than double-using a side.
        let raw = [seg(0, 0, 1_000, 0), seg(0, 160, 1_000, 160), seg(0, 900, 1_000, 900)]
        let result = AisleNetwork.detectCorridors(from: raw)
        XCTAssertEqual(result.corridors.count, 1)
        XCTAssertEqual(result.unpaired.count, 1)
    }

    func testUnpairedCenterlinesAreReturnedForRouting() {
        let raw = [seg(0, 0, 1_000, 0)]
        let result = AisleNetwork.detectCorridors(from: raw)
        XCTAssertTrue(result.corridors.isEmpty)
        XCTAssertEqual(result.unpaired.count, 1, "a lone centerline must survive as routable")
    }

    // MARK: - Annotation -> corridor assignment

    func testNearestAnnotationFillsAnUnmeasuredCorridorWidth() {
        let corridor = AisleNetwork.Corridor(centerline: seg(0, 0, 1_000, 0), width: nil)
        let ann = AisleNetwork.WidthAnnotation(position: CGPoint(x: 500, y: 20),
                                               width: 160, text: "13'-4\" AISLE", isOneWay: false)
        let out = AisleNetwork.applyWidthAnnotations([ann], to: [corridor], maxDistance: 500)
        XCTAssertEqual(out[0].width!, 160, accuracy: 1e-9)
        XCTAssertEqual(out[0].widthSource, .textAnnotation)
    }

    func testMeasuredWidthIsNotOverwrittenByAnAnnotation() {
        let corridor = AisleNetwork.Corridor(centerline: seg(0, 0, 1_000, 0), width: 200,
                                             widthSource: .measuredFromBoundaries)
        let ann = AisleNetwork.WidthAnnotation(position: CGPoint(x: 500, y: 10),
                                               width: 160, text: "13'-4\" AISLE", isOneWay: false)
        let out = AisleNetwork.applyWidthAnnotations([ann], to: [corridor], maxDistance: 500)
        XCTAssertEqual(out[0].width!, 200, accuracy: 1e-9,
                       "a directly measured width must win over a nearby label")
        XCTAssertEqual(out[0].widthSource, .measuredFromBoundaries)
    }

    func testDistantAnnotationIsNotApplied() {
        let corridor = AisleNetwork.Corridor(centerline: seg(0, 0, 1_000, 0), width: nil)
        let ann = AisleNetwork.WidthAnnotation(position: CGPoint(x: 500, y: 99_999),
                                               width: 160, text: "13'-4\" AISLE", isOneWay: false)
        let out = AisleNetwork.applyWidthAnnotations([ann], to: [corridor], maxDistance: 500)
        XCTAssertNil(out[0].width, "a far-off label must not be applied to an unrelated aisle")
    }

    // MARK: - Ribbons (shading geometry)

    func testRibbonIsAClosedRectangleOfTheCorridorWidth() {
        let corridor = AisleNetwork.Corridor(centerline: seg(0, 0, 1_000, 0), width: 160,
                                             widthSource: .measuredFromBoundaries)
        let r = try? XCTUnwrap(AisleNetwork.ribbon(for: corridor, fallbackWidth: 100))
        XCTAssertEqual(r!.points.count, 4, "a ribbon must be a closed quad")
        XCTAssertEqual(r!.width, 160, accuracy: 1e-9)
        // Buffered half-width to each side of the centerline (y = 0).
        let ys = r!.points.map { Double($0.y) }.sorted()
        XCTAssertEqual(ys.first!, -80, accuracy: 1e-6)
        XCTAssertEqual(ys.last!, 80, accuracy: 1e-6)
    }

    func testRibbonUsesFallbackWidthAndReportsItAsAssumed() {
        let corridor = AisleNetwork.Corridor(centerline: seg(0, 0, 1_000, 0), width: nil)
        let r = try? XCTUnwrap(AisleNetwork.ribbon(for: corridor, fallbackWidth: 144))
        XCTAssertEqual(r!.width, 144, accuracy: 1e-9)
        XCTAssertEqual(r!.widthSource, .assumed,
                       "a guessed width must be flagged so the user can spot-check it")
    }

    func testRibbonFollowsDiagonalCorridorOrientation() {
        // 45-degree corridor: the ribbon must be perpendicular-offset, not
        // axis-aligned.
        let corridor = AisleNetwork.Corridor(centerline: seg(0, 0, 100, 100), width: 20,
                                             widthSource: .measuredFromBoundaries)
        let r = try? XCTUnwrap(AisleNetwork.ribbon(for: corridor, fallbackWidth: 10))
        // Every corner must sit exactly half-width from the centerline.
        for p in r!.points {
            let d = abs(Double(p.x) - Double(p.y)) / 2.0.squareRoot()
            XCTAssertEqual(d, 10, accuracy: 1e-6)
        }
    }

    func testDegenerateCorridorProducesNoRibbon() {
        let corridor = AisleNetwork.Corridor(centerline: seg(5, 5, 5, 5), width: 100)
        XCTAssertNil(AisleNetwork.ribbon(for: corridor, fallbackWidth: 100))
    }

    func testRibbonsAreGeneratedForEveryValidCorridor() {
        let corridors = [
            AisleNetwork.Corridor(centerline: seg(0, 0, 100, 0), width: 20),
            AisleNetwork.Corridor(centerline: seg(0, 50, 100, 50), width: nil),
            AisleNetwork.Corridor(centerline: seg(9, 9, 9, 9), width: 20),   // degenerate
        ]
        let ribbons = AisleNetwork.ribbons(for: corridors, fallbackWidth: 30)
        XCTAssertEqual(ribbons.count, 2, "degenerate corridors must be skipped")
    }

    // MARK: - Junction rounding (closes the corner gap at aisle bends)

    func testLShapedBendProducesOneJunctionAtTheCorner() {
        // Two corridors meeting at (100,0): a horizontal run then a vertical
        // one — the classic "L shape" the user reported a gap in.
        let corridors = [
            AisleNetwork.Corridor(centerline: seg(0, 0, 100, 0), width: 160),
            AisleNetwork.Corridor(centerline: seg(100, 0, 100, 100), width: 160),
        ]
        let junctions = AisleNetwork.junctions(for: corridors, fallbackWidth: 100)
        XCTAssertEqual(junctions.count, 1, "an L-bend has exactly one shared corner")
        let j = junctions[0]
        XCTAssertEqual(j.point.x, 100, accuracy: 1e-6)
        XCTAssertEqual(j.point.y, 0, accuracy: 1e-6)
        XCTAssertEqual(j.degree, 2)
        XCTAssertEqual(j.width, 160, accuracy: 1e-6)
    }

    func testJunctionWidthMatchesTheWidestMeetingCorridor() {
        // A narrow aisle meeting a much wider one at their shared corner —
        // the disk must be sized to fully cover the WIDER ribbon, or it
        // would leave a sliver gap on that side.
        let corridors = [
            AisleNetwork.Corridor(centerline: seg(0, 0, 100, 0), width: 60),
            AisleNetwork.Corridor(centerline: seg(100, 0, 100, 100), width: 200),
        ]
        let junctions = AisleNetwork.junctions(for: corridors, fallbackWidth: 100)
        XCTAssertEqual(junctions.count, 1)
        XCTAssertEqual(junctions[0].width, 200, accuracy: 1e-6, "must use the WIDER corridor's width")
    }

    func testTJunctionHasDegreeThree() {
        // Three corridors meeting at one point: a T-branch.
        let corridors = [
            AisleNetwork.Corridor(centerline: seg(0, 0, 100, 0), width: 100),
            AisleNetwork.Corridor(centerline: seg(200, 0, 100, 0), width: 100),   // reversed direction, same shared point
            AisleNetwork.Corridor(centerline: seg(100, 0, 100, 100), width: 100),
        ]
        let junctions = AisleNetwork.junctions(for: corridors, fallbackWidth: 100)
        XCTAssertEqual(junctions.count, 1)
        XCTAssertEqual(junctions[0].degree, 3)
    }

    func testStraightThroughCrossingStillProducesAJunction() {
        // Two corridors merely passing through a shared point end-to-end (no
        // actual turn) still get a disk — harmless (a straight run has no
        // gap to close, but a same-radius circle sitting on the seam is
        // visually a no-op, not a defect) and keeps the rule simple: any
        // node degree >= 2 gets a disk, rather than special-casing "is this
        // really a turn."
        let corridors = [
            AisleNetwork.Corridor(centerline: seg(0, 0, 100, 0), width: 100),
            AisleNetwork.Corridor(centerline: seg(100, 0, 200, 0), width: 100),
        ]
        let junctions = AisleNetwork.junctions(for: corridors, fallbackWidth: 100)
        XCTAssertEqual(junctions.count, 1)
    }

    func testIsolatedEndpointIsNotAJunction() {
        // A single corridor's own free end (degree 1, nothing else meets it)
        // must NOT get a rounding disk — there is no gap to close there.
        let corridors = [AisleNetwork.Corridor(centerline: seg(0, 0, 100, 0), width: 100)]
        let junctions = AisleNetwork.junctions(for: corridors, fallbackWidth: 100)
        XCTAssertTrue(junctions.isEmpty)
    }

    func testJunctionUsesFallbackWidthWhenCorridorWidthIsUnknown() {
        let corridors = [
            AisleNetwork.Corridor(centerline: seg(0, 0, 100, 0), width: nil),
            AisleNetwork.Corridor(centerline: seg(100, 0, 100, 100), width: nil),
        ]
        let junctions = AisleNetwork.junctions(for: corridors, fallbackWidth: 144)
        XCTAssertEqual(junctions.count, 1)
        XCTAssertEqual(junctions[0].width, 144, accuracy: 1e-6)
    }

    func testJunctionDisksHaveHalfWidthRadius() {
        let junctions = [AisleNetwork.Junction(point: CGPoint(x: 5, y: 5), width: 160, degree: 2)]
        let disks = AisleNetwork.junctionDisks(for: junctions)
        XCTAssertEqual(disks.count, 1)
        XCTAssertEqual(disks[0].radius, 80, accuracy: 1e-6)
        XCTAssertEqual(disks[0].center.x, 5, accuracy: 1e-6)
    }

    func testJunctionDiskPolygonTessellatesAsAClosedLoop() {
        let disk = AisleNetwork.JunctionDisk(center: CGPoint(x: 10, y: 10), radius: 50)
        let poly = AisleNetwork.polygon(for: disk, segments: 16)
        XCTAssertEqual(poly.count, 16)
        for p in poly {
            let d = hypot(Double(p.x - disk.center.x), Double(p.y - disk.center.y))
            XCTAssertEqual(d, disk.radius, accuracy: 1e-6)
        }
    }

    func testDegenerateJunctionDiskProducesNoPolygon() {
        let disk = AisleNetwork.JunctionDisk(center: .zero, radius: 0)
        XCTAssertTrue(AisleNetwork.polygon(for: disk).isEmpty)
    }
}
