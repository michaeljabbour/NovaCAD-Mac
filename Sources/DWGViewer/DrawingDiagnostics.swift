import CADCore
import Foundation

/// Annotation units can differ legitimately from coordinate units. Explain
/// the distinction rather than guessing a new scale from arbitrary text.
enum DrawingDiagnostics {
    static func unitNotice(in document: DXFDocument) -> String? {
        guard [4, 5, 6].contains(document.insUnits) else { return nil }
        let hasImperialNotes = (document.modelGroups + document.paperGroups).contains { group in
            group.texts.contains { item in
                item.text.range(of: #"(?i)\b(?:ft(?:2|²)?|feet|inches)\b|ft²|ft\^2"#, options: .regularExpression) != nil
            }
        }
        guard hasImperialNotes else { return nil }
        return "Drawing coordinates use \(document.unitsLabel), while some annotations use feet or square feet. These may be intentional conversions. Measurements follow the drawing coordinate units and your selected display format; annotation text does not set the scale."
    }
}
