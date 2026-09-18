//
//  FilletChamferExecutor.swift
//  DWGViewer / Editing
//
//  Phase 4.4 — glue between `FilletChamferToolState` (UI state),
//  `FilletChamfer` (pure geometry), and `Transaction` (commit). Mirrors
//  `TrimExtendExecutor`'s split for the same reason: keep `FilletChamfer.swift`
//  itself free of `EntityStore`/`Transaction` awareness.
//

import Foundation
import CADCore
import CoreGraphics

enum FilletChamferExecutor {

    /// One fully-resolved FILLET/CHAMFER commit request: both target
    /// entity ids (which may be the SAME entity if the user fillets two
    /// segments of one polyline — not handled by this pass; see the
    /// module's scope note) plus the geometric result to apply.
    struct CommitRequest {
        let id1: EntityID
        let id2: EntityID
        let result: FilletChamferResult
    }

    /// Resolves a FILLET between `id1` (clicked at `click1`) and `id2`
    /// (clicked at `click2`) — LINE/LINE only in this pass (see
    /// `FilletChamfer.swift`'s scope note); any other entity type pair
    /// returns nil (the interactive layer reports "cannot fillet that
    /// object combination" and does not crash).
    static func resolveFillet(id1: EntityID, click1: CGPoint, id2: EntityID, click2: CGPoint,
                              radius: Double, store: EntityStore, tol: Tolerance) -> CommitRequest? {
        guard let l1 = lineSeg(for: id1, in: store), let l2 = lineSeg(for: id2, in: store) else { return nil }
        guard let result = FilletChamfer.fillet(line1: l1, line2: l2, radius: radius,
                                                clickPoint1: Vec2(click1), clickPoint2: Vec2(click2), tol: tol) else { return nil }
        return CommitRequest(id1: id1, id2: id2, result: result)
    }

    static func resolveChamfer(id1: EntityID, click1: CGPoint, id2: EntityID, click2: CGPoint,
                               d1: Double, d2: Double, angleMode: Bool, store: EntityStore, tol: Tolerance) -> CommitRequest? {
        guard let l1 = lineSeg(for: id1, in: store), let l2 = lineSeg(for: id2, in: store) else { return nil }
        guard let result = FilletChamfer.chamfer(line1: l1, line2: l2, d1: d1, d2: d2, angleMode: angleMode,
                                                 clickPoint1: Vec2(click1), clickPoint2: Vec2(click2), tol: tol) else { return nil }
        return CommitRequest(id1: id1, id2: id2, result: result)
    }

    /// Applies a resolved `CommitRequest` to the live document. `trimMode`
    /// (TRIMMODE sysvar): true modifies both original lines in place to
    /// their tangent/chamfer feet AND adds the connector (arc/segment);
    /// false leaves the original lines completely untouched and adds ONLY
    /// the connector, per AutoCAD's own TRIMMODE=0 behavior. Returns the
    /// newly-created connector entity's id (nil if TRIMMODE removed it or
    /// there was nothing to add — e.g. FILLET R=0, which never has a
    /// separate connector entity, joins purely via the two trimmed lines).
    @discardableResult
    static func apply(_ request: CommitRequest, trimMode: Bool, layerId1: Int32, to tx: Transaction) -> EntityID? {
        if trimMode {
            if let t1 = request.result.trimmedLine1, let payload = EntityCurveBridge.standalonePayload(for: t1) {
                tx.modifyPayload(request.id1) { $0 = payload }
            }
            if let t2 = request.result.trimmedLine2, let payload = EntityCurveBridge.standalonePayload(for: t2) {
                tx.modifyPayload(request.id2) { $0 = payload }
            }
        }
        guard let connector = request.result.connector, let payload = EntityCurveBridge.standalonePayload(for: connector) else {
            return nil
        }
        // The connector's layer follows the FIRST-clicked line's layer,
        // matching AutoCAD's own "new fillet/chamfer geometry inherits the
        // first selected object's properties" convention.
        return tx.add(EntityPrototype(type: connectorType(connector), layerId: layerId1, payload: payload))
    }

    private static func connectorType(_ curve: Curve2) -> DXFEntityType {
        switch curve {
        case .arc: return .arc
        case .segment: return .line
        default: return .unknown
        }
    }

    /// Resolves a LINE entity's current geometry to a `LineSeg` — nil for
    /// anything else (arc/polyline/etc — out of scope for this pass, per
    /// `FilletChamfer.swift`'s documented scope).
    private static func lineSeg(for id: EntityID, in store: EntityStore) -> LineSeg? {
        guard let h = store.header(id), !h.flags.contains(.deleted), h.type == .line, h.payload >= 0 else { return nil }
        let l = store.lines[Int(h.payload)]
        return LineSeg(a: Vec2(l.a.x, l.a.y), b: Vec2(l.b.x, l.b.y))
    }
}
