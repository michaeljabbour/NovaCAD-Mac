import Foundation
import CoreGraphics
import CADCore

// MARK: - Data Extraction (AutoCAD DATAEXTRACTION / "dx" equivalent)
//
// A CSV round-trip for bulk-editing object data attributes: EXPORT every
// entity (and each INSERT's ATTRIB tag/value pairs) to a spreadsheet-
// friendly CSV, edit it externally (Excel/Numbers/Sheets), then IMPORT the
// edited CSV to bulk-apply the changes back onto the drawing in one undoable
// step.
//
// The join key is `entityId` (`EntityID.raw`) — carried as the first column
// so `DataExtractionImporter.apply` knows exactly which live entity each
// edited row targets. CRITICAL CAVEAT (surfaced in the UI): `EntityID.raw`
// is stable only WITHIN a session (slots are tombstoned-not-reused until a
// save-time compaction — see `EntityID`'s own doc comment). So the round
// trip must complete against the SAME open document: export, edit, re-import
// without closing/reloading/saving in between. This matches how AutoCAD's
// own DATAEXTRACTION-then-edit-then-update workflow is used in practice, and
// exactly mirrors the already-shipped AI-assistant edit path
// (`AIProposedEdit.insertEntityId` is the same "external representation names
// an EntityID.raw, we apply an edit to it" round trip).
//
// Editability (per this feature's product decision): on import, the EDITABLE
// columns are `layer`, `color` (ACI), `text` (TEXT/MTEXT content), `blockName`
// (INSERT only — see below), and each `attr:<TAG>` column (INSERT ATTRIB
// values). Every other column (entityId/type/space/position/bounds) is
// REFERENCE-ONLY — exported to help the user identify/sort rows, ignored on
// import.
//
// `blockName` is DELIBERATELY COSMETIC, not structural: editing it sets a
// per-instance DISPLAY NAME override (`InsertPayload.displayNameId` /
// `BlockEditor.setDisplayName`) — it does NOT retarget which block
// definition the INSERT draws, and therefore never changes the object's
// on-canvas appearance/geometry in any way. This was an explicit product
// decision after a user tried to use this column to relabel objects and
// found it silently ignored (it used to be pure reference data, matching
// AutoCAD DATAEXTRACTION's own read-only treatment of a block's name) —
// "rename the block a specific INSERT reports as" is a real, wanted
// operation distinct from "reassign this INSERT to draw a DIFFERENT block's
// geometry" (which this column intentionally does NOT do; no CSV column
// does, today — that would be a structural edit with its own, separate
// product surface).
enum DataExtraction {

    // MARK: Column names (stable header strings — the CSV's contract)

    enum Column {
        static let entityId = "entityId"       // reference / join key
        static let type = "type"               // reference
        static let space = "space"             // reference ("model"/"paper")
        static let blockName = "blockName"     // EDITABLE (INSERT only — cosmetic display-name override, see header comment)
        static let ownerInsertId = "ownerInsertId" // reference (ATTRIB only)
        static let minX = "minX", minY = "minY", maxX = "maxX", maxY = "maxY" // reference (world bounds)
        static let layer = "layer"             // EDITABLE
        static let color = "color"             // EDITABLE (ACI: 256=ByLayer, 0=ByBlock, 1-255)
        static let text = "text"               // EDITABLE (TEXT/MTEXT content)
        static let scaleX = "scaleX"           // EDITABLE (INSERT only; empty for other types)
        static let scaleY = "scaleY"           // EDITABLE (INSERT only)
        static let rotation = "rotation"       // EDITABLE (INSERT only, degrees)
        static let attrPrefix = ""             // was "attr:" — removed per user request
    }

    /// One extracted row — one entity, plus its INSERT ATTRIBs (if any) as
    /// `tag -> value`. Column order in the CSV is: fixed reference columns,
    /// then the editable fixed columns, then one `attr:<TAG>` column per
    /// distinct tag found anywhere in the export (union across all INSERTs).
    struct Row {
        var entityId: Int32
        var type: String
        var space: String
        var blockName: String?
        var ownerInsertId: Int32?
        var minX, minY, maxX, maxY: Double
        var layer: String
        var color: Int16
        var text: String?
        var scaleX: Double?
        var scaleY: Double?
        var rotationDegrees: Double?
        var attributes: [String: String]   // tag -> value (INSERT only)
    }

    // MARK: - Export

    /// Walks EVERY non-deleted entity in the live document (both model and
    /// paper space — no 4000-entity cap, unlike `DrawingReader.summarize`
    /// which is bounded for the LLM's context window), reading each one's
    /// stable id, type, layer, color, text content, and — for INSERTs — its
    /// ATTRIB tag/value pairs. Reads only; never mutates `parsed`.
    static func extractRows(from parsed: EditableParsedDocument) -> [Row] {
        let store = parsed.store
        var rows: [Row] = []

        func layerName(_ id: Int32) -> String {
            id >= 0 && Int(id) < parsed.layers.count ? parsed.layers[Int(id)].name : "0"
        }

        for i in store.headers.indices {
            let h = store.headers[i]
            guard !h.flags.contains(.deleted) else { continue }
            // ATTRIB children are represented via their owning INSERT's
            // `attr:<TAG>` columns, not as their own top-level rows — a lone
            // ATTRIB with no live INSERT parent would be orphaned data the
            // user can't meaningfully re-import, so it's skipped here (its
            // value still round-trips through the parent INSERT's row).
            if h.type == .attrib { continue }
            // VERTEX and other pure sub-records carry no user-facing row.
            guard rowWorthy(h.type) else { continue }

            let id = EntityID(raw: Int32(i))
            let space = h.owner.isPaper ? "paper" : "model"
            let bounds = store.bounds(id)

            var text: String? = nil
            var blockName: String? = nil
            var attributes: [String: String] = [:]
            var scaleX: Double?
            var scaleY: Double?
            var rotationDegrees: Double?

            switch h.type {
            case .text, .mtext:
                text = textContent(of: h, store: store)
            case .insert:
                // `displayName(of:)` reconciles the real block name with any
                // per-instance cosmetic override — see that function's own
                // doc comment. This is what makes the round trip work: a
                // PREVIOUSLY-exported/edited `blockName` value comes back as
                // THIS row's `blockName` again on the next export, instead
                // of reverting to the real block name every time.
                blockName = BlockEditor.displayName(of: id, in: store)
                for attr in BlockEditor.attributes(of: id, in: store) {
                    attributes[attr.tag] = attr.value
                }
                if h.payload >= 0, Int(h.payload) < store.inserts.count {
                    let p = store.inserts[Int(h.payload)]
                    scaleX = p.scale.x
                    scaleY = p.scale.y
                    rotationDegrees = p.rotationDeg
                }

            default:
                break
            }

            rows.append(Row(
                entityId: Int32(i), type: typeName(h.type), space: space,
                blockName: blockName, ownerInsertId: nil,
                minX: Double(bounds.minX), minY: Double(bounds.minY),
                maxX: Double(bounds.maxX), maxY: Double(bounds.maxY),
                layer: layerName(h.layerId), color: h.aci, text: text,
                scaleX: scaleX, scaleY: scaleY, rotationDegrees: rotationDegrees,
                attributes: attributes))
        }
        return rows
    }

    /// Every column name that WOULD appear in a full (unfiltered) export of
    /// `rows`, in the CSV's default order — the fixed reference/editable
    /// columns, then the sorted union of every ATTRIB tag seen across all
    /// rows. This is the candidate list the column-picker UI
    /// (`DataExtractionColumnPicker.swift`) shows the user to choose from
    /// and reorder, and is exactly what `csv(for:columns:)` uses when no
    /// explicit `columns` override is given.
    static func availableColumns(for rows: [Row]) -> [String] {
        let attrTags = Set(rows.flatMap { $0.attributes.keys }).sorted()
        return [Column.entityId, Column.type, Column.space, Column.blockName,
               Column.ownerInsertId, Column.minX, Column.minY, Column.maxX, Column.maxY,
               Column.layer, Column.color, Column.text,
               Column.scaleX, Column.scaleY, Column.rotation] + attrTags
    }

    /// Serializes `rows` to CSV text.
    ///
    /// `columns`, when non-nil, is BOTH the exact subset of columns to
    /// include AND their exact left-to-right order in the output — this is
    /// how the Data Extraction column-picker UI lets a user choose only
    /// the fields they care about (e.g. drop `minX`/`minY`/`maxX`/`maxY`
    /// entirely) and control which comes first vs. last. Any name in
    /// `columns` not found among `availableColumns(for: rows)` (e.g. an
    /// ATTRIB tag that happens not to appear on any row in THIS export) is
    /// silently skipped rather than producing an empty column of blanks.
    /// `nil` (the default) preserves the original "every column, in the
    /// fixed reference/editable/attr-tags order" behavior — the entire
    /// existing test suite and any caller that doesn't opt into column
    /// selection is completely unaffected by this feature.
    static func csv(for rows: [Row], columns: [String]? = nil) -> String {
        let attrTags = Set(rows.flatMap { $0.attributes.keys })
        let allColumns = availableColumns(for: rows)
        let selected = columns.map { requested in requested.filter { allColumns.contains($0) } } ?? allColumns

        func field(_ row: Row, _ column: String) -> String {
            switch column {
            case Column.entityId: return String(row.entityId)
            case Column.type: return row.type
            case Column.space: return row.space
            case Column.blockName: return row.blockName ?? ""
            case Column.ownerInsertId: return row.ownerInsertId.map(String.init) ?? ""
            case Column.minX: return trimTrailingZeros(row.minX)
            case Column.minY: return trimTrailingZeros(row.minY)
            case Column.maxX: return trimTrailingZeros(row.maxX)
            case Column.maxY: return trimTrailingZeros(row.maxY)
            case Column.layer: return row.layer
            case Column.color: return String(row.color)
            case Column.text: return row.text ?? ""
            case Column.scaleX: return row.scaleX.map(trimTrailingZeros) ?? ""
            case Column.scaleY: return row.scaleY.map(trimTrailingZeros) ?? ""
            case Column.rotation: return row.rotationDegrees.map(trimTrailingZeros) ?? ""
            default:
                // Every remaining selected column name is an ATTRIB tag
                // (already filtered to only names present in
                // `allColumns`, so this is exhaustive in practice).
                return attrTags.contains(column) ? (row.attributes[column] ?? "") : ""
            }
        }

        var lines = [selected.map(csvEscape).joined(separator: ",")]
        for row in rows {
            lines.append(selected.map { csvEscape(field(row, $0)) }.joined(separator: ","))
        }
        // CRLF line endings — the most broadly compatible across Excel on
        // both Windows and macOS (RFC 4180's recommendation).
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    // MARK: - Import (parse)

    /// An edited row parsed back from an imported CSV: the join key plus
    /// only the EDITABLE fields, each optional so "column absent from the
    /// file" is distinguishable from "present but blank" (a present-but-
    /// blank editable cell is a real edit — e.g. clearing a text value —
    /// whereas an absent column leaves that property untouched).
    struct ParsedEdit {
        var entityId: Int32
        var layer: String?
        var color: Int16?
        var text: String?
        var textPresent: Bool          // was the `text` column in the file at all?
        /// New/edited display-name value (INSERT only) — see `Column
        /// .blockName`'s own doc comment for what this does/doesn't do
        /// (cosmetic display name, NEVER retargets the drawn geometry).
        /// `blockNamePresent` mirrors `textPresent`'s "column absent vs.
        /// present-but-blank" distinction: a present-but-blank cell clears
        /// any existing override back to the real block name (see `apply`).
        var blockName: String?
        var blockNamePresent: Bool
        var scaleX: Double?
        var scaleXPresent: Bool = false
        var scaleY: Double?
        var scaleYPresent: Bool = false
        var rotationDegrees: Double?
        var rotationPresent: Bool = false
        var attributes: [String: String]   // only tags whose columns were present
    }

    enum ParseError: LocalizedError {
        case empty
        case missingEntityIdColumn
        var errorDescription: String? {
            switch self {
            case .empty: return "The file is empty or has no data rows."
            case .missingEntityIdColumn: return "The file has no \"\(Column.entityId)\" column — it must be a NovaCAD data extraction CSV."
            }
        }
    }

    /// Parses imported CSV text into `ParsedEdit`s. Throws `ParseError` for a
    /// structurally invalid file (empty / no entityId column). Rows whose
    /// entityId cell isn't a valid integer are skipped (reported to the
    /// caller via the return's second element count so the UI can surface
    /// "N rows skipped").
    static func parseCSV(_ text: String) throws -> (edits: [ParsedEdit], skippedRows: Int) {
        let records = parseCSVRecords(text)
        guard let header = records.first, !header.isEmpty else { throw ParseError.empty }
        guard records.count > 1 else { throw ParseError.empty }

        // Map header name -> column index.
        var indexOf: [String: Int] = [:]
        for (i, name) in header.enumerated() { indexOf[name] = i }
        guard let idIdx = indexOf[Column.entityId] else { throw ParseError.missingEntityIdColumn }

        let layerIdx = indexOf[Column.layer]
        let colorIdx = indexOf[Column.color]
        let textIdx = indexOf[Column.text]
        let blockNameIdx = indexOf[Column.blockName]
        let scaleXIdx = indexOf[Column.scaleX]
        let scaleYIdx = indexOf[Column.scaleY]
        let rotationIdx = indexOf[Column.rotation]
        // ATTRIB columns: if the prefix is empty (current), EVERY column
        // that isn't a known fixed column name is treated as an attribute
        // tag — this is how the user sees bare tag names as column headers.
        // If the prefix is non-empty (legacy "attr:" prefix), only columns
        // starting with that prefix are included.
        let attrColumns: [(idx: Int, tag: String)]
        if Column.attrPrefix.isEmpty {
            let fixedNames = Set([Column.entityId, Column.type, Column.space, Column.blockName,
                                  Column.ownerInsertId, Column.minX, Column.minY, Column.maxX,
                                  Column.maxY, Column.layer, Column.color, Column.text,
                                  Column.scaleX, Column.scaleY, Column.rotation])
            attrColumns = header.enumerated().compactMap { i, name in
                fixedNames.contains(name) ? nil : (i, name)
            }
        } else {
            attrColumns = header.enumerated().compactMap { i, name in
                name.hasPrefix(Column.attrPrefix) ? (i, String(name.dropFirst(Column.attrPrefix.count))) : nil
            }
        }

        var edits: [ParsedEdit] = []
        var skipped = 0
        for record in records.dropFirst() {
            // A trailing empty line yields a single empty field — ignore it.
            if record.count == 1, record[0].isEmpty { continue }
            func field(_ idx: Int?) -> String? {
                guard let idx, idx < record.count else { return nil }
                return record[idx]
            }
            guard let idStr = field(idIdx), let entityId = Int32(idStr.trimmingCharacters(in: .whitespaces)) else {
                skipped += 1
                continue
            }
            var attrs: [String: String] = [:]
            for col in attrColumns {
                if let v = field(col.idx) { attrs[col.tag] = v }
            }
            let textField = field(textIdx)
            edits.append(ParsedEdit(
                entityId: entityId,
                layer: field(layerIdx).map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 },
                color: field(colorIdx).flatMap { Int16($0.trimmingCharacters(in: .whitespaces)) },
                text: textField,
                textPresent: textIdx != nil,
                blockName: field(blockNameIdx),
                blockNamePresent: blockNameIdx != nil,
                scaleX: field(scaleXIdx).flatMap { Double($0.trimmingCharacters(in: .whitespaces)) },
                scaleXPresent: scaleXIdx != nil,
                scaleY: field(scaleYIdx).flatMap { Double($0.trimmingCharacters(in: .whitespaces)) },
                scaleYPresent: scaleYIdx != nil,
                rotationDegrees: field(rotationIdx).flatMap { Double($0.trimmingCharacters(in: .whitespaces)) },
                rotationPresent: rotationIdx != nil,
                attributes: attrs))
        }
        return (edits, skipped)
    }

    // MARK: - Helpers

    private static func rowWorthy(_ type: DXFEntityType) -> Bool {
        switch type {
        case .unknown: return false
        default: return true
        }
    }

    private static func typeName(_ type: DXFEntityType) -> String {
        switch type {
        case .line: return "line"
        case .point: return "point"
        case .circle: return "circle"
        case .arc: return "arc"
        case .ellipse: return "ellipse"
        case .lwpolyline: return "lwpolyline"
        case .polyline2d: return "polyline2d"
        case .polyline3d: return "polyline3d"
        case .spline: return "spline"
        case .solid: return "solid"
        case .trace: return "trace"
        case .face3d: return "face3d"
        case .hatch: return "hatch"
        case .text: return "text"
        case .mtext: return "mtext"
        case .attdef: return "attdef"
        case .attrib: return "attrib"
        case .insert: return "insert"
        case .dimension: return "dimension"
        case .leader: return "leader"
        case .mleader: return "mleader"
        case .xline: return "xline"
        case .ray: return "ray"
        case .wipeout: return "wipeout"
        case .image: return "image"
        case .viewport: return "viewport"
        case .acadTable: return "acadTable"
        case .unknown: return "unknown"
        }
    }

    private static func textContent(of h: EntityHeader, store: EntityStore) -> String? {
        guard h.payload >= 0 else { return nil }
        switch h.type {
        case .text:
            return store.strings.string(for: store.texts[Int(h.payload)].stringId)
        case .mtext:
            // MTEXT's stored string retains formatting codes verbatim; the
            // renderer strips them. For a data-extraction round trip we
            // expose the RAW stored string (so re-import writes back exactly
            // what the user edited, formatting codes and all) — matching how
            // `PasteboardSnapshot` also carries the raw MTEXT string.
            return store.strings.string(for: store.mtexts[Int(h.payload)].stringId)
        default:
            return nil
        }
    }

    /// RFC 4180 CSV field escaping: wrap in double-quotes and double any
    /// embedded quotes if the field contains a comma, quote, CR, or LF.
    static func csvEscape(_ field: String) -> String {
        guard field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r")
        else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Compact numeric formatting for the reference bounds columns — avoids
    /// "10.0"/"1.2300000000001" noise while keeping full precision where it
    /// matters. These columns are reference-only (ignored on import), so
    /// exact byte-for-byte round-tripping isn't required.
    private static func trimTrailingZeros(_ v: Double) -> String {
        if v == v.rounded() && abs(v) < 1e15 { return String(Int64(v)) }
        return String(format: "%.6g", v)
    }

    // MARK: - Import (apply)

    /// Summary of what an import changed — surfaced to the user so a bulk
    /// edit reports concrete numbers ("Updated 42 attributes, 3 layers…")
    /// rather than a silent success.
    struct ApplyResult {
        var attributeEdits = 0
        var layerEdits = 0
        var colorEdits = 0
        var textEdits = 0
        /// INSERT display-name (`blockName` column) overrides applied —
        /// cosmetic only, see `Column.blockName`'s own doc comment.
        var displayNameEdits = 0
        /// INSERT scale/rotation edits applied (`scaleX`, `scaleY`,
        /// `rotation` columns).
        var scaleEdits = 0
        var rowsSkipped = 0            // entityId didn't resolve to a live entity
        var createdLayer = false       // a new layer name was introduced (needs fullRebuild)

        var totalEdits: Int { attributeEdits + layerEdits + colorEdits + textEdits + displayNameEdits + scaleEdits }

        var summary: String {
            guard totalEdits > 0 || rowsSkipped > 0 else { return "No changes to apply" }
            var parts: [String] = []
            if attributeEdits > 0 { parts.append("\(attributeEdits) attribute(s)") }
            if layerEdits > 0 { parts.append("\(layerEdits) layer(s)") }
            if colorEdits > 0 { parts.append("\(colorEdits) color(s)") }
            if textEdits > 0 { parts.append("\(textEdits) text value(s)") }
            if displayNameEdits > 0 { parts.append("\(displayNameEdits) name(s)") }
            if scaleEdits > 0 { parts.append("\(scaleEdits) scale/rotation value(s)") }
            var s = parts.isEmpty ? "No changes applied" : "Updated " + parts.joined(separator: ", ")
            if rowsSkipped > 0 { s += " · \(rowsSkipped) row(s) skipped (entity no longer exists)" }
            return s
        }
    }

    /// Applies `edits` to `parsed` inside `tx` — the write half of the round
    /// trip, structurally identical to `AIProposedEditApplier.apply`'s
    /// "loop over edits, one transaction for the whole batch" idiom so the
    /// entire import is a SINGLE undo step.
    ///
    /// Only actually writes a field when the imported value DIFFERS from the
    /// current one (a diff, not a blind overwrite) — so re-importing an
    /// unedited export is a genuine no-op (zero ops, nothing on the undo
    /// stack), and the reported counts reflect real changes only.
    ///
    /// Returns an `ApplyResult` whose `createdLayer` tells the caller to
    /// `fullRebuild()` afterward (a brand-new layer name changes the
    /// document's structural layer table, which the incremental render-delta
    /// path can't patch — same precedent as `PropertiesPanel`'s markup
    /// re-layer).
    static func apply(_ edits: [ParsedEdit], in parsed: EditableParsedDocument, tx: Transaction) -> ApplyResult {
        let store = parsed.store
        var result = ApplyResult()

        for edit in edits {
            let id = EntityID(raw: edit.entityId)
            guard let h = store.header(id), !h.flags.contains(.deleted) else {
                result.rowsSkipped += 1
                continue
            }

            // ---- Layer ----
            if let newLayer = edit.layer {
                let currentLayer = h.layerId >= 0 && Int(h.layerId) < parsed.layers.count
                    ? parsed.layers[Int(h.layerId)].name : "0"
                if newLayer != currentLayer {
                    let hadLayer = parsed.layerIdByName[newLayer] != nil
                    let layerId = MarkupStore.ensureLayer(named: newLayer, in: parsed)
                    if !hadLayer { result.createdLayer = true }
                    tx.modifyHeader(id) { $0.layerId = layerId }
                    result.layerEdits += 1
                }
            }

            // ---- Color (ACI) ----
            if let newColor = edit.color, newColor != h.aci {
                tx.modifyHeader(id) { $0.aci = newColor }
                result.colorEdits += 1
            }

            // ---- Text content (TEXT / MTEXT) ----
            if edit.textPresent, (h.type == .text || h.type == .mtext), h.payload >= 0 {
                let current = textContent(of: h, store: store) ?? ""
                let newText = edit.text ?? ""
                if newText != current {
                    let valueId = store.strings.intern(newText)
                    tx.modifyPayload(id) { copy in
                        switch copy {
                        case .text(var p): p.stringId = valueId; copy = .text(p)
                        case .mtext(var p): p.stringId = valueId; copy = .mtext(p)
                        default: break
                        }
                    }
                    result.textEdits += 1
                }
            }

            // ---- Display name (INSERT only; cosmetic — see Column
            // .blockName's own doc comment). `blockNamePresent` distinguishes
            // "column absent -> leave untouched" from "present but blank ->
            // clear back to the real block name", the same convention
            // `textPresent` already established above.
            if edit.blockNamePresent, h.type == .insert {
                let current = BlockEditor.displayName(of: id, in: store) ?? ""
                let newName = edit.blockName ?? ""
                if newName != current {
                    if BlockEditor.setDisplayName(id, to: newName, in: parsed, tx: tx) {
                        result.displayNameEdits += 1
                    }
                }
            }

            // ---- Scale X / Scale Y / Rotation (INSERT only) ----
            if h.type == .insert, h.payload >= 0, Int(h.payload) < store.inserts.count {
                let idx = Int(h.payload)
                if edit.scaleXPresent, let newScaleX = edit.scaleX {
                    let current = store.inserts[idx].scale.x
                    if abs(newScaleX - current) > 1e-12 {
                        tx.modifyPayload(id) { copy in
                            if case .insert(var p) = copy {
                                p.scale.x = newScaleX
                                copy = .insert(p)
                            }
                        }
                        result.scaleEdits += 1
                    }
                }
                if edit.scaleYPresent, let newScaleY = edit.scaleY {
                    let current = store.inserts[idx].scale.y
                    if abs(newScaleY - current) > 1e-12 {
                        tx.modifyPayload(id) { copy in
                            if case .insert(var p) = copy {
                                p.scale.y = newScaleY
                                copy = .insert(p)
                            }
                        }
                        result.scaleEdits += 1
                    }
                }
                if edit.rotationPresent, let newRot = edit.rotationDegrees {
                    let current = store.inserts[idx].rotationDeg
                    if abs(newRot - current) > 1e-12 {
                        tx.modifyPayload(id) { copy in
                            if case .insert(var p) = copy {
                                p.rotationDeg = newRot
                                copy = .insert(p)
                            }
                        }
                        result.scaleEdits += 1   // counted as a "scale" edit for brevity
                    }
                }
            }

            // ---- INSERT ATTRIB values ----
            if h.type == .insert, !edit.attributes.isEmpty {
                let current = Dictionary(BlockEditor.attributes(of: id, in: store)
                    .map { ($0.tag, $0.value) }, uniquingKeysWith: { a, _ in a })
                for (tag, value) in edit.attributes {
                    guard let existing = current[tag] else { continue }   // no such tag on this INSERT
                    if value != existing {
                        if BlockEditor.setAttribute(id, tag: tag, value: value, in: parsed, tx: tx) {
                            result.attributeEdits += 1
                        }
                    }
                }
            }
        }
        return result
    }

    /// A minimal RFC 4180 CSV parser: splits `text` into records (rows) of
    /// fields, honoring double-quoted fields (which may contain commas,
    /// CR/LF, and escaped `""` quotes). Handles both LF and CRLF line
    /// endings. Sufficient for the well-formed CSVs Excel/Numbers/Sheets
    /// produce on export of a file this feature itself wrote.
    ///
    /// Operates on `text.unicodeScalars`, NOT `Character`s — Swift's
    /// `String` iterates by extended grapheme cluster, and `"\r\n"` is a
    /// SINGLE `Character` (grapheme cluster), not two. A `Character`-based
    /// scan therefore never matches a bare `"\r"`/`"\n"` case for real CRLF
    /// input (`text[i] == "\r"` is false when that position is actually the
    /// combined `"\r\n"` grapheme) and silently falls through to appending
    /// the whole `"\r\n"` literally into the field — corrupting every
    /// record boundary. Scalars don't have this grapheme-clustering
    /// behavior, so `\r`/`\n` are always seen as the two distinct code
    /// points RFC 4180 expects.
    static func parseCSVRecords(_ text: String) -> [[String]] {
        var records: [[String]] = []
        var field = String.UnicodeScalarView()
        var record: [String] = []
        var inQuotes = false
        let scalars = Array(text.unicodeScalars)
        var i = 0

        func endField() { record.append(String(field)); field = String.UnicodeScalarView() }
        func endRecord() { endField(); records.append(record); record = [] }

        while i < scalars.count {
            let c = scalars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < scalars.count, scalars[i + 1] == "\"" {
                        field.append("\""); i += 1   // escaped quote
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(c)
                }
            } else {
                switch c {
                case "\"": inQuotes = true
                case ",": endField()
                case "\r":
                    // Swallow a following \n (CRLF) as one line ending.
                    endRecord()
                    if i + 1 < scalars.count, scalars[i + 1] == "\n" { i += 1 }
                case "\n": endRecord()
                default: field.append(c)
                }
            }
            i += 1
        }
        // Flush a final field/record if the text didn't end with a newline.
        if !field.isEmpty || !record.isEmpty { endRecord() }
        return records
    }
}
