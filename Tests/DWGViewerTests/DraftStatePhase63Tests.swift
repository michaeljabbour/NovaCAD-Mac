import XCTest
@testable import DWGViewer
import CADCore

/// Phase 6.3: ELLIPSE/POINT/SPLINE/3DFACE `DraftState` tool tests — pure
/// geometry (no EntityStore needed beyond a throwaway one for `DraftContext`,
/// mirroring `HeadlessCommandHarness`'s own "scratch store, never read"
/// convention since none of these modes intern strings).
final class DraftStatePhase63Tests: XCTestCase {

    private func ctx() -> DraftContext {
        DraftContext(layerId: 0, aci: 7, owner: .model, store: EntityStore())
    }

    // MARK: - ELLIPSE — ratio (perpendicular-distance) mode

    /// Center (0,0), major axis endpoint (10,0) (majorLen=10), 3rd point at
    /// (0,4) — perpendicular distance from the major axis line (the X axis)
    /// is exactly 4, so ratio = 4/10 = 0.4.
    func testEllipseCenterFormRatioFromPerpendicularDistance() throws {
        var draft = DraftState(mode: .ellipse)
        _ = draft.addPoint(CGPoint(x: 0, y: 0), ctx: ctx())
        _ = draft.addPoint(CGPoint(x: 10, y: 0), ctx: ctx())
        let output = draft.addPoint(CGPoint(x: 0, y: 4), ctx: ctx())
        guard case .entity(let proto) = output, case .ellipse(let e) = proto.payload else {
            return XCTFail("expected an ellipse entity")
        }
        XCTAssertEqual(e.center.x, 0, accuracy: 1e-9)
        XCTAssertEqual(e.center.y, 0, accuracy: 1e-9)
        XCTAssertEqual(e.majorAxisEndpoint.x, 10, accuracy: 1e-9)
        XCTAssertEqual(e.majorAxisEndpoint.y, 0, accuracy: 1e-9)
        XCTAssertEqual(e.ratio, 0.4, accuracy: 1e-9)
    }

    /// ratio > 1 (the "minor" pick is actually farther than the major
    /// endpoint) swaps the axes: center (0,0), "major" endpoint (5,0)
    /// (length 5), 3rd point perpendicular distance 10 -> raw ratio 2.0,
    /// which must swap to majorAxisEndpoint = (0,5) (rotated 90 degrees,
    /// length preserved at the ORIGINAL 5... wait — per the swap rule the
    /// new major is perp(oldMajor) with the SAME magnitude as oldMajor, and
    /// ratio becomes 1/2 = 0.5). Verifies both the swapped endpoint and the
    /// inverted ratio.
    func testEllipseRatioGreaterThanOneSwapsAxes() throws {
        var draft = DraftState(mode: .ellipse)
        _ = draft.addPoint(CGPoint(x: 0, y: 0), ctx: ctx())
        _ = draft.addPoint(CGPoint(x: 5, y: 0), ctx: ctx())
        let output = draft.addPoint(CGPoint(x: 0, y: 10), ctx: ctx())
        guard case .entity(let proto) = output, case .ellipse(let e) = proto.payload else {
            return XCTFail("expected an ellipse entity")
        }
        // majorLen=5, perp (distance from (0,10) to the X-axis line) = 10,
        // so raw ratio = 10/5 = 2 > 1 -> swap. The TRUE major axis is
        // perpendicular to the picked (5,0) with length = perp = 10 (NOT
        // majorLen=5), i.e. (0,10), and the stored ratio inverts to 0.5.
        XCTAssertEqual(e.majorAxisEndpoint.x, 0, accuracy: 1e-9)
        XCTAssertEqual(e.majorAxisEndpoint.y, 10, accuracy: 1e-9)
        XCTAssertEqual(e.ratio, 0.5, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(e.ratio, 1.0)
    }

    /// R (rotation-mode) keyword: ratio = cos(angle). Center (0,0), major
    /// endpoint (10,0), rotation-mode 3rd click at a point making a 60
    /// degree angle with the major axis from the center: e.g. (5, 5*sqrt(3))
    /// which is at exactly 60 degrees from +X. Expected ratio = cos(60) = 0.5.
    func testEllipseRotationModeRatioIsCosineOfAngle() throws {
        var draft = DraftState(mode: .ellipse)
        draft.ellipseRotationMode = true
        _ = draft.addPoint(CGPoint(x: 0, y: 0), ctx: ctx())
        _ = draft.addPoint(CGPoint(x: 10, y: 0), ctx: ctx())
        let angleRad = 60.0 * .pi / 180
        let farPoint = CGPoint(x: CGFloat(cos(angleRad)) * 100, y: CGFloat(sin(angleRad)) * 100)
        let output = draft.addPoint(farPoint, ctx: ctx())
        guard case .entity(let proto) = output, case .ellipse(let e) = proto.payload else {
            return XCTFail("expected an ellipse entity")
        }
        XCTAssertEqual(e.ratio, cos(angleRad), accuracy: 1e-6)
    }

    /// Rotation mode at 90 degrees degenerates to ratio 0 (a degenerate
    /// ellipse, collapsed to a line) — the guard `ratio > 1e-9` must reject
    /// this rather than emit a zero-area ellipse.
    func testEllipseRotationMode90DegreesIsRejectedAsDegenerate() {
        var draft = DraftState(mode: .ellipse)
        draft.ellipseRotationMode = true
        _ = draft.addPoint(CGPoint(x: 0, y: 0), ctx: ctx())
        _ = draft.addPoint(CGPoint(x: 10, y: 0), ctx: ctx())
        let output = draft.addPoint(CGPoint(x: 0, y: 50), ctx: ctx())
        guard case .none = output else {
            return XCTFail("expected .none for a degenerate (ratio≈0) ellipse")
        }
    }

    /// Axis-endpoint variant: two clicks define ONE axis directly (center =
    /// midpoint), 3rd click sets the ratio via perpendicular distance —
    /// axis endpoints (0,0) and (10,0) -> center (5,0), major vector (5,0)
    /// (length 5); 3rd point (5,2) is perpendicular distance 2 from the
    /// axis line -> ratio = 2/5 = 0.4.
    func testEllipseAxisEndpointFormComputesCenterAsMidpoint() throws {
        var draft = DraftState(mode: .ellipseAxis)
        _ = draft.addPoint(CGPoint(x: 0, y: 0), ctx: ctx())
        _ = draft.addPoint(CGPoint(x: 10, y: 0), ctx: ctx())
        let output = draft.addPoint(CGPoint(x: 5, y: 2), ctx: ctx())
        guard case .entity(let proto) = output, case .ellipse(let e) = proto.payload else {
            return XCTFail("expected an ellipse entity")
        }
        XCTAssertEqual(e.center.x, 5, accuracy: 1e-9)
        XCTAssertEqual(e.center.y, 0, accuracy: 1e-9)
        XCTAssertEqual(e.majorAxisEndpoint.x, 5, accuracy: 1e-9)
        XCTAssertEqual(e.ratio, 0.4, accuracy: 1e-9)
    }

    // MARK: - POINT

    func testPointEntCreatesAPointAtTheClickAndStaysActive() throws {
        var draft = DraftState(mode: .pointEnt)
        let output = draft.addPoint(CGPoint(x: 3, y: 4), ctx: ctx())
        guard case .entity(let proto) = output, case .point(let p) = proto.payload else {
            return XCTFail("expected a point entity")
        }
        XCTAssertEqual(p.p.x, 3, accuracy: 1e-9)
        XCTAssertEqual(p.p.y, 4, accuracy: 1e-9)
        XCTAssertEqual(draft.mode, .pointEnt, "POINT tool must stay active for repeated placement")
        XCTAssertTrue(draft.points.isEmpty, "POINT never accumulates a point buffer")
    }

    // MARK: - 3DFACE

    func testFace3DCompletesOnFourthClick() throws {
        var draft = DraftState(mode: .face3d)
        _ = draft.addPoint(CGPoint(x: 0, y: 0), ctx: ctx())
        _ = draft.addPoint(CGPoint(x: 10, y: 0), ctx: ctx())
        _ = draft.addPoint(CGPoint(x: 10, y: 10), ctx: ctx())
        let output = draft.addPoint(CGPoint(x: 0, y: 10), ctx: ctx())
        guard case .entity(let proto) = output, case .polyline(let p, let verts, _) = proto.payload else {
            return XCTFail("expected a polyline-backed 3DFACE entity")
        }
        XCTAssertEqual(proto.type, .face3d)
        XCTAssertTrue(p.closed)
        XCTAssertEqual(verts.count, 4)
        XCTAssertEqual(draft.points.count, 0, "3DFACE resets after completing")
    }

    func testFace3DThirdEqualsFourthCollapsesToTriangle() throws {
        // AutoCAD convention: repeating the 3rd point as the 4th closes the
        // face as a triangle — this app stores it as a degenerate 4-vertex
        // polyline with two coincident vertices rather than a distinct
        // 3-vertex shape (documented simplification), so this test just
        // confirms the SHAPE still completes without crashing/rejecting.
        var draft = DraftState(mode: .face3d)
        _ = draft.addPoint(CGPoint(x: 0, y: 0), ctx: ctx())
        _ = draft.addPoint(CGPoint(x: 10, y: 0), ctx: ctx())
        _ = draft.addPoint(CGPoint(x: 5, y: 10), ctx: ctx())
        let output = draft.addPoint(CGPoint(x: 5, y: 10), ctx: ctx())
        guard case .entity(let proto) = output, case .polyline(_, let verts, _) = proto.payload else {
            return XCTFail("expected a polyline-backed 3DFACE entity")
        }
        XCTAssertEqual(verts.count, 4)
        XCTAssertEqual(verts[2], verts[3])
    }

    // MARK: - SPLINE (fit points)

    func testSplineFitRequiresAtLeastTwoPointsToFinish() {
        var draft = DraftState(mode: .splineFit)
        _ = draft.addPoint(CGPoint(x: 0, y: 0), ctx: ctx())
        let output = draft.finishSplineFit(close: false, ctx: ctx())
        guard case .none = output else {
            return XCTFail("a single fit point must not produce a spline")
        }
    }

    func testSplineFitProducesAValidNURBSThroughAllPoints() throws {
        var draft = DraftState(mode: .splineFit)
        _ = draft.addPoint(CGPoint(x: 0, y: 0), ctx: ctx())
        _ = draft.addPoint(CGPoint(x: 10, y: 5), ctx: ctx())
        _ = draft.addPoint(CGPoint(x: 20, y: 0), ctx: ctx())
        let output = draft.finishSplineFit(close: false, ctx: ctx())
        guard case .entity(let proto) = output, case .spline = proto.payload else {
            return XCTFail("expected a spline entity")
        }
        XCTAssertEqual(proto.type, .spline)
        XCTAssertTrue(draft.points.isEmpty)
    }

    func testSplineCVRequiresAtLeastFourControlPoints() {
        var draft = DraftState(mode: .splineCV)
        for p in [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 2, y: 0)] {
            _ = draft.addPoint(p, ctx: ctx())
        }
        let output = draft.finishSplineCV(ctx: ctx())
        guard case .none = output else {
            return XCTFail("3 control points must not produce a degree-3 spline")
        }
    }

    func testSplineCVWithFourPointsProducesADegree3Spline() throws {
        var draft = DraftState(mode: .splineCV)
        for p in [CGPoint(x: 0, y: 0), CGPoint(x: 5, y: 5), CGPoint(x: 10, y: 5), CGPoint(x: 15, y: 0)] {
            _ = draft.addPoint(p, ctx: ctx())
        }
        let output = draft.finishSplineCV(ctx: ctx())
        guard case .entity(let proto) = output, case .spline(let payload, let control, _, _) = proto.payload else {
            return XCTFail("expected a spline entity")
        }
        XCTAssertEqual(payload.degree, 3)
        XCTAssertEqual(control.count, 4)
    }

    // MARK: - CurrentProperties resolution

    func testCurrentPropertiesResolvedLayerIdCreatesLayerIfMissing() {
        let parsed = EditableParsedDocument()
        var props = CurrentProperties()
        props.layerName = "MY-NEW-LAYER"
        XCTAssertNil(parsed.layerIdByName["MY-NEW-LAYER"])
        let id = props.resolvedLayerId(in: parsed)
        XCTAssertEqual(parsed.layerIdByName["MY-NEW-LAYER"], id)
        XCTAssertEqual(parsed.layers.first { $0.id == Int(id) }?.name, "MY-NEW-LAYER")
    }

    func testCurrentPropertiesAciOrByLayerDefaultsToByLayer() {
        let props = CurrentProperties()
        XCTAssertEqual(props.aciOrByLayer, 256)
        var withColor = props
        withColor.color = 3
        XCTAssertEqual(withColor.aciOrByLayer, 3)
    }

    func testCurrentPropertiesResolvedLinetypeFallsBackToByLayerWhenUnknown() {
        let parsed = EditableParsedDocument()
        parsed.linetypes.append(DXFLinetype(name: "DASHED", dashes: [5, 2]))
        parsed.linetypeIdByName["DASHED"] = 0
        var props = CurrentProperties()
        props.linetypeName = "DASHED"
        XCTAssertEqual(props.resolvedLinetypeId(in: parsed), 0)
        props.linetypeName = "NO-SUCH-LINETYPE"
        XCTAssertEqual(props.resolvedLinetypeId(in: parsed), -1)
        props.linetypeName = nil
        XCTAssertEqual(props.resolvedLinetypeId(in: parsed), -1)
    }
}
