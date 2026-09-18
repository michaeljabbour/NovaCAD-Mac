import Foundation

/// Phase 5.1: which native macOS menu (`MainMenuCommands`) and/or ribbon
/// group (`RibbonView`) a command belongs under. Purely a UI-grouping
/// classification, modeled loosely on AutoCAD's own classic menu layout
/// (Draw/Modify/Insert/Format/Tools) — it has NO effect on command
/// resolution/parsing (`CommandParser`/`resolve`/`complete` are unchanged by
/// this field's existence). Additive only.
enum MenuPath: String, CaseIterable {
    case file
    case edit
    case view
    case insert
    case format
    case tools
    case draw
    case dimension
    case modify
}

/// One entry in the command registry: a canonical drafting/measurement
/// command, every short alias AutoCAD-style users might type for it, a set
/// of fuzzy search-only synonyms (matched by the "/" autocomplete, never
/// resolved as a command themselves), a short human label, and the
/// `CommandAction` it produces (the SAME enum `CommandParser`/`ContentView`
/// already dispatch on — see DraftingTools.swift).
struct CommandSpec: Identifiable {
    var id: String { name }
    /// Canonical uppercase form, e.g. "LINE".
    let name: String
    /// All uppercase. May be empty if the canonical name is the only way to
    /// type this command.
    let aliases: [String]
    /// Fuzzy search-only terms — contribute to "/" popover matching but are
    /// never themselves resolved by `resolve(_:)`.
    let synonyms: [String]
    /// Short human label shown in the "/" popover, e.g. "Line".
    let desc: String
    let action: CommandAction
    /// Phase 5.1: which menu/ribbon group this command is filed under. Every
    /// entry below sets this explicitly (no default) so a future addition to
    /// `CommandRegistry.all` can't silently land in the wrong menu by
    /// omission.
    let menuPath: MenuPath
}

/// Single source of truth for every drafting/measurement command the command
/// bar recognizes. `CommandParser.parse` resolves tokens through this
/// registry instead of its own inline switch; the "/" autocomplete popover
/// also sources its suggestions from here (see `complete(prefix:limit:)`).
///
/// NOTE: the toolbar's `Menu` block and the right-click context menu in
/// ContentView.swift are intentionally NOT consolidated onto this registry —
/// they carry bespoke per-button disabled-state logic that isn't safe to
/// fold in yet. Only the "/" command-bar autocomplete and `CommandParser`
/// itself route through `CommandRegistry`.
enum CommandRegistry {

    static let all: [CommandSpec] = [
        CommandSpec(name: "LINE", aliases: ["L"], synonyms: ["draw"],
                    desc: "Line", action: .tool(.line), menuPath: .draw),
        CommandSpec(name: "PLINE", aliases: ["PL", "POLYLINE"], synonyms: [],
                    desc: "Polyline", action: .tool(.polyline), menuPath: .draw),
        CommandSpec(name: "CIRCLE", aliases: ["C"], synonyms: [],
                    desc: "Circle", action: .tool(.circle), menuPath: .draw),
        CommandSpec(name: "ARC", aliases: ["A"], synonyms: ["3 point"],
                    desc: "Arc, 3 points", action: .tool(.arc3pt), menuPath: .draw),
        CommandSpec(name: "RECTANGLE", aliases: ["REC", "RECT"], synonyms: ["box"],
                    desc: "Rectangle", action: .tool(.rect), menuPath: .draw),
        CommandSpec(name: "POLYGON", aliases: ["POL"], synonyms: [],
                    desc: "Polygon", action: .tool(.polygon), menuPath: .draw),
        // "T"/"TEXT"/"MT"/"MTEXT"/"DT"/"DTEXT" all map to the same text-note
        // tool today — preserved exactly. TEXT is the canonical name; the
        // rest are aliases of it.
        CommandSpec(name: "TEXT", aliases: ["T", "MT", "MTEXT", "DT", "DTEXT"],
                    synonyms: ["note", "label"],
                    desc: "Text note", action: .tool(.text), menuPath: .draw),
        CommandSpec(name: "ERASE", aliases: ["E"], synonyms: ["delete"],
                    desc: "Erase markup", action: .tool(.erase), menuPath: .modify),
        CommandSpec(name: "MOVE", aliases: ["M"], synonyms: [],
                    desc: "Move", action: .moveTool, menuPath: .modify),
        // Phase 4.2: COPY/ROTATE/SCALE/MIRROR. No conflicts with existing
        // single letters (E=ERASE, A=ARC, C=CIRCLE, L=LINE, M=MOVE unchanged)
        // — CO/RO/SC/MI are all two-letter aliases specifically to avoid
        // colliding with those. During an active modify command's
        // `.selecting` phase, ContentView intercepts the bare single
        // letters W/C/F/ALL/P/L/R/A/U itself (SelectionPrompt tokens) BEFORE
        // they ever reach this registry — see executeCommand's dedicated
        // guard — so C/L/A here never actually shadow SelectionPrompt's own
        // C(rossing)/L(ast)/A(dd) tokens in practice.
        CommandSpec(name: "COPY", aliases: ["CO", "CP"], synonyms: ["duplicate"],
                    desc: "Copy", action: .modify(.copy), menuPath: .modify),
        CommandSpec(name: "ROTATE", aliases: ["RO"], synonyms: ["turn"],
                    desc: "Rotate", action: .modify(.rotate), menuPath: .modify),
        CommandSpec(name: "SCALE", aliases: ["SC"], synonyms: ["resize"],
                    desc: "Scale", action: .modify(.scale), menuPath: .modify),
        CommandSpec(name: "MIRROR", aliases: ["MI"], synonyms: ["flip", "reflect"],
                    desc: "Mirror", action: .modify(.mirror), menuPath: .modify),
        // Phase 4.3: TRIM/EXTEND. TR/EX are both two-letter, so they can't
        // collide with any top-level single-letter command (E=ERASE is the
        // only single-letter command starting with E, unaffected by EX being
        // two letters). During an active TRIM/EXTEND boundary-acquisition
        // prompt (`trimExtendState.phase == .selectingBoundaries`), the SAME
        // pre-registry W/C/F/ALL/P/L/R/A/U guard `executeCommand` already
        // uses for ModifyToolState's `.selecting` phase intercepts those
        // tokens before they ever reach this registry — see
        // `ContentView.executeCommand`'s shared guard, extended to check
        // `trimExtendState.phase` too.
        CommandSpec(name: "TRIM", aliases: ["TR"], synonyms: ["cut"],
                    desc: "Trim", action: .trimExtend(.trim), menuPath: .modify),
        CommandSpec(name: "EXTEND", aliases: ["EX"], synonyms: ["lengthen"],
                    desc: "Extend", action: .trimExtend(.extend), menuPath: .modify),
        // STRETCH (new feature). AutoCAD's real shortcut is the single
        // letter "S", but "S" is already SAVE's shortcut in this registry
        // (see below) — SAVE's binding predates this command and changing
        // it would be a disruptive, unrelated behavior change, so STRETCH
        // is reachable only by its full name here (still autocompletable
        // via the "/" popover). "STR" is offered as a shorter alias that
        // doesn't collide with anything existing.
        CommandSpec(name: "STRETCH", aliases: ["STR"], synonyms: ["reshape", "extrude section"],
                    desc: "Stretch", action: .stretch, menuPath: .modify),
        // Phase 4.4: FILLET/CHAMFER. "F" is FILLET's canonical AutoCAD
        // shortcut and is NOT bound to anything else at the registry level
        // (confirmed by grep before adding this) — its only potential
        // collision is with SelectionPrompt's OWN "F" (fence) sub-token,
        // which is consumed by ContentView's pre-registry guard ONLY while
        // a modify/trim-extend `SelectionPrompt` is actively pending (see
        // executeCommand's dedicated guard) — FILLET/CHAMFER's own
        // `FilletChamferToolState` never constructs a `SelectionPrompt` at
        // all (its 2-click gesture has no boundary-acquisition step), so
        // that guard is never active while typing "F" to START Fillet,
        // and "F" always reaches this registry entry in that context.
        CommandSpec(name: "FILLET", aliases: ["F"], synonyms: ["round", "corner"],
                    desc: "Fillet", action: .filletChamfer(.fillet), menuPath: .modify),
        CommandSpec(name: "CHAMFER", aliases: ["CHA"], synonyms: ["bevel"],
                    desc: "Chamfer", action: .filletChamfer(.chamfer), menuPath: .modify),
        // Phase 4.5: OFFSET. "O" is not bound elsewhere at the registry level.
        CommandSpec(name: "OFFSET", aliases: ["O"], synonyms: ["parallel"],
                    desc: "Offset", action: .offset, menuPath: .modify),
        // Phase 6.1: BLOCK/INSERT/ATTDEF/ATTEDIT. "B"/"I" are AutoCAD's own
        // canonical shortcuts and are NOT bound to anything else at the
        // registry level (confirmed by grep before adding these, same
        // process as FILLET's "F" above) — their only potential collision is
        // with SelectionPrompt's OWN sub-tokens (B is not one of
        // W/C/F/ALL/P/L/R/A/U, so no collision exists at all; "I" likewise).
        CommandSpec(name: "BLOCK", aliases: ["B"], synonyms: ["make block", "define block"],
                    desc: "Block", action: .blockCommand(.block), menuPath: .insert),
        CommandSpec(name: "INSERT", aliases: ["I"], synonyms: ["place block"],
                    desc: "Insert", action: .blockCommand(.insert), menuPath: .insert),
        CommandSpec(name: "ATTDEF", aliases: ["ATT"], synonyms: ["attribute definition"],
                    desc: "Attribute definition", action: .attdef, menuPath: .draw),
        CommandSpec(name: "ATTEDIT", aliases: ["ATE"], synonyms: ["edit attributes"],
                    desc: "Edit attributes", action: .attedit, menuPath: .modify),
        // Phase 6.2: EXPLODE. "X" is AutoCAD's own canonical shortcut and is
        // NOT bound to anything else at the registry level.
        CommandSpec(name: "EXPLODE", aliases: ["X"], synonyms: ["break apart", "ungroup"],
                    desc: "Explode", action: .explode, menuPath: .modify),
        // JOIN (new feature). "J" is AutoCAD's own canonical JOIN shortcut
        // and is not a SelectionPrompt sub-token (W/C/F/ALL/P/L/R/A/U) nor
        // bound to anything else in this registry (confirmed by grep), so
        // it never shadows an acquisition-phase token the way C/L/A could —
        // same alias-collision discipline documented throughout this file.
        CommandSpec(name: "JOIN", aliases: ["J"], synonyms: ["merge", "combine", "connect"],
                    desc: "Join", action: .join, menuPath: .modify),
        // Phase 6.3: new drafting entity tools. "EL" is AutoCAD's own
        // ELLIPSE shortcut and doesn't collide with anything registered
        // above (confirmed by grep, same process as every other alias in
        // this file). "PO" for POINT avoids colliding with "P" (a
        // SelectionPrompt sub-token, per this file's own established
        // pattern of choosing 2-letter aliases specifically to dodge that
        // collision — see FILLET/OFFSET's comments above).
        CommandSpec(name: "ELLIPSE", aliases: ["EL"], synonyms: ["oval"],
                    desc: "Ellipse", action: .tool(.ellipse), menuPath: .draw),
        CommandSpec(name: "POINT", aliases: ["PO"], synonyms: ["node"],
                    desc: "Point", action: .tool(.pointEnt), menuPath: .draw),
        // SPLINE always starts in fit-point mode; the CV (control-vertex)
        // variant has no separate AutoCAD top-level command name of its own
        // (real AutoCAD's SPLINE prompts "Method: Fit/CV" as a sub-option) —
        // exposed here as a distinct registry entry anyway (SPLINECV) since
        // this app's command bar has no interactive sub-option prompt yet,
        // matching how POLYGON's side count is a separate typed step rather
        // than a sub-prompt.
        CommandSpec(name: "SPLINE", aliases: ["SPL"], synonyms: ["curve", "fit spline"],
                    desc: "Spline (fit points)", action: .tool(.splineFit), menuPath: .draw),
        CommandSpec(name: "SPLINECV", aliases: [], synonyms: ["control vertex spline"],
                    desc: "Spline (control vertices)", action: .tool(.splineCV), menuPath: .draw),
        CommandSpec(name: "3DFACE", aliases: ["3DF"], synonyms: ["face"],
                    desc: "3D Face", action: .tool(.face3d), menuPath: .draw),
        CommandSpec(name: "REGION", aliases: ["REG"], synonyms: [],
                    desc: "Region (from closed curve)", action: .tool(.region), menuPath: .draw),
        // Phase 6.4: ARRAY. "AR" is AutoCAD's own shortcut; the rect/polar
        // sub-type is chosen via the command-bar prompt this command opens
        // (mirroring FILLET's D/A-keyword style sub-prompts), not via a
        // separate registry entry per type.
        CommandSpec(name: "ARRAY", aliases: ["AR"], synonyms: ["pattern", "repeat"],
                    desc: "Array", action: .array, menuPath: .modify),
        // Phase 6.3: CLAYER — sets the current layer (see
        // CurrentProperties.swift). Distinct from the SETVAR shortcut path
        // (CLAYER isn't a registered SysVar — see that file's header
        // comment) but follows the exact same "type the name, then the
        // next submission is the new value" two-step UX, via its own
        // pending-entry state (`pendingClayerEntry`) rather than piggy-
        // backing on `pendingSetVar` (which is typed against `SysVars`,
        // not `CurrentProperties`).
        CommandSpec(name: "CLAYER", aliases: [], synonyms: ["current layer"],
                    desc: "Set current layer", action: .clayer, menuPath: .format),
        CommandSpec(name: "DISTANCE", aliases: ["DI", "DIST"], synonyms: ["measure"],
                    desc: "Measure distance", action: .measureDistance, menuPath: .dimension),
        CommandSpec(name: "AREA", aliases: ["AA"], synonyms: [],
                    desc: "Measure area", action: .measureArea, menuPath: .dimension),
        // "RAD"/"RADIUS"/"DIAMETER"/"DIA" all map to the same radius/diameter
        // measurement tool today — preserved exactly. RADIUS is canonical.
        CommandSpec(name: "RADIUS", aliases: ["RAD", "DIAMETER", "DIA"], synonyms: [],
                    desc: "Measure radius", action: .measureRadius, menuPath: .dimension),
        CommandSpec(name: "ANGLE", aliases: ["ANG"], synonyms: [],
                    desc: "Measure angle", action: .measureAngle, menuPath: .dimension),
        // Real, persistent DIMENSION entities (linear/aligned) — matches
        // AutoCAD's own DIMLINEAR/DIMALIGNED command names exactly.
        CommandSpec(name: "DIMLINEAR", aliases: ["DLI"], synonyms: ["linear dimension"],
                    desc: "Linear dimension", action: .dimension(.linear), menuPath: .dimension),
        CommandSpec(name: "DIMALIGNED", aliases: ["DAL"], synonyms: ["aligned dimension"],
                    desc: "Aligned dimension", action: .dimension(.aligned), menuPath: .dimension),
        CommandSpec(name: "ZOOM", aliases: ["Z", "ZE"], synonyms: ["fit"],
                    desc: "Zoom fit", action: .zoomFit, menuPath: .view),
        // "ESC"/"CANCEL"/"SEL"/"SELECT" all map to selectMode today —
        // preserved exactly (pre-Phase-4.2 behavior for ESC/CANCEL/SEL
        // unchanged). SEL is the canonical name (it's the one that reads as
        // an actual command name rather than a keyboard-escape synonym).
        // "SELECT" is registered per the Phase 4.1 plan as an alias of the
        // SAME action — AutoCAD's real SELECT command builds a standalone
        // selection set without launching any other command, which this
        // app doesn't have a distinct mode for yet (plain Select mode
        // already IS "build a selection with no other command running");
        // a future session could split them if that distinction ever
        // matters here.
        CommandSpec(name: "SEL", aliases: ["ESC", "CANCEL", "SELECT"], synonyms: [],
                    desc: "Select mode", action: .selectMode, menuPath: .edit),
        // Cross-drawing Copy/Paste (new feature). Named "COPYCLIP"/
        // "PASTECLIP" (AutoCAD's own real command names for the ⌘C/⌘V-
        // equivalent clipboard commands) rather than bare "COPY"/"PASTE" —
        // "COPY" is already registered above (line ~92) for the existing
        // interactive same-drawing multi-copy tool (`.modify(.copy)`), and
        // giving these two DIFFERENT commands the same canonical name would
        // make `CommandRegistry.resolve("COPY")` ambiguous. "CTRLC"/"CTRLV"
        // are added as memorable aliases for command-bar users, distinct
        // from the menu's own ⌘C/⌘V keyboard shortcuts (`MainMenuCommands`'s
        // `CommandGroup(replacing: .pasteboard)`).
        CommandSpec(name: "COPYCLIP", aliases: ["CTRLC"], synonyms: ["copy to clipboard", "copy for paste"],
                    desc: "Copy (for pasting into another drawing)", action: .clipboardCopy, menuPath: .edit),
        CommandSpec(name: "PASTECLIP", aliases: ["CTRLV"], synonyms: ["paste from clipboard"],
                    desc: "Paste", action: .clipboardPaste, menuPath: .edit),
        CommandSpec(name: "CLOSE", aliases: [], synonyms: [],
                    desc: "Close polyline", action: .closePolyline, menuPath: .draw),
        CommandSpec(name: "UNDO", aliases: ["U"], synonyms: [],
                    desc: "Undo", action: .undo, menuPath: .edit),
        // Phase 3.2: real Save/Save As, writing every live edit (not just
        // markup) through `DXFStructuralWriter` — see `ContentView.
        // saveDrawing`/`saveDrawingAs`. `.file` was previously an unpopulated
        // `MenuPath` case (its native-menu `CommandGroup` was removed as
        // dead scaffolding — see `App/MainMenuCommands.swift` git history);
        // these two entries are what it was reserved for.
        CommandSpec(name: "SAVE", aliases: ["S"], synonyms: ["save drawing"],
                    desc: "Save", action: .save, menuPath: .file),
        CommandSpec(name: "SAVEAS", aliases: ["SA"], synonyms: ["save as", "save drawing as"],
                    desc: "Save As…", action: .saveAs, menuPath: .file),
        // Data Extraction (AutoCAD DATAEXTRACTION / "DX"). Filed under
        // `.file` (which already renders a native menu) rather than
        // `.tools` (which has no CommandMenu — see `MainMenuCommands`) since
        // export/import to a CSV file is naturally a File-menu concern.
        // "DATAEXTRACTION"/"DX" are AutoCAD's own names; import has no
        // native AutoCAD command so "DATAIMPORT"/"DXI" are our own,
        // discoverable synonyms.
        CommandSpec(name: "DATAEXTRACTION", aliases: ["DX"],
                    synonyms: ["extract data", "export attributes", "export data to csv", "attributes to csv"],
                    desc: "Extract Data…", action: .extractData, menuPath: .file),
        CommandSpec(name: "DATAIMPORT", aliases: ["DXI"],
                    synonyms: ["import data", "import attributes", "import data from csv", "csv to attributes", "bulk edit attributes"],
                    desc: "Import Data…", action: .importData, menuPath: .file),
    ]

    /// PGP aliases loaded from the user's acad.pgp, overlaid on top of the
    /// built-in alias table. Maps an alias token -> canonical command NAME
    /// (not directly to a CommandSpec, so a reload never has to worry about
    /// stale spec references). Checked FIRST by `resolve(_:)` when the token
    /// isn't an exact canonical-name match, so a pgp line can repoint which
    /// command a short code invokes, but can never rename or hide a
    /// canonical NAME itself (typing "LINE" in full always means Draw Line).
    private static var userAliasOverrides: [String: String] = [:]

    /// Rebuilds `userAliasOverrides` from the user's acad.pgp. Unknown target
    /// commands (a typo, or an alias to something CommandRegistry doesn't
    /// know) are silently ignored — never crashes, never leaves the table in
    /// a partially-applied state.
    static func reloadUserAliases(from url: URL) {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            userAliasOverrides = [:]
            return
        }
        var overrides: [String: String] = [:]
        for (alias, command) in PGPFile.parseAliases(text) {
            let aliasU = alias.uppercased()
            let commandU = command.uppercased()
            guard all.contains(where: { $0.name == commandU }) else { continue }
            overrides[aliasU] = commandU
        }
        userAliasOverrides = overrides
    }

    /// Exact canonical name match first, then user pgp alias overrides, then
    /// built-in alias match. Case-insensitive (call site is expected to have
    /// already uppercased, but this uppercases defensively too).
    static func resolve(_ token: String) -> CommandSpec? {
        let t = token.uppercased()
        guard !t.isEmpty else { return nil }
        if let exact = all.first(where: { $0.name == t }) { return exact }
        if let target = userAliasOverrides[t] {
            return all.first { $0.name == target }
        }
        return all.first { $0.aliases.contains(t) }
    }

    /// Prefix match over name+aliases first; if that doesn't fill `limit`,
    /// add synonym prefix matches (deduped by command name, name/alias
    /// matches take priority over synonym matches). Empty prefix returns the
    /// first `limit` entries in declaration order.
    static func complete(prefix: String, limit: Int) -> [CommandSpec] {
        let p = prefix.uppercased()
        guard !p.isEmpty else { return Array(all.prefix(limit)) }

        var results: [CommandSpec] = []
        var seen = Set<String>()

        for spec in all {
            guard !seen.contains(spec.name) else { continue }
            if spec.name.hasPrefix(p) || spec.aliases.contains(where: { $0.hasPrefix(p) }) {
                results.append(spec)
                seen.insert(spec.name)
                if results.count >= limit { return results }
            }
        }
        for spec in all {
            guard !seen.contains(spec.name) else { continue }
            if spec.synonyms.contains(where: { $0.uppercased().hasPrefix(p) }) {
                results.append(spec)
                seen.insert(spec.name)
                if results.count >= limit { return results }
            }
        }
        return results
    }
}
