//
//  TrimExtendExecutor.swift
//  DWGViewer / Editing
//
//  Phase 4.3 — glue between `TrimExtendToolState` (UI state), `BoundaryResolver`
//  (lazy per-target boundary lookup), `TrimExtend` (pure geometry), and
//  `Transaction` (commit). Kept separate from `TrimExtend.swift` itself so
//  that file stays pure-geometry (Curve2/BulgePolyline in, outcome out) with
//  no `DXFDocument`/`Transaction` awareness, matching the split already
//  established between `Geometry/` (pure) and `Editing/` (entity-aware).
//

import CADCore
import CoreGraphics

enum TrimExtendExecutor {

    /// Starting world-unit margin added around a target's bbox when
    /// resolving boundaries lazily ("all visible") — deliberately scaled to
    /// the TARGET's own size (NOT the whole document's diagonal — a 15%-of-
    /// document-diagonal margin was this function's first draft, but on a
    /// real 3.4M-entity file spanning ~147,000 units that put ~22,000 units
    /// of margin around even a hairline-thin target, which measured at
    /// 390-2,467ms per lazy query in practice — technically still "pruned"
    /// relative to the whole document, but nowhere near what "never
    /// materialize 2.35M curves" is actually asking for, and unacceptably
    /// slow for an interactive click). A target's own size is what actually
    /// predicts where a meaningful nearby cutting edge lives; the document's
    /// overall extent is not a useful signal for local click gestures.
    ///
    /// `minimumMargin` (the floor for a near-degenerate/point-like target)
    /// was ORIGINALLY 50.0 — but a measurement against the real 3.4M-entity
    /// file found a dense region (near the file's own origin) where a
    /// 50-unit-radius box alone contains 28,295 entities, making the very
    /// FIRST (supposedly cheap) ring query itself cost ~683ms end-to-end for
    /// EXTEND. Lowered to 5.0 (still generous relative to a sub-unit
    /// target).
    ///
    /// `ringGrowthFactor` was ORIGINALLY 4.0 — but re-measuring EXTEND at
    /// the same real point after lowering the floor showed the SAME
    /// underlying problem one ring out: at margin~5 only 26 entities
    /// qualify (cheap), but a straight 4x jump to margin~20 already nets
    /// 60,048 entities in this file's dense region — a single ring's
    /// candidate-resolution cost dominating end-to-end time (416ms)
    /// whenever the true boundary isn't within the very first, tightest
    /// ring. A gentler 2x growth (`2^n` instead of `4^n`) gives the search
    /// more graduated intermediate ring sizes to succeed at BEFORE reaching
    /// a density spike, at the cost of needing more total attempts to reach
    /// the same eventual radius for a genuinely isolated target — an
    /// acceptable trade since `maximumRingSearches` was raised to compensate
    /// (8 attempts of 2x each reaches the same 3*2^7 ~= 384x final multiple
    /// the original 6-attempts-of-4x configuration reached via 3*4^5 —
    /// comparable eventual reach, far smoother growth in between).
    private static let initialMarginFraction = 3.0       // 3x the target's own bbox diagonal
    private static let minimumMargin = 5.0               // floor for a near-degenerate (point-like) target
    private static let maximumRingSearches = 8
    private static let ringGrowthFactor = 2.0

    /// Resolves the boundary `Curve2`s for ONE target, per
    /// `TrimExtendToolState.usedAllVisible`/`boundaryIDs`:
    ///  - explicit boundaries: bridge exactly those ids (materialized once
    ///    per command invocation by the caller — see `resolveExplicitBoundaryCurves`
    ///    — not re-bridged per target).
    ///  - "all visible": resolved LAZILY, HERE, per target, from
    ///    `BoundaryResolver` around the target's own (inflated) bbox — never
    ///    materializes the whole document's curves. Starts with a margin
    ///    proportional to the TARGET's own size (see `initialMarginFraction`)
    ///    and doubles outward (capped at `maximumRingSearches` attempts) only
    ///    if that first, tight query finds nothing at all — the common case
    ///    (a real nearby cutting edge) resolves on the FIRST, cheap query;
    ///    only a genuinely isolated target pays for a wider search.
    static func boundaryCurves(for targetId: EntityID, state: TrimExtendToolState,
                               explicitBoundaryCurves: [Curve2],
                               document: DXFDocument, usePaperSpace: Bool,
                               store: EntityStore, visibility: VisibilityState) -> [Curve2] {
        if !state.usedAllVisible {
            return explicitBoundaryCurves
        }
        let targetBBox = store.bounds(targetId)
        let targetDiag = max(hypot(targetBBox.width, targetBBox.height), 1e-6)
        var margin = max(targetDiag * initialMarginFraction, minimumMargin)

        for _ in 0..<maximumRingSearches {
            let candidateIDs = BoundaryResolver.candidateIDs(document: document, usePaperSpace: usePaperSpace,
                                                             around: targetId, in: store, margin: margin,
                                                             visibility: visibility)
            if !candidateIDs.isEmpty {
                var curves: [Curve2] = []
                for id in candidateIDs {
                    for ec in EntityCurveBridge.curves(for: id, in: store) {
                        curves.append(ec.curve)
                    }
                }
                return curves
            }
            margin *= ringGrowthFactor
        }
        return []
    }

    /// Bridges an explicit boundary `EntityID` set to `Curve2`s once, up
    /// front (used when the user explicitly picked cutting edges rather
    /// than pressing Enter for "all visible") — NOT re-resolved per target,
    /// matching AutoCAD's own "the cutting edge set is fixed for the whole
    /// TRIM/EXTEND command once chosen."
    static func resolveExplicitBoundaryCurves(_ ids: Set<EntityID>, store: EntityStore) -> [Curve2] {
        var curves: [Curve2] = []
        for id in ids {
            for ec in EntityCurveBridge.curves(for: id, in: store) {
                curves.append(ec.curve)
            }
        }
        return curves
    }

    /// One resolved click: which entity (and, for a polyline, which segment)
    /// the click landed nearest to, plus the parameter on that curve/segment
    /// and the world-space point itself (used for EXTEND's "nearer end"
    /// decision and TRIM's "which interval" decision alike).
    struct ClickResolution {
        let targetId: EntityID
        let segment: Int?
        let param: Double
        let worldPoint: CGPoint
    }

    /// Finds the nearest point on `targetId`'s geometry to `clickWorld` —
    /// for a polyline, checks every segment and keeps the closest. Returns
    /// nil if the target has no curve geometry (shouldn't happen for
    /// anything `HitTester` would have returned as a hit, but defensive
    /// against a stale/deleted id).
    static func resolveClick(targetId: EntityID, clickWorld: CGPoint, store: EntityStore, tol: Tolerance) -> ClickResolution? {
        let curves = EntityCurveBridge.curves(for: targetId, in: store)
        guard !curves.isEmpty else { return nil }
        let p = Vec2(clickWorld)
        var best: (segment: Int?, param: Double, dist: Double)? = nil
        for ec in curves {
            let (u, _, dist) = ec.curve.closestPoint(to: p, tol: tol)
            if best == nil || dist < best!.dist {
                best = (ec.polySegmentIndex, u, dist)
            }
        }
        guard let best else { return nil }
        return ClickResolution(targetId: targetId, segment: best.segment, param: best.param, worldPoint: clickWorld)
    }

    /// Applies TRIM to one clicked target, returning what changed (nil if
    /// nothing did — no-op/no-boundary-intersection) — commits nothing
    /// itself; callers apply the returned outcome via a `Transaction e.g.
    /// through `apply(_:to:)` below inside `DocumentSession.performEdit`.
    static func trimAtClick(_ resolution: ClickResolution, boundaries: [Curve2],
                            extendBoundaries: Bool, store: EntityStore, tol: Tolerance) -> TrimExtendOutcome? {
        TrimExtend.trim(targetId: resolution.targetId, clickParam: resolution.param, clickSegment: resolution.segment,
                        store: store, boundaries: boundaries, extendBoundaries: extendBoundaries, tol: tol)
    }

    /// Applies EXTEND to one clicked target. `nearStart` is derived from
    /// which domain end `resolution.param` is closer to (the interactive
    /// layer doesn't need to compute this itself).
    static func extendAtClick(_ resolution: ClickResolution, boundaries: [Curve2],
                              extendBoundaries: Bool, store: EntityStore, tol: Tolerance) -> TrimExtendOutcome? {
        guard let ec = EntityCurveBridge.curve(for: resolution.targetId, segment: resolution.segment, in: store) else { return nil }
        let domain = ec.curve.paramDomain
        let mid = (domain.lowerBound + domain.upperBound) / 2
        let nearStart = resolution.param < mid
        return TrimExtend.extend(targetId: resolution.targetId, nearStart: nearStart, store: store,
                                 boundaries: boundaries, extendBoundaries: extendBoundaries, tol: tol)
    }

    /// Applies a `TrimExtendOutcome` to the live document via `tx` — the ONE
    /// place `.delete`/`.replaceStandalone`/`.modifyInPlace`/`.noOp` map to
    /// actual `Transaction` calls, so `ContentView`'s click handler and
    /// `EditScriptRunner`'s `trim`/`extend` verbs share identical commit
    /// logic rather than each re-implementing the action-to-Transaction
    /// mapping.
    @discardableResult
    static func apply(_ outcome: TrimExtendOutcome, to tx: Transaction) -> Bool {
        switch outcome.action {
        case .noOp:
            return false
        case .delete:
            tx.delete(outcome.targetId)
            return true
        case .replaceStandalone(let payloads):
            tx.replace(outcome.targetId, with: payloads.map { EntityPrototype(type: type(for: $0), layerId: -1, payload: $0) })
            return true
        case .modifyInPlace(let payload):
            tx.modifyPayload(outcome.targetId) { $0 = payload }
            return true
        }
    }

    // MARK: - Fence batch (drag = trim every crossed entity at the indicated side)

    /// Resolves a fence-drag TRIM batch: every `EntityID` `SelectionEngine.fenceSelect`
    /// reports as crossed by `fencePoints` is trimmed using the EXACT WORLD
    /// POINT where the fence actually crosses that entity as the "click"
    /// (per the plan's "trim every crossed entity at the indicated side" —
    /// the fence's own crossing point IS the indication of which side/
    /// interval to remove, exactly like an ordinary click would be). Returns
    /// one `TrimExtendOutcome` per entity that had something to change
    /// (no-op entities are silently omitted, matching a single click's own
    /// no-op handling).
    ///
    /// EXTEND is deliberately NOT batchable via fence in this phase — a
    /// fence's "crossing point" has no meaningful analogue for "which
    /// direction to extend" the way it does for "which interval to remove"
    /// (AutoCAD itself only supports fence-selection for the cutting-edge
    /// prompt, not as an EXTEND target-selection gesture) — the interactive
    /// layer only offers fence-drag while `command == .trim`.
    static func trimFenceBatch(fencePoints: [CGPoint], boundaryState: TrimExtendToolState,
                               explicitBoundaryCurves: [Curve2], document: DXFDocument, usePaperSpace: Bool,
                               store: EntityStore, visibility: VisibilityState, tol: Tolerance,
                               extendBoundaries: Bool = false) -> [TrimExtendOutcome] {
        guard fencePoints.count >= 2 else { return [] }
        let crossedIDs = SelectionEngine.fenceSelect(document: document, usePaperSpace: usePaperSpace,
                                                     fence: fencePoints, visibility: visibility)
        var outcomes: [TrimExtendOutcome] = []
        for id in crossedIDs {
            guard let crossPoint = fenceCrossingPoint(id: id, fencePoints: fencePoints, store: store, tol: tol) else { continue }
            guard let resolution = resolveClick(targetId: id, clickWorld: crossPoint, store: store, tol: tol) else { continue }
            let boundaries = boundaryCurves(for: id, state: boundaryState, explicitBoundaryCurves: explicitBoundaryCurves,
                                            document: document, usePaperSpace: usePaperSpace, store: store, visibility: visibility)
            if let outcome = trimAtClick(resolution, boundaries: boundaries, extendBoundaries: extendBoundaries, store: store, tol: tol),
               !isNoOp(outcome) {
                outcomes.append(outcome)
            }
        }
        return outcomes
    }

    private static func isNoOp(_ outcome: TrimExtendOutcome) -> Bool {
        if case .noOp = outcome.action { return true }
        return false
    }

    /// The world point where the fence polyline actually crosses `id`'s
    /// geometry — the nearest fence-segment/entity-curve intersection to the
    /// entity, used as the trim "click point" for that entity in a fence
    /// batch. Falls back to nil (skip this entity) if, surprisingly, no
    /// precise crossing is found (shouldn't happen for an id
    /// `SelectionEngine.fenceSelect` already reported as crossed, but this
    /// keeps the batch robust against any prefilter/precise-test disagreement
    /// rather than crashing or guessing).
    private static func fenceCrossingPoint(id: EntityID, fencePoints: [CGPoint], store: EntityStore, tol: Tolerance) -> CGPoint? {
        let entityCurves = EntityCurveBridge.curves(for: id, in: store)
        guard !entityCurves.isEmpty else { return nil }
        for i in 0..<(fencePoints.count - 1) {
            let fenceSeg = Curve2.segment(LineSeg(a: Vec2(fencePoints[i]), b: Vec2(fencePoints[i + 1])))
            for ec in entityCurves {
                let hits = Intersect.curves(fenceSeg, ec.curve, tol: tol, extendA: false, extendB: false)
                if let first = hits.first(where: { $0.within1 && $0.within2 }) {
                    return first.point.cgPoint
                }
            }
        }
        return nil
    }

    /// Maps a payload back to its `DXFEntityType` — needed because
    /// `Transaction.replace`'s `EntityPrototype` requires an explicit type
    /// tag (it doesn't infer one from the payload case), and every
    /// trim/extend-produced payload is one of these 4 shapes.
    private static func type(for payload: EntityPayloadCopy) -> DXFEntityType {
        switch payload {
        case .line: return .line
        case .arc: return .arc
        case .circle: return .circle
        case .ellipse: return .ellipse
        case .polyline: return .lwpolyline
        case .spline: return .spline
        default: return .unknown
        }
    }
}
