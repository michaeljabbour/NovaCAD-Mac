import XCTest
@testable import DWGViewer
import CoreGraphics
import CADCore

/// Validates `AisleNetwork` against the real reference layout, cross-checking
/// the numbers independently measured during this feature's design research.
/// Skips when the fixture isn't present.
final class RealAisleNetworkValidationTests: XCTestCase {
    private var fixtureURL: URL? {
        guard let path = ProcessInfo.processInfo.environment["NOVACAD_SAMPLE_LAYOUT"] else { return nil }
        return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    func testRealAisleLayerAnalysis() throws {
        guard let url = fixtureURL else { throw XCTSkip("reference layout not present") }
        let rc = try RegenCoordinator.load(url: url)
        let segs = AisleNetwork.segments(onLayerNamed: "AISLE", document: rc.document, space: .model)
        print("=== REAL FILE: AISLE ===")
        print("segments extracted: \(segs.count)")
        let a = AisleNetwork.analyze(segments: segs)
        print("after split: \(a.segmentCount) segments, \(a.nodeCount) nodes")
        print("components: \(a.components.count)")
        print("dangling endpoints: \(a.danglingEndpointCount)")
        print(String(format: "total aisle length: %.1f", a.totalLength))
        print(String(format: "largest component share: %.1f%%", a.largestComponentShare * 100))
        print("distinct gaps: \(a.gaps.count)")
        for g in a.gaps.prefix(15) {
            print(String(format: "  %8.2f  %-10@  (%.0f,%.0f) -> (%.0f,%.0f)  c%d->c%d",
                         g.distance, g.kind.rawValue as NSString,
                         g.from.x, g.from.y, g.to.x, g.to.y, g.fromComponent, g.toComponent))
        }
        let r = AisleNetwork.repair(segments: segs, autoBridgeUpTo: 120)
        print("--- repair @120 units ---")
        print("applied: \(r.applied.count), deferred: \(r.deferred.count)")
        print("components: \(r.before.components.count) -> \(r.after.components.count)")
        print(String(format: "largest share: %.1f%% -> %.1f%%",
                     r.before.largestComponentShare * 100, r.after.largestComponentShare * 100))
        XCTAssertGreaterThan(segs.count, 100, "should find the real aisle geometry")
    }

    func testRealCorridorDetectionAndWidthMeasurement() throws {
        guard let url = fixtureURL else { throw XCTSkip("reference layout not present") }
        let rc = try RegenCoordinator.load(url: url)
        let segs = AisleNetwork.segments(onLayerNamed: "AISLE", document: rc.document, space: .model)
        let (corridors, unpaired) = AisleNetwork.detectCorridors(from: segs)
        let anns = AisleNetwork.widthAnnotations(onLayerNamed: "AISLE", document: rc.document, space: .model)

        print("=== REAL FILE: corridors + widths on AISLE ===")
        print("raw segments: \(segs.count)")
        print("corridors detected (boundary pairs): \(corridors.count)")
        print("unpaired segments (bare centerlines): \(unpaired.count)")
        print("width annotations parsed: \(anns.count)")
        let oneWay = anns.filter(\.isOneWay)
        print("  of which ONE WAY: \(oneWay.count)")

        let measured = corridors.compactMap(\.width)
        if !measured.isEmpty {
            let ft = measured.map { $0 / 12 }.sorted()
            print(String(format: "measured widths (ft): min=%.1f median=%.1f max=%.1f",
                         ft.first!, ft[ft.count/2], ft.last!))
            var hist: [Int: Int] = [:]
            for f in ft { hist[Int(f.rounded()), default: 0] += 1 }
            print("  rounded-foot distribution:")
            for k in hist.keys.sorted() { print("     \(k) ft : \(hist[k]!)") }
        }
        let annFt = anns.map { $0.width / 12 }.sorted()
        if !annFt.isEmpty {
            print(String(format: "annotated widths (ft): min=%.1f median=%.1f max=%.1f",
                         annFt.first!, annFt[annFt.count/2], annFt.last!))
        }

        // Fill unmeasured corridors from nearby labels, then build ribbons.
        let filled = AisleNetwork.applyWidthAnnotations(anns, to: corridors, maxDistance: 600)
        let withWidth = filled.filter { $0.width != nil }.count
        print("corridors with a known width after annotation matching: \(withWidth)/\(filled.count)")
        let ribbons = AisleNetwork.ribbons(for: filled, fallbackWidth: 13.34 * 12)
        print("ribbons generated for shading: \(ribbons.count)")
        var bySource: [String: Int] = [:]
        for r in ribbons { bySource[r.widthSource.rawValue, default: 0] += 1 }
        print("  width provenance: \(bySource)")

        XCTAssertGreaterThan(corridors.count, 20, "should detect real boundary-pair corridors")
        XCTAssertGreaterThan(anns.count, 50, "should parse the drawing's own width labels")
    }

    func testRealDockDetectionAndApronGeneration() throws {
        guard let url = fixtureURL else { throw XCTSkip("reference layout not present") }
        let rc = try RegenCoordinator.load(url: url)
        let doors = DockAprons.detectDockDoors(document: rc.document, space: .model)
        let banks = DockAprons.groupIntoBanks(doors)
        let aisles = AisleNetwork.segments(onLayerNamed: "AISLE", document: rc.document, space: .model)

        print("=== REAL FILE: dock doors + aprons ===")
        print("dock doors detected: \(doors.count)")
        print("dock banks grouped:  \(banks.count)")
        var byLayer: [String: Int] = [:]
        for d in doors { byLayer[d.layer, default: 0] += 1 }
        print("doors by source layer: \(byLayer)")

        // Building centroid as the interior hint.
        let allPts = doors.map(\.position)
        let hint = AisleNetwork.centroid(of: allPts)

        var withSuggestion = 0
        print("--- per-bank suggested depth (from nearest PARALLEL aisle) ---")
        for b in banks.prefix(14) {
            let nums = b.numbers
            let label = "docks \(nums.first ?? 0)-\(nums.last ?? 0) (n=\(nums.count))"
            if let d = DockAprons.suggestedDepth(for: b, aisleSegments: aisles) {
                withSuggestion += 1
                print(String(format: "   %-26@ suggested depth %6.1f ft", label as NSString, d / 12))
            } else {
                print("   \(label) — no parallel aisle within range; depth must be supplied")
            }
        }
        for b in banks.dropFirst(14) {
            if DockAprons.suggestedDepth(for: b, aisleSegments: aisles) != nil { withSuggestion += 1 }
        }
        print("banks with an automatic depth suggestion: \(withSuggestion)/\(banks.count)")

        let aprons = DockAprons.aprons(for: banks, depth: 40 * 12, interiorHint: hint)
        print("aprons generated at 40 ft depth: \(aprons.count)")
        let frontFt = aprons.map { $0.frontage / 12 }.sorted()
        if !frontFt.isEmpty {
            print(String(format: "apron frontage (ft): min=%.1f median=%.1f max=%.1f",
                         frontFt.first!, frontFt[frontFt.count/2], frontFt.last!))
        }

        XCTAssertGreaterThan(doors.count, 80, "should find the dock labels in a large production layout")
        XCTAssertGreaterThan(banks.count, 10, "should group them into real banks")
        XCTAssertFalse(aprons.isEmpty, "should generate apron shapes")
    }

    func testRealJunctionDetectionAndDiskSizing() throws {
        guard let url = fixtureURL else { throw XCTSkip("reference layout not present") }
        let rc = try RegenCoordinator.load(url: url)
        let segs = AisleNetwork.segments(onLayerNamed: "AISLE", document: rc.document, space: .model)
        let (corridors, unpaired) = AisleNetwork.detectCorridors(from: segs)
        let anns = AisleNetwork.widthAnnotations(onLayerNamed: "AISLE", document: rc.document, space: .model)
        let filled = AisleNetwork.applyWidthAnnotations(anns, to: corridors, maxDistance: 600)
        let unpairedCorridors = unpaired.map { AisleNetwork.Corridor(centerline: $0, width: nil) }
        let allCorridors = filled + AisleNetwork.applyWidthAnnotations(anns, to: unpairedCorridors, maxDistance: 600)
        let fallback = 13.34 * 12.0

        print("=== REAL FILE: junctions on AISLE ===")
        let junctions = AisleNetwork.junctions(for: allCorridors, fallbackWidth: fallback)
        print("junctions detected: \(junctions.count)")
        var byDegree: [Int: Int] = [:]
        for j in junctions { byDegree[j.degree, default: 0] += 1 }
        print("  by degree: \(byDegree.sorted { $0.key < $1.key }.map { "\($0.key)-way: \($0.value)" }.joined(separator: ", "))")

        let widthsFt = junctions.map { $0.width / 12 }.sorted()
        if !widthsFt.isEmpty {
            print(String(format: "junction disk-driving widths (ft): min=%.1f median=%.1f max=%.1f",
                         widthsFt.first!, widthsFt[widthsFt.count / 2], widthsFt.last!))
        }

        let disks = AisleNetwork.junctionDisks(for: junctions)
        XCTAssertEqual(disks.count, junctions.count, "every junction must produce exactly one disk")
        for d in disks {
            XCTAssertGreaterThan(d.radius, 0, "a real junction's disk must have a positive radius")
        }

        // Every disk must fully cover its narrowest possible contributing
        // ribbon half-width — i.e. radius must equal half of the WIDEST
        // meeting corridor, never less than any single meeting corridor's
        // own half-width (would leave a sliver gap on that ribbon's side).
        var widthsAtPoint: [String: [Double]] = [:]
        for c in allCorridors {
            let w = c.width ?? fallback
            for p in [c.centerline.a, c.centerline.b] {
                let key = String(format: "%.0f,%.0f", (p.x / 6).rounded() * 6, (p.y / 6).rounded() * 6)
                widthsAtPoint[key, default: []].append(w)
            }
        }
        var checked = 0
        for j in junctions {
            let key = String(format: "%.0f,%.0f", (j.point.x / 6).rounded() * 6, (j.point.y / 6).rounded() * 6)
            guard let ws = widthsAtPoint[key], let maxW = ws.max() else { continue }
            XCTAssertGreaterThanOrEqual(j.width, maxW - 1e-3,
                                        "junction disk radius must cover the widest meeting corridor at \(key)")
            checked += 1
        }
        print("junction-width-vs-widest-meeting-corridor checks performed: \(checked)")

        XCTAssertGreaterThan(junctions.count, 5, "a real multi-aisle layout should have several bends/branches")
    }
}
