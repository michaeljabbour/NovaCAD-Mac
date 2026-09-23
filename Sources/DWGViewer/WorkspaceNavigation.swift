import Foundation
import CADCore
import CoreGraphics

/// World-space camera state survives changes in sheet extents and panel size.
struct DrawingViewport: Codable, Equatable {
    var zoom: Double
    var centerX: Double
    var centerY: Double

    static func capture(zoom: CGFloat, pan: CGSize, size: CGSize, bounds: CGRect) -> Self {
        Self(zoom: zoom, centerX: bounds.midX + (size.width / 2 - pan.width) / zoom,
             centerY: bounds.midY - (size.height / 2 - pan.height) / zoom)
    }
    func pan(in size: CGSize, bounds: CGRect) -> CGSize {
        CGSize(width: size.width / 2 + (bounds.midX - centerX) * zoom,
               height: size.height / 2 - (bounds.midY - centerY) * zoom)
    }
    static func fitted(to bounds: CGRect, size: CGSize) -> Self {
        let zoom = bounds.width > 0 && bounds.height > 0 && size.width > 0 && size.height > 0
            ? min(size.width / bounds.width, size.height / bounds.height) * 0.92 : 1
        return Self(zoom: zoom, centerX: bounds.midX, centerY: bounds.midY)
    }
}

enum SearchFraming {
    /// The limiting dimension occupies 28% of the canvas, preserving context
    /// around short labels as well as tall or rotated text.
    static func viewport(for hit: SearchHit, size: CGSize) -> DrawingViewport {
        let box = hit.bounds ?? CGRect(x: hit.position.x - 5, y: hit.position.y - 5, width: 10, height: 10)
        let scale = min(size.width * 0.28 / max(box.width, 1e-6),
                        size.height * 0.28 / max(box.height, 1e-6))
        return DrawingViewport(zoom: min(1e9, max(1e-9, scale)), centerX: box.midX, centerY: box.midY)
    }
}

struct SearchOrigin {
    let space: SpaceSelection
    let sheetID: UInt64?
    let viewport: DrawingViewport
    let selection: Set<EntityID>
}

@MainActor extension DocumentSession {
    var viewport: DrawingViewport {
        DrawingViewport.capture(zoom: zoom, pan: pan, size: viewSize, bounds: viewBounds)
    }
    var viewportKey: String {
        space == .model ? "model" : "paper:\(regen?.parsed.activePaperLayoutID ?? 0)"
    }
    func restoreViewport(_ view: DrawingViewport) {
        guard view.zoom.isFinite, view.zoom > 0, view.centerX.isFinite, view.centerY.isFinite else { return }
        zoom = view.zoom
        pan = view.pan(in: viewSize, bounds: viewBounds)
    }
    func rememberViewport() {
        guard !searchVisible, viewSize.width > 0, viewSize.height > 0 else { return }
        sheetViewports[viewportKey] = viewport
    }
    func switchSpace(to target: SpaceSelection, sheetID: UInt64? = nil) {
        rememberViewport()
        if let sheetID { regen?.selectPaperLayout(sheetID) }
        space = target
        selection = []
        restoreViewport(sheetViewports[viewportKey] ?? .fitted(to: viewBounds, size: viewSize))
        objectWillChange.send()
    }
    func beginSearch() {
        guard !searchVisible else { return }
        rememberViewport()
        searchOrigin = SearchOrigin(space: space, sheetID: regen?.parsed.activePaperLayoutID,
                                    viewport: viewport, selection: selection)
        searchVisible = true
    }
    func endSearch() {
        searchVisible = false
        searchQuery = ""; searchResults = []; searchCursor = -1
        guard let origin = searchOrigin else { return }
        searchOrigin = nil
        if let id = origin.sheetID { regen?.selectPaperLayout(id) }
        space = origin.space
        selection = origin.selection
        restoreViewport(origin.viewport)
        objectWillChange.send()
    }
}
