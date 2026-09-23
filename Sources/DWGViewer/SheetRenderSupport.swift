import Foundation
import CADCore
import CoreGraphics
import ImageIO

/// Resolves only local resources. A drawing never causes a remote image fetch.
final class SheetRenderSupport {
    let parsed: EditableParsedDocument
    var warnings = Set<String>()
    private var images: [URL: CGImage] = [:]
    private var missing = Set<String>()
    init(_ parsed: EditableParsedDocument) { self.parsed = parsed }

    static func resourceURL(_ name: String, directories: [URL]) -> URL? {
        let path = name.replacingOccurrences(of: "\\", with: "/")
        guard !path.contains("://") else { return nil }
        var candidates: [URL] = []
        if path.hasPrefix("/") { candidates.append(URL(fileURLWithPath: path)) }
        let basename = (path as NSString).lastPathComponent
        for directory in directories {
            candidates.append(directory.appendingPathComponent(path))
            candidates.append(directory.appendingPathComponent(basename))
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    func raster(_ p: ImagePayload, transform: CGAffineTransform, layer: Int, xref: Int) -> RasterPlacement? {
        guard p.displayFlags & 1 != 0 else { return nil }
        guard p.sizePxWidth > 0, p.sizePxHeight > 0,
              p.sizePxWidth.isFinite, p.sizePxHeight.isFinite else {
            warnings.insert("An image has invalid pixel dimensions."); return nil
        }
        let definition = parsed.objects.imageDefs.values.first { $0.handle == p.imageDefHandle }
        let name = definition?.fileName ?? "IMAGEDEF \(String(p.imageDefHandle, radix: 16))"
        var image: CGImage?
        if let url = Self.resourceURL(name, directories: parsed.resourceDirectories) {
            image = images[url]
            if image == nil, !missing.contains(name),
               let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
                // Bound decode memory while retaining enough detail for architectural sheets.
                let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 12000, kCGImageSourceShouldCacheImmediately: true]
                image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
                if let image { images[url] = image }
            }
        }
        if image == nil { missing.insert(name); warnings.insert("Missing or unreadable image: \(name)") }
        if p.brightness != 50 || p.contrast != 50 {
            warnings.insert("Image brightness/contrast adjustments are not applied; original pixels are displayed.")
        }
        let placement = CGAffineTransform(a: p.uVector.x * p.sizePxWidth, b: p.uVector.y * p.sizePxWidth,
            c: p.vVector.x * p.sizePxHeight, d: p.vVector.y * p.sizePxHeight,
            tx: p.origin.x, ty: p.origin.y).concatenating(transform)
        guard [placement.a, placement.b, placement.c, placement.d, placement.tx, placement.ty].allSatisfy(\.isFinite),
              abs(placement.a * placement.d - placement.b * placement.c) > 1e-15 else { return nil }
        var clip: CGPath?
        if p.clipping && p.displayFlags & 4 != 0 && p.clipVertices.count >= 2 {
            let points = p.clipVertices.map { CGPoint(x: ($0.x + 0.5) / p.sizePxWidth, y: ($0.y + 0.5) / p.sizePxHeight) }
            let path = CGMutablePath()
            if points.count == 2 {
                path.addRect(CGRect(x: min(points[0].x, points[1].x), y: min(points[0].y, points[1].y),
                    width: abs(points[1].x - points[0].x), height: abs(points[1].y - points[0].y)))
            } else { path.addLines(between: points); path.closeSubpath() }
            if p.clipInverted { path.addRect(CGRect(x: 0, y: 0, width: 1, height: 1)) }
            clip = path
        }
        return RasterPlacement(image: image, transform: placement, clip: clip, layerId: layer, xrefId: xref,
                               opacity: CGFloat(1 - Double(min(100, max(0, p.fade))) / 100.0))
    }

    func viewport(_ p: ViewportPayload, transform: CGAffineTransform, layer: Int) -> PaperViewport? {
        guard p.viewportID != 1, p.status != 0, p.flags & 131072 == 0 else { return nil }
        guard p.widthPaper > 0, p.heightPaper > 0, p.viewHeight > 0,
              [p.widthPaper, p.heightPaper, p.viewHeight, p.twistDeg].allSatisfy(\.isFinite) else {
            warnings.insert("A viewport has invalid dimensions."); return nil
        }
        guard abs(p.direction.x) < 1e-8, abs(p.direction.y) < 1e-8, p.direction.z > 0,
              p.flags & 7 == 0 else {
            warnings.insert("A 3D, perspective, or depth-clipped viewport is not rendered. Use a top-down 2D viewport."); return nil
        }
        let scale = p.heightPaper / p.viewHeight
        var t = CGAffineTransform(translationX: p.centerPaper.x, y: p.centerPaper.y)
        t = t.scaledBy(x: scale, y: scale)
        t = t.translatedBy(x: -p.viewCenter.x, y: -p.viewCenter.y)
        t = t.rotated(by: -p.twistDeg * .pi / 180)
        t = t.translatedBy(x: -p.target.x, y: -p.target.y)
        let rect = CGRect(x: p.centerPaper.x - p.widthPaper / 2, y: p.centerPaper.y - p.heightPaper / 2,
                          width: p.widthPaper, height: p.heightPaper)
        var clip = CGPath(rect: rect, transform: nil)
        if p.flags & 65536 != 0 {
            guard let boundary = clipBoundary(handle: p.clipHandle) else {
                warnings.insert("A viewport's nonrectangular clipping boundary could not be rendered."); return nil
            }
            clip = boundary
        }
        var transform = transform
        clip = clip.copy(using: &transform) ?? clip
        let handles = Set(p.frozenLayerHandles)
        return PaperViewport(clip: clip, modelToPaper: t.concatenating(transform),
            frozenLayerIDs: Set(parsed.layers.filter { handles.contains($0.handle) }.map(\.id)), layerId: layer)
    }

    private func clipBoundary(handle: UInt64) -> CGPath? {
        guard let id = parsed.store.entity(forHandle: handle), let h = parsed.store.header(id) else { return nil }
        let store = parsed.store
        let path = CGMutablePath()
        if h.type == .circle {
            let p = store.circles[Int(h.payload)]
            path.addEllipse(in: CGRect(x: p.center.x - p.radius, y: p.center.y - p.radius, width: p.radius * 2, height: p.radius * 2))
        } else if [.lwpolyline, .polyline2d].contains(h.type) {
            let p = store.polylines[Int(h.payload)]
            guard p.vertsCount >= 3 else { return nil }
            // Curved clipping boundaries are preserved but flagged instead of approximated silently.
            if p.bulgesStart >= 0, (0..<Int(p.vertsCount)).contains(where: { abs(store.scalarArena[Int(p.bulgesStart) + $0]) > 1e-10 }) { return nil }
            let points = (0..<Int(p.vertsCount)).map { i -> CGPoint in
                let v = store.vertexArena[Int(p.vertsStart) + i]; return CGPoint(x: v.x, y: v.y)
            }
            path.addLines(between: points); path.closeSubpath()
        } else { return nil }
        return path
    }
}
