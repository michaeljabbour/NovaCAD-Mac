import XCTest
@testable import DWGViewer
import CADCore

final class Transform2Tests: XCTestCase {

    private let eps = 1e-9

    private func assertClose(_ a: Vec2, _ b: Vec2, _ msg: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: 1e-9, msg, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: 1e-9, msg, file: file, line: line)
    }

    // MARK: - Translation

    func testTranslation() {
        let t = Transform2.translation(dx: 5, dy: -3)
        assertClose(t.apply(Vec2(1, 1)), Vec2(6, -2))
        XCTAssertFalse(t.isMirroring)
        XCTAssertEqual(t.uniformScale, 1, accuracy: eps)
    }

    // MARK: - Rotation

    func testRotationAboutOrigin90Degrees() {
        let t = Transform2.rotation(about: Vec2(0, 0), angleRad: .pi / 2)
        assertClose(t.apply(Vec2(1, 0)), Vec2(0, 1))
        assertClose(t.apply(Vec2(0, 1)), Vec2(-1, 0))
    }

    func testRotationAboutArbitraryPivot() {
        let pivot = Vec2(10, 10)
        let t = Transform2.rotation(about: pivot, angleRad: .pi)
        // 180-degree rotation about (10,10): (11,10) -> (9,10)
        assertClose(t.apply(Vec2(11, 10)), Vec2(9, 10))
        // The pivot itself must be a fixed point.
        assertClose(t.apply(pivot), pivot)
    }

    func testRotationTwice90EqualsRotation180() {
        let pivot = Vec2(3, -2)
        let p = Vec2(7, 5)
        let r90 = Transform2.rotation(about: pivot, angleRad: .pi / 2)
        let r180 = Transform2.rotation(about: pivot, angleRad: .pi)
        let twice = r90.apply(r90.apply(p))
        let once = r180.apply(p)
        assertClose(twice, once, "two 90-degree rotations must equal one 180-degree rotation")
    }

    func testRotationPreservesOrientationAndScale() {
        let t = Transform2.rotation(about: Vec2(0, 0), angleRad: 0.7)
        XCTAssertFalse(t.isMirroring)
        XCTAssertEqual(t.uniformScale, 1, accuracy: eps)
        XCTAssertEqual(t.rotationAngle, 0.7, accuracy: eps)
    }

    // MARK: - Scale

    func testScalingAboutPivot() {
        let pivot = Vec2(2, 2)
        let t = Transform2.scaling(about: pivot, factor: 2)
        // (4,2) is distance (2,0) from pivot -> becomes (4,0) from pivot -> (6,2)
        assertClose(t.apply(Vec2(4, 2)), Vec2(6, 2))
        assertClose(t.apply(pivot), pivot, "pivot is a fixed point of scaling")
        XCTAssertEqual(t.uniformScale, 2, accuracy: eps)
        XCTAssertFalse(t.isMirroring)
    }

    func testScalingFactorLessThanOne() {
        let t = Transform2.scaling(about: Vec2(0, 0), factor: 0.5)
        assertClose(t.apply(Vec2(10, 20)), Vec2(5, 10))
    }

    // MARK: - Mirror

    func testMirrorAcrossXAxis() {
        let t = Transform2.mirror(across: Vec2(0, 0), Vec2(1, 0))
        assertClose(t.apply(Vec2(3, 5)), Vec2(3, -5))
        XCTAssertTrue(t.isMirroring)
        XCTAssertEqual(t.uniformScale, 1, accuracy: eps)
    }

    func testMirrorAcrossYAxis() {
        let t = Transform2.mirror(across: Vec2(0, 0), Vec2(0, 1))
        assertClose(t.apply(Vec2(3, 5)), Vec2(-3, 5))
    }

    func testMirrorAcrossArbitraryLine() {
        // Mirror across the line y = x: (a,b) -> (b,a).
        let t = Transform2.mirror(across: Vec2(0, 0), Vec2(1, 1))
        assertClose(t.apply(Vec2(3, 7)), Vec2(7, 3))
    }

    func testMirrorAcrossOffsetLine() {
        // Mirror across the horizontal line y = 5.
        let t = Transform2.mirror(across: Vec2(0, 5), Vec2(1, 5))
        assertClose(t.apply(Vec2(2, 8)), Vec2(2, 2))
    }

    func testMirrorTwiceIsIdentity() {
        let a = Vec2(1, 2), b = Vec2(4, -1)
        let t = Transform2.mirror(across: a, b)
        let p = Vec2(9, -3)
        let roundTrip = t.apply(t.apply(p))
        assertClose(roundTrip, p, "mirroring twice across the same line returns the original point")
    }

    func testMirrorDegenerateLineIsIdentity() {
        let t = Transform2.mirror(across: Vec2(1, 1), Vec2(1, 1))
        XCTAssertEqual(t, .identity)
    }

    func testMirrorPointsOnLineAreFixed() {
        let a = Vec2(0, 0), b = Vec2(2, 3)
        let t = Transform2.mirror(across: a, b)
        assertClose(t.apply(a), a)
        assertClose(t.apply(b), b)
    }

    // MARK: - isMirroring / determinant

    func testComposedRotationAndMirrorIsMirroring() {
        let r = Transform2.rotation(about: Vec2(0, 0), angleRad: 0.3)
        let m = Transform2.mirror(across: Vec2(0, 0), Vec2(1, 0))
        XCTAssertTrue(r.then(m).isMirroring)
        XCTAssertFalse(r.then(r).isMirroring)
    }

    // MARK: - Composition (`then`)

    func testThenComposesInOrder() {
        let translate = Transform2.translation(dx: 10, dy: 0)
        let rotate = Transform2.rotation(about: Vec2(0, 0), angleRad: .pi / 2)
        let p = Vec2(1, 0)
        // First translate (1,0)->(11,0), then rotate 90 about origin -> (0,11).
        let composed = translate.then(rotate)
        assertClose(composed.apply(p), Vec2(0, 11))
    }

    func testThenIdentityIsNoOp() {
        let t = Transform2.rotation(about: Vec2(1, 2), angleRad: 0.5)
        let composed = t.then(.identity)
        let p = Vec2(5, 5)
        assertClose(composed.apply(p), t.apply(p))
    }

    // MARK: - applyLinear (no translation)

    func testApplyLinearIgnoresTranslation() {
        let t = Transform2.translation(dx: 100, dy: 50)
        assertClose(t.applyLinear(Vec2(3, 4)), Vec2(3, 4))
    }

    func testApplyLinearRotatesVector() {
        let t = Transform2.rotation(about: Vec2(99, -99), angleRad: .pi / 2)
        assertClose(t.applyLinear(Vec2(1, 0)), Vec2(0, 1))
    }
}
