import XCTest
import CoreGraphics
@testable import DWGViewer
import CADCore

/// Verifies the render coalescing queue (`BitmapRenderer`) always converges —
/// rapid-fire requests (simulating fast xref/layer toggles + pan/zoom on a
/// large drawing) must still deliver a final frame and never latch `busy`
/// permanently, which was the "canvas frozen, pan/zoom does nothing" bug.
final class RenderQueueTests: XCTestCase {

    private func tinyDoc() throws -> DXFDocument {
        // A minimal real document via the live parse path.
        let parsed = try PackageLoader.loadIntoStore(url: TestFixtures.url("resolved_xref.dxf"), progress: { _ in })
        return Regenerator.build(from: parsed, parseSeconds: 0) { _ in }
    }

    private func params(_ doc: DXFDocument, zoom: CGFloat) -> RenderParams {
        var p = RenderParams()
        p.viewSize = CGSize(width: 200, height: 150)
        p.backingScale = 1
        p.zoom = zoom
        let fit = doc.modelFitBounds
        var t = CGAffineTransform.identity
        t = t.translatedBy(x: p.viewSize.width / 2, y: p.viewSize.height / 2)
        t = t.scaledBy(x: zoom, y: -zoom)
        t = t.translatedBy(x: -fit.midX, y: -fit.midY)
        p.worldToView = t
        return p
    }

    func testRapidRequestsStillDeliverAFinalFrame() throws {
        let doc = try tinyDoc()
        let renderer = BitmapRenderer()
        let got = expectation(description: "final frame delivered")
        got.assertForOverFulfill = false

        var frames = 0
        renderer.onFrame = { _ in
            frames += 1
            got.fulfill()
        }

        // Fire a burst of requests with changing params (like fast toggles/pan).
        for i in 0..<50 {
            renderer.request(document: doc, params: params(doc, zoom: 1.0 + CGFloat(i) * 0.01))
        }
        wait(for: [got], timeout: 10)
        XCTAssertGreaterThan(frames, 0, "at least one frame must be delivered after a burst")
    }

    func testQueueDoesNotLatchAfterBurst() throws {
        let doc = try tinyDoc()
        let renderer = BitmapRenderer()

        // Burst, let it settle.
        for i in 0..<20 {
            renderer.request(document: doc, params: params(doc, zoom: 1 + CGFloat(i) * 0.02))
        }
        let settle = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { settle.fulfill() }
        wait(for: [settle], timeout: 5)

        // A brand-new request after settling MUST still produce a frame — proves
        // the queue didn't latch `busy` and stop draining.
        let after = expectation(description: "frame after settle")
        renderer.onFrame = { _ in after.fulfill() }
        renderer.request(document: doc, params: params(doc, zoom: 2.0))
        wait(for: [after], timeout: 10)
    }
}
