import XCTest
@testable import DWGViewer
import CADCore

final class EntityTransformTests: XCTestCase {

    private let eps = 1e-6

    private func assertClose(_ a: Double, _ b: Double, _ msg: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a, b, accuracy: eps, msg, file: file, line: line)
    }
    private func assertClose(_ a: Vec3, _ b: Vec3, _ msg: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.x, b.x, accuracy: eps, msg, file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: eps, msg, file: file, line: line)
    }

    // MARK: - Line (rotate/scale/mirror sanity — translate already covered by translate(dx:dy:))

    func testLineRotate90AboutOrigin() {
        var c = EntityPayloadCopy.line(LinePayload(a: Vec3(x: 1, y: 0), b: Vec3(x: 2, y: 0)))
        let t = Transform2.rotation(about: Vec2(0, 0), angleRad: .pi / 2)
        EntityTransform.apply(t, to: &c, mirrtext: false)
        guard case .line(let p) = c else { return XCTFail() }
        assertClose(p.a, Vec3(x: 0, y: 1))
        assertClose(p.b, Vec3(x: 0, y: 2))
    }

    func testLineMirrorAcrossXAxis() {
        var c = EntityPayloadCopy.line(LinePayload(a: Vec3(x: 1, y: 2), b: Vec3(x: 3, y: -4)))
        let t = Transform2.mirror(across: Vec2(0, 0), Vec2(1, 0))
        EntityTransform.apply(t, to: &c, mirrtext: false)
        guard case .line(let p) = c else { return XCTFail() }
        assertClose(p.a, Vec3(x: 1, y: -2))
        assertClose(p.b, Vec3(x: 3, y: 4))
    }

    // MARK: - Circle: center as point, radius * uniformScale

    func testCircleScale() {
        var c = EntityPayloadCopy.circle(CirclePayload(center: Vec3(x: 5, y: 5), radius: 2))
        let t = Transform2.scaling(about: Vec2(0, 0), factor: 3)
        EntityTransform.apply(t, to: &c, mirrtext: false)
        guard case .circle(let p) = c else { return XCTFail() }
        assertClose(p.center, Vec3(x: 15, y: 15))
        assertClose(p.radius, 6)
    }

    func testCircleMirrorPreservesRadius() {
        var c = EntityPayloadCopy.circle(CirclePayload(center: Vec3(x: 5, y: 5), radius: 2))
        let t = Transform2.mirror(across: Vec2(0, 0), Vec2(1, 0))
        EntityTransform.apply(t, to: &c, mirrtext: false)
        guard case .circle(let p) = c else { return XCTFail() }
        assertClose(p.center, Vec3(x: 5, y: -5))
        assertClose(p.radius, 2, "mirroring must not change radius")
    }

    // MARK: - Arc: rotation/scale accumulate; mirror swaps+reflects to stay CCW

    /// Ground truth for arc-mirror: mirror the arc's actual ENDPOINTS with
    /// Transform2 directly (bypassing EntityTransform), then verify
    /// EntityTransform's transformed arc reproduces the same two endpoint
    /// positions (start/end, in order) and remains a CCW sweep.
    func testArcMirrorMatchesDirectEndpointReflection() {
        let center = Vec3(x: 0, y: 0)
        let radius = 5.0
        let startDeg = 30.0, endDeg = 120.0
        var c = EntityPayloadCopy.arc(ArcPayload(center: center, radius: radius,
                                                  startAngleDeg: startDeg, endAngleDeg: endDeg))
        let t = Transform2.mirror(across: Vec2(0, 0), Vec2(1, 0))   // mirror across X axis
        EntityTransform.apply(t, to: &c, mirrtext: false)
        guard case .arc(let p) = c else { return XCTFail() }

        // Direct ground truth: reflect the original start/end points across the X axis.
        func pointOnCircle(_ deg: Double) -> Vec2 {
            let rad = deg * .pi / 180
            return Vec2(center.x + radius * cos(rad), center.y + radius * sin(rad))
        }
        let mirroredStartPoint = t.apply(pointOnCircle(startDeg))
        let mirroredEndPoint = t.apply(pointOnCircle(endDeg))

        func pointFromTransformed(_ deg: Double) -> Vec2 {
            let rad = deg * .pi / 180
            return Vec2(p.center.x + p.radius * cos(rad), p.center.y + p.radius * sin(rad))
        }
        // Mirroring reverses traversal direction (CCW becomes CW), so to
        // stay CCW (this kernel's universal convention) start/end must
        // SWAP: the mirrored arc's own start angle lands on the mirrored
        // END point, and its own end angle lands on the mirrored START
        // point — per the plan's spec ("swaps reflected start/end").
        let gotStart = pointFromTransformed(p.startAngleDeg)
        let gotEnd = pointFromTransformed(p.endAngleDeg)
        XCTAssertEqual(gotStart.x, mirroredEndPoint.x, accuracy: eps)
        XCTAssertEqual(gotStart.y, mirroredEndPoint.y, accuracy: eps)
        XCTAssertEqual(gotEnd.x, mirroredStartPoint.x, accuracy: eps)
        XCTAssertEqual(gotEnd.y, mirroredStartPoint.y, accuracy: eps)

        // And the sweep from startAngleDeg to endAngleDeg (CCW, per this
        // kernel's convention) must still contain the mirrored midpoint.
        let midDeg = (startDeg + endDeg) / 2
        let mirroredMid = t.apply(pointOnCircle(midDeg))
        // Find the CCW angle of mirroredMid relative to the new center.
        let midAngle = atan2(mirroredMid.y - p.center.y, mirroredMid.x - p.center.x) * 180 / .pi
        XCTAssertTrue(HitTester.angleWithinSweep(midAngle, from: p.startAngleDeg, to: p.endAngleDeg),
                     "mirrored arc's sweep must still contain the mirrored midpoint (stays CCW)")
    }

    func testArcMirrorTwiceReturnsOriginal() {
        var c = EntityPayloadCopy.arc(ArcPayload(center: Vec3(x: 3, y: 4), radius: 7,
                                                  startAngleDeg: 10, endAngleDeg: 200))
        let t = Transform2.mirror(across: Vec2(1, 1), Vec2(4, -2))
        EntityTransform.apply(t, to: &c, mirrtext: false)
        EntityTransform.apply(t, to: &c, mirrtext: false)
        guard case .arc(let p) = c else { return XCTFail() }
        assertClose(p.center, Vec3(x: 3, y: 4))
        assertClose(p.radius, 7)
        // Angles should return to the original pair (mod 360, but our formula
        // is exact so no wraparound needed here).
        assertClose(p.startAngleDeg, 10)
        assertClose(p.endAngleDeg, 200)
    }

    func testArcRotateAccumulatesAngle() {
        var c = EntityPayloadCopy.arc(ArcPayload(center: Vec3(x: 0, y: 0), radius: 1,
                                                  startAngleDeg: 0, endAngleDeg: 90))
        let t = Transform2.rotation(about: Vec2(0, 0), angleRad: .pi / 2)
        EntityTransform.apply(t, to: &c, mirrtext: false)
        guard case .arc(let p) = c else { return XCTFail() }
        assertClose(p.startAngleDeg, 90)
        assertClose(p.endAngleDeg, 180)
    }

    func testArcScaleAppliesToRadiusOnly() {
        var c = EntityPayloadCopy.arc(ArcPayload(center: Vec3(x: 0, y: 0), radius: 2,
                                                  startAngleDeg: 0, endAngleDeg: 45))
        let t = Transform2.scaling(about: Vec2(0, 0), factor: 4)
        EntityTransform.apply(t, to: &c, mirrtext: false)
        guard case .arc(let p) = c else { return XCTFail() }
        assertClose(p.radius, 8)
        assertClose(p.startAngleDeg, 0)
        assertClose(p.endAngleDeg, 45)
    }

    // MARK: - Polyline: vertices as points, mirror negates every bulge

    func testPolylineMirrorNegatesBulges() {
        var c = EntityPayloadCopy.polyline(
            PolylinePayload(vertsStart: 0, vertsCount: 3, bulgesStart: 0, closed: true),
            vertices: [Vec3(x: 0, y: 0), Vec3(x: 10, y: 0), Vec3(x: 10, y: 10)],
            bulges: [0.5, -0.3, 0])
        let t = Transform2.mirror(across: Vec2(0, 0), Vec2(1, 0))
        EntityTransform.apply(t, to: &c, mirrtext: false)
        guard case .polyline(_, let verts, let bulges) = c else { return XCTFail() }
        assertClose(verts[0], Vec3(x: 0, y: 0))
        assertClose(verts[1], Vec3(x: 10, y: 0))
        assertClose(verts[2], Vec3(x: 10, y: -10))
        assertClose(bulges[0], -0.5)
        assertClose(bulges[1], 0.3)
        assertClose(bulges[2], 0)
    }

    func testPolylineMirrorPreservesArcGeometryViaBulgeRoundTrip() {
        // Ground truth: build the arc from vertex a->b with bulge, mirror
        // its actual geometry (via bulgeToArc), and confirm the negated
        // bulge on the mirrored vertices reconstructs the SAME mirrored arc.
        let a = Vec2(0, 0), b = Vec2(10, 0)
        let bulge = 0.6
        let originalArc = bulgeToArc(from: a, to: b, bulge: bulge)

        var c = EntityPayloadCopy.polyline(
            PolylinePayload(vertsStart: 0, vertsCount: 2, bulgesStart: 0, closed: false),
            vertices: [Vec3(x: a.x, y: a.y), Vec3(x: b.x, y: b.y)],
            bulges: [bulge, 0])
        let t = Transform2.mirror(across: Vec2(0, 0), Vec2(1, 0))
        EntityTransform.apply(t, to: &c, mirrtext: false)
        guard case .polyline(_, let verts, let bulges) = c else { return XCTFail() }

        let mirroredA = Vec2(verts[0].x, verts[0].y)
        let mirroredB = Vec2(verts[1].x, verts[1].y)
        let reconstructedArc = bulgeToArc(from: mirroredA, to: mirroredB, bulge: bulges[0])

        // Ground truth: mirror the ORIGINAL arc's center directly and compare radius.
        let directMirroredCenter = t.apply(originalArc.center)
        XCTAssertEqual(reconstructedArc.center.x, directMirroredCenter.x, accuracy: eps)
        XCTAssertEqual(reconstructedArc.center.y, directMirroredCenter.y, accuracy: eps)
        XCTAssertEqual(reconstructedArc.r, originalArc.r, accuracy: eps)
    }

    func testPolylineScaleAppliesToConstantWidth() {
        var c = EntityPayloadCopy.polyline(
            PolylinePayload(vertsStart: 0, vertsCount: 2, bulgesStart: 0, closed: false, constantWidth: 2),
            vertices: [Vec3(x: 0, y: 0), Vec3(x: 1, y: 0)],
            bulges: [0, 0])
        let t = Transform2.scaling(about: Vec2(0, 0), factor: 3)
        EntityTransform.apply(t, to: &c, mirrtext: false)
        guard case .polyline(let p, _, _) = c else { return XCTFail() }
        assertClose(p.constantWidth, 6)
    }

    // MARK: - Ellipse: majorAxis as vector, mirror swaps/negates params

    func testEllipseRotateMapsMajorAxis() {
        var c = EntityPayloadCopy.ellipse(EllipsePayload(center: Vec3(x: 0, y: 0),
            majorAxisEndpoint: Vec3(x: 5, y: 0), ratio: 0.5, startParam: 0, endParam: .pi))
        let t = Transform2.rotation(about: Vec2(0, 0), angleRad: .pi / 2)
        EntityTransform.apply(t, to: &c, mirrtext: false)
        guard case .ellipse(let p) = c else { return XCTFail() }
        assertClose(p.majorAxisEndpoint, Vec3(x: 0, y: 5))
        assertClose(p.startParam, 0)
        assertClose(p.endParam, .pi)
    }

    func testEllipseMirrorSwapsParamsAndPreservesRatioSign() {
        let start = 0.3, end = 2.1
        var c = EntityPayloadCopy.ellipse(EllipsePayload(center: Vec3(x: 0, y: 0),
            majorAxisEndpoint: Vec3(x: 5, y: 0), ratio: 0.5, startParam: start, endParam: end))
        let t = Transform2.mirror(across: Vec2(0, 0), Vec2(1, 0))
        EntityTransform.apply(t, to: &c, mirrtext: false)
        guard case .ellipse(let p) = c else { return XCTFail() }
        assertClose(p.startParam, -end)
        assertClose(p.endParam, -start)
        // Unlike Curve2.reversed() (which fixes majorAxis and flips ratio's
        // sign to encode reversal), EntityTransform remaps majorAxisEndpoint
        // itself through the mirror, so ratio's sign is UNCHANGED — see the
        // derivation in EntityTransform.swift's ellipse case.
        assertClose(p.ratio, 0.5)
    }

    func testEllipseMirrorEndpointsMatchDirectReflection() {
        // Ground truth: evaluate the ORIGINAL ellipse curve at start/end,
        // mirror those points directly, and confirm the transformed
        // ellipse's OWN start/end params land on the same mirrored points.
        let center = Vec2(1, 1)
        let majorAxis = Vec2(4, 0)
        let ratio = 0.4
        let start = 0.2, end = 2.5
        func evalOriginal(_ u: Double) -> Vec2 {
            let minor = Vec2(-majorAxis.y, majorAxis.x) * ratio
            return center + majorAxis * cos(u) + minor * sin(u)
        }
        let originalStartPt = evalOriginal(start)
        let originalEndPt = evalOriginal(end)

        var c = EntityPayloadCopy.ellipse(EllipsePayload(center: Vec3(x: center.x, y: center.y),
            majorAxisEndpoint: Vec3(x: majorAxis.x, y: majorAxis.y), ratio: ratio,
            startParam: start, endParam: end))
        let t = Transform2.mirror(across: Vec2(0, 5), Vec2(3, 5))
        EntityTransform.apply(t, to: &c, mirrtext: false)
        guard case .ellipse(let p) = c else { return XCTFail() }

        func evalTransformed(_ u: Double) -> Vec2 {
            let newCenter = Vec2(p.center.x, p.center.y)
            let newMajor = Vec2(p.majorAxisEndpoint.x, p.majorAxisEndpoint.y)
            let newMinor = Vec2(-newMajor.y, newMajor.x) * p.ratio
            return newCenter + newMajor * cos(u) + newMinor * sin(u)
        }
        let gotStartPt = evalTransformed(p.startParam)
        let gotEndPt = evalTransformed(p.endParam)
        let mirroredOriginalStart = t.apply(originalStartPt)
        let mirroredOriginalEnd = t.apply(originalEndPt)

        // Reflection reverses traversal (see Curve2.reversed()'s ellipse
        // case), so start/end swap: the transformed ellipse's OWN startParam
        // lands on the mirror of the ORIGINAL end point, and vice versa.
        XCTAssertEqual(gotStartPt.x, mirroredOriginalEnd.x, accuracy: 1e-6)
        XCTAssertEqual(gotStartPt.y, mirroredOriginalEnd.y, accuracy: 1e-6)
        XCTAssertEqual(gotEndPt.x, mirroredOriginalStart.x, accuracy: 1e-6)
        XCTAssertEqual(gotEndPt.y, mirroredOriginalStart.y, accuracy: 1e-6)
    }

    // MARK: - Spline: control points as points, structure untouched

    func testSplineControlPointsTransform() {
        var c = EntityPayloadCopy.spline(
            SplinePayload(degree: 3, controlStart: 0, controlCount: 4, knotStart: 0, knotCount: 8,
                         weightStart: 0, weightCount: 0, closed: false),
            control: [Vec3(x: 0, y: 0), Vec3(x: 1, y: 1), Vec3(x: 2, y: 1), Vec3(x: 3, y: 0)],
            knots: [0, 0, 0, 0, 1, 1, 1, 1],
            weights: [])
        let t = Transform2.translation(dx: 5, dy: 5)
        EntityTransform.apply(t, to: &c, mirrtext: false)
        guard case .spline(let p, let control, let knots, let weights) = c else { return XCTFail() }
        assertClose(control[0], Vec3(x: 5, y: 5))
        assertClose(control[3], Vec3(x: 8, y: 5))
        XCTAssertEqual(knots, [0, 0, 0, 0, 1, 1, 1, 1], "knots must be untouched")
        XCTAssertTrue(weights.isEmpty)
        XCTAssertEqual(p.degree, 3)
    }

    // MARK: - Text: MIRRTEXT=0 re-normalizes; MIRRTEXT=1 goes backwards

    func testTextRotateAccumulates() {
        var c = EntityPayloadCopy.text(TextPayload(position: Vec3(x: 0, y: 0), height: 2,
                                                    rotationDeg: 10, stringId: 0))
        let t = Transform2.rotation(about: Vec2(0, 0), angleRad: .pi / 2)
        EntityTransform.apply(t, to: &c, mirrtext: false)
        guard case .text(let p) = c else { return XCTFail() }
        assertClose(p.rotationDeg, 100)
    }

    func testTextScaleAppliesToHeight() {
        var c = EntityPayloadCopy.text(TextPayload(position: Vec3(x: 0, y: 0), height: 2,
                                                    rotationDeg: 0, stringId: 0))
        let t = Transform2.scaling(about: Vec2(0, 0), factor: 2.5)
        EntityTransform.apply(t, to: &c, mirrtext: false)
        guard case .text(let p) = c else { return XCTFail() }
        assertClose(p.height, 5)
    }

    func testTextMirrorMirrtextFalseReNormalizesAndSwapsAlign() {
        var c = EntityPayloadCopy.text(TextPayload(position: Vec3(x: 0, y: 0), height: 2,
                                                    rotationDeg: 30, stringId: 0, hAlign: 0, vAlign: 0))
        let t = Transform2.mirror(across: Vec2(0, 0), Vec2(1, 0))
        EntityTransform.apply(t, to: &c, mirrtext: false)
        guard case .text(let p) = c else { return XCTFail() }
        XCTAssertFalse(p.isBackwards, "MIRRTEXT=0 must not set isBackwards")
        XCTAssertEqual(p.hAlign, 2, "left-align must swap to right-align under MIRRTEXT=0 re-normalization")
    }

    func testTextMirrorMirrtextFalseSwapsRightToLeft() {
        var c = EntityPayloadCopy.text(TextPayload(position: Vec3(x: 0, y: 0), height: 2,
                                                    rotationDeg: 0, stringId: 0, hAlign: 2, vAlign: 0))
        let t = Transform2.mirror(across: Vec2(0, 0), Vec2(1, 0))
        EntityTransform.apply(t, to: &c, mirrtext: false)
        guard case .text(let p) = c else { return XCTFail() }
        XCTAssertEqual(p.hAlign, 0)
    }

    func testTextMirrorMirrtextFalseLeavesCenterAlignAlone() {
        var c = EntityPayloadCopy.text(TextPayload(position: Vec3(x: 0, y: 0), height: 2,
                                                    rotationDeg: 0, stringId: 0, hAlign: 1, vAlign: 0))
        let t = Transform2.mirror(across: Vec2(0, 0), Vec2(1, 0))
        EntityTransform.apply(t, to: &c, mirrtext: false)
        guard case .text(let p) = c else { return XCTFail() }
        XCTAssertEqual(p.hAlign, 1, "center alignment has no left/right sense to swap")
    }

    func testTextMirrorMirrtextTrueTogglesBackwardsAndKeepsReflectedRotation() {
        var c = EntityPayloadCopy.text(TextPayload(position: Vec3(x: 0, y: 0), height: 2,
                                                    rotationDeg: 30, stringId: 0, hAlign: 0, vAlign: 0))
        let t = Transform2.mirror(across: Vec2(0, 0), Vec2(1, 0))
        EntityTransform.apply(t, to: &c, mirrtext: true)
        guard case .text(let p) = c else { return XCTFail() }
        XCTAssertTrue(p.isBackwards)
        // Reflected rotation: alpha (mirror axis angle) = 0 for the X axis,
        // so rotationDeg' = 2*0 - 30 = -30.
        assertClose(p.rotationDeg, -30)
        XCTAssertEqual(p.hAlign, 0, "MIRRTEXT=1 does not touch alignment — only the render-time x-flip changes")
    }

    func testTextMirrorTwiceWithMirrtextTrueReturnsToForward() {
        var c = EntityPayloadCopy.text(TextPayload(position: Vec3(x: 0, y: 0), height: 2,
                                                    rotationDeg: 30, stringId: 0))
        let t = Transform2.mirror(across: Vec2(0, 0), Vec2(1, 0))
        EntityTransform.apply(t, to: &c, mirrtext: true)
        EntityTransform.apply(t, to: &c, mirrtext: true)
        guard case .text(let p) = c else { return XCTFail() }
        XCTAssertFalse(p.isBackwards, "mirroring twice with MIRRTEXT=1 must toggle isBackwards back off")
        assertClose(p.rotationDeg, 30)
    }

    // MARK: - MText: rotation accumulates/reflects; no hAlign/isBackwards to touch

    func testMTextRotateAccumulates() {
        var c = EntityPayloadCopy.mtext(MTextPayload(insertion: Vec3(x: 0, y: 0), height: 3,
                                                      rotationDeg: 15, stringId: 0))
        let t = Transform2.rotation(about: Vec2(0, 0), angleRad: .pi)
        EntityTransform.apply(t, to: &c, mirrtext: false)
        guard case .mtext(let p) = c else { return XCTFail() }
        assertClose(p.rotationDeg, 195)
    }

    func testMTextScaleAppliesToHeightAndRefWidth() {
        var c = EntityPayloadCopy.mtext(MTextPayload(insertion: Vec3(x: 0, y: 0), height: 2,
                                                      refWidth: 10, rotationDeg: 0, stringId: 0))
        let t = Transform2.scaling(about: Vec2(0, 0), factor: 2)
        EntityTransform.apply(t, to: &c, mirrtext: false)
        guard case .mtext(let p) = c else { return XCTFail() }
        assertClose(p.height, 4)
        assertClose(p.refWidth, 20)
    }

    // MARK: - Insert: standard DXF mirror encoding (scale.x *= -1)

    func testInsertMoveAndRotate() {
        var c = EntityPayloadCopy.insert(InsertPayload(blockNameId: 0, position: Vec3(x: 1, y: 0),
                                                        scale: Vec3(x: 1, y: 1, z: 1), rotationDeg: 0))
        let t = Transform2.rotation(about: Vec2(0, 0), angleRad: .pi / 2)
        EntityTransform.apply(t, to: &c, mirrtext: false)
        guard case .insert(let p) = c else { return XCTFail() }
        assertClose(p.position, Vec3(x: 0, y: 1))
        assertClose(p.rotationDeg, 90)
        assertClose(p.scale.x, 1)
    }

    func testInsertScaleMultipliesAllAxes() {
        var c = EntityPayloadCopy.insert(InsertPayload(blockNameId: 0, position: Vec3(x: 0, y: 0),
                                                        scale: Vec3(x: 2, y: 3, z: 1), rotationDeg: 0))
        let t = Transform2.scaling(about: Vec2(0, 0), factor: 2)
        EntityTransform.apply(t, to: &c, mirrtext: false)
        guard case .insert(let p) = c else { return XCTFail() }
        assertClose(p.scale.x, 4)
        assertClose(p.scale.y, 6)
        assertClose(p.scale.z, 2)
    }

    func testInsertMirrorNegatesScaleXAndReflectsRotation() {
        var c = EntityPayloadCopy.insert(InsertPayload(blockNameId: 0, position: Vec3(x: 5, y: 0),
                                                        scale: Vec3(x: 1, y: 1, z: 1), rotationDeg: 20))
        let t = Transform2.mirror(across: Vec2(0, 0), Vec2(1, 0))
        EntityTransform.apply(t, to: &c, mirrtext: false)
        guard case .insert(let p) = c else { return XCTFail() }
        assertClose(p.position, Vec3(x: 5, y: 0))
        XCTAssertEqual(p.scale.x, -1, accuracy: eps, "mirroring an INSERT negates scale.x per standard DXF encoding")
        assertClose(p.scale.y, 1, "scale.y is untouched by a mirror — only X carries the flip")
        assertClose(p.rotationDeg, -20, "rotation reflects through the mirror axis angle (0 here)")
    }

    /// Regression test for a bug an adversarial review found and this
    /// session fixed: mirroring across a NON-horizontal line previously
    /// used `2 * alpha - rotationDeg` where `alpha` (`Transform2.
    /// rotationAngle`) is ALREADY 2x the mirror line's own angle for a
    /// reflection matrix, double-counting it. A horizontal mirror line
    /// (alpha = 0) can't expose this — `2*0` and `0` are identical — which
    /// is exactly why every pre-existing mirror test in this file used one.
    /// A VERTICAL mirror line (the everyday "flip left-right" case) makes
    /// alpha = 180°, so the bug and the fix diverge by a full 180°: the
    /// buggy formula gives 340° for this input, the correct answer is 160°.
    func testInsertMirrorAcrossVerticalLineReflectsRotationCorrectly() {
        var c = EntityPayloadCopy.insert(InsertPayload(blockNameId: 0, position: Vec3(x: 5, y: 0),
                                                        scale: Vec3(x: 1, y: 1, z: 1), rotationDeg: 20))
        let t = Transform2.mirror(across: Vec2(0, 0), Vec2(0, 1))   // vertical line (the Y axis)
        EntityTransform.apply(t, to: &c, mirrtext: false)
        guard case .insert(let p) = c else { return XCTFail() }
        // Normalize to [0, 360) before comparing — the formula can return
        // either 160 or -200 depending on angle wrap, both equivalent.
        let normalized = p.rotationDeg.truncatingRemainder(dividingBy: 360) + (p.rotationDeg < 0 ? 360 : 0)
        assertClose(normalized, 160, "mirroring 20° across a vertical line must give 160°, not the buggy formula's 340°")
    }

    /// Same regression, for TEXT (MIRRTEXT=1, so the reflected rotation is
    /// kept as-is rather than re-normalized — the most direct way to check
    /// the raw reflection formula without the MIRRTEXT=0 alignment-swap
    /// logic also in play).
    func testTextMirrorAcrossVerticalLineWithMirrtextTrueReflectsRotationCorrectly() {
        var c = EntityPayloadCopy.text(TextPayload(position: Vec3(x: 5, y: 0), height: 1,
                                                    rotationDeg: 20, stringId: 0))
        let t = Transform2.mirror(across: Vec2(0, 0), Vec2(0, 1))
        EntityTransform.apply(t, to: &c, mirrtext: true)
        guard case .text(let p) = c else { return XCTFail() }
        let normalized = p.rotationDeg.truncatingRemainder(dividingBy: 360) + (p.rotationDeg < 0 ? 360 : 0)
        assertClose(normalized, 160, "mirroring 20° across a vertical line must give 160°, not the buggy formula's 340°")
    }

    /// Same regression, for MTEXT.
    func testMtextMirrorAcrossVerticalLineReflectsRotationCorrectly() {
        var c = EntityPayloadCopy.mtext(MTextPayload(insertion: Vec3(x: 5, y: 0), height: 1,
                                                      refWidth: 0, rotationDeg: 20, stringId: 0))
        let t = Transform2.mirror(across: Vec2(0, 0), Vec2(0, 1))
        EntityTransform.apply(t, to: &c, mirrtext: false)
        guard case .mtext(let p) = c else { return XCTFail() }
        let normalized = p.rotationDeg.truncatingRemainder(dividingBy: 360) + (p.rotationDeg < 0 ? 360 : 0)
        assertClose(normalized, 160, "mirroring 20° across a vertical line must give 160°, not the buggy formula's 340°")
    }

    /// Same regression for ARC, but against a genuine ground-truth
    /// endpoint reflection (like `testArcMirrorMatchesDirectEndpointReflection`
    /// above, which uses the X axis — a DIAGONAL line here specifically
    /// because it's the case the bug actually breaks).
    func testArcMirrorAcrossDiagonalLineMatchesDirectEndpointReflection() {
        let center = Vec3(x: 0, y: 0)
        let radius = 5.0
        let startDeg = 30.0, endDeg = 120.0
        var c = EntityPayloadCopy.arc(ArcPayload(center: center, radius: radius,
                                                  startAngleDeg: startDeg, endAngleDeg: endDeg))
        // A 30-degree mirror line through the origin: (0,0)-(cos30,sin30).
        let t = Transform2.mirror(across: Vec2(0, 0), Vec2(cos(30 * .pi / 180), sin(30 * .pi / 180)))
        EntityTransform.apply(t, to: &c, mirrtext: false)
        guard case .arc(let p) = c else { return XCTFail() }

        func pointOnCircle(_ deg: Double) -> Vec2 {
            let rad = deg * .pi / 180
            return Vec2(center.x + radius * cos(rad), center.y + radius * sin(rad))
        }
        let mirroredStartPoint = t.apply(pointOnCircle(startDeg))
        let mirroredEndPoint = t.apply(pointOnCircle(endDeg))
        func pointFromTransformed(_ deg: Double) -> Vec2 {
            let rad = deg * .pi / 180
            return Vec2(p.center.x + p.radius * cos(rad), p.center.y + p.radius * sin(rad))
        }
        let gotStart = pointFromTransformed(p.startAngleDeg)
        let gotEnd = pointFromTransformed(p.endAngleDeg)
        XCTAssertEqual(gotStart.x, mirroredEndPoint.x, accuracy: eps)
        XCTAssertEqual(gotStart.y, mirroredEndPoint.y, accuracy: eps)
        XCTAssertEqual(gotEnd.x, mirroredStartPoint.x, accuracy: eps)
        XCTAssertEqual(gotEnd.y, mirroredStartPoint.y, accuracy: eps)
    }

    func testInsertMirrorTwiceReturnsOriginalScale() {
        var c = EntityPayloadCopy.insert(InsertPayload(blockNameId: 0, position: Vec3(x: 5, y: 3),
                                                        scale: Vec3(x: 1, y: 1, z: 1), rotationDeg: 45))
        let t = Transform2.mirror(across: Vec2(1, 1), Vec2(4, -2))
        EntityTransform.apply(t, to: &c, mirrtext: false)
        EntityTransform.apply(t, to: &c, mirrtext: false)
        guard case .insert(let p) = c else { return XCTFail() }
        assertClose(p.scale.x, 1)
        assertClose(p.rotationDeg, 45)
        assertClose(p.position, Vec3(x: 5, y: 3))
    }

    // MARK: - Hatch

    func testHatchOriginAndLoopsTransform() {
        var c = EntityPayloadCopy.hatch(
            HatchPayload(isSolid: true, angle: 0, scale: 1, origin: Vec3(x: 0, y: 0)),
            loops: [[Vec3(x: 0, y: 0), Vec3(x: 1, y: 0), Vec3(x: 1, y: 1)]])
        let t = Transform2.translation(dx: 10, dy: 20)
        EntityTransform.apply(t, to: &c, mirrtext: false)
        guard case .hatch(let p, let loops) = c else { return XCTFail() }
        assertClose(p.origin, Vec3(x: 10, y: 20))
        assertClose(loops[0][0], Vec3(x: 10, y: 20))
        assertClose(loops[0][2], Vec3(x: 11, y: 21))
    }

    func testHatchScaleUpdatesScaleField() {
        var c = EntityPayloadCopy.hatch(
            HatchPayload(isSolid: false, angle: 0, scale: 1, origin: Vec3(x: 0, y: 0)),
            loops: [[Vec3(x: 0, y: 0), Vec3(x: 1, y: 0), Vec3(x: 0, y: 1)]])
        let t = Transform2.scaling(about: Vec2(0, 0), factor: 3)
        EntityTransform.apply(t, to: &c, mirrtext: false)
        guard case .hatch(let p, _) = c else { return XCTFail() }
        assertClose(p.scale, 3)
    }

    // MARK: - Round-trip: rotate 90 twice == rotate 180 once, on real payloads

    func testRotate90TwiceEqualsRotate180OnceForLine() {
        var c1 = EntityPayloadCopy.line(LinePayload(a: Vec3(x: 3, y: 1), b: Vec3(x: 7, y: -2)))
        var c2 = c1
        let r90 = Transform2.rotation(about: Vec2(2, 2), angleRad: .pi / 2)
        let r180 = Transform2.rotation(about: Vec2(2, 2), angleRad: .pi)
        EntityTransform.apply(r90, to: &c1, mirrtext: false)
        EntityTransform.apply(r90, to: &c1, mirrtext: false)
        EntityTransform.apply(r180, to: &c2, mirrtext: false)
        guard case .line(let p1) = c1, case .line(let p2) = c2 else { return XCTFail() }
        assertClose(p1.a, p2.a)
        assertClose(p1.b, p2.b)
    }

    // MARK: - unknown payload is a no-op

    func testUnknownPayloadIsNoOp() {
        var c = EntityPayloadCopy.unknown
        let t = Transform2.rotation(about: Vec2(0, 0), angleRad: 1)
        EntityTransform.apply(t, to: &c, mirrtext: false)
        guard case .unknown = c else { return XCTFail("unknown must remain unknown") }
    }
}
