//
//  RegionTool.swift
//  DWGViewer / Editing
//
//  Phase 6.3 — REGION, scoped per the plan's own explicit guidance: "REGION
//  is genuinely hard and lower-value on its own... do NOT attempt to build
//  boundary detection from scratch; the plan's own fallback — 'select a
//  closed polyline/circle/ellipse -> region record' — is acceptable scope."
//  Real AutoCAD REGION traces an arbitrary set of coplanar curves into a
//  bounded ACIS solid; that's Phase 7's `BoundaryDetect.trace` (hatch
//  boundary detection shares the same underlying problem) — this file does
//  NOT attempt it.
//
//  What this DOES do: given an EntityID that is ALREADY a closed
//  LWPOLYLINE/POLYLINE2D, CIRCLE, or full-sweep ELLIPSE, record a
//  `RegionRecord` (area, perimeter, source entity) in a session-side table
//  (`DocumentSession.regions`, mirroring `db.arrays`'s own "associativity
//  side-table, transaction-visible in spirit but not literally undo-tracked
//  at the Transaction op level" shape — see that type's own doc comment for
//  why a plain dictionary keyed by EntityID is adequate here: a REGION
//  record has no geometry of its own to lose on undo, since it never
//  mutates or deletes the source entity, only tags it).
//
//  Serialization: per the plan's spec, "NovaCAD-authored regions write as
//  closed LWPOLYLINE(s) + NOVACAD REGION XDATA + WriteWarning (hand-writing
//  ACIS/SAT is out of scope)." Since this implementation's REGION record
//  points at an EXISTING closed LWPOLYLINE/CIRCLE/ELLIPSE rather than
//  synthesizing a NEW one, there is no separate entity to write — the
//  region-ness is carried entirely by `NOVACAD REGION` XDATA on the
//  ALREADY-being-written source entity (`EntityRecordWriter`'s generic
//  XDATA pass — see `writeXData` — already emits this for free once
//  `EntityStore.xdata[id]` is populated, matching how `ArrayDefinition`
//  members carry their own `ARRAYDEF` XDATA — see `ArrayTool.swift`). No
//  `WriteWarning` is needed for a NovaCAD-authored region specifically
//  BECAUSE it round-trips as an ordinary closed polyline/circle/ellipse (any
//  OTHER application opening the file just sees that shape, silently
//  ignoring the unrecognized XDATA app id, which is exactly how DXF XDATA
//  is supposed to degrade) — the plan's WriteWarning language anticipates a
//  scheme that fabricates NEW geometry no source entity already justified,
//  which this simpler scope avoids needing entirely.
//

import Foundation
import CoreGraphics

/// One region record — session-local bookkeeping, not a new geometric
/// entity. `sourceId` is the closed polyline/circle/ellipse this region
/// wraps; the region has no geometry independent of that entity (unlike
/// `ArrayDefinition`, which spawns real member copies).
struct RegionRecord: Equatable {
    var sourceId: EntityID
    /// Signed per the shoelace convention (positive = CCW) for polylines;
    /// always positive for circle/ellipse (no winding ambiguity there).
    /// Callers wanting a plain magnitude should `abs()` this themselves
    /// (mirrors `SearchIndex.polygonArea`'s own "caller abs()es" convention).
    var area: Double
    var perimeter: Double
}

enum RegionTool {

    /// XDATA app-id NovaCAD-authored regions are tagged with — see this
    /// file's header comment for why this is the ENTIRE persistence
    /// mechanism (no synthesized geometry, no WriteWarning needed).
    static let xdataAppId = "NOVACAD"
    static let xdataRegionMarker = "REGION"

    /// Builds a `RegionRecord` for `id` if-and-only-if it currently resolves
    /// to a closed LWPOLYLINE/POLYLINE2D, a CIRCLE, or a full-sweep ELLIPSE
    /// (an open elliptical ARC is not a valid region boundary — mirrors
    /// AutoCAD's own REGION command rejecting open curves). Returns nil for
    /// anything else (host call site reports a clear message rather than
    /// silently no-op'ing — see `ContentView.commitRegionPick`).
    static func makeRegion(from id: EntityID, store: EntityStore) -> RegionRecord? {
        guard let h = store.header(id), !h.flags.contains(.deleted), h.payload >= 0 else { return nil }
        switch h.type {
        case .lwpolyline, .polyline2d:
            let p = store.polylines[Int(h.payload)]
            guard p.closed, p.vertsCount >= 3 else { return nil }
            let verts = (0..<Int(p.vertsCount)).map { store.vertexArena[Int(p.vertsStart) + $0].cgPoint }
            // Bulge (arc-segment) contribution to area/perimeter is
            // deliberately ignored here (treated as a straight chord) —
            // documented simplification: an EXACT bulge-aware area/perimeter
            // needs `BulgePolyline`'s own per-segment arc integration
            // (Geometry/Curve.swift), which is more machinery than a
            // fallback-scope REGION record's informational area/perimeter
            // warrants. Good enough for hatch-boundary/hit-test purposes
            // (both of which use the vertex loop directly, not this number)
            // — see this type's own doc comment on `area`'s intended use.
            let area = Double(MeasureState.polygonArea(verts))
            let perimeter = Double(MeasureState.pathLength(verts, closed: true))
            return RegionRecord(sourceId: id, area: area, perimeter: perimeter)

        case .circle:
            let c = store.circles[Int(h.payload)]
            guard c.radius > 0 else { return nil }
            return RegionRecord(sourceId: id, area: .pi * c.radius * c.radius, perimeter: 2 * .pi * c.radius)

        case .ellipse:
            let e = store.ellipses[Int(h.payload)]
            let sweep = abs(e.endParam - e.startParam)
            // Full sweep only (2*pi, allowing float slop) — an elliptical
            // ARC has no well-defined enclosed area.
            guard sweep >= 2 * .pi - 1e-6 else { return nil }
            let majorLen = e.majorAxisEndpoint.length
            guard majorLen > 0 else { return nil }
            let minorLen = majorLen * e.ratio
            let area = .pi * majorLen * minorLen
            // Ramanujan's approximation (exact perimeter has no closed
            // form) — plenty accurate for an informational region record.
            let a = majorLen, b = minorLen
            let h2 = pow((a - b) / (a + b), 2)
            let perimeter = .pi * (a + b) * (1 + 3 * h2 / (10 + sqrt(4 - 3 * h2)))
            return RegionRecord(sourceId: id, area: area, perimeter: perimeter)

        default:
            return nil
        }
    }

    /// Tags `id`'s XDATA with the NovaCAD REGION marker (see this file's
    /// header comment) so a save/reload round-trip preserves region-ness
    /// without inventing new geometry. Bypasses `Transaction` deliberately
    /// (like `BlockEditor`'s block-table metadata) since `EntityStore.xdata`
    /// is a side dictionary the `Op` enum has no case for — callers MUST
    /// register an undo/redo side effect via `tx.registerSideEffect` around
    /// this call (mirrors every other `EntityStore`-side-table mutation in
    /// this codebase — see `BlockEditor.createBlock`'s identical pattern).
    static func tagAsRegionXData(_ id: EntityID, store: EntityStore) {
        let before = store.xdata[id.raw]
        var blob = before ?? XDataBlob(appId: xdataAppId, pairs: [])
        guard !blob.pairs.contains(where: { $0.code == 1000 && $0.value == .string(xdataRegionMarker) }) else { return }
        blob.pairs.append((code: 1000, value: .string(xdataRegionMarker)))
        store.xdata[id.raw] = blob
    }
}
