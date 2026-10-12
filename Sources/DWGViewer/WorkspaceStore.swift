import Foundation
import CADCore
import CoreGraphics
import CryptoKit

struct DrawingWorkspace: Codable, Equatable {
    var space: String
    var sheetName: String?
    var zoom: Double
    var centerX: Double
    var centerY: Double
    var hiddenLayers: Set<String>
    var lockedLayers: Set<String>
    var hiddenXrefs: Set<String>
}

struct WorkspacePreset: Codable, Identifiable {
    var id = UUID()
    var name: String
    var workspace: DrawingWorkspace
}

struct WorkspaceRecord: Codable {
    var resourceDirectories: [URL]?
    var lastView: DrawingWorkspace?
    var presets: [WorkspacePreset] = []
    var sheetViewports: [String: DrawingViewport]?
}

/// Small per-file view records; no drawing data or translated identifiers.
enum WorkspaceStore {
    static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NovaCAD/Workspaces", isDirectory: true)
    }
    static func key(for url: URL) -> String {
        SHA256.hash(data: Data(url.standardizedFileURL.resolvingSymlinksInPath().path.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
    static func load(_ url: URL, directory: URL = root) -> WorkspaceRecord {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(key(for: url) + ".json")),
              let record = try? JSONDecoder().decode(WorkspaceRecord.self, from: data) else { return WorkspaceRecord() }
        return record
    }
    static func save(_ record: WorkspaceRecord, for url: URL, directory: URL = root) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: directory.appendingPathComponent(key(for: url) + ".json"), options: .atomic)
    }
}

extension EditableParsedDocument {
    /// Copy-on-write arrays plus independent block/string objects: a worker
    /// can serialize this snapshot while the main actor continues editing.
    func detachedSnapshot() -> EditableParsedDocument {
        let copy = EditableParsedDocument()
        copy.store.restore(fromCheckpoint: store.checkpoint())
        copy.layers = layers; copy.layerIdByName = layerIdByName
        copy.linetypes = linetypes; copy.linetypeIdByName = linetypeIdByName
        copy.ltScale = ltScale; copy.insUnits = insUnits; copy.skippedTypes = skippedTypes
        copy.headerVars = headerVars; copy.classes = classes; copy.symbolTables = symbolTables
        copy.objects = objects; copy.xrefMergeCapped = xrefMergeCapped
        copy.activePaperLayoutID = activePaperLayoutID
        copy.resourceDirectories = resourceDirectories
        for (name, b) in blocks {
            let c = EditableBlockDef()
            c.name = b.name; c.base = b.base; c.flags = b.flags; c.xrefPath = b.xrefPath
            c.xrefSourcePath = b.xrefSourcePath; c.xrefLoadedPath = b.xrefLoadedPath
            c.blockIndex = b.blockIndex; c.entityStart = b.entityStart; c.entityCount = b.entityCount
            c.isXrefDependent = b.isXrefDependent; c.wasResolved = b.wasResolved
            c.handle = b.handle; c.blockRecordHandle = b.blockRecordHandle
            copy.blocks[name] = c
        }
        return copy
    }
}

/// Ownership is transferred to one serial writer after detaching all mutable
/// reference storage. The live session never receives or mutates this copy.
struct DetachedDrawing: @unchecked Sendable {
    let parsed: EditableParsedDocument
    init(_ source: EditableParsedDocument) { parsed = source.detachedSnapshot() }
}
