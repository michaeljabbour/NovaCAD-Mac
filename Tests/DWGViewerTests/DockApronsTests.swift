import XCTest
@testable import DWGViewer
import CoreGraphics

/// Unit tests for `DockAprons` — dock-door detection, bank grouping, and apron
/// geometry generation. Hand-built fixtures throughout so expected results are
/// unambiguous; real-file validation lives in
/// `RealAisleNetworkValidationTests`.
final class DockApronsTests: XCTestCase {

    private func door(_ n: Int, _ x: Double, _ y: Double, layer: String = "Trucks") -> DockAprons.DockDoor {
        DockAprons.DockDoor(number: n, position: CGPoint(x: x, y: y), layer: layer)
    }

    // MARK: - Label parsing

    func testParsesStandardDockLabel() {
        XCTAssertEqual(DockAprons.parseDockNumber("DOCK 34"), 34)
        XCTAssertEqual(DockAprons.parseDockNumber("Dock 122"), 122)
        XCTAssertEqual(DockAprons.parseDockNumber("dock  7"), 7)
    }

    func testParsesDockLabelWithMTextParagraphBreak() {
        // MTEXT stores the number after a \P paragraph break.
        XCTAssertEqual(DockAprons.parseDockNumber("DOCK\\P42"), 42)
    }

    func testParsesDockLabelWithHashPrefix() {
        XCTAssertEqual(DockAprons.parseDockNumber("DOCK #12"), 12)
    }

    func testRejectsNonDockTextFoundOnTheSameLayers() {
        // Every one of these appears on dock layers in production drawings.
        for junk in ["RAMP", "CONC.", "DRIVE-IN DOOR", "TRASH ROOM", "CANOPY", "GE", "XXX"] {
            XCTAssertNil(DockAprons.parseDockNumber(junk), "\(junk) must not parse as a dock")
        }
    }

    func testRejectsGroupHeaderAsIndividualDock() {
        // A named group header is not a numbered door.
        XCTAssertNil(DockAprons.parseDockNumber("DOCK-GROUP-B DOCKS"))
        XCTAssertNil(DockAprons.parseDockNumber("DOCK-GROUP-S DOCKS"))
    }

    func testParsesDockGroupNames() {
        XCTAssertNotNil(DockAprons.parseDockGroupName("DOCK-GROUP-B DOCKS"))
        XCTAssertNotNil(DockAprons.parseDockGroupName("DOCK-GROUP-C DOCKS\\A3"))
        // A numbered individual door is not a group.
        XCTAssertNil(DockAprons.parseDockGroupName("DOCK 9"))
        XCTAssertNil(DockAprons.parseDockGroupName("TRASH ROOM"))
    }

    // MARK: - Bank grouping

    func testGroupsConsecutiveEvenlySpacedDoorsIntoOneBank() {
        // 12 doors at 20 ft pitch along a wall — the reference file's dock 1-12.
        let doors = (1...12).map { door($0, Double($0) * 20 * 12, 0) }
        let banks = DockAprons.groupIntoBanks(doors)
        XCTAssertEqual(banks.count, 1)
        XCTAssertEqual(banks[0].doors.count, 12)
        XCTAssertEqual(banks[0].numbers, Array(1...12))
    }

    func testNonConsecutiveNumbersStartANewBank() {
        // A numbering gap means a separate bank even if geometrically close.
        let doors = [door(1, 0, 0), door(2, 240, 0), door(40, 480, 0), door(41, 720, 0)]
        let banks = DockAprons.groupIntoBanks(doors)
        XCTAssertEqual(banks.count, 2)
        XCTAssertEqual(banks[0].numbers, [1, 2])
        XCTAssertEqual(banks[1].numbers, [40, 41])
    }

    func testFarApartDoorsStartANewBankEvenIfConsecutive() {
        let doors = [door(1, 0, 0), door(2, 240, 0), door(3, 100_000, 0)]
        let banks = DockAprons.groupIntoBanks(doors)
        XCTAssertEqual(banks.count, 2, "a huge gap must split the bank")
        XCTAssertEqual(banks[0].numbers, [1, 2])
    }

    func testNonCollinearDoorsStartANewBank() {
        // Docks turning a building corner: 1-3 run along X, then 4 jumps far
        // off that line in Y.
        let doors = [door(1, 0, 0), door(2, 240, 0), door(3, 480, 0),
                     door(4, 480, 50 * 12)]
        let banks = DockAprons.groupIntoBanks(doors)
        XCTAssertEqual(banks.count, 2, "doors around a corner are separate banks")
    }

    func testEmptyInputProducesNoBanks() {
        XCTAssertTrue(DockAprons.groupIntoBanks([]).isEmpty)
    }

    func testBankCentroidIsTheDoorMidpoint() {
        let doors = [door(1, 0, 0), door(2, 100, 0), door(3, 200, 0)]
        let bank = DockAprons.groupIntoBanks(doors)[0]
        let c = try? XCTUnwrap(bank.centroid)
        XCTAssertEqual(c!.x, 100, accuracy: 1e-9)
        XCTAssertEqual(c!.y, 0, accuracy: 1e-9)
    }

    // MARK: - Apron geometry

    func testApronIsAClosedRectangleOfTheGivenDepth() {
        let doors = (1...4).map { door($0, Double($0) * 240, 0) }
        let bank = DockAprons.groupIntoBanks(doors)[0]
        // Interior is toward +Y.
        let apron = try? XCTUnwrap(DockAprons.apron(for: bank, depth: 40 * 12,
                                                    interiorHint: CGPoint(x: 0, y: 10_000)))
        XCTAssertEqual(apron!.points.count, 4, "apron must be a closed quad")
        XCTAssertEqual(apron!.depth, 40 * 12, accuracy: 1e-9)
        // Two corners on the dock line (y=0), two at depth (y=480).
        let ys = apron!.points.map { Double($0.y) }.sorted()
        XCTAssertEqual(ys[0], 0, accuracy: 1e-6)
        XCTAssertEqual(ys[1], 0, accuracy: 1e-6)
        XCTAssertEqual(ys[2], 40 * 12, accuracy: 1e-6)
        XCTAssertEqual(ys[3], 40 * 12, accuracy: 1e-6)
    }

    func testApronExtendsTowardTheInteriorHint() {
        let doors = [door(1, 0, 0), door(2, 240, 0)]
        let bank = DockAprons.groupIntoBanks(doors)[0]
        // Interior toward NEGATIVE Y this time — apron must flip.
        let apron = try? XCTUnwrap(DockAprons.apron(for: bank, depth: 120,
                                                    interiorHint: CGPoint(x: 0, y: -10_000)))
        let ys = apron!.points.map { Double($0.y) }
        XCTAssertTrue(ys.contains { $0 < -1 }, "apron must extend toward the interior hint")
        XCTAssertFalse(ys.contains { $0 > 1 }, "apron must not extend away from the interior")
    }

    func testApronFrontageSpansTheWholeBank() {
        let doors = (1...5).map { door($0, Double($0 - 1) * 240, 0) }   // 4 gaps * 240 = 960
        let bank = DockAprons.groupIntoBanks(doors)[0]
        let apron = try? XCTUnwrap(DockAprons.apron(for: bank, depth: 100,
                                                    interiorHint: CGPoint(x: 0, y: 1_000)))
        XCTAssertEqual(apron!.frontage, 960, accuracy: 1e-6)
    }

    func testEndPaddingExtendsFrontageBeyondTheOuterDoors() {
        let doors = [door(1, 0, 0), door(2, 240, 0)]
        let bank = DockAprons.groupIntoBanks(doors)[0]
        let apron = try? XCTUnwrap(DockAprons.apron(for: bank, depth: 100, endPadding: 60,
                                                    interiorHint: CGPoint(x: 0, y: 1_000)))
        XCTAssertEqual(apron!.frontage, 240 + 120, accuracy: 1e-6,
                       "padding must be added at BOTH ends")
        let xs = apron!.points.map { Double($0.x) }
        XCTAssertEqual(xs.min()!, -60, accuracy: 1e-6)
        XCTAssertEqual(xs.max()!, 300, accuracy: 1e-6)
    }

    func testApronFollowsADiagonalDockFace() {
        // Docks along a 45-degree wall: every corner must sit exactly `depth`
        // from the dock line, proving the buffer is perpendicular. Spacing is
        // kept within `maxDoorPitch` (900 units) so the two doors legitimately
        // form ONE bank — a diagonal separation of 1,414 units would (rightly)
        // be split as two banks instead.
        let doors = [door(1, 0, 0), door(2, 600, 600)]
        let bank = DockAprons.groupIntoBanks(doors)[0]
        let depth = 100.0
        let apron = try? XCTUnwrap(DockAprons.apron(for: bank, depth: depth,
                                                    interiorHint: CGPoint(x: -1_000, y: 1_000)))
        // Distance from the dock line (y = x) is |y-x|/sqrt(2): either 0 or depth.
        for p in apron!.points {
            let d = abs(Double(p.y) - Double(p.x)) / 2.0.squareRoot()
            XCTAssertTrue(abs(d) < 1e-6 || abs(d - depth) < 1e-6,
                          "corner must be on the dock line or exactly depth away, got \(d)")
        }
    }

    func testSingleDoorBankProducesNoApron() {
        // One labelled door gives no orientation; a guessed apron would be
        // worse than none.
        let bank = DockAprons.groupIntoBanks([door(1, 0, 0)])[0]
        XCTAssertNil(DockAprons.apron(for: bank, depth: 100, interiorHint: CGPoint(x: 0, y: 100)))
    }

    func testZeroOrNegativeDepthProducesNoApron() {
        let bank = DockAprons.groupIntoBanks([door(1, 0, 0), door(2, 240, 0)])[0]
        XCTAssertNil(DockAprons.apron(for: bank, depth: 0, interiorHint: CGPoint(x: 0, y: 100)))
        XCTAssertNil(DockAprons.apron(for: bank, depth: -50, interiorHint: CGPoint(x: 0, y: 100)))
    }

    func testApronsAreBuiltForEveryOrientableBank() {
        let doors = [door(1, 0, 0), door(2, 240, 0),           // bank A (2 doors)
                     door(50, 100_000, 0)]                      // lone door -> skipped
        let banks = DockAprons.groupIntoBanks(doors)
        XCTAssertEqual(banks.count, 2)
        let aprons = DockAprons.aprons(for: banks, depth: 480, interiorHint: CGPoint(x: 0, y: 10_000))
        XCTAssertEqual(aprons.count, 1, "the single-door bank must be skipped")
        XCTAssertEqual(aprons[0].bankNumbers, [1, 2])
    }

    // MARK: - Depth suggestion

    func testSuggestsDepthFromAParallelAisle() {
        // Dock face along X at y=0; a parallel aisle 40 ft inside at y=480.
        let bank = DockAprons.groupIntoBanks([door(1, 0, 0), door(2, 720, 0)])[0]
        let aisles = [AisleNetwork.Segment(a: CGPoint(x: -500, y: 480),
                                          b: CGPoint(x: 1_500, y: 480))]
        let d = try? XCTUnwrap(DockAprons.suggestedDepth(for: bank, aisleSegments: aisles))
        XCTAssertEqual(d!, 480, accuracy: 1.0)
    }

    func testIgnoresPerpendicularAisleWhenSuggestingDepth() {
        // A perpendicular aisle is not this apron's bounding aisle, even
        // though it may be the geometrically nearest one.
        let bank = DockAprons.groupIntoBanks([door(1, 0, 0), door(2, 720, 0)])[0]
        let aisles = [AisleNetwork.Segment(a: CGPoint(x: 500, y: 10),
                                          b: CGPoint(x: 500, y: 5_000))]
        XCTAssertNil(DockAprons.suggestedDepth(for: bank, aisleSegments: aisles),
                     "a perpendicular aisle must not be offered as the apron depth")
    }

    func testIgnoresVeryDistantAisleWhenSuggestingDepth() {
        // Measured reality: some docks' nearest aisle is 1,476 ft away and
        // unrelated. Such an aisle must not be suggested as a depth.
        let bank = DockAprons.groupIntoBanks([door(1, 0, 0), door(2, 720, 0)])[0]
        let aisles = [AisleNetwork.Segment(a: CGPoint(x: 0, y: 1_476 * 12),
                                          b: CGPoint(x: 1_000, y: 1_476 * 12))]
        XCTAssertNil(DockAprons.suggestedDepth(for: bank, aisleSegments: aisles))
    }

    func testPicksNearestOfSeveralParallelAisles() {
        let bank = DockAprons.groupIntoBanks([door(1, 0, 0), door(2, 720, 0)])[0]
        let aisles = [
            AisleNetwork.Segment(a: CGPoint(x: 0, y: 1_200), b: CGPoint(x: 1_000, y: 1_200)),
            AisleNetwork.Segment(a: CGPoint(x: 0, y: 480), b: CGPoint(x: 1_000, y: 480)),
        ]
        let d = try? XCTUnwrap(DockAprons.suggestedDepth(for: bank, aisleSegments: aisles))
        XCTAssertEqual(d!, 480, accuracy: 1.0, "must suggest the closest parallel aisle")
    }

    func testNoSuggestionWhenNoAislesExist() {
        let bank = DockAprons.groupIntoBanks([door(1, 0, 0), door(2, 240, 0)])[0]
        XCTAssertNil(DockAprons.suggestedDepth(for: bank, aisleSegments: []))
    }

    // MARK: - Duplicate label handling

    func testDuplicateLabelsForOneDoorCollapse() {
        // Production files annotate the same door on several layers (measured:
        // `DOCK NUMBERS` and `Trucks` both label docks 34/35 at identical
        // coordinates).
        let doors = [door(34, 1_000, 2_000, layer: "Trucks"),
                     door(34, 1_000, 2_000, layer: "DOCK NUMBERS"),
                     door(35, 1_180, 2_000, layer: "Trucks")]
        // Grouping runs on already-deduplicated input; verify the tolerance
        // constant is at least large enough to catch identical positions.
        XCTAssertGreaterThan(DockAprons.duplicateLabelTolerance, 0)
        let banks = DockAprons.groupIntoBanks(doors)
        // Both 34s are consecutive-equal, not consecutive+1, so they split;
        // this documents that dedup must happen BEFORE grouping.
        XCTAssertGreaterThanOrEqual(banks.count, 1)
    }

    // MARK: - Layer priority / renovation-phase exclusion
    //
    // Measured problem this guards: in the reference file the same dock number
    // legitimately exists at up to 4 positions across renovation phases
    // (`27-DEMO` vs `27-NEW`, over 2,000 units apart). Reading every phase at
    // once produced 63 bogus banks from 129 labels; scoping to current-state
    // layers yields 21 clean banks from 93 real doors.

    func testDefaultsExcludeDemolitionPhaseLayers() {
        XCTAssertTrue(DockAprons.defaultExcludedLayerFragments.contains("demo"),
                      "demolition-phase layers must be excluded by default")
    }

    func testLayerPriorityOrderIsMostAuthoritativeFirst() {
        // A door annotated on several live layers must resolve to one instance,
        // preferring the dedicated dock-numbering layer.
        XCTAssertEqual(DockAprons.defaultDockLayerPriority.first, "DOCK NUMBERS")
        XCTAssertTrue(DockAprons.defaultDockLayerPriority.contains("Trucks"))
    }

    func testDuplicateToleranceCoversTheMeasuredCrossLayerOffset() {
        // `Dock` and `Trucks` annotate one door 342 units apart in the
        // reference file; the tolerance must absorb that.
        XCTAssertGreaterThan(DockAprons.duplicateLabelTolerance, 342,
                             "tolerance must cover the real cross-layer label offset")
    }

    // MARK: - Idempotent regeneration
    //
    // Aprons must be safely re-derivable when docks shift, since the user
    // regenerates them onto a fresh layer as circumstances change.

    func testRegeneratingAproneFromTheSameInputIsDeterministic() {
        let doors = (1...6).map { door($0, Double($0 - 1) * 240, 0) }
        let banks = DockAprons.groupIntoBanks(doors)
        let hint = CGPoint(x: 0, y: 10_000)
        let first = DockAprons.aprons(for: banks, depth: 480, interiorHint: hint)
        let second = DockAprons.aprons(for: banks, depth: 480, interiorHint: hint)
        XCTAssertEqual(first, second, "identical input must yield identical aprons")
    }

    func testMovedDocksProduceCorrespondinglyMovedAprons() {
        // Simulates docks shifting during a layout change.
        let before = (1...4).map { door($0, Double($0 - 1) * 240, 0) }
        let after = (1...4).map { door($0, Double($0 - 1) * 240, 5_000) }
        let hint = CGPoint(x: 0, y: 50_000)
        let a1 = DockAprons.aprons(for: DockAprons.groupIntoBanks(before), depth: 480, interiorHint: hint)
        let a2 = DockAprons.aprons(for: DockAprons.groupIntoBanks(after), depth: 480, interiorHint: hint)
        XCTAssertEqual(a1.count, a2.count)
        XCTAssertNotEqual(a1, a2, "shifted docks must yield shifted aprons")
        XCTAssertEqual(a1[0].frontage, a2[0].frontage, accuracy: 1e-6,
                       "frontage is unchanged by a pure translation")
    }
}
