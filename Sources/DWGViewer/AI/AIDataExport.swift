import Foundation

enum AIDataExport {
    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("NovaCAD Exports", isDirectory: true)
    }

    static func writeCSV(columns: [String], rows: [[String]], filename requestedName: String?) throws -> URL {
        guard !columns.isEmpty else { throw ExportError.noColumns }
        let directory = defaultDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let rawName = requestedName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let base = rawName.isEmpty ? "NovaCAD-Export-\(timestamp())" : rawName
        let safe = base
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let filename = safe.lowercased().hasSuffix(".csv") ? safe : safe + ".csv"
        let url = directory.appendingPathComponent(filename)

        var lines = [columns.map(csvField).joined(separator: ",")]
        lines.reserveCapacity(rows.count + 1)
        for row in rows {
            let normalized = (0..<columns.count).map { $0 < row.count ? row[$0] : "" }
            lines.append(normalized.map(csvField).joined(separator: ","))
        }
        try (lines.joined(separator: "\r\n") + "\r\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func csvField(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r") else {
            return value
        }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    enum ExportError: LocalizedError {
        case noColumns
        case malformedDataset

        var errorDescription: String? {
            switch self {
            case .noColumns: return "CSV export requires at least one column."
            case .malformedDataset: return "Dataset JSON must contain string 'columns' and an array of row arrays."
            }
        }
    }
}
