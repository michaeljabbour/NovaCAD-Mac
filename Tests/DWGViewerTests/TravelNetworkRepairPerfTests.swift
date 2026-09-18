import XCTest
@testable import DWGViewer
import CoreGraphics
import CADCore

/// Guards the repair NON-TERMINATION bug against a large production layout.
///
/// `AisleNetwork.repair` used to bridge one gap per pass and re-analyze after
/// each (O(n^2) per pass), and counted a gap as applied even when its bridge
/// was degenerate — so a gap whose endpoints quantized to one node was
/// re-found forever. On a large production layout it never returned. It now
/// completes in well under a second.
///
/// Skips when the fixture isn't present.
final class TravelNetworkRepairPerfTests: XCTestCase {
    private var fixtureURL: URL? {
        guard let path = ProcessInfo.processInfo.environment["NOVACAD_SAMPLE_LAYOUT"] else { return nil }
        return FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
    }

    private func time<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
        let t0 = Date()
        let r = try body()
        FileHandle.standardError.write(Data(String(format: "[perf] %-34@ %.2fs\n",
                                                   label as NSString,
                                                   Date().timeIntervalSince(t0)).utf8))
        return r
    }

    private func note(_ s: String) {
        FileHandle.standardError.write(Data("[perf] \(s)\n".utf8))
    }

    /// Regression guard for the repair non-termination bug: preparing a
    /// large production layout's travel network previously never returned.
    /// It now completes in well under a second; the 60s budget is loose
    /// enough to tolerate a slow CI machine while still failing loudly if
    /// the O(n^2)-per-bridge behaviour is ever reintroduced.
    func testPrepareRealLayoutCompletesQuickly() throws {
        guard let url = fixtureURL else { throw XCTSkip("reference layout not present") }
        let rc = try time("load document") { try RegenCoordinator.load(url: url) }
        let raw = time("extract segments") {
            AisleNetwork.segments(onLayerNamed: "AISLE", document: rc.document, space: .model)
        }
        note("raw segments: \(raw.count)")

        let (corridors, unpaired) = time("detectCorridors") { AisleNetwork.detectCorridors(from: raw) }
        note("corridors: \(corridors.count), unpaired: \(unpaired.count)")

        var travel = corridors.map(\.centerline) + unpaired
        travel = time("deduplicateCollinear") { TravelNetwork.deduplicateCollinear(travel) }
        note("after dedupe: \(travel.count)")

        let split = time("splitAtIntersections") { AisleNetwork.splitAtIntersections(travel) }
        note("after split: \(split.count)")

        let analysis = time("analyze") { AisleNetwork.analyze(segments: split) }
        note("components: \(analysis.components.count), gaps: \(analysis.gaps.count)")

        let repaired = time("repair @25ft") {
            AisleNetwork.repair(segments: split, autoBridgeUpTo: 25 * 12)
        }
        note("repair applied: \(repaired.applied.count), components \(repaired.before.components.count) -> \(repaired.after.components.count)")

        let started = Date()
        let full = TravelNetwork.prepare(layerNames: ["AISLE"], document: rc.document,
                                         space: .model, visibility: nil, mode: .auto, autoRepairFeet: 25)
        let elapsed = Date().timeIntervalSince(started)
        note(String(format: "TravelNetwork.prepare (end to end) %.2fs", elapsed))
        note("prepared segments: \(full.segments.count)")

        XCTAssertLessThan(elapsed, 60,
                          "preparing the real aisle network must not regress into the non-terminating repair loop")
        XCTAssertFalse(full.isEmpty)
        XCTAssertLessThan(full.componentsAfter, full.componentsBefore / 4,
                          "in-memory repair should substantially reconnect the real network")
    }
}
