//
//  SelectionEngine.swift
//  DWGViewer / Selection
//
//  Phase 4.1 — Window/Crossing rectangle selection, lasso (arbitrary closed
//  polygon), and fence (open polyline, crossing-only) selection, returning
//  stable `EntityID`s. Built directly on `DXFDocument`'s render groups (the
//  SAME already-tessellated `StrokeStore.Run`/`.Arc`/`TextItem` data
//  `HitTester.hitTest`/`boxSelect` already use) rather than re-decomposing
//  geometry from `EntityStore` payloads — this is deliberate: render groups
//  are already the "curve decomposition" the plan calls for (produced once
//  at parse/regen time), so building a second geometry pipeline on top of
//  `CurveBridge`/`Curve2` would duplicate work for no correctness or
//  performance benefit, and would risk drifting out of sync with whatever
//  the renderer/hit-tester actually draws/picks. `HitTester.boxSelect`'s
//  existing two-level bounds hierarchy (group bounds -> per-run/arc bounds)
//  is the proven-fast prefilter on the real 731MB/3.4M-entity fixture; this
//  file's job is to ADD a precise per-primitive Crossing test alongside the
//  existing Window (full-containment) one, using `SelGeom`.
//

import Foundation
import CADCore
import CoreGraphics

enum SelectionMode {
    case window     // AutoCAD: fully enclosed only
    case crossing   // AutoCAD: any touch/intersection counts
}

enum SelectionEngine {

    // MARK: - Rectangle (Window / Crossing)

    /// Every selectable `EntityID` under `mode`'s semantics, over `rect`
    /// (world-space), in `space`, honoring `vis` (matches
    /// `HitTester.boxSelectEntityIDs`'s visibility contract exactly — hidden/
    /// locked layers and hidden xrefs never selectable). Window = fully
    /// contained (`HitTester.boxSelect`'s existing semantics, reused
    /// verbatim for `.window`); Crossing = any endpoint inside OR any
    /// segment/arc actually intersects the rect boundary.
    static func rectSelect(document: DXFDocument, usePaperSpace: Bool,
                           rect: CGRect, mode: SelectionMode,
                           visibility: VisibilityState) -> Set<EntityID> {
        switch mode {
        case .window:
            // Existing HitTester semantics are exactly Window — reuse
            // directly rather than reimplementing full-containment here.
            return HitTester.boxSelectEntityIDs(document: document, usePaperSpace: usePaperSpace,
                                                rect: rect, visibility: visibility)
        case .crossing:
            let region = RectRegion(minX: Double(rect.minX), minY: Double(rect.minY),
                                    maxX: Double(rect.maxX), maxY: Double(rect.maxY))
            return crossingSelect(document: document, usePaperSpace: usePaperSpace,
                                  region: region, visibility: visibility)
        }
    }

    // MARK: - Lasso (closed polygon, ≥3 points)

    /// Selects by an arbitrary closed polygon path (Option+drag gesture).
    /// Same Window/Crossing duality as `rectSelect`, generalized from "4 rect
    /// edges" to "the polygon's own edges" via `SelGeom.segmentIntersectsPolygon`/
    /// `pointInPolygon`. `polygon` need not be explicitly closed (last point
    /// implicitly connects back to the first, matching `SelGeom`'s
    /// convention).
    static func lassoSelect(document: DXFDocument, usePaperSpace: Bool,
                            polygon: [CGPoint], mode: SelectionMode,
                            visibility: VisibilityState) -> Set<EntityID> {
        guard polygon.count >= 3 else { return [] }
        let poly = polygon.map { Vec2($0) }
        let bbox = polygonBounds(polygon)
        return polygonSelect(document: document, usePaperSpace: usePaperSpace,
                             polygon: poly, polygonBBox: bbox, mode: mode, visibility: visibility)
    }

    // MARK: - Fence (open polyline, crossing-only)

    /// AutoCAD FENCE: an open rubber-band polyline; anything the fence's
    /// segments cross is selected (there is no "Window" analogue for an open
    /// path — every fence selection is Crossing semantics by definition,
    /// hence no `mode` parameter).
    static func fenceSelect(document: DXFDocument, usePaperSpace: Bool,
                            fence: [CGPoint], visibility: VisibilityState) -> Set<EntityID> {
        guard fence.count >= 2 else { return [] }
        let segments = zip(fence, fence.dropFirst()).map { (Vec2($0.0), Vec2($0.1)) }
        let bbox = polygonBounds(fence)
        var result: Set<EntityID> = []
        walkGroups(document: document, usePaperSpace: usePaperSpace, filterBBox: bbox,
                  visibility: visibility) { candidate in
            for (a, b) in segments {
                if candidate.crossesSegment(a, b) { return true }
            }
            return false
        } into: { id in result.insert(id) }
        return result
    }

    // MARK: - Crossing rectangle (shared core)

    private static func crossingSelect(document: DXFDocument, usePaperSpace: Bool,
                                       region: RectRegion, visibility: VisibilityState) -> Set<EntityID> {
        var result: Set<EntityID> = []
        walkGroups(document: document, usePaperSpace: usePaperSpace,
                  filterBBox: CGRect(x: region.minX, y: region.minY,
                                     width: region.maxX - region.minX, height: region.maxY - region.minY),
                  visibility: visibility) { candidate in
            candidate.crossesRect(region)
        } into: { id in result.insert(id) }
        return result
    }

    private static func polygonSelect(document: DXFDocument, usePaperSpace: Bool,
                                      polygon: [Vec2], polygonBBox: CGRect, mode: SelectionMode,
                                      visibility: VisibilityState) -> Set<EntityID> {
        var result: Set<EntityID> = []
        walkGroups(document: document, usePaperSpace: usePaperSpace, filterBBox: polygonBBox,
                  visibility: visibility) { candidate in
            switch mode {
            case .crossing:
                return candidate.crossesPolygon(polygon)
            case .window:
                return candidate.fullyInsidePolygon(polygon)
            }
        } into: { id in result.insert(id) }
        return result
    }

    private static func polygonBounds(_ pts: [CGPoint]) -> CGRect {
        guard let first = pts.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in pts.dropFirst() {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    // MARK: - Group/primitive walk (shared prefilter + candidate abstraction)

    /// One candidate primitive or whole-insert's testable geometry, lazily
    /// exposing the specific `SelGeom` queries callers need — avoids
    /// building an intermediate `[Curve2]` array per primitive when most
    /// candidates get rejected by the bbox prefilter before any precise test
    /// runs at all.
    private struct Candidate {
        enum Shape {
            case segments([Vec2])           // polyline run: consecutive pairs are edges; closed wraps last->first
            case arc(center: Vec2, radius: Double, startAngle: Double, sweep: Double)
            case point(Vec2)
        }
        let shape: Shape
        let closed: Bool

        func crossesRect(_ rect: RectRegion) -> Bool {
            switch shape {
            case .segments(let pts):
                return testSegments(pts, closed: closed) { a, b in SelGeom.segmentIntersectsRect(a, b, rect) }
            case .arc(let c, let r, let s, let sw):
                return SelGeom.arcIntersectsRect(center: c, radius: r, startAngle: s, sweep: sw, rect: rect)
            case .point(let p):
                return rect.contains(p)
            }
        }

        func crossesPolygon(_ polygon: [Vec2]) -> Bool {
            switch shape {
            case .segments(let pts):
                return testSegments(pts, closed: closed) { a, b in SelGeom.segmentIntersectsPolygon(a, b, polygon) }
            case .arc(let c, let r, let s, let sw):
                // Sample the arc into short segments for the polygon test —
                // lasso boundaries are arbitrary, so no closed-form
                // arc/polygon-edge test exists; sampling density matches
                // typical lasso point spacing (the plan's own 2px min-sample
                // gesture spec), more than adequate for a decent visual
                // approximation of arc-crosses-arbitrary-polygon.
                return arcSamplePoints(center: c, radius: r, startAngle: s, sweep: sw).crossesAsPolyline(polygon)
            case .point(let p):
                return SelGeom.pointInPolygon(p, polygon)
            }
        }

        func crossesSegment(_ a: Vec2, _ b: Vec2) -> Bool {
            switch shape {
            case .segments(let pts):
                return testSegments(pts, closed: closed) { p, q in SelGeom.segmentsIntersect(p, q, a, b) }
            case .arc(let c, let r, let s, let sw):
                return arcSamplePoints(center: c, radius: r, startAngle: s, sweep: sw)
                    .crossesAsPolylineSegment(a, b)
            case .point(let p):
                // A degenerate point "crosses" a fence segment only if it
                // lies exactly on it — negligible in practice, matched for
                // completeness/consistency with the rect/polygon cases.
                return SelGeom.segmentsIntersect(p, p, a, b)
            }
        }

        func fullyInsidePolygon(_ polygon: [Vec2]) -> Bool {
            switch shape {
            case .segments(let pts):
                return pts.allSatisfy { SelGeom.pointInPolygon($0, polygon) }
            case .arc(let c, let r, let s, let sw):
                return arcSamplePoints(center: c, radius: r, startAngle: s, sweep: sw)
                    .allSatisfy { SelGeom.pointInPolygon($0, polygon) }
            case .point(let p):
                return SelGeom.pointInPolygon(p, polygon)
            }
        }

        private func testSegments(_ pts: [Vec2], closed: Bool, _ test: (Vec2, Vec2) -> Bool) -> Bool {
            guard pts.count >= 2 else { return false }
            for i in 0..<(pts.count - 1) {
                if test(pts[i], pts[i + 1]) { return true }
            }
            if closed, pts.count > 2 {
                if test(pts[pts.count - 1], pts[0]) { return true }
            }
            return false
        }

        /// Arc sampling density for polygon/fence tests (no closed-form
        /// arc-vs-arbitrary-polygon-edge test exists) — 24 segments/full
        /// circle keeps chordal deviation well under typical screen-pixel
        /// tolerance at any reasonable zoom.
        private func arcSamplePoints(center: Vec2, radius: Double, startAngle: Double, sweep: Double) -> [Vec2] {
            let segments = max(2, Int(ceil(abs(sweep) / (2 * .pi) * 24)))
            let sign: Double = sweep >= 0 ? 1 : -1
            return (0...segments).map { i in
                let u = abs(sweep) * Double(i) / Double(segments)
                let angle = startAngle + sign * u
                return center + Vec2(cos(angle), sin(angle)) * radius
            }
        }
    }

    /// Shared traversal: for each visible+selectable `RenderGroup` whose
    /// bounds intersect `filterBBox`, test every run/arc/text/point/fillRun
    /// primitive (skipping tombstoned ones) via `test`, resolving hits to
    /// stable `EntityID`s through the SAME positional-ref resolution
    /// `HitTester.boxSelectEntityIDs` uses — `.insert`-owned primitives
    /// resolve to their owning INSERT's `EntityID` (whole-block selection),
    /// loose primitives resolve to their own entity. A block is "selected"
    /// as soon as ANY of its member primitives passes `test` (Crossing-style
    /// semantics for `.insert`, matching `HitTester.boxSelect`'s existing
    /// `.insert` handling, which likewise counts any one child primitive's
    /// full-containment as sufficient for the WHOLE block).
    private static func walkGroups(document: DXFDocument, usePaperSpace: Bool, filterBBox: CGRect,
                                   visibility: VisibilityState,
                                   test: (Candidate) -> Bool,
                                   into add: (EntityID) -> Void) {
        let groups = usePaperSpace ? document.paperGroups : document.modelGroups

        @inline(__always) func wrap(_ insertId: Int32, _ primitive: EntityRef) -> EntityRef {
            insertId >= 0 ? .insert(insertId) : primitive
        }

        for (gi, g) in groups.enumerated() {
            guard visibility.isSelectable(g) else { continue }
            guard g.bounds.intersectsInclusive(filterBBox) else { continue }
            let gi32 = Int32(gi)
            let pts = g.strokes.points
            let tombstones = GroupTombstoneRegistry.tombstones(for: g)

            for (ri, run) in g.strokes.runs.enumerated() {
                if let t = tombstones, t.isDead(.run, Int32(ri)) { continue }
                guard run.bounds.intersectsInclusive(filterBBox) else { continue }
                let s = Int(run.start), c = Int(run.count)
                guard c >= 1 else { continue }
                let segPts = (s..<(s + c)).map { Vec2(pts[$0]) }
                let candidate = Candidate(shape: .segments(segPts), closed: run.closed)
                if test(candidate),
                   let id = HitTester.resolveEntityID(wrap(run.insertId, .primitive(group: gi32, store: .run, index: Int32(ri))),
                                                      document: document, usePaperSpace: usePaperSpace) {
                    add(id)
                }
            }

            for (ai, arc) in g.strokes.arcs.enumerated() {
                if let t = tombstones, t.isDead(.arc, Int32(ai)) { continue }
                let arcBB = arc.isFullCircle
                    ? CGRect(x: arc.center.x - arc.radius, y: arc.center.y - arc.radius,
                            width: arc.radius * 2, height: arc.radius * 2)
                    : HitTester.arcBoundingBox(center: arc.center, radius: arc.radius,
                                               startDeg: arc.startAngleDeg, endDeg: arc.endAngleDeg)
                guard arcBB.intersectsInclusive(filterBBox) else { continue }
                let sweepRad = arc.isFullCircle ? 2 * .pi
                    : (arc.endAngleDeg - arc.startAngleDeg) * .pi / 180
                let normalizedSweep: Double = {
                    guard !arc.isFullCircle else { return 2 * .pi }
                    var sw = sweepRad.truncatingRemainder(dividingBy: 2 * .pi)
                    if sw <= 0 { sw += 2 * .pi }
                    return sw
                }()
                let candidate = Candidate(shape: .arc(center: Vec2(arc.center), radius: Double(arc.radius),
                                                      startAngle: Double(arc.startAngleDeg) * .pi / 180,
                                                      sweep: normalizedSweep), closed: arc.isFullCircle)
                if test(candidate),
                   let id = HitTester.resolveEntityID(wrap(arc.insertId, .primitive(group: gi32, store: .arc, index: Int32(ai))),
                                                      document: document, usePaperSpace: usePaperSpace) {
                    add(id)
                }
            }

            for (ti, t) in g.texts.enumerated() {
                if let ts = tombstones, ts.isDead(.text, Int32(ti)) { continue }
                guard t.height > 0 else { continue }
                let corners = textRotatedCorners(t)
                guard corners.map({ CGPoint(x: $0.x, y: $0.y) }).boundingBox.intersectsInclusive(filterBBox) else { continue }
                let candidate = Candidate(shape: .segments(corners), closed: true)
                if test(candidate),
                   let id = HitTester.resolveEntityID(wrap(t.insertId, .primitive(group: gi32, store: .text, index: Int32(ti))),
                                                      document: document, usePaperSpace: usePaperSpace) {
                    add(id)
                }
            }

            for (pi, p) in g.points.enumerated() {
                if let t = tombstones, t.isDead(.point, Int32(pi)) { continue }
                guard filterBBox.containsInclusive(p) else { continue }
                let candidate = Candidate(shape: .point(Vec2(p)), closed: false)
                if test(candidate) {
                    let ins = pi < g.strokes.pointInsertIds.count ? g.strokes.pointInsertIds[pi] : -1
                    if let id = HitTester.resolveEntityID(wrap(ins, .primitive(group: gi32, store: .point, index: Int32(pi))),
                                                          document: document, usePaperSpace: usePaperSpace) {
                        add(id)
                    }
                }
            }

            for (fi, run) in g.strokes.fillRuns.enumerated() {
                if let t = tombstones, t.isDead(.fillRun, Int32(fi)) { continue }
                guard run.bounds.intersectsInclusive(filterBBox) else { continue }
                let s = Int(run.start), c = Int(run.count)
                guard c >= 1 else { continue }
                let fillPts = (s..<(s + c)).map { Vec2(g.strokes.fillPoints[$0]) }
                let candidate = Candidate(shape: .segments(fillPts), closed: true)
                if test(candidate),
                   let id = HitTester.resolveEntityID(wrap(run.insertId, .primitive(group: gi32, store: .fillRun, index: Int32(fi))),
                                                      document: document, usePaperSpace: usePaperSpace) {
                    add(id)
                }
            }
        }
    }

    /// The 4 corners of a `TextItem`'s rotated local bounding box, in world
    /// space — same width/height estimate `HitTester.hitTest`'s text branch
    /// uses (kept in exact agreement so click-select and rect-select treat
    /// text identically), just exposed as 4 corner points instead of a
    /// local-space accept/reject box.
    private static func textRotatedCorners(_ t: TextItem) -> [Vec2] {
        let box = t.localBounds
        let x0 = box.minX, x1 = box.maxX, y0 = box.minY, y1 = box.maxY
        let rot = t.rotationDegrees * .pi / 180
        let c = cos(rot), s = sin(rot)
        func rotated(_ lx: CGFloat, _ ly: CGFloat) -> Vec2 {
            let wx = t.position.x + lx * c - ly * s
            let wy = t.position.y + lx * s + ly * c
            return Vec2(Double(wx), Double(wy))
        }
        return [rotated(x0, y0), rotated(x1, y0), rotated(x1, y1), rotated(x0, y1)]
    }
}

// MARK: - Small local helpers

private extension Array where Element == Vec2 {
    /// Treats `self` as an open polyline and tests each of its segments
    /// against a closed `polygon` — used by arc-sample-vs-lasso-polygon.
    func crossesAsPolyline(_ polygon: [Vec2]) -> Bool {
        guard count >= 2 else { return false }
        for i in 0..<(count - 1) {
            if SelGeom.segmentIntersectsPolygon(self[i], self[i + 1], polygon) { return true }
        }
        return false
    }

    /// Treats `self` as an open polyline and tests each of its segments
    /// against a single fence segment `a->b`.
    func crossesAsPolylineSegment(_ a: Vec2, _ b: Vec2) -> Bool {
        guard count >= 2 else { return false }
        for i in 0..<(count - 1) {
            if SelGeom.segmentsIntersect(self[i], self[i + 1], a, b) { return true }
        }
        return false
    }
}

private extension Array where Element == CGPoint {
    var boundingBox: CGRect {
        guard let first = self.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in dropFirst() {
            minX = Swift.min(minX, p.x); maxX = Swift.max(maxX, p.x)
            minY = Swift.min(minY, p.y); maxY = Swift.max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

private extension CGRect {
    /// `CGRect.intersects` returns `false` for rects that only touch along a
    /// shared edge or corner (documented CoreGraphics behavior: it tests for
    /// non-empty AREA overlap, not boundary contact) — wrong for a bbox
    /// PREFILTER here, where a perfectly horizontal/vertical run's bounds
    /// are legitimately zero-width/zero-height and must still register as
    /// "touching" a selection rect that shares that exact edge (e.g. a
    /// vertical line at x=5 and a fence leg also at x=5). A prefilter false
    /// positive just costs one extra precise `SelGeom` test (cheap); a false
    /// negative silently drops a valid selection (a correctness bug) — this
    /// bug was caught by `SelectionEngineTests.testFenceWithMultiSegmentPath`
    /// during development.
    func intersectsInclusive(_ other: CGRect) -> Bool {
        minX <= other.maxX && maxX >= other.minX && minY <= other.maxY && maxY >= other.minY
    }

    /// `CGRect.contains(_:)` for a point already includes boundary points
    /// correctly (unlike `intersects`, this one isn't the trap) — this
    /// exists purely so call sites read symmetrically with
    /// `intersectsInclusive` and to avoid the ad hoc `insetBy(dx:-1,dy:-1)`
    /// fudge-factor this replaced (which was both wrong in magnitude for an
    /// arbitrary-scale selection rect and unnecessary once the actual bug —
    /// `intersects`, not `contains` — was identified).
    func containsInclusive(_ p: CGPoint) -> Bool {
        contains(p)
    }
}
