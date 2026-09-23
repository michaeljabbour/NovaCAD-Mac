import CADCore
import SwiftUI

/// Phase 5.1: the read-only entity Properties panel + its minimized tab,
/// extracted VERBATIM out of `ContentView`'s old `propertiesPanel`/
/// `minimizedPropertiesTab` (see git history) — same header, same
/// minimize/deselect buttons, same scrolling property list, just moved into
/// its own file with explicit parameters instead of reading `ContentView`'s
/// private state directly. Shown when the current selection is NOT markup
/// (see `MarkupPropertiesPanel` below for the editable markup counterpart).
struct PropertiesPanel: View {
    private let englishNames = true
    @ObservedObject var session: DocumentSession
    let document: DXFDocument?
    let selectionCount: Int
    let mergedProperties: [EntityProperty]
    @Binding var propertiesMinimized: Bool
    @Binding var selection: Set<EntityID>
    /// Units/precision for the editable block-geometry fields — same format
    /// the read-only rows are rendered with, so a value the user reads out of
    /// a field can be typed straight back into it. Defaults so existing call
    /// sites/tests that don't care about the block editor still compile.
    var format: MeasureFormat = MeasureFormat()

    @State private var showingColorPicker = false
    /// Drives the theme-aware color swatch — `.foreground` (ACI 7) must read
    /// as black on a light panel and white on a dark one.
    @Environment(\.colorScheme) private var colorScheme

    private var regen: RegenCoordinator? { session.regen }

    /// The single selected BLOCK REFERENCE, if the selection is exactly one
    /// live INSERT — the gate for the editable `BlockPropertiesEditor` below.
    /// Multi-selection deliberately keeps the merged read-only view: typing
    /// one ABSOLUTE position into N blocks would stack them all at the same
    /// point, which is essentially never intended (MOVE with a delta already
    /// covers the "shift them all" case).
    private var singleSelectedInsertId: EntityID? {
        guard selection.count == 1, let id = selection.first, let regen else { return nil }
        guard let h = regen.parsed.store.header(id), h.type == .insert,
              !h.flags.contains(.deleted) else { return nil }
        return id
    }

    /// Property rows already covered by an EDITABLE control, so they aren't
    /// duplicated below as read-only text. "Layer" is always editable via the
    /// dropdown; the block rows only when a lone INSERT is selected (and the
    /// ATTRIB rows, which `HitTester.properties` names directly after each
    /// tag, are filtered dynamically since their names are data-dependent).
    private var rowsHandledByEditors: Set<String> {
        var handled: Set<String> = ["Layer"]
        guard let insertId = singleSelectedInsertId, let regen else { return handled }
        handled.formUnion(["Type", "Name", "Position X", "Position Y",
                           "Scale X", "Scale Y", "Rotation"])
        for attr in BlockEditor.attributes(of: insertId, in: regen.parsed.store) {
            handled.insert(attr.tag)
        }
        return handled
    }

    /// Every layer name in the current document, sorted — the dropdown's
    /// full candidate list (matches the Layers panel's own "Current layer"
    /// picker source, `clayerPickerNames`, which likewise just lists every
    /// `doc.layers` name).
    private var layerNames: [String] {
        guard let doc = document else { return [] }
        return doc.layers.map(\.name).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// The layer name to show/edit for the CURRENT (possibly multi-entity,
    /// possibly non-markup) selection — mirrors `MarkupPropertiesPanel
    /// .markupLayerBinding`'s exact "read every selected entity's layer
    /// name; show it if they all agree, else a 'Various' placeholder"
    /// shape, generalized from `selectedMarkupIDs` to the full `selection`
    /// (this panel, unlike the markup one, is shown for ANY non-markup
    /// selection — ordinary parsed-file geometry included). The underlying
    /// write path (`Transaction.modifyHeader`) already operates on any
    /// `EntityID`, not just markup, so no new mutation machinery is needed
    /// — only this panel lacked an editable control for it until now.
    private var layerBinding: Binding<String> {
        Binding(
            get: {
                guard let regen, let doc = document else { return EntityProperty.variesValue }
                // Reads each selected entity's RESOLVED/effective layer —
                // NOT `EntityHeader.layerId` directly — via the exact same
                // `resolveToRefs`/`InsertInstance.layerId`/`RenderGroup
                // .layerId` path `HitTester.properties(for:)`'s read-only
                // "Layer" row already uses (see that function's own
                // `layerName(...)` calls). This was a real bug: block-
                // internal geometry (overwhelmingly common in xref content,
                // where source authoring convention draws on layer "0" so
                // it inherits the owning INSERT's layer via BYLAYER
                // substitution) genuinely has a STORED layerId of 0 — that
                // part of the store is correct — but 0 is not what the
                // entity actually renders/reports as once
                // `PropertyResolver.resolve`'s layer-0-substitution and any
                // xref-dependent layer renaming are applied. Reading the raw
                // header made the dropdown show "0" for essentially every
                // xref'd object regardless of which xref/layer it was
                // logically on, while the read-only rows elsewhere in this
                // same panel (and the renderer) showed the correct resolved
                // name — reported verbatim: "whenever i click an xref
                // object, the layer always says '0' in properties."
                let refs = regen.resolveToRefs(selection)
                var names: Set<String> = []
                for ref in refs {
                    switch ref {
                    case .insert(let idx):
                        guard Int(idx) < doc.inserts.count else { continue }
                        let layerId = Int(doc.inserts[Int(idx)].layerId)
                        guard layerId < doc.layers.count else { continue }
                        names.insert(doc.layers[layerId].name)
                    case .primitive(let gi, _, _):
                        let groups = session.space == .paper ? doc.paperGroups : doc.modelGroups
                        guard Int(gi) < groups.count else { continue }
                        let layerId = Int(groups[Int(gi)].layerId)
                        guard layerId < doc.layers.count else { continue }
                        names.insert(doc.layers[layerId].name)
                    }
                }
                return names.count == 1 ? (names.first ?? EntityProperty.variesValue)
                                        : EntityProperty.variesValue
            },
            set: { newValue in
                guard let regen, newValue != EntityProperty.variesValue,
                      let layerId = regen.parsed.layerIdByName[newValue] else { return }
                let ids = selection
                session.performEdit("Change Layer") { tx in
                    for id in ids { tx.modifyHeader(id) { $0.layerId = layerId } }
                }
            }
        )
    }

    /// The single selected FILLABLE closed shape, if there is exactly one —
    /// gates the "Fill / Hatch…" button. Multi-selection is out of scope
    /// (same "one absolute action, not obviously N-way" rationale as
    /// `singleSelectedInsertId`): which of several selected shapes should the
    /// one new hatch attach to is ambiguous, whereas `ShadeLayer` already
    /// covers "fill every closed shape on a layer" for the bulk case.
    private var singleFillableId: EntityID? {
        guard selection.count == 1, let id = selection.first, let regen else { return nil }
        return HatchTool.isFillable(id, in: regen.parsed.store,
                                    isOrphanRoot: { regen.isOrphanRootBlock($0) }) ? id : nil
    }

    /// Every currently-selected LINE/LWPOLYLINE/POLYLINE2D/POLYLINE3D — the
    /// candidates for the "Line Weight" editor. Unlike `singleSelectedInsertId`/
    /// `singleFillableId`, this DOES support multi-selection: setting a
    /// lineweight is a "one value applied to every selected line/polyline"
    /// action (matches `applyColorToSelection`'s own multi-select shape), not
    /// an ambiguous single-target one. Non-line/polyline members of a mixed
    /// selection are simply ignored (the row itself only appears when at
    /// least one candidate is present — see `hasWeightableSelection`).
    private var weightableIds: [EntityID] {
        guard let regen else { return [] }
        return selection.filter { id in
            guard let h = regen.parsed.store.header(id), !h.flags.contains(.deleted) else { return false }
            switch h.type {
            case .line, .lwpolyline, .polyline2d, .polyline3d: return true
            default: return false
            }
        }
    }

    private var hasWeightableSelection: Bool { !weightableIds.isEmpty }

    /// The current lineweight to show in the picker: the shared value if
    /// every weightable selected entity agrees, else `nil` ("Varies").
    private var selectionLineweight: Int16? {
        guard let regen else { return nil }
        let values = Set(weightableIds.compactMap { regen.parsed.store.header($0)?.lineweight })
        return values.count == 1 ? values.first! : nil
    }

    /// The single selected HATCH, if there is exactly one — gates the
    /// per-hatch color/transparency controls (`HatchPayload.transparency` is
    /// scoped to HATCH only; see that field's own doc comment for why it
    /// isn't a generic per-entity property).
    private var singleSelectedHatchId: EntityID? {
        guard selection.count == 1, let id = selection.first, let regen else { return nil }
        guard let h = regen.parsed.store.header(id), h.type == .hatch,
              !h.flags.contains(.deleted) else { return nil }
        return id
    }

    /// Generic per-entity COLOR editor — any selected entity (not just
    /// markup), reusing `SelectColorDialog`'s existing ACI/true-color grid.
    ///
    /// Reads the RESOLVED/effective color via `PropertiesColorResolver` — NOT
    /// `EntityHeader.aci` directly. Reading the raw header was a real bug (the
    /// same class as `layerBinding`'s "layer always says 0"): a BYLAYER
    /// entity's color lives on its LAYER, a BYBLOCK entity's on its owning
    /// INSERT, and block/xref content authored on layer 0 inherits the
    /// INSERT's layer — so the raw fields describe none of them. Combined
    /// with `.foreground` being painted as literal white, the swatch showed
    /// blank white for most objects a user could click.
    private var selectionColor: ResolvedColor {
        guard let regen, let doc = document else { return .foreground }
        return PropertiesColorResolver.color(for: selection, parsed: regen.parsed,
                                             document: doc, space: session.space == .paper ? .paper : .model)
    }

    /// True when the selection holds more than one distinct color, so the
    /// swatch/label can say "Various" instead of implying a single shared one.
    private var selectionColorIsMixed: Bool {
        guard let regen, let doc = document, selection.count > 1 else { return false }
        return PropertiesColorResolver.isMixed(for: selection, parsed: regen.parsed,
                                               document: doc, space: session.space == .paper ? .paper : .model)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Properties").font(.headline)
                Spacer()
                Text(selectionCount == 1 ? "1 object" : "\(selectionCount) objects")
                    .font(.caption).foregroundColor(.secondary)
                Button {
                    propertiesMinimized = true
                } label: {
                    Image(systemName: "rectangle.rightthird.inset.filled")
                }
                .buttonStyle(.plain)
                .help("Minimize properties")
                Button {
                    selection = []
                } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .help("Deselect all (Esc)")
            }
            .padding(10)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // Editable: layer — a dropdown of every layer in the
                    // document, so any selected object (not just markup)
                    // can be retargeted onto a different layer without
                    // typing its exact name.
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Layer").font(.caption).foregroundColor(.secondary)
                        Picker("", selection: layerBinding) {
                            if layerBinding.wrappedValue == EntityProperty.variesValue {
                                Text(EntityProperty.variesValue).tag(EntityProperty.variesValue)
                            }
                            ForEach(layerNames, id: \.self) { name in
                                Text(LayerDisplayName.display(name, inEnglish: englishNames)).tag(name)
                            }
                        }
                        .labelsHidden()
                        .font(.callout)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    Divider().padding(.leading, 10)

                    // Editable: color — any selected entity (not just
                    // markup), via the same full ACI/true-color grid the
                    // Layers panel's swatch already uses. Answers a real gap:
                    // a HATCH's fill color (or any entity's own color) could
                    // only be set by-layer before this, with no per-object
                    // override reachable from the Properties panel.
                    colorRow

                    // Editable line weight/thickness — any selected LINE or
                    // polyline (LWPOLYLINE/POLYLINE2D/POLYLINE3D), single or
                    // multi-selection.
                    if hasWeightableSelection {
                        lineWeightRow
                    }

                    // "Fill / Hatch…" — turns a selected closed shape into a
                    // solid HATCH. Only offered for a single fillable shape
                    // that isn't already itself a hatch (hatching a hatch is
                    // meaningless — its own transparency/color controls,
                    // shown below instead, are the relevant action there).
                    if let fillableId = singleFillableId {
                        fillHatchButton(fillableId)
                    }

                    // Editable per-hatch transparency (independent of the
                    // layer's own — see `HatchPayload.transparency`'s doc
                    // comment) for a single selected HATCH.
                    if let hatchId = singleSelectedHatchId {
                        hatchSettingsRow(hatchId)
                    }

                    // Editable block-reference properties (name, display
                    // name, position, scale, rotation, and every ATTRIB) for
                    // a lone selected INSERT — see `BlockPropertiesEditor`.
                    if let insertId = singleSelectedInsertId {
                        BlockPropertiesEditor(session: session, insertId: insertId, format: format)
                    }

                    // Rows already covered by an editable control above are
                    // filtered out so they aren't duplicated as read-only text.
                    let handled = rowsHandledByEditors
                    ForEach(mergedProperties.filter { !handled.contains($0.name) }) { prop in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(prop.name)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(LayerDisplayName.display(prop.value, inEnglish: englishNames))
                                .font(.callout)
                                .foregroundColor(prop.value == EntityProperty.variesValue
                                                 ? .orange : .primary)
                                .textSelection(.enabled)
                                .lineLimit(3)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        Divider().padding(.leading, 10)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(width: 250)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(Rectangle().frame(width: 1).foregroundColor(.black.opacity(0.2)),
                 alignment: .leading)
        .sheet(isPresented: $showingColorPicker) {
            SelectColorDialog(
                title: "Object Color",
                initial: selectionColor,
                onApply: { newColor in
                    applyColorToSelection(newColor)
                    showingColorPicker = false
                },
                onCancel: { showingColorPicker = false }
            )
        }
    }

    @ViewBuilder
    private var colorRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Color").font(.caption).foregroundColor(.secondary)
            Button {
                showingColorPicker = true
            } label: {
                HStack(spacing: 8) {
                    // A MIXED selection gets a neutral checkerboard-ish grey
                    // rather than one member's color, which would misrepresent
                    // the others.
                    RoundedRectangle(cornerRadius: 3)
                        .fill(selectionColorIsMixed
                              ? AnyShapeStyle(.tertiary)
                              : AnyShapeStyle(Color(rgb: selectionColor
                                  .swatchDisplayRGB(darkBackground: colorScheme == .dark))))
                        .frame(width: 16, height: 16)
                        .overlay(RoundedRectangle(cornerRadius: 3)
                            .strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))
                    Text(colorLabel)
                        .font(.callout)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        Divider().padding(.leading, 10)
    }

    /// Describes the effective color. Reports the RESOLVED color name for a
    /// BYLAYER entity (e.g. "ByLayer (green)") rather than a bare "ByLayer",
    /// so the label and the swatch always agree about what is on screen, and
    /// says "Various" for a genuinely mixed selection instead of picking one
    /// member's color to speak for all of them.
    private var colorLabel: String {
        guard let regen, let id = selection.first,
              let h = regen.parsed.store.header(id) else { return "ByLayer" }
        if selectionColorIsMixed { return "Various" }
        if h.aci == 256 {
            switch selectionColor {
            case .foreground: return "ByLayer (default)"
            case .rgb(let v): return String(format: "ByLayer (#%06X)", v & 0xFFFFFF)
            }
        }
        if h.aci == 0 { return "ByBlock" }
        if (h.trueColor >> 24) != 0xFF { return String(format: "#%06X", h.trueColor & 0xFFFFFF) }
        return h.aci == 7 ? "White / Black (ACI 7)" : "Index Color \(h.aci)"
    }

    /// Writes `color` onto every selected entity's `aci`/`trueColor` header
    /// fields. An EXACT ACI-palette match is stored as a plain index color
    /// (matches `writeColor`'s own preference: cheaper to write, and how a
    /// user picking a swatch off the ACI grid would expect their choice to
    /// round-trip); anything else is stored as true color, with `aci` set to
    /// its own nearest-ACI approximation as the R12/R14-degrade fallback
    /// `writeColor` already reads (mirrors that function's existing
    /// "ACI still gets a sane fallback value alongside the true color"
    /// comment) rather than left at 256 (ByLayer), which would silently
    /// discard the user's explicit choice on a version-degraded save.
    private func applyColorToSelection(_ color: ResolvedColor) {
        guard regen != nil else { return }
        let ids = selection
        let aci: Int16
        let trueColor: UInt32
        switch color {
        case .foreground:
            aci = 7
            trueColor = 0xFF00_0000
        case .rgb(let v):
            let nearest = ACIPalette.nearestACI(forRGB: v)
            if ACIPalette.rgb(forACI: nearest) == v {
                aci = Int16(nearest)
                trueColor = 0xFF00_0000
            } else {
                aci = Int16(nearest)
                trueColor = 0xFF00_0000 | (v & 0x00FF_FFFF)
            }
        }
        session.performEdit("Change Color") { tx in
            for id in ids {
                tx.modifyHeader(id) { h in
                    h.aci = aci
                    h.trueColor = trueColor
                }
            }
        }
    }

    /// The AutoCAD-standard lineweight menu, in DXF group-370 units
    /// (hundredths of a millimeter) — the same fixed set AutoCAD's own
    /// "Lineweight" dropdown offers, so a value round-trips exactly with
    /// files authored/edited there. `nil` represents "ByLayer" (-1, the
    /// default — no explicit per-entity override).
    private static let lineweightChoices: [Int16?] = [
        nil, 0, 5, 9, 13, 15, 18, 20, 25, 30, 35, 40, 50, 53, 60, 70, 80, 90, 100, 106, 120, 140, 158, 200, 211
    ]

    private static func lineweightLabel(_ lw: Int16?) -> String {
        guard let lw else { return "ByLayer" }
        if lw == 0 { return "0.00 mm (hairline)" }
        return String(format: "%.2f mm", Double(lw) / 100)
    }

    @ViewBuilder
    private var lineWeightRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Line Weight").font(.caption).foregroundColor(.secondary)
            Picker("", selection: lineweightBinding) {
                if selectionLineweight == nil, weightableIds.count > 1,
                   Set(weightableIds.compactMap { regen?.parsed.store.header($0)?.lineweight }).count > 1 {
                    Text(EntityProperty.variesValue).tag(Int16(Int16.min))
                }
                ForEach(Self.lineweightChoices, id: \.self) { choice in
                    Text(Self.lineweightLabel(choice)).tag(choice ?? -1)
                }
            }
            .labelsHidden()
            .font(.callout)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        Divider().padding(.leading, 10)
    }

    /// `Int16.min` is used as the "Various" sentinel tag (distinct from every
    /// real lineweight value AND from -1/BYLAYER) purely for the Picker's
    /// `tag`-matching — never written back to the store (the "Various" row
    /// disappears the instant a real choice is picked, same UX as
    /// `layerBinding`'s own "Various" placeholder).
    private var lineweightBinding: Binding<Int16> {
        Binding(
            get: { selectionLineweight ?? Int16.min },
            set: { newValue in
                guard newValue != Int16.min else { return }
                let ids = weightableIds
                session.performEdit("Change Line Weight") { tx in
                    for id in ids { tx.modifyHeader(id) { $0.lineweight = newValue } }
                }
            }
        )
    }

    @ViewBuilder
    private func fillHatchButton(_ id: EntityID) -> some View {
        Button {
            guard let regen else { return }
            let newIds = session.performEdit("Fill / Hatch", selectNewEntities: true) { tx in
                HatchTool.hatch(id, in: regen.parsed, tx: tx)
            }
            _ = newIds
        } label: {
            Label("Fill / Hatch\u{2026}", systemImage: "paintbrush.fill")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .foregroundColor(.accentColor)
        .padding(.horizontal, 10).padding(.vertical, 6)
        Divider().padding(.leading, 10)
    }

    /// The current HATCH's stored payload, or `nil` if `hatchId` no longer
    /// resolves to a live HATCH — every row below reads through this rather
    /// than re-deriving the same `store.hatches[Int(h.payload)]` lookup.
    private func hatchPayload(_ hatchId: EntityID) -> HatchPayload? {
        guard let regen, let h = regen.parsed.store.header(hatchId), h.payload >= 0 else { return nil }
        return regen.parsed.store.hatches[Int(h.payload)]
    }

    /// "Hatch Settings" — Hatch Type (solid fill vs. diagonal-line pattern),
    /// Hatch Density (diagonal-line spacing, shown only when that style is
    /// selected), and Fill Transparency, for a single selected HATCH. Shading
    /// COLOR itself is deliberately NOT duplicated here — the generic
    /// `colorRow` above already edits `EntityHeader.aci`/`.trueColor` for
    /// ANY selected entity, hatches included, via the exact same "Color"
    /// row/`SelectColorDialog` a user already uses for every other object;
    /// a second color control here would just be the same value, editable
    /// twice, one of which could silently go stale relative to the other.
    @ViewBuilder
    private func hatchSettingsRow(_ hatchId: EntityID) -> some View {
        if let hp = hatchPayload(hatchId) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Hatch Settings").font(.caption).foregroundColor(.secondary)

                Picker("", selection: hatchStyleBinding(hatchId, current: hp)) {
                    Text("Solid Fill").tag(HatchStyle.solid)
                    Text("Diagonal Lines").tag(HatchStyle.diagonalLines)
                }
                .labelsHidden()
                .font(.callout)

                if !hp.isSolid {
                    let density = hp.scale > 0 ? min(max(1 / hp.scale, 0.2), 5) : 1
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Hatch Density").font(.caption).foregroundColor(.secondary)
                            Spacer()
                            Text(String(format: "%.1f\u{00d7}", density))
                                .font(.caption).monospacedDigit().foregroundColor(.secondary)
                        }
                        Slider(value: Binding(
                            get: { density },
                            set: { newValue in
                                let clampedDensity = min(max(newValue, 0.2), 5)
                                session.performEdit("Hatch Density") { tx in
                                    tx.modifyPayload(hatchId) { copy in
                                        guard case .hatch(var p, let loops) = copy else { return }
                                        p.scale = 1 / clampedDensity
                                        copy = .hatch(p, loops: loops)
                                    }
                                }
                            }
                        ), in: 0.2...5, step: 0.1)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Fill Transparency").font(.caption).foregroundColor(.secondary)
                        Spacer()
                        Text("\(Int(hp.transparency.rounded()))%")
                            .font(.caption).monospacedDigit().foregroundColor(.secondary)
                    }
                    Slider(value: Binding(
                        get: { hp.transparency },
                        set: { newValue in
                            let clamped = min(max(newValue, 0), 100)
                            session.performEdit("Fill Transparency") { tx in
                                tx.modifyPayload(hatchId) { copy in
                                    guard case .hatch(var p, let loops) = copy else { return }
                                    p.transparency = clamped
                                    copy = .hatch(p, loops: loops)
                                }
                            }
                        }
                    ), in: 0...100, step: 1)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            Divider().padding(.leading, 10)
        }
    }

    /// Writes a Hatch Type choice onto `hatchId`'s payload: `.solid` clears
    /// the pattern name (-1, matching `HatchTool.hatch`'s own solid-fill
    /// default), `.diagonalLines` interns `HatchStyle.diagonalPatternName`
    /// ("ANSI31") so the DXF round-trips with a real AutoCAD pattern name —
    /// see `HatchStyle`'s own doc comment.
    private func hatchStyleBinding(_ hatchId: EntityID, current hp: HatchPayload) -> Binding<HatchStyle> {
        Binding(
            get: { HatchStyle(isSolid: hp.isSolid) },
            set: { newStyle in
                guard let regen else { return }
                let patternId = newStyle == .solid ? Int32(-1)
                    : regen.parsed.store.strings.intern(HatchStyle.diagonalPatternName)
                session.performEdit("Change Hatch Type") { tx in
                    tx.modifyPayload(hatchId) { copy in
                        guard case .hatch(var p, let loops) = copy else { return }
                        p.isSolid = newStyle == .solid
                        p.patternNameId = patternId
                        if !p.isSolid, p.angle == 0 { p.angle = 45 }
                        copy = .hatch(p, loops: loops)
                    }
                }
            }
        )
    }
}

struct MinimizedPropertiesTab: View {
    let selectionCount: Int
    @Binding var propertiesMinimized: Bool

    var body: some View {
        Button {
            propertiesMinimized = false
        } label: {
            VStack(spacing: 6) {
                Image(systemName: "sidebar.right")
                Text("\(selectionCount)")
                    .font(.caption2).bold()
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 6)
        }
        .buttonStyle(.plain)
        .background(Color(nsColor: .windowBackgroundColor))
        .help("Show properties (\(selectionCount) selected)")
    }
}

/// Phase 5.1: the editable Markup properties panel, extracted VERBATIM out
/// of `ContentView`'s old `markupPropertiesPanel`/`selectedMarkupEntities`/
/// `markupGeometryRows`/`markupTypeName`/`markupLayerBinding` (see git
/// history) — same color menu, same editable layer text field, same
/// read-only geometry rows, same Move/Copy/Rotate/Scale/Mirror/Delete action
/// row, just moved into its own file. Shown instead of `PropertiesPanel`
/// whenever the current selection is (at least partly) markup — see
/// `ContentView.body`'s `if !selectedMarkupIDs.isEmpty` branch.
struct MarkupPropertiesPanel: View {
    @ObservedObject var session: DocumentSession
    let document: DXFDocument?
    let selectedMarkupIDs: Set<EntityID>
    let currentFormat: MeasureFormat
    let markupPalette: [(aci: Int, name: String)]
    @Binding var markupColor: Int
    @Binding var selection: Set<EntityID>
    let onStartMove: () -> Void
    let onStartModify: (ModifyCommand) -> Void
    let onDeleteSelectedMarkup: () -> Void

    private var regen: RegenCoordinator? { session.regen }

    /// Read-only `[DrawnEntity]` reconstruction of the currently-selected
    /// markup, for the editable markup properties panel below (geometry
    /// display + layer-name binding). The panel's actual EDITS (color,
    /// layer name, move, delete) go through `session.performEdit`/
    /// `Transaction` directly on the real `EntityID`s in `selectedMarkupIDs`
    /// — this array only feeds read-only display rows.
    private var selectedMarkupEntities: [DrawnEntity] {
        guard let regen else { return [] }
        let store = regen.parsed.store
        return selectedMarkupIDs.compactMap { id -> DrawnEntity? in
            guard let h = store.header(id), let shape = MarkupStore.shapeForGhost(id: id, store: store)
            else { return nil }
            var e = DrawnEntity(shape: shape)
            e.aci = h.aci == 256 ? 1 : Int(h.aci)
            e.isPaper = h.owner.isPaper
            return e
        }
    }

    /// Read-only geometry rows for the current markup selection ("Various" when
    /// values differ across a multi-selection).
    private func markupGeometryRows(_ items: [DrawnEntity]) -> [EntityProperty] {
        func merge(_ values: [String]) -> String {
            let set = Set(values)
            return set.count == 1 ? (set.first ?? "") : EntityProperty.variesValue
        }
        let fmt = currentFormat
        func L(_ v: CGFloat) -> String { fmt.length(v) }
        var rows: [EntityProperty] = []
        rows.append(EntityProperty(name: "Type", value: merge(items.map { Self.markupTypeName($0) })))
        // Show length/area for uniform-type selections only.
        if Set(items.map { Self.markupTypeName($0) }).count == 1, let first = items.first {
            switch first.shape {
            case .line(let a, let b):
                rows.append(.init(name: "Length", value: merge(items.map {
                    if case .line(let a, let b) = $0.shape { return L(hypot(b.x - a.x, b.y - a.y)) }
                    return "" })))
                rows.append(.init(name: "Angle", value: fmt.angle(atan2(b.y - a.y, b.x - a.x) * 180 / .pi)))
            case .circle(_, let r):
                rows.append(.init(name: "Radius", value: merge(items.map {
                    if case .circle(_, let r) = $0.shape { return L(r) }; return "" })))
                rows.append(.init(name: "Area", value: fmt.area(.pi * r * r)))
            case .arc(_, let r, let s, let e):
                var sweep = (e - s).truncatingRemainder(dividingBy: 360); if sweep <= 0 { sweep += 360 }
                rows.append(.init(name: "Radius", value: L(r)))
                rows.append(.init(name: "Arc Length", value: L(r * CGFloat(sweep) * .pi / 180)))
            case .rect(let a, let b):
                rows.append(.init(name: "Width", value: L(abs(b.x - a.x))))
                rows.append(.init(name: "Height", value: L(abs(b.y - a.y))))
                rows.append(.init(name: "Area", value: fmt.area(abs((b.x - a.x) * (b.y - a.y)))))
            case .polyline(let pts, let closed):
                var len: CGFloat = 0
                for i in 0..<max(0, pts.count - 1) { len += hypot(pts[i+1].x - pts[i].x, pts[i+1].y - pts[i].y) }
                if closed, pts.count > 2 { len += hypot(pts[0].x - pts.last!.x, pts[0].y - pts.last!.y) }
                rows.append(.init(name: "Vertices", value: "\(pts.count)"))
                rows.append(.init(name: "Length", value: L(len)))
            case .text(_, let h, _):
                rows.append(.init(name: "Contents", value: merge(items.map {
                    if case .text(_, _, let s) = $0.shape { return s }; return "" })))
                rows.append(.init(name: "Height", value: L(h)))
            }
        }
        return rows
    }

    /// `static` (not just `private`) because `ContentView.commitDrawn` also
    /// needs this exact mapping for its "Drew <Type>" status message —
    /// shared here rather than duplicated, since this panel is the type that
    /// otherwise owns markup-shape display logic.
    static func markupTypeName(_ e: DrawnEntity) -> String {
        switch e.shape {
        case .line: return "Line"
        case .polyline(_, let c): return c ? "Polyline (closed)" : "Polyline"
        case .circle: return "Circle"
        case .arc: return "Arc"
        case .rect: return "Rectangle"
        case .text: return "Text"
        }
    }

    var body: some View {
        let items = selectedMarkupEntities
        return VStack(spacing: 0) {
            HStack {
                Text("Markup").font(.headline)
                Spacer()
                Text(items.count == 1 ? "1 object" : "\(items.count) objects")
                    .font(.caption).foregroundColor(.secondary)
                Button { selection = [] } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain).foregroundColor(.secondary)
                .help("Deselect (Esc)")
            }
            .padding(10)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // Editable: color.
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Color").font(.caption).foregroundColor(.secondary)
                        Menu {
                            ForEach(markupPalette, id: \.aci) { entry in
                                Button {
                                    let aci = Int16(entry.aci)
                                    let ids = selectedMarkupIDs
                                    session.performEdit("Recolor") { tx in
                                        for id in ids { tx.modifyHeader(id) { $0.aci = aci } }
                                    }
                                    markupColor = entry.aci
                                } label: {
                                    Label {
                                        Text(entry.name)
                                    } icon: {
                                        Image(systemName: "square.fill")
                                            .foregroundColor(Color(rgb: ACIPalette.rgb(forACI: entry.aci)))
                                    }
                                }
                            }
                        } label: {
                            let acis = Set(items.map(\.aci))
                            HStack(spacing: 6) {
                                Image(systemName: "square.fill")
                                    .foregroundColor(acis.count == 1
                                        ? Color(rgb: ACIPalette.rgb(forACI: acis.first ?? 1))
                                        : .secondary)
                                Text(acis.count == 1
                                     ? (markupPalette.first { $0.aci == acis.first }?.name ?? "ACI \(acis.first ?? 1)")
                                     : "Various")
                            }
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    Divider().padding(.leading, 10)

                    // Editable: layer name.
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Layer").font(.caption).foregroundColor(.secondary)
                        TextField("Layer", text: markupLayerBinding)
                            .textFieldStyle(.roundedBorder)
                            .font(.callout)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    Divider().padding(.leading, 10)

                    // Read-only geometry.
                    ForEach(markupGeometryRows(items)) { prop in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(prop.name).font(.caption).foregroundColor(.secondary)
                            Text(prop.value)
                                .font(.callout)
                                .foregroundColor(prop.value == EntityProperty.variesValue ? .orange : .primary)
                                .textSelection(.enabled)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        Divider().padding(.leading, 10)
                    }

                    // Actions.
                    HStack {
                        Button { onStartMove() } label: {
                            Label("Move", systemImage: "arrow.up.and.down.and.arrow.left.and.right")
                        }
                        Button { onStartModify(.copy) } label: {
                            Image(systemName: "plus.square.on.square")
                        }.help("Copy  (CO)")
                        Button { onStartModify(.rotate) } label: {
                            Image(systemName: "rotate.right")
                        }.help("Rotate  (RO)")
                        Button { onStartModify(.scale) } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                        }.help("Scale  (SC)")
                        Button { onStartModify(.mirror) } label: {
                            Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                        }.help("Mirror  (MI)")
                        Button(role: .destructive) { onDeleteSelectedMarkup() } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(width: 250)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(Rectangle().frame(width: 1).foregroundColor(.black.opacity(0.2)),
                 alignment: .leading)
    }

    private var markupLayerBinding: Binding<String> {
        Binding(
            get: {
                guard let regen else { return DXFWriter.markupLayer }
                let store = regen.parsed.store
                let names = Set(selectedMarkupIDs.compactMap { id -> String? in
                    guard let h = store.header(id), Int(h.layerId) < (document?.layers.count ?? 0)
                    else { return nil }
                    return document?.layers[Int(h.layerId)].name
                })
                // "Various" placeholder for mixed selections — the user must clear
                // it before a value is committed, so distinct layers aren't
                // silently collapsed on the first keystroke.
                return names.count == 1 ? (names.first ?? DXFWriter.markupLayer)
                                        : EntityProperty.variesValue
            },
            set: { newValue in
                guard let regen else { return }
                let trimmed = newValue.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, trimmed != EntityProperty.variesValue else { return }
                let ids = selectedMarkupIDs
                let hadLayerBefore = regen.parsed.layerIdByName[trimmed] != nil
                let layerId = MarkupStore.ensureLayer(named: trimmed, in: regen.parsed)
                session.performEdit("Change Layer") { tx in
                    for id in ids { tx.modifyHeader(id) { $0.layerId = layerId } }
                }
                // A BRAND-NEW layer needs a full rebuild before it shows up in
                // `document.layers` (that array is immutable-after-load,
                // unlike modelGroups/paperGroups — see MarkupStore's doc
                // comment) — retargeting onto an EXISTING layer needs no
                // extra rebuild beyond what `performEdit` already did.
                if !hadLayerBefore { regen.fullRebuild(); session.objectWillChange.send() }
            }
        )
    }
}
