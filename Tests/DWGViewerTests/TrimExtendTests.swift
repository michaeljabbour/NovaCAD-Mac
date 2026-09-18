//
//  TrimExtendTests.swift
//  DWGViewerTests
//
//  Direct EntityStore construction (no file I/O) covering TrimExtend's core
//  geometry per the plan's gate: line/line, line/arc, circle->arc conversion,
//  closed-polyline open-up, bulge-preserving partial removal, EXTEND incl.
//  spline tangent-ray, and defensive no-crash cases.
//

import XCTest
import simd
@testable import DWGViewer
import CADCore

final class TrimExtendTests: XCTestCase {

    let tol = Tolerance(linear: 1e-6)

    private func makeStore() -> EntityStore { EntityStore() }

    @discardableResult
    private func addLine(_ store: EntityStore, _ a: Vec2, _ b: Vec2) -> EntityID {
        store.append(EntityPrototype(type: .line, layerId: 0,
                                     payload: .line(LinePayload(a: Vec3(x: a.x, y: a.y), b: Vec3(x: b.x, y: b.y)))))
    }

    @discardableResult
    private func addArc(_ store: EntityStore, center: Vec2, r: Double, startDeg: Double, endDeg: Double) -> EntityID {
        store.append(EntityPrototype(type: .arc, layerId: 0,
                                     payload: .arc(ArcPayload(center: Vec3(x: center.x, y: center.y), radius: r,
                                                              startAngleDeg: startDeg, endAngleDeg: endDeg))))
    }

    @discardableResult
    private func addCircle(_ store: EntityStore, center: Vec2, r: Double) -> EntityID {
        store.append(EntityPrototype(type: .circle, layerId: 0,
                                     payload: .circle(CirclePayload(center: Vec3(x: center.x, y: center.y), radius: r))))
    }

    @discardableResult
    private func addPolyline(_ store: EntityStore, _ verts: [Vec2], _ bulges: [Double], closed: Bool) -> EntityID {
        store.append(EntityPrototype(type: .lwpolyline, layerId: 0,
                                     payload: .polyline(PolylinePayload(closed: closed),
                                                        vertices: verts.map { Vec3(x: $0.x, y: $0.y) }, bulges: bulges)))
    }

    private func curveOf(_ id: EntityID, in store: EntityStore) -> Curve2 {
        EntityCurveBridge.curves(for: id, in: store).first!.curve
    }

    // MARK: - LINE / LINE trim

    func testTrimLineAtSingleCrossingLine() {
        let store = makeStore()
        // Horizontal line 0->10, cut by a vertical line at x=5.
        let target = addLine(store, Vec2(0, 0), Vec2(10, 0))
        let cutter = curveOf(addLine(store, Vec2(5, -5), Vec2(5, 5)), in: store)
        // Click near x=8 (right side) — should remove [5,10], keep [0,5].
        let clickParam = 0.8   // segment param 0...1, 0.8 maps to x=8
        let outcome = TrimExtend.trim(targetId: target, clickParam: clickParam, store: store,
                                      boundaries: [cutter], extendBoundaries: false, tol: tol)
        guard case .replaceStandalone(let payloads)? = outcome?.action else { return XCTFail("expected replaceStandalone") }
        XCTAssertEqual(payloads.count, 1)
        guard case .line(let l) = payloads[0] else { return XCTFail("expected line payload") }
        XCTAssertEqual(l.a.x, 0, accuracy: 1e-9)
        XCTAssertEqual(l.b.x, 5, accuracy: 1e-9)
    }

    func testTrimLineWithTwoCrossingsRemovesMiddleKeepsTwoPieces() {
        let store = makeStore()
        let target = addLine(store, Vec2(0, 0), Vec2(10, 0))
        let cut1 = curveOf(addLine(store, Vec2(3, -5), Vec2(3, 5)), in: store)
        let cut2 = curveOf(addLine(store, Vec2(7, -5), Vec2(7, 5)), in: store)
        // Click at x=5 (param 0.5) is between the two cuts -> remove middle.
        let outcome = TrimExtend.trim(targetId: target, clickParam: 0.5, store: store,
                                      boundaries: [cut1, cut2], extendBoundaries: false, tol: tol)
        guard case .replaceStandalone(let payloads)? = outcome?.action else { return XCTFail("expected replaceStandalone") }
        XCTAssertEqual(payloads.count, 2, "clicking the middle interval should leave 2 surviving pieces")
        var xs: [Double] = []
        for p in payloads { if case .line(let l) = p { xs.append(l.a.x); xs.append(l.b.x) } }
        XCTAssertTrue(xs.contains(where: { abs($0 - 0) < 1e-9 }))
        XCTAssertTrue(xs.contains(where: { abs($0 - 3) < 1e-9 }))
        XCTAssertTrue(xs.contains(where: { abs($0 - 7) < 1e-9 }))
        XCTAssertTrue(xs.contains(where: { abs($0 - 10) < 1e-9 }))
    }

    func testTrimLineNoIntersectionIsNoOp() {
        let store = makeStore()
        let target = addLine(store, Vec2(0, 0), Vec2(10, 0))
        let farAway = curveOf(addLine(store, Vec2(100, -5), Vec2(100, 5)), in: store)
        let outcome = TrimExtend.trim(targetId: target, clickParam: 0.5, store: store,
                                      boundaries: [farAway], extendBoundaries: false, tol: tol)
        guard case .noOp? = outcome?.action else { return XCTFail("expected noOp when no boundary crosses") }
    }

    // MARK: - Circle -> Arc conversion (periodic trim)

    func testTrimCircleWithTwoCuttersBecomesArc() {
        let store = makeStore()
        let target = addCircle(store, center: .zero, r: 5)
        // Two vertical cutting lines at x=0's left/right — actually use two
        // lines crossing the circle at distinct angles: one along +X axis
        // direction area, one along +Y.
        let cut1 = curveOf(addLine(store, Vec2(-10, 0), Vec2(10, 0)), in: store)   // crosses circle at angle 0 and pi
        let cut2 = curveOf(addLine(store, Vec2(0, -10), Vec2(0, 10)), in: store)   // crosses circle at pi/2 and 3pi/2
        // Circle param convention: angle from +X, CCW. Click at angle pi/4
        // (45deg, between hits at 0 and pi/2) should remove that quarter.
        let clickParam = Double.pi / 4
        let outcome = TrimExtend.trim(targetId: target, clickParam: clickParam, store: store,
                                      boundaries: [cut1, cut2], extendBoundaries: false, tol: tol)
        guard case .replaceStandalone(let payloads)? = outcome?.action else { return XCTFail("expected replaceStandalone (circle->arc)") }
        // 4 hits total (0, pi/2, pi, 3pi/2) -> removing one quarter leaves 3 arc pieces.
        XCTAssertEqual(payloads.count, 3)
        for p in payloads {
            guard case .arc = p else { return XCTFail("circle trim survivors must be ARC entities, not circles") }
        }
    }

    /// Regression test for a dead zone an adversarial review found straddling
    /// the circle's 0/360-degree parameter seam. Cutting points at 10 and
    /// 350 degrees split the circle into a short arc (350 -> 0 -> 10, the
    /// wraparound piece) and a long arc (10 -> 350). Clicking at 5 degrees
    /// (inside the short arc, on the "before the seam" side) previously
    /// matched neither the plain interval [10,350] nor the wraparound
    /// interval [350, 370] and silently no-opped, even though clicking at
    /// 355 degrees (the other half of the SAME visual short arc) worked
    /// correctly. Both halves must now trim consistently.
    func testTrimCircleClickInWraparoundDeadZoneNowTrimsCorrectly() {
        let store = makeStore()
        let target = addCircle(store, center: .zero, r: 5)
        func radialCutter(atDeg deg: Double) -> Curve2 {
            let rad = deg * .pi / 180
            // A segment from the center to just past the circle's radius,
            // along a single ray — crosses the boundary exactly once, at
            // exactly `deg`, regardless of the circle's own cutting points
            // (mirrors `testTrimCircleWithOnlyOneCutterIsNoOp`'s "center ->
            // outside" pattern, just at an arbitrary angle instead of 0).
            return curveOf(addLine(store, Vec2(0, 0), Vec2(10 * cos(rad), 10 * sin(rad))), in: store)
        }
        let cut10 = radialCutter(atDeg: 10)
        let cut350 = radialCutter(atDeg: 350)
        let clickParam = 5 * Double.pi / 180   // 5 degrees — inside the short 350->0->10 arc
        let outcome = TrimExtend.trim(targetId: target, clickParam: clickParam, store: store,
                                      boundaries: [cut10, cut350], extendBoundaries: false, tol: tol)
        guard case .replaceStandalone(let payloads)? = outcome?.action else {
            return XCTFail("expected replaceStandalone — a click inside the wraparound arc must not be a silent no-op")
        }
        // Removing the short (350->10) arc leaves exactly 1 surviving piece:
        // the long arc from 10 to 350 degrees.
        XCTAssertEqual(payloads.count, 1)
        guard case .arc(let a) = payloads[0] else { return XCTFail("expected an arc payload") }
        XCTAssertEqual(a.center.x, 0, accuracy: 1e-9)
        XCTAssertEqual(a.center.y, 0, accuracy: 1e-9)
    }

    func testTrimCircleWithOnlyOneCutterIsNoOp() {
        // A line SEGMENT that starts INSIDE the circle and ends outside it
        // crosses the circle boundary exactly once — the minimal case where
        // a circle target has fewer than the 2 cutting points TRIM requires.
        let store = makeStore()
        let target = addCircle(store, center: .zero, r: 5)
        let halfCutter = curveOf(addLine(store, Vec2(0, 0), Vec2(10, 0)), in: store)   // center -> outside: 1 crossing at x=5
        let outcome = TrimExtend.trim(targetId: target, clickParam: 0.1, store: store,
                                      boundaries: [halfCutter], extendBoundaries: false, tol: tol)
        guard case .noOp? = outcome?.action else { return XCTFail("expected noOp with only 1 cutting point on a circle") }
    }

    // MARK: - LINE/ARC trim

    func testTrimLineAgainstArcBoundary() {
        let store = makeStore()
        let target = addLine(store, Vec2(-10, 0), Vec2(10, 0))
        // Semicircle arc above the line, from (−5,0) through (0,5) to (5,0) —
        // crosses the line at x=-5 and x=5.
        let arcId = addArc(store, center: .zero, r: 5, startDeg: 0, endDeg: 180)
        let arcCurve = curveOf(arcId, in: store)
        // Click near x=0 (param 0.5) is between the two crossings -> removed.
        let outcome = TrimExtend.trim(targetId: target, clickParam: 0.5, store: store,
                                      boundaries: [arcCurve], extendBoundaries: false, tol: tol)
        guard case .replaceStandalone(let payloads)? = outcome?.action else { return XCTFail("expected replaceStandalone") }
        XCTAssertEqual(payloads.count, 2)
    }

    // MARK: - Polyline (bulge-preserving partial trim + closed open-up)

    func testTrimOpenPolylineMiddleSegmentSplitsIntoTwoPolylines() {
        let store = makeStore()
        // 3-segment open polyline: (0,0)-(10,0)-(10,10)-(0,10), straight.
        let verts = [Vec2(0, 0), Vec2(10, 0), Vec2(10, 10), Vec2(0, 10)]
        let polyId = addPolyline(store, verts, [0, 0, 0, 0], closed: false)
        // TWO cutters both crossing the middle (vertical) segment 1
        // ((10,0)->(10,10)): at y=3 (local 0.3) and y=7 (local 0.7) — a
        // middle-segment split into 2 surviving polylines needs cut points
        // on BOTH sides of the click, not just one (a single cutter would
        // remove everything from the clicked side to that ONE segment
        // domain edge, still leaving exactly 1 survivor — see
        // testTrimOpenPolylineSingleCutOnMiddleSegmentLeavesOneSurvivor).
        let cut1 = curveOf(addLine(store, Vec2(5, 3), Vec2(15, 3)), in: store)
        let cut2 = curveOf(addLine(store, Vec2(5, 7), Vec2(15, 7)), in: store)
        // Segment 1 is the vertical run (10,0)->(10,10); click at y=5 (local
        // param 0.5) sits between the two cuts.
        let ecList = EntityCurveBridge.curves(for: polyId, in: store)
        XCTAssertEqual(ecList[1].polySegmentIndex, 1)
        let outcome = TrimExtend.trim(targetId: polyId, clickParam: 0.5, clickSegment: 1, store: store,
                                      boundaries: [cut1, cut2], extendBoundaries: false, tol: tol)
        guard case .replaceStandalone(let payloads)? = outcome?.action else { return XCTFail("expected 2 polylines from a middle-segment trim") }
        XCTAssertEqual(payloads.count, 2)
        for p in payloads { guard case .polyline = p else { return XCTFail("expected polyline payloads") } }
        // First survivor: (0,0)-(10,0)-(10,3). Second: (10,7)-(10,10)-(0,10).
        var foundFirst = false, foundSecond = false
        for p in payloads {
            guard case .polyline(_, let v, _) = p else { continue }
            if v.count == 3, abs(v[0].x) < 1e-9, abs(v[0].y) < 1e-9, abs(v[2].y - 3) < 1e-9 { foundFirst = true }
            if v.count == 3, abs(v[0].y - 7) < 1e-9, abs(v[2].x) < 1e-9, abs(v[2].y - 10) < 1e-9 { foundSecond = true }
        }
        XCTAssertTrue(foundFirst, "expected a surviving polyline (0,0)-(10,0)-(10,3)")
        XCTAssertTrue(foundSecond, "expected a surviving polyline (10,7)-(10,10)-(0,10)")
    }

    /// A SINGLE cutter on a middle segment removes only the side the click
    /// is on, up to that one segment's own domain edge — leaving exactly ONE
    /// surviving polyline (from the far end of the original polyline, through
    /// the untouched segments, to the cut point) — distinguishing this from
    /// the two-cutter "split into two remnants" case above.
    func testTrimOpenPolylineSingleCutOnMiddleSegmentLeavesOneSurvivor() {
        let store = makeStore()
        let verts = [Vec2(0, 0), Vec2(10, 0), Vec2(10, 10), Vec2(0, 10)]
        let polyId = addPolyline(store, verts, [0, 0, 0, 0], closed: false)
        let cutter = curveOf(addLine(store, Vec2(5, 5), Vec2(15, 5)), in: store)
        // Click below the cut (local param 0.2, y=2) removes [start-of-poly, cut].
        let outcome = TrimExtend.trim(targetId: polyId, clickParam: 0.2, clickSegment: 1, store: store,
                                      boundaries: [cutter], extendBoundaries: false, tol: tol)
        guard case .modifyInPlace(let payload)? = outcome?.action, case .polyline(_, let v, _) = payload else {
            return XCTFail("expected a single modified-in-place polyline survivor")
        }
        // Survivor: (10,5)-(10,10)-(0,10).
        XCTAssertEqual(v.count, 3)
        XCTAssertEqual(v.first?.x ?? -999, 10, accuracy: 1e-6)
        XCTAssertEqual(v.first?.y ?? -999, 5, accuracy: 1e-6)
        XCTAssertEqual(v.last?.x ?? -999, 0, accuracy: 1e-6)
        XCTAssertEqual(v.last?.y ?? -999, 10, accuracy: 1e-6)
    }

    func testTrimClosedPolylineOpensUp() {
        let store = makeStore()
        // Closed square: (0,0)-(10,0)-(10,10)-(0,10)-back to (0,0).
        let verts = [Vec2(0, 0), Vec2(10, 0), Vec2(10, 10), Vec2(0, 10)]
        let polyId = addPolyline(store, verts, [0, 0, 0, 0], closed: true)
        // Two cutters crossing segment 0 (bottom edge, (0,0)->(10,0)) at x=3 and x=7.
        let cut1 = curveOf(addLine(store, Vec2(3, -5), Vec2(3, 5)), in: store)
        let cut2 = curveOf(addLine(store, Vec2(7, -5), Vec2(7, 5)), in: store)
        // Click at x=5 on segment 0 (local param 0.5) removes the [3,7] gap on that edge.
        let outcome = TrimExtend.trim(targetId: polyId, clickParam: 0.5, clickSegment: 0, store: store,
                                      boundaries: [cut1, cut2], extendBoundaries: false, tol: tol)
        guard case .replaceStandalone(let payloads)? = outcome?.action, payloads.count == 1,
              case .polyline(let p, let newVerts, _) = payloads[0] else { return XCTFail("expected exactly 1 opened-up polyline") }
        XCTAssertFalse(p.closed, "trimming a closed polyline must open it up")
        // The new polyline should start at (7,0) and end at (3,0), walking
        // forward through (10,0)-(10,10)-(0,10)-(0,0) back to (3,0).
        XCTAssertEqual(newVerts.first?.x ?? -999, 7, accuracy: 1e-6)
        XCTAssertEqual(newVerts.last?.x ?? -999, 3, accuracy: 1e-6)
        XCTAssertEqual(newVerts.last?.y ?? -999, 0, accuracy: 1e-6)
    }

    func testTrimPolylineWithBulgePreservesPartialBulge() {
        let store = makeStore()
        // Single segment: semicircle bulge from (0,0) to (10,0), bulge=1 (180deg CCW).
        let verts = [Vec2(0, 0), Vec2(10, 0)]
        let polyId = addPolyline(store, verts, [1.0, 0.0], closed: false)
        // Cutter: vertical line at x=5 crosses the arc's apex (since the
        // semicircle bulges upward through (5,5)).
        let cutter = curveOf(addLine(store, Vec2(5, -5), Vec2(5, 15)), in: store)
        // The arc segment's local param domain is 0...pi (sweep magnitude).
        // Click near the START (small param) removes [hit, pi] keeping [0, hit].
        let ec = EntityCurveBridge.curves(for: polyId, in: store)[0]
        guard case .arc = ec.curve else { return XCTFail("expected arc segment") }
        let outcome = TrimExtend.trim(targetId: polyId, clickParam: 0.3, clickSegment: 0, store: store,
                                      boundaries: [cutter], extendBoundaries: false, tol: tol)
        guard case .modifyInPlace(let payload)? = outcome?.action,
              case .polyline(_, let newVerts, let newBulges) = payload else { return XCTFail("expected in-place polyline modify") }
        XCTAssertEqual(newVerts.count, 2)
        // Surviving bulge must be nonzero (still an arc) and have the SAME
        // sign as the original (180deg CCW => positive bulge) but smaller
        // magnitude (partial sweep < pi).
        XCTAssertGreaterThan(newBulges[0], 0, "partial bulge must keep the original CCW sign")
        XCTAssertLessThan(newBulges[0], 1.0, "partial bulge magnitude must be less than the original full bulge")
    }

    // MARK: - EXTEND

    func testExtendLineToBoundary() {
        let store = makeStore()
        let target = addLine(store, Vec2(0, 0), Vec2(5, 0))
        let boundary = curveOf(addLine(store, Vec2(10, -5), Vec2(10, 5)), in: store)
        // Extend the far end (nearStart: false) to x=10.
        let outcome = TrimExtend.extend(targetId: target, nearStart: false, store: store,
                                        boundaries: [boundary], extendBoundaries: false, tol: tol)
        guard case .modifyInPlace(let payload)? = outcome?.action, case .line(let l) = payload else { return XCTFail("expected line modify") }
        XCTAssertEqual(l.a.x, 0, accuracy: 1e-9)
        XCTAssertEqual(l.b.x, 10, accuracy: 1e-9)
    }

    func testExtendLineNearestHitWins() {
        let store = makeStore()
        let target = addLine(store, Vec2(0, 0), Vec2(5, 0))
        let near = curveOf(addLine(store, Vec2(8, -5), Vec2(8, 5)), in: store)
        let far = curveOf(addLine(store, Vec2(20, -5), Vec2(20, 5)), in: store)
        let outcome = TrimExtend.extend(targetId: target, nearStart: false, store: store,
                                        boundaries: [near, far], extendBoundaries: false, tol: tol)
        guard case .modifyInPlace(let payload)? = outcome?.action, case .line(let l) = payload else { return XCTFail("expected line modify") }
        XCTAssertEqual(l.b.x, 8, accuracy: 1e-9, "nearest boundary must win, not the farther one")
    }

    func testExtendLineWithNoBoundaryAheadIsNoOp() {
        let store = makeStore()
        let target = addLine(store, Vec2(0, 0), Vec2(5, 0))
        // Boundary is BEHIND the extension direction (won't be hit extending forward).
        let behind = curveOf(addLine(store, Vec2(-10, -5), Vec2(-10, 5)), in: store)
        let outcome = TrimExtend.extend(targetId: target, nearStart: false, store: store,
                                        boundaries: [behind], extendBoundaries: false, tol: tol)
        guard case .noOp? = outcome?.action else { return XCTFail("expected noOp — boundary is behind the extension direction") }
    }

    func testExtendArcWidensSweep() {
        let store = makeStore()
        let arcId = addArc(store, center: .zero, r: 5, startDeg: 0, endDeg: 45)
        let boundary = curveOf(addLine(store, Vec2(-10, 5), Vec2(10, 5)), in: store)   // horizontal line at y=5, crosses circle of r=5 at angle 90
        let outcome = TrimExtend.extend(targetId: arcId, nearStart: false, store: store,
                                        boundaries: [boundary], extendBoundaries: false, tol: tol)
        guard case .modifyInPlace(let payload)? = outcome?.action, case .arc(let a) = payload else { return XCTFail("expected arc modify") }
        XCTAssertEqual(a.startAngleDeg, 0, accuracy: 1e-6)
        XCTAssertEqual(a.endAngleDeg, 90, accuracy: 1e-6)
    }

    /// Adversarial check (per the plan's explicit request): extends the
    /// START end of an arc that does NOT begin at 0 degrees, verifying BOTH
    /// the new start angle's EXACT value and that the END angle stays FIXED.
    /// A plausible-but-wrong formula — e.g. `newStart = a.startAngle - best`
    /// (missing the `sign` factor), or `newSweep = a.sweep + best` (wrong
    /// sign, which would SHRINK instead of grow the sweep) — would produce a
    /// numerically different, clearly wrong startAngleDeg/endAngleDeg here;
    /// the existing `testExtendArcWidensSweep` test only exercises the
    /// `nearStart: false` branch with `startDeg: 0`, which can't distinguish
    /// a start/end-branch mixup or a sign error in the OTHER branch.
    func testExtendArcStartEndWithNonZeroBaseAngleKeepsFarEndFixed() {
        let store = makeStore()
        // Arc from 30deg to 75deg (45deg sweep), center at origin, r=10.
        let arcId = addArc(store, center: .zero, r: 10, startDeg: 30, endDeg: 75)
        // Boundary: a ray from the origin at 10 degrees, extended as an
        // infinite line (extendBoundaries) so it crosses the circle at
        // BOTH 10deg and 190deg — the near one (10deg) is what a
        // correctly-implemented "extend the START backward" should find.
        let rayDir = Vec2(cos(10 * .pi / 180), sin(10 * .pi / 180))
        let boundary = curveOf(addLine(store, .zero, rayDir * 5), in: store)
        let outcome = TrimExtend.extend(targetId: arcId, nearStart: true, store: store,
                                        boundaries: [boundary], extendBoundaries: true, tol: tol)
        guard case .modifyInPlace(let payload)? = outcome?.action, case .arc(let a) = payload else {
            return XCTFail("expected arc modify")
        }
        // New start must be EXACTLY 10 degrees (where the boundary crosses),
        // and the end must be UNCHANGED at 75 degrees — a coefficient bug in
        // either newStart's or newSweep's formula would shift one or both of
        // these to a different, checkable wrong value (e.g. a missing sign
        // would put the new start at 50deg [30 + (30-10)] instead of 10deg,
        // or a doubled correction would put it at -10deg).
        XCTAssertEqual(a.startAngleDeg, 10, accuracy: 1e-6)
        XCTAssertEqual(a.endAngleDeg, 75, accuracy: 1e-6)
        // Independently verify via direct geometric evaluation: the
        // resulting arc's curve, evaluated at its OWN start parameter (u=0),
        // must land exactly on the boundary ray's direction from the
        // center — a cross-check that doesn't rely on trusting the same
        // angle-normalization code path the payload conversion uses.
        guard let newCircArc = EntityCurveBridge.circArc(fromDegreesStart: a.startAngleDeg, end: a.endAngleDeg, center: Vec2(a.center.x, a.center.y), r: a.radius) else {
            return XCTFail("expected valid re-bridged arc")
        }
        let startPoint = Curve2.arc(newCircArc).evaluate(0)
        XCTAssertEqual(startPoint.x, 10 * cos(10 * .pi / 180), accuracy: 1e-6)
        XCTAssertEqual(startPoint.y, 10 * sin(10 * .pi / 180), accuracy: 1e-6)
    }

    /// Extending a polyline whose FREE END segment is an ARC (bulge != 0) —
    /// exercises `extendPolyline`'s bulge-recompute path, which is untested
    /// by every other EXTEND case (all of which extend a bare LINE/ARC
    /// entity, not a polyline's arc-shaped end segment). Verifies both the
    /// new vertex position AND the new bulge sign/magnitude via independent
    /// geometric re-evaluation (`EntityCurveBridge.curves`), not just
    /// "some non-zero bulge came back."
    func testExtendPolylineWithArcEndSegmentRecomputesBulgeCorrectly() {
        let store = makeStore()
        // Single-segment open polyline: quarter-circle arc from (10,0) to
        // (0,10) around center (0,0), bulge = tan(sweep/4) for a 90deg CCW
        // sweep = tan(22.5deg) ≈ 0.4142.
        let bulge = tan(Double.pi / 2 / 4)
        let polyId = addPolyline(store, [Vec2(10, 0), Vec2(0, 10)], [bulge, 0], closed: false)
        // Extend the END (nearStart: false) to a boundary that widens the
        // sweep to a full 180deg (i.e. the far end should land at (-10,0)).
        let boundary = curveOf(addLine(store, Vec2(-20, 0), Vec2(20, 0)), in: store)
        let outcome = TrimExtend.extend(targetId: polyId, nearStart: false, store: store,
                                        boundaries: [boundary], extendBoundaries: false, tol: tol)
        guard case .modifyInPlace(let payload)? = outcome?.action,
              case .polyline(_, let verts, let bulges) = payload else {
            return XCTFail("expected in-place polyline modify with a recomputed arc bulge")
        }
        XCTAssertEqual(verts.count, 2)
        XCTAssertEqual(verts[0].x, 10, accuracy: 1e-6, "unaffected start vertex must be untouched")
        XCTAssertEqual(verts[0].y, 0, accuracy: 1e-6)
        XCTAssertEqual(verts[1].x, -10, accuracy: 1e-6, "extended end vertex must reach the boundary at (-10,0)")
        XCTAssertEqual(verts[1].y, 0, accuracy: 1e-6)
        // New sweep is 180deg CCW -> bulge = tan(pi/4) = 1.0 exactly.
        XCTAssertEqual(bulges[0], 1.0, accuracy: 1e-6)

        // Independent cross-check: re-bridge the committed polyline and
        // confirm ITS OWN geometric midpoint actually lies on the expected
        // circle (radius 10, center origin) — catches a bug where the
        // vertex position is right but the bulge encodes the WRONG arc
        // (e.g. correct endpoints but wrong sweep direction/magnitude,
        // which a pure endpoint check can't detect).
        let verifyStore = EntityStore()
        let verifyId = verifyStore.append(EntityPrototype(type: .lwpolyline, layerId: 0,
                                                           payload: .polyline(PolylinePayload(closed: false),
                                                                              vertices: verts.map { Vec3(x: $0.x, y: $0.y) }, bulges: bulges)))
        let rebridged = EntityCurveBridge.curves(for: verifyId, in: verifyStore)[0]
        guard case .arc(let a) = rebridged.curve else { return XCTFail("expected arc segment after re-bridging") }
        let mid = Curve2.arc(a).evaluate(a.sweep / 2)
        XCTAssertEqual(simd_length(mid), 10, accuracy: 1e-6, "midpoint of the recomputed arc must lie on the radius-10 circle")
        XCTAssertGreaterThan(mid.y, 0, "the 180deg CCW arc's midpoint must bulge into the UPPER half-plane (0,10), not dip below")
    }

    // MARK: - Spline EXTEND (tangent-ray)

    func testExtendSplineViaTangentRay() {
        let store = makeStore()
        // A roughly-horizontal spline through 4 points, tangent near the end pointing +X.
        let fitPoints = [Vec2(0, 0), Vec2(3, 1), Vec2(6, 0.5), Vec2(9, 0)]
        let n = SplineFit.interpolate(fitPoints: fitPoints, closed: false)
        let payload = EntityCurveBridge.splinePayload(for: n)
        let splineId = store.append(EntityPrototype(type: .spline, layerId: 0, payload: payload))
        // A vertical boundary line ahead of the spline's forward tangent direction.
        let boundary = curveOf(addLine(store, Vec2(15, -20), Vec2(15, 20)), in: store)
        let outcome = TrimExtend.extend(targetId: splineId, nearStart: false, store: store,
                                        boundaries: [boundary], extendBoundaries: false, tol: tol)
        guard case .modifyInPlace(let extPayload)? = outcome?.action, case .spline(_, let control, _, _) = extPayload else {
            return XCTFail("expected spline modify via tangent-ray extension")
        }
        XCTAssertGreaterThan(control.count, n.control.count, "extending a spline must add at least one control point")
        // The new curve's far end should now be at/near x=15 (the boundary).
        // Commit the extended payload into a fresh single-entity store (the
        // same "apply the outcome" step `TrimExtendToolState`/`Transaction`
        // performs) and re-bridge to confirm the geometry actually reaches
        // the boundary, not just that SOME control point was appended.
        let verifyStore = EntityStore()
        let verifyId = verifyStore.append(EntityPrototype(type: .spline, layerId: 0, payload: extPayload))
        let newSpline = EntityCurveBridge.curves(for: verifyId, in: verifyStore).first!
        if case .spline(let ns) = newSpline.curve {
            let endPt = Curve2.spline(ns).evaluate(ns.domain.upperBound)
            XCTAssertEqual(endPt.x, 15, accuracy: 1.0, "extended spline's far end should reach near the boundary")
        }
    }

    func testExtendClosedSplineIsNoOp() {
        let store = makeStore()
        let fitPoints = [Vec2(0, 0), Vec2(5, 5), Vec2(10, 0), Vec2(5, -5)]
        let n = SplineFit.interpolate(fitPoints: fitPoints, closed: true)
        let payload = EntityCurveBridge.splinePayload(for: n)
        let splineId = store.append(EntityPrototype(type: .spline, layerId: 0, payload: payload))
        let boundary = curveOf(addLine(store, Vec2(100, -100), Vec2(100, 100)), in: store)
        let outcome = TrimExtend.extend(targetId: splineId, nearStart: false, store: store,
                                        boundaries: [boundary], extendBoundaries: false, tol: tol)
        guard case .noOp? = outcome?.action else { return XCTFail("closed spline must never extend") }
    }

    // MARK: - Defensive / no-crash

    func testTrimNonCurveEntityReturnsNil() {
        let store = makeStore()
        let sid = store.strings.intern("x")
        let id = store.append(EntityPrototype(type: .text, layerId: 0, payload: .text(TextPayload(position: Vec3(x: 0, y: 0), height: 1, stringId: sid))))
        let outcome = TrimExtend.trim(targetId: id, clickParam: 0, store: store, boundaries: [], extendBoundaries: false, tol: tol)
        XCTAssertNil(outcome)
    }

    func testTrimWithEmptyBoundariesIsNoOp() {
        let store = makeStore()
        let target = addLine(store, .zero, Vec2(10, 0))
        let outcome = TrimExtend.trim(targetId: target, clickParam: 0.5, store: store, boundaries: [], extendBoundaries: false, tol: tol)
        guard case .noOp? = outcome?.action else { return XCTFail("expected noOp with zero boundaries") }
    }
}
