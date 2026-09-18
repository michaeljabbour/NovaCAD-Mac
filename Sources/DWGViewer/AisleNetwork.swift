import Foundation
import CoreGraphics
import CADCore

// MARK: - Aisle network extraction, repair, and routing
//
// The geometry/graph engine behind the AI Assistant's aisle-routing tools
// (`analyze_aisle_network`, `repair_aisle_network`, `route_along_aisles`,
// `find_route_endpoints` — see `AIToolSchema`/`AIToolExecutor`). Deliberately
// PURE: no AI types, no UI, no Transaction — it takes geometry in and returns
// analysis/paths out, so it is fully unit-testable on hand-built fixtures and
// reusable by any caller (a future manual command, an external layout-sync
// consumer, etc). The tool layer owns all document mutation and user-approval
// staging.
//
// ---- Why this is non-trivial: real aisle layers are NOT graphs ----
//
// Measured on a real production layout (layer `AISLE`): 138 source
// polylines -> 867 segments -> 848 nodes, but
// **43 disconnected components**, with the largest holding only ~34% of the
// 484,884 units of total aisle length. Only 27 nodes had degree >= 3, where a
// genuinely connected network would have many. Aisle centerlines are drawn as
// independent VISUAL annotations that merely LOOK continuous — they routinely
// stop a few units short of the cross-aisle they appear to meet.
//
// Two distinct defects cause that, and both are handled here:
//
//  1. T-JUNCTIONS: one aisle ends ON another aisle's interior, not at its
//     endpoint. Pure endpoint-matching never sees these. `splitAtIntersections`
//     fixes them by cutting every segment at every true geometric crossing —
//     on the reference file this alone lifted the largest component from 15%
//     to 33% of nodes.
//  2. NEAR-MISS GAPS: an endpoint stops short of its intended connection.
//     Raising the snap tolerance does NOT fix these (measured: 6->192 units
//     only moved 48 -> 37 components), because the missing links are mostly
//     endpoint->interior, not endpoint->endpoint. `findGaps` therefore
//     measures each dangling endpoint to the nearest point on any OTHER
//     component's segments (projection, not just endpoints).
//
// Gaps are REPORTED, never silently bridged: on the reference file they range
// from 33 units (an obvious drafting slip) to 9,643 units (a genuine physical
// separation between building wings that must NOT be auto-joined, or the
// router would invent an aisle straight through a wall). The tool layer
// presents the inventory and applies only what the user approves.
enum AisleNetwork {

    // MARK: - Geometry primitives

    /// A straight aisle segment in world space. Curved aisle geometry (ARC/
    /// SPLINE) is consumed as its already-flattened polyline approximation
    /// from the render model, so everything here is straight-line.
    struct Segment: Equatable {
        var a: CGPoint
        var b: CGPoint
        var length: Double { hypot(b.x - a.x, b.y - a.y) }
    }

    /// A candidate connection that would merge two disconnected components.
    /// `kind` distinguishes the two defect shapes described in this file's
    /// header comment, because they warrant different confidence: an
    /// `endpoint` gap is two aisle ends not quite meeting, while a
    /// `tJunction` gap is an aisle end stopping short of another aisle's
    /// interior (the more common real-world drafting slip).
    struct Gap: Equatable {
        enum Kind: String, Codable { case endpoint, tJunction }
        /// The dangling endpoint that needs connecting.
        var from: CGPoint
        /// The point it should connect TO (may be mid-segment for `.tJunction`).
        var to: CGPoint
        var distance: Double
        var kind: Kind
        var fromComponent: Int
        var toComponent: Int
    }

    /// One connected piece of the aisle network.
    struct Component: Equatable {
        var id: Int
        var nodeCount: Int
        /// Total aisle length in this component (drawing units) — the honest
        /// measure of how much of the network it represents, far more
        /// meaningful than node count (a long straight aisle has 2 nodes).
        var length: Double
        var bounds: CGRect
    }

    /// The full analysis result — what `analyze_aisle_network` reports.
    struct Analysis {
        var segmentCount: Int
        var nodeCount: Int
        var danglingEndpointCount: Int
        var components: [Component]
        /// Sorted ascending by distance, so the caller can threshold trivially
        /// ("auto-fix everything under N") and so the most-likely-accidental
        /// gaps are presented first.
        var gaps: [Gap]
        var totalLength: Double

        var isFullyConnected: Bool { components.count <= 1 }
        /// Fraction of total aisle length held by the largest component — the
        /// single clearest "how usable is this network?" number.
        var largestComponentShare: Double {
            guard totalLength > 0, let biggest = components.map(\.length).max() else { return 0 }
            return biggest / totalLength
        }
    }

    // MARK: - Tolerances
    //
    // Node identity uses a small absolute quantization rather than an
    // epsilon-compare so graph lookups stay O(1) hashed. 2.0 drawing units is
    // far below any real aisle feature size (aisle widths on the reference
    // file are hundreds of units) while still absorbing the sub-unit
    // coordinate noise DWG->DXF conversion introduces.
    static let nodeQuantum: Double = 2.0
    /// Segments shorter than this are dropped as degenerate (duplicate
    /// vertices, zero-length closing segments).
    static let minSegmentLength: Double = 1e-6

    /// Quantized node identity. `fileprivate` rather than `private` so
    /// `Graph`'s own storage can reference it (Swift forbids a `fileprivate`
    /// member whose type is `private`).
    fileprivate struct NodeKey: Hashable { var x: Int; var y: Int }

    private static func nodeKey(_ p: CGPoint) -> NodeKey {
        NodeKey(x: Int((p.x / nodeQuantum).rounded()), y: Int((p.y / nodeQuantum).rounded()))
    }

    // MARK: - Step 1: intersection splitting
    //
    // Cuts every segment at every point where it truly crosses or touches
    // another, so T-junctions become shared graph nodes. Without this, an
    // aisle ending on another aisle's interior is invisible to the graph (see
    // this file's header comment for the measured impact).
    //
    // O(n^2) in segment count by design: aisle layers are small (hundreds of
    // segments — 867 on the reference file), and a spatial index's complexity
    // isn't justified at that scale. `maxSegmentsForSplitting` guards against
    // a pathological input rather than letting it hang.
    static let maxSegmentsForSplitting = 4000

    static func splitAtIntersections(_ segments: [Segment]) -> [Segment] {
        guard segments.count <= maxSegmentsForSplitting else { return segments }
        var cuts = [[CGPoint]](repeating: [], count: segments.count)
        for i in 0..<segments.count {
            for j in (i + 1)..<segments.count {
                guard let p = intersection(segments[i], segments[j]) else { continue }
                cuts[i].append(p)
                cuts[j].append(p)
            }
        }
        var out: [Segment] = []
        out.reserveCapacity(segments.count)
        for (idx, seg) in segments.enumerated() {
            let dx = seg.b.x - seg.a.x, dy = seg.b.y - seg.a.y
            let len = hypot(dx, dy)
            guard len > minSegmentLength else { continue }
            // Order all cut points along the segment, de-duplicated by node
            // quantum so a crossing detected from both sides doesn't create
            // a zero-length fragment.
            var pts = [seg.a, seg.b] + cuts[idx]
            var seen = Set<NodeKey>()
            pts = pts.filter { seen.insert(nodeKey($0)).inserted }
            pts.sort { p, q in
                let tp = ((p.x - seg.a.x) * dx + (p.y - seg.a.y) * dy) / len
                let tq = ((q.x - seg.a.x) * dx + (q.y - seg.a.y) * dy) / len
                return tp < tq
            }
            for (p, q) in zip(pts, pts.dropFirst()) {
                let s = Segment(a: p, b: q)
                if s.length > minSegmentLength { out.append(s) }
            }
        }
        return out
    }

    /// True segment-segment intersection (including touching endpoints), or
    /// nil for parallel/non-overlapping pairs. Collinear overlap returns nil
    /// deliberately — two collinear aisles already share direction, so
    /// splitting them adds nodes without improving connectivity.
    private static func intersection(_ s1: Segment, _ s2: Segment) -> CGPoint? {
        let x1 = s1.a.x, y1 = s1.a.y, x2 = s1.b.x, y2 = s1.b.y
        let x3 = s2.a.x, y3 = s2.a.y, x4 = s2.b.x, y4 = s2.b.y
        let d = (x2 - x1) * (y4 - y3) - (y2 - y1) * (x4 - x3)
        guard abs(d) > 1e-12 else { return nil }
        let t = ((x3 - x1) * (y4 - y3) - (y3 - y1) * (x4 - x3)) / d
        let u = ((x3 - x1) * (y2 - y1) - (y3 - y1) * (x2 - x1)) / d
        guard t >= -1e-9, t <= 1 + 1e-9, u >= -1e-9, u <= 1 + 1e-9 else { return nil }
        return CGPoint(x: x1 + t * (x2 - x1), y: y1 + t * (y2 - y1))
    }

    // MARK: - Step 2: graph

    /// Adjacency graph over quantized nodes. Bidirectional by design — see
    /// this feature's product decision: nothing in the DXF encodes one-way
    /// aisle direction today, so every aisle is traversable both ways. The
    /// edge-weight model (`cost`) is kept separate from geometric length
    /// specifically so directional/penalized cost can be layered in later
    /// without reshaping the graph.
    struct Graph {
        fileprivate var adjacency: [NodeKey: Set<NodeKey>] = [:]
        fileprivate var positions: [NodeKey: CGPoint] = [:]
        /// Component id per node, assigned by `computeComponents`.
        fileprivate var componentOf: [NodeKey: Int] = [:]
        fileprivate var components: [[NodeKey]] = []

        var nodeCount: Int { positions.count }
        var componentCount: Int { components.count }

        fileprivate func neighbors(_ k: NodeKey) -> Set<NodeKey> { adjacency[k] ?? [] }
        fileprivate func degree(_ k: NodeKey) -> Int { adjacency[k]?.count ?? 0 }
    }

    static func buildGraph(from segments: [Segment]) -> Graph {
        var g = Graph()
        for s in segments {
            let ka = nodeKey(s.a), kb = nodeKey(s.b)
            guard ka != kb else { continue }
            g.adjacency[ka, default: []].insert(kb)
            g.adjacency[kb, default: []].insert(ka)
            g.positions[ka] = s.a
            g.positions[kb] = s.b
        }
        computeComponents(&g)
        return g
    }

    private static func computeComponents(_ g: inout Graph) {
        g.componentOf = [:]
        g.components = []
        var visited = Set<NodeKey>()
        for start in g.positions.keys {
            guard !visited.contains(start) else { continue }
            var members: [NodeKey] = []
            var stack = [start]
            while let k = stack.popLast() {
                guard !visited.contains(k) else { continue }
                visited.insert(k)
                members.append(k)
                for n in g.neighbors(k) where !visited.contains(n) { stack.append(n) }
            }
            let cid = g.components.count
            for m in members { g.componentOf[m] = cid }
            g.components.append(members)
        }
    }

    // MARK: - Step 3: gap detection

    /// Distance from `p` to the nearest point on segment `s`, plus that point
    /// and whether it landed on an endpoint (vs. the interior).
    private static func closestPoint(_ p: CGPoint, on s: Segment) -> (distance: Double, point: CGPoint, atEndpoint: Bool) {
        let dx = s.b.x - s.a.x, dy = s.b.y - s.a.y
        let l2 = dx * dx + dy * dy
        guard l2 > 1e-12 else { return (hypot(p.x - s.a.x, p.y - s.a.y), s.a, true) }
        var t = ((p.x - s.a.x) * dx + (p.y - s.a.y) * dy) / l2
        t = max(0, min(1, t))
        let q = CGPoint(x: s.a.x + t * dx, y: s.a.y + t * dy)
        return (hypot(p.x - q.x, p.y - q.y), q, t < 1e-9 || t > 1 - 1e-9)
    }

    /// For every dangling endpoint (degree 1 — an aisle that just stops),
    /// finds the nearest point on any OTHER component. Projection-based, not
    /// endpoint-only: the measured data shows most missing links are
    /// endpoint-to-interior, which endpoint matching cannot see.
    ///
    /// Deduplicates the symmetric case (two ends facing each other produce
    /// the same gap from both sides) so the caller sees each distinct gap
    /// once.
    static func findGaps(graph: Graph, segments: [Segment], maxDistance: Double = .infinity) -> [Gap] {
        var segmentsByComponent: [Int: [Segment]] = [:]
        for s in segments {
            guard let cid = graph.componentOf[nodeKey(s.a)] else { continue }
            segmentsByComponent[cid, default: []].append(s)
        }
        var gaps: [Gap] = []
        for (key, pos) in graph.positions where graph.degree(key) == 1 {
            guard let fromComp = graph.componentOf[key] else { continue }
            var best: (distance: Double, point: CGPoint, atEndpoint: Bool, comp: Int)?
            for (cid, segs) in segmentsByComponent where cid != fromComp {
                for s in segs {
                    let hit = closestPoint(pos, on: s)
                    if best == nil || hit.distance < best!.distance {
                        best = (hit.distance, hit.point, hit.atEndpoint, cid)
                    }
                }
            }
            guard let b = best, b.distance <= maxDistance else { continue }
            gaps.append(Gap(from: pos, to: b.point, distance: b.distance,
                            kind: b.atEndpoint ? .endpoint : .tJunction,
                            fromComponent: fromComp, toComponent: b.comp))
        }
        // Reduce to ONE gap per component pair: the shortest.
        //
        // A pair of components typically yields several raw candidates — the
        // mirrored view from each side (swapped from/to, equal distance) plus
        // the far ends of each component reaching across to the same target.
        // All of them would merge the SAME two components, so only the
        // shortest is actionable; the rest are strictly worse duplicates that
        // would clutter the user's review list (measured on the reference
        // file: 33 raw candidates collapse to the genuinely distinct set).
        // Keyed on the unordered pair so a gap and its mirror collapse
        // together regardless of which side was scanned first.
        var bestByPair: [String: Gap] = [:]
        for g in gaps.sorted(by: { $0.distance < $1.distance }) {
            let lo = min(g.fromComponent, g.toComponent)
            let hi = max(g.fromComponent, g.toComponent)
            let pairKey = "\(lo)-\(hi)"
            if let existing = bestByPair[pairKey], existing.distance <= g.distance { continue }
            bestByPair[pairKey] = g
        }
        return bestByPair.values.sorted { $0.distance < $1.distance }
    }

    // MARK: - Full analysis

    static func analyze(segments rawSegments: [Segment]) -> Analysis {
        let segments = splitAtIntersections(rawSegments)
        let graph = buildGraph(from: segments)
        let gaps = findGaps(graph: graph, segments: segments)

        var lengthByComponent: [Int: Double] = [:]
        var boundsByComponent: [Int: CGRect] = [:]
        for s in segments {
            guard let cid = graph.componentOf[nodeKey(s.a)] else { continue }
            lengthByComponent[cid, default: 0] += s.length
            let r = CGRect(x: min(s.a.x, s.b.x), y: min(s.a.y, s.b.y),
                           width: abs(s.b.x - s.a.x), height: abs(s.b.y - s.a.y))
            boundsByComponent[cid] = boundsByComponent[cid]?.union(r) ?? r
        }
        let comps = (0..<graph.componentCount).map { cid in
            Component(id: cid, nodeCount: graph.components[cid].count,
                      length: lengthByComponent[cid] ?? 0,
                      bounds: boundsByComponent[cid] ?? .zero)
        }.sorted { $0.length > $1.length }

        let dangling = graph.positions.keys.filter { graph.degree($0) == 1 }.count
        return Analysis(segmentCount: segments.count, nodeCount: graph.nodeCount,
                        danglingEndpointCount: dangling, components: comps,
                        gaps: gaps, totalLength: segments.reduce(0) { $0 + $1.length })
    }

    // MARK: - Repair

    /// Returns the bridging segments for the supplied gaps — the caller
    /// decides which gaps to pass (a threshold, or an explicitly approved
    /// subset), and owns writing them to a document. Bridges are plain
    /// straight connectors from the dangling endpoint to its target point.
    static func bridgeSegments(for gaps: [Gap]) -> [Segment] {
        gaps.compactMap { g in
            let s = Segment(a: g.from, b: g.to)
            return s.length > minSegmentLength ? s : nil
        }
    }

    /// Upper bound on repair re-planning passes. Each pass bridges every
    /// currently-actionable gap at once, so a handful of passes settles even
    /// a badly fragmented network; this exists purely so a pathological input
    /// can never spin indefinitely.
    static let maxRepairPasses = 12

    /// Convenience: analyze, auto-bridge every gap at or under `threshold`,
    /// and return the repaired segment set plus the applied/deferred split.
    /// The deferred list is what the user is asked to review.
    ///
    /// ---- Why this is BATCHED and bounded ----
    ///
    /// This previously bridged exactly ONE gap per pass and re-analyzed after
    /// each, which had two serious defects on real drawings:
    ///
    ///  1. **Non-termination.** `bridgeSegments` drops a degenerate
    ///     (sub-`minSegmentLength`) connector, but the old loop counted the
    ///     gap as `applied` regardless. When a gap's two endpoints quantized
    ///     to the same node, `repaired` was therefore left UNCHANGED while
    ///     the loop condition still found that same gap — an infinite loop
    ///     that appended to `applied` forever. Measured on the reference
    ///     plant layout, `repair` never returned.
    ///  2. **Cost.** Every pass re-ran `analyze`, whose `splitAtIntersections`
    ///     is O(n^2) in segment count. One pass per bridge over a network
    ///     needing dozens of bridges is O(bridges x n^2).
    ///
    /// Both are fixed by bridging every actionable gap in one pass (they are
    /// independent by construction — `findGaps` already reduces to one gap
    /// per component PAIR), then re-planning only to catch chains that the
    /// merged component layout newly exposes. Progress is verified explicitly
    /// each pass: if a pass fails to reduce the component count, no further
    /// pass can either, so the loop stops instead of spinning.
    static func repair(segments: [Segment], autoBridgeUpTo threshold: Double)
        -> (segments: [Segment], applied: [Gap], deferred: [Gap], before: Analysis, after: Analysis) {
        let before = analyze(segments: segments)
        var repaired = splitAtIntersections(segments)
        var applied: [Gap] = []
        var current = before
        var passes = 0

        while passes < maxRepairPasses {
            passes += 1
            let actionable = current.gaps.filter { $0.distance <= threshold }
            guard !actionable.isEmpty else { break }

            // Only gaps that yield a REAL (non-degenerate) connector count as
            // applied — this is the specific guard whose absence caused the
            // infinite loop described above. Pair each gap with ITS OWN
            // bridge explicitly rather than calling `bridgeSegments(for:)`
            // and zipping positionally: `bridgeSegments` uses `compactMap`,
            // which can drop ANY element (not just trailing ones) when a
            // gap's endpoints quantize to the same node. A later
            // `actionable.prefix(bridges.count)` therefore silently paired
            // the wrong gaps with the wrong bridges whenever a MIDDLE gap
            // was the one dropped — `applied` ended up including an
            // unbridged gap and excluding a later gap that really was
            // bridged. The staged geometry itself was unaffected (every
            // consumer re-derives its bridge lines from `applied` via a
            // fresh `bridgeSegments(for:)` call), but `applied`'s gap
            // count/list and every per-gap diagnostic built from it
            // (distance reports, "bridged N ft gap" messages) were wrong.
            let actionableBridges: [(gap: Gap, bridge: Segment)] = actionable.compactMap { g in
                let s = Segment(a: g.from, b: g.to)
                return s.length > minSegmentLength ? (g, s) : nil
            }
            guard !actionableBridges.isEmpty else { break }

            let componentsBefore = current.components.count
            repaired.append(contentsOf: actionableBridges.map(\.bridge))
            repaired = splitAtIntersections(repaired)
            let next = analyze(segments: repaired)

            // Record only the gaps that actually improved connectivity, and
            // stop if this pass achieved nothing — without this, a gap whose
            // bridge fails to merge its components (quantization landing both
            // ends on the same node) would be re-proposed every pass.
            guard next.components.count < componentsBefore else { break }
            applied.append(contentsOf: actionableBridges.map(\.gap))
            current = next
            if current.isFullyConnected { break }
        }

        let after = analyze(segments: repaired)
        let deferred = after.gaps.filter { $0.distance > threshold }
        return (repaired, applied, deferred, before, after)
    }

    // MARK: - Routing (A*)

    struct Route {
        /// Full path in world space, including the connector legs at each end.
        var points: [CGPoint]
        /// Distance travelled ALONG AISLES only (excludes connector legs) —
        /// separated so a caller can report honest "on-aisle" travel vs. the
        /// unavoidable last-mile approach.
        var aisleLength: Double
        /// Straight-line connector from the origin to the network, and from
        /// the network to the destination.
        var startConnectorLength: Double
        var endConnectorLength: Double
        var totalLength: Double { aisleLength + startConnectorLength + endConnectorLength }
    }

    enum RouteFailure: Error, Equatable {
        /// The network has no segments at all (wrong layer? empty drawing?).
        case emptyNetwork
        /// Origin and destination snapped into DIFFERENT disconnected
        /// components — reported rather than bridged, so the router never
        /// invents an aisle through a wall. Carries the component ids and
        /// their sizes so the caller can explain exactly what's disconnected.
        case disconnected(originComponent: Int, destinationComponent: Int)
    }

    /// Routes from `origin` to `destination` along the aisle network.
    ///
    /// Both endpoints are snapped to their nearest point on the network
    /// (docks and stations sit BESIDE aisles, never on them), and those
    /// straight approach legs are reported separately from on-aisle travel.
    /// Uses A* with straight-line distance as the heuristic — admissible for
    /// Euclidean edge weights, so the result is a true shortest path.
    static func route(from origin: CGPoint, to destination: CGPoint,
                      segments rawSegments: [Segment]) -> Result<Route, RouteFailure> {
        routePrepared(from: origin, to: destination, segments: splitAtIntersections(rawSegments))
    }

    /// Batch-routing entry point for callers that have already split the
    /// network once. Workstation exports can contain thousands of endpoints;
    /// repeating the O(E^2) intersection pass for every row is unnecessary.
    static func routePrepared(from origin: CGPoint, to destination: CGPoint,
                              segments preparedSegments: [Segment]) -> Result<Route, RouteFailure> {
        var segments = preparedSegments
        guard !segments.isEmpty else { return .failure(.emptyNetwork) }

        func nearestProjection(_ p: CGPoint) -> (segment: Int, point: CGPoint, distance: Double)? {
            var best: (Int, CGPoint, Double)?
            for (index, s) in segments.enumerated() {
                let hit = closestPoint(p, on: s)
                if best == nil || hit.distance < best!.2 { best = (index, hit.point, hit.distance) }
            }
            return best
        }

        guard let startHit = nearestProjection(origin), let goalHit = nearestProjection(destination) else {
            return .failure(.emptyNetwork)
        }

        // Make both true projected access points graph nodes. This avoids the
        // old behavior of driving diagonally to an arbitrary end of a long
        // aisle segment and gives honest first/last-mile connector lengths.
        var cutsBySegment: [Int: [CGPoint]] = [:]
        cutsBySegment[startHit.segment, default: []].append(startHit.point)
        cutsBySegment[goalHit.segment, default: []].append(goalHit.point)
        var augmented: [Segment] = []
        augmented.reserveCapacity(segments.count + 2)
        for (index, segment) in segments.enumerated() {
            guard let cuts = cutsBySegment[index], !cuts.isEmpty else {
                augmented.append(segment)
                continue
            }
            let dx = segment.b.x - segment.a.x, dy = segment.b.y - segment.a.y
            let length2 = dx * dx + dy * dy
            var points = [segment.a, segment.b] + cuts
            var seen = Set<NodeKey>()
            points = points.filter { seen.insert(nodeKey($0)).inserted }
            points.sort {
                (($0.x - segment.a.x) * dx + ($0.y - segment.a.y) * dy) / length2
                    < (($1.x - segment.a.x) * dx + ($1.y - segment.a.y) * dy) / length2
            }
            for (a, b) in zip(points, points.dropFirst()) where hypot(b.x - a.x, b.y - a.y) > minSegmentLength {
                augmented.append(Segment(a: a, b: b))
            }
        }
        segments = augmented
        let graph = buildGraph(from: segments)
        let start = (node: nodeKey(startHit.point), point: startHit.point, distance: startHit.distance)
        let goal = (node: nodeKey(goalHit.point), point: goalHit.point, distance: goalHit.distance)
        guard let sc = graph.componentOf[start.node], let gc = graph.componentOf[goal.node] else {
            return .failure(.emptyNetwork)
        }
        guard sc == gc else {
            return .failure(.disconnected(originComponent: sc, destinationComponent: gc))
        }

        // ---- A* ----
        func h(_ k: NodeKey) -> Double {
            guard let p = graph.positions[k], let q = graph.positions[goal.node] else { return 0 }
            return hypot(q.x - p.x, q.y - p.y)
        }
        var gScore: [NodeKey: Double] = [start.node: 0]
        var cameFrom: [NodeKey: NodeKey] = [:]
        var open: Set<NodeKey> = [start.node]
        var closed = Set<NodeKey>()

        while !open.isEmpty {
            // Small graphs (hundreds of nodes) — a linear min scan is
            // simpler and faster in practice than maintaining a heap.
            guard let current = open.min(by: { (gScore[$0] ?? .infinity) + h($0) < (gScore[$1] ?? .infinity) + h($1) })
            else { break }
            if current == goal.node { break }
            open.remove(current)
            closed.insert(current)
            guard let cp = graph.positions[current] else { continue }
            for n in graph.neighbors(current) where !closed.contains(n) {
                guard let np = graph.positions[n] else { continue }
                let tentative = (gScore[current] ?? .infinity) + hypot(np.x - cp.x, np.y - cp.y)
                if tentative < (gScore[n] ?? .infinity) {
                    cameFrom[n] = current
                    gScore[n] = tentative
                    open.insert(n)
                }
            }
        }
        guard gScore[goal.node] != nil else {
            // Same component but unreachable shouldn't happen; treated as
            // disconnected rather than silently returning a bogus path.
            return .failure(.disconnected(originComponent: sc, destinationComponent: gc))
        }

        var nodePath: [NodeKey] = [goal.node]
        var cursor = goal.node
        while let prev = cameFrom[cursor] {
            nodePath.append(prev)
            cursor = prev
        }
        nodePath.reverse()
        let aislePoints = nodePath.compactMap { graph.positions[$0] }

        var points: [CGPoint] = [origin]
        points.append(contentsOf: aislePoints)
        points.append(destination)
        points = points.reduce(into: []) { result, point in
            if let last = result.last, nodeKey(last) == nodeKey(point) { return }
            result.append(point)
        }
        return .success(Route(points: points,
                              aisleLength: gScore[goal.node] ?? 0,
                              startConnectorLength: start.distance,
                              endConnectorLength: goal.distance))
    }

    // MARK: - Extraction from a live document
    //
    // Reads aisle centerlines off the ALREADY-EXPANDED, ALREADY-WORLD-SPACE
    // render model (`DXFDocument.modelGroups`/`paperGroups`), exactly as
    // `DrawingReader`/`HitTester`/`SelectionEngine` do — never a raw
    // `EntityStore` walk. That guarantees the graph matches what the user
    // actually SEES on canvas (block-nested aisles, INSERT transforms, and
    // xref content all already resolved) without re-deriving transform math
    // here. It also means curved aisle geometry arrives pre-flattened into
    // polyline runs, so `Segment` only ever needs to be straight.

    /// Every aisle segment on `layerName`. Matching is case-insensitive and
    /// matches an xref-qualified layer too (`XREFNAME|AISLE`), since a
    /// production layout routinely carries its aisles inside an xref — the
    /// user names the plain layer, and both forms resolve.
    ///
    /// `visibility`, when supplied, scopes extraction to CURRENTLY VISIBLE
    /// model-space state — a layer the user has frozen/hidden (or a
    /// STATION BLOCKS-style isolate) is excluded, exactly as `DrawingReader
    /// .summarize` already does for the AI's read tools. This matters for
    /// every aisle/dock tool: "analyze the aisle network" must analyze what
    /// the user is actually looking at right now, not stale geometry they've
    /// deliberately hidden (e.g. a demolished-phase aisle layer toggled off).
    /// `nil` (the default) analyzes every layer regardless of visibility —
    /// used by callers that explicitly want the full drawing state
    /// (`RealAisleNetworkValidationTests`, `AisleNetworkTests`'s hand-built
    /// fixtures with no `VisibilityState` at all).
    static func segments(onLayerNamed layerName: String, document: DXFDocument,
                         space: SpaceID, visibility: VisibilityState? = nil) -> [Segment] {
        let groups = space == .paper ? document.paperGroups : document.modelGroups
        let wanted = layerName.lowercased()
        var out: [Segment] = []
        for g in groups {
            let idx = Int(g.layerId)
            guard idx >= 0, idx < document.layers.count else { continue }
            if let visibility, visibility.hiddenLayerIds.contains(idx) { continue }
            let full = document.layers[idx].name.lowercased()
            // Accept an exact match, or an xref-qualified suffix ("xref|layer").
            let bare = full.split(separator: "|").last.map(String.init) ?? full
            guard full == wanted || bare == wanted else { continue }
            for run in g.strokes.runs {
                let start = Int(run.start), count = Int(run.count)
                guard count >= 2, start >= 0, start + count <= g.strokes.points.count else { continue }
                let pts = Array(g.strokes.points[start..<(start + count)])
                for (p, q) in zip(pts, pts.dropFirst()) {
                    let s = Segment(a: p, b: q)
                    if s.length > minSegmentLength { out.append(s) }
                }
                if run.closed, let f = pts.first, let l = pts.last {
                    let s = Segment(a: l, b: f)
                    if s.length > minSegmentLength { out.append(s) }
                }
            }
        }
        return out
    }

    /// Layer names that look like aisle layers, for when the user hasn't named
    /// one explicitly — lets a tool say "did you mean AISLE?" instead of
    /// silently returning an empty network. Excludes obvious non-centerline
    /// companions (stop bars, crosswalks, hatch patterns, text) that would
    /// pollute the graph with geometry nobody travels along.
    ///
    /// `visibility`, when supplied, excludes currently hidden/frozen layers —
    /// see `segments(onLayerNamed:...)`'s doc comment for why: a suggestion
    /// should never point the user at a layer they've deliberately hidden.
    static func candidateAisleLayers(document: DXFDocument, visibility: VisibilityState? = nil) -> [String] {
        let exclude = ["stop", "crosswalk", "cross walk", "hatch", "patt", "text", "anno", "sign"]
        var seen = Set<String>()
        var out: [String] = []
        for layer in document.layers {
            if let visibility, visibility.hiddenLayerIds.contains(layer.id) { continue }
            let lower = layer.name.lowercased()
            guard lower.contains("aisl") else { continue }
            guard !exclude.contains(where: { lower.contains($0) }) else { continue }
            if seen.insert(layer.name).inserted { out.append(layer.name) }
        }
        return out
    }

    // MARK: - Corridor detection (boundary pairs -> derived centerlines + widths)
    //
    // A real aisle layer is NOT a clean centerline graph. Measured on the
    // reference layout's `AISLE` layer: of 829 segments, 427 are long enough to
    // pair up, and 294 parallel overlapping pairs sit 6.7'-33.2' apart. That
    // is because the layer carries BOTH aisle centerlines AND the boundary
    // edge lines that draw each aisle's two sides.
    //
    // Feeding boundary lines straight into the routing graph is wrong twice
    // over: routes would follow an aisle EDGE instead of its middle, and each
    // corridor would contribute two redundant parallel paths. So boundary
    // pairs are detected geometrically, collapsed into a single DERIVED
    // centerline midway between them, and tagged with the perpendicular
    // separation as that aisle's measured width.
    //
    // This also cross-validates against the drawing's own text annotations:
    // measured pair separations peak at 13 ft (104 of 294) with a 13.7 ft
    // median, while the written labels peak at 13'-4" (47 of ~90). Two
    // independent sources agreeing is what makes automatic width measurement
    // trustworthy here.

    /// An aisle corridor: a travel centerline plus how wide the aisle is.
    struct Corridor: Equatable {
        var centerline: Segment
        /// Perpendicular aisle width in drawing units, when known.
        var width: Double?
        /// How `width` was established — surfaced to the user so an inferred
        /// value is never mistaken for a measured one.
        enum WidthSource: String, Codable {
            /// Measured between a detected pair of boundary lines.
            case measuredFromBoundaries
            /// Read from a nearby `13'-4" AISLE`-style annotation.
            case textAnnotation
            /// Neither available — caller supplied/assumed a value.
            case assumed
            case unknown
        }
        var widthSource: WidthSource = .unknown
    }

    /// Widths outside this range are rejected as implausible for an aisle.
    /// The reference drawing's own labels top out at 21'-7" and the user's
    /// stated range is 13'-23', so pairs beyond ~24 ft are far more likely to
    /// be coincidental parallelism between two unrelated aisles than a real
    /// corridor — accepting them would shade over non-aisle floor space.
    /// Expressed in drawing units (inches for these plant layouts).
    static let minPlausibleWidth: Double = 4 * 12      // 4 ft
    static let maxPlausibleWidth: Double = 24 * 12     // 24 ft

    /// Only segments at least this long are considered as corridor sides —
    /// short stubs pair up spuriously with almost anything nearby.
    static let minCorridorSideLength: Double = 200

    /// Maximum angular deviation for two segments to count as parallel.
    static let parallelToleranceDegrees: Double = 3

    private static func angleMod180(_ s: Segment) -> Double {
        var a = atan2(Double(s.b.y - s.a.y), Double(s.b.x - s.a.x))
        if a < 0 { a += .pi }
        if a >= .pi { a -= .pi }
        return a
    }

    /// Perpendicular distance from `p` to the infinite line through `s`.
    private static func perpendicularDistance(_ p: CGPoint, toLineThrough s: Segment) -> Double? {
        let dx = Double(s.b.x - s.a.x), dy = Double(s.b.y - s.a.y)
        let len = (dx * dx + dy * dy).squareRoot()
        guard len > 1e-9 else { return nil }
        return abs((Double(p.x - s.a.x) * dy - Double(p.y - s.a.y) * dx)) / len
    }

    /// True when `t` projects onto a meaningful stretch of `s` — prevents two
    /// parallel segments that merely pass near each other end-to-end from
    /// being mistaken for the two sides of one corridor.
    private static func projectionsOverlap(_ s: Segment, _ t: Segment) -> Bool {
        let dx = Double(s.b.x - s.a.x), dy = Double(s.b.y - s.a.y)
        let len = (dx * dx + dy * dy).squareRoot()
        guard len > 1e-9 else { return false }
        let ux = dx / len, uy = dy / len
        let t0 = Double(t.a.x - s.a.x) * ux + Double(t.a.y - s.a.y) * uy
        let t1 = Double(t.b.x - s.a.x) * ux + Double(t.b.y - s.a.y) * uy
        return max(t0, t1) > 0.15 * len && min(t0, t1) < 0.85 * len
    }

    /// Splits `segments` into corridors derived from boundary pairs plus the
    /// leftover unpaired segments (treated as bare centerlines of unknown
    /// width). Each side is consumed by at most one corridor — the closest
    /// plausible partner wins — so a boundary shared between two aisles
    /// doesn't produce overlapping corridors.
    static func detectCorridors(from segments: [Segment]) -> (corridors: [Corridor], unpaired: [Segment]) {
        let candidateIndices = segments.indices.filter { segments[$0].length >= minCorridorSideLength }
        var partnered = Set<Int>()
        var corridors: [Corridor] = []

        // Evaluate every plausible pairing, then greedily take the tightest
        // ones first so each side binds to its true opposite rather than to
        // whichever happened to be visited first.
        var candidates: [(distance: Double, i: Int, j: Int)] = []
        for (offset, i) in candidateIndices.enumerated() {
            for j in candidateIndices[(offset + 1)...] {
                let s = segments[i], t = segments[j]
                var delta = abs(angleMod180(s) - angleMod180(t))
                delta = min(delta, .pi - delta)
                guard delta <= parallelToleranceDegrees * .pi / 180 else { continue }
                guard projectionsOverlap(s, t) else { continue }
                guard let d1 = perpendicularDistance(t.a, toLineThrough: s),
                      let d2 = perpendicularDistance(t.b, toLineThrough: s) else { continue }
                // Both ends must sit the same distance away, else these are
                // converging lines rather than a constant-width corridor.
                guard abs(d1 - d2) <= 6 else { continue }
                let d = (d1 + d2) / 2
                guard d >= minPlausibleWidth, d <= maxPlausibleWidth else { continue }
                candidates.append((d, i, j))
            }
        }
        for c in candidates.sorted(by: { $0.distance < $1.distance }) {
            guard !partnered.contains(c.i), !partnered.contains(c.j) else { continue }
            partnered.insert(c.i); partnered.insert(c.j)
            guard let mid = midline(segments[c.i], segments[c.j]) else { continue }
            corridors.append(Corridor(centerline: mid, width: c.distance,
                                      widthSource: .measuredFromBoundaries))
        }
        let unpaired = segments.indices.filter { !partnered.contains($0) }.map { segments[$0] }
        return (corridors, unpaired)
    }

    /// Centerline midway between two parallel boundary segments. Built over
    /// the stretch where they actually overlap, and oriented along `s`, so the
    /// derived centerline spans the real corridor rather than either side's
    /// full extent.
    private static func midline(_ s: Segment, _ t: Segment) -> Segment? {
        let dx = Double(s.b.x - s.a.x), dy = Double(s.b.y - s.a.y)
        let len = (dx * dx + dy * dy).squareRoot()
        guard len > 1e-9 else { return nil }
        let ux = dx / len, uy = dy / len
        func proj(_ p: CGPoint) -> Double {
            Double(p.x - s.a.x) * ux + Double(p.y - s.a.y) * uy
        }
        let lo = max(0, min(proj(t.a), proj(t.b)))
        let hi = min(len, max(proj(t.a), proj(t.b)))
        guard hi - lo > minSegmentLength else { return nil }
        func pointOnS(_ d: Double) -> CGPoint {
            CGPoint(x: s.a.x + CGFloat(ux * d), y: s.a.y + CGFloat(uy * d))
        }
        // Offset halfway toward t, perpendicular to s, on t's side.
        let nx = -uy, ny = ux
        let signedOffset = Double(t.a.x - s.a.x) * nx + Double(t.a.y - s.a.y) * ny
        let half = signedOffset / 2
        let a = pointOnS(lo), b = pointOnS(hi)
        return Segment(a: CGPoint(x: a.x + CGFloat(nx * half), y: a.y + CGFloat(ny * half)),
                       b: CGPoint(x: b.x + CGFloat(nx * half), y: b.y + CGFloat(ny * half)))
    }

    // MARK: - Width annotations (`13'-4" AISLE`)

    /// A width read from the drawing's own text, with where it sits so it can
    /// be matched to the nearest corridor.
    struct WidthAnnotation: Equatable {
        var position: CGPoint
        /// Parsed width in drawing units (inches).
        var width: Double
        /// Raw source text, retained for reporting/traceability.
        var text: String
        /// The drawing sometimes states direction alongside width (measured:
        /// `10'-0" AISLE - ONE WAY`). Captured and reported now so it's ready
        /// for future directional routing; routing itself remains
        /// bidirectional per this feature's product decision.
        var isOneWay: Bool
    }

    /// Parses a feet-inches aisle annotation. Accepts the forms actually
    /// present in production files — `13'-4" AISLE`, `14'-0" AISLE`,
    /// `9'-0" - MAINTENANCE AISLE`, `17'-4" AISLE\PMANUAL FORK AREA` — and
    /// rejects non-width text on the same layers (`DOCK`, `TRASH ROOM`,
    /// `CANOPY`, `XXX`). Returns inches.
    static func parseWidthAnnotation(_ raw: String) -> (width: Double, isOneWay: Bool)? {
        let upper = raw.uppercased()
        // Must actually describe an aisle/opening/access, so a dock label
        // that happens to contain a dimension isn't read as an aisle width.
        let describesAisle = upper.contains("AISLE") || upper.contains("OPENING")
            || upper.contains("ACCESS")
        guard describesAisle else { return nil }

        // FEET ' - INCHES ", with the inches part optional.
        guard let feetRange = upper.range(of: #"(\d+)\s*'"#, options: .regularExpression) else { return nil }
        let feetDigits = upper[feetRange].filter(\.isNumber)
        guard let feet = Double(feetDigits) else { return nil }
        var inches = 0.0
        // Look for the inch component only AFTER the feet mark, so a trailing
        // qualifier's digits can't be misread as inches.
        let afterFeet = upper[feetRange.upperBound...]
        if let inchRange = afterFeet.range(of: #"^\s*-?\s*(\d+)\s*""#, options: .regularExpression) {
            let digits = afterFeet[inchRange].filter(\.isNumber)
            inches = Double(digits) ?? 0
        }
        let total = feet * 12 + inches
        guard total >= minPlausibleWidth, total <= maxPlausibleWidth else { return nil }
        return (total, upper.contains("ONE WAY") || upper.contains("ONE-WAY"))
    }

    /// Collects every parseable width annotation on `layerName` from the live
    /// render model's text items.
    static func widthAnnotations(onLayerNamed layerName: String, document: DXFDocument,
                                 space: SpaceID, visibility: VisibilityState? = nil) -> [WidthAnnotation] {
        let groups = space == .paper ? document.paperGroups : document.modelGroups
        let wanted = layerName.lowercased()
        var out: [WidthAnnotation] = []
        for g in groups {
            let idx = Int(g.layerId)
            guard idx >= 0, idx < document.layers.count else { continue }
            if let visibility, visibility.hiddenLayerIds.contains(idx) { continue }
            let full = document.layers[idx].name.lowercased()
            let bare = full.split(separator: "|").last.map(String.init) ?? full
            guard full == wanted || bare == wanted else { continue }
            for t in g.texts {
                guard let parsed = parseWidthAnnotation(t.text) else { continue }
                out.append(WidthAnnotation(position: t.position, width: parsed.width,
                                           text: t.text, isOneWay: parsed.isOneWay))
            }
        }
        return out
    }

    /// Fills in each corridor's width from the nearest annotation, for
    /// corridors whose width wasn't already measured from boundary pairs.
    /// The drawing writes the width INSIDE the aisle it describes, so nearest-
    /// label assignment is the correct association; `maxDistance` prevents a
    /// far-off label from being applied to an unrelated aisle.
    static func applyWidthAnnotations(_ annotations: [WidthAnnotation],
                                      to corridors: [Corridor],
                                      maxDistance: Double) -> [Corridor] {
        guard !annotations.isEmpty else { return corridors }
        return corridors.map { corridor in
            guard corridor.width == nil else { return corridor }
            var best: (distance: Double, annotation: WidthAnnotation)?
            for a in annotations {
                let hit = closestPoint(a.position, on: corridor.centerline)
                if best == nil || hit.distance < best!.distance { best = (hit.distance, a) }
            }
            guard let b = best, b.distance <= maxDistance else { return corridor }
            var updated = corridor
            updated.width = b.annotation.width
            updated.widthSource = .textAnnotation
            return updated
        }
    }

    // MARK: - Ribbon generation (shading the aisle network)
    //
    // Aisle centerlines are ZERO-WIDTH: there is no interior to hatch, which
    // is why the existing `ShadeLayer` feature (which needs closed shapes)
    // cannot shade an aisle network. Each centerline is therefore buffered
    // outward by half its width into a closed rectangle ("ribbon"), and the
    // ribbons together cover where the aisles physically are.
    //
    // Ribbons deliberately OVERLAP at junctions rather than being booleaned
    // into one merged outline (no polygon-union primitive exists in this
    // codebase). That is visually correct only if transparency is applied at
    // the LAYER level rather than per shape — with per-shape alpha, dozens of
    // overlaps compound into opaque dark blotches at every intersection.
    // Hence the caller places all ribbons on one dedicated layer and sets
    // that layer's transparency.

    /// A closed quadrilateral covering one aisle segment's footprint.
    struct Ribbon: Equatable {
        /// Corner points in order, forming a closed shape.
        var points: [CGPoint]
        var width: Double
        var widthSource: Corridor.WidthSource
    }

    /// Buffers `corridor` into a closed rectangle. `fallbackWidth` is used
    /// when the corridor has no measured or annotated width; the resulting
    /// ribbon reports `.assumed` so the caller can tell the user exactly which
    /// aisles were guessed.
    static func ribbon(for corridor: Corridor, fallbackWidth: Double) -> Ribbon? {
        let s = corridor.centerline
        let dx = Double(s.b.x - s.a.x), dy = Double(s.b.y - s.a.y)
        let len = (dx * dx + dy * dy).squareRoot()
        guard len > minSegmentLength else { return nil }
        let width = corridor.width ?? fallbackWidth
        guard width > 0 else { return nil }
        let half = width / 2
        let nx = -dy / len * half, ny = dx / len * half
        let pts = [
            CGPoint(x: s.a.x + CGFloat(nx), y: s.a.y + CGFloat(ny)),
            CGPoint(x: s.b.x + CGFloat(nx), y: s.b.y + CGFloat(ny)),
            CGPoint(x: s.b.x - CGFloat(nx), y: s.b.y - CGFloat(ny)),
            CGPoint(x: s.a.x - CGFloat(nx), y: s.a.y - CGFloat(ny)),
        ]
        return Ribbon(points: pts, width: width,
                      widthSource: corridor.width == nil ? .assumed : corridor.widthSource)
    }

    /// Builds ribbons for every corridor, skipping degenerate ones.
    static func ribbons(for corridors: [Corridor], fallbackWidth: Double) -> [Ribbon] {
        corridors.compactMap { ribbon(for: $0, fallbackWidth: fallbackWidth) }
    }

    // MARK: - Junction rounding (closes the corner gap where ribbons meet)
    //
    // Each `Ribbon` above is a rectangle cut off PERPENDICULAR to its own
    // centerline at both ends. When two aisles meet at anything other than a
    // straight-through crossing (the common case: an L-turn, or a T/X
    // junction), neither rectangle covers the OUTER (convex) corner of the
    // turn — a real gap in the shading exactly at the corner, reported by a
    // user seeing "an L shape ... a gap of space in the outer-most corner."
    //
    // This is the identical problem stroke rendering solves with a "join"
    // style at path vertices (miter/round/bevel). A `.round` join is defined
    // as a circular arc of the stroke's own half-width centered on the
    // vertex — which is exactly what closes this gap, and unlike a miter
    // join it degrades gracefully at very sharp/very wide-angle turns rather
    // than producing an unbounded spike. Implemented here as one filled
    // CIRCLE per junction node (radius = half the width of whichever meeting
    // corridor is widest, so a junction between differently-sized aisles is
    // still fully covered) rather than an actual boolean union with the
    // ribbons — see this file's own header comment on ribbons already
    // relying on overlap + layer-level transparency instead of a real
    // polygon-union primitive (which doesn't exist in this codebase); a
    // junction disk is just one more overlapping shape in that same scheme,
    // not a structural change to it.
    //
    // Only emitted at junctions with 2+ MEETING corridors and where every
    // meeting corridor actually turns (isn't perfectly straight-through) —
    // a plain interior point of one single straight aisle has no gap to
    // close and would just add a redundant circle.

    /// One junction: a graph node where 2+ corridor centerlines meet, plus
    /// the width to use for its rounding disk.
    struct Junction: Equatable {
        var point: CGPoint
        /// Half of this equals the disk's radius — the widest of every
        /// corridor meeting here, so the disk fully covers each one's ribbon.
        var width: Double
        /// How many distinct corridor centerlines meet at this point —
        /// surfaced mainly for diagnostics/tests (2 = a bend/T-branch-arm,
        /// 3+ = a genuine T/X junction).
        var degree: Int
    }

    /// Finds every point where 2+ of `corridors`' centerlines meet (share an
    /// endpoint, within `nodeQuantum`), returning one `Junction` per such
    /// point sized to the widest meeting corridor. Corridors are used here
    /// (not raw segments) specifically because a `Corridor.width` is the
    /// real, already-resolved aisle width (measured/annotated/assumed) a
    /// ribbon was actually buffered by — junctions must match that exactly,
    /// or the disk would leave a sliver gap or bulge past the ribbon it's
    /// meant to seamlessly join.
    static func junctions(for corridors: [Corridor], fallbackWidth: Double) -> [Junction] {
        var widthsAtNode: [NodeKey: Double] = [:]
        var pointAtNode: [NodeKey: CGPoint] = [:]
        var countAtNode: [NodeKey: Int] = [:]

        for c in corridors {
            let width = c.width ?? fallbackWidth
            guard width > 0 else { continue }
            for p in [c.centerline.a, c.centerline.b] {
                let k = nodeKey(p)
                pointAtNode[k] = p
                countAtNode[k, default: 0] += 1
                widthsAtNode[k] = max(widthsAtNode[k] ?? 0, width)
            }
        }
        return countAtNode.compactMap { key, count in
            guard count >= 2, let p = pointAtNode[key], let w = widthsAtNode[key] else { return nil }
            return Junction(point: p, width: w, degree: count)
        }
    }

    /// A filled circle at one junction, sized to fully cover the widest
    /// meeting ribbon.
    struct JunctionDisk: Equatable {
        var center: CGPoint
        var radius: Double
    }

    /// Builds the rounding disk for each junction. `segments` — matching
    /// `CGRenderCore`'s own circle tessellation convention (a fixed-segment
    /// polygon approximation, since `HatchPayload`'s solid-fill loops are
    /// plain point lists, not true arcs) — defaults to a value visually
    /// indistinguishable from a true circle at any aisle's real-world scale
    /// while keeping the resulting entity count small across a network with
    /// many junctions.
    static func junctionDisks(for junctions: [Junction], segments: Int = 24) -> [JunctionDisk] {
        junctions.map { JunctionDisk(center: $0.point, radius: $0.width / 2) }
    }

    /// Tessellates a `JunctionDisk` into a closed point loop, ready for the
    /// same solid-fill HATCH construction `Ribbon`s already use — kept
    /// separate from `JunctionDisk` itself (a plain center+radius) so callers
    /// that only need the disk's geometric extent (e.g. a future true-union
    /// implementation) aren't forced to pay for tessellation they don't need.
    static func polygon(for disk: JunctionDisk, segments: Int = 24) -> [CGPoint] {
        guard disk.radius > 0, segments >= 3 else { return [] }
        return (0..<segments).map { i in
            let angle = 2 * Double.pi * Double(i) / Double(segments)
            return CGPoint(x: disk.center.x + CGFloat(disk.radius * cos(angle)),
                           y: disk.center.y + CGFloat(disk.radius * sin(angle)))
        }
    }

    // MARK: - Endpoint helpers

    /// Centroid of a group of points — how a DOCK GROUP is reduced to a
    /// single routing origin (this feature's product decision: "mid-point
    /// amongst a group of docks"). The caller then snaps it to the network,
    /// so a centroid landing inside a building is still routed from its
    /// nearest real aisle access point.
    static func centroid(of points: [CGPoint]) -> CGPoint? {
        guard !points.isEmpty else { return nil }
        let sx = points.reduce(0.0) { $0 + $1.x }
        let sy = points.reduce(0.0) { $0 + $1.y }
        return CGPoint(x: sx / Double(points.count), y: sy / Double(points.count))
    }
}
