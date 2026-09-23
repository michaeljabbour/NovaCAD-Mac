import Foundation

/// Local display aliases for common Russian architectural names.
/// Unknown text is retained; identifiers in the document are never renamed.
enum LayerDisplayName {
    private static let glossary: [(String, String)] = [
        ("2-ШТРИХ-ШТРИХОВАЯ", "Double dash"),
        ("КРУПНЫЙ ПУНКТИР", "Large dashed"),
        ("МЕТАЛЛ   ТВЕРДЫЙ СПЛАВ", "Metal - hard alloy"),
        ("ЛИНИИ НАКЛОННЫЕ  ШАГ", "Diagonal lines - spacing"),
        ("ШТУКАТУРКА  ГИПС", "Plaster - gypsum"),
        ("ЖЕЛЕЗОБЕТОН", "Reinforced concrete"),
        ("ШТРИХПУНКТИРНАЯ", "Dash-dot"),
        ("НЕВИДИМАЯ", "Hidden"),
        ("ШТРИХОВАЯ", "Dashed"),
        ("С КРУГАМИ", "Circles"),
        ("ЧЕРТЕЖ", "Drawing"),
        ("ЧЕРТЁЖ", "Drawing"),
        ("ЛИНИЯ", "Line"),
        ("КИРПИЧ", "Brick"),
        ("КОВЕР", "Carpet"),
        ("СЕТКА", "Grid"),
        ("РАЗМЕРЫ ВЫНОСКИ ПРИМЕЧАНИЯ", "Dimensions & notes"),
        ("РОЗЕТКИ НАКЛАДНЫЕ ВЫДВИЖНЫЕ", "Surface / retractable outlets"),
        ("УСЛОВНЫЕ ОБОЗНАЧЕНИЯ СКРЫТЬ", "Legend symbols (hide)"),
        ("СТЕНЫ СУЩЕСТВУЮЩИЕ", "Existing walls"),
        ("КОРПУСНАЯ МЕБЕЛЬ", "Cabinetry"),
        ("ШТУКАТУРНЫЙ СЛОЙ", "Plaster finish"),
        ("ПЛИТКА И ПАНЕЛИ", "Tile & panels"),
        ("ПОТОЛКИ ДОП ЭЛЕМЕНТЫ", "Ceiling accessories"),
        ("ПОТОЛКИ ПОКРЫТИЯ", "Ceiling finishes"),
        ("ПОЛЫ ПОКРЫТИЯ", "Floor finishes"),
        ("САНТЕХНИКА ОБОЗНАЧЕНИЯ", "Plumbing symbols"),
        ("ОТДЕЛКА ОБОЗНАЧЕНИЕ", "Finish symbols"),
        ("ЭКСПЛИКАЦИЯ НОВАЯ", "Proposed room schedule"),
        ("СТЕНЫ НОВЫЕ", "New walls"),
        ("СВЕТ ПОТОЛОК", "Ceiling lighting"),
        ("СВЕТ СТЕНЫ", "Wall lighting"),
        ("ОСНВОА", "Base plan"), // Common transposition in supplied drawings.
        ("ОСНОВА", "Base plan"),
        ("ДЕМОНТАЖ", "Demolition"),
        ("МОНТАЖ", "Construction"),
        ("МЕБЕЛЬ", "Furniture"),
        ("КУХНЯ", "Kitchen"),
        ("САНТЕХНИКА", "Plumbing fixtures"),
        ("ВЫКЛЮЧАТЕЛИ", "Switches"),
        ("ЭЛЕКТРОВЫВОДЫ", "Electrical connections"),
        ("РОЗЕТКИ", "Outlets"),
        ("ПОТОЛКИ", "Ceilings"),
        ("СТЕНЫ", "Walls"),
        ("ПОЛЫ", "Floors"),
        ("ГРУППЫ", "Circuits"),
        ("ОТДЕЛКА", "Finishes"),
    ]

    private static let replacements: [(NSRegularExpression, String)] = glossary.map {
        let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: $0.0)
            + "(?![\\p{L}\\p{N}])"
        return (try! NSRegularExpression(pattern: pattern, options: .caseInsensitive), $0.1)
    }

    static func englishAlias(for name: String) -> String? {
        // Preserve xref names verbatim, even when they contain Cyrillic.
        let parts = name.split(separator: "|", omittingEmptySubsequences: false)
        let source = String(parts.last ?? "")
        guard source.range(of: "[А-Яа-яЁё]", options: .regularExpression) != nil else { return nil }
        var translated = source.replacingOccurrences(of: "_", with: " ")
        var changed = false
        for (pattern, replacement) in replacements {
            let range = NSRange(translated.startIndex..., in: translated)
            if pattern.firstMatch(in: translated, range: range) != nil {
                translated = pattern.stringByReplacingMatches(in: translated, range: range,
                                                               withTemplate: replacement)
                changed = true
            }
        }
        guard changed else { return nil }
        return (parts.dropLast().map(String.init) + [translated]).joined(separator: "|")
    }

    static func matches(_ name: String, search: String) -> Bool {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || name.localizedCaseInsensitiveContains(query)
            || (englishAlias(for: name)?.localizedCaseInsensitiveContains(query) ?? false)
    }

    static func display(_ name: String, inEnglish: Bool) -> String {
        inEnglish ? englishAlias(for: name) ?? name : name
    }
}

/// Isolation is a temporary view operation: restoring it must preserve any
/// layers the user had already hidden, including across repeated isolates.
struct LayerIsolationState {
    private(set) var previousHidden: Set<Int>?

    mutating func isolate(_ ids: Set<Int>, allLayerIDs: Set<Int>, hidden: inout Set<Int>) {
        guard !ids.isEmpty else { return }
        if previousHidden == nil { previousHidden = hidden }
        hidden = allLayerIDs.subtracting(ids)
    }

    mutating func restore(hidden: inout Set<Int>) {
        guard let previousHidden else { return }
        hidden = previousHidden
        self.previousHidden = nil
    }
}
