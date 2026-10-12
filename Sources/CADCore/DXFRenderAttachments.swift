import Foundation
import CoreGraphics

/// Raster placement expressed in normalized image coordinates, bottom-left origin.
public struct RasterPlacement {
    public var image: CGImage?
    public var transform: CGAffineTransform
    public var clip: CGPath?
    public var layerId: Int
    public var xrefId: Int
    public var opacity: CGFloat
    public var bounds: CGRect { CGRect(x: 0, y: 0, width: 1, height: 1).applying(transform) }
    public init(image: CGImage?, transform: CGAffineTransform, clip: CGPath? = nil,
                layerId: Int, xrefId: Int = -1, opacity: CGFloat = 1) {
        self.image = image; self.transform = transform; self.clip = clip
        self.layerId = layerId; self.xrefId = xrefId; self.opacity = opacity
    }
}

public struct PaperViewport {
    public var clip: CGPath
    public var modelToPaper: CGAffineTransform
    public var frozenLayerIDs: Set<Int>
    public var layerId: Int
    public var bounds: CGRect { clip.boundingBoxOfPath }
    public init(clip: CGPath, modelToPaper: CGAffineTransform, frozenLayerIDs: Set<Int> = [], layerId: Int) {
        self.clip = clip; self.modelToPaper = modelToPaper; self.frozenLayerIDs = frozenLayerIDs; self.layerId = layerId
    }
}
