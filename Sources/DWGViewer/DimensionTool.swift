import Foundation
import CoreGraphics
import CADCore

// MARK: - Dimension annotations (linear / aligned)
//
// Authors a REAL DXF DIMENSION entity + its own anonymous BLOCK definition
// (matching AutoCAD's own on-disk structure exactly — an anonymous `*D<n>`
// block containing the actual drawn geometry: two extension lines, the
// dimension line, two closed-triangle arrowheads, and a TEXT label showing
// the measured value), rather than the simpler "just drop plain LINE/TEXT
// entities on the markup layer" shortcut the existing (pre-dimension-tool)
// Measure feature uses (`ContentView.commitMeasurement`). This is the
// "DXF-correct" route flagged as the more-work-but-more-compatible option
// during design: a dimension authored this way round-trips through AutoCAD
// (and back through NovaCAD) as a real, recognized DIMENSION entity, not
// disconnected geometry-that-happens-to-look-like-one.
//
// Persistence / selection semantics (a hard product requirement): unlike
// the ephemeral on-canvas overlay `MeasureState` drives while a measurement
// is in progress (drawn live, never an entity until "commit"), a DIMENSION
// created here is a REAL entity from the moment it's placed — it remains
// visible after being deselected exactly like every other entity (there is
// no separate "dimension mode" overlay to fall out of after the 3-click
// gesture finishes; the click sequence commits a genuine `tx.add`).
//
// Render-path constraint this must respect (see `Regenerator.insertLike`'s
// `.dimension` case): a DIMENSION's anonymous block is ALWAYS expanded with
// an identity placement transform (position (0,0), scale (1,1), rotation 0)
// — `DimensionPayload.defPoint` is used only for bounds/hit-testing
// (`RegenCoordinator`'s `case .dimension: return pointRect(p.defPoint)`),
// NEVER as a render-time placement offset. So every member entity inside
// the anonymous block must be authored in ABSOLUTE WORLD coordinates
// already (with `block.base = .zero`), not block-local coordinates that
// would need a placement transform to land in the right spot — there is no
// such transform applied for `.dimension` references.
//
// Per-dimension format override: each dimension stores its own
// `MeasureFormat` (system/style/precision), defaulting to whatever the
// global Units preference is at CREATION time, so mixed-format dimensions
// on one drawing are supported (e.g. one architectural dimension alongside
// others in decimal) — this is a deliberate product decision (see the
// conversation this was designed in) rather than always deferring to the
// live global setting. Stored as XDATA on the DIMENSION entity itself
// (`xdataAppId`/`xdataFormatCodes` below) since `DimensionPayload` has no
// spare fields for it and XDATA already round-trips for free through both
// the parser (case "DIMENSION" hits the generic `commonProps` XDATA
// handling) and the writer (`EntityRecordWriter.writeDimension` leaves
// `needsGenericExtras = true`, so `writeExtras`/`writeXData` always runs).
// The format is re-read from this XDATA and reformats the text label
// in-place whenever the user changes it via the on-canvas format control
// (see `DimensionFormatOverlay`/`ContentView.setDimensionFormat`) — the
// dimension's stored measured VALUE (a plain Double, also in this XDATA)
// never changes, only how it's displayed.
enum DimensionKind: Equatable {
    case linear    // horizontal/vertical: measures ONLY the axis-aligned component AutoCAD's DIMLINEAR would report
    case aligned   // measures the true point-to-point distance, dimension line parallel to the measured edge
}

enum DimensionTool {

    /// AutoCAD's own anonymous-dimension-block naming convention
    /// (`*D<n>`, referenced only in this codebase's comments before now —
    /// see `EntityRecordWriter.swift`'s writeDimension doc comment). Not a
    /// real requirement for NovaCAD's own parser (it only checks the name
    /// resolves in `parsed.blocks`, not that it matches this pattern), but
    /// matching the convention keeps a saved-and-reopened-in-AutoCAD file
    /// looking like an ordinary, recognizable AutoCAD-authored dimension
    /// rather than an oddly-named custom block.
    private static func nextAnonymousBlockName(in parsed: EditableParsedDocument) -> String {
        var n = 1
        while parsed.blocks["*D\(n)"] != nil { n += 1 }
        return "*D\(n)"
    }

    /// XDATA app-id NovaCAD's own dimension metadata is filed under —
    /// mirrors `RegionTool.xdataAppId`'s own precedent for "small app-
    /// specific marker/metadata living in XDATA rather than inventing new
    /// EntityStore/DimensionPayload fields."
    static let xdataAppId = "NOVACAD_DIM"
    /// Group codes used within that one XDATA blob's `pairs`, all scoped to
    /// this one appId so they never collide with a real AutoCAD extension
    /// dictionary/XDATA an opened file might already carry under a
    /// DIFFERENT appId (XDATA is keyed by appId — see `XDataBlob`).
    private enum Code {
        static let measuredValue: Int16 = 1040     // the raw measured length (drawing units) — group 1040 = real (double)
        static let unitSystem: Int16 = 1000        // UnitSystem.rawValue, as a string
        static let lengthStyle: Int16 = 1071       // LengthStyle index (see `styleOrder`), as an int
        static let precision: Int16 = 1072         // MeasureFormat.precision, as an int
    }
    /// `LengthStyle` has no raw `Int` — indexed via `CaseIterable` order so
    /// it round-trips through an XDATA int code without needing a second
    /// string code (keeps this dimension's metadata to a compact 4 pairs).
    private static let styleOrder = LengthStyle.allCases

    /// Reads back a dimension's stored format + measured value from its
    /// XDATA, if this entity is (and still carries) NovaCAD-authored
    /// dimension metadata. Returns `nil` for a DIMENSION round-tripped from
    /// some OTHER source (e.g. opened from an AutoCAD-authored file) that
    /// never went through `DimensionTool.create` — such a dimension has no
    /// per-entity format override and simply isn't editable via the
    /// on-canvas format control (falls back silently; it still renders via
    /// its own already-authored geometry regardless).
    static func readMetadata(_ id: EntityID, store: EntityStore) -> (format: MeasureFormat, measuredValue: Double)? {
        guard let blob = store.xdata[id.raw], blob.appId == xdataAppId else { return nil }
        var system: UnitSystem = .asDrawn
        var style: LengthStyle = .decimal
        var precision = 3
        var measured: Double = 0
        for (code, value) in blob.pairs {
            switch (code, value) {
            case (Code.measuredValue, .double(let d)): measured = d
            case (Code.unitSystem, .string(let s)): system = UnitSystem(rawValue: s) ?? .asDrawn
            case (Code.lengthStyle, .int(let i)): style = styleOrder[safe: Int(i)] ?? .decimal
            case (Code.precision, .int(let i)): precision = Int(i)
            default: break
            }
        }
        return (MeasureFormat(system: system, style: style, precision: precision), measured)
    }

    private static func metadataXData(format: MeasureFormat, measuredValue: Double) -> XDataBlob {
        let styleIndex = styleOrder.firstIndex(of: format.style) ?? 0
        return XDataBlob(appId: xdataAppId, pairs: [
            (Code.measuredValue, .double(measuredValue)),
            (Code.unitSystem, .string(format.system.rawValue)),
            (Code.lengthStyle, .int(Int32(styleIndex))),
            (Code.precision, .int(Int32(format.precision))),
        ])
    }

    /// Geometric constants, all expressed relative to the dimension's own
    /// TEXT height (`textHeight`) so a dimension scales sensibly whether
    /// it's measuring a 2-unit gap or a 2000-unit one — mirrors how
    /// `ContentView.commitMeasurement`'s existing (non-persistent) distance
    /// label already derives its height from the measured length rather
    /// than a fixed absolute constant.
    private static let arrowLengthToTextHeight: CGFloat = 1.2
    private static let arrowWidthToLength: CGFloat = 0.32
    private static let extensionLineOvershoot: CGFloat = 1.0       // multiples of textHeight, past the dimension line
    private static let extensionLineGap: CGFloat = 0.4             // multiples of textHeight, gap from the measured point
    private static let textGapAboveLine: CGFloat = 0.35            // multiples of textHeight, text baseline above the dim line

    /// Builds and commits one linear or aligned dimension, given the two
    /// measured points and a third "dimension line placement" point (the
    /// AutoCAD DIMLINEAR/DIMALIGNED 3-click gesture this tool matches) —
    /// entirely self-contained: creates the anonymous block, its member
    /// entities, and the owning DIMENSION entity, all inside ONE
    /// transaction (so it's one atomic, undoable action, mirroring
    /// `ShadeLayer.apply`'s "caller supplies an open `tx`" convention).
    ///
    /// `kind: .linear` projects BOTH the measured segment and the placement
    /// point onto whichever axis (horizontal/vertical) the placement point
    /// is farther offset along — matching AutoCAD's own DIMLINEAR "pick a
    /// direction implicitly from where you drag the dimension line"
    /// behavior. `kind: .aligned` always measures the true distance between
    /// the two points, with the dimension line kept exactly parallel to the
    /// segment being measured, offset perpendicular to it toward the
    /// placement point.
    /// Pure geometry result (no `EntityStore`/`Transaction` involved) — shared
    /// by `previewGeometry` (canvas-only, live preview while placing) and
    /// `create` (which turns each `lines`/`arrowTriangles` entry into a real
    /// entity, plus the text). Kept entirely separate from entity
    /// construction so the live on-canvas preview computes EXACTLY the same
    /// shape that will be committed, with zero risk of preview/commit drift.
    struct Geometry {
        var lines: [(CGPoint, CGPoint)]           // extension lines + dimension line
        var arrowTriangles: [[CGPoint]]           // two 3-point closed triangles
        var textPosition: CGPoint
        var textRotationDeg: Double
        var textHeight: CGFloat
        var measuredValue: Double
        var text: String                          // pre-formatted using the CALLER's format
    }

    /// Computes the full dimension geometry for the given 3 picked points —
    /// the shared core both `create` (commits real entities) and
    /// `previewGeometry` (canvas-only) build on.
    private static func computeGeometry(kind: DimensionKind, p1: CGPoint, p2: CGPoint,
                                        placement: CGPoint, format: MeasureFormat) -> Geometry? {
        guard hypot(p2.x - p1.x, p2.y - p1.y) > 1e-9 else { return nil }

        // ---- Resolve the dimension-line geometry ----
        let dimA: CGPoint, dimB: CGPoint, measuredValue: Double
        switch kind {
        case .aligned:
            let dx = p2.x - p1.x, dy = p2.y - p1.y
            let len = hypot(dx, dy)
            let ux = dx / len, uy = dy / len          // unit vector along the measured edge
            let nx = -uy, ny = ux                     // unit normal (perpendicular)
            // Signed perpendicular distance from p1 to the placement point,
            // along the normal — this is how far OFF the measured line the
            // dimension line itself sits (can be negative; sign just flips
            // which side it's drawn on, exactly like AutoCAD).
            let offset = (placement.x - p1.x) * nx + (placement.y - p1.y) * ny
            dimA = CGPoint(x: p1.x + nx * offset, y: p1.y + ny * offset)
            dimB = CGPoint(x: p2.x + nx * offset, y: p2.y + ny * offset)
            measuredValue = Double(len)

        case .linear:
            // Implicit axis choice: whichever offset (horizontal vs
            // vertical distance from the measured segment to the placement
            // point) is larger decides whether this is a horizontal or
            // vertical linear dimension — mirrors AutoCAD's DIMLINEAR mouse
            // behavior (no explicit H/V keystroke needed for the common
            // case).
            let horizOffset = abs(placement.y - p1.y)
            let vertOffset = abs(placement.x - p1.x)
            if horizOffset >= vertOffset {
                // Horizontal dimension line: measures |Δx|, sits at the
                // placement point's Y.
                let y = placement.y
                dimA = CGPoint(x: p1.x, y: y)
                dimB = CGPoint(x: p2.x, y: y)
                measuredValue = Double(abs(p2.x - p1.x))
            } else {
                // Vertical dimension line: measures |Δy|, sits at the
                // placement point's X.
                let x = placement.x
                dimA = CGPoint(x: x, y: p1.y)
                dimB = CGPoint(x: x, y: p2.y)
                measuredValue = Double(abs(p2.y - p1.y))
            }
        }
        guard measuredValue > 1e-9 else { return nil }

        let dimLen = hypot(dimB.x - dimA.x, dimB.y - dimA.y)
        guard dimLen > 1e-9 else { return nil }
        let ux = (dimB.x - dimA.x) / dimLen, uy = (dimB.y - dimA.y) / dimLen

        // Text height scales off the measured length itself — same
        // convention `commitMeasurement`'s distance label already uses
        // (`len * 0.04`), reused here for visual consistency between the
        // old ephemeral measure tool and this new persistent one.
        let textHeight = max(dimLen * 0.04, 1e-6)
        let arrowLen = textHeight * arrowLengthToTextHeight
        let arrowHalfWidth = arrowLen * arrowWidthToLength * 0.5

        var lines: [(CGPoint, CGPoint)] = []
        var triangles: [[CGPoint]] = []

        // Extension lines: from each measured point out past the dimension
        // line by `extensionLineOvershoot`, starting `extensionLineGap`
        // short of the measured point itself (AutoCAD's default DIMEXO/
        // small standoff gap, so the extension line doesn't visually touch
        // the measured geometry).
        let gap = textHeight * extensionLineGap
        let overshoot = textHeight * extensionLineOvershoot
        func extensionLine(from measuredPoint: CGPoint, to dimPoint: CGPoint) {
            let dx = dimPoint.x - measuredPoint.x, dy = dimPoint.y - measuredPoint.y
            let len = hypot(dx, dy)
            guard len > 1e-9 else { return }
            let ex = dx / len, ey = dy / len
            let start = CGPoint(x: measuredPoint.x + ex * gap, y: measuredPoint.y + ey * gap)
            let end = CGPoint(x: dimPoint.x + ex * overshoot, y: dimPoint.y + ey * overshoot)
            lines.append((start, end))
        }
        extensionLine(from: p1, to: dimA)
        extensionLine(from: p2, to: dimB)

        // Dimension line + two closed-triangle arrowheads pointing inward
        // (toward each other) — per the confirmed design decision (closed
        // filled triangles, AutoCAD's own default, over architectural tick
        // marks).
        lines.append((dimA, dimB))
        func arrowhead(at tip: CGPoint, pointingAwayFrom other: CGPoint) {
            let dx = tip.x - other.x, dy = tip.y - other.y
            let len = hypot(dx, dy)
            guard len > 1e-9 else { return }
            let dirx = dx / len, diry = dy / len          // unit vector FROM other TOWARD tip (arrow points this way)
            let nx = -diry, ny = dirx                      // perpendicular
            let backX = tip.x - dirx * arrowLen, backY = tip.y - diry * arrowLen
            let p2x = backX + nx * arrowHalfWidth, p2y = backY + ny * arrowHalfWidth
            let p3x = backX - nx * arrowHalfWidth, p3y = backY - ny * arrowHalfWidth
            triangles.append([tip, CGPoint(x: p2x, y: p2y), CGPoint(x: p3x, y: p3y)])
        }
        arrowhead(at: dimA, pointingAwayFrom: dimB)
        arrowhead(at: dimB, pointingAwayFrom: dimA)

        // Text label: centered at the dimension line's midpoint, offset
        // perpendicular (toward whichever side is "up" relative to the
        // dimension line's own direction) by a small standoff, rotated to
        // read along the dimension line — matches AutoCAD's default
        // horizontal/aligned text placement.
        let midX = (dimA.x + dimB.x) / 2, midY = (dimA.y + dimB.y) / 2
        let nx = -uy, ny = ux
        let textGap = textHeight * (1 + textGapAboveLine)
        let textPos = CGPoint(x: midX + nx * textGap, y: midY + ny * textGap)
        var rotationDeg = atan2(Double(uy), Double(ux)) * 180 / .pi
        // Keep dimension text upright/readable — flip 180° if it would
        // otherwise render upside-down (between 90° and 270°), matching
        // ordinary CAD-annotation convention (text should never read
        // bottom-to-top).
        if rotationDeg > 90 || rotationDeg < -90 { rotationDeg += 180 }

        let labelText = format.length(CGFloat(measuredValue))
        return Geometry(lines: lines, arrowTriangles: triangles, textPosition: textPos,
                        textRotationDeg: rotationDeg, textHeight: textHeight,
                        measuredValue: measuredValue, text: labelText)
    }

    /// Canvas-only preview (no entities created) — used by
    /// `DXFCanvasView.drawDimensionPreview` while the user is choosing the
    /// dimension-line placement, so the preview shows EXACTLY what
    /// `create` below would commit. Always previews using plain default
    /// decimal formatting's SHAPE (the caller's `MeasureFormat` isn't
    /// available mid-gesture in `DXFCanvasView`, which has no access to
    /// `ContentView.currentFormat` — only geometry positions are load-
    /// bearing for the preview's visual accuracy; the exact text/format is
    /// finalized at commit time in `create`, which DOES receive the real
    /// format).
    static func previewGeometry(kind: DimensionKind, p1: CGPoint, p2: CGPoint,
                               placement: CGPoint) -> Geometry? {
        computeGeometry(kind: kind, p1: p1, p2: p2, placement: placement, format: MeasureFormat())
    }

    @discardableResult
    static func create(kind: DimensionKind, p1: CGPoint, p2: CGPoint, placement: CGPoint,
                       layerId: Int32, aci: Int16, format: MeasureFormat,
                       owner: OwnerRef, parsed: EditableParsedDocument, tx: Transaction) -> EntityID? {
        guard let geo = computeGeometry(kind: kind, p1: p1, p2: p2, placement: placement, format: format) else {
            return nil
        }
        let store = parsed.store

        var memberProtos: [EntityPrototype] = []
        for (a, b) in geo.lines {
            memberProtos.append(EntityPrototype(type: .line, layerId: layerId, aci: aci,
                                                owner: .block(-1),   // owner is rewritten below once blockIndex is known
                                                payload: .line(LinePayload(a: Vec3(a), b: Vec3(b)))))
        }
        for tri in geo.arrowTriangles {
            let verts = tri.map { Vec3($0) }
            let bulges = [Double](repeating: 0, count: verts.count)
            memberProtos.append(EntityPrototype(type: .solid, layerId: layerId, aci: aci,
                                                owner: .block(-1),
                                                payload: .polyline(PolylinePayload(closed: true),
                                                                   vertices: verts, bulges: bulges)))
        }

        let stringId = store.strings.intern(geo.text)
        // hAlign=1 (center) / vAlign=2 (middle) is a non-default alignment,
        // so the renderer anchors off `alignPosition` (group 11/21), NOT
        // `position` (group 10/20) — see `Regenerator`'s TEXT case: `anchor
        // = (hAlign == 0 && vAlign == 0) ? position : alignPosition`. Both
        // are set to the same point here since there's no separate
        // "insertion point vs alignment point" distinction needed for a
        // dimension's own generated label.
        memberProtos.append(EntityPrototype(
            type: .text, layerId: layerId, aci: aci, owner: .block(-1),
            payload: .text(TextPayload(position: Vec3(geo.textPosition), alignPosition: Vec3(geo.textPosition),
                                      height: Double(geo.textHeight), rotationDeg: geo.textRotationDeg,
                                      stringId: stringId, hAlign: 1, vAlign: 2))))

        // ---- Register the anonymous block, fixing up member ownership ----
        let blockIndex = BlockEditor.nextBlockIndex(in: parsed)
        let blockOwner = OwnerRef.block(blockIndex)
        for i in memberProtos.indices { memberProtos[i].owner = blockOwner }

        var newIDs: [EntityID] = []
        newIDs.reserveCapacity(memberProtos.count)
        for proto in memberProtos { newIDs.append(tx.add(proto)) }
        guard let firstId = newIDs.first else { return nil }

        let name = nextAnonymousBlockName(in: parsed)
        let def = EditableBlockDef()
        def.name = name
        def.base = .zero   // members already authored in absolute world coords — see this file's header comment
        def.blockIndex = blockIndex
        def.entityStart = firstId.raw
        def.entityCount = Int32(newIDs.count)
        parsed.blocks[name] = def
        tx.registerSideEffect(
            undo: { parsed.blocks[name] = nil },
            redo: { parsed.blocks[name] = def })

        // ---- The DIMENSION entity itself ----
        let dimA = geo.lines.last?.0 ?? p1   // the dimension line's own start point (defPoint, per DXF convention)
        let blockNameId = store.strings.intern(name)
        let dimId = tx.add(EntityPrototype(
            type: .dimension, layerId: layerId, aci: aci, owner: owner,
            payload: .dimension(DimensionPayload(blockNameId: blockNameId, defPoint: Vec3(dimA)))))
        store.xdata[dimId.raw] = metadataXData(format: format, measuredValue: geo.measuredValue)
        tx.registerSideEffect(
            undo: { store.xdata[dimId.raw] = nil },
            redo: { store.xdata[dimId.raw] = Self.metadataXData(format: format, measuredValue: geo.measuredValue) })

        return dimId
    }

    /// Re-renders a dimension's TEXT label in a NEW format without moving
    /// or re-measuring anything — used by the on-canvas format switcher for
    /// a selected dimension. Finds the label entity inside the dimension's
    /// own anonymous block (the one TEXT entity `DimensionTool.create`
    /// placed there) and rewrites its string; updates the stored XDATA
    /// metadata to the new format so it's remembered on reselect/reopen.
    @discardableResult
    static func setFormat(_ dimId: EntityID, to newFormat: MeasureFormat,
                         parsed: EditableParsedDocument, tx: Transaction) -> Bool {
        let store = parsed.store
        guard let h = store.header(dimId), h.type == .dimension, h.payload >= 0,
              let (oldFormat, measuredValue) = readMetadata(dimId, store: store) else { return false }
        let dp = store.dimensions[Int(h.payload)]
        let name = store.strings.string(for: dp.blockNameId)
        guard let block = parsed.blocks[name], block.entityCount > 0 else { return false }

        var textId: EntityID? = nil
        for i in Int(block.entityStart)..<Int(block.entityStart + block.entityCount) {
            let id = EntityID(raw: Int32(i))
            guard let mh = store.header(id), !mh.flags.contains(.deleted), mh.type == .text else { continue }
            textId = id
            break
        }
        guard let textId else { return false }

        let newLabel = newFormat.length(CGFloat(measuredValue))
        tx.modifyPayload(textId) { copy in
            if case .text(var p) = copy {
                p.stringId = store.strings.intern(newLabel)
                copy = .text(p)
            }
        }
        let oldBlob = store.xdata[dimId.raw]
        let newBlob = metadataXData(format: newFormat, measuredValue: measuredValue)
        store.xdata[dimId.raw] = newBlob
        tx.registerSideEffect(
            undo: { store.xdata[dimId.raw] = oldBlob },
            redo: { store.xdata[dimId.raw] = newBlob })
        _ = oldFormat   // only needed to confirm this WAS a NovaCAD-authored dimension
        return true
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
