import Foundation

/// Interns strings so repeated text (layer names, block names, and above all
/// TEXT/MTEXT/ATTRIB contents — plant layouts repeat labels heavily) is stored
/// once, addressed by a 4-byte `Int32` rather than a 16-byte `String` header
/// per occurrence in every `EntityStore` payload that references text.
final class StringTable {
    private(set) var strings: [String] = []
    private var index: [String: Int32] = [:]

    /// Interns `s`, returning its stable id. Repeated calls with an equal
    /// string return the same id.
    @discardableResult
    func intern(_ s: String) -> Int32 {
        if let existing = index[s] { return existing }
        let id = Int32(strings.count)
        strings.append(s)
        index[s] = id
        return id
    }

    func string(for id: Int32) -> String {
        guard id >= 0, Int(id) < strings.count else { return "" }
        return strings[Int(id)]
    }

    var count: Int { strings.count }

    /// Deep copy — used by `EntityStore.checkpoint()` (Phase 1.8's
    /// `--edit-script save` command) to snapshot interned strings alongside
    /// the entity arrays that reference them by id.
    func clone() -> StringTable {
        let copy = StringTable()
        copy.strings = strings
        copy.index = index
        return copy
    }

    /// Overwrites this table's contents with `other`'s — `EntityStore` is a
    /// reference type held via `let strings`, so restoring a checkpoint
    /// mutates the existing `StringTable` in place rather than replacing it.
    func replaceContents(with other: StringTable) {
        strings = other.strings
        index = other.index
    }
}
