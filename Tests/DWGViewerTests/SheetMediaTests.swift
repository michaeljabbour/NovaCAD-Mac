import XCTest
import CoreGraphics
import ImageIO
import CADCore
@testable import DWGViewer

final class SheetMediaTests: XCTestCase {
    private func parsed() throws -> EditableParsedDocument {
        try EntityStoreParser.parse(url: TestFixtures.url("multiple_layouts.dxf"))
    }
    private func addPaper(_ payload: EntityPayloadCopy, type: DXFEntityType, to parsed: EditableParsedDocument) -> EntityID {
        let id = parsed.store.append(EntityPrototype(type: type, layerId: 0, owner: .paper, payload: payload))
        parsed.store.residualPairs[id.raw] = RawPairBlob(pairs: [(330, "23")])
        return id
    }
    func testViewportRoundtripPreservesTwistTargetFrozenLayersAndStatus() throws {
        let parsed = try parsed()
        var p = ViewportPayload(centerPaper: Vec3(x: 100, y: 100), widthPaper: 40, heightPaper: 20,
                                viewCenter: Vec3(x: 5, y: 6), viewHeight: 10, twistDeg: 90, status: -1)
        p.viewportID = 3; p.target = Vec3(x: 20, y: 30)
        p.frozenLayerHandles = [0xCA]; p.flags = 16384
        _ = addPaper(.viewport(p), type: .viewport, to: parsed)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("vp-\(UUID()).dxf")
        defer { try? FileManager.default.removeItem(at: url) }
        try DrawingFileWriter.write(parsed, to: url)
        let restored = try EntityStoreParser.parse(url: url)
        let vp = try XCTUnwrap(restored.store.viewports.first)
        XCTAssertEqual(vp.twistDeg, 90); XCTAssertEqual(vp.target.x, 20)
        XCTAssertEqual(vp.status, -1); XCTAssertEqual(vp.flags, 16384)
        XCTAssertEqual(vp.viewportID, 3); XCTAssertEqual(vp.frozenLayerHandles, [0xCA])
        restored.activePaperLayoutID = 0x23
        let doc = Regenerator.build(from: restored, parseSeconds: 0, progress: { _ in })
        XCTAssertEqual(doc.paperViewports.count, 1)
        let transform = try XCTUnwrap(doc.paperViewports.first).modelToPaper
        let target = CGPoint(x: 20, y: 30).applying(transform)
        XCTAssertEqual(target.x, 90, accuracy: 1e-8)
        XCTAssertEqual(target.y, 88, accuracy: 1e-8)
        restored.activePaperLayoutID = 0x1B
        XCTAssertTrue(Regenerator.build(from: restored, parseSeconds: 0, progress: { _ in }).paperViewports.isEmpty)
    }
    func testViewportRenderingClipsModelAndHonorsFrozenLayers() throws {
        let parsed = EditableParsedDocument()
        parsed.layers = [DXFLayer(id: 0, name: "0", handle: 0xCA)]
        parsed.layerIdByName = ["0": 0]
        parsed.linetypes = [DXFLinetype(name: "CONTINUOUS", dashes: [])]
        _ = parsed.store.append(EntityPrototype(type: .line, layerId: 0, owner: .model,
            payload: .line(LinePayload(a: Vec3(x: -50, y: 0), b: Vec3(x: 50, y: 0)))))
        var viewport = ViewportPayload(centerPaper: Vec3(x: 50, y: 50), widthPaper: 20, heightPaper: 20,
            viewCenter: Vec3(x: 0, y: 0), viewHeight: 20)
        viewport.viewportID = 2
        _ = parsed.store.append(EntityPrototype(type: .viewport, layerId: 0, owner: .paper, payload: .viewport(viewport)))
        func pixel(_ x: Int, frozen: Bool) throws -> UInt8 {
            parsed.store.viewports[0].frozenLayerHandles = frozen ? [0xCA] : []
            let doc = Regenerator.build(from: parsed, parseSeconds: 0, progress: { _ in })
            let ctx = try XCTUnwrap(CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 400,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            var params = RenderParams()
            params.viewSize = CGSize(width: 100, height: 100); params.backingScale = 1
            params.usePaperSpace = true; params.darkBackground = false; params.quality = 1
            params.worldToView = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 100)
            XCTAssertTrue(CGRenderCore.draw(into: ctx, document: doc, params: params))
            let bytes = try XCTUnwrap(ctx.data).bindMemory(to: UInt8.self, capacity: 40000)
            return min(bytes[(49 * 100 + x) * 4], bytes[(50 * 100 + x) * 4])
        }
        XCTAssertLessThan(try pixel(50, frozen: false), 128)
        XCTAssertEqual(try pixel(20, frozen: false), 255, "Model must not spill outside its viewport")
        XCTAssertEqual(try pixel(50, frozen: true), 255)
    }

    func testUnsupportedPerspectiveIsReportedAndOffViewportIsIgnored() throws {
        let parsed = try parsed()
        var p = ViewportPayload(centerPaper: Vec3(x: 100, y: 100), widthPaper: 40, heightPaper: 20,
                                viewCenter: Vec3(x: 0, y: 0), viewHeight: 10)
        p.flags = 1
        let support = SheetRenderSupport(parsed)
        XCTAssertNil(support.viewport(p, transform: .identity, layer: 0))
        XCTAssertFalse(support.warnings.isEmpty)
        p.flags = 0; p.status = 0
        XCTAssertNil(support.viewport(p, transform: .identity, layer: 0))
    }
    func testImagePixelsResolveAndClipPropertiesSurviveSave() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let context = try XCTUnwrap(CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let png = try XCTUnwrap(CGImageDestinationCreateWithURL(dir.appendingPathComponent("image.png") as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(png, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(png))
        let parsed = try parsed()
        parsed.resourceDirectories = [dir]
        parsed.objects.imageDefs[0xABC] = ImageDefObject(handle: 0xABC, ownerHandle: 0, fileName: "image.png", imageSizePx: nil, rawPairs: [])
        var p = ImagePayload(origin: Vec3(x: 100, y: 100), uVector: Vec3(x: 2, y: 0), vVector: Vec3(x: 0, y: 2), sizePxWidth: 4, sizePxHeight: 4, imageDefHandle: 0xABC)
        p.displayFlags = 7; p.clipping = true; p.clipVertices = [Vec3(x: -0.5, y: -0.5), Vec3(x: 1.5, y: 3.5)]
        let raster = try XCTUnwrap(SheetRenderSupport(parsed).raster(p, transform: .identity, layer: 0, xref: -1))
        XCTAssertNotNil(raster.image); XCTAssertEqual(raster.bounds.width, 8)
        XCTAssertEqual(raster.clip?.boundingBoxOfPath.width, 0.5)
        _ = addPaper(.image(p), type: .image, to: parsed)
        let url = dir.appendingPathComponent("roundtrip.dxf")
        try DrawingFileWriter.write(parsed, to: url)
        let restored = try EntityStoreParser.parse(url: url)
        XCTAssertEqual(restored.store.images.count, 1)
        XCTAssertEqual(restored.store.images[0].clipVertices.count, 2)
        XCTAssertTrue(restored.store.images[0].clipping)
        restored.activePaperLayoutID = 0x23
        let doc = Regenerator.build(from: restored, parseSeconds: 0, progress: { _ in })
        XCTAssertEqual(doc.paperImages.count, 1)
        XCTAssertNotNil(doc.paperImages[0].image)
        XCTAssertTrue(doc.renderingWarnings.isEmpty)
    }
    func testXrefImageHandlesAreRemappedInsteadOfShowingHostImage() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let host = try EntityStoreParser.parse(url: TestFixtures.url("xref_host.dxf"))
        let sub = try EntityStoreParser.parse(url: TestFixtures.url("resolved_xref.dxf"))
        for (parsed, name) in [(host, "host.png"), (sub, "sub.png")] {
            try Data().write(to: dir.appendingPathComponent(name))
            parsed.resourceDirectories = [dir]
            parsed.objects.imageDefs[0xABC] = ImageDefObject(handle: 0xABC, ownerHandle: 0,
                fileName: name, imageSizePx: nil, rawPairs: [])
            _ = parsed.store.append(EntityPrototype(type: .image, layerId: 0, owner: .model,
                payload: .image(ImagePayload(origin: Vec3(x: 0, y: 0), uVector: Vec3(x: 1, y: 0),
                    vVector: Vec3(x: 0, y: 1), sizePxWidth: 1, sizePxHeight: 1, imageDefHandle: 0xABC))))
        }
        try DrawingFileWriter.write(host, to: dir.appendingPathComponent("host.dxf"))
        try DrawingFileWriter.write(sub, to: dir.appendingPathComponent("resolved_xref.dxf"))
        let merged = try PackageLoader.loadIntoStore(url: dir.appendingPathComponent("host.dxf"))
        let handles = Set(merged.store.images.map(\.imageDefHandle))
        XCTAssertEqual(handles.count, 2)
        let paths = Set(handles.compactMap { handle in merged.objects.imageDefs.values.first { $0.handle == handle }?.fileName })
        XCTAssertEqual(paths, [dir.appendingPathComponent("host.png").path, dir.appendingPathComponent("sub.png").path])
    }

    func testMissingImageHasPlaceholderAndActionableWarning() throws {
        let parsed = try parsed()
        let p = ImagePayload(origin: Vec3(x: 100, y: 100), uVector: Vec3(x: 1, y: 0), vVector: Vec3(x: 0, y: 1), sizePxWidth: 20, sizePxHeight: 10)
        _ = addPaper(.image(p), type: .image, to: parsed)
        parsed.activePaperLayoutID = 0x23
        let doc = Regenerator.build(from: parsed, parseSeconds: 0, progress: { _ in })
        XCTAssertEqual(doc.paperImages.count, 1)
        XCTAssertNil(doc.paperImages[0].image)
        XCTAssertTrue(doc.renderingWarnings.contains { $0.contains("Missing or unreadable image") })
        XCTAssertEqual(doc.paperBounds.maxX, 120)
    }
}
