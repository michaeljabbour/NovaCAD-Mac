//
//  CurrentProperties.swift
//  DWGViewer / Editing
//
//  Phase 6.3 — the "current properties" AutoCAD applies to every NEWLY
//  authored entity: CLAYER (current layer), CECOLOR (current color,
//  BYLAYER by default), CELTYPE (current linetype, BYLAYER by default),
//  CELTSCALE (current linetype scale), plus the current text style/height
//  used by TEXT-family entities. One instance lives on `DocumentSession`
//  (`session.currentProperties`) — a single, per-document (not per-app)
//  value, since CLAYER/CECOLOR are genuinely drawing-scoped state in real
//  AutoCAD (stored in the DWG/DXF header itself, group $CLAYER etc.), not a
//  global user preference like `AppSettings.markupColor`.
//
//  Scope decision (see the plan's own text, "decide in-session"): the
//  legacy hand-drawn "Draw" tools (LINE/PLINE/CIRCLE/ARC/RECT/POLYGON/TEXT/
//  STAMP) predate CurrentProperties and have their own well-established
//  "always goes on NOVACAD-MARKUP, colored by `AppSettings.markupColor`"
//  behavior, exercised by real users already — changing that now would be
//  a surprising regression with no user-visible upside. The NEW Phase 6.3
//  entity tools (ELLIPSE/POINT/SPLINE/FACE3D/REGION) are genuinely new
//  surface area with no prior "always markup, always red" convention to
//  preserve, so they honor `CurrentProperties` fully: CLAYER for the
//  target layer (defaulting to NOVACAD-MARKUP the first time a document is
//  opened, so a user who never touches CLAYER still gets the familiar
//  "new stuff shows up highlighted on my markup layer" behavior), CECOLOR/
//  CELTYPE/CELTSCALE for appearance. This means: old tools ignore
//  CurrentProperties entirely (unchanged behavior); new tools honor it
//  fully; CLAYER itself can be changed via the command bar (`CLAYER` command,
//  mirroring how `pendingSetVar` already lets a user type a sysvar name then
//  its new value) or via the Layers panel's current-layer dropdown, and
//  doing so does NOT retroactively affect already-drawn markup.
//

import Foundation

/// The current-properties bundle new entities are created with. `layerName`
/// (not a raw `Int32` layer id) is the source of truth — ids can be
/// reassigned across a reload (a fresh `EditableParsedDocument` renumbers
/// layers from the file), matching how `ReloadSnapshot` already tracks
/// hidden/locked layers BY NAME rather than by id for exactly this reason.
struct CurrentProperties: Equatable {
    /// CLAYER — the name of the layer new entities are created on. Resolved
    /// to a live `Int32` id via `resolvedLayerId(in:)` at the point of use
    /// (creating it if it doesn't exist yet, mirroring `MarkupStore.
    /// ensureLayer`'s own find-or-create convention) rather than cached,
    /// since the whole point of storing this by name is to survive a reload
    /// where ids get renumbered.
    var layerName: String = MarkupStore.layerName

    /// CECOLOR — ACI 1-255 for an explicit color, or `nil` for BYLAYER (256),
    /// AutoCAD's own CECOLOR default. `0` (BYBLOCK) is deliberately not
    /// representable here — "current color while drawing a brand-new,
    /// top-level entity" has no enclosing block context for BYBLOCK to
    /// inherit from, so it would be meaningless (AutoCAD itself doesn't let
    /// you set CECOLOR to BYBLOCK either).
    var color: Int16? = nil

    /// CELTYPE — a linetype NAME, or `nil` for BYLAYER (AutoCAD's default).
    /// Stored by name (not a resolved `Int16` linetype id) for the same
    /// reload-survives-renumbering reason as `layerName`.
    var linetypeName: String? = nil

    /// CELTSCALE — current entity linetype scale factor. AutoCAD default 1.0.
    var linetypeScale: Double = 1.0

    /// Current text style NAME for new TEXT/MTEXT-family entities. Empty
    /// string (not "STANDARD" literally) mirrors `TextPayload.styleNameId
    /// == -1`'s own "no distinct style interned" convention — resolved to
    /// -1 at the point of use, exactly like a parsed entity with no style
    /// override.
    var textStyleName: String = ""

    /// Current default text height for new TEXT/ATTDEF-family entities
    /// placed by the Phase 6.3 tools that need a height with no other
    /// natural source (SPLINE/POINT/ELLIPSE have none; this exists for
    /// forward compatibility with any future MTEXT/DTEXT-via-CurrentProperties
    /// path). AutoCAD's own TEXTSIZE default is 2.5 (metric) / 0.2 (imperial)
    /// drawing units; 2.5 is used here as a unit-agnostic, harmless default
    /// since NovaCAD doesn't yet branch default sizes on $MEASUREMENT for
    /// any other tool either (the legacy TEXT tool derives its height from
    /// the live view scale instead — see `ContentView`'s `18 / zoom`).
    var textHeight: Double = 2.5

    /// Resolves `layerName` to a live layer id in `parsed`, creating the
    /// layer (via `MarkupStore.ensureLayer`) if it doesn't exist yet — so
    /// CLAYER can legitimately name a layer that hasn't been drawn on yet
    /// this session (mirrors AutoCAD's own CLAYER, which can be set to any
    /// existing layer name; creating a BRAND NEW one is normally done via a
    /// separate LAYER command, but silently creating it here is strictly
    /// more forgiving than crashing/no-op'ing, and this app has no separate
    /// "create an empty layer" command yet).
    func resolvedLayerId(in parsed: EditableParsedDocument) -> Int32 {
        MarkupStore.ensureLayer(named: layerName, in: parsed)
    }

    /// Resolves `linetypeName` to a live `Int16` linetype id, or -1
    /// (BYLAYER) when `linetypeName` is nil OR names a linetype the
    /// document doesn't define (rather than crashing/creating a fake
    /// linetype — unlike layers, this app has no "create a new linetype at
    /// runtime" concept anywhere, so an unresolvable name silently falls
    /// back to BYLAYER, matching how a stale/renamed CELTYPE would behave
    /// in AutoCAD after an xref/reload changes the LTYPE table).
    func resolvedLinetypeId(in parsed: EditableParsedDocument) -> Int16 {
        guard let name = linetypeName else { return -1 }
        // `linetypeIdByName` is keyed by the SAME uppercased form
        // `EntityStoreParser` interns names under (see that file's own
        // `.uppercased()` call sites) — uppercase here too so a
        // case-insensitively-typed CELTYPE command still resolves.
        return parsed.linetypeIdByName[name.uppercased()] ?? -1
    }

    /// ACI for a brand-new entity's header — 256 (BYLAYER) when `color` is
    /// nil, else the explicit ACI.
    var aciOrByLayer: Int16 { color ?? 256 }
}
