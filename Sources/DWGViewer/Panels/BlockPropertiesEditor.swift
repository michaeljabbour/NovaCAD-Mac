import CADCore
import SwiftUI

/// Editable properties for a selected BLOCK REFERENCE (INSERT) — the typed-
/// entry counterpart to `PropertiesPanel`'s read-only rows.
///
/// Before this, an INSERT's Properties rows (Name, Position X/Y, Scale X/Y,
/// Rotation, and every ATTRIB tag/value) were display-only text: the numbers
/// could be read but not typed into, so repositioning or rotating a block by
/// an exact amount meant using MOVE/ROTATE and picking points by eye, and
/// attribute values could only be reached through a separate double-click
/// sheet. Every one of those is now an editable field committed as one
/// undoable transaction, per the user's request to be able to "edit block
/// attributes ... including the 'Name', and manually typing the position x,
/// position y, rotation, etc."
///
/// Scope decisions worth knowing:
///
/// - **Name is the real `blockNameId`** — retargeting which block DEFINITION
///   this INSERT draws, so the object's geometry changes to the chosen block.
///   It's offered as a picker over the document's actual block table (not a
///   free-text field) because a name with no matching definition would render
///   nothing at all; there is no way to type a typo that silently blanks the
///   object. Distinct from `InsertPayload.displayNameId`, the purely cosmetic
///   per-instance label (edited as "Display Name" below), which deliberately
///   never alters the drawn geometry — see that field's own doc comment.
/// - **Commit on Return/blur, not per keystroke.** Each field edits a local
///   string buffer and only writes to the store when the user commits it, so
///   a half-typed number ("-", "1.", "") never becomes a real coordinate, and
///   one edit is one undo step. Fields re-seed from the store whenever the
///   selection or the underlying value changes, so an external edit (undo, a
///   drag on canvas, an AI-applied change) is reflected rather than being
///   overwritten by a stale buffer.
/// - **Single-INSERT only.** Multi-selection keeps the merged read-only view:
///   typing one absolute position into N blocks would stack them all at the
///   same point, which is almost never what's wanted (MOVE with a delta is
///   the right tool for that, and already exists).
struct BlockPropertiesEditor: View {
    private let englishNames = true
    @ObservedObject var session: DocumentSession
    let insertId: EntityID
    /// Units/precision for displaying and parsing the geometry fields — the
    /// same format the read-only rows use, so what the user sees in the field
    /// is what they can type back into it.
    let format: MeasureFormat

    private var regen: RegenCoordinator? { session.regen }

    /// Live payload read straight from the store — the single source of truth
    /// every field re-seeds from.
    private var payload: InsertPayload? {
        guard let regen else { return nil }
        let store = regen.parsed.store
        guard let h = store.header(insertId), h.type == .insert, h.payload >= 0,
              !h.flags.contains(.deleted) else { return nil }
        return store.inserts[Int(h.payload)]
    }

    /// Every block definition name in the document, sorted — the Name
    /// picker's candidate list. Anonymous/system blocks (leading `*`, e.g.
    /// `*U` hatch/dimension helper blocks) are filtered out: they're
    /// internal artifacts, and retargeting a user's block onto one would be
    /// a destructive mistake with no legitimate use.
    private var blockNames: [String] {
        guard let regen else { return [] }
        return regen.parsed.blocks.keys
            .filter { !$0.hasPrefix("*") }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    var body: some View {
        if let p = payload {
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader("Block")
                blockNameRow(current: currentBlockName(p))
                displayNameRow(p)

                sectionHeader("Geometry")
                // Position/scale/rotation. Scale and rotation are plain
                // numbers (no unit conversion); position is unit-formatted.
                lengthRow("Position X", value: p.position.x) { new, payload in
                    payload.position.x = new
                }
                lengthRow("Position Y", value: p.position.y) { new, payload in
                    payload.position.y = new
                }
                numberRow("Scale X", value: p.scale.x, allowZero: false) { new, payload in
                    payload.scale.x = new
                }
                numberRow("Scale Y", value: p.scale.y, allowZero: false) { new, payload in
                    payload.scale.y = new
                }
                numberRow("Rotation", value: p.rotationDeg, allowZero: true, suffix: "\u{00B0}") { new, payload in
                    payload.rotationDeg = new
                }

                attributesSection
            }
        }
    }

    // MARK: - Rows

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2).bold()
            .foregroundColor(.secondary)
            .padding(.horizontal, 10)
            .padding(.top, 10).padding(.bottom, 3)
    }

    private func currentBlockName(_ p: InsertPayload) -> String {
        guard let regen else { return "" }
        return regen.parsed.store.strings.string(for: p.blockNameId)
    }

    /// Retargets which block definition this INSERT draws. A full rebuild is
    /// forced afterward because the drawn geometry itself changes (a
    /// different definition means different primitives), which the
    /// incremental path can't express as a payload tweak.
    @ViewBuilder
    private func blockNameRow(current: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Name").font(.caption).foregroundColor(.secondary)
            Picker("", selection: Binding(
                get: { current },
                set: { newName in
                    guard newName != current, !newName.isEmpty, let regen else { return }
                    let nameId = regen.parsed.store.strings.intern(newName)
                    session.performEdit("Change Block") { tx in
                        tx.modifyPayload(insertId) { copy in
                            guard case .insert(var p) = copy else { return }
                            p.blockNameId = nameId
                            copy = .insert(p)
                        }
                    }
                    regen.fullRebuild()
                    session.objectWillChange.send()
                })) {
                // A block whose name isn't in the (filtered) candidate list —
                // e.g. an anonymous block, or a definition missing from this
                // file — still needs a tag to display, or the picker would
                // show blank and the first real edit would silently retarget
                // the object.
                if !blockNames.contains(current) {
                    Text(current.isEmpty ? "(none)" : LayerDisplayName.display(current, inEnglish: englishNames)).tag(current)
                }
                ForEach(blockNames, id: \.self) { name in
                    Text(LayerDisplayName.display(name, inEnglish: englishNames)).tag(name)
                }
            }
            .labelsHidden()
            .font(.callout)
            .help(current)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        Divider().padding(.leading, 10)
    }

    /// The cosmetic per-instance label (`InsertPayload.displayNameId`) — what
    /// Data Extraction and the AI Assistant report for this one object.
    /// Empty clears the override and falls back to the real block name.
    @ViewBuilder
    private func displayNameRow(_ p: InsertPayload) -> some View {
        let stored = p.displayNameId >= 0
            ? (regen?.parsed.store.strings.string(for: p.displayNameId) ?? "")
            : ""
        VStack(alignment: .leading, spacing: 4) {
            Text("Display Name").font(.caption).foregroundColor(.secondary)
            CommittingTextField(
                title: "(same as block name)",
                stored: stored,
                onCommit: { newValue in
                    guard newValue != stored, let regen else { return }
                    session.performEdit("Rename Object") { tx in
                        _ = BlockEditor.setDisplayName(insertId, to: newValue,
                                                       in: regen.parsed, tx: tx)
                    }
                })
            Text("Label for reports \u{2014} does not change the drawn block.")
                .font(.caption2).foregroundColor(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        Divider().padding(.leading, 10)
    }

    /// A unit-formatted length field (position coordinates): displays through
    /// `MeasureFormat` and parses back with `UnitInput.parseLength`, so
    /// architectural drawings can be typed as `12'-6"` rather than raw units.
    @ViewBuilder
    private func lengthRow(_ label: String, value: Double,
                           apply: @escaping (Double, inout InsertPayload) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundColor(.secondary)
            CommittingTextField(
                title: label,
                stored: format.length(CGFloat(value)),
                onCommit: { text in
                    guard let parsed = UnitInput.parseLength(text, format: format) else { return }
                    commit(label, parsed, apply)
                })
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        Divider().padding(.leading, 10)
    }

    /// A plain numeric field (scale factors, rotation degrees) — no unit
    /// conversion, since neither is a length.
    @ViewBuilder
    private func numberRow(_ label: String, value: Double, allowZero: Bool, suffix: String = "",
                           apply: @escaping (Double, inout InsertPayload) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundColor(.secondary)
            HStack(spacing: 4) {
                CommittingTextField(
                    title: label,
                    stored: UnitInput.plainNumber(value),
                    onCommit: { text in
                        guard let parsed = UnitInput.parseNumber(text) else { return }
                        // A zero X/Y scale collapses the block to nothing and
                        // is not recoverable by typing (every subsequent
                        // scale multiplies by zero), so it's rejected rather
                        // than committed — matching AutoCAD refusing a zero
                        // scale factor.
                        if !allowZero, abs(parsed) < 1e-12 { return }
                        commit(label, parsed, apply)
                    })
                if !suffix.isEmpty {
                    Text(suffix).font(.caption).foregroundColor(.secondary)
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        Divider().padding(.leading, 10)
    }

    private func commit(_ label: String, _ newValue: Double,
                        _ apply: @escaping (Double, inout InsertPayload) -> Void) {
        session.performEdit("Change \(label)") { tx in
            tx.modifyPayload(insertId) { copy in
                guard case .insert(var p) = copy else { return }
                apply(newValue, &p)
                copy = .insert(p)
            }
        }
    }

    // MARK: - Attributes

    /// Every ATTRIB on this INSERT, each editable in place — the same values
    /// the double-click attribute sheet edits, surfaced directly in the
    /// Properties panel so they're visible/editable without a modal.
    @ViewBuilder
    private var attributesSection: some View {
        if let regen {
            let attrs = BlockEditor.attributes(of: insertId, in: regen.parsed.store)
            if !attrs.isEmpty {
                sectionHeader("Attributes")
                ForEach(attrs, id: \.id) { attr in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(attr.tag).font(.caption).foregroundColor(.secondary)
                        CommittingTextField(
                            title: attr.tag,
                            stored: attr.value,
                            onCommit: { newValue in
                                guard newValue != attr.value else { return }
                                session.performEdit("Edit \(attr.tag)") { tx in
                                    _ = BlockEditor.setAttribute(insertId, tag: attr.tag,
                                                                 value: newValue,
                                                                 in: regen.parsed, tx: tx)
                                }
                            })
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    Divider().padding(.leading, 10)
                }
            }
        }
    }
}

// MARK: - Commit-on-Return/blur text field

/// A `TextField` that edits a LOCAL buffer and reports a committed value only
/// on Return or focus loss — never per keystroke.
///
/// Why this exists rather than binding a `TextField` straight at the store:
/// a per-keystroke binding would push every intermediate string through the
/// parser and into a transaction, so typing "-12.5" would commit at "-"
/// (invalid, dropped), "-1" (moves the block!), "-12", "-12." and finally
/// "-12.5" — five undo steps and four wrong positions, with the block visibly
/// jumping around mid-typing. It also re-seeds from `stored` whenever the
/// underlying value changes, so undo/redo, a canvas drag, or an AI-applied
/// edit updates the field instead of being clobbered by a stale buffer.
struct CommittingTextField: View {
    let title: String
    /// The current value from the store, formatted for display.
    let stored: String
    let onCommit: (String) -> Void

    @State private var buffer: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(title, text: $buffer)
            .textFieldStyle(.roundedBorder)
            .font(.callout)
            .focused($focused)
            .onSubmit { commit() }
            .onAppear { buffer = stored }
            .onChange(of: stored) { _, newValue in
                // Only adopt external changes while the user ISN'T typing, so
                // a re-render mid-edit can't yank the caret or discard input.
                if !focused { buffer = newValue }
            }
            .onChange(of: focused) { wasFocused, isFocused in
                if wasFocused && !isFocused { commit() }
            }
    }

    private func commit() {
        let trimmed = buffer.trimmingCharacters(in: .whitespaces)
        // An unparseable/rejected entry is reverted to the stored value by the
        // caller declining to commit; snap the buffer back so the field never
        // keeps showing a value the document doesn't actually have.
        onCommit(trimmed)
        buffer = stored
    }
}

// MARK: - Numeric input parsing

/// Parsing for typed numeric property fields — the inverse of
/// `MeasureFormat`'s display formatting.
///
/// Kept as a standalone, pure helper (not a method on a view) so the parsing
/// rules are unit-testable: this is the layer that decides whether `12'-6"`,
/// `12' 6`, `150`, or `1,250.5` become numbers, and getting it wrong means
/// either silently refusing a user's legitimate input or committing a
/// nonsense coordinate.
enum UnitInput {
    /// Formats a plain (non-length) number for a text field: trims trailing
    /// zeros so a rotation of 90 shows as "90", not "90.000000", while still
    /// preserving genuine precision.
    static func plainNumber(_ value: Double) -> String {
        if abs(value.rounded() - value) < 1e-9 { return String(Int(value.rounded())) }
        return String(format: "%g", value)
    }

    /// Parses a plain decimal number, tolerating thousands separators and
    /// surrounding whitespace/degree signs (so a rotation field's own
    /// displayed "90°" can be pasted straight back in).
    static func parseNumber(_ text: String) -> Double? {
        var s = text.trimmingCharacters(in: .whitespaces)
        s = s.replacingOccurrences(of: ",", with: "")
        s = s.replacingOccurrences(of: "\u{00B0}", with: "")
        s = s.replacingOccurrences(of: "deg", with: "", options: .caseInsensitive)
        s = s.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        return Double(s)
    }

    /// Parses a length back into DRAWING UNITS, accepting both the plain
    /// decimal form and the feet/inches forms `MeasureFormat` displays for
    /// architectural/engineering drawings:
    ///
    ///   `150`, `1,250.5`, `12'`, `6"`, `12'-6"`, `12' 6 1/2"`, `6 1/2"`
    ///
    /// Feet/inches input is converted to inches and then divided by the
    /// format's own `inchesPerUnit`, so it round-trips exactly with what
    /// `MeasureFormat.length` printed — typing back the string the field
    /// showed always yields the value it came from.
    static func parseLength(_ text: String, format: MeasureFormat) -> Double? {
        let s = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "")
        guard !s.isEmpty else { return nil }

        // No feet/inches marks at all -> a plain number in drawing units.
        if !s.contains("'") && !s.contains("\"") {
            return parseFraction(s)
        }

        var feet = 0.0
        var rest = s
        if let footMark = rest.firstIndex(of: "'") {
            guard let f = parseFraction(String(rest[rest.startIndex..<footMark])) else { return nil }
            feet = f
            rest = String(rest[rest.index(after: footMark)...])
        }
        // The separator between feet and inches may be "-" or whitespace.
        rest = rest.replacingOccurrences(of: "\"", with: "")
        rest = rest.trimmingCharacters(in: .whitespaces)
        if rest.hasPrefix("-") { rest.removeFirst() }
        rest = rest.trimmingCharacters(in: .whitespaces)

        var inches = 0.0
        if !rest.isEmpty {
            guard let i = parseFraction(rest) else { return nil }
            inches = i
        }
        let totalInches = feet * 12 + inches
        let perUnit = inchesPerUnit(format)
        guard perUnit > 0 else { return totalInches }
        return totalInches / perUnit
    }

    /// Inches per drawing unit for `format.insUnits` (DXF `$INSUNITS`).
    ///
    /// Deliberately re-derived here from the PUBLIC `insUnits` rather than
    /// reading `MeasureFormat`'s own `metresPerUnit`/`inchesPerUnit`, both of
    /// which are private to CADCore: this app-side parser shouldn't widen a
    /// shared package's API surface just to read a constant back. Mirrors
    /// CADCore's own table and its fallback exactly — an unknown/unset
    /// `$INSUNITS` is treated as inches, so a drawing that declares no units
    /// round-trips 1:1 instead of silently scaling. Must stay in step with
    /// `UnitFormat.metresPerUnit`; covered by a round-trip test asserting that
    /// parsing what `MeasureFormat.length` printed returns the original value.
    static func inchesPerUnit(_ format: MeasureFormat) -> Double {
        let metresPerUnit: Double?
        switch format.insUnits {
        case 1: metresPerUnit = 0.0254            // inch
        case 2: metresPerUnit = 0.3048            // foot
        case 3: metresPerUnit = 1609.344          // mile
        case 4: metresPerUnit = 0.001             // mm
        case 5: metresPerUnit = 0.01              // cm
        case 6: metresPerUnit = 1.0               // metre
        case 7: metresPerUnit = 1000.0            // km
        case 8: metresPerUnit = 0.0254e-6         // microinch
        case 9: metresPerUnit = 0.0254e-3         // mil
        case 10: metresPerUnit = 0.9144           // yard
        case 11: metresPerUnit = 1e-10            // angstrom
        case 12: metresPerUnit = 1e-9             // nanometre
        case 13: metresPerUnit = 1e-6             // micron
        case 14: metresPerUnit = 0.1              // decimetre
        case 15: metresPerUnit = 10.0             // decametre
        case 16: metresPerUnit = 100.0            // hectometre
        case 21: metresPerUnit = 0.3048006096     // US survey foot
        default: metresPerUnit = nil
        }
        guard let metres = metresPerUnit else { return 1 }
        return metres / 0.0254
    }

    /// Parses a decimal, a bare fraction, or a mixed number: `6`, `1/2`,
    /// `6 1/2`, `6-1/2`, `-6 1/2` — the forms `MeasureFormat`'s fractional
    /// architectural output produces.
    ///
    /// Both a SPACE and a HYPHEN are accepted between the whole part and the
    /// fraction, because `MeasureFormat.length` actually prints the hyphen form
    /// (`12'-6-1/2"`); a space-only split silently rejected the app's own
    /// displayed value, which the display/parse round-trip test caught.
    /// The hyphen is only a separator INSIDE the number — a leading one is
    /// still a sign, stripped first.
    static func parseFraction(_ text: String) -> Double? {
        let s = text.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        if let d = Double(s) { return d }

        var negative = false
        var body = s
        if body.hasPrefix("-") { negative = true; body.removeFirst() }

        let parts = body.split(whereSeparator: { $0 == " " || $0 == "-" })
        func fraction(_ piece: Substring) -> Double? {
            let halves = piece.split(separator: "/")
            guard halves.count == 2, let n = Double(halves[0]), let d = Double(halves[1]), d != 0
            else { return nil }
            return n / d
        }
        var total: Double
        switch parts.count {
        case 1:
            guard let f = fraction(parts[0]) else { return nil }
            total = f
        case 2:
            guard let whole = Double(parts[0]), let f = fraction(parts[1]) else { return nil }
            total = whole + f
        default:
            return nil
        }
        return negative ? -total : total
    }
}
