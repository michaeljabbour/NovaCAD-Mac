import Foundation
import CADCore
import CoreGraphics

/// One navigable search result.
struct SearchHit: Identifiable, Equatable {
    let id: Int
    let label: String          // matched text / block name
    let sublabel: String       // kind · layer
    let position: CGPoint      // world coordinates
    let screenHeightHint: CGFloat  // world height of the object (0 = unknown)
    let ref: EntityRef
    let isPaper: Bool
}

/// In-memory text index over everything the drawing shows — text entities
/// (including resolved xref content, which is merged into the document by
/// PackageLoader) and block-reference names. Built once per load; queried
/// per keystroke with case-insensitive substring matching.
final class SearchIndex {

    private struct Entry {
        let lower: String
        let display: String
        let sublabel: String
        let position: CGPoint
        let heightHint: CGFloat
        let ref: EntityRef
        let isPaper: Bool
    }

    private var entries: [Entry] = []
    let documentID: ObjectIdentifier

    /// `store`, when supplied, lets block references be indexed under their
    /// per-instance COSMETIC display name (`InsertPayload.displayNameId` — set
    /// by Data Import's `blockName` column, `BlockEditor.setDisplayName`, or
    /// the Properties panel) as well as the real block-definition name. Without
    /// it, an object the user deliberately renamed (e.g. 739 stations relabeled
    /// to their true station names via a CSV import) stayed unfindable by that
    /// new name — the index only ever saw the underlying definition name.
    /// Optional so callers with no live `EntityStore` (the legacy
    /// `GeometryBuilder`/`PackageLoader.load` path) keep working unchanged.
    init(document: DXFDocument, store: EntityStore? = nil) {
        documentID = ObjectIdentifier(document)

        func layerName(_ id: Int) -> String {
            id < document.layers.count ? document.layers[id].name : "?"
        }

        func searchTerms(_ name: String) -> String {
            [name, LayerDisplayName.englishAlias(for: name) ?? ""].joined(separator: "\n").lowercased()
        }

        func indexGroups(_ groups: [RenderGroup], isPaper: Bool) {
            for (gi, g) in groups.enumerated() {
                for (ti, t) in g.texts.enumerated() {
                    let display = t.text.replacingOccurrences(of: "\n", with: " ")
                        .trimmingCharacters(in: .whitespaces)
                    guard !display.isEmpty else { continue }
                    let ref: EntityRef = t.insertId >= 0
                        ? .insert(t.insertId)
                        : .primitive(group: Int32(gi), store: .text, index: Int32(ti))
                    entries.append(Entry(
                        lower: searchTerms(display),
                        display: display,
                        sublabel: "\(t.kind.label) · \(layerName(g.layerId))",
                        position: t.position,
                        heightHint: t.height,
                        ref: ref, isPaper: isPaper))
                }
            }
        }
        indexGroups(document.modelGroups, isPaper: false)
        indexGroups(document.paperGroups, isPaper: true)

        // Block references by name — finding equipment by its block name.
        // Indexed under BOTH the real block-definition name and (when it
        // differs) the cosmetic display-name override, so a renamed object is
        // findable either way — by its true station name (what the user now
        // expects to search for) or by its original block name (what someone
        // else on the team, or an older export, might still call it).
        for (i, ins) in document.inserts.enumerated() {
            let display = ins.name.trimmingCharacters(in: .whitespaces)
            var shown: String? = nil
            if let store, ins.entityId >= 0 {
                shown = BlockEditor.displayName(of: EntityID(raw: ins.entityId), in: store)?
                    .trimmingCharacters(in: .whitespaces)
            }
            let sublabel = "Block Reference · \(layerName(Int(ins.layerId)))"
            if !display.isEmpty, !display.hasPrefix("*") {
                entries.append(Entry(
                    lower: searchTerms(display),
                    display: display,
                    sublabel: sublabel,
                    position: ins.position,
                    heightHint: 0,
                    ref: .insert(Int32(i)),
                    isPaper: i >= document.modelInsertCount))
            }
            if let shown, !shown.isEmpty, shown != display {
                entries.append(Entry(
                    lower: searchTerms(shown),
                    display: shown,
                    sublabel: sublabel,
                    position: ins.position,
                    heightHint: 0,
                    ref: .insert(Int32(i)),
                    isPaper: i >= document.modelInsertCount))
            }
        }
    }

    var count: Int { entries.count }

    /// Case-insensitive substring search, model space first, capped.
    func search(_ query: String, limit: Int = 500) -> [SearchHit] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return [] }
        var hits: [SearchHit] = []
        hits.reserveCapacity(min(limit, 64))
        var id = 0
        for e in entries {
            guard e.lower.contains(q) else { continue }
            hits.append(SearchHit(id: id, label: e.display, sublabel: e.sublabel,
                                  position: e.position, screenHeightHint: e.heightHint,
                                  ref: e.ref, isPaper: e.isPaper))
            id += 1
            if hits.count >= limit { break }
        }
        // Exact matches first, then prefix matches, then the rest.
        return hits.sorted { a, b in
            let ae = a.label.lowercased() == q, be = b.label.lowercased() == q
            if ae != be { return ae }
            let ap = a.label.lowercased().hasPrefix(q), bp = b.label.lowercased().hasPrefix(q)
            if ap != bp { return ap }
            return a.id < b.id
        }
    }
}

// MARK: - Measurement

/// Interactive measurement state (distance / area), drawn as a screen-space
/// overlay by the canvas.
struct MeasureState: Equatable {
    enum Mode: Equatable {
        case select, distance, area, radius, angle
    }
    var mode: Mode = .select
    /// Clicked points in world coordinates.
    var points: [CGPoint] = []
    /// Live cursor position while measuring (world coordinates).
    var hover: CGPoint? = nil
    /// Snap result for the current cursor position — snapped to endpoint,
    /// midpoint, center, intersection, perpendicular, or tangent of visible
    /// geometry. Snapped points produce cleaner, more accurate measurements.
    var snap: SnapResult? = nil
    /// Area mode: measurement finished (polygon closed).
    var closed = false
    /// Radius mode: the picked circle/arc (center, radius, sweep) if any.
    var pickedArc: (center: CGPoint, radius: CGFloat, startDeg: Double, endDeg: Double, full: Bool)? = nil

    var isActive: Bool { mode != .select }

    static func == (l: MeasureState, r: MeasureState) -> Bool {
        l.mode == r.mode && l.points == r.points && l.hover == r.hover && l.closed == r.closed
            && arcEq(l.pickedArc, r.pickedArc)
    }
    private static func arcEq(_ a: (center: CGPoint, radius: CGFloat, startDeg: Double, endDeg: Double, full: Bool)?,
                              _ b: (center: CGPoint, radius: CGFloat, startDeg: Double, endDeg: Double, full: Bool)?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case let (x?, y?): return x.center == y.center && x.radius == y.radius && x.full == y.full
        default: return false
        }
    }

    mutating func addPoint(_ p: CGPoint) {
        switch mode {
        case .select, .radius: break   // radius picks via the host's hit-test
        case .distance:
            if points.count >= 2 { points = [] }
            points.append(p)
        case .area:
            if closed { points = []; closed = false }
            points.append(p)
        case .angle:
            if points.count >= 3 { points = [] }
            points.append(p)
        }
    }

    /// Distance/area values against the given points array + optional hover.
    static func polygonArea(_ pts: [CGPoint]) -> CGFloat {
        guard pts.count >= 3 else { return 0 }
        var sum: CGFloat = 0
        var j = pts.count - 1
        for i in 0..<pts.count {
            sum += (pts[j].x + pts[i].x) * (pts[j].y - pts[i].y)
            j = i
        }
        return abs(sum / 2)
    }

    static func pathLength(_ pts: [CGPoint], closed: Bool) -> CGFloat {
        guard pts.count >= 2 else { return 0 }
        var len: CGFloat = 0
        for i in 0..<(pts.count - 1) {
            len += hypot(pts[i + 1].x - pts[i].x, pts[i + 1].y - pts[i].y)
        }
        if closed {
            len += hypot(pts[0].x - pts.last!.x, pts[0].y - pts.last!.y)
        }
        return len
    }
}

/// Transient halo shown over a search result after re-centering.
struct SearchHalo: Equatable {
    var position: CGPoint      // world
    var worldRadius: CGFloat   // ring size in world units (0 = fixed screen size)
    var until: Date
}
