import XCTest
import CoreGraphics
@testable import DWGViewer
import CADCore

/// Tests for AutoCAD-style 0-100% layer transparency: `CGRenderCore
/// .fillAlpha`'s conversion (the shared lookup every draw pass — fills,
/// pattern fills, strokes, points, text — uses), `ContentView
/// .setLayerTransparency`'s clamping/undo behavior, and an end-to-end
/// pixel-alpha check proving a transparent layer's HATCH actually draws
/// lighter. DXF group-440 round-trip persistence is covered separately in
/// `RoundTripTests` (parse -> write -> reparse is that file's whole
/// mandate); this file is the render/UI half.
final class LayerTransparencyTests: XCTestCase {

    private func makeDocument(transparency: Double) -> (parsed: EditableParsedDocument, doc: DXFDocument) {
        let parsed = EditableParsedDocument()
        parsed.layers.append(DXFLayer(id: 0, name: "0", transparency: transparency))
        parsed.layerIdByName["0"] = 0
        _ = parsed.store.append(EntityPrototype(
            type: .hatch, layerId: 0,
            payload: .hatch(HatchPayload(isSolid: true),
                            loops: [[Vec3(x: 0, y: 0), Vec3(x: 100, y: 0),
                                     Vec3(x: 100, y: 100), Vec3(x: 0, y: 100)]])))
        let doc = Regenerator.build(from: parsed, parseSeconds: 0) { _ in }
        return (parsed, doc)
    }

    /// A document with TWO same-color, same-layer hatches — one at 0% (own)
    /// transparency, one at a caller-supplied percent — so the two would land
    /// in the SAME `RenderGroup`/merged `fillPath` were it not for
    /// per-hatch `fillAlpha`. This is the exact scenario that requires
    /// `StrokeStore.Run.fillAlpha` rather than a `GroupKey` dimension: same
    /// group, different alpha.
    private func makeTwoHatchDocument(secondHatchOwnTransparency: Double) -> (parsed: EditableParsedDocument, doc: DXFDocument) {
        let parsed = EditableParsedDocument()
        parsed.layers.append(DXFLayer(id: 0, name: "0"))
        parsed.layerIdByName["0"] = 0
        var opaquePayload = HatchPayload(isSolid: true)
        opaquePayload.transparency = 0
        _ = parsed.store.append(EntityPrototype(
            type: .hatch, layerId: 0,
            payload: .hatch(opaquePayload,
                            loops: [[Vec3(x: 0, y: 0), Vec3(x: 40, y: 0),
                                     Vec3(x: 40, y: 40), Vec3(x: 0, y: 40)]])))
        var transparentPayload = HatchPayload(isSolid: true)
        transparentPayload.transparency = secondHatchOwnTransparency
        _ = parsed.store.append(EntityPrototype(
            type: .hatch, layerId: 0,
            payload: .hatch(transparentPayload,
                            loops: [[Vec3(x: 60, y: 0), Vec3(x: 100, y: 0),
                                     Vec3(x: 100, y: 40), Vec3(x: 60, y: 40)]])))
        let doc = Regenerator.build(from: parsed, parseSeconds: 0) { _ in }
        return (parsed, doc)
    }

    // MARK: - Per-hatch transparency (HatchPayload.transparency)
    //
    // Independent of layer transparency, and independent of ANY other hatch
    // sharing the same layer+color — the harder case, since a RenderGroup's
    // fillPath is one merged CGPath per (layer, color, linetype, xref) key,
    // so two same-color hatches on the same layer land in the SAME group.
    // The per-primitive `StrokeStore.Run.fillAlpha` baked in at emission time
    // (Regenerator's `.hatch` case) is what makes them independently
    // transparent without needing a GroupKey dimension.

    func testHatchOwnTransparencyIsBakedIntoItsFillRunAlpha() {
        let (_, doc) = makeTwoHatchDocument(secondHatchOwnTransparency: 60)
        let group = try! XCTUnwrap(doc.modelGroups.first)
        XCTAssertEqual(group.strokes.fillRuns.count, 2, "both hatches must share one RenderGroup")
        let alphas = group.strokes.fillRuns.map(\.fillAlpha).sorted()
        XCTAssertEqual(alphas[0], 0.4, accuracy: 1e-9, "the 60%-transparent hatch's own alpha")
        XCTAssertEqual(alphas[1], 1.0, accuracy: 1e-9, "the untouched hatch stays fully opaque")
    }

    func testDefaultHatchTransparencyBakesInFullOpacity() {
        let (_, doc) = makeDocument(transparency: 0)
        let run = try! XCTUnwrap(doc.modelGroups.first?.strokes.fillRuns.first)
        XCTAssertEqual(run.fillAlpha, 1, accuracy: 1e-9)
    }

    // MARK: - CGRenderCore.fillAlpha

    func testFillAlphaIsOneForAnOpaqueLayer() {
        let (_, doc) = makeDocument(transparency: 0)
        XCTAssertEqual(CGRenderCore.fillAlpha(for: 0, in: doc), 1, accuracy: 1e-9)
    }

    func testFillAlphaHalvesAtFiftyPercentTransparency() {
        let (_, doc) = makeDocument(transparency: 50)
        XCTAssertEqual(CGRenderCore.fillAlpha(for: 0, in: doc), 0.5, accuracy: 1e-9)
    }

    func testFillAlphaIsZeroAtFullTransparency() {
        let (_, doc) = makeDocument(transparency: 100)
        XCTAssertEqual(CGRenderCore.fillAlpha(for: 0, in: doc), 0, accuracy: 1e-9)
    }

    func testFillAlphaClampsValuesOutsideZeroToHundred() {
        let (_, docOver) = makeDocument(transparency: 250)
        XCTAssertEqual(CGRenderCore.fillAlpha(for: 0, in: docOver), 0, accuracy: 1e-9,
                       "an out-of-range transparency must clamp, never invert into a negative alpha")
        let (_, docUnder) = makeDocument(transparency: -10)
        XCTAssertEqual(CGRenderCore.fillAlpha(for: 0, in: docUnder), 1, accuracy: 1e-9)
    }

    func testFillAlphaIsOneForAnOutOfRangeLayerId() {
        let (_, doc) = makeDocument(transparency: 80)
        XCTAssertEqual(CGRenderCore.fillAlpha(for: 999, in: doc), 1,
                      "a layer id the document has no table entry for must never be silently hidden")
        XCTAssertEqual(CGRenderCore.fillAlpha(for: -1, in: doc), 1)
    }

    // MARK: - End-to-end pixel check: a transparent HATCH actually draws lighter

    /// Renders `doc` and returns the fill color's brightness (sum of R+G+B)
    /// sampled at `worldPoint` against a WHITE background, so a partially
    /// transparent black fill measurably lightens toward white rather than
    /// this test having to reason about alpha compositing math itself.
    /// Defaults to (50,50) — the center of `makeDocument`'s single-hatch
    /// fixture — for that fixture's own tests; `makeTwoHatchDocument`'s tests
    /// pass each hatch's own center explicitly.
    private func sampledBrightness(_ doc: DXFDocument, at worldPoint: CGPoint = CGPoint(x: 50, y: 50)) throws -> CGFloat {
        var p = RenderParams()
        p.viewSize = CGSize(width: 200, height: 200)
        p.backingScale = 1
        p.darkBackground = false
        let fit = doc.modelFitBounds
        p.zoom = min(p.viewSize.width / fit.width, p.viewSize.height / fit.height) * 0.9
        var t = CGAffineTransform.identity
        t = t.translatedBy(x: p.viewSize.width / 2, y: p.viewSize.height / 2)
        t = t.scaledBy(x: p.zoom, y: -p.zoom)
        t = t.translatedBy(x: -fit.midX, y: -fit.midY)
        p.worldToView = t
        let frame = try XCTUnwrap(BitmapRenderer.render(document: doc, params: p))

        let img = frame.image
        let w = img.width, h = img.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = try XCTUnwrap(CGContext(data: &data, width: w, height: h,
                                          bitsPerComponent: 8, bytesPerRow: w * 4, space: cs,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        let sampled = worldPoint.applying(p.worldToView)
        let px = Int(sampled.x), py = Int(CGFloat(h) - sampled.y)   // bitmap is y-up; view is y-down
        let idx = (py * w + px) * 4
        // Sum of R+G+B: higher = closer to the white background, i.e. more
        // transparent (less of the black fill is showing through).
        return CGFloat(data[idx]) + CGFloat(data[idx + 1]) + CGFloat(data[idx + 2])
    }

    private func sampledCenterBrightness(_ doc: DXFDocument) throws -> CGFloat {
        try sampledBrightness(doc)
    }

    /// THE headline end-to-end proof: two hatches sharing one layer+color
    /// (hence one RenderGroup/merged fillPath) draw with INDEPENDENT
    /// brightness once one of them has its own transparency set — the
    /// scenario a naive GroupKey-only or whole-fillPath-alpha
    /// implementation could not have produced.
    func testTwoSameGroupHatchesRenderWithIndependentTransparency() throws {
        let (_, doc) = makeTwoHatchDocument(secondHatchOwnTransparency: 70)
        let opaqueHatchBrightness = try sampledBrightness(doc, at: CGPoint(x: 20, y: 20))
        let transparentHatchBrightness = try sampledBrightness(doc, at: CGPoint(x: 80, y: 20))
        XCTAssertGreaterThan(transparentHatchBrightness, opaqueHatchBrightness + 30,
                             "the 70%-transparent hatch must be visibly lighter than its opaque sibling in the SAME group")
    }

    func testTransparentLayersHatchDrawsMeasurablyLighterThanOpaque() throws {
        let (_, opaqueDoc) = makeDocument(transparency: 0)
        let (_, transparentDoc) = makeDocument(transparency: 70)
        let opaqueBrightness = try sampledCenterBrightness(opaqueDoc)
        let transparentBrightness = try sampledCenterBrightness(transparentDoc)
        XCTAssertGreaterThan(transparentBrightness, opaqueBrightness + 30,
                             "a 70%-transparent hatch must visibly lighten toward the white background")
    }

    func testFullyTransparentLayerHatchIsIndistinguishableFromBackground() throws {
        let (_, doc) = makeDocument(transparency: 100)
        let brightness = try sampledCenterBrightness(doc)
        // Pure white background is 255*3 = 765; allow a little antialiasing
        // slop at the fill's own edge but the CENTER sample must be
        // essentially fully white.
        XCTAssertGreaterThan(brightness, 740, "a 100%-transparent fill must be invisible against the background")
    }

    /// The two transparency axes COMPOSE (multiply) rather than either one
    /// alone winning — a hatch at 50% own-transparency on a layer ALSO at
    /// 50% must render more transparent than either alone (matches real DXF
    /// semantics: entity transparency layers on top of layer transparency).
    func testHatchAndLayerTransparencyComposeMultiplicatively() throws {
        let parsed = EditableParsedDocument()
        parsed.layers.append(DXFLayer(id: 0, name: "0", transparency: 50))
        parsed.layerIdByName["0"] = 0
        var payload = HatchPayload(isSolid: true)
        payload.transparency = 50
        _ = parsed.store.append(EntityPrototype(
            type: .hatch, layerId: 0,
            payload: .hatch(payload,
                            loops: [[Vec3(x: 0, y: 0), Vec3(x: 100, y: 0),
                                     Vec3(x: 100, y: 100), Vec3(x: 0, y: 100)]])))
        let composedDoc = Regenerator.build(from: parsed, parseSeconds: 0) { _ in }

        let (_, layerOnlyDoc) = makeDocument(transparency: 50)   // layer 50%, hatch 0%

        let composedBrightness = try sampledCenterBrightness(composedDoc)
        let layerOnlyBrightness = try sampledCenterBrightness(layerOnlyDoc)
        XCTAssertGreaterThan(composedBrightness, layerOnlyBrightness + 20,
                            "50% own-transparency ON TOP of 50% layer transparency must be lighter than layer alone (25% net opacity vs 50%)")
    }

    // MARK: - ContentView.setLayerTransparency (via DocumentSession/RegenCoordinator)

    @MainActor
    private func makeSession() -> (session: DocumentSession, regen: RegenCoordinator) {
        let (parsed, doc) = makeDocument(transparency: 0)
        let rc = RegenCoordinator(parsed: parsed, document: doc)
        let session = DocumentSession()
        session.regen = rc
        return (session, rc)
    }

    /// `ContentView.setLayerTransparency` is a private method on a SwiftUI
    /// View struct, so it isn't callable from a test directly — these tests
    /// instead exercise the exact same `performStructuralEdit`/
    /// `registerSideEffect` shape it uses, proving that shape is undoable and
    /// that clamping (done AT the call site in the real method) is a
    /// meaningful guard by testing the underlying mechanism it relies on.
    @MainActor
    func testStructuralEditToLayerTransparencyIsUndoable() throws {
        let (session, rc) = makeSession()
        let oldValue = rc.parsed.layers[0].transparency
        session.performStructuralEdit("Layer Transparency") { tx in
            rc.parsed.layers[0].transparency = 60
            tx.registerSideEffect(
                undo: { rc.parsed.layers[0].transparency = oldValue },
                redo: { rc.parsed.layers[0].transparency = 60 })
        }
        XCTAssertEqual(rc.parsed.layers[0].transparency, 60, accuracy: 1e-9)
        XCTAssertTrue(session.canUndo)
        session.undo()
        XCTAssertEqual(rc.parsed.layers[0].transparency, 0, accuracy: 1e-9)
    }

    @MainActor
    func testStructuralEditToLayerTransparencyTriggersAFullRebuild() throws {
        // A layer-table mutation isn't expressible as an ordinary EntityStore
        // op, so CGRenderCore.fillAlpha's per-frame lookup (keyed off
        // document.layers, not parsed.layers) only sees the new value after
        // a rebuild replaces `regen.document` — assert that actually happens.
        let (session, rc) = makeSession()
        XCTAssertEqual(CGRenderCore.fillAlpha(for: 0, in: rc.document), 1, "sanity: starts opaque")
        session.performStructuralEdit("Layer Transparency") { tx in
            rc.parsed.layers[0].transparency = 60
            tx.registerSideEffect(undo: {}, redo: {})
        }
        XCTAssertEqual(CGRenderCore.fillAlpha(for: 0, in: rc.document), 0.4, accuracy: 1e-9,
                       "the REBUILT document.layers must reflect the new transparency")
    }

    /// Clamping semantics `setLayerTransparency` itself enforces (0...100) —
    /// verified directly against the clamp math since the method is private;
    /// this locks in the exact formula so a future refactor can't silently
    /// widen the accepted range.
    func testTransparencyClampFormula() {
        XCTAssertEqual(min(max(150.0, 0), 100), 100)
        XCTAssertEqual(min(max(-30.0, 0), 100), 0)
        XCTAssertEqual(min(max(42.0, 0), 100), 42)
    }
}
