import CADCore
import CoreGraphics

/// One row in the properties panel.
struct EntityProperty: Identifiable, Equatable {
    let name: String
    let value: String
    var id: String { name }

    static let variesValue = "Various/Multiple"
}

enum HitTester {

    // NOTE (Phase 1.3): a positional `EntityRef.primitive` now carries enough
    // information to resolve to a stable `EntityID` — look up the
    // `StrokeStore.Run`/`.Arc`/`TextItem`/`pointEntityIds` entry the ref
    // addresses and read its `entityId` field (added alongside `insertId`).
    // `.insert` refs are positional into `DXFDocument.inserts`, which isn't
    // itself EntityStore-backed yet. Nothing below resolves through that
    // field yet — wiring stable-identity selection through is a later phase;
    // this comment exists so that phase doesn't have to rediscover where the
    // data already lives.

    // MARK: - Picking

    /// Returns the closest selectable object within `tolerance` world units of
    /// `wp`, honoring layer/xref visibility. Geometry that belongs to a block
    /// reference resolves to the whole insert (AutoCAD behavior).
    static func hitTest(document: DXFDocument, usePaperSpace: Bool,
                        at wp: CGPoint, tolerance: CGFloat,
                        visibility: VisibilityState) -> EntityRef? {
        let groups = usePaperSpace ? document.paperGroups : document.modelGroups
        var best: (ref: EntityRef, dist: CGFloat)? = nil

        @inline(__always) func consider(_ ref: EntityRef, _ dist: CGFloat) {
            if best == nil || dist < best!.dist { best = (ref, dist) }
        }
        @inline(__always) func wrap(_ insertId: Int32, _ primitive: EntityRef) -> EntityRef {
            insertId >= 0 ? .insert(insertId) : primitive
        }

        for (gi, g) in groups.enumerated() {
            guard visibility.isSelectable(g) else { continue }
            guard g.bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(wp)
            else { continue }
            let gi32 = Int32(gi)
            let pts = g.strokes.points
            let tombstones = GroupTombstoneRegistry.tombstones(for: g)   // Phase 1.6: nil unless this group has been edited

            for (ri, run) in g.strokes.runs.enumerated() {
                if let t = tombstones, t.isDead(.run, Int32(ri)) { continue }
                guard run.bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(wp)
                else { continue }
                let s = Int(run.start), c = Int(run.count)
                var d = CGFloat.infinity
                for j in s..<(s + c - 1) {
                    d = min(d, distanceToSegment(wp, pts[j], pts[j + 1]))
                    if d < tolerance * 0.02 { break }
                }
                if run.closed, c > 2 {
                    d = min(d, distanceToSegment(wp, pts[s + c - 1], pts[s]))
                }
                if d <= tolerance {
                    consider(wrap(run.insertId,
                                  .primitive(group: gi32, store: .run, index: Int32(ri))), d)
                }
            }

            for (ai, arc) in g.strokes.arcs.enumerated() {
                if let t = tombstones, t.isDead(.arc, Int32(ai)) { continue }
                let dc = hypot(wp.x - arc.center.x, wp.y - arc.center.y)
                let d = abs(dc - arc.radius)
                guard d <= tolerance else { continue }
                if !arc.isFullCircle {
                    let ang = atan2(wp.y - arc.center.y, wp.x - arc.center.x) * 180 / .pi
                    guard angleWithinSweep(ang, from: arc.startAngleDeg, to: arc.endAngleDeg)
                    else { continue }
                }
                consider(wrap(arc.insertId,
                              .primitive(group: gi32, store: .arc, index: Int32(ai))), d)
            }

            for (ti, t) in g.texts.enumerated() {
                if let ts = tombstones, ts.isDead(.text, Int32(ti)) { continue }
                guard t.height > 0 else { continue }
                // Un-rotate the pick point around the anchor, then test a
                // generous alignment-aware box.
                let rot = -t.rotationDegrees * .pi / 180
                let dx = wp.x - t.position.x, dy = wp.y - t.position.y
                let lx = dx * CoreGraphics.cos(rot) - dy * CoreGraphics.sin(rot)
                let ly = dx * CoreGraphics.sin(rot) + dy * CoreGraphics.cos(rot)
                let lines = t.text.components(separatedBy: "\n")
                let maxChars = lines.reduce(1) { max($0, $1.count) }
                let w = CGFloat(maxChars) * t.height * 0.75 * max(t.widthFactor, 0.1)
                let lineAdv = t.height * 5 / 3
                let totalH = t.height + CGFloat(lines.count - 1) * lineAdv
                let x0: CGFloat, x1: CGFloat
                switch t.hAlign {
                case 1: x0 = -w / 2; x1 = w / 2
                case 2: x0 = -w; x1 = 0
                default: x0 = 0; x1 = w
                }
                let y0: CGFloat, y1: CGFloat
                switch t.vAlign {
                case 3: y0 = -totalH; y1 = 0
                case 2: y0 = -totalH / 2; y1 = totalH / 2
                default: y0 = -(totalH - t.height); y1 = t.height
                }
                if lx >= x0 - tolerance, lx <= x1 + tolerance,
                   ly >= y0 - tolerance, ly <= y1 + tolerance {
                    consider(wrap(t.insertId,
                                  .primitive(group: gi32, store: .text, index: Int32(ti))),
                             tolerance * 0.9)
                }
            }

            for (pi, p) in g.points.enumerated() {
                if let t = tombstones, t.isDead(.point, Int32(pi)) { continue }
                let d = hypot(wp.x - p.x, wp.y - p.y)
                if d <= tolerance {
                    let ins = pi < g.strokes.pointInsertIds.count
                        ? g.strokes.pointInsertIds[pi] : -1
                    consider(wrap(ins,
                                  .primitive(group: gi32, store: .point, index: Int32(pi))), d)
                }
            }

            for (fi, run) in g.strokes.fillRuns.enumerated() {
                if let t = tombstones, t.isDead(.fillRun, Int32(fi)) { continue }
                guard run.bounds.contains(wp) else { continue }
                if pointInPolygon(wp, points: g.strokes.fillPoints,
                                  start: Int(run.start), count: Int(run.count)) {
                    // Fills lose ties against nearby linework.
                    consider(wrap(run.insertId,
                                  .primitive(group: gi32, store: .fillRun, index: Int32(fi))),
                             tolerance * 0.99)
                }
            }
        }
        return best?.ref
    }

    /// Every selectable object whose geometry lies fully within `rect`
    /// (AutoCAD "Window" selection semantics). Geometry belonging to a block
    /// reference resolves to the whole insert, same as `hitTest`.
    static func boxSelect(document: DXFDocument, usePaperSpace: Bool,
                          rect: CGRect, visibility: VisibilityState) -> Set<EntityRef> {
        let groups = usePaperSpace ? document.paperGroups : document.modelGroups
        var result: Set<EntityRef> = []

        @inline(__always) func wrap(_ insertId: Int32, _ primitive: EntityRef) -> EntityRef {
            insertId >= 0 ? .insert(insertId) : primitive
        }

        for (gi, g) in groups.enumerated() {
            guard visibility.isSelectable(g) else { continue }
            guard g.bounds.intersects(rect) else { continue }
            let gi32 = Int32(gi)
            let tombstones = GroupTombstoneRegistry.tombstones(for: g)   // Phase 1.6: nil unless this group has been edited

            for (ri, run) in g.strokes.runs.enumerated() {
                if let t = tombstones, t.isDead(.run, Int32(ri)) { continue }
                guard rect.contains(run.bounds) else { continue }
                result.insert(wrap(run.insertId, .primitive(group: gi32, store: .run, index: Int32(ri))))
            }
            for (ai, arc) in g.strokes.arcs.enumerated() {
                if let t = tombstones, t.isDead(.arc, Int32(ai)) { continue }
                let bb = arc.isFullCircle
                    ? CGRect(x: arc.center.x - arc.radius, y: arc.center.y - arc.radius,
                            width: arc.radius * 2, height: arc.radius * 2)
                    : arcBoundingBox(center: arc.center, radius: arc.radius,
                                     startDeg: arc.startAngleDeg, endDeg: arc.endAngleDeg)
                guard rect.contains(bb) else { continue }
                result.insert(wrap(arc.insertId, .primitive(group: gi32, store: .arc, index: Int32(ai))))
            }
            for (ti, t) in g.texts.enumerated() {
                if let ts = tombstones, ts.isDead(.text, Int32(ti)) { continue }
                guard t.height > 0, rect.contains(t.position) else { continue }
                result.insert(wrap(t.insertId, .primitive(group: gi32, store: .text, index: Int32(ti))))
            }
            for (pi, p) in g.points.enumerated() {
                if let t = tombstones, t.isDead(.point, Int32(pi)) { continue }
                guard rect.contains(p) else { continue }
                let ins = pi < g.strokes.pointInsertIds.count ? g.strokes.pointInsertIds[pi] : -1
                result.insert(wrap(ins, .primitive(group: gi32, store: .point, index: Int32(pi))))
            }
            for (fi, run) in g.strokes.fillRuns.enumerated() {
                if let t = tombstones, t.isDead(.fillRun, Int32(fi)) { continue }
                guard rect.contains(run.bounds) else { continue }
                result.insert(wrap(run.insertId, .primitive(group: gi32, store: .fillRun, index: Int32(fi))))
            }
        }
        return result
    }

    // MARK: - Stable-identity picking (Phase 1.6/1.8/1.7)
    //
    // `hitTest`/`boxSelect` above return positional `EntityRef`s, which is
    // what the live app's `ContentView`/`DXFCanvasView` are wired for and
    // must keep working unchanged. The `--edit-script` harness (and the live
    // app's Phase 1.7 cutover) needs a stable `EntityID` instead — a
    // positional group/index pair means nothing across an undo, a
    // compaction, or a delta-group append. These resolve internally
    // positional -> EntityID via each primitive's `entityId` field (added in
    // Phase 1.3), and — for `.insert` refs — via `InsertInstance.entityId`
    // (added in Phase 1.7; see DXFModel.swift) — exactly per the plan's
    // cross-cutting note; they are additive wrappers, not replacements for
    // the EntityRef API above.

    /// `EntityID`-returning equivalent of `hitTest`. Resolves BOTH loose
    /// primitives and whole block references (`.insert`) — this file's real
    /// 731MB fixture is dominated by orphan-block/INSERT-driven geometry
    /// (see the Phase 1.7 plan notes), so a selection system that only
    /// resolved loose primitives would silently fail to select the majority
    /// of real content.
    static func hitTestEntityID(document: DXFDocument, usePaperSpace: Bool,
                                at wp: CGPoint, tolerance: CGFloat,
                                visibility: VisibilityState) -> EntityID? {
        guard let ref = hitTest(document: document, usePaperSpace: usePaperSpace, at: wp,
                                tolerance: tolerance, visibility: visibility)
        else { return nil }
        return resolveEntityID(ref, document: document, usePaperSpace: usePaperSpace)
    }

    /// `EntityID`-returning equivalent of `boxSelect`. See `hitTestEntityID`
    /// re: `.insert` resolution.
    static func boxSelectEntityIDs(document: DXFDocument, usePaperSpace: Bool,
                                   rect: CGRect, visibility: VisibilityState) -> Set<EntityID> {
        var result: Set<EntityID> = []
        for ref in boxSelect(document: document, usePaperSpace: usePaperSpace, rect: rect, visibility: visibility) {
            if let id = resolveEntityID(ref, document: document, usePaperSpace: usePaperSpace) {
                result.insert(id)
            }
        }
        return result
    }

    /// Resolves ANY positional `EntityRef` (primitive or whole block
    /// reference) to the stable `EntityID` of the source entity it came
    /// from. Public so callers outside `HitTesting.swift` (e.g.
    /// `ContentView`'s xref-row "select all its entities" and deep-search
    /// "go to hit," both of which build/consume positional `EntityRef`s
    /// directly, not through `hitTest`/`boxSelect`) can promote a positional
    /// ref to `EntityID` without duplicating this switch. Returns nil for an
    /// out-of-range index or a primitive/insert predating Phase 1.3/1.7
    /// (`entityId == -1`, only possible via the OLD `GeometryBuilder` path,
    /// which never populates either field).
    static func resolveEntityID(_ ref: EntityRef, document: DXFDocument,
                                usePaperSpace: Bool) -> EntityID? {
        switch ref {
        case .insert(let idx):
            guard Int(idx) < document.inserts.count else { return nil }
            let raw = document.inserts[Int(idx)].entityId
            return raw >= 0 ? EntityID(raw: raw) : nil
        case .primitive(let g, let store, let idx):
            return entityID(group: g, store: store, index: idx, document: document, usePaperSpace: usePaperSpace)
        }
    }

    /// Reads the stable `entityId` field off whichever primitive array
    /// `(group, store, index)` addresses. Returns nil for an out-of-range
    /// index or a primitive predating Phase 1.3 (`entityId == -1`, only
    /// possible via the OLD `GeometryBuilder` path, which never populates it).
    private static func entityID(group: Int32, store: PrimitiveStore, index: Int32,
                                 document: DXFDocument, usePaperSpace: Bool) -> EntityID? {
        let groups = usePaperSpace ? document.paperGroups : document.modelGroups
        guard Int(group) < groups.count else { return nil }
        let g = groups[Int(group)]
        let i = Int(index)
        let raw: Int32
        switch store {
        case .run: guard i < g.strokes.runs.count else { return nil }; raw = g.strokes.runs[i].entityId
        case .arc: guard i < g.strokes.arcs.count else { return nil }; raw = g.strokes.arcs[i].entityId
        case .text: guard i < g.texts.count else { return nil }; raw = g.texts[i].entityId
        case .point: guard i < g.strokes.pointEntityIds.count else { return nil }; raw = g.strokes.pointEntityIds[i]
        case .fillRun: guard i < g.strokes.fillRuns.count else { return nil }; raw = g.strokes.fillRuns[i].entityId
        }
        return raw >= 0 ? EntityID(raw: raw) : nil
    }

    // MARK: - Properties

    static func properties(for ref: EntityRef, document doc: DXFDocument,
                           usePaperSpace: Bool,
                           format: MeasureFormat = MeasureFormat(),
                           store: EntityStore? = nil) -> [EntityProperty] {
        var props: [EntityProperty] = []
        func add(_ n: String, _ v: String) { props.append(EntityProperty(name: n, value: v)) }
        func layerName(_ id: Int32) -> String {
            Int(id) < doc.layers.count ? doc.layers[Int(id)].name : "?"
        }
        // Length/coordinate values honor the chosen units; L() for lengths,
        // A() for angles (degrees).
        func L(_ v: CGFloat) -> String { format.length(v) }
        func A(_ v: Double) -> String { format.angle(v) }

        switch ref {
        case .insert(let id):
            guard Int(id) < doc.inserts.count else { return [] }
            let ins = doc.inserts[Int(id)]
            add("Type", "Block Reference")
            // `InsertInstance.name` is the REAL block-definition name (that's
            // what resolves the geometry, and it must stay that way — see
            // `InsertPayload.displayNameId`). But the per-instance COSMETIC
            // display-name override lives only in the EntityStore payload, so
            // reading `ins.name` alone made Data Import's `blockName` column
            // silently invisible: an import would correctly report "Updated
            // 739 name(s)" and really write every override, yet clicking any
            // of those objects still showed the original name, because this
            // row never consulted the override. `BlockEditor.displayName` is
            // the one place both are reconciled, so use it whenever a live
            // store is available and fall back to the render-side name
            // otherwise (the legacy GeometryBuilder path has no store).
            if let store, ins.entityId >= 0,
               let shown = BlockEditor.displayName(of: EntityID(raw: ins.entityId), in: store) {
                add("Name", shown)
                // When an override is in effect, surface the underlying block
                // it still DRAWS too — otherwise a renamed object gives the
                // user no way to see which definition it actually is.
                if shown != ins.name { add("Block", ins.name) }
            } else {
                add("Name", ins.name)
            }
            add("Layer", layerName(ins.layerId))
            if ins.xrefId >= 0, Int(ins.xrefId) < doc.xrefs.count {
                add("Xref", doc.xrefs[Int(ins.xrefId)].blockName)
            }
            add("Position X", L(ins.position.x))
            add("Position Y", L(ins.position.y))
            add("Scale X", fmt(ins.scaleX))
            add("Scale Y", fmt(ins.scaleY))
            add("Rotation", A(ins.rotationDegrees))
            // Attribute (ATTRIB) tag/value pairs, when a live EntityStore is
            // available to look them up — INSERT instances built off the
            // legacy GeometryBuilder path (`entityId == -1`) have no stable
            // id to resolve, so they simply show no attribute rows (same as
            // today). Rows are named directly after the tag (e.g. "PART_NUM")
            // so `mergedProperties`' existing string-keyed merge (below)
            // handles multi-selection intersection/"Various" semantics for
            // free — no separate merge logic needed for attributes.
            if let store, ins.entityId >= 0 {
                let attrs = BlockEditor.attributes(of: EntityID(raw: ins.entityId), in: store)
                for attr in attrs { add(attr.tag, attr.value) }
            }

        case .primitive(let gi, let store, let index):
            let groups = usePaperSpace ? doc.paperGroups : doc.modelGroups
            guard Int(gi) < groups.count else { return [] }
            let g = groups[Int(gi)]
            let i = Int(index)

            func addCommon(kind: EntityKind) {
                add("Type", kind.label)
                add("Layer", layerName(Int32(g.layerId)))
                add("Color", describe(g.color))
                if g.linetypeId < doc.linetypes.count {
                    add("Linetype", doc.linetypes[g.linetypeId].name)
                }
                if g.xrefId >= 0, g.xrefId < doc.xrefs.count {
                    add("Xref", doc.xrefs[g.xrefId].blockName)
                }
            }

            switch store {
            case .run:
                guard i < g.strokes.runs.count else { return [] }
                let run = g.strokes.runs[i]
                addCommon(kind: run.kind)
                let s = Int(run.start), c = Int(run.count)
                let pts = g.strokes.points
                if run.kind == .line && c == 2 {
                    let a = pts[s], b = pts[s + 1]
                    add("Start X", L(a.x)); add("Start Y", L(a.y))
                    add("End X", L(b.x)); add("End Y", L(b.y))
                    add("Delta X", L(b.x - a.x)); add("Delta Y", L(b.y - a.y))
                    add("Length", L(hypot(b.x - a.x, b.y - a.y)))
                    add("Angle", A(atan2(b.y - a.y, b.x - a.x) * 180 / .pi))
                } else {
                    add("Closed", run.closed ? "Yes" : "No")
                    add("Points", "\(c)")
                    var len: CGFloat = 0
                    for j in s..<(s + c - 1) {
                        len += hypot(pts[j + 1].x - pts[j].x, pts[j + 1].y - pts[j].y)
                    }
                    if run.closed {
                        len += hypot(pts[s].x - pts[s + c - 1].x, pts[s].y - pts[s + c - 1].y)
                    }
                    add("Length", L(len))
                    if run.closed {
                        add("Area", format.area(abs(shoelaceArea(pts, start: s, count: c))))
                    }
                }

            case .arc:
                guard i < g.strokes.arcs.count else { return [] }
                let arc = g.strokes.arcs[i]
                addCommon(kind: arc.isFullCircle ? .circle : .arc)
                add("Center X", L(arc.center.x))
                add("Center Y", L(arc.center.y))
                add("Radius", L(arc.radius))
                add("Diameter", L(arc.radius * 2))
                if arc.isFullCircle {
                    add("Circumference", L(2 * .pi * arc.radius))
                    add("Area", format.area(.pi * arc.radius * arc.radius))
                } else {
                    var sweep = (arc.endAngleDeg - arc.startAngleDeg)
                        .truncatingRemainder(dividingBy: 360)
                    if sweep <= 0 { sweep += 360 }
                    add("Start Angle", A(arc.startAngleDeg))
                    add("End Angle", A(arc.endAngleDeg))
                    add("Arc Length", L(arc.radius * CGFloat(sweep) * .pi / 180))
                }

            case .text:
                guard i < g.texts.count else { return [] }
                let t = g.texts[i]
                addCommon(kind: t.kind)
                add("Contents", t.text.replacingOccurrences(of: "\n", with: " ⏎ "))
                add("Height", L(t.height))
                if abs(t.widthFactor - 1) > 0.001 { add("Width Factor", fmt(t.widthFactor)) }
                add("Rotation", A(t.rotationDegrees))
                add("Position X", L(t.position.x))
                add("Position Y", L(t.position.y))

            case .point:
                guard i < g.points.count else { return [] }
                addCommon(kind: .point)
                add("Position X", L(g.points[i].x))
                add("Position Y", L(g.points[i].y))

            case .fillRun:
                guard i < g.strokes.fillRuns.count else { return [] }
                let run = g.strokes.fillRuns[i]
                addCommon(kind: run.kind)
                add("Points", "\(run.count)")
                add("Area", format.area(abs(shoelaceArea(g.strokes.fillPoints,
                                                 start: Int(run.start), count: Int(run.count)))))
            }
        }
        return props
    }

    /// AutoCAD-style merge: only properties every selected object has are
    /// shown; differing values become "Various/Multiple".
    static func mergedProperties(for refs: [EntityRef], document: DXFDocument,
                                 usePaperSpace: Bool,
                                 format: MeasureFormat = MeasureFormat(),
                                 store: EntityStore? = nil) -> [EntityProperty] {
        guard let first = refs.first else { return [] }
        let firstProps = properties(for: first, document: document,
                                    usePaperSpace: usePaperSpace, format: format, store: store)
        guard refs.count > 1 else { return firstProps }

        var merged: [String: String?] = [:]   // nil value = varies
        var presentCount: [String: Int] = [:]
        for ref in refs {
            for p in properties(for: ref, document: document,
                                usePaperSpace: usePaperSpace, format: format, store: store) {
                presentCount[p.name, default: 0] += 1
                if let existing = merged[p.name] {
                    if existing != p.value { merged[p.name] = String?.none }
                } else {
                    merged[p.name] = p.value
                }
            }
        }
        // Keep the first entity's ordering; keep only universally shared names.
        return firstProps.compactMap { p in
            guard presentCount[p.name] == refs.count else { return nil }
            let v = merged[p.name] ?? nil
            return EntityProperty(name: p.name, value: v ?? EntityProperty.variesValue)
        }
    }

    // MARK: - Helpers

    static func describe(_ color: ResolvedColor) -> String {
        switch color {
        case .foreground: return "White/Black"
        case .rgb(let v): return String(format: "#%06X", v)
        }
    }

    private static func fmt(_ v: CGFloat) -> String { fmt(Double(v)) }
    private static func fmt(_ v: Double) -> String {
        if !v.isFinite { return "—" }
        let a = abs(v)
        if a >= 10000 { return String(format: "%.1f", v) }
        if a >= 1 { return String(format: "%.3f", v) }
        return String(format: "%.4f", v)
    }

    private static func normalizeDeg(_ d: Double) -> Double {
        var v = d.truncatingRemainder(dividingBy: 360)
        if v < 0 { v += 360 }
        return v
    }

    static func angleWithinSweep(_ angle: Double, from start: Double, to end: Double) -> Bool {
        var sweep = (end - start).truncatingRemainder(dividingBy: 360)
        if sweep <= 0 { sweep += 360 }
        var rel = (angle - start).truncatingRemainder(dividingBy: 360)
        if rel < 0 { rel += 360 }
        return rel <= sweep
    }

    /// Exact axis-aligned bounding box of a (non-full-circle) arc — its two
    /// endpoints plus whichever of the 4 cardinal points (0/90/180/270°) fall
    /// within the swept range. Tighter than the full parent-circle bbox, so
    /// short arcs stay reasonably window-selectable.
    static func arcBoundingBox(center c: CGPoint, radius r: CGFloat,
                               startDeg: Double, endDeg: Double) -> CGRect {
        func point(_ deg: Double) -> CGPoint {
            let rad = deg * .pi / 180
            return CGPoint(x: c.x + r * CoreGraphics.cos(rad), y: c.y + r * CoreGraphics.sin(rad))
        }
        var pts = [point(startDeg), point(endDeg)]
        for axisDeg in [0.0, 90.0, 180.0, 270.0]
        where angleWithinSweep(axisDeg, from: startDeg, to: endDeg) {
            pts.append(point(axisDeg))
        }
        var box = CGRect(origin: pts[0], size: .zero)
        for p in pts.dropFirst() { box = box.union(CGRect(origin: p, size: .zero)) }
        return box
    }

    private static func distanceToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let abx = b.x - a.x, aby = b.y - a.y
        let len2 = abx * abx + aby * aby
        guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * abx + (p.y - a.y) * aby) / len2))
        return hypot(p.x - (a.x + t * abx), p.y - (a.y + t * aby))
    }

    private static func pointInPolygon(_ p: CGPoint, points: [CGPoint],
                                       start: Int, count: Int) -> Bool {
        guard count >= 3 else { return false }
        var inside = false
        var j = start + count - 1
        for i in start..<(start + count) {
            let pi = points[i], pj = points[j]
            if (pi.y > p.y) != (pj.y > p.y),
               p.x < (pj.x - pi.x) * (p.y - pi.y) / (pj.y - pi.y) + pi.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    private static func shoelaceArea(_ pts: [CGPoint], start: Int, count: Int) -> CGFloat {
        guard count >= 3 else { return 0 }
        var sum: CGFloat = 0
        var j = start + count - 1
        for i in start..<(start + count) {
            sum += (pts[j].x + pts[i].x) * (pts[j].y - pts[i].y)
            j = i
        }
        return sum / 2
    }
}
