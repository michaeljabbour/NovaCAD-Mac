import SwiftUI
import CADCore

extension DocumentSession {
    var currentLayerUsage: [Int: LayerUsage] {
        guard let regen else { return [:] }
        let key = ObjectIdentifier(regen.document)
        if let cache = layerUsageCache, cache.0 == key, cache.1 == regen.revision, cache.2 == space { return cache.3 }
        let result = LayerUsage.summary(document: regen.document, paper: space == .paper)
        layerUsageCache = (key, regen.revision, space, result)
        return result
    }
    var viewBounds: CGRect {
        guard let document else { return .zero }
        return space == .paper ? document.paperFitBounds : document.modelFitBounds
    }
    func captureWorkspace() -> DrawingWorkspace? {
        guard let document, zoom.isFinite, zoom > 0, viewSize.width > 0, viewSize.height > 0 else { return nil }
        return DrawingWorkspace(space: space.rawValue,
            sheetName: regen?.parsed.paperLayouts.first { $0.id == regen?.parsed.activePaperLayoutID }?.name,
            zoom: Double(zoom), centerX: Double(viewBounds.midX + (viewSize.width / 2 - pan.width) / zoom),
            centerY: Double(viewBounds.midY - (viewSize.height / 2 - pan.height) / zoom),
            hiddenLayers: Set(document.layers.filter { visibility.hiddenLayerIds.contains($0.id) }.map(\.name)),
            lockedLayers: Set(document.layers.filter { visibility.lockedLayerIds.contains($0.id) }.map(\.name)),
            hiddenXrefs: Set(document.xrefs.filter { visibility.hiddenXrefIds.contains($0.id) }.map(\.blockName)))
    }
    @discardableResult
    func restoreWorkspace(_ view: DrawingWorkspace) -> Bool {
        guard let regen, view.zoom.isFinite, view.zoom > 0, view.centerX.isFinite, view.centerY.isFinite else { return false }
        if viewSize.width <= 0 || viewSize.height <= 0 { pendingWorkspace = view; return true }
        var replacedEmptyLayout = false
        if let name = view.sheetName {
            if let sheet = regen.navigationPaperLayouts.first(where: { $0.name == name }) {
                regen.selectPaperLayout(sheet.id)
            } else if let first = regen.navigationPaperLayouts.first {
                regen.selectPaperLayout(first.id)
                replacedEmptyLayout = true
            }
        }
        let restoredSpace = SpaceSelection(rawValue: view.space) ?? .model
        space = restoredSpace
        let doc = regen.document
        visibility.hiddenLayerIds = Set(doc.layers.filter { view.hiddenLayers.contains($0.name) }.map(\.id))
        visibility.lockedLayerIds = Set(doc.layers.filter { view.lockedLayers.contains($0.name) }.map(\.id))
        visibility.hiddenXrefIds = Set(doc.xrefs.filter { view.hiddenXrefs.contains($0.blockName) }.map(\.id))
        zoom = min(1e9, max(1e-9, view.zoom))
        pan = CGSize(width: viewSize.width / 2 + (viewBounds.midX - view.centerX) * zoom,
                     height: viewSize.height / 2 - (viewBounds.midY - view.centerY) * zoom)
        if replacedEmptyLayout && space == .paper {
            restoreViewport(.fitted(to: viewBounds, size: viewSize))
        }
        selection = []
        pendingWorkspace = nil
        objectWillChange.send()
        return true
    }
    func persistWorkspace() {
        guard !isLoading, !searchVisible, let url = currentSourceURL, let view = captureWorkspace() else { return }
        rememberViewport()
        var record = WorkspaceStore.load(url)
        record.lastView = view
        record.sheetViewports = sheetViewports
        record.resourceDirectories = regen?.parsed.resourceDirectories
        do { try WorkspaceStore.save(record, for: url) }
        catch { workspaceError = "Could not remember this view: \(error.localizedDescription)" }
    }
    func savePreset(name: String) {
        guard let url = currentSourceURL, let view = captureWorkspace() else { return }
        var record = WorkspaceStore.load(url)
        record.presets.removeAll { $0.name == name }
        record.presets.append(WorkspacePreset(name: name, workspace: view))
        do { try WorkspaceStore.save(record, for: url); presets = record.presets }
        catch { alertMessage = error.localizedDescription }
    }
    func deletePreset(_ id: UUID) {
        guard let url = currentSourceURL else { return }
        var record = WorkspaceStore.load(url)
        record.presets.removeAll { $0.id == id }
        do { try WorkspaceStore.save(record, for: url); presets = record.presets }
        catch { alertMessage = error.localizedDescription }
    }
    var hasUnsavedChanges: Bool { recoveredDocument || (editableDocument?.revision ?? 0) != savedRevision }
    func markSaved(to url: URL) {
        persistWorkspace()
        currentSourceURL = url
        recoveredDocument = false
        savedRevision = editableDocument?.revision ?? 0
        lastRecoveryRevision = savedRevision
        recoveryGeneration += 1
        let id = recoveryID
        let recoveredID = recoveredFromID
        recoveredFromID = nil
        RecoveryStore.queue.async {
            RecoveryStore.discard(id)
            if let recoveredID { RecoveryStore.discard(recoveredID) }
        }
        recoveryStatus = "Saved"
        persistWorkspace()
    }
    func scheduleRecovery() {
        recoveryTask?.cancel()
        recoveryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            self?.checkpointRecovery()
        }
    }
    func checkpointRecovery() {
        guard !isLoading, let parsed = regen?.parsed, hasUnsavedChanges,
              lastRecoveryRevision != parsed.document.revision else { return }
        let revision = parsed.document.revision
        let snapshot = DetachedDrawing(parsed)
        let entry = RecoveryEntry(id: recoveryID, sourceURL: currentSourceURL, savedAt: Date(),
            snapshotName: "\(recoveryID)-\(UUID()).dxf", workspace: captureWorkspace(),
            resourceDirectories: parsed.resourceDirectories, warnings: [])
        let generation = recoveryGeneration
        lastRecoveryRevision = revision
        recoveryStatus = "Saving recovery copy…"
        RecoveryStore.queue.async { [weak self] in
            do {
                try RecoveryStore.write(snapshot.parsed, entry: entry)
                Task { @MainActor [weak self] in
                    guard let self, self.recoveryGeneration == generation else { return }
                    self.recoveryStatus = "Recovery copy saved"
                }
            } catch {
                let message = error.localizedDescription
                Task { @MainActor [weak self] in
                    guard let self, self.recoveryGeneration == generation else { return }
                    self.lastRecoveryRevision = nil
                    self.recoveryStatus = "Recovery failed: \(message)"
                }
            }
        }
    }
}

@MainActor
enum DocumentSessionRegistry {
    static let sessions = NSHashTable<DocumentSession>.weakObjects()
    static func checkpointAll() {
        for session in sessions.allObjects { session.persistWorkspace(); session.checkpointRecovery() }
    }
}
