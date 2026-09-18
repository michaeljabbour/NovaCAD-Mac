import Foundation
import CoreGraphics
import CADCore

// MARK: - Travel network: an accurate, self-healing routing graph
//
// The measurement layer behind the AI Assistant's travel-distance tools.
// `AisleNetwork` supplies the primitives (segment extraction, intersection
// splitting, corridor/boundary-pair detection, gap finding, A*); this file
// composes them into ONE prepared, routable graph and answers distance
// questions against it.
//
// ---- Why this exists: routed distances were coming back ~2x too long ----
//
// `route_along_aisles` and `export_workstation_travel_distances` routed over
// the RAW segments returned by `AisleNetwork.segments(onLayerNamed:)`. On a
// real plant layout that layer is not a centerline graph — it also carries
// the two parallel BOUNDARY edge lines that draw each aisle's sides
// (measured on the reference file: of 829 segments, 294 form parallel
// overlapping pairs 6.7'-33.2' apart). `AisleNetwork.detectCorridors` already
// knows this and is used by the shading tool, but routing never was.
//
// Routing over boundary edges inflates distance three separate ways, and they
// COMPOUND — which is what turns a modest modelling error into the reported
// "almost double":
//
//  1. NO CROSSINGS AT INTERSECTIONS. Where two aisles cross, their
//     centerlines intersect but their boundary edges mostly do not — the
//     edges of aisle A stop at the edges of aisle B, forming a ring around
//     the junction rather than an X through it. A route that should turn
//     straight through an intersection instead has to travel around the
//     junction box.
//  2. WRONG-SIDE COMMITMENT. Having entered along one edge line, a path
//     cannot cross to the other side of the same aisle except at a place
//     where the two edges happen to be joined (typically only at the aisle's
//     far end). A destination on the opposite side of the aisle from the
//     entry point therefore costs a full out-and-back down the aisle instead
//     of a short perpendicular hop.
//  3. DOUBLE-COUNTED PARALLEL PATHS. Both edges of one physical aisle are
//     separately traversable, so the graph contains two near-identical
//     corridors; A* picks whichever it reaches first, which is frequently not
//     the one nearer the destination, adding another lateral detour.
//
// The fix is to route on DERIVED CENTERLINES: collapse each detected boundary
// pair to the single midline between them (already implemented and tested for
// shading), keep genuinely unpaired segments as bare centerlines, then split
// at intersections so junctions become real graph nodes.
//
// ---- Second correctness issue: fragmented networks ----
//
// Real aisle layers are drawn as visual annotations that merely LOOK
// continuous; the reference file splits into 43+ disconnected components.
// Routing across those either failed outright or (worse) succeeded via a long
// way around. `TravelNetwork` therefore repairs the graph IN MEMORY before
// measuring, and reports every bridge it used so the numbers stay auditable.
enum TravelNetwork {

    /// Feet <-> drawing-unit conversion. These plant layouts are authored in
    /// inches; every user-facing number here is feet.
    static let inchesPerFoot = 12.0

    // MARK: - Configuration

    /// How the routable graph is derived from the raw layer geometry.
    enum CenterlineMode: String, Codable, CaseIterable {
        /// Detect boundary pairs, collapse them to midlines, and keep
        /// unpaired segments as-is. Correct for the common real-world layer
        /// that mixes centerlines and edge lines.
        case auto
        /// Use ONLY derived midlines; discard unpaired segments. For a layer
        /// known to be pure boundary linework.
        case centerlinesOnly
        /// Route the raw segments verbatim (the old, usually-inflated
        /// behavior). Retained for comparison/diagnosis.
        case raw

        var explanation: String {
            switch self {
            case .auto:
                return "boundary-line pairs collapsed to centerlines; unpaired segments kept as centerlines"
            case .centerlinesOnly:
                return "only centerlines derived from boundary pairs were used"
            case .raw:
                return "raw layer geometry used verbatim (boundary edge lines included — distances are typically inflated)"
            }
        }
    }

    /// Whether a reported distance covers travel out only, or out and back.
    enum TripType: String, Codable, CaseIterable {
        case oneWay
        case roundTrip

        /// Multiplier applied to a one-way path length.
        var multiplier: Double { self == .roundTrip ? 2 : 1 }

        var label: String { self == .roundTrip ? "round trip" : "one way" }

        /// Lenient parse so the model can say "round_trip", "round trip",
        /// "roundtrip", "one-way", etc.
        static func parse(_ raw: String?) -> TripType? {
            guard let raw else { return nil }
            let k = raw.lowercased().filter { $0.isLetter }
            if k.contains("round") || k == "rt" || k.contains("both") || k.contains("return") {
                return .roundTrip
            }
            if k.contains("one") || k == "ow" || k.contains("single") { return .oneWay }
            return nil
        }
    }

    /// Default auto-repair budget. Gaps at or under this are bridged in the
    /// working graph so a drafting slip doesn't force a long detour or an
    /// outright routing failure. Chosen to comfortably cover the "aisle stops
    /// a few units short of the cross-aisle" defect while staying far below
    /// any genuine physical separation (the reference file's real wall
    /// separations start around 9,600 units / 800 ft).
    static let defaultAutoRepairFeet: Double = 25

    // MARK: - The prepared network

    /// A fully prepared, routable aisle network plus the provenance needed to
    /// defend its numbers. Build ONCE per batch and reuse: preparation is the
    /// expensive part (O(n^2) pairing + splitting), routing against it is
    /// cheap.
    struct Prepared {
        /// Intersection-split segments, ready for `AisleNetwork.routePrepared`.
        var segments: [AisleNetwork.Segment]
        /// The graph mode actually used.
        var mode: CenterlineMode
        /// Bridges auto-applied during preparation (in-memory repairs).
        var bridges: [AisleNetwork.Segment]
        /// Gaps left unbridged because they exceeded the repair budget.
        var deferredGaps: [AisleNetwork.Gap]
        /// Connectivity before and after preparation.
        var componentsBefore: Int
        var componentsAfter: Int
        /// Raw segment count on the source layer(s), pre-derivation.
        var rawSegmentCount: Int
        /// How many boundary pairs were collapsed into centerlines.
        var collapsedPairCount: Int
        /// Segments that were never paired (kept as bare centerlines in
        /// `.auto`, discarded in `.centerlinesOnly`).
        var unpairedCount: Int
        /// Share of total network length held by the largest component after
        /// repair — the single clearest "is this network usable?" number.
        var largestComponentShare: Double

        var isEmpty: Bool { segments.isEmpty }

        /// A compact, human-readable provenance report. Every distance the
        /// assistant quotes should be accompanied by this, so an unexpected
        /// number can be diagnosed rather than merely disbelieved.
        var diagnostics: String {
            var lines: [String] = []
            lines.append("Network: \(rawSegmentCount) raw segment(s) on the source layer(s) -> \(segments.count) routable segment(s).")
            lines.append("  Graph mode: \(mode.rawValue) (\(mode.explanation)).")
            if collapsedPairCount > 0 {
                lines.append("  \(collapsedPairCount) parallel boundary-line pair(s) were collapsed into single centerlines. "
                             + "This is what keeps distances honest: routing along an aisle's EDGE lines instead of its "
                             + "centre inflates travel (no crossings at intersections, no way to change sides mid-aisle), "
                             + "typically by 1.5-2x.")
            }
            if unpairedCount > 0 {
                lines.append("  \(unpairedCount) unpaired segment(s) treated as bare centerlines.")
            }
            if bridges.isEmpty {
                lines.append("  Connectivity: \(componentsAfter) component(s); no repairs needed.")
            } else {
                let total = bridges.reduce(0.0) { $0 + $1.length } / inchesPerFoot
                lines.append("  Repaired in memory: \(bridges.count) gap(s) bridged (\(String(format: "%.0f", total)) ft of connectors), "
                             + "\(componentsBefore) -> \(componentsAfter) connected component(s). "
                             + "These repairs affect measurement only; the drawing is unchanged unless the repair geometry is applied.")
            }
            if !deferredGaps.isEmpty {
                let smallest = (deferredGaps.map(\.distance).min() ?? 0) / inchesPerFoot
                lines.append("  \(deferredGaps.count) gap(s) left unbridged (smallest \(String(format: "%.0f", smallest)) ft) — "
                             + "likely genuine physical separations (walls, separate wings), not drafting slips.")
            }
            lines.append("  Largest component holds \(String(format: "%.0f", largestComponentShare * 100))% of total aisle length.")
            if largestComponentShare < 0.6 && componentsAfter > 1 {
                lines.append("  WARNING: the network is still substantially fragmented, so some destinations may be "
                             + "unreachable or routed the long way around. Consider raising autoRepairFeet.")
            }
            return lines.joined(separator: "\n")
        }
    }

    /// Builds a prepared travel network from one or more source layers.
    ///
    /// - Parameters:
    ///   - layerNames: aisle layer(s) to union. Multiple are supported so a
    ///     separate hand-drawn connector/repair layer can be folded in.
    ///   - mode: how to derive the routable graph (see `CenterlineMode`).
    ///   - autoRepairFeet: in-memory gap-bridging budget; 0 disables repair.
    static func prepare(layerNames: [String], document: DXFDocument, space: SpaceID,
                        visibility: VisibilityState?, mode: CenterlineMode = .auto,
                        autoRepairFeet: Double = defaultAutoRepairFeet) -> Prepared {
        var raw: [AisleNetwork.Segment] = []
        var seenLayers = Set<String>()
        for name in layerNames {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, seenLayers.insert(trimmed.lowercased()).inserted else { continue }
            raw += AisleNetwork.segments(onLayerNamed: trimmed, document: document,
                                         space: space, visibility: visibility)
        }
        return prepare(rawSegments: raw, mode: mode, autoRepairFeet: autoRepairFeet)
    }

    /// Geometry-only preparation, so the whole derivation is unit-testable on
    /// hand-built fixtures with no document at all.
    static func prepare(rawSegments raw: [AisleNetwork.Segment],
                        mode: CenterlineMode = .auto,
                        autoRepairFeet: Double = defaultAutoRepairFeet) -> Prepared {
        guard !raw.isEmpty else {
            return Prepared(segments: [], mode: mode, bridges: [], deferredGaps: [],
                            componentsBefore: 0, componentsAfter: 0, rawSegmentCount: 0,
                            collapsedPairCount: 0, unpairedCount: 0, largestComponentShare: 0)
        }

        // ---- Step 1: derive travel centerlines ----
        var travel: [AisleNetwork.Segment]
        var collapsed = 0
        var unpaired = 0
        switch mode {
        case .raw:
            travel = raw
        case .auto, .centerlinesOnly:
            let (corridors, leftovers) = AisleNetwork.detectCorridors(from: raw)
            collapsed = corridors.count
            unpaired = leftovers.count
            travel = corridors.map(\.centerline)
            if mode == .auto {
                // Keep unpaired geometry: on a mixed layer these are the
                // genuine hand-drawn centerlines (and short connector stubs)
                // that have no opposite edge to pair with. Dropping them
                // would disconnect large parts of the network.
                travel += leftovers
            }
            // A layer that yielded no pairs at all is already a pure
            // centerline layer; collapsing produced nothing, so fall back to
            // the raw geometry rather than routing an empty graph.
            if travel.isEmpty { travel = raw }
        }

        // ---- Step 2: de-duplicate near-coincident centerlines ----
        // Boundary-pair detection can emit two midlines that describe the
        // same physical corridor (e.g. a three-line aisle where the middle
        // line pairs with each outer line in turn). Left in, they double the
        // node count at every junction and give A* a second, slightly-worse
        // parallel path to wander onto.
        travel = deduplicateCollinear(travel)

        // ---- Step 3: split at intersections so junctions are real nodes ----
        var prepared = AisleNetwork.splitAtIntersections(travel)
        let before = AisleNetwork.analyze(segments: prepared)

        // ---- Step 4: repair in memory ----
        var bridges: [AisleNetwork.Segment] = []
        var deferred: [AisleNetwork.Gap] = []
        if autoRepairFeet > 0 {
            let result = AisleNetwork.repair(segments: prepared,
                                             autoBridgeUpTo: autoRepairFeet * inchesPerFoot)
            prepared = result.segments
            bridges = AisleNetwork.bridgeSegments(for: result.applied)
            deferred = result.deferred
        } else {
            deferred = before.gaps
        }

        let after = AisleNetwork.analyze(segments: prepared)
        return Prepared(segments: prepared, mode: mode, bridges: bridges, deferredGaps: deferred,
                        componentsBefore: before.components.count,
                        componentsAfter: after.components.count,
                        rawSegmentCount: raw.count,
                        collapsedPairCount: collapsed, unpairedCount: unpaired,
                        largestComponentShare: after.largestComponentShare)
    }

    /// Drops centerlines that duplicate one already kept: same direction,
    /// negligible perpendicular offset, and overlapping extent. Keeps the
    /// longer of each duplicate set.
    static func deduplicateCollinear(_ segments: [AisleNetwork.Segment]) -> [AisleNetwork.Segment] {
        guard segments.count > 1 else { return segments }
        // Two centerlines this close together cannot be separate aisles — a
        // real corridor pair is `minPlausibleWidth` (4 ft) apart at minimum.
        let offsetTolerance = AisleNetwork.minPlausibleWidth / 4
        let angleTolerance = 2.0 * .pi / 180

        let order = segments.indices.sorted { segments[$0].length > segments[$1].length }
        var kept: [AisleNetwork.Segment] = []
        kept.reserveCapacity(segments.count)
        for idx in order {
            let candidate = segments[idx]
            guard candidate.length > AisleNetwork.minSegmentLength else { continue }
            var duplicate = false
            for existing in kept {
                guard angleDelta(candidate, existing) <= angleTolerance else { continue }
                guard let d1 = perpendicularDistance(candidate.a, toLineThrough: existing),
                      let d2 = perpendicularDistance(candidate.b, toLineThrough: existing),
                      d1 <= offsetTolerance, d2 <= offsetTolerance else { continue }
                guard overlapsAlong(existing, candidate) else { continue }
                duplicate = true
                break
            }
            if !duplicate { kept.append(candidate) }
        }
        return kept
    }

    private static func angleDelta(_ s: AisleNetwork.Segment, _ t: AisleNetwork.Segment) -> Double {
        func mod180(_ seg: AisleNetwork.Segment) -> Double {
            var a = atan2(Double(seg.b.y - seg.a.y), Double(seg.b.x - seg.a.x))
            if a < 0 { a += .pi }
            if a >= .pi { a -= .pi }
            return a
        }
        let d = abs(mod180(s) - mod180(t))
        return min(d, .pi - d)
    }

    private static func perpendicularDistance(_ p: CGPoint, toLineThrough s: AisleNetwork.Segment) -> Double? {
        let dx = Double(s.b.x - s.a.x), dy = Double(s.b.y - s.a.y)
        let len = (dx * dx + dy * dy).squareRoot()
        guard len > 1e-9 else { return nil }
        return abs(Double(p.x - s.a.x) * dy - Double(p.y - s.a.y) * dx) / len
    }

    /// True when `t` projects onto `s`'s extent with meaningful overlap.
    private static func overlapsAlong(_ s: AisleNetwork.Segment, _ t: AisleNetwork.Segment) -> Bool {
        let dx = Double(s.b.x - s.a.x), dy = Double(s.b.y - s.a.y)
        let len = (dx * dx + dy * dy).squareRoot()
        guard len > 1e-9 else { return false }
        let ux = dx / len, uy = dy / len
        let t0 = Double(t.a.x - s.a.x) * ux + Double(t.a.y - s.a.y) * uy
        let t1 = Double(t.b.x - s.a.x) * ux + Double(t.b.y - s.a.y) * uy
        return max(t0, t1) > 0 && min(t0, t1) < len
    }

    // MARK: - Anchors (where a trip actually starts and ends)

    /// How a point-of-travel is derived from an object's footprint.
    ///
    /// An INSERT's reference point is an arbitrary block datum that can sit
    /// well outside the drawn shape, and a marketplace's centroid is deep
    /// inside a large area nobody drives through. A forklift leaves from the
    /// closest point on the object's OUTLINE to the aisle it uses, which is
    /// what `.nearestEdge` models.
    enum Anchor: String, Codable {
        case nearestEdge
        case centroid
        case insertionPoint

        static func parse(_ raw: String?) -> Anchor? {
            guard let raw else { return nil }
            let k = raw.lowercased().filter { $0.isLetter }
            if k.contains("edge") || k.contains("nearest") || k.contains("perimeter") { return .nearestEdge }
            if k.contains("centroid") || k.contains("center") || k.contains("centre") || k.contains("mid") { return .centroid }
            if k.contains("insert") || k.contains("datum") || k.contains("origin") { return .insertionPoint }
            return nil
        }
    }

    /// Resolves the travel point for a footprint under the given anchor rule.
    static func anchorPoint(for bounds: CGRect, insertionPoint: CGPoint,
                            anchor: Anchor, network: [AisleNetwork.Segment]) -> CGPoint {
        switch anchor {
        case .insertionPoint:
            return insertionPoint
        case .centroid:
            guard bounds.width > 0 || bounds.height > 0 else { return insertionPoint }
            return CGPoint(x: bounds.midX, y: bounds.midY)
        case .nearestEdge:
            guard bounds.width > 0 || bounds.height > 0 else { return insertionPoint }
            return nearestPointOnFootprint(bounds, to: network)
        }
    }

    /// The point on `bounds`' outline closest to any part of the network.
    ///
    /// Considers both directions of approach — network vertices clamped onto
    /// the rectangle, and the rectangle's own corners projected onto network
    /// segments — because either can hold the true minimum depending on
    /// whether the aisle runs past the footprint's face or its corner.
    static func nearestPointOnFootprint(_ bounds: CGRect,
                                        to segments: [AisleNetwork.Segment]) -> CGPoint {
        guard !segments.isEmpty else { return CGPoint(x: bounds.midX, y: bounds.midY) }
        let corners = [CGPoint(x: bounds.minX, y: bounds.minY), CGPoint(x: bounds.maxX, y: bounds.minY),
                       CGPoint(x: bounds.maxX, y: bounds.maxY), CGPoint(x: bounds.minX, y: bounds.maxY)]
        var best = CGPoint(x: bounds.midX, y: bounds.midY)
        var bestDistance = Double.infinity

        for segment in segments {
            // Network endpoints clamped onto the footprint rectangle.
            for endpoint in [segment.a, segment.b] {
                let clamped = CGPoint(x: min(max(endpoint.x, bounds.minX), bounds.maxX),
                                      y: min(max(endpoint.y, bounds.minY), bounds.maxY))
                let d = hypot(endpoint.x - clamped.x, endpoint.y - clamped.y)
                if d < bestDistance { bestDistance = d; best = clamped }
            }
            // Footprint corners projected onto the segment.
            let dx = segment.b.x - segment.a.x, dy = segment.b.y - segment.a.y
            let l2 = Double(dx * dx + dy * dy)
            guard l2 > 0 else { continue }
            for corner in corners {
                let t = min(1, max(0, Double((corner.x - segment.a.x) * dx + (corner.y - segment.a.y) * dy) / l2))
                let onSeg = CGPoint(x: segment.a.x + CGFloat(t) * dx, y: segment.a.y + CGFloat(t) * dy)
                let d = hypot(onSeg.x - corner.x, onSeg.y - corner.y)
                if d < bestDistance { bestDistance = d; best = corner }
            }
        }
        return best
    }

    // MARK: - Measurement

    /// One measured trip.
    struct Measurement {
        var path: [CGPoint]
        /// Distance travelled along aisle centerlines.
        var aisleLengthFeet: Double
        /// Off-aisle approach at the origin end.
        var originConnectorFeet: Double
        /// Off-aisle approach at the destination end.
        var destinationConnectorFeet: Double

        /// Total for a single outbound trip.
        var oneWayFeet: Double { aisleLengthFeet + originConnectorFeet + destinationConnectorFeet }
        /// Out and back.
        var roundTripFeet: Double { oneWayFeet * 2 }

        func feet(for trip: TripType) -> Double { oneWayFeet * trip.multiplier }
    }

    enum MeasurementFailure: Error {
        case emptyNetwork
        case disconnected(origin: Int, destination: Int)

        var explanation: String {
            switch self {
            case .emptyNetwork:
                return "the aisle network is empty, or the endpoints could not be placed on it"
            case .disconnected(let a, let b):
                return "origin and destination are in disconnected parts of the network (component \(a) vs \(b)); "
                    + "raise autoRepairFeet or repair the aisle network first"
            }
        }
    }

    /// Measures one trip against a prepared network.
    static func measure(from origin: CGPoint, to destination: CGPoint,
                        in prepared: Prepared) -> Result<Measurement, MeasurementFailure> {
        guard !prepared.isEmpty else { return .failure(.emptyNetwork) }
        switch AisleNetwork.routePrepared(from: origin, to: destination, segments: prepared.segments) {
        case .success(let route):
            return .success(Measurement(
                path: route.points,
                aisleLengthFeet: route.aisleLength / inchesPerFoot,
                originConnectorFeet: route.startConnectorLength / inchesPerFoot,
                destinationConnectorFeet: route.endConnectorLength / inchesPerFoot))
        case .failure(.emptyNetwork):
            return .failure(.emptyNetwork)
        case .failure(.disconnected(let a, let b)):
            return .failure(.disconnected(origin: a, destination: b))
        }
    }

    /// Straight-line origin-to-destination distance in feet — reported
    /// alongside routed distance as a sanity check. A routed/direct ratio far
    /// above ~2.0 on an open plant floor is the signature of a bad graph
    /// (boundary-line routing, or a missing connection forcing a detour),
    /// which is exactly the failure this file exists to prevent.
    static func directFeet(from a: CGPoint, to b: CGPoint) -> Double {
        hypot(Double(b.x - a.x), Double(b.y - a.y)) / inchesPerFoot
    }
}
