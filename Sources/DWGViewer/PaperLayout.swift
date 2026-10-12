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
        let sheets = sheets(in: parsed)
        let byName = Dictionary(uniqueKeysWithValues: sheets.map { ($0.name.lowercased(), $0.id) })
        let ids = Set(sheets.map(\.id))
        var blockOwners: [Int32: UInt64] = [:]
        for block in parsed.blocks.values {
            if let owner = block.blockRecordHandle, ids.contains(owner) { blockOwners[block.blockIndex] = owner }
        }
        let defaultOwner = sheets.first { $0.blockNames.contains { $0.uppercased() == "*PAPER_SPACE" } }?.id
        var populated = Set<UInt64>()
        for (index, header) in parsed.store.headers.enumerated() {
            guard !header.flags.contains(.deleted), header.owner.isPaper || blockOwners[header.owner.raw] != nil else { continue }
            if header.type == .viewport {
                let viewport = parsed.store.viewports[Int(header.payload)]
                guard viewport.viewportID > 1, viewport.status > 0 else { continue }
            }
            if let owner = blockOwners[header.owner.raw] { populated.insert(owner); continue }
            let pairs = parsed.store.residualPairs[Int32(index)]?.pairs ?? []
            let named = pairs.first { $0.code == 410 }.flatMap { byName[$0.value.lowercased()] }
            let owner = pairs.first { $0.code == 330 }.flatMap {
                UInt64($0.value.trimmingCharacters(in: .whitespaces), radix: 16)
            }
            if let id = named ?? owner ?? defaultOwner, ids.contains(id) { populated.insert(id) }
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

    func contains(_ id: EntityID, in store: EntityStore) -> Bool {
        let pairs = store.residualPairs[id.raw]?.pairs ?? []
        // Group 410 is the explicit layout name. Group 330 is the owning
        // BLOCK_RECORD; it must not be confused with a reactor's group 330.
        if let name = pairs.first(where: { $0.code == 410 })?.value {
            return name.caseInsensitiveCompare(self.name) == .orderedSame
        }
        if let value = pairs.first(where: { $0.code == 330 })?.value,
           let owner = UInt64(value.trimmingCharacters(in: .whitespaces), radix: 16) {
            return owner == self.id
        }
        // Older DXFs omit the owner on ENTITIES-section paper content; that
        // section belongs to the active *Paper_Space block, not every sheet.
        return blockNames.contains { $0.uppercased() == "*PAPER_SPACE" }
    }
}
