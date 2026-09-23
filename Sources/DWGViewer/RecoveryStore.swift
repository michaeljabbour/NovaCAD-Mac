import Foundation

struct RecoveryEntry: Codable, Identifiable {
    var id: UUID
    var sourceURL: URL?
    var savedAt: Date
    var snapshotName: String
    var workspace: DrawingWorkspace?
    var resourceDirectories: [URL]
    var warnings: [String]
    var displayName: String { sourceURL?.lastPathComponent ?? "Untitled drawing" }
}

/// Serial disk writes publish the manifest LAST. An interrupted write never
/// replaces the last complete checkpoint or writes to the original drawing.
enum RecoveryStore {
    static let queue = DispatchQueue(label: "novacad.recovery", qos: .utility)
    static var root: URL { WorkspaceStore.root.deletingLastPathComponent().appendingPathComponent("Recovery") }
    static func entries(directory: URL = root) -> [RecoveryEntry] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap {
            guard let data = try? Data(contentsOf: $0), let entry = try? JSONDecoder().decode(RecoveryEntry.self, from: data),
                  FileManager.default.fileExists(atPath: directory.appendingPathComponent(entry.snapshotName).path) else { return nil }
            return entry
        }.sorted { $0.savedAt > $1.savedAt }
    }
    static func write(_ parsed: EditableParsedDocument, entry: RecoveryEntry, directory: URL = root) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest = directory.appendingPathComponent(entry.id.uuidString + ".json")
        let previous = (try? Data(contentsOf: manifest)).flatMap { try? JSONDecoder().decode(RecoveryEntry.self, from: $0) }
        var entry = entry
        let output = directory.appendingPathComponent(entry.snapshotName)
        entry.warnings = try DrawingFileWriter.write(parsed, to: output).map(\.message)
        do { try JSONEncoder().encode(entry).write(to: manifest, options: .atomic) }
        catch { try? FileManager.default.removeItem(at: output); throw error }
        if let previous, previous.snapshotName != entry.snapshotName {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(previous.snapshotName))
        }
    }
    static func discard(_ id: UUID, directory: URL = root) {
        let manifest = directory.appendingPathComponent(id.uuidString + ".json")
        if let data = try? Data(contentsOf: manifest), let entry = try? JSONDecoder().decode(RecoveryEntry.self, from: data) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(entry.snapshotName))
        }
        try? FileManager.default.removeItem(at: manifest)
    }
}

/// The structural writer streams to a sibling temp file; POSIX rename is
/// atomic on this volume and preserves the previous file on write failure.
enum DrawingFileWriter {
    @discardableResult
    static func write(_ parsed: EditableParsedDocument, to url: URL) throws -> [WriteWarning] {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".novacad-\(UUID()).dxf")
        defer { try? FileManager.default.removeItem(at: temporary) }
        var warnings = try DXFStructuralWriter.write(parsed, to: temporary, options: DXFWriteOptions(version: .r2018))
        warnings += parsed.skippedTypes.sorted { $0.key < $1.key }.map {
            WriteWarning(kind: .dropped, message: "\($0.value) unsupported \($0.key) entities were not retained by the parser.")
        }
        if rename(temporary.path, url.path) != 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return warnings
    }
}
