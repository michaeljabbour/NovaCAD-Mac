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
    /// The unobscured canvas rectangle in drawing coordinates (Y points up).
    func visibleBounds(size: CGSize) -> CGRect? {
        guard zoom.isFinite, zoom > 0, centerX.isFinite, centerY.isFinite,
              size.width.isFinite, size.height.isFinite, size.width > 1, size.height > 1 else { return nil }
        let width = size.width / zoom, height = size.height / zoom
        guard width.isFinite, height.isFinite else { return nil }
        return CGRect(x: centerX - width / 2, y: centerY - height / 2, width: width, height: height)
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

    /// A fitted drawing follows the available canvas; a manually positioned
    /// camera keeps its scale and world center when a panel opens or closes.
    func resized(from oldSize: CGSize, to newSize: CGSize, fitBounds: [CGRect]) -> Self {
        guard oldSize.width > 0, oldSize.height > 0, newSize.width > 0, newSize.height > 0 else { return self }
        for bounds in fitBounds where bounds.width > 0 && bounds.height > 0 {
            let fitted = Self.fitted(to: bounds, size: oldSize)
            // Restored views can differ by a few pixels after toolbar metrics
            // change. Treat an otherwise centered view within 1% as fitted.
            let sameScale = abs(zoom - fitted.zoom) <= max(1e-9, fitted.zoom * 0.01)
            let sameCenter = abs(centerX - fitted.centerX) * zoom <= 1
                && abs(centerY - fitted.centerY) * zoom <= 1
            if sameScale && sameCenter { return Self.fitted(to: bounds, size: newSize) }
        }
        return self
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

/// Priority of camera restoration when the canvas changes size. Kept outside
/// the view so a pending restore cannot accidentally lose to search or first fit.
enum CanvasResizeAction: Equatable {
    case waitForSize, restoreWorkspace, frameSearchMatch, initialFit, resizeViewport

    static func decide(previous: CGSize, next: CGSize, hasPendingWorkspace: Bool,
                       searchVisible: Bool, hasSearchMatch: Bool) -> Self {
        guard next.width > 1, next.height > 1 else { return .waitForSize }
        if hasPendingWorkspace { return .restoreWorkspace }
        if searchVisible && hasSearchMatch { return .frameSearchMatch }
        if previous.width <= 1 || previous.height <= 1 { return .initialFit }
        return .resizeViewport
    }
}
