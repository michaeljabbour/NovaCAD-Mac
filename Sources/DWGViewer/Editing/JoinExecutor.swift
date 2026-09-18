//
//  JoinExecutor.swift
//  DWGViewer / Editing
//
//  JOIN (new feature) — store/transaction glue for the pure `Join.swift`
//  geometry, mirroring `TrimExtendExecutor`/`FilletChamferExecutor`'s exact
//  "resolve ids → geometry, then apply the result to a Transaction in ONE
//  place" split. `ContentView`'s JOIN command and `EditScriptRunner`'s
//  `join` verb both call `resolveJoin`/`apply` so they share identical
//  commit logic rather than each re-implementing the id→curve→payload
//  mapping.
//

import Foundation
import CADCore

enum JoinExecutor {

    /// A resolved JOIN ready to commit: the merged chains (from `Join.join`)
    /// plus the FULL set of source ids that participated (so the executor
    /// deletes every source, keeping one as the `replace` anchor so the
    /// merged entity inherits its layer).
    struct CommitRequest {
        var results: [JoinResult]
    }

    /// Resolves a JOIN over `ids` (a selection set): decomposes each into
    /// its joinable segment/arc curves via `EntityCurveBridge`, runs the
    /// pure chaining, and returns nil if nothing actually joined (fewer than
    /// two curves, or no contiguous run) — matching AutoCAD's "JOIN needs at
    /// least two objects that connect."
    static func resolveJoin(ids: [EntityID], store: EntityStore, tol: Tolerance) -> CommitRequest? {
        var inputs: [JoinInput] = []
        for id in ids {
            for ec in EntityCurveBridge.curves(for: id, in: store) {
                // Only segments/arcs chain; `Join.endpoints` filters the
                // rest, but pre-filtering here keeps `inputs` tidy.
                switch ec.curve {
                case .segment, .arc:
                    inputs.append(JoinInput(sourceId: id, curve: ec.curve))
                default:
                    break
                }
            }
        }
        let results = Join.join(inputs, tol: tol)
        guard !results.isEmpty else { return nil }
        return CommitRequest(results: results)
    }

    /// Applies a resolved JOIN to the live document via `tx` — the ONE place
    /// a `JoinResult` maps to actual `Transaction` calls. For each merged
    /// chain: the first source id is `replace`d with the single merged
    /// entity (inheriting that source's layer via the `layerId: -1`
    /// sentinel, exactly like `TrimExtendExecutor.apply`), and every OTHER
    /// source in the chain is deleted. Returns the ids of the newly created
    /// merged entities.
    @discardableResult
    static func apply(_ request: CommitRequest, to tx: Transaction) -> [EntityID] {
        var created: [EntityID] = []
        for result in request.results {
            guard let anchor = result.sourceIds.first else { continue }
            let payload = payload(for: result.shape)
            // Delete the non-anchor sources first (order doesn't matter —
            // all are independent tombstones).
            for other in result.sourceIds.dropFirst() {
                tx.delete(other)
            }
            let newIds = tx.replace(anchor, with: [EntityPrototype(type: type(for: payload), layerId: -1, payload: payload)])
            created.append(contentsOf: newIds)
        }
        return created
    }

    // MARK: - Shape → payload

    private static func payload(for shape: JoinOutputShape) -> EntityPayloadCopy {
        switch shape {
        case .line(let a, let b):
            return .line(LinePayload(a: Vec3(x: a.x, y: a.y), b: Vec3(x: b.x, y: b.y)))
        case .arc(let arc):
            // Reuse EntityCurveBridge's arc→payload conversion (handles the
            // CCW/degree normalization) by wrapping the CircArc in a Curve2.
            if let p = EntityCurveBridge.standalonePayload(for: .arc(arc)) { return p }
            // Degenerate fallback (shouldn't happen for a merged arc): a
            // 2-point polyline through the arc's endpoints.
            let s: Double = arc.sweep >= 0 ? 1 : -1
            let startPt = Vec3(x: arc.center.x + cos(arc.startAngle) * arc.r,
                               y: arc.center.y + sin(arc.startAngle) * arc.r)
            let endAngle = arc.startAngle + s * abs(arc.sweep)
            let endPt = Vec3(x: arc.center.x + cos(endAngle) * arc.r,
                             y: arc.center.y + sin(endAngle) * arc.r)
            return .line(LinePayload(a: startPt, b: endPt))
        case .polyline(let vertices, let bulges, let closed):
            let verts = vertices.map { Vec3(x: $0.x, y: $0.y) }
            return .polyline(PolylinePayload(closed: closed), vertices: verts, bulges: bulges)
        }
    }

    /// Maps a payload back to its `DXFEntityType` — `EntityPrototype` needs
    /// an explicit type tag (same helper shape as `TrimExtendExecutor`).
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
