import XCTest
import CoreGraphics
@testable import DWGViewer
import CADCore

/// Proves the renderer actually honors `VisibilityState` — hiding a layer or
/// an xref must remove that content's ink from the rasterized frame. This is
/// the render-level ground truth behind the sidebar eye-toggle: if these pass,
/// any "toggle does nothing on the canvas" bug lives in the SwiftUI redraw
/// trigger, not in the render pipeline.
final class VisibilityRenderTests: XCTestCase {

    /// Counts non-background pixels in a rendered frame (ink coverage).
    private func inkPixels(_ frame: RenderedFrame) -> Int {
        let img = frame.image
        let w = img.width, h = img.height
        let bytesPerRow = w * 4
        var data = [UInt8](repeating: 0, count: bytesPerRow * h)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &data, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                  space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return -1
        }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        // Use the top-left corner pixel as the empirical background color and
        // count anything that differs from it by more than a small tolerance.
        let bg = (r: data[0], g: data[1], b: data[2])
        var ink = 0
        var i = 0
        while i < data.count {
            let dr = abs(Int(data[i]) - Int(bg.r))
            let dg = abs(Int(data[i + 1]) - Int(bg.g))
            let db = abs(Int(data[i + 2]) - Int(bg.b))
            if dr + dg + db > 24 { ink += 1 }
            i += 4
        }
        return ink
    }

    private func render(_ doc: DXFDocument, visibility: VisibilityState) throws -> RenderedFrame {
        var p = RenderParams()
        p.viewSize = CGSize(width: 400, height: 300)
        p.backingScale = 1
        p.darkBackground = true
        p.visibility = visibility
        let fit = doc.modelFitBounds
        p.zoom = min(p.viewSize.width / fit.width, p.viewSize.height / fit.height) * 0.9
        var t = CGAffineTransform.identity
        t = t.translatedBy(x: p.viewSize.width / 2, y: p.viewSize.height / 2)
        t = t.scaledBy(x: p.zoom, y: -p.zoom)
        t = t.translatedBy(x: -fit.midX, y: -fit.midY)
        p.worldToView = t
        return try XCTUnwrap(BitmapRenderer.render(document: doc, params: p))
    }

    func testHidingLayerRemovesInk() throws {
        let doc = try PackageLoader.load(url: TestFixtures.url("resolved_xref.dxf"))
        let allVisible = try render(doc, visibility: VisibilityState())
        let fullInk = inkPixels(allVisible)
        XCTAssertGreaterThan(fullInk, 0, "baseline render must have some ink")

        // Hide every layer that has content — should render (near) nothing.
        var hideAll = VisibilityState()
        hideAll.hiddenLayerIds = Set(doc.layers.map(\.id))
        let hiddenInk = inkPixels(try render(doc, visibility: hideAll))
        XCTAssertLessThan(hiddenInk, fullInk / 4,
                          "hiding all layers must remove most ink (was \(hiddenInk) vs \(fullInk))")
    }

    /// Guards the redraw trigger: `DXFCanvasView.Coordinator.requestIfNeeded`
    /// re-renders only when `params != lastRequested`, so a visibility change
    /// MUST make two otherwise-identical `RenderParams` compare unequal — if a
    /// refactor ever dropped `visibility` from the synthesized `Equatable`,
    /// toggling the eye icon would silently stop updating the canvas.
    func testVisibilityChangeMakesRenderParamsUnequal() {
        var a = RenderParams()
        var b = RenderParams()
        XCTAssertEqual(a, b)
        b.visibility.hiddenLayerIds.insert(7)
        XCTAssertNotEqual(a, b, "hiding a layer must change RenderParams equality")
        a.visibility.hiddenLayerIds.insert(7)
        XCTAssertEqual(a, b)
        b.visibility.hiddenXrefIds.insert(3)
        XCTAssertNotEqual(a, b, "hiding an xref must change RenderParams equality")
    }

    func testHidingXrefRemovesInk() throws {
        let doc = try PackageLoader.load(url: TestFixtures.url("resolved_xref.dxf"))
        guard let xref = doc.xrefs.first else {
            throw XCTSkip("fixture has no xref")
        }
        let fullInk = inkPixels(try render(doc, visibility: VisibilityState()))
        var hideXref = VisibilityState()
        hideXref.hiddenXrefIds = [xref.id]
        let afterInk = inkPixels(try render(doc, visibility: hideXref))
        XCTAssertLessThan(afterInk, fullInk,
                          "hiding the xref must remove some ink (was \(afterInk) vs \(fullInk))")
    }

    /// The above tests use the OLD parse path (`PackageLoader.load` ->
    /// `GeometryBuilder`). The LIVE app renders the NEW path
    /// (`PackageLoader.loadIntoStore` -> `Regenerator.build`, via
    /// `RegenCoordinator.loadPackage`). This pins the SAME "hiding an xref
    /// removes its ink" guarantee on that exact path, so a regression there
    /// (the path the live app actually uses) is caught by CI.
    func testHidingXrefRemovesInkOnLivePath() throws {
        let parsed = try PackageLoader.loadIntoStore(url: TestFixtures.url("resolved_xref.dxf"), progress: { _ in })
        let doc = Regenerator.build(from: parsed, parseSeconds: 0) { _ in }
        guard let xref = doc.xrefs.first(where: { $0.isResolved }) else {
            throw XCTSkip("fixture has no resolved xref on the live path")
        }
        // Confirm the xref's content is actually tagged onto render groups —
        // otherwise "hiding" it could pass vacuously.
        let taggedGroups = doc.modelGroups.filter { $0.xrefId == xref.id }
        XCTAssertFalse(taggedGroups.isEmpty,
                       "live path must tag this xref's geometry with its xrefId")

        let fullInk = inkPixels(try render(doc, visibility: VisibilityState()))
        XCTAssertGreaterThan(fullInk, 0)
        var hideXref = VisibilityState()
        hideXref.hiddenXrefIds = doc.xrefs.subtreeXrefIds(of: xref)
        let afterInk = inkPixels(try render(doc, visibility: hideXref))
        XCTAssertLessThan(afterInk, fullInk,
                          "hiding the xref (live path) must remove some ink (was \(afterInk) vs \(fullInk))")
    }
}
