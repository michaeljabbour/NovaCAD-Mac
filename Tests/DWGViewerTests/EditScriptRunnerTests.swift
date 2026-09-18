import XCTest
@testable import DWGViewer
import CADCore

/// Unit coverage for `EditScriptRunner.payloadsApproximatelyEqual` — the
/// geometry-comparison primitive behind the `assert-geometry-equal` script
/// verb (Phase 4.1/4.2's scripted round-trip verification, e.g. "ROTATE 90
/// twice equals ROTATE 180 once", "MIRROR twice returns to the original").
/// The `--edit-script` grammar itself (parsing, verb dispatch) is exercised
/// via manual CLI invocation per the phase's verification report, matching
/// the precedent set by `EditScriptRunner`'s own doc comment (this class of
/// test needs a live `RegenCoordinator` + file I/O that's a poor fit for
/// fast unit tests) — this file covers just the pure comparison logic.
final class EditScriptRunnerTests: XCTestCase {

    func testIdenticalLinesAreEqual() {
        let a = EntityPayloadCopy.line(LinePayload(a: Vec3(x: 0, y: 0), b: Vec3(x: 10, y: 10)))
        let b = EntityPayloadCopy.line(LinePayload(a: Vec3(x: 0, y: 0), b: Vec3(x: 10, y: 10)))
        XCTAssertTrue(EditScriptRunner.payloadsApproximatelyEqual(a, b, tol: 1e-6))
    }

    func testLinesDifferingBeyondToleranceAreNotEqual() {
        let a = EntityPayloadCopy.line(LinePayload(a: Vec3(x: 0, y: 0), b: Vec3(x: 10, y: 10)))
        let b = EntityPayloadCopy.line(LinePayload(a: Vec3(x: 0, y: 0), b: Vec3(x: 10.1, y: 10)))
        XCTAssertFalse(EditScriptRunner.payloadsApproximatelyEqual(a, b, tol: 1e-6))
    }

    func testLinesDifferingWithinToleranceAreEqual() {
        let a = EntityPayloadCopy.line(LinePayload(a: Vec3(x: 0, y: 0), b: Vec3(x: 10, y: 10)))
        let b = EntityPayloadCopy.line(LinePayload(a: Vec3(x: 0, y: 0), b: Vec3(x: 10.0000001, y: 10)))
        XCTAssertTrue(EditScriptRunner.payloadsApproximatelyEqual(a, b, tol: 1e-6))
    }

    func testDifferentEntityTypesAreNeverEqual() {
        let line = EntityPayloadCopy.line(LinePayload(a: Vec3(x: 0, y: 0), b: Vec3(x: 10, y: 10)))
        let circle = EntityPayloadCopy.circle(CirclePayload(center: Vec3(x: 0, y: 0), radius: 5))
        XCTAssertFalse(EditScriptRunner.payloadsApproximatelyEqual(line, circle, tol: 1e-6))
    }

    func testCirclesCompareCenterAndRadius() {
        let a = EntityPayloadCopy.circle(CirclePayload(center: Vec3(x: 5, y: 5), radius: 3))
        let b = EntityPayloadCopy.circle(CirclePayload(center: Vec3(x: 5, y: 5), radius: 3))
        let c = EntityPayloadCopy.circle(CirclePayload(center: Vec3(x: 5, y: 5), radius: 4))
        XCTAssertTrue(EditScriptRunner.payloadsApproximatelyEqual(a, b, tol: 1e-6))
        XCTAssertFalse(EditScriptRunner.payloadsApproximatelyEqual(a, c, tol: 1e-6))
    }

    func testPolylinesRequireMatchingVertexAndBulgeCounts() {
        let a = EntityPayloadCopy.polyline(PolylinePayload(), vertices: [Vec3(x: 0, y: 0), Vec3(x: 1, y: 1)], bulges: [0, 0])
        let b = EntityPayloadCopy.polyline(PolylinePayload(), vertices: [Vec3(x: 0, y: 0), Vec3(x: 1, y: 1)], bulges: [0, 0])
        let c = EntityPayloadCopy.polyline(PolylinePayload(), vertices: [Vec3(x: 0, y: 0)], bulges: [0])
        XCTAssertTrue(EditScriptRunner.payloadsApproximatelyEqual(a, b, tol: 1e-6))
        XCTAssertFalse(EditScriptRunner.payloadsApproximatelyEqual(a, c, tol: 1e-6))
    }

    func testUnknownPayloadsAreAlwaysEqual() {
        XCTAssertTrue(EditScriptRunner.payloadsApproximatelyEqual(.unknown, .unknown, tol: 1e-6))
    }

    func testRotate90TwiceMatchesRotate180OnceViaComparison() {
        // Cross-check that the comparison helper itself agrees with
        // EntityTransform's own rotate-composition guarantee (already
        // proven by EntityTransformTests) — belt-and-suspenders on the NEW
        // comparison code, not a re-test of EntityTransform.
        var a = EntityPayloadCopy.line(LinePayload(a: Vec3(x: 5, y: 0), b: Vec3(x: 10, y: 0)))
        var b = a
        let r90 = Transform2.rotation(about: Vec2(0, 0), angleRad: .pi / 2)
        let r180 = Transform2.rotation(about: Vec2(0, 0), angleRad: .pi)
        EntityTransform.apply(r90, to: &a, mirrtext: false)
        EntityTransform.apply(r90, to: &a, mirrtext: false)
        EntityTransform.apply(r180, to: &b, mirrtext: false)
        XCTAssertTrue(EditScriptRunner.payloadsApproximatelyEqual(a, b, tol: 1e-9))
    }
}
