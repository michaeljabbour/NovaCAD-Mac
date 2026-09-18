import Foundation
import CoreGraphics
import AppKit
import CADCore

// MARK: - Cross-drawing Copy/Paste: the wire format
//
// The transport is `NSPasteboard` (see `CrossDocumentPaste.swift`'s own
// header comment for why — it's the one mechanism that works uniformly
// whether the destination is another tab in the SAME window or a tab in a
// DIFFERENT window, with no live cross-session registry needed). This file
// defines the self-contained, source-document-independent payload that gets
// JSON-encoded onto the pasteboard: every copied entity's own geometry/
// properties PLUS, by NAME (not by the source document's own numeric ids —
// see `PastedLayer.name`'s doc comment), every layer/linetype/block
// definition it depends on, so `CrossDocumentPaste.commitPaste` can
// reconstruct it against an ARBITRARY destination document that may not
// share a single one of the source's layer/linetype/block tables.
enum PasteboardSnapshot {
    /// Custom UTI — this app's first (see `XrefAttach`'s research phase:
    /// every prior `NSPasteboard` use in this codebase was plain
    /// `.string`).
    static let pasteboardType = NSPasteboard.PasteboardType("com.novacad.entities")

    /// One payload value, tagged by entity type — a plain-data mirror of
    /// `EntityPayloadCopy` with every string-table reference (`stringId`/
    /// `blockNameId`/etc.) resolved to the literal `String` it names,
    /// rather than an index into the SOURCE store's `StringTable` (which is
    /// meaningless once decoded in a different process/against a different
    /// document — the exact class of bug this session's `appendCopy` fix
    /// addressed for the xref-attach path; this format sidesteps it
    /// entirely for paste by never carrying a raw string-table index across
    /// the pasteboard boundary at all).
    enum PayloadSnapshot: Codable {
        case line(a: Vec3, b: Vec3)
        case point(p: Vec3)
        case circle(center: Vec3, radius: Double, extrusionZ: Double)
        case arc(center: Vec3, radius: Double, startAngleDeg: Double, endAngleDeg: Double, extrusionZ: Double)
        case ellipse(center: Vec3, majorAxisEndpoint: Vec3, ratio: Double, startParam: Double, endParam: Double)
        case polyline(vertices: [Vec3], bulges: [Double], closed: Bool, constantWidth: Double,
                     elevation: Double, is3D: Bool)
        case spline(degree: Int32, control: [Vec3], knots: [Double], weights: [Double], closed: Bool)
        /// `tag`/`prompt` are only meaningful for ATTRIB/ATTDEF (empty
        /// string for a plain TEXT) — carried on every `.text` case rather
        /// than a separate ATTRIB-only case, matching `TextPayload`'s own
        /// "one shape, tag/prompt default empty" convention.
        case text(position: Vec3, alignPosition: Vec3, height: Double, rotationDeg: Double, widthFactor: Double,
                  obliqueDeg: Double, value: String, styleName: String, hAlign: Int16, vAlign: Int16,
                  isBackwards: Bool, isUpsideDown: Bool, tag: String, prompt: String)
        case mtext(insertion: Vec3, height: Double, refWidth: Double, rotationDeg: Double, attachPoint: Int16,
                  value: String, styleName: String)
        /// `blockName` is the SOURCE document's own name for the block this
        /// INSERT references — `CrossDocumentPaste` resolves/renames it
        /// into the destination via `PastedSelection.blocks` (below),
        /// exactly like `XrefAttach.commitAttach`'s `remapBlockName`.
        case insert(blockName: String, position: Vec3, scale: Vec3, rotationDeg: Double,
                   cols: Int32, rows: Int32, colSpacing: Double, rowSpacing: Double)
        case hatch(patternName: String, isSolid: Bool, angle: Double, scale: Double, origin: Vec3,
                  loops: [[Vec3]], associative: Bool)
        case unsupported   // image/viewport/dimension/unknown — see PastedEntity.unsupportedTypeName
    }

    /// One copied entity, plus its own ATTRIB children if it's an INSERT
    /// (`children`) — capturing this at COPY time (rather than resolving
    /// ATTRIBs again at paste time via `store.children(of:)`) is what fixes
    /// the gap this session's research flagged: neither `Transaction
    /// .copyTransformed` (same-document COPY) nor a bare `appendCopy` call
    /// re-parents an INSERT's ATTRIBs on their own; capturing them here
    /// means `CrossDocumentPaste` only has to re-parent onto the NEW
    /// INSERT's id, never re-discover which entities belong to it.
    struct PastedEntity: Codable {
        var type: DXFEntityType
        var layerName: String
        var aci: Int16
        var trueColor: UInt32
        var linetypeName: String?   // nil = BYLAYER; "BYBLOCK" sentinel handled by CrossDocumentPaste
        var lineweight: Int16
        var ltScale: Float
        var payload: PayloadSnapshot
        /// ATTRIB children, present only when `type == .insert`. Each is a
        /// `PastedEntity` in its own right (so a nested ATTRIB's own layer/
        /// linetype dependencies are captured identically to a top-level
        /// entity's) — always `type == .attrib`, `payload == .text`.
        var children: [PastedEntity] = []
    }

    /// One dependency table entry, captured by NAME — see this enum's own
    /// header comment for why names (not the source document's numeric
    /// ids) are the right cross-document join key: the destination almost
    /// certainly has a DIFFERENT numbering for "layer 3," but "a layer named
    /// PIPING" means the same thing in any DXF file.
    struct PastedLayer: Codable {
        var name: String
        var colorIsForeground: Bool
        var colorRGB: UInt32
        var linetypeName: String
        var isOffByDefault: Bool
        var isFrozen: Bool
    }
    struct PastedLinetype: Codable {
        var name: String
        var dashes: [Double]
    }
    /// A block definition reachable from the copied selection's own INSERTs
    /// (recursively — an INSERT nested inside a copied block's definition
    /// pulls in ITS block too), captured content-first so
    /// `CrossDocumentPaste` can register+transplant it into the destination
    /// exactly once regardless of how many copied INSERTs reference it.
    struct PastedBlock: Codable {
        var name: String
        var entities: [PastedEntity]
    }

    /// The full pasteboard payload for one Copy — self-contained: nothing
    /// in here is meaningful only in the context of the source
    /// `EntityStore`/`EditableParsedDocument` that produced it.
    struct Snapshot: Codable {
        var entities: [PastedEntity]
        var layers: [PastedLayer]
        var linetypes: [PastedLinetype]
        var blocks: [PastedBlock]
        /// World-space bounding box (union) of every top-level copied
        /// entity, in the SOURCE drawing's own coordinates — `CrossDocumentPaste`
        /// uses this to compute the translation for "paste at a clicked
        /// point" (offset from this box's center, or any other reference
        /// point a future refinement might choose) without needing to
        /// re-walk `entities` at paste time.
        var sourceBoundsMinX: Double
        var sourceBoundsMinY: Double
        var sourceBoundsMaxX: Double
        var sourceBoundsMaxY: Double
    }

    static func write(_ snapshot: Snapshot, to pasteboard: NSPasteboard) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        pasteboard.clearContents()
        pasteboard.setData(data, forType: pasteboardType)
    }

    static func read(from pasteboard: NSPasteboard) -> Snapshot? {
        guard let data = pasteboard.data(forType: pasteboardType) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    // MARK: - Capture (Copy)

    /// Builds a `Snapshot` from `ids` (a live selection) against `parsed` —
    /// the ONLY read this feature performs against the source document;
    /// nothing here mutates `parsed`/its `store` in any way. INSERTs bring
    /// along their ATTRIB children (`store.children(of:)`) and, recursively,
    /// every block definition reachable from any copied/nested INSERT
    /// (`collectBlock`) — so a copy of "one INSERT of a block that itself
    /// contains another INSERT of a different block" captures both block
    /// definitions, not just the outer one.
    static func capture(ids: Set<EntityID>, from parsed: EditableParsedDocument) -> Snapshot? {
        let store = parsed.store
        var topLevel: [PastedEntity] = []
        var bounds = CGRect.null
        var neededBlockNames = Set<String>()

        for id in ids {
            guard let h = store.header(id), !h.flags.contains(.deleted) else { continue }
            // A copied ATTRIB reached only because its OWNING INSERT is
            // ALSO in `ids` is captured as that INSERT's `children`, not as
            // its own top-level row — but an ATTRIB selected on its OWN
            // (its parent INSERT NOT in `ids`) still copies as a standalone
            // top-level TEXT-shaped entity (matching how the Properties
            // panel already treats a lone ATTRIB pick), so no special-case
            // skip is needed here: every non-deleted id in `ids` becomes
            // exactly one top-level `PastedEntity`.
            let entity = snapshotEntity(id, header: h, store: store, parsed: parsed,
                                        neededBlockNames: &neededBlockNames)
            topLevel.append(entity)
            bounds = bounds.union(store.bounds(id))
        }
        guard !topLevel.isEmpty else { return nil }
        if bounds.isNull { bounds = .zero }

        var blocks: [PastedBlock] = []
        var visitedBlocks = Set<String>()
        var queue = Array(neededBlockNames)
        while let name = queue.popLast() {
            guard !visitedBlocks.contains(name) else { continue }
            visitedBlocks.insert(name)
            guard let def = parsed.blocks[name] else { continue }
            var nested = Set<String>()
            var entities: [PastedEntity] = []
            for i in Int(def.entityStart)..<Int(def.entityStart + def.entityCount) {
                let childId = EntityID(raw: Int32(i))
                guard let ch = store.header(childId), !ch.flags.contains(.deleted) else { continue }
                entities.append(snapshotEntity(childId, header: ch, store: store, parsed: parsed,
                                              neededBlockNames: &nested))
            }
            blocks.append(PastedBlock(name: name, entities: entities))
            queue.append(contentsOf: nested)
        }

        let layers = collectLayers(usedIn: topLevel, and: blocks, parsed: parsed)
        let linetypes = collectLinetypes(usedIn: topLevel, and: blocks, parsed: parsed)

        return Snapshot(entities: topLevel, layers: layers, linetypes: linetypes, blocks: blocks,
                        sourceBoundsMinX: bounds.minX, sourceBoundsMinY: bounds.minY,
                        sourceBoundsMaxX: bounds.maxX, sourceBoundsMaxY: bounds.maxY)
    }

    private static func snapshotEntity(_ id: EntityID, header h: EntityHeader, store: EntityStore,
                                       parsed: EditableParsedDocument,
                                       neededBlockNames: inout Set<String>) -> PastedEntity {
        let layerName = h.layerId >= 0 && Int(h.layerId) < parsed.layers.count
            ? parsed.layers[Int(h.layerId)].name : "0"
        let linetypeName: String? = {
            guard h.linetypeId >= 0 else { return nil }   // BYLAYER
            if h.linetypeId == -2 { return "BYBLOCK" }
            guard Int(h.linetypeId) < parsed.linetypes.count else { return nil }
            return parsed.linetypes[Int(h.linetypeId)].name
        }()

        let payload = snapshotPayload(header: h, store: store, neededBlockNames: &neededBlockNames)

        var children: [PastedEntity] = []
        if h.type == .insert {
            for childId in store.children(of: id) {
                guard let ch = store.header(childId), !ch.flags.contains(.deleted) else { continue }
                children.append(snapshotEntity(childId, header: ch, store: store, parsed: parsed,
                                              neededBlockNames: &neededBlockNames))
            }
        }

        return PastedEntity(type: h.type, layerName: layerName, aci: h.aci, trueColor: h.trueColor,
                            linetypeName: linetypeName, lineweight: h.lineweight, ltScale: h.ltScale,
                            payload: payload, children: children)
    }

    private static func snapshotPayload(header h: EntityHeader, store: EntityStore,
                                        neededBlockNames: inout Set<String>) -> PayloadSnapshot {
        guard h.payload >= 0 else { return .unsupported }
        let i = Int(h.payload)
        switch h.type {
        case .line:
            let p = store.lines[i]; return .line(a: p.a, b: p.b)
        case .point:
            return .point(p: store.points[i].p)
        case .circle:
            let p = store.circles[i]
            return .circle(center: p.center, radius: p.radius, extrusionZ: p.extrusionZ)
        case .arc:
            let p = store.arcs[i]
            return .arc(center: p.center, radius: p.radius, startAngleDeg: p.startAngleDeg,
                       endAngleDeg: p.endAngleDeg, extrusionZ: p.extrusionZ)
        case .ellipse:
            let p = store.ellipses[i]
            return .ellipse(center: p.center, majorAxisEndpoint: p.majorAxisEndpoint, ratio: p.ratio,
                           startParam: p.startParam, endParam: p.endParam)
        case .lwpolyline, .polyline2d, .polyline3d, .solid, .trace, .face3d, .leader:
            let p = store.polylines[i]
            let verts = Array(store.vertexArena[Int(p.vertsStart)..<Int(p.vertsStart + p.vertsCount)])
            let bulges = Array(store.scalarArena[Int(p.bulgesStart)..<Int(p.bulgesStart) + Int(p.vertsCount)])
            return .polyline(vertices: verts, bulges: bulges, closed: p.closed,
                            constantWidth: p.constantWidth, elevation: p.elevation, is3D: p.is3D)
        case .spline:
            let p = store.splines[i]
            let control = Array(store.vertexArena[Int(p.controlStart)..<Int(p.controlStart + p.controlCount)])
            let knots = Array(store.scalarArena[Int(p.knotStart)..<Int(p.knotStart + p.knotCount)])
            let weights = Array(store.scalarArena[Int(p.weightStart)..<Int(p.weightStart + p.weightCount)])
            return .spline(degree: p.degree, control: control, knots: knots, weights: weights, closed: p.closed)
        case .text, .attrib, .attdef:
            let p = store.texts[i]
            return .text(position: p.position, alignPosition: p.alignPosition, height: p.height,
                        rotationDeg: p.rotationDeg, widthFactor: p.widthFactor, obliqueDeg: p.obliqueDeg,
                        value: store.strings.string(for: p.stringId),
                        styleName: p.styleNameId >= 0 ? store.strings.string(for: p.styleNameId) : "",
                        hAlign: p.hAlign, vAlign: p.vAlign, isBackwards: p.isBackwards,
                        isUpsideDown: p.isUpsideDown,
                        tag: p.tagStringId >= 0 ? store.strings.string(for: p.tagStringId) : "",
                        prompt: p.promptStringId >= 0 ? store.strings.string(for: p.promptStringId) : "")
        case .mtext:
            let p = store.mtexts[i]
            return .mtext(insertion: p.insertion, height: p.height, refWidth: p.refWidth,
                         rotationDeg: p.rotationDeg, attachPoint: p.attachPoint,
                         value: store.strings.string(for: p.stringId),
                         styleName: p.styleNameId >= 0 ? store.strings.string(for: p.styleNameId) : "")
        case .insert:
            let p = store.inserts[i]
            let name = store.strings.string(for: p.blockNameId)
            neededBlockNames.insert(name)
            return .insert(blockName: name, position: p.position, scale: p.scale,
                          rotationDeg: p.rotationDeg, cols: p.cols, rows: p.rows,
                          colSpacing: p.colSpacing, rowSpacing: p.rowSpacing)
        case .hatch:
            let p = store.hatches[i]
            var loops: [[Vec3]] = []
            for r in Int(p.loopRangeStart)..<Int(p.loopRangeStart + p.loopRangeCount) {
                let range = store.hatchLoopRanges[r]
                loops.append(Array(store.vertexArena[Int(range.vertStart)..<Int(range.vertStart + range.vertCount)]))
            }
            let patternName = p.patternNameId >= 0 ? store.strings.string(for: p.patternNameId) : ""
            return .hatch(patternName: patternName, isSolid: p.isSolid, angle: p.angle, scale: p.scale,
                        origin: p.origin, loops: loops, associative: p.associative)
        default:
            return .unsupported
        }
    }

    private static func collectLayers(usedIn entities: [PastedEntity], and blocks: [PastedBlock],
                                      parsed: EditableParsedDocument) -> [PastedLayer] {
        var names = Set<String>()
        func walk(_ e: PastedEntity) {
            names.insert(e.layerName)
            for c in e.children { walk(c) }
        }
        entities.forEach(walk)
        blocks.forEach { $0.entities.forEach(walk) }

        return names.compactMap { name -> PastedLayer? in
            guard let id = parsed.layerIdByName[name], Int(id) < parsed.layers.count else { return nil }
            let layer = parsed.layers[Int(id)]
            let linetypeName = Int(layer.linetypeId) < parsed.linetypes.count && layer.linetypeId >= 0
                ? parsed.linetypes[Int(layer.linetypeId)].name : "CONTINUOUS"
            let isForeground: Bool
            let rgb: UInt32
            switch layer.color {
            case .foreground: isForeground = true; rgb = 0
            case .rgb(let v): isForeground = false; rgb = v
            }
            return PastedLayer(name: layer.name, colorIsForeground: isForeground, colorRGB: rgb,
                              linetypeName: linetypeName, isOffByDefault: layer.isOffByDefault,
                              isFrozen: layer.isFrozen)
        }
    }

    private static func collectLinetypes(usedIn entities: [PastedEntity], and blocks: [PastedBlock],
                                         parsed: EditableParsedDocument) -> [PastedLinetype] {
        var names = Set<String>()
        func walk(_ e: PastedEntity) {
            if let lt = e.linetypeName, lt != "BYBLOCK" { names.insert(lt) }
            for c in e.children { walk(c) }
        }
        entities.forEach(walk)
        blocks.forEach { $0.entities.forEach(walk) }

        return names.compactMap { name -> PastedLinetype? in
            guard let id = parsed.linetypeIdByName[name.uppercased()], Int(id) < parsed.linetypes.count
            else { return nil }
            let lt = parsed.linetypes[Int(id)]
            return PastedLinetype(name: lt.name, dashes: lt.dashes.map { Double($0) })
        }
    }
}
