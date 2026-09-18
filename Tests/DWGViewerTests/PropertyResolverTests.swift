import XCTest
@testable import DWGViewer
import CADCore

final class PropertyResolverTests: XCTestCase {

    // MARK: - Top-level (no block context)

    func testTopLevelExplicitACIPassesThrough() {
        let r = PropertyResolver.resolveTopLevel(layerId: 3, aci: 5, trueColor: 0xFF00_0000, linetypeId: -1)
        XCTAssertEqual(r.layerId, 3)
        XCTAssertEqual(r.aci, 5)
        XCTAssertEqual(r.trueColor, 0xFF00_0000)
        XCTAssertEqual(r.linetypeId, -1)   // BYLAYER stays dynamic in native form
    }

    func testTopLevelTrueColorWinsOverACI() {
        let r = PropertyResolver.resolveTopLevel(layerId: 0, aci: 3, trueColor: 0x00FF8040, linetypeId: 0)
        XCTAssertEqual(r.trueColor, 0x00FF8040)
        // aci passthrough value is irrelevant once trueColor is set; only
        // documenting it doesn't crash / mutate unexpectedly.
    }

    func testTopLevelByBlockFallsBackToForegroundLikeCtxDefault() {
        // aci == 0 (BYBLOCK) at the top level (no owning INSERT) resolves to
        // BlockContext.topLevel's byBlockAci (7 = foreground), matching
        // Regenerator.Ctx()'s default byBlockColor = .foreground.
        let r = PropertyResolver.resolveTopLevel(layerId: 0, aci: 0, trueColor: 0xFF00_0000, linetypeId: -2)
        XCTAssertEqual(r.aci, 7)
        XCTAssertEqual(r.linetypeId, 0)
    }

    func testLayerZeroAtTopLevelStaysLayerZero() {
        // No subLayer substitution outside a block context.
        let r = PropertyResolver.resolveTopLevel(layerId: 0, aci: 256, trueColor: 0xFF00_0000, linetypeId: -1)
        XCTAssertEqual(r.layerId, 0)
    }

    // MARK: - Block context inheritance

    func testLayerZeroInsideBlockInheritsInsertsLayer() {
        let ctx = PropertyResolver.BlockContext(subLayer: 42, byBlockAci: 1, byBlockTrueColor: 0xFF00_0000, byBlockLinetypeId: 0)
        let r = PropertyResolver.resolve(layerId: 0, aci: 256, trueColor: 0xFF00_0000, linetypeId: -1, in: ctx)
        XCTAssertEqual(r.layerId, 42)
    }

    func testNonZeroLayerInsideBlockIsUnaffectedByInsertsLayer() {
        let ctx = PropertyResolver.BlockContext(subLayer: 42, byBlockAci: 1, byBlockTrueColor: 0xFF00_0000, byBlockLinetypeId: 0)
        let r = PropertyResolver.resolve(layerId: 7, aci: 256, trueColor: 0xFF00_0000, linetypeId: -1, in: ctx)
        XCTAssertEqual(r.layerId, 7)
    }

    func testByBlockACIInheritsInsertsColor() {
        let ctx = PropertyResolver.BlockContext(subLayer: nil, byBlockAci: 3, byBlockTrueColor: 0xFF00_0000, byBlockLinetypeId: 0)
        let r = PropertyResolver.resolve(layerId: 5, aci: 0, trueColor: 0xFF00_0000, linetypeId: -1, in: ctx)
        XCTAssertEqual(r.aci, 3)
    }

    func testByBlockTrueColorInheritsInsertsTrueColor() {
        let ctx = PropertyResolver.BlockContext(subLayer: nil, byBlockAci: 7, byBlockTrueColor: 0x00112233, byBlockLinetypeId: 0)
        let r = PropertyResolver.resolve(layerId: 5, aci: 0, trueColor: 0xFF00_0000, linetypeId: -1, in: ctx)
        XCTAssertEqual(r.trueColor, 0x00112233)
    }

    func testByBlockLinetypeInheritsInsertsLinetype() {
        let ctx = PropertyResolver.BlockContext(subLayer: nil, byBlockAci: 7, byBlockTrueColor: 0xFF00_0000, byBlockLinetypeId: 9)
        let r = PropertyResolver.resolve(layerId: 5, aci: 256, trueColor: 0xFF00_0000, linetypeId: -2, in: ctx)
        XCTAssertEqual(r.linetypeId, 9)
    }

    func testExplicitACIInsideBlockIgnoresByBlockColor() {
        let ctx = PropertyResolver.BlockContext(subLayer: nil, byBlockAci: 3, byBlockTrueColor: 0xFF00_0000, byBlockLinetypeId: 0)
        let r = PropertyResolver.resolve(layerId: 5, aci: 4, trueColor: 0xFF00_0000, linetypeId: -1, in: ctx)
        XCTAssertEqual(r.aci, 4)   // explicit ACI 4, not the insert's byBlockAci
    }

    func testEntityTrueColorWinsEvenInsideBlockWithByBlockSet() {
        let ctx = PropertyResolver.BlockContext(subLayer: nil, byBlockAci: 3, byBlockTrueColor: 0x00AABBCC, byBlockLinetypeId: 0)
        let r = PropertyResolver.resolve(layerId: 5, aci: 0, trueColor: 0x00112233, linetypeId: -1, in: ctx)
        // Entity's OWN true color takes precedence over BYBLOCK inheritance
        // entirely (matches GeometryBuilder/Regenerator: trueColor check
        // happens before the aci==0 branch).
        XCTAssertEqual(r.trueColor, 0x00112233)
    }

    // MARK: - EXPLODE convenience (resolveForExplode)

    func testExplodeBYBLOCKBakesToInsertsResolvedColor() {
        // The INSERT itself resolved to ACI 3 on layer 10.
        let insertResolved = PropertyResolver.Resolved(layerId: 10, aci: 3, trueColor: 0xFF00_0000, linetypeId: 2)
        // A child entity declared BYBLOCK (aci=0) on layer "0" (inherits the
        // insert's layer) and BYBLOCK linetype.
        let r = PropertyResolver.resolveForExplode(entityLayerId: 0, entityAci: 0, entityTrueColor: 0xFF00_0000,
                                                    entityLinetypeId: -2, insertResolved: insertResolved)
        XCTAssertEqual(r.layerId, 10)
        XCTAssertEqual(r.aci, 3)
        XCTAssertEqual(r.linetypeId, 2)
    }

    func testExplodeBYLAYERStaysBYLAYEROnResolvedLayer() {
        let insertResolved = PropertyResolver.Resolved(layerId: 10, aci: 3, trueColor: 0xFF00_0000, linetypeId: 2)
        // A child entity declared BYLAYER (aci=256) on layer "0".
        let r = PropertyResolver.resolveForExplode(entityLayerId: 0, entityAci: 256, entityTrueColor: 0xFF00_0000,
                                                    entityLinetypeId: -1, insertResolved: insertResolved)
        XCTAssertEqual(r.layerId, 10)   // layer-0 substitution still applies
        XCTAssertEqual(r.aci, 256)      // BYLAYER preserved, NOT baked to insert's aci 3
        XCTAssertEqual(r.linetypeId, -1) // BYLAYER preserved for linetype too
    }

    func testExplodeExplicitColorOnNonZeroLayerPassesThroughUnchanged() {
        let insertResolved = PropertyResolver.Resolved(layerId: 10, aci: 3, trueColor: 0xFF00_0000, linetypeId: 2)
        let r = PropertyResolver.resolveForExplode(entityLayerId: 5, entityAci: 1, entityTrueColor: 0xFF00_0000,
                                                    entityLinetypeId: 4, insertResolved: insertResolved)
        XCTAssertEqual(r.layerId, 5)
        XCTAssertEqual(r.aci, 1)
        XCTAssertEqual(r.linetypeId, 4)
    }

    /// Adversarial-review regression: an entity with BOTH aci==0 (BYBLOCK)
    /// AND an explicit true color set must resolve `aci` to the INSERT's
    /// resolved color, not leak the raw 0 through — `Resolved.aci`'s own
    /// documented invariant is "never 0." Previously the trueColor branch
    /// unconditionally passed `aci` through unresolved, which is fine for
    /// any OTHER aci value (256 BYLAYER, 7 foreground, explicit 1-255) but
    /// silently violated the invariant specifically for aci==0.
    func testTrueColorPlusBYBLOCKResolvesACINotZero() {
        let ctx = PropertyResolver.BlockContext(subLayer: nil, byBlockAci: 5, byBlockTrueColor: 0xFF00_0000, byBlockLinetypeId: 0)
        let r = PropertyResolver.resolve(layerId: 0, aci: 0, trueColor: 0x00112233, linetypeId: -1, in: ctx)
        XCTAssertEqual(r.trueColor, 0x00112233, "true color must still win as the actual paint value")
        XCTAssertNotEqual(r.aci, 0, "aci must never leak through as raw BYBLOCK (0)")
        XCTAssertEqual(r.aci, 5, "aci must resolve to the block context's byBlockAci")
    }

    func testTrueColorWithNonBYBLOCKACIPassesThroughUnchanged() {
        // Sanity check the fix didn't disturb the ordinary (non-BYBLOCK) case.
        let ctx = PropertyResolver.BlockContext(subLayer: nil, byBlockAci: 5, byBlockTrueColor: 0xFF00_0000, byBlockLinetypeId: 0)
        let r = PropertyResolver.resolve(layerId: 0, aci: 3, trueColor: 0x00112233, linetypeId: -1, in: ctx)
        XCTAssertEqual(r.aci, 3)
        XCTAssertEqual(r.trueColor, 0x00112233)
    }

    func testExplodeEntityTrueColorWinsOverBYBLOCK() {
        let insertResolved = PropertyResolver.Resolved(layerId: 10, aci: 3, trueColor: 0xFF00_0000, linetypeId: 2)
        let r = PropertyResolver.resolveForExplode(entityLayerId: 0, entityAci: 0, entityTrueColor: 0x00445566,
                                                    entityLinetypeId: -1, insertResolved: insertResolved)
        XCTAssertEqual(r.trueColor, 0x00445566)
    }
}
