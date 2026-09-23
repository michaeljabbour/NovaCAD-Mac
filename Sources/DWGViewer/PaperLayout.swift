import Foundation

/// A named paper sheet, identified by its BLOCK_RECORD rather than by the
/// order or spelling of *Paper_Space blocks in the file.
struct PaperLayout: Identifiable, Equatable {
    let id: UInt64
    let name: String
    let tabOrder: Int
    let blockNames: Set<String>

    /// Navigation excludes empty layouts, not the stored layout records. The
    /// default viewport (ID 1) describes the paper itself and is not content.
    static func navigableSheets(in parsed: EditableParsedDocument) -> [PaperLayout] {
        let ownership = PaperLayoutOwnership(parsed)
        let sheets = ownership.sheets
        var populated = Set<UInt64>()
        for (index, header) in parsed.store.headers.enumerated() {
            guard !header.flags.contains(.deleted) else { continue }
            if header.type == .viewport {
                let viewport = parsed.store.viewports[Int(header.payload)]
                guard viewport.viewportID > 1, viewport.status > 0 else { continue }
            }
            if let owner = ownership.ownerSheetID(for: EntityID(raw: Int32(index)), in: parsed.store) {
                populated.insert(owner)
            }
        }
        return sheets.filter { populated.contains($0.id) }
    }

    static func sheets(in parsed: EditableParsedDocument) -> [PaperLayout] {
        let records = parsed.symbolTables["BLOCK_RECORD"] ?? []
        return parsed.objects.layouts.values.compactMap { layout in
            guard layout.name.caseInsensitiveCompare("Model") != .orderedSame else { return nil }
            let linkedRecord = records.first {
                if case .blockRecord(let handle) = $0.typed { return handle == layout.handle }
                return false
            }
            guard let owner = linkedRecord?.handle ?? layout.blockRecordHandle, owner != 0 else { return nil }
            var names = Set(records.filter { $0.handle == owner }.map(\.name))
            names.formUnion(parsed.blocks.filter { $0.value.blockRecordHandle == owner }.map(\.key))
            return PaperLayout(id: owner, name: layout.name, tabOrder: layout.tabOrder ?? 0,
                               blockNames: names)
        }.sorted {
            $0.tabOrder == $1.tabOrder
                ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                : $0.tabOrder < $1.tabOrder
        }
    }

    func contains(_ id: EntityID, in store: EntityStore, ownership: PaperLayoutOwnership) -> Bool {
        ownership.ownerSheetID(for: id, in: store) == self.id
    }
}

/// Build once per navigation scan or render walk. Both use the same precedence:
/// owning paper block, recognized layout name, explicit BLOCK_RECORD, legacy default.
/// A stale group-410 name falls back to group 330; an unknown explicit owner does
/// not silently move content into the default sheet.
struct PaperLayoutOwnership {
    let sheets: [PaperLayout]
    private let byName: [String: UInt64]
    private let ids: Set<UInt64>
    private let blockOwners: [Int32: UInt64]
    private let defaultOwner: UInt64?

    init(_ parsed: EditableParsedDocument) {
        sheets = PaperLayout.sheets(in: parsed)
        byName = Dictionary(sheets.map { ($0.name.lowercased(), $0.id) }, uniquingKeysWith: { first, _ in first })
        ids = Set(sheets.map(\.id))
        var owners: [Int32: UInt64] = [:]
        for block in parsed.blocks.values {
            if let owner = block.blockRecordHandle, ids.contains(owner) { owners[block.blockIndex] = owner }
        }
        blockOwners = owners
        defaultOwner = sheets.first { $0.blockNames.contains { $0.uppercased() == "*PAPER_SPACE" } }?.id
    }

    func ownerSheetID(for id: EntityID, in store: EntityStore) -> UInt64? {
        guard let header = store.header(id) else { return nil }
        if let owner = blockOwners[header.owner.raw] { return owner }
        guard header.owner.isPaper else { return nil }
        let pairs = store.residualPairs[id.raw]?.pairs ?? []
        if let name = pairs.first(where: { $0.code == 410 })?.value,
           let owner = byName[name.lowercased()] { return owner }
        // Reactor lists may contain their own 330 references. Only an owner
        // outside a group-102 control block describes the entity's layout.
        var controlDepth = 0
        for pair in pairs {
            if pair.code == 102 {
                if pair.value.hasPrefix("{") { controlDepth += 1 }
                else if pair.value == "}" { controlDepth = max(0, controlDepth - 1) }
            } else if pair.code == 330, controlDepth == 0,
                      let owner = UInt64(pair.value.trimmingCharacters(in: .whitespaces), radix: 16) {
                return ids.contains(owner) ? owner : nil
            }
        }
        return defaultOwner
    }
}
