import Foundation
import CoreGraphics
import CADCore

// MARK: - Cross-drawing Copy/Paste (new feature)
//
// Transport: `NSPasteboard` (`PasteboardSnapshot.swift`) rather than a live
// registry of every open `DocumentSession` — this session's own research
// found no existing cross-tab/cross-window session registry in NovaCAD
// (tabs are a private `@State` array on `DocumentTabsView`, one per window;
// `WindowGroup` gives independent windows no shared state at all), and a
// pasteboard-based design needs none: the SOURCE drawing is only read from
// at Copy time (producing a self-contained snapshot with every layer/
// linetype/block dependency captured BY NAME — see `PasteboardSnapshot`'s
// own header comment), and Paste only ever needs the DESTINATION tab's own
// session, exactly like `XrefAttach`'s "read a file, then commit against
// the live document" split. This also means Copy/Paste works identically
// whether the destination is another tab in the SAME window or a tab in a
// completely different window/`WindowGroup` instance, with no additional
// plumbing.
//
// `commitPaste` is structured as `XrefAttach.commitAttach`'s direct
// sibling: register any layer/linetype/block the snapshot depends on that
// the destination doesn't already have (by NAME, auto-created carrying over
// the source's own color/dashes — matching this feature's product
// decision), remap, then re-create each entity via `Transaction.add` (not
// `appendCopy` — there is no live source `EntityStore` to copy FROM here,
// only the plain-data `PasteboardSnapshot` already decoded from JSON) with
// its ATTRIB children correctly re-parented onto the NEW INSERT's id (the
// gap neither `Transaction.copyTransformed` nor a bare `EntityStore
// .appendCopy` call closes on its own — see this session's research notes).
enum CrossDocumentPaste {

    /// Registers every layer/linetype/block the snapshot depends on that
    /// `parsed` doesn't already have (by name — reusing an existing same-
    /// named layer/linetype/block as-is, per this feature's product
    /// decision, rather than prompting on a collision), places every
    /// top-level copied entity translated by `(dx, dy)`, and returns the
    /// new top-level `EntityID`s (in `snapshot.entities` order) for the
    /// caller to select afterward. `owner` is the destination space (model
    /// or paper) the paste lands in — independent of which space the
    /// ENTITIES were copied from, matching `EntityImage.asPrototype`'s own
    /// "COPY always passes the ambient space explicitly" precedent.
    @discardableResult
    static func commitPaste(_ snapshot: PasteboardSnapshot.Snapshot, dx: Double, dy: Double,
                            owner: OwnerRef, in parsed: EditableParsedDocument,
                            tx: Transaction) -> [EntityID] {
        let store = parsed.store

        // ---- Layers: reuse by name if present, else create carrying over
        // the snapshot's own color/linetype/visibility. ----
        var layerIdByName = [String: Int32]()
        for pastedLayer in snapshot.layers {
            if let existing = parsed.layerIdByName[pastedLayer.name] {
                layerIdByName[pastedLayer.name] = existing
                continue
            }
            let color: ResolvedColor = pastedLayer.colorIsForeground ? .foreground : .rgb(pastedLayer.colorRGB)
            let newId = Int32(parsed.layers.count)
            parsed.layers.append(DXFLayer(id: Int(newId), name: pastedLayer.name, color: color, linetypeId: 0,
                                          isOffByDefault: pastedLayer.isOffByDefault,
                                          isFrozen: pastedLayer.isFrozen, entityCount: 0))
            parsed.layerIdByName[pastedLayer.name] = newId
            layerIdByName[pastedLayer.name] = newId
        }
        func resolveLayer(_ name: String) -> Int32 {
            layerIdByName[name] ?? parsed.layerIdByName[name] ?? 0   // "0" always exists in a real document
        }

        // ---- Linetypes: reuse by (uppercased) name if present, else create. ----
        var linetypeIdByName = [String: Int16]()
        for pastedLt in snapshot.linetypes {
            let upper = pastedLt.name.uppercased()
            if let existing = parsed.linetypeIdByName[upper] {
                linetypeIdByName[upper] = existing
                continue
            }
            let newId = Int16(parsed.linetypes.count)
            parsed.linetypes.append(DXFLinetype(name: pastedLt.name, dashes: pastedLt.dashes.map { CGFloat($0) }))
            parsed.linetypeIdByName[upper] = newId
            linetypeIdByName[upper] = newId
        }
        /// nil = BYLAYER (-1); "BYBLOCK" sentinel = BYBLOCK (-2); otherwise
        /// resolves through the map above, falling back to BYLAYER for a
        /// name the destination can't resolve (shouldn't happen — every
        /// name here was captured as a dependency in `snapshot.linetypes`
        /// or is one of the two sentinels — but never worth a crash).
        func resolveLinetype(_ name: String?) -> Int16 {
            guard let name else { return -1 }
            if name == "BYBLOCK" { return -2 }
            return linetypeIdByName[name.uppercased()] ?? parsed.linetypeIdByName[name.uppercased()] ?? -1
        }

        // ---- Blocks: any block a copied INSERT references gets registered
        // (reusing an existing same-named block as-is) before any INSERT
        // pointing at it is created, exactly like layers/linetypes above —
        // unlike XrefAttach, pasted block names are NOT renamed/prefixed
        // (a paste's block dependency is the SAME named block concept in
        // both documents, not a synthetic per-attach dependency wrapper),
        // so if the destination already has a DIFFERENT block under that
        // name, this paste reuses the destination's own definition rather
        // than the pasted content — an accepted, documented tradeoff of the
        // "auto-create by name" product decision (same one `XrefAttach`
        // makes for layers/linetypes); a future refinement could detect a
        // structural mismatch and rename instead.
        //
        // `addedBlockDefs` mirrors `XrefAttach.commitAttach`'s own
        // identically-named local exactly — the `(name, def)` pairs THIS
        // paste actually created, captured at creation time (not
        // re-derived later), so the single `registerSideEffect` below can
        // undo (nil the dictionary entries) and redo (restore the exact
        // same `EditableBlockDef` instances) correctly regardless of what
        // else touches `parsed.blocks` in between.
        var addedBlockDefs: [(name: String, def: EditableBlockDef)] = []
        func ensureBlock(named name: String) {
            guard parsed.blocks[name] == nil,
                  let pastedBlock = snapshot.blocks.first(where: { $0.name == name })
            else { return }
            // Guard against `ensureBlock` re-entering for the SAME name via
            // a dependency cycle (shouldn't occur in a well-formed DXF, but
            // a defensive placeholder registration prevents infinite
            // recursion either way): reserve the dictionary slot with a
            // still-being-filled def before recursing into dependencies.
            let def = EditableBlockDef()
            def.name = name
            parsed.blocks[name] = def
            addedBlockDefs.append((name, def))

            for entity in pastedBlock.entities {
                if case .insert(let blockName, _, _, _, _, _, _, _) = entity.payload {
                    ensureBlock(named: blockName)
                }
            }
            let blockIndex = BlockEditor.nextBlockIndex(in: parsed)
            def.blockIndex = blockIndex
            let start = Int32(store.count)
            for entity in pastedBlock.entities {
                _ = createEntity(entity, dx: 0, dy: 0, owner: .block(blockIndex),
                                 resolveLayer: resolveLayer, resolveLinetype: resolveLinetype,
                                 ensureBlock: ensureBlock, store: store, tx: tx)
            }
            def.entityStart = start
            def.entityCount = Int32(store.count) - start
        }
        for pastedBlock in snapshot.blocks { ensureBlock(named: pastedBlock.name) }
        if !addedBlockDefs.isEmpty {
            tx.registerSideEffect(
                undo: { for (name, _) in addedBlockDefs { parsed.blocks[name] = nil } },
                redo: { for (name, def) in addedBlockDefs { parsed.blocks[name] = def } })
        }

        // ---- Top-level entities: translated by (dx, dy). ----
        var newIds: [EntityID] = []
        for entity in snapshot.entities {
            if let id = createEntity(entity, dx: dx, dy: dy, owner: owner,
                                     resolveLayer: resolveLayer, resolveLinetype: resolveLinetype,
                                     ensureBlock: ensureBlock, store: store, tx: tx) {
                newIds.append(id)
            }
        }
        return newIds
    }

    /// Creates one entity (translated by `dx`/`dy`) plus, for an INSERT, its
    /// ATTRIB children re-parented onto the NEW INSERT's id — the fix for
    /// the gap this session's research flagged (neither existing COPY path
    /// re-parents ATTRIBs on its own). Ensures any block the entity
    /// references (INSERT) is registered first via `ensureBlock`.
    @discardableResult
    private static func createEntity(_ entity: PasteboardSnapshot.PastedEntity, dx: Double, dy: Double,
                                     owner: OwnerRef, resolveLayer: (String) -> Int32,
                                     resolveLinetype: (String?) -> Int16,
                                     ensureBlock: (String) -> Void, store: EntityStore,
                                     tx: Transaction) -> EntityID? {
        if case .insert(let blockName, _, _, _, _, _, _, _) = entity.payload {
            ensureBlock(blockName)
        }
        let layerId = resolveLayer(entity.layerName)
        let linetypeId = resolveLinetype(entity.linetypeName)
        let payload = translatedPayload(entity.payload, dx: dx, dy: dy, store: store)

        let proto = EntityPrototype(type: entity.type, layerId: layerId, aci: entity.aci,
                                    trueColor: entity.trueColor, linetypeId: linetypeId,
                                    lineweight: entity.lineweight, owner: owner, ltScale: entity.ltScale,
                                    payload: payload)
        let newId = tx.add(proto)

        for child in entity.children {
            _ = createEntity(child, dx: dx, dy: dy, owner: .parentEntity(newId),
                            resolveLayer: resolveLayer, resolveLinetype: resolveLinetype,
                            ensureBlock: ensureBlock, store: store, tx: tx)
        }
        return newId
    }

    /// Converts a `PayloadSnapshot` into a live `EntityPayloadCopy`,
    /// interning every plain `String` (value/style/tag/prompt/block name/
    /// pattern name) into the DESTINATION store's OWN `StringTable` — this
    /// is the cross-drawing-paste equivalent of the fix this session made
    /// to `EntityStore.appendCopy` for the xref-attach path, done here at
    /// the source (there is no raw string-table index to mis-copy in the
    /// first place, since `PasteboardSnapshot` already carries literal
    /// `String`s, not indices) — and applies the world-space translation in
    /// the same pass `EntityPayloadCopy.translate(dx:dy:)` already defines
    /// for the live in-store COPY/MOVE tools, reused here rather than
    /// duplicated.
    private static func translatedPayload(_ p: PasteboardSnapshot.PayloadSnapshot, dx: Double, dy: Double,
                                          store: EntityStore) -> EntityPayloadCopy {
        var copy: EntityPayloadCopy
        switch p {
        case .line(let a, let b):
            copy = .line(LinePayload(a: a, b: b))
        case .point(let pt):
            copy = .point(PointPayload(p: pt))
        case .circle(let center, let radius, let extrusionZ):
            copy = .circle(CirclePayload(center: center, radius: radius, extrusionZ: extrusionZ))
        case .arc(let center, let radius, let s, let e, let extrusionZ):
            copy = .arc(ArcPayload(center: center, radius: radius, startAngleDeg: s, endAngleDeg: e, extrusionZ: extrusionZ))
        case .ellipse(let center, let majorAxisEndpoint, let ratio, let sp, let ep):
            copy = .ellipse(EllipsePayload(center: center, majorAxisEndpoint: majorAxisEndpoint, ratio: ratio,
                                          startParam: sp, endParam: ep))
        case .polyline(let verts, let bulges, let closed, let width, let elevation, let is3D):
            var pp = PolylinePayload(closed: closed)
            pp.constantWidth = width; pp.elevation = elevation; pp.is3D = is3D
            copy = .polyline(pp, vertices: verts, bulges: bulges)
        case .spline(let degree, let control, let knots, let weights, let closed):
            var sp = SplinePayload(degree: degree)
            sp.closed = closed
            copy = .spline(sp, control: control, knots: knots, weights: weights)
        case .text(let position, let alignPosition, let height, let rotationDeg, let widthFactor, let obliqueDeg,
                  let value, let styleName, let hAlign, let vAlign, let isBackwards, let isUpsideDown,
                  let tag, let prompt):
            var tp = TextPayload(position: position, height: height, stringId: store.strings.intern(value))
            tp.alignPosition = alignPosition; tp.rotationDeg = rotationDeg; tp.widthFactor = widthFactor
            tp.obliqueDeg = obliqueDeg; tp.hAlign = hAlign; tp.vAlign = vAlign
            tp.isBackwards = isBackwards; tp.isUpsideDown = isUpsideDown
            tp.styleNameId = styleName.isEmpty ? -1 : store.strings.intern(styleName)
            tp.tagStringId = tag.isEmpty ? -1 : store.strings.intern(tag)
            tp.promptStringId = prompt.isEmpty ? -1 : store.strings.intern(prompt)
            copy = .text(tp)
        case .mtext(let insertion, let height, let refWidth, let rotationDeg, let attachPoint, let value, let styleName):
            var mp = MTextPayload(insertion: insertion, height: height, stringId: store.strings.intern(value))
            mp.refWidth = refWidth; mp.rotationDeg = rotationDeg; mp.attachPoint = attachPoint
            mp.styleNameId = styleName.isEmpty ? -1 : store.strings.intern(styleName)
            copy = .mtext(mp)
        case .insert(let blockName, let position, let scale, let rotationDeg, let cols, let rows,
                    let colSpacing, let rowSpacing):
            var ip = InsertPayload(blockNameId: store.strings.intern(blockName), position: position)
            ip.scale = scale; ip.rotationDeg = rotationDeg; ip.cols = cols; ip.rows = rows
            ip.colSpacing = colSpacing; ip.rowSpacing = rowSpacing
            copy = .insert(ip)
        case .hatch(let patternName, let isSolid, let angle, let scale, let origin, let loops, let associative):
            var hp = HatchPayload(isSolid: isSolid)
            hp.patternNameId = patternName.isEmpty ? -1 : store.strings.intern(patternName)
            hp.angle = angle; hp.scale = scale; hp.origin = origin; hp.associative = associative
            copy = .hatch(hp, loops: loops)
        case .unsupported:
            copy = .unknown
        }
        if dx != 0 || dy != 0 { copy.translate(dx: dx, dy: dy) }
        return copy
    }
}
