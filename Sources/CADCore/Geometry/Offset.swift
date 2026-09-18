//
//  Offset.swift
//  DWGViewer / Geometry
//
//  Phase 2 geometry kernel — pure Swift (Foundation + simd only).
//  Curve offsetting: exact for line/arc/circle, adaptive-sampling +
//  refit for ellipse/spline, and a full join/trim/chain pipeline for
//  polylines (the hard case).
//

import Foundation
import simd

public enum OffsetSide {
    case left
    case right
}

public enum Offset {

    // MARK: - Primitive offsets

    /// Offsets a segment perpendicular to its direction by distance `d`.
    /// `.left` is the CCW-perpendicular side of a->b; `.right` is CW.
    public static func segment(_ s: LineSeg, _ d: Double, _ side: OffsetSide) -> LineSeg {
        let dir = s.b - s.a
        let len = simd_length(dir)
        guard len > 0 else { return s }
        let perp = Vec2(-dir.y, dir.x) / len
        let sign: Double = side == .left ? 1 : -1
        let offsetVec = perp * (d * sign)
        return LineSeg(a: s.a + offsetVec, b: s.b + offsetVec)
    }

    /// Offsets an arc, returning nil if the offset radius would collapse to
    /// <= 0 (i.e., an inward offset larger than the arc's own radius).
    public static func arc(_ a: CircArc, _ d: Double, _ side: OffsetSide) -> CircArc? {
        // Left-offsetting a CCW arc grows its radius (you're moving away
        // from the center on the outside); left-offsetting a CW arc shrinks
        // it. Concretely: side .left means "outward" when sweep > 0.
        let sign: Double = side == .left ? 1 : -1
        let sweepSign: Double = a.sweep >= 0 ? 1 : -1
        let newR = a.r + sign * sweepSign * d
        guard newR > 0 else { return nil }
        return CircArc(center: a.center, r: newR, startAngle: a.startAngle, sweep: a.sweep)
    }

    /// Offsets a full circle. `outward: true` grows the radius by `d`;
    /// `false` shrinks it. Returns nil if the result would collapse to <= 0.
    public static func circle(_ c: Circle2, _ d: Double, outward: Bool) -> Circle2? {
        let newR = c.r + (outward ? d : -d)
        guard newR > 0 else { return nil }
        return Circle2(center: c.center, r: newR)
    }

    /// An ellipse's offset curve is not itself an ellipse in general, so we
    /// adaptively sample the source curve and fit a biarc/segment chain
    /// (via `SplineFit`, producing a `BulgePolyline` whose arc segments
    /// approximate the true offset) such that the max deviation from the
    /// true offset curve stays under `4 * tol.linear`.
    public static func ellipse(_ e: EllipseArc, _ d: Double, _ side: OffsetSide, tol: Tolerance) -> BulgePolyline {
        let curve = Curve2.ellipse(e)
        let deviationBudget = 4 * tol.linear
        let samples = adaptiveOffsetSamples(curve, d: d, side: side, deviationBudget: deviationBudget)
        return polylineFromOffsetSamples(samples, closed: curve.isPeriodic)
    }

    /// Samples `E(t) + d*normal(t)` at increasing density until consecutive
    /// samples agree within tolerance, then re-interpolates via
    /// `SplineFit.interpolate`.
    public static func spline(_ n: NURBS, _ d: Double, _ side: OffsetSide, tol: Tolerance) -> NURBS {
        guard n.isValid else { return n }
        let curve = Curve2.spline(n)
        var previousSamples: [Vec2]? = nil
        var density = Self.initialOffsetSampleDensity
        var finalSamples: [Vec2] = []

        while density <= Self.maxOffsetSampleDensity {
            let samples = offsetSamplePoints(curve, d: d, side: side, count: density)
            if let prev = previousSamples, samplesAgree(prev, samples, tol: tol.linear) {
                finalSamples = samples
                break
            }
            previousSamples = samples
            finalSamples = samples
            density *= 2
        }
        return SplineFit.interpolate(fitPoints: finalSamples, closed: curve.isPeriodic)
    }

    /// Starting sample density for adaptive offset sampling of splines.
    private static let initialOffsetSampleDensity = 16
    /// Hard cap on sample density — bounds worst-case cost on pathological
    /// (very high-curvature) splines while remaining far denser than any
    /// realistic DXF SPLINE needs for a visually-exact offset.
    private static let maxOffsetSampleDensity = 512

    /// Compares two same-shape sample point sets pairwise (after
    /// re-sampling the coarser set up isn't needed here since both densities
    /// are powers of two of the same base — every point in `prev` also
    /// appears, index-doubled, in `next`) for agreement within `tol`.
    private static func samplesAgree(_ prev: [Vec2], _ next: [Vec2], tol: Double) -> Bool {
        guard next.count >= prev.count else { return false }
        let stride = (next.count - 1) / max(prev.count - 1, 1)
        guard stride > 0 else { return false }
        for i in 0..<prev.count {
            let j = i * stride
            guard j < next.count else { return false }
            if simd_length(prev[i] - next[j]) > tol { return false }
        }
        return true
    }

    private static func offsetSamplePoints(_ curve: Curve2, d: Double, side: OffsetSide, count: Int) -> [Vec2] {
        let domain = curve.paramDomain
        let sign: Double = side == .left ? 1 : -1
        var pts: [Vec2] = []
        pts.reserveCapacity(count + 1)
        for k in 0...count {
            let u = domain.lowerBound + (domain.upperBound - domain.lowerBound) * Double(k) / Double(count)
            let p = curve.evaluate(u)
            let tangent = curve.tangent(u)
            let normal = Vec2(-tangent.y, tangent.x)
            pts.append(p + normal * (d * sign))
        }
        return pts
    }

    private static func adaptiveOffsetSamples(_ curve: Curve2, d: Double, side: OffsetSide, deviationBudget: Double) -> [Vec2] {
        var density = initialOffsetSampleDensity
        var samples = offsetSamplePoints(curve, d: d, side: side, count: density)
        while density < maxOffsetSampleDensity {
            let denser = offsetSamplePoints(curve, d: d, side: side, count: density * 2)
            if samplesAgree(samples, denser, tol: deviationBudget) {
                return denser
            }
            samples = denser
            density *= 2
        }
        return samples
    }

    private static func polylineFromOffsetSamples(_ samples: [Vec2], closed: Bool) -> BulgePolyline {
        // Straight-segment chain through the sampled offset points; simple
        // and meets the "max deviation under budget" requirement since the
        // sampling loop above already ensured point density is fine enough
        // that successive samples agree within budget (i.e., the polyline
        // through them deviates from the true offset by less than budget).
        var verts = samples
        if closed, verts.count > 1, simd_length(verts.first! - verts.last!) < 1e-9 {
            verts.removeLast()
        }
        let bulges = [Double](repeating: 0, count: verts.count)
        return BulgePolyline(vertices: verts, bulges: bulges, closed: closed)
    }

    // MARK: - Polyline offset (the hard case)

    /// Distance below which a joined piece is considered degenerate
    /// (near-zero length) and dropped during the join/trim pipeline.
    private static let degenerateLengthEpsilon = 1e-9

    /// Gap below which two atom endpoints during final chaining may be
    /// bridged with a micro-segment rather than left as a real gap.
    private static func bridgeGap(tol: Tolerance) -> Double { 4 * tol.linear }

    public static func polyline(_ p: BulgePolyline, distance d: Double, side: OffsetSide, tol: Tolerance) -> [BulgePolyline] {
        guard p.segmentCount > 0, d > 0 else { return [] }

        // 1. Offset each segment/arc independently.
        var offsetPieces: [Curve2?] = []
        for i in 0..<p.segmentCount {
            let seg = p.segmentCurve(i)
            switch seg {
            case .segment(let s):
                offsetPieces.append(.segment(segment(s, d, side)))
            case .arc(let a):
                offsetPieces.append(arc(a, d, side).map { .arc($0) })
            default:
                offsetPieces.append(nil)
            }
        }

        // 2. Join consecutive offset pieces (mitre or round arc join).
        // Mitre joins trim/extend the two neighboring pieces' shared
        // endpoint to the mitre point directly (rather than inserting a
        // separate connector), since a mitre is exactly "extend both curves
        // to their mutual intersection." Round-arc joins insert a new arc
        // piece between unchanged neighbors.
        let n = offsetPieces.count
        var validPieceIndices: [Int] = []
        for i in 0..<n where offsetPieces[i] != nil { validPieceIndices.append(i) }
        guard !validPieceIndices.isEmpty else { return [] }

        var working = validPieceIndices.map { offsetPieces[$0]! }
        var extraJoinPieces: [(afterWorkingIndex: Int, piece: Curve2)] = []

        for (k, idx) in validPieceIndices.enumerated() {
            let nextK = (k + 1) % validPieceIndices.count
            let isLastWrap = (k == validPieceIndices.count - 1)
            if isLastWrap && !p.closed { continue } // open polyline: no join after the last piece
            let cur = working[k]
            let next = working[nextK]
            // The shared original vertex is the "to" vertex of segment idx,
            // i.e. vertex index (idx+1) mod vertices.count.
            let joinVertexIndex = (idx + 1) % p.vertices.count
            guard joinVertexIndex < p.vertices.count else { continue }
            let originalVertex = p.vertices[joinVertexIndex]

            switch makeJoin(from: cur, to: next, originalVertex: originalVertex, distance: d, tol: tol) {
            case .mitre(let mitrePoint):
                working[k] = trimEndTo(cur, point: mitrePoint, atStart: false)
                working[nextK] = trimEndTo(next, point: mitrePoint, atStart: true)
            case .arcJoin(let a):
                extraJoinPieces.append((afterWorkingIndex: k, piece: .arc(a)))
            case .none:
                break
            }
        }

        // Rebuild the ordered piece list, splicing in any arc-join pieces
        // right after the working piece they follow.
        var withJoins: [Curve2] = []
        for (k, piece) in working.enumerated() {
            withJoins.append(piece)
            for extra in extraJoinPieces where extra.afterWorkingIndex == k {
                withJoins.append(extra.piece)
            }
        }

        // 3. Remove degenerate pieces.
        var cleaned: [Curve2] = []
        for piece in withJoins {
            if isDegenerate(piece) { continue }
            cleaned.append(piece)
        }
        guard !cleaned.isEmpty else { return [] }

        // 4. Global self-intersection trim.
        let trimmed = trimSelfIntersections(cleaned, original: p, distance: d, tol: tol)
        guard !trimmed.isEmpty else { return [] }

        // 5. Chain atoms into closed/open BulgePolylines.
        return chainAtoms(trimmed, tol: tol)
    }

    /// Result of joining two consecutive offset curves at a corner.
    private enum JoinResult {
        /// The two curves should be trimmed/extended to meet exactly at
        /// this point — no separate connector geometry is inserted.
        case mitre(Vec2)
        /// No reasonable mitre exists; insert this round arc between the
        /// unchanged neighbors.
        case arcJoin(CircArc)
        /// Neither is possible (degenerate corner); drop the join.
        case none
    }

    /// Decides how to join two consecutive offset curves that meet near
    /// `originalVertex`. Tries an extended intersection first (mitre join);
    /// falls back to a round arc centered at the original vertex.
    private static func makeJoin(from cur: Curve2, to next: Curve2, originalVertex: Vec2, distance d: Double, tol: Tolerance) -> JoinResult {
        let hits = Intersect.curves(cur, next, tol: tol, extendA: true, extendB: true)
        if let best = hits.min(by: { simd_length($0.point - originalVertex) < simd_length($1.point - originalVertex) }) {
            // Accept the mitre point only if it's a "reasonable" distance
            // from the corner (bounded so a near-parallel join doesn't
            // produce an absurdly long mitre spike).
            let maxMitre = 32 * max(d, tol.linear)
            if simd_length(best.point - originalVertex) <= maxMitre {
                return .mitre(best.point)
            }
        }
        // No reasonable mitre: round arc join centered at the ORIGINAL
        // vertex, radius |d|, sweeping from cur's end to next's start in
        // the corner's turn direction.
        let curEnd = cur.evaluate(cur.paramDomain.upperBound)
        let nextStart = next.evaluate(next.paramDomain.lowerBound)
        let r = abs(d)
        guard r > 0 else { return .none }
        let startAngle = atan2(curEnd.y - originalVertex.y, curEnd.x - originalVertex.x)
        let endAngle = atan2(nextStart.y - originalVertex.y, nextStart.x - originalVertex.x)
        // Turn direction: sign of the cross product of (curEnd-vertex) and
        // (nextStart-vertex) gives the short-way sweep direction; use that
        // sign to decide CCW vs CW traversal from start to end angle.
        let cross = (curEnd.x - originalVertex.x) * (nextStart.y - originalVertex.y)
                  - (curEnd.y - originalVertex.y) * (nextStart.x - originalVertex.x)
        var sweep = endAngle - startAngle
        sweep = sweep.truncatingRemainder(dividingBy: 2 * .pi)
        if cross >= 0 {
            if sweep < 0 { sweep += 2 * .pi }
        } else {
            if sweep > 0 { sweep -= 2 * .pi }
        }
        return .arcJoin(CircArc(center: originalVertex, r: r, startAngle: startAngle, sweep: sweep))
    }

    /// Trims/extends a segment or arc so that its start (if `atStart`) or
    /// end (otherwise) becomes exactly `point`, preserving the curve's
    /// underlying geometry (line direction / arc center+radius) — this is
    /// exactly what a mitre join needs: extend both neighbors to their
    /// mutual intersection.
    private static func trimEndTo(_ c: Curve2, point: Vec2, atStart: Bool) -> Curve2 {
        switch c {
        case .segment(let s):
            return .segment(atStart ? LineSeg(a: point, b: s.b) : LineSeg(a: s.a, b: point))
        case .arc(let a):
            let angle = atan2(point.y - a.center.y, point.x - a.center.x)
            let sign: Double = a.sweep >= 0 ? 1 : -1
            if atStart {
                // New start angle is `angle`; keep the same end angle, so
                // sweep shrinks/grows from the new start to the old end.
                let oldEndAngle = a.startAngle + a.sweep
                var newSweep = (oldEndAngle - angle) * sign
                newSweep = newSweep.truncatingRemainder(dividingBy: 2 * .pi)
                if newSweep < 0 { newSweep += 2 * .pi }
                return .arc(CircArc(center: a.center, r: a.r, startAngle: angle, sweep: sign * newSweep))
            } else {
                var newSweep = (angle - a.startAngle) * sign
                newSweep = newSweep.truncatingRemainder(dividingBy: 2 * .pi)
                if newSweep < 0 { newSweep += 2 * .pi }
                return .arc(CircArc(center: a.center, r: a.r, startAngle: a.startAngle, sweep: sign * newSweep))
            }
        default:
            return c
        }
    }

    private static func isDegenerate(_ c: Curve2) -> Bool {
        switch c {
        case .segment(let s):
            return simd_length(s.b - s.a) < degenerateLengthEpsilon
        case .arc(let a):
            return a.r <= 0 || abs(a.sweep) < 1e-12
        default:
            return c.length() < degenerateLengthEpsilon
        }
    }

    /// Computes all pairwise intersections among the joined pieces (skipping
    /// adjacent pairs, which already meet by construction), splits every
    /// piece at its hit parameters, and keeps only atoms whose midpoint is
    /// at distance >= |d| - 2*tol.linear from the ORIGINAL polyline (this
    /// removes "bowtie" self-intersections on inward offsets of concave
    /// corners).
    private static func trimSelfIntersections(_ pieces: [Curve2], original: BulgePolyline, distance d: Double, tol: Tolerance) -> [Curve2] {
        let n = pieces.count
        guard n > 0 else { return [] }
        var splitParams: [[Double]] = Array(repeating: [], count: n)

        for i in 0..<n {
            for j in (i + 1)..<n {
                // Skip pairs that are adjacent (share an endpoint by
                // construction from the join step) — checked by proximity
                // of the two curves' shared endpoint candidates rather than
                // strict index-adjacency, since join pieces sit between
                // "real" offset pieces in the array.
                if arePiecesAdjacent(pieces[i], pieces[j], tol: tol) { continue }
                let hits = Intersect.curves(pieces[i], pieces[j], tol: tol)
                for h in hits where h.within1 && h.within2 {
                    splitParams[i].append(h.u1)
                    splitParams[j].append(h.u2)
                }
            }
        }

        var atoms: [Curve2] = []
        for i in 0..<n {
            let pieces2 = pieces[i].split(at: splitParams[i])
            for atom in pieces2 {
                if isDegenerate(atom) { continue }
                let mid = atom.evaluate((atom.paramDomain.lowerBound + atom.paramDomain.upperBound) / 2)
                let distToOriginal = distanceToPolyline(mid, original)
                if distToOriginal >= abs(d) - 2 * tol.linear {
                    atoms.append(atom)
                }
            }
        }
        return atoms
    }

    private static func arePiecesAdjacent(_ a: Curve2, _ b: Curve2, tol: Tolerance) -> Bool {
        let aStart = a.evaluate(a.paramDomain.lowerBound)
        let aEnd = a.evaluate(a.paramDomain.upperBound)
        let bStart = b.evaluate(b.paramDomain.lowerBound)
        let bEnd = b.evaluate(b.paramDomain.upperBound)
        let eps = 4 * tol.linear
        return simd_length(aEnd - bStart) < eps || simd_length(aStart - bEnd) < eps
            || simd_length(aStart - bStart) < eps || simd_length(aEnd - bEnd) < eps
    }

    private static func distanceToPolyline(_ p: Vec2, _ poly: BulgePolyline) -> Double {
        var best = Double.infinity
        for i in 0..<poly.segmentCount {
            let seg = poly.segmentCurve(i)
            let (_, _, dist) = seg.closestPoint(to: p, tol: Tolerance(linear: 1e-9))
            best = min(best, dist)
        }
        return best
    }

    /// Chains atoms into one or more closed/open `BulgePolyline`s by
    /// endpoint proximity. Gaps smaller than `4*tol.linear` are bridged
    /// with a micro-segment; larger gaps end a chain (valid — offset
    /// exceeding available space legitimately produces multiple loops).
    private static func chainAtoms(_ atoms: [Curve2], tol: Tolerance) -> [BulgePolyline] {
        var remaining = atoms
        var results: [BulgePolyline] = []
        let bridge = bridgeGap(tol: tol)

        while !remaining.isEmpty {
            var chain: [Curve2] = [remaining.removeFirst()]
            var extended = true
            while extended {
                extended = false
                let chainEnd = chain.last!.evaluate(chain.last!.paramDomain.upperBound)
                if let (idx, reversedMatch) = findNearestStart(chainEnd, in: remaining, within: bridge) {
                    let piece = remaining.remove(at: idx)
                    chain.append(reversedMatch ? piece.reversed() : piece)
                    extended = true
                }
            }
            // Try to close the loop if the chain's end nearly meets its start.
            let start = chain.first!.evaluate(chain.first!.paramDomain.lowerBound)
            let end = chain.last!.evaluate(chain.last!.paramDomain.upperBound)
            let closed = simd_length(end - start) < bridge
            if let poly = buildBulgePolyline(chain, closed: closed) {
                results.append(poly)
            }
        }
        return results
    }

    private static func findNearestStart(_ point: Vec2, in pieces: [Curve2], within tol: Double) -> (Int, Bool)? {
        var best: (Int, Bool, Double)? = nil
        for (i, piece) in pieces.enumerated() {
            let s = piece.evaluate(piece.paramDomain.lowerBound)
            let e = piece.evaluate(piece.paramDomain.upperBound)
            let dStart = simd_length(point - s)
            let dEnd = simd_length(point - e)
            if dStart < tol, best == nil || dStart < best!.2 { best = (i, false, dStart) }
            if dEnd < tol, best == nil || dEnd < best!.2 { best = (i, true, dEnd) }
        }
        return best.map { ($0.0, $0.1) }
    }

    /// Converts a chain of curves (segments/arcs — the only shapes this
    /// pipeline produces) into a single `BulgePolyline`, bridging any small
    /// gaps between consecutive pieces with the previous vertex snapped to
    /// the next piece's start.
    private static func buildBulgePolyline(_ chain: [Curve2], closed: Bool) -> BulgePolyline? {
        guard !chain.isEmpty else { return nil }
        var vertices: [Vec2] = []
        var bulges: [Double] = []

        for piece in chain {
            let start = piece.evaluate(piece.paramDomain.lowerBound)
            if vertices.isEmpty {
                vertices.append(start)
            }
            switch piece {
            case .segment(let s):
                vertices.append(s.b)
                bulges.append(0)
            case .arc(let a):
                let end = piece.evaluate(piece.paramDomain.upperBound)
                vertices.append(end)
                bulges.append(arcToBulge(CircArc(center: a.center, r: a.r, startAngle: a.startAngle, sweep: a.sweep)))
            default:
                // The join/offset pipeline for polylines only ever produces
                // segments and arcs; anything else is unexpected input and
                // is skipped rather than crashing.
                continue
            }
        }
        guard vertices.count >= 2 else { return nil }
        // At this point vertices.count == chain.count + 1 and
        // bulges.count == chain.count (one bulge recorded per traversed
        // piece, "from" that piece's start vertex). `BulgePolyline` always
        // wants bulges.count == vertices.count:
        //  - closed: drop the duplicated closing vertex so the last
        //    recorded bulge becomes the wrap-around segment's bulge.
        //  - open: the trailing vertex has no "next" vertex, so its bulge
        //    slot is unused by `segmentCount`/`segmentCurve` — append a
        //    placeholder 0 to satisfy the count invariant.
        if closed {
            vertices.removeLast()
        } else {
            bulges.append(0)
        }
        return BulgePolyline(vertices: vertices, bulges: bulges, closed: closed)
    }
}
