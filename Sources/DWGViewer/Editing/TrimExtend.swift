//
//  TrimExtend.swift
//  DWGViewer / Editing
//
//  Phase 4.3 — TRIM/EXTEND core geometry. Pure functions operating on
//  `Curve2`/`BulgePolyline` (via `EntityCurveBridge`) plus a small set of
//  `Transaction` primitives to apply the result — no UI/state-machine
//  concerns here (see `TrimExtendToolState.swift` for the click-loop/fence
//  interactive layer built on top of this).
//
//  Scope (per the plan's own prioritization): LINE, ARC (incl. circle->arc
//  conversion), LWPOLYLINE/POLYLINE2D (incl. bulge-preserving partial
//  removal, closed-polyline open-up) are the fully-correct, thoroughly
//  tested core. SPLINE EXTEND (tangent-ray, not intrinsic extension) is
//  implemented per the plan's explicit requirement. SPLINE as a TRIM target
//  (cutting a spline into pieces) is NOT implemented — `canExtend` is false
//  for splines and this kernel does not attempt to re-fit a spline sub-arc
//  as a trimmed spline entity; a spline can still act as a CUTTING EDGE for
//  trimming other curves (its intersections are found normally via
//  `Intersect.curves`), it just can't itself be the TARGET of a trim. This
//  is called out explicitly in the phase's final report as a known,
//  deliberate gap (splines are the least common real-world TRIM target by
//  far, and correctly re-fitting a trimmed NURBS while preserving its exact
//  shape is materially harder than everything else in this phase).
//

import Foundation
import CADCore
import simd

/// One request to trim or extend a single target entity, already reduced to
/// pure geometry (no UI types) — built by the interactive layer from a click
/// point + the resolved boundary set, consumed here.
struct TrimExtendOutcome {
    /// What to do to commit this outcome — kept generic so the interactive
    /// layer's `Transaction` call is a 3-line dispatch, not a duplicate of
    /// this file's per-shape logic.
    enum Action {
        /// Delete the target entirely (trimming removed its only piece).
        case delete
        /// Replace the target with 0 or more new standalone entities
        /// (`Transaction.replace`) — used whenever piece COUNT changes
        /// (a split, or a circle -> arc conversion) or the entity's
        /// fundamental payload shape changes.
        case replaceStandalone([EntityPayloadCopy])
        /// Replace the target's payload in place (`Transaction.modifyPayload`)
        /// — used for a simple EXTEND that only moves one endpoint without
        /// changing the entity's shape/piece-count (line/arc/ellipse endpoint
        /// move), or a polyline edit that keeps exactly one surviving polyline.
        case modifyInPlace(EntityPayloadCopy)
        /// Nothing valid to do (e.g. click point didn't land in any
        /// removable interval, or no boundary intersects the target at all)
        /// — the interactive layer leaves the target untouched and can show
        /// an "edge does not intersect" message, matching AutoCAD.
        case noOp
    }
    let targetId: EntityID
    let action: Action
}

enum TrimExtend {

    // MARK: - TRIM

    /// Trims `targetId` at the interval containing `clickParam` (a parameter
    /// on the target's OWN un-extended domain — the interactive layer is
    /// responsible for finding the click's nearest point on the target and
    /// converting it to a parameter before calling this). `clickSegment`
    /// (required for a polyline target; ignored for anything else) names
    /// WHICH segment `clickParam` is local to — a polyline target with no
    /// segment specified, or a segment index that doesn't resolve, is
    /// treated as "click didn't land on this entity" (nil), never silently
    /// defaulting to segment 0 (a caller bug that would otherwise trim the
    /// wrong part of the polyline without any error). `boundaries` are OTHER
    /// entities' curves (already resolved, e.g. via `BoundaryResolver`) —
    /// this function intersects the target against each of them.
    ///
    /// Algorithm (per the plan): collect `within1` hits of target vs
    /// boundaries (boundaries may be extended per `extendBoundaries`/
    /// EDGEMODE) -> sorted unique params -> the interval containing
    /// `clickParam` is the piece to REMOVE -> 0/1/2 survivors.
    /// Periodic curves (circle) require >= 2 hits (a single hit on a circle
    /// can't define a removable arc — AutoCAD requires at least 2 cutting
    /// points on a circle).
    static func trim(targetId: EntityID, clickParam: Double, clickSegment: Int? = nil,
                     store: EntityStore, boundaries: [Curve2],
                     extendBoundaries: Bool, tol: Tolerance) -> TrimExtendOutcome? {
        guard let h = store.header(targetId), !h.flags.contains(.deleted) else { return nil }
        let isPolyline = h.type == .lwpolyline || h.type == .polyline2d

        // Polylines: trimming one segment may need to touch the WHOLE
        // vertex/bulge array (removal spanning multiple vertices), so it has
        // its own path. `clickSegment` MUST be supplied and resolve — a
        // missing/invalid segment index is a caller bug (never silently
        // guessed at, e.g. by defaulting to segment 0), since guessing wrong
        // would trim a part of the polyline the user never clicked.
        if isPolyline {
            guard let segIdx = clickSegment else { return nil }
            return trimPolyline(targetId: targetId, clickSegment: segIdx, clickLocalParam: clickParam,
                                store: store, boundaries: boundaries, extendBoundaries: extendBoundaries, tol: tol)
        }

        guard let ec = EntityCurveBridge.curve(for: targetId, segment: nil, in: store) else { return nil }
        let curve = ec.curve
        let hitParams = collectHitParams(curve, boundaries: boundaries, extendBoundaries: extendBoundaries, tol: tol)

        if curve.isPeriodic {
            return trimPeriodic(targetId: targetId, curve: curve, hitParams: hitParams, clickParam: clickParam, tol: tol)
        }
        return trimOpen(targetId: targetId, curve: curve, hitParams: hitParams, clickParam: clickParam, tol: tol)
    }

    /// Collects sorted, deduped hit parameters of `curve` against every
    /// boundary, restricted to hits that land within curve's OWN domain
    /// (`within1`) — the boundary side (`within2`) is extended per
    /// `extendBoundaries`/EDGEMODE but the TARGET side is never extended
    /// during a trim (you can't trim a point outside the object itself).
    private static func collectHitParams(_ curve: Curve2, boundaries: [Curve2], extendBoundaries: Bool, tol: Tolerance) -> [Double] {
        var params: [Double] = []
        for boundary in boundaries {
            let hits = Intersect.curves(curve, boundary, tol: tol, extendA: false, extendB: extendBoundaries)
            for h in hits where h.within1 {
                params.append(h.u1)
            }
        }
        return dedupSorted(params, tol: tol)
    }

    /// Dedup epsilon for parameter values: `Tolerance.parametric` (1e-12) is
    /// tuned for Newton-iteration convergence, far tighter than what's
    /// meaningful for "are these two intersection hits actually the same
    /// point" — using it directly here would fail to merge two hits that are
    /// numerically distinct-but-coincident (e.g. two boundaries crossing the
    /// target at nearly, but not exactly, the same spot due to floating-point
    /// noise in an upstream transform), which would then be treated as TWO
    /// cutting points bracketing a hairline sliver instead of one. `1e-7` is
    /// a generous, scale-appropriate parametric merge threshold for this
    /// dedup step specifically (distinct from the geometric coincidence
    /// tests inside `Intersect`, which already use `tol.linear` in world
    /// units).
    private static let paramDedupEpsilon = 1e-7

    private static func dedupSorted(_ params: [Double], tol: Tolerance) -> [Double] {
        let sorted = params.sorted()
        var result: [Double] = []
        for p in sorted {
            if let last = result.last, abs(p - last) < paramDedupEpsilon { continue }
            result.append(p)
        }
        return result
    }

    /// Open curve (line/arc/ellipse-arc): the hit params partition the
    /// domain into segments; find which segment contains `clickParam` and
    /// drop it, keeping 0/1/2 survivors.
    private static func trimOpen(targetId: EntityID, curve: Curve2, hitParams: [Double], clickParam: Double, tol: Tolerance) -> TrimExtendOutcome {
        guard !hitParams.isEmpty else { return TrimExtendOutcome(targetId: targetId, action: .noOp) }
        let domain = curve.paramDomain
        var bounds = [domain.lowerBound] + hitParams + [domain.upperBound]
        bounds = bounds.filter { $0 >= domain.lowerBound - paramDedupEpsilon && $0 <= domain.upperBound + paramDedupEpsilon }
        bounds.sort()

        guard let removeIdx = intervalIndex(containing: clickParam, in: bounds) else {
            return TrimExtendOutcome(targetId: targetId, action: .noOp)
        }

        var survivorPieces: [Curve2] = []
        for i in 0..<(bounds.count - 1) {
            guard i != removeIdx else { continue }
            let lo = bounds[i], hi = bounds[i + 1]
            guard hi - lo > paramDedupEpsilon else { continue }   // zero-length piece — never emit
            survivorPieces.append(exactSubCurve(curve, from: lo, to: hi))
        }

        if survivorPieces.isEmpty {
            return TrimExtendOutcome(targetId: targetId, action: .delete)
        }
        let payloads = survivorPieces.compactMap { EntityCurveBridge.standalonePayload(for: $0) }
        guard payloads.count == survivorPieces.count else { return TrimExtendOutcome(targetId: targetId, action: .noOp) }
        return TrimExtendOutcome(targetId: targetId, action: .replaceStandalone(payloads))
    }

    /// Periodic curve (circle — the only entity-level periodic case; a
    /// periodic arc entity doesn't exist in DXF, and a closed polyline is
    /// handled per-segment via `trimPolyline`, not here). Needs >= 2 hits to
    /// define any removable interval.
    private static func trimPeriodic(targetId: EntityID, curve: Curve2, hitParams: [Double], clickParam: Double, tol: Tolerance) -> TrimExtendOutcome {
        guard hitParams.count >= 2 else { return TrimExtendOutcome(targetId: targetId, action: .noOp) }
        let domain = curve.paramDomain
        let period = domain.upperBound - domain.lowerBound
        var click = clickParam
        while click < domain.lowerBound { click += period }
        while click >= domain.upperBound { click -= period }

        let sorted = hitParams
        for i in 0..<sorted.count {
            let lo = sorted[i]
            let hi = i + 1 < sorted.count ? sorted[i + 1] : sorted[0] + period
            // `click` is wrapped into [0, period) above, but the LAST
            // interval here wraps past `period` (e.g. cutting points at
            // 10 deg and 350 deg produce a wraparound interval [350, 370]).
            // A click in (0, 10) is the SAME visual arc as a click in
            // (350, 360) — both are part of the short 350->0->10 arc — but
            // only the latter satisfies `click >= lo && click <= hi`
            // directly; the former needs the `+period` alias to land in
            // [350, 370]. Testing both `click` and `click + period` against
            // every interval (harmless for non-wraparound intervals, whose
            // `hi` never approaches `period`) closes this dead zone.
            let clickWrapped = click + period
            guard (click >= lo && click <= hi) || (clickWrapped >= lo && clickWrapped <= hi) else { continue }
            // Removed interval [lo, hi]; every OTHER interval around the
            // circle survives as its own arc piece (AutoCAD: with >2
            // cutting points, TRIM removes only the clicked interval,
            // leaving the rest as multiple arcs).
            var pieces: [Curve2] = []
            for j in 0..<sorted.count {
                let a = sorted[j]
                let b = j + 1 < sorted.count ? sorted[j + 1] : sorted[0] + period
                guard !(abs(a - lo) < paramDedupEpsilon && abs(b - hi) < paramDedupEpsilon) else { continue }
                guard b - a > paramDedupEpsilon else { continue }
                pieces.append(exactSubCurve(curve, from: a, to: b))
            }
            guard !pieces.isEmpty else { return TrimExtendOutcome(targetId: targetId, action: .delete) }
            let payloads = pieces.compactMap { EntityCurveBridge.standalonePayload(for: $0) }
            guard payloads.count == pieces.count else { return TrimExtendOutcome(targetId: targetId, action: .noOp) }
            return TrimExtendOutcome(targetId: targetId, action: .replaceStandalone(payloads))
        }
        return TrimExtendOutcome(targetId: targetId, action: .noOp)
    }

    /// Extracts the EXACT sub-curve over `[lo, hi]` for a line/arc/ellipse
    /// (closed form per shape — avoids `split(at:)`'s generic "guess which
    /// piece" ambiguity, which matters once `hi` can exceed the curve's own
    /// original domain during periodic wraparound arithmetic above).
    private static func exactSubCurve(_ curve: Curve2, from lo: Double, to hi: Double) -> Curve2 {
        switch curve {
        case .segment:
            return .segment(LineSeg(a: curve.evaluate(lo), b: curve.evaluate(hi)))
        case .arc(let a):
            let sign: Double = a.sweep >= 0 ? 1 : -1
            let newStart = a.startAngle + sign * lo
            return .arc(CircArc(center: a.center, r: a.r, startAngle: newStart, sweep: sign * (hi - lo)))
        case .circle(let c):
            // A circle sub-curve over [lo, hi] (periodic domain 0...2pi) is
            // an arc starting at angle `lo` with the given sweep.
            return .arc(CircArc(center: c.center, r: c.r, startAngle: lo, sweep: hi - lo))
        case .ellipse(let e):
            return .ellipse(EllipseArc(center: e.center, majorAxis: e.majorAxis, ratio: e.ratio, startParam: lo, endParam: hi))
        case .spline(let n):
            // Only reached if a spline is ever passed through trimOpen
            // (currently unreachable — splines aren't TRIM targets per this
            // phase's documented scope) — fall back to split(at:) rather
            // than crash.
            guard let (_, right) = n.split(at: max(lo, n.domain.lowerBound)) else { return curve }
            guard let (left, _) = right.split(at: min(hi, n.domain.upperBound)) else { return .spline(right) }
            return .spline(left)
        }
    }

    private static func intervalIndex(containing value: Double, in bounds: [Double]) -> Int? {
        guard bounds.count >= 2 else { return nil }
        for i in 0..<(bounds.count - 1) {
            if value >= bounds[i] - paramDedupEpsilon && value <= bounds[i + 1] + paramDedupEpsilon { return i }
        }
        return nil
    }

    // MARK: - TRIM (polyline)

    /// One boundary-crossing on a polyline, in GLOBAL chained-parameter
    /// space: `seg` is the segment index, `local` the param WITHIN that
    /// segment's own domain (matches `BulgePolyline.segmentCurve(seg)`'s
    /// `paramDomain`), `normalized` is `seg + fractionalPositionInSegment`
    /// purely for ordering/interval arithmetic (never used to reconstruct
    /// geometry — `seg`/`local` are what rebuild the actual curve).
    private struct PolyHit: Comparable {
        var seg: Int
        var local: Double
        var normalized: Double
        static func < (a: PolyHit, b: PolyHit) -> Bool { a.normalized < b.normalized }
    }

    private static func normalizedParam(_ poly: BulgePolyline, seg: Int, local: Double) -> Double {
        let d = poly.segmentCurve(seg).paramDomain
        let span = d.upperBound - d.lowerBound
        let frac = span > 0 ? (local - d.lowerBound) / span : 0
        return Double(seg) + frac
    }

    /// Polyline TRIM: `clickSegment`/`clickLocalParam` locate the click on
    /// ONE segment. Boundaries may cross several segments — every segment is
    /// checked against every boundary, hits are expressed as a single
    /// GLOBAL chained parameter (`segIndex + normalizedLocalU`, matching the
    /// plan's spec) so the removed interval can span multiple vertices; the
    /// vertex/bulge arrays are rebuilt from the surviving pieces. A closed
    /// polyline that gets a piece removed "opens up" (per the plan) — the
    /// vertex list is rebuilt starting right after the removed interval, so
    /// the gap sits at the new start/end rather than wrapping.
    private static func trimPolyline(targetId: EntityID, clickSegment: Int, clickLocalParam: Double,
                                     store: EntityStore, boundaries: [Curve2], extendBoundaries: Bool, tol: Tolerance) -> TrimExtendOutcome? {
        guard let poly = EntityCurveBridge.fullPolyline(for: targetId, in: store) else { return nil }
        let segCount = poly.segmentCount
        guard segCount > 0, clickSegment >= 0, clickSegment < segCount else { return nil }

        var hitsPerSegment: [[Double]] = Array(repeating: [], count: segCount)
        for i in 0..<segCount {
            let seg = poly.segmentCurve(i)
            for boundary in boundaries {
                let hits = Intersect.curves(seg, boundary, tol: tol, extendA: false, extendB: extendBoundaries)
                for h in hits where h.within1 {
                    hitsPerSegment[i].append(h.u1)
                }
            }
            hitsPerSegment[i] = dedupSorted(hitsPerSegment[i], tol: tol)
        }

        var globalHits: [PolyHit] = []
        for i in 0..<segCount {
            for h in hitsPerSegment[i] {
                globalHits.append(PolyHit(seg: i, local: h, normalized: normalizedParam(poly, seg: i, local: h)))
            }
        }
        globalHits.sort()
        let clickGlobal = normalizedParam(poly, seg: clickSegment, local: clickLocalParam)
        guard !globalHits.isEmpty else { return TrimExtendOutcome(targetId: targetId, action: .noOp) }

        if poly.closed {
            guard globalHits.count >= 2 else { return TrimExtendOutcome(targetId: targetId, action: .noOp) }
            let period = Double(segCount)
            var click = clickGlobal
            while click < 0 { click += period }
            while click >= period { click -= period }
            for i in 0..<globalHits.count {
                let lo = globalHits[i]
                let hiRaw = i + 1 < globalHits.count ? globalHits[i + 1] : globalHits[0]
                let hiNorm = i + 1 < globalHits.count ? hiRaw.normalized : hiRaw.normalized + period
                guard click >= lo.normalized && click <= hiNorm else { continue }
                // Survivor: the open chain from `hiRaw` forward (wrapping
                // past the seam if needed — `hiNorm` already encodes whether
                // wraparound occurred, e.g. both cut points landing on the
                // SAME segment with hi's local position preceding lo's means
                // the survivor walks almost all the way around, not just
                // that one segment) around to `lo`. Pass ABSOLUTE normalized
                // endpoints (`lo.seg`'s own `normalized` value, and
                // `hiRaw.normalized` OR `hiRaw.normalized + period` — the
                // exact value that made the `click` bracket test above pass)
                // so the walk length is unambiguous even when fromSeg==toSeg.
                let toNormAbs = lo.normalized + (lo.normalized < hiRaw.normalized ? period : 0)
                let sub = extractPolylineChainByNormalized(poly, fromNorm: hiRaw.normalized, toNorm: toNormAbs)
                guard let sub, !sub.vertices.isEmpty else { return TrimExtendOutcome(targetId: targetId, action: .delete) }
                return TrimExtendOutcome(targetId: targetId, action: .replaceStandalone([EntityCurveBridge.polylinePayload(for: sub)]))
            }
            return TrimExtendOutcome(targetId: targetId, action: .noOp)
        } else {
            var boundsList: [Double] = [0.0] + globalHits.map { $0.normalized } + [Double(segCount)]
            boundsList = Array(Set(boundsList)).sorted()
            guard let removeIdx = intervalIndex(containing: clickGlobal, in: boundsList) else {
                return TrimExtendOutcome(targetId: targetId, action: .noOp)
            }
            var keepRanges: [(Double, Double)] = []
            for i in 0..<(boundsList.count - 1) where i != removeIdx {
                let lo = boundsList[i], hi = boundsList[i + 1]
                guard hi - lo > 1e-9 else { continue }
                keepRanges.append((lo, hi))
            }
            guard !keepRanges.isEmpty else { return TrimExtendOutcome(targetId: targetId, action: .delete) }

            let payloads: [EntityPayloadCopy] = keepRanges.compactMap { range in
                guard let sub = extractPolylineChainByNormalized(poly, fromNorm: range.0, toNorm: range.1) else { return nil }
                return EntityCurveBridge.polylinePayload(for: sub)
            }
            guard payloads.count == keepRanges.count else { return TrimExtendOutcome(targetId: targetId, action: .noOp) }
            // Single surviving range: one modified polyline in place. Two
            // ranges (the clicked interval was in the middle): the original
            // entity becomes TWO new polyline entities.
            if payloads.count == 1 {
                return TrimExtendOutcome(targetId: targetId, action: .modifyInPlace(payloads[0]))
            }
            return TrimExtendOutcome(targetId: targetId, action: .replaceStandalone(payloads))
        }
    }

    private static func localParam(_ poly: BulgePolyline, seg: Int, normalized: Double) -> Double {
        let d = poly.segmentCurve(seg).paramDomain
        let frac = normalized - Double(seg)
        return d.lowerBound + frac * (d.upperBound - d.lowerBound)
    }

    /// Extracts a polyline chain spanning the ABSOLUTE normalized-param range
    /// `[fromNorm, toNorm]` (`toNorm > fromNorm`; `toNorm` may exceed
    /// `segCount` to express wraparound past the closed polyline's own seam
    /// — e.g. `fromNorm = 3.5, toNorm = 4.2` on a 4-segment closed polyline
    /// means "start mid-segment-3, walk through segment 0 (index `4 mod 4`),
    /// end mid-segment-0"). This ABSOLUTE-range representation is what makes
    /// the from==to-segment-number wraparound case (both cut points on the
    /// SAME physical segment, survivor wrapping almost all the way around)
    /// unambiguous — a bug in an earlier version of this function compared
    /// raw segment INDICES (which collide when `fromSeg == toSeg`) instead of
    /// the absolute normalized values (which never collide, since `toNorm`
    /// is always strictly greater than `fromNorm` by construction of every
    /// caller above).
    private static func extractPolylineChainByNormalized(_ poly: BulgePolyline, fromNorm: Double, toNorm: Double) -> BulgePolyline? {
        let segCount = poly.segmentCount
        guard segCount > 0, toNorm > fromNorm else { return nil }

        let fromSeg = min(max(Int(floor(fromNorm)), 0), segCount - 1)
        // `toNorm` can land exactly on an integer (a hit exactly at a
        // vertex) or exceed `segCount` (wraparound) — subtract a hair before
        // flooring so an exact-integer `toNorm` resolves to the segment
        // ENDING there, not the next one starting there.
        let toSegRaw = Int(floor(toNorm - 1e-9))
        let toSeg = max(toSegRaw, fromSeg)
        let localStart = localParam(poly, seg: fromSeg, normalized: fromNorm)
        let localEnd = localParam(poly, seg: toSeg % segCount, normalized: toNorm - Double(toSeg - (toSeg % segCount)))

        // Ordered segment walk: fromSeg, fromSeg+1, ..., toSeg (mod
        // segCount at each step) — `toSeg` itself may be >= segCount when
        // wrapping, so the walk naturally spans the seam.
        var order: [Int] = []
        var s = fromSeg
        while true {
            order.append(s % segCount)
            if s == toSeg { break }
            s += 1
            guard order.count <= segCount + 1 else { return nil }   // safety: never loop forever on malformed input
        }

        var vertices: [Vec2] = []
        var bulges: [Double] = []

        for (walkIdx, segIdx) in order.enumerated() {
            let segCurve = poly.segmentCurve(segIdx)
            let domain = segCurve.paramDomain
            let isFirst = walkIdx == 0
            let isLast = walkIdx == order.count - 1

            let effectiveStart = isFirst ? localStart : domain.lowerBound
            let effectiveEnd = isLast ? localEnd : domain.upperBound
            guard effectiveEnd > effectiveStart - 1e-12 else {
                // Degenerate (click landed exactly on a vertex, or the
                // segment contributes zero length after clipping) — skip
                // emitting a vertex/bulge pair for it, but keep walking so a
                // single-segment chain doesn't silently vanish. If this is
                // the ONLY segment, fall through and let the vertex-count
                // guard below reject an empty result.
                continue
            }

            let startPoint = segCurve.evaluate(effectiveStart)
            if vertices.isEmpty {
                vertices.append(startPoint)
            }
            switch segCurve {
            case .segment:
                vertices.append(segCurve.evaluate(effectiveEnd))
                bulges.append(0)
            case .arc(let a):
                let sign: Double = a.sweep >= 0 ? 1 : -1
                let partialSweep = sign * (effectiveEnd - effectiveStart)
                vertices.append(segCurve.evaluate(effectiveEnd))
                // Partial bulge via tan(sweep/4) — the plan's specified
                // formula for a partially-retained bulge segment.
                bulges.append(tan(partialSweep / 4))
            default:
                // Polylines never contain circle/ellipse/spline segments —
                // `BulgePolyline.segmentCurve` only ever returns
                // .segment/.arc — but guard defensively rather than crash.
                vertices.append(segCurve.evaluate(effectiveEnd))
                bulges.append(0)
            }
        }
        guard vertices.count >= 2 else { return nil }
        // vertices.count == bulges.count + 1 at this point (N segments
        // walked -> N+1 vertices, N bulges) — BulgePolyline wants
        // bulges.count == vertices.count for an OPEN polyline (trailing
        // bulge slot unused by segmentCount/segmentCurve), so pad with 0.
        bulges.append(0)
        return BulgePolyline(vertices: vertices, bulges: bulges, closed: false)
    }

    // MARK: - EXTEND

    /// Extends `targetId`'s nearer endpoint (`nearStart` — the interactive
    /// layer picks whichever domain end `clickPoint` is nearer to) to the
    /// nearest extension-mode hit against `boundaries`. `canExtend` curves
    /// (line/arc/ellipse) use `Intersect.curves(extendA: true)`; splines use
    /// tangent-ray extension (see `extendSpline`); polylines extend only
    /// their first/last segment's free end.
    static func extend(targetId: EntityID, nearStart: Bool,
                       store: EntityStore, boundaries: [Curve2],
                       extendBoundaries: Bool, tol: Tolerance) -> TrimExtendOutcome? {
        guard let ec = EntityCurveBridge.curve(for: targetId, segment: nil, in: store) else { return nil }

        if case .spline(let n) = ec.curve {
            return extendSpline(targetId: targetId, nurbs: n, nearStart: nearStart, boundaries: boundaries, tol: tol)
        }
        if ec.polySegmentIndex != nil {
            return extendPolyline(targetId: targetId, nearStart: nearStart, store: store,
                                  boundaries: boundaries, extendBoundaries: extendBoundaries, tol: tol)
        }
        return extendSimpleCurve(targetId: targetId, curve: ec.curve, nearStart: nearStart,
                                 boundaries: boundaries, extendBoundaries: extendBoundaries, tol: tol)
    }

    /// Shared core for a single line/arc/ellipse curve's EXTEND — used both
    /// standalone and (with a differently-constructed `curve`) for a
    /// polyline's end segment.
    private static func extendSimpleCurve(targetId: EntityID, curve: Curve2, nearStart: Bool,
                                          boundaries: [Curve2], extendBoundaries: Bool, tol: Tolerance) -> TrimExtendOutcome {
        guard curve.canExtend else { return TrimExtendOutcome(targetId: targetId, action: .noOp) }
        let domain = curve.paramDomain
        // Arc/ellipse hit params from `Intersect.curves` are ALWAYS reported
        // wrapped into a canonical range near the curve's OWN un-extended
        // domain (see `Intersect.mapAngleToOtherDomain`/`mapAngleToEllipseDomain`,
        // both of which normalize via `truncatingRemainder(2*pi)` then add
        // 2*pi if negative — so a hit "before the start" of an arc/ellipse
        // comes back as a LARGE POSITIVE value near `2*pi`, never as a small
        // NEGATIVE value the way a plain "extend the domain" mental model
        // would suggest). A line's domain (0...1) has no such periodicity —
        // its `extendA: true` hits genuinely CAN be negative/>1 directly.
        // `unwrapPeriodicHit` below corrects for this by re-expressing a
        // periodic hit at whichever of (u, u - period) sits closer to the
        // curve's own domain, which is exactly what "extend the START
        // backward" needs (a period-shifted alias of the SAME physical
        // point, chosen to be numerically comparable against
        // `domain.lowerBound`). This bug was caught by
        // `TrimExtendTests.testExtendArcStartEndWithNonZeroBaseAngleKeepsFarEndFixed`,
        // an adversarial test written specifically per the plan's request to
        // probe the `nearStart` branch with a non-zero base angle — every
        // pre-existing test happened to use `startDeg: 0`, under which this
        // bug is invisible (delta and delta-2pi both fail the naive `< 0`
        // check identically when startAngle is 0, since a "before start" hit
        // at exactly the wrap boundary coincides with 2*pi regardless).
        let period: Double? = {
            switch curve {
            case .arc, .circle: return 2 * .pi
            case .ellipse: return 2 * .pi
            case .segment, .spline: return nil
            }
        }()
        func unwrapPeriodicHit(_ u: Double) -> Double {
            guard let period else { return u }
            let alias = u - period
            let distU = min(abs(u - domain.lowerBound), abs(u - domain.upperBound))
            let distAlias = min(abs(alias - domain.lowerBound), abs(alias - domain.upperBound))
            return distAlias < distU ? alias : u
        }

        var candidateHits: [Double] = []
        for boundary in boundaries {
            let hits = Intersect.curves(curve, boundary, tol: tol, extendA: true, extendB: extendBoundaries)
            for hit in hits {
                guard hit.within2 || extendBoundaries else { continue }
                let u = unwrapPeriodicHit(hit.u1)
                if nearStart, u < domain.lowerBound - paramDedupEpsilon { candidateHits.append(u) }
                if !nearStart, u > domain.upperBound + paramDedupEpsilon { candidateHits.append(u) }
            }
        }
        guard !candidateHits.isEmpty else { return TrimExtendOutcome(targetId: targetId, action: .noOp) }
        let ownEnd = nearStart ? domain.lowerBound : domain.upperBound
        let best = candidateHits.min(by: { abs($0 - ownEnd) < abs($1 - ownEnd) })!

        let extendedCurve: Curve2
        switch curve {
        case .segment(let s):
            extendedCurve = .segment(nearStart ? LineSeg(a: curve.evaluate(best), b: s.b) : LineSeg(a: s.a, b: curve.evaluate(best)))
        case .arc(let a):
            let sign: Double = a.sweep >= 0 ? 1 : -1
            if nearStart {
                let newStart = a.startAngle + sign * best
                let newSweep = a.sweep - sign * best
                extendedCurve = .arc(CircArc(center: a.center, r: a.r, startAngle: newStart, sweep: newSweep))
            } else {
                let newSweep = sign * best
                extendedCurve = .arc(CircArc(center: a.center, r: a.r, startAngle: a.startAngle, sweep: newSweep))
            }
        case .ellipse(let e):
            extendedCurve = nearStart
                ? .ellipse(EllipseArc(center: e.center, majorAxis: e.majorAxis, ratio: e.ratio, startParam: best, endParam: e.endParam))
                : .ellipse(EllipseArc(center: e.center, majorAxis: e.majorAxis, ratio: e.ratio, startParam: e.startParam, endParam: best))
        default:
            return TrimExtendOutcome(targetId: targetId, action: .noOp)
        }
        guard let payload = EntityCurveBridge.standalonePayload(for: extendedCurve) else {
            return TrimExtendOutcome(targetId: targetId, action: .noOp)
        }
        return TrimExtendOutcome(targetId: targetId, action: .modifyInPlace(payload))
    }

    /// Extends a polyline's free end (segment 0's start, if `nearStart`, or
    /// the last segment's end otherwise) — only meaningful for an OPEN
    /// polyline (a closed polyline has no free end to extend; AutoCAD's own
    /// EXTEND likewise refuses a closed polyline). Only that ONE end
    /// segment's underlying curve (line or arc) is extended; the rest of the
    /// polyline is untouched.
    private static func extendPolyline(targetId: EntityID, nearStart: Bool, store: EntityStore,
                                       boundaries: [Curve2], extendBoundaries: Bool, tol: Tolerance) -> TrimExtendOutcome? {
        guard let poly = EntityCurveBridge.fullPolyline(for: targetId, in: store), !poly.closed, poly.segmentCount > 0 else {
            return TrimExtendOutcome(targetId: targetId, action: .noOp)
        }
        let endSegIndex = nearStart ? 0 : poly.segmentCount - 1
        let endCurve = poly.segmentCurve(endSegIndex)
        let outcome = extendSimpleCurve(targetId: targetId, curve: endCurve, nearStart: nearStart,
                                        boundaries: boundaries, extendBoundaries: extendBoundaries, tol: tol)
        guard case .modifyInPlace(let payload) = outcome.action else { return outcome }

        // Rebuild the polyline with just that one end vertex moved (and, for
        // an arc end segment, its bulge recomputed from the new sweep).
        var verts = poly.vertices
        var bulges = poly.bulges
        switch payload {
        case .line(let l):
            if nearStart { verts[0] = Vec2(l.a.x, l.a.y) } else { verts[verts.count - 1] = Vec2(l.b.x, l.b.y) }
        case .arc(let a):
            guard let newArc = EntityCurveBridge.circArc(fromDegreesStart: a.startAngleDeg, end: a.endAngleDeg,
                                                         center: Vec2(a.center.x, a.center.y), r: a.radius) else {
                return TrimExtendOutcome(targetId: targetId, action: .noOp)
            }
            if nearStart {
                verts[0] = Curve2.arc(newArc).evaluate(0)
                bulges[0] = arcToBulge(newArc)
            } else {
                let d = Curve2.arc(newArc).paramDomain
                verts[verts.count - 1] = Curve2.arc(newArc).evaluate(d.upperBound)
                bulges[endSegIndex] = arcToBulge(newArc)
            }
        default:
            return TrimExtendOutcome(targetId: targetId, action: .noOp)
        }
        let newPoly = BulgePolyline(vertices: verts, bulges: bulges, closed: false)
        return TrimExtendOutcome(targetId: targetId, action: .modifyInPlace(EntityCurveBridge.polylinePayload(for: newPoly)))
    }

    /// Spline EXTEND via tangent-ray (documented spec deviation from
    /// AutoCAD's intrinsic-extension algorithm — see this file's header
    /// comment): the endpoint's tangent line is intersected against every
    /// boundary (as a `LineSeg` with `extendA: true`, i.e. treated as an
    /// infinite ray); on a hit, the spline is extended by re-fitting through
    /// its existing fit-point-equivalent samples plus the new hit point
    /// appended (fit-point style) — this kernel doesn't distinguish
    /// "fit-point" vs "CV" splines at the payload level (DXF SPLINE stores
    /// only control points, never separate fit points, once written), so
    /// both cases are handled uniformly by sampling the existing spline
    /// densely, appending the tangent-ray hit as one more sample, and
    /// re-interpolating via `SplineFit` — visually equivalent to AutoCAD's
    /// fit-point behavior and a reasonable, documented approximation of its
    /// CV behavior.
    private static func extendSpline(targetId: EntityID, nurbs: NURBS, nearStart: Bool, boundaries: [Curve2], tol: Tolerance) -> TrimExtendOutcome {
        guard nurbs.isValid, !nurbs.isClosedLoop else { return TrimExtendOutcome(targetId: targetId, action: .noOp) }
        let curve = Curve2.spline(nurbs)
        let domain = nurbs.domain
        let endParam = nearStart ? domain.lowerBound : domain.upperBound
        let endPoint = curve.evaluate(endParam)
        var tangent = curve.tangent(endParam)
        // Tangent direction must point AWAY from the curve at the start end
        // (extending backwards) and forward at the end (extending
        // forwards) — `derivative`/`tangent` at the lower bound already
        // points in the curve's forward traversal direction, so extending
        // the START needs the ray in the OPPOSITE direction.
        if nearStart { tangent = -tangent }
        guard simd_length(tangent) > 1e-12 else { return TrimExtendOutcome(targetId: targetId, action: .noOp) }

        // Represent the tangent ray as a long (but finite) LineSeg from the
        // endpoint outward, and intersect with `extendA: true` so it behaves
        // as a true infinite ray (only the forward half matters, so instead
        // of extending in both directions we construct the segment already
        // pointing the right way and take only positive-parameter hits).
        let rayLength = tangentRayLength(nurbs)
        let rayEnd = endPoint + tangent * rayLength
        let ray = Curve2.segment(LineSeg(a: endPoint, b: rayEnd))

        var best: (point: Vec2, distAlongRay: Double)? = nil
        for boundary in boundaries {
            let hits = Intersect.curves(ray, boundary, tol: tol, extendA: true, extendB: false)
            for h in hits where h.within2 && h.u1 > paramDedupEpsilon {
                let dist = h.u1 * rayLength
                if best == nil || dist < best!.distAlongRay { best = (h.point, dist) }
            }
        }
        guard let hit = best else { return TrimExtendOutcome(targetId: targetId, action: .noOp) }

        // Snap the hit to the endpoint if it's within tolerance of it
        // (degenerate near-zero extension) — never emit a zero-length
        // addition per the plan's "never emit zero-length segments" rule.
        guard simd_length(hit.point - endPoint) > tol.linear else { return TrimExtendOutcome(targetId: targetId, action: .noOp) }

        let sampleCount = max(nurbs.control.count * 4, 32)
        var samples: [Vec2] = []
        for k in 0...sampleCount {
            let u = domain.lowerBound + (domain.upperBound - domain.lowerBound) * Double(k) / Double(sampleCount)
            samples.append(curve.evaluate(u))
        }
        if nearStart { samples.insert(hit.point, at: 0) } else { samples.append(hit.point) }

        let refit = SplineFit.interpolate(fitPoints: samples, closed: false)
        guard refit.isValid else { return TrimExtendOutcome(targetId: targetId, action: .noOp) }
        return TrimExtendOutcome(targetId: targetId, action: .modifyInPlace(EntityCurveBridge.splinePayload(for: refit)))
    }

    /// Length of the tangent-extension search ray — generous relative to the
    /// spline's own control-polygon extent so a boundary anywhere near the
    /// spline's natural extension direction is found, while staying finite
    /// (required by `Intersect.curves`'s `extendA` line handling, which
    /// already caps an "infinite" line's search domain at 1e6 chord-units —
    /// see `Intersect.effectiveDomain`). Bounded generously below by an
    /// absolute floor so a near-degenerate (very small) spline still gets a
    /// meaningfully long search ray.
    private static func tangentRayLength(_ nurbs: NURBS) -> Double {
        guard let first = nurbs.control.first else { return 1000 }
        var maxDist = 0.0
        for p in nurbs.control {
            maxDist = max(maxDist, simd_length(p - first))
        }
        return max(maxDist * 50, 1000)
    }
}
