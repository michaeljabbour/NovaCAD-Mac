//
//  Join.swift
//  DWGViewer / Editing
//
//  JOIN (new feature) — pure geometry for AutoCAD's JOIN command: combine a
//  set of LINE/ARC/LWPOLYLINE source curves into as few entities as
//  possible. Contiguous segments (endpoints coincident within tolerance)
//  chain into ONE LWPOLYLINE; a run of collinear LINEs collapses into one
//  longer LINE; contiguous+concentric same-sweep-direction ARCs collapse
//  into one longer ARC. Mixed contiguous runs (a line meeting an arc, etc.)
//  become an LWPOLYLINE with the arc carried as a bulge segment.
//
//  DESIGN, mirroring the `FilletChamfer`/`Intersect` split already in this
//  codebase: this file is PURE GEOMETRY only — it knows nothing about
//  `EntityStore`, `Transaction`, or `EntityID`. It takes `Curve2`s in and
//  returns a `[JoinResult]` (each an ordered chain + its simplified output
//  shape) out; `JoinExecutor.swift` does the store<->curve bridging and the
//  actual delete-sources/add-merged commit. Kept separate so the chaining/
//  collinearity math is unit-testable without a document, exactly like
//  `GripEditing`'s pure layer is.
//
//  Scope note: only `.segment` and `.arc` participate. A source polyline is
//  decomposed to its per-segment curves by the caller (`EntityCurveBridge
//  .curves`), so a polyline joining another polyline "just works" as a run
//  of segments. `.circle`/`.ellipse`/`.spline` are NOT joinable (a full
//  circle has no free endpoint to chain from; AutoCAD JOIN likewise refuses
//  most of these) and are dropped by the caller before reaching here.
//

import Foundation
import CADCore
import simd

/// One joinable input curve, tagged with the id of the entity it came from
/// so `JoinExecutor` can delete exactly the right sources once a chain is
/// committed. A single polyline contributes MANY `JoinInput`s (one per
/// segment) all sharing the same `sourceId`.
struct JoinInput {
    var sourceId: EntityID
    var curve: Curve2
}

/// The simplified output shape for one joined chain.
enum JoinOutputShape: Equatable {
    /// A run that collapsed to a single straight line.
    case line(a: Vec2, b: Vec2)
    /// A run that collapsed to a single circular arc (concentric, same
    /// radius, contiguous, same sweep direction).
    case arc(CircArc)
    /// A general chain → LWPOLYLINE. `bulges[i]` is the bulge for the
    /// segment leaving `vertices[i]`; the final bulge is 0 for an open
    /// chain (there is no segment after the last vertex).
    case polyline(vertices: [Vec2], bulges: [Double], closed: Bool)

    // Manual `Equatable` (CADCore's `CircArc` isn't `Equatable`) — compares
    // arcs field-by-field. Used only by tests; the app never compares two
    // `JoinOutputShape`s at runtime.
    static func == (lhs: JoinOutputShape, rhs: JoinOutputShape) -> Bool {
        switch (lhs, rhs) {
        case let (.line(a1, b1), .line(a2, b2)):
            return a1 == a2 && b1 == b2
        case let (.arc(a1), .arc(a2)):
            return a1.center == a2.center && a1.r == a2.r
                && a1.startAngle == a2.startAngle && a1.sweep == a2.sweep
        case let (.polyline(v1, bu1, c1), .polyline(v2, bu2, c2)):
            return v1 == v2 && bu1 == bu2 && c1 == c2
        default:
            return false
        }
    }
}

/// One joined chain: the simplified geometry plus every source entity id
/// that fed into it (so the executor deletes them and adds the single
/// merged replacement).
struct JoinResult {
    var shape: JoinOutputShape
    var sourceIds: [EntityID]
}

enum Join {

    /// Endpoints of a joinable curve (start, end). Only `.segment`/`.arc`
    /// reach here; anything else returns nil (and is skipped by the caller).
    static func endpoints(_ c: Curve2) -> (start: Vec2, end: Vec2)? {
        switch c {
        case .segment(let s):
            return (s.a, s.b)
        case .arc(let a):
            return (a.evaluateArc(0), a.evaluateArc(abs(a.sweep)))
        default:
            return nil
        }
    }

    /// Joins `inputs` into the fewest possible chains. Curves are chained by
    /// coincident endpoints (within `tol.linear`); each resulting chain is
    /// then simplified (collinear lines → one line, concentric arcs → one
    /// arc, otherwise → polyline). Curves that can't chain to anything
    /// (isolated, or a type we don't join) are returned as their own
    /// single-element result ONLY if they combined with at least one other
    /// curve — a lone unmergeable curve produces no result (nothing to do),
    /// matching AutoCAD's "JOIN needs at least two things that actually
    /// join" behavior. A result is emitted only when it merges >= 2 source
    /// curves OR simplifies a single multi-vertex source (the latter never
    /// happens here since single sources aren't decomposed by this layer).
    static func join(_ inputs: [JoinInput], tol: Tolerance) -> [JoinResult] {
        let joinable = inputs.filter { endpoints($0.curve) != nil }
        guard joinable.count >= 2 else { return [] }

        var used = [Bool](repeating: false, count: joinable.count)
        var results: [JoinResult] = []

        for seed in joinable.indices where !used[seed] {
            // Grow a chain outward from `seed` in both directions.
            var chain: [Curve2] = [joinable[seed].curve]
            var chainSources: [EntityID] = [joinable[seed].sourceId]
            used[seed] = true

            var extended = true
            while extended {
                extended = false
                guard let (headStart, _) = endpoints(chain.first!),
                      let (_, tailEnd) = endpoints(chain.last!) else { break }

                for i in joinable.indices where !used[i] {
                    guard let (s, e) = endpoints(joinable[i].curve) else { continue }
                    // Try appending to the TAIL (tailEnd == candidate.start,
                    // or tailEnd == candidate.end → reverse the candidate).
                    if coincident(tailEnd, s, tol) {
                        chain.append(joinable[i].curve)
                        chainSources.append(joinable[i].sourceId)
                        used[i] = true; extended = true; break
                    } else if coincident(tailEnd, e, tol) {
                        chain.append(reverse(joinable[i].curve))
                        chainSources.append(joinable[i].sourceId)
                        used[i] = true; extended = true; break
                    }
                    // Try prepending to the HEAD (candidate.end == headStart,
                    // or candidate.start == headStart → reverse the candidate).
                    else if coincident(headStart, e, tol) {
                        chain.insert(joinable[i].curve, at: 0)
                        chainSources.insert(joinable[i].sourceId, at: 0)
                        used[i] = true; extended = true; break
                    } else if coincident(headStart, s, tol) {
                        chain.insert(reverse(joinable[i].curve), at: 0)
                        chainSources.insert(joinable[i].sourceId, at: 0)
                        used[i] = true; extended = true; break
                    }
                }
            }

            // A chain of one curve joined nothing → skip (dedupe sources
            // since a multi-segment single polyline could contribute one
            // curve per segment all with the same id).
            let distinctSources = Set(chainSources)
            guard chain.count >= 2 else { continue }

            let shape = simplify(chain: chain, tol: tol)
            results.append(JoinResult(shape: shape, sourceIds: Array(distinctSources)))
        }

        return results
    }

    // MARK: - Chain simplification

    /// Collapses an ordered, contiguous chain into the simplest output
    /// shape. All-collinear straight segments → one `.line`; all arcs that
    /// share a center+radius and sweep direction → one `.arc`; otherwise a
    /// general `.polyline` (arcs carried as bulges).
    static func simplify(chain: [Curve2], tol: Tolerance) -> JoinOutputShape {
        // Determine chain endpoints for the closed-loop test.
        guard let (chainStart, _) = endpoints(chain.first!),
              let (_, chainEnd) = endpoints(chain.last!) else {
            return .polyline(vertices: [], bulges: [], closed: false)
        }
        let closed = coincident(chainStart, chainEnd, tol)

        // All straight + collinear → single line.
        if !closed, chain.allSatisfy({ if case .segment = $0 { return true } else { return false } }),
           allCollinear(chain, tol: tol) {
            return .line(a: chainStart, b: chainEnd)
        }

        // All arcs sharing center/radius/sweep-sign and contiguous → single arc.
        if !closed, chain.count >= 2, let merged = mergeConcentricArcs(chain, tol: tol) {
            return .arc(merged)
        }

        // General case → polyline with bulges.
        var vertices: [Vec2] = [chainStart]
        var bulges: [Double] = []
        for c in chain {
            switch c {
            case .segment(let s):
                bulges.append(0)
                vertices.append(s.b)
            case .arc(let a):
                bulges.append(arcToBulge(a))
                vertices.append(a.evaluateArc(abs(a.sweep)))
            default:
                break
            }
        }
        if closed {
            // Drop the duplicated closing vertex; mark closed. The last
            // bulge stays (it describes the closing segment).
            vertices.removeLast()
            return .polyline(vertices: vertices, bulges: bulges, closed: true)
        }
        // Open chain: there's no segment leaving the final vertex.
        bulges.append(0)
        return .polyline(vertices: vertices, bulges: bulges, closed: false)
    }

    // MARK: - Geometry predicates

    static func coincident(_ a: Vec2, _ b: Vec2, _ tol: Tolerance) -> Bool {
        simd_length(a - b) <= tol.linear
    }

    /// Every consecutive pair of straight segments points the same
    /// direction (so the whole run lies on one infinite line). Assumes the
    /// chain is already contiguous (endpoints matched during chaining).
    static func allCollinear(_ chain: [Curve2], tol: Tolerance) -> Bool {
        var dir: Vec2? = nil
        for c in chain {
            guard case .segment(let s) = c else { return false }
            let d = s.b - s.a
            let len = simd_length(d)
            guard len > 0 else { continue }
            let unit = d / len
            if let prev = dir {
                // Cross product ~0 AND same direction (dot > 0) → collinear
                // and not doubling back. Compare the cross to the angular
                // tolerance (both are unit vectors, so |cross| == sin θ).
                let cross = prev.x * unit.y - prev.y * unit.x
                if abs(cross) > max(tol.angular, 1e-9) { return false }
                if simd_dot(prev, unit) < 0 { return false }
            }
            dir = unit
        }
        return dir != nil
    }

    /// If every curve in the chain is an arc sharing the same center, radius
    /// and sweep sign, returns the single merged arc spanning the whole run
    /// (start angle of the first, total sweep = sum of the parts). Nil if
    /// any curve isn't such an arc.
    static func mergeConcentricArcs(_ chain: [Curve2], tol: Tolerance) -> CircArc? {
        var center: Vec2? = nil
        var radius: Double? = nil
        var sign: Double? = nil
        var totalSweep = 0.0
        guard case .arc(let first) = chain.first else { return nil }
        for c in chain {
            guard case .arc(let a) = c else { return nil }
            if let ctr = center {
                guard simd_length(ctr - a.center) <= tol.linear else { return nil }
            } else { center = a.center }
            if let r = radius {
                guard abs(r - a.r) <= tol.linear else { return nil }
            } else { radius = a.r }
            let s: Double = a.sweep >= 0 ? 1 : -1
            if let existing = sign {
                guard existing == s else { return nil }
            } else { sign = s }
            totalSweep += a.sweep
        }
        // A merged sweep that meets/exceeds a full turn is degenerate for a
        // single ARC entity (it'd be a circle); refuse rather than produce a
        // self-overlapping arc.
        guard abs(totalSweep) < 2 * .pi + max(tol.angular, 1e-9) else { return nil }
        return CircArc(center: first.center, r: first.r, startAngle: first.startAngle, sweep: totalSweep)
    }

    /// Reverses a curve's direction (start<->end) so it can be appended in
    /// the chain's travel direction. Only segment/arc are ever reversed here.
    static func reverse(_ c: Curve2) -> Curve2 {
        switch c {
        case .segment(let s):
            return .segment(LineSeg(a: s.b, b: s.a))
        case .arc(let a):
            // Reverse: new start is the old end angle, sweep negated.
            let endAngle = a.startAngle + a.sweep
            return .arc(CircArc(center: a.center, r: a.r, startAngle: endAngle, sweep: -a.sweep))
        default:
            return c
        }
    }
}

private extension CircArc {
    /// Point at arc parameter `u` (0...|sweep|), respecting sweep sign — a
    /// thin local mirror of `Curve2.arc`'s own `evaluate`, so `Join` can get
    /// arc endpoints without wrapping every arc in a `Curve2` first.
    func evaluateArc(_ u: Double) -> Vec2 {
        let s: Double = sweep >= 0 ? 1 : -1
        let angle = startAngle + s * u
        return center + Vec2(cos(angle), sin(angle)) * r
    }
}
