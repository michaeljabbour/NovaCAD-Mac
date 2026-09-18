import CADCore
import CoreGraphics

/// The Properties panel's "Hatch Type" choices for a HATCH entity. `HATCH`'s
/// on-disk representation only distinguishes solid (`isSolid == true`, DXF
/// group 70 bit 0) from a NAMED pattern (`isSolid == false`,
/// `HatchPayload.patternNameId` naming it, group 2) — `.diagonalLines` maps
/// to the synthetic pattern name `HatchStyle.diagonalPatternName` ("ANSI31",
/// AutoCAD's own standard 45°-diagonal-line hatch pattern name, so a
/// drawing round-trips through real AutoCAD showing a recognizable,
/// non-garbage pattern name rather than an app-specific placeholder).
enum HatchStyle: Equatable {
    case solid
    case diagonalLines

    /// AutoCAD's own standard name for a 45°-diagonal single-line hatch —
    /// used as `HatchPayload.patternNameId`'s interned string whenever
    /// `.diagonalLines` is selected, so a saved DXF's HATCH pattern name is
    /// exactly what real AutoCAD would show for the same visual pattern,
    /// not a NovaCAD-invented one a re-opened-elsewhere file couldn't
    /// interpret.
    static let diagonalPatternName = "ANSI31"

    /// `isSolid == false` always maps to `.diagonalLines` today — every
    /// non-solid `HatchPayload` renders as diagonal lines regardless of its
    /// stored pattern name (see `Regenerator`'s `.hatch` case); the name
    /// itself is preserved purely for round-trip fidelity with files
    /// authored/edited in real AutoCAD, not read back by this app.
    init(isSolid: Bool) {
        self = isSolid ? .solid : .diagonalLines
    }
}

/// "Fill / Hatch…" — the Properties panel's single-entity counterpart to
/// `ShadeLayer` (which fills every closed shape on a WHOLE layer at once).
/// Fills exactly ONE selected closed shape's interior with a solid HATCH on
/// its OWN layer, so a user can hatch/shade a specific room/zone/region
/// without having to first isolate it onto its own layer the way
/// `ShadeLayer` requires.
///
/// Reuses `ShadeLayer.closedLoop(for:store:)` for boundary extraction
/// (closed LWPOLYLINE/POLYLINE2D with bulge-arc expansion, CIRCLE, full-sweep
/// ELLIPSE) rather than re-deriving a second notion of "what counts as a
/// fillable closed shape" — see that function's own doc comment.
enum HatchTool {
    /// Whether `id` is currently eligible for "Fill / Hatch…" — a live,
    /// top-level-RENDERED closed shape. Gates the Properties panel button's
    /// very existence so it never appears for something that would silently
    /// no-op if clicked (an open polyline, a block-DEFINITION-owned entity
    /// that IS normally inserted elsewhere, an already-deleted one).
    ///
    /// `isOrphanRoot` — `RegenCoordinator.isOrphanRootBlock`, or `nil` when
    /// no live coordinator is available (matches every existing call site's
    /// prior behavior exactly: `h.owner.isModel || h.owner.isPaper` only) —
    /// additionally admits a shape owned by an ORPHAN-ROOT block: a block
    /// definition with real geometry that nothing anywhere INSERTs, which
    /// this project's `Regenerator` renders as if it WERE top-level content
    /// at its own base point (see `RegenCoordinator.isOrphanRootBlock`'s own
    /// doc comment for why this is the common case, not an edge case, on a
    /// real plant-layout DXF). Without this, "Fill / Hatch…" never appeared
    /// for the overwhelming majority of a real drawing's closed shapes —
    /// reported as "it isn't visible/displaying in the properties pane when
    /// selecting enclosed objects."
    static func isFillable(_ id: EntityID, in store: EntityStore,
                           isOrphanRoot: ((Int32) -> Bool)? = nil) -> Bool {
        guard let h = store.header(id), !h.flags.contains(.deleted) else { return false }
        guard h.owner.isModel || h.owner.isPaper
                || (h.owner.isBlock && (isOrphanRoot?(h.owner.raw) ?? false)) else { return false }
        return ShadeLayer.closedLoop(for: h, store: store) != nil
    }

    /// Creates one new HATCH entity from `id`'s boundary, on the SAME layer
    /// as `id` itself (unlike `ShadeLayer`, which routes to a dedicated
    /// `<layer>-SHADED`/`NOVACAD-SHADE-<layer>` layer for a whole-layer bulk
    /// operation — a single-object fill is a much more targeted action, and
    /// keeping it on the source object's own layer means it shows/hides
    /// alongside that object rather than needing a second layer toggled).
    /// Defaults to a solid fill at 0% transparency — matching this
    /// function's original (pre-Hatch-Settings) always-solid behavior
    /// exactly, so every existing call site (and `HatchToolTests`, which
    /// asserts `hp.isSolid` unconditionally) is unaffected; the Properties
    /// panel's Hatch Settings row lets a user change style/density/
    /// transparency/color on the created hatch afterward via ordinary
    /// `tx.modifyPayload`/`tx.modifyHeader` calls (see `PropertiesPanel
    /// .hatchSettingsRow`), the same pattern `hatchTransparencyRow` already
    /// established. Returns the new hatch's id, or nil if `id` isn't
    /// fillable.
    @discardableResult
    static func hatch(_ id: EntityID, in parsed: EditableParsedDocument, tx: Transaction,
                      style: HatchStyle = .solid) -> EntityID? {
        let store = parsed.store
        guard let h = store.header(id), !h.flags.contains(.deleted) else { return nil }
        guard let loop = ShadeLayer.closedLoop(for: h, store: store) else { return nil }
        let centroid = loop.reduce(Vec3(x: 0, y: 0)) { Vec3(x: $0.x + $1.x / Double(loop.count),
                                                            y: $0.y + $1.y / Double(loop.count)) }
        let patternId = style == .solid ? Int32(-1) : store.strings.intern(HatchStyle.diagonalPatternName)
        let payload = HatchPayload(patternNameId: patternId, isSolid: style == .solid,
                                   angle: 45, scale: 1, origin: centroid)
        let proto = EntityPrototype(type: .hatch, layerId: h.layerId, aci: h.aci, trueColor: h.trueColor,
                                    owner: h.owner, payload: .hatch(payload, loops: [loop]))
        return tx.add(proto)
    }
}
