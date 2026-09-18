//
//  BoundaryResolver.swift
//  DWGViewer / Editing
//
//  Phase 4.3 — "Select cutting edges or <Enter> for all visible, extended"
//  needs a candidate boundary/cutting-edge EntityID set resolved LAZILY, per
//  target, from a spatial prefilter — never a full document scan (the plan's
//  hard requirement: "never materialize 2.35M curves").
//
//  No formal spatial index (quadtree/grid/R-tree) exists anywhere in this
//  codebase (confirmed by investigation before writing this file); what DOES
//  exist, and what `HitTester.hitTest`/`boxSelect` and
//  `SelectionEngine.walkGroups` already rely on for the exact same
//  performance property, is a two-level bounding hierarchy that's already
//  materialized at regen time: each `RenderGroup.bounds` (typically hundreds
//  of groups even at 3.4M entities), then each primitive's own `bounds`
//  (`StrokeStore.Run.bounds`/arc center+radius) within a surviving group.
//  This file reuses that exact hierarchy — group-bbox prefilter, then
//  primitive-bbox prefilter, then resolve to `EntityID` — instead of
//  building a new, redundant spatial structure. See `SelectionEngine.walkGroups`
//  for the precedent this mirrors.
//

import Foundation
import CADCore
import CoreGraphics

enum BoundaryResolver {

    /// Every `EntityID` whose RENDERED bounds intersect `region` (world
    /// space), honoring `visibility` exactly like `HitTester`/`SelectionEngine`
    /// — used as "for target T, only look at entities within T's (inflated)
    /// bbox" for TRIM/EXTEND's "Enter for all visible" cutting-edge mode, and
    /// for OFFSET/FILLET/CHAMFER's neighbor lookups. Deduplicated (a
    /// polyline's several segments all resolve to the SAME owning EntityID —
    /// callers get it once, not once per matching segment).
    ///
    /// Cost: proportional to (groups whose bounds intersect `region`) +
    /// (primitives within those surviving groups), never the whole document
    /// — identical prefilter cost profile to `HitTester.boxSelect`, which is
    /// the proven-fast path on the real 731MB/3.4M-entity fixture.
    static func candidateIDs(document: DXFDocument, usePaperSpace: Bool,
                             near region: CGRect, visibility: VisibilityState) -> Set<EntityID> {
        var result: Set<EntityID> = []
        let groups = usePaperSpace ? document.paperGroups : document.modelGroups

        @inline(__always) func wrap(_ insertId: Int32, _ primitive: EntityRef) -> EntityRef {
            insertId >= 0 ? .insert(insertId) : primitive
        }

        for (gi, g) in groups.enumerated() {
            guard visibility.isSelectable(g) else { continue }
            guard g.bounds.intersectsOrTouches(region) else { continue }
            let gi32 = Int32(gi)
            let tombstones = GroupTombstoneRegistry.tombstones(for: g)

            for (ri, run) in g.strokes.runs.enumerated() {
                if let t = tombstones, t.isDead(.run, Int32(ri)) { continue }
                guard run.bounds.intersectsOrTouches(region) else { continue }
                if let id = HitTester.resolveEntityID(wrap(run.insertId, .primitive(group: gi32, store: .run, index: Int32(ri))),
                                                      document: document, usePaperSpace: usePaperSpace) {
                    result.insert(id)
                }
            }
            for (ai, arc) in g.strokes.arcs.enumerated() {
                if let t = tombstones, t.isDead(.arc, Int32(ai)) { continue }
                let arcBB = arc.isFullCircle
                    ? CGRect(x: arc.center.x - arc.radius, y: arc.center.y - arc.radius,
                            width: arc.radius * 2, height: arc.radius * 2)
                    : HitTester.arcBoundingBox(center: arc.center, radius: arc.radius,
                                               startDeg: arc.startAngleDeg, endDeg: arc.endAngleDeg)
                guard arcBB.intersectsOrTouches(region) else { continue }
                if let id = HitTester.resolveEntityID(wrap(arc.insertId, .primitive(group: gi32, store: .arc, index: Int32(ai))),
                                                      document: document, usePaperSpace: usePaperSpace) {
                    result.insert(id)
                }
            }
        }
        return result
    }

    /// Convenience: candidate ids near `id`'s own current bbox, inflated by
    /// `margin` (world units) — the exact "resolved lazily per target from
    /// the spatial index around the target's bbox" the plan calls for.
    /// `margin` should be generous enough to catch boundaries that only
    /// intersect the target once EXTENDED (a boundary entity whose
    /// un-extended geometry sits outside the target's own bbox but whose
    /// infinite-line/full-circle extension would cross it) — callers pass a
    /// margin derived from the drawing's extents (see `TrimExtend`'s use),
    /// not a hardcoded constant, since "far enough to catch a plausible
    /// extension" scales with the drawing.
    static func candidateIDs(document: DXFDocument, usePaperSpace: Bool,
                             around id: EntityID, in store: EntityStore, margin: Double,
                             visibility: VisibilityState) -> Set<EntityID> {
        let bbox = store.bounds(id)
        guard bbox != .zero || store.header(id) != nil else { return [] }
        let region = bbox.insetBy(dx: -margin, dy: -margin)
        var result = candidateIDs(document: document, usePaperSpace: usePaperSpace, near: region, visibility: visibility)
        result.remove(id)
        return result
    }
}

private extension CGRect {
    /// Same "touching counts as intersecting" fix `SelectionEngine` already
    /// applies (see its `intersectsInclusive` doc comment) — a boundary
    /// candidate exactly tangent to the target's bbox (e.g. a vertical
    /// cutting line at the target's exact bbox edge) must not be silently
    /// dropped by plain `CGRect.intersects`, which excludes zero-area
    /// boundary contact.
    func intersectsOrTouches(_ other: CGRect) -> Bool {
        minX <= other.maxX && maxX >= other.minX && minY <= other.maxY && maxY >= other.minY
    }
}
