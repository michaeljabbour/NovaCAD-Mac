import XCTest
@testable import DWGViewer
import CADCore

final class ExplodeTests: XCTestCase {

    private func makeParsed() -> EditableParsedDocument {
        let parsed = EditableParsedDocument()
        parsed.layers.append(DXFLayer(id: 0, name: "0"))
        parsed.layerIdByName["0"] = 0
        parsed.layers.append(DXFLayer(id: 1, name: "SYMBOLS"))
        parsed.layerIdByName["SYMBOLS"] = 1
        parsed.linetypes.append(DXFLinetype(name: "CONTINUOUS", dashes: []))
        parsed.linetypeIdByName["CONTINUOUS"] = 0
        return parsed
    }

    // MARK: - 2x2 SVD correctness (hand-computed examples, cross-checked against NumPy)

    func testSVDOfDiagonalScaleMatrix() {
        // M = diag(2,1) — already its own SVD: sigma1=2 (X axis), sigma2=1.
        let r = EntityExploder.svd2x2(m11: 2, m21: 0, m12: 0, m22: 1)
        XCTAssertEqual(r.sigma1, 2, accuracy: 1e-9)
        XCTAssertEqual(r.sigma2, 1, accuracy: 1e-9)
        XCTAssertEqual(r.u1.x, 1, accuracy: 1e-9)
        XCTAssertEqual(r.u1.y, 0, accuracy: 1e-9)
    }

    /// Hand-computed example (independently verified via NumPy's
    /// `numpy.linalg.svd` during development — see this test's numeric
    /// comments): M = rotate(40 deg) * diag(3, 1.5). Expected SVD:
    /// sigma1=3, sigma2=1.5, U's first column at angle 40 deg (phi=40),
    /// V's rotation angle (theta) = 0 (no shear introduced by composing a
    /// pure rotation with a diagonal scale).
    func testSVDMatchesHandComputedRotateThenScaleExample() {
        let rot = 40.0 * .pi / 180
        let m11 = cos(rot) * 3, m21 = sin(rot) * 3
        let m12 = -sin(rot) * 1.5, m22 = cos(rot) * 1.5
        let r = EntityExploder.svd2x2(m11: m11, m21: m21, m12: m12, m22: m22)
        XCTAssertEqual(r.sigma1, 3, accuracy: 1e-9)
        XCTAssertEqual(r.sigma2, 1.5, accuracy: 1e-9)
        XCTAssertEqual(r.vAngle, 0, accuracy: 1e-9)
        let phi = atan2(r.u1.y, r.u1.x)
        XCTAssertEqual(phi * 180 / .pi, 40, accuracy: 1e-6)
    }

    /// Reconstruction check: M must equal U * diag(sigma1,sigma2) * V^T for
    /// any POSITIVE-determinant 2x2 matrix (not just the two hand-picked
    /// examples above) — a general correctness property, not tied to one
    /// example's numbers. Restricted to positive-determinant inputs because
    /// `svd2x2` deliberately returns an UNSIGNED `sigma2` with both `U`
    /// (via `u1`/`u2`) and `V` (via `vAngle`) constructed as PURE rotations
    /// (see `svd2x2`'s own doc comment for why) — a decomposition shape
    /// that cannot represent a negative-determinant matrix exactly via this
    /// particular U*Sigma*V^T reconstruction (det(U)*det(V) is always +1
    /// for two pure rotations, so it can never equal a negative det(M)).
    /// This is NOT a correctness gap for EXPLODE's actual use: the
    /// negative-determinant (mirror) case is verified by
    /// `testSVDMapsUnitCircleOntoCorrectEllipseIncludingMirrorCase` below,
    /// which checks the property `svd2x2` actually needs to guarantee
    /// (every point of the unit circle maps into the ellipse traced by
    /// sigma1/sigma2/u1/u2) rather than one specific U*Sigma*V^T
    /// factorization's exact numeric form.
    func testSVDReconstructsOriginalMatrixForPositiveDeterminant() {
        let cases: [(Double, Double, Double, Double)] = [
            (2, 0, 0, 1), (1, 0, 0, 1), (3, 1, -1, 2), (0.5, 0.2, 0.3, 0.7)
        ]
        for (m11, m21, m12, m22) in cases {
            XCTAssertGreaterThan(m11 * m22 - m12 * m21, 0, "test case must be positive-determinant")
            let svd = EntityExploder.svd2x2(m11: m11, m21: m21, m12: m12, m22: m22)
            // Reconstruct: M = [u1 u2] * diag(sigma1,sigma2) * [v1 v2]^T,
            // where v1=(cos theta, sin theta), v2=(-sin theta, cos theta).
            let v1x = cos(svd.vAngle), v1y = sin(svd.vAngle)
            let v2x = -sin(svd.vAngle), v2y = cos(svd.vAngle)
            // M*e1 = U*Sigma*V^T*e1 = U*Sigma*(v1x, v2x) = U*(sigma1*v1x, sigma2*v2x)
            //      = v1x*sigma1*u1 + v2x*sigma2*u2
            let col1 = svd.u1 * (svd.sigma1 * v1x) + svd.u2 * (svd.sigma2 * v2x)
            let col2 = svd.u1 * (svd.sigma1 * v1y) + svd.u2 * (svd.sigma2 * v2y)
            XCTAssertEqual(col1.x, m11, accuracy: 1e-7, "m11 mismatch for (\(m11),\(m21),\(m12),\(m22))")
            XCTAssertEqual(col1.y, m21, accuracy: 1e-7, "m21 mismatch for (\(m11),\(m21),\(m12),\(m22))")
            XCTAssertEqual(col2.x, m12, accuracy: 1e-7, "m12 mismatch for (\(m11),\(m21),\(m12),\(m22))")
            XCTAssertEqual(col2.y, m22, accuracy: 1e-7, "m22 mismatch for (\(m11),\(m21),\(m12),\(m22))")
        }
    }

    /// The property `svd2x2` actually needs to guarantee for EXPLODE:
    /// transforming every point of the unit circle by `M` must land exactly
    /// on the ellipse `sigma1*cos(t)*u1 + sigma2*sin(t)*u2` for SOME `t` —
    /// i.e. the transformed circle traces out precisely this ellipse shape,
    /// regardless of `M`'s determinant sign. Checked for both a positive-
    /// and a negative-determinant (mirror) matrix.
    func testSVDMapsUnitCircleOntoCorrectEllipseIncludingMirrorCase() {
        let cases: [(Double, Double, Double, Double)] = [
            (3, 1, -1, 2),      // positive determinant, asymmetric
            (-2, 1, 0.5, 3),    // negative determinant (mirror)
        ]
        for (m11, m21, m12, m22) in cases {
            let svd = EntityExploder.svd2x2(m11: m11, m21: m21, m12: m12, m22: m22)
            var maxErr = 0.0
            for k in 0..<360 {
                let t = Double(k) * .pi / 180
                let px = m11 * cos(t) + m12 * sin(t)
                let py = m21 * cos(t) + m22 * sin(t)
                // Project onto the u1/u2 axes and check the ellipse equation.
                let x = px * svd.u1.x + py * svd.u1.y
                let y = px * svd.u2.x + py * svd.u2.y
                let eq = (x / svd.sigma1) * (x / svd.sigma1) + (y / svd.sigma2) * (y / svd.sigma2)
                maxErr = max(maxErr, abs(eq - 1))
            }
            XCTAssertLessThan(maxErr, 1e-6, "unit circle under (\(m11),\(m21),\(m12),\(m22)) must trace the SVD-derived ellipse exactly")
        }
    }

    func testSVDSingularValuesAreOrderedAndNonNegative() {
        let r = EntityExploder.svd2x2(m11: 0.5, m21: 0.2, m12: 0.3, m22: 0.7)
        XCTAssertGreaterThanOrEqual(r.sigma1, r.sigma2)
        XCTAssertGreaterThanOrEqual(r.sigma2, 0)
    }

    // MARK: - INSERT explode, uniform scale — cross-check against Regenerator's own flattened geometry

    /// The plan's own explicit gate: "explode-uniform-insert output equals
    /// GeometryBuilder's/Regenerator's own flattened rendering geometry."
    /// Builds a block with a LINE+CIRCLE, inserts it with a UNIFORM
    /// scale+rotation, explodes the insert, then independently computes
    /// what `Regenerator.build` renders for the SAME (unexploded) insert in
    /// a separate parallel document — the two must produce geometrically
    /// identical results.
    func testExplodeUniformInsertMatchesRegeneratorFlattenedGeometry() throws {
        let parsed = makeParsed()
        let doc = parsed.document
        var lineId: EntityID!, circleId: EntityID!
        doc.transact("Draw") { tx in
            lineId = tx.add(EntityPrototype(type: .line, layerId: 0,
                payload: .line(LinePayload(a: Vec3(x: 0, y: 0), b: Vec3(x: 10, y: 0)))))
            circleId = tx.add(EntityPrototype(type: .circle, layerId: 0,
                payload: .circle(CirclePayload(center: Vec3(x: 5, y: 5), radius: 3))))
        }
        var blockResult: BlockEditor.CreateBlockResult?
        doc.transact("Block") { tx in
            blockResult = BlockEditor.createBlock(name: "SYM", basePoint: .zero, from: [lineId, circleId],
                                                  insertLayerId: 0, in: parsed, tx: tx)
        }
        let insertId = try XCTUnwrap(blockResult?.insertId)

        // Reposition/rotate/scale the insert (uniform: scale.x == scale.y).
        doc.transact("Adjust insert") { tx in
            tx.modifyPayload(insertId) { copy in
                guard case .insert(var p) = copy else { return }
                p.position = Vec3(x: 200, y: 300)
                p.rotationDeg = 30
                p.scale = Vec3(x: 2, y: 2, z: 1)
                copy = .insert(p)
            }
        }

        // Cross-check reference: Regenerator's own flattened output for
        // this exact insert (built from `parsed` BEFORE exploding).
        let referenceDoc = Regenerator.build(from: parsed, parseSeconds: 0) { _ in }
        var referenceLineEndpoints: (CGPoint, CGPoint)?
        var referenceCircle: (center: CGPoint, radius: Double)?
        for g in referenceDoc.modelGroups {
            for run in g.strokes.runs where run.kind == .line {
                referenceLineEndpoints = (g.strokes.points[Int(run.start)], g.strokes.points[Int(run.start) + 1])
            }
            for arc in g.strokes.arcs where arc.isFullCircle {
                referenceCircle = (arc.center, Double(arc.radius))
            }
        }
        let (refA, refB) = try XCTUnwrap(referenceLineEndpoints)
        let (refCenter, refRadius) = try XCTUnwrap(referenceCircle)

        // Now explode and inspect the resulting LINE/CIRCLE payloads directly.
        var result: EntityExploder.Result!
        doc.transact("Explode") { tx in
            result = EntityExploder.explode(ids: [insertId], store: doc.store, parsed: parsed, tx: tx)
        }
        XCTAssertEqual(result.explodedCount, 1)
        XCTAssertTrue(doc.store.isDeleted(insertId))

        var explodedLine: (Vec3, Vec3)?
        var explodedCircle: (center: Vec3, radius: Double)?
        for id in result.newIDs {
            guard let h = doc.store.header(id) else { continue }
            if h.type == .line { let l = doc.store.lines[Int(h.payload)]; explodedLine = (l.a, l.b) }
            if h.type == .circle { let c = doc.store.circles[Int(h.payload)]; explodedCircle = (c.center, c.radius) }
        }
        let (expA, expB) = try XCTUnwrap(explodedLine)
        let (expCenter, expRadius) = try XCTUnwrap(explodedCircle)

        // Line endpoints must match (either orientation).
        let matchesForward = hypot(Double(refA.x) - expA.x, Double(refA.y) - expA.y) < 1e-6 &&
                             hypot(Double(refB.x) - expB.x, Double(refB.y) - expB.y) < 1e-6
        let matchesReverse = hypot(Double(refA.x) - expB.x, Double(refA.y) - expB.y) < 1e-6 &&
                             hypot(Double(refB.x) - expA.x, Double(refB.y) - expA.y) < 1e-6
        XCTAssertTrue(matchesForward || matchesReverse,
                     "exploded line (\(expA),\(expB)) must match Regenerator's flattened line (\(refA),\(refB))")

        XCTAssertEqual(expCenter.x, Double(refCenter.x), accuracy: 1e-6)
        XCTAssertEqual(expCenter.y, Double(refCenter.y), accuracy: 1e-6)
        XCTAssertEqual(expRadius, refRadius, accuracy: 1e-6)
    }

    func testExplodeUndoRestoresOriginalInsert() throws {
        let parsed = makeParsed()
        let doc = parsed.document
        var lineId: EntityID!
        doc.transact("Draw") { tx in
            lineId = tx.add(EntityPrototype(type: .line, layerId: 0,
                payload: .line(LinePayload(a: Vec3(x: 0, y: 0), b: Vec3(x: 1, y: 1)))))
        }
        var blockResult: BlockEditor.CreateBlockResult?
        doc.transact("Block") { tx in
            blockResult = BlockEditor.createBlock(name: "S", basePoint: .zero, from: [lineId],
                                                  insertLayerId: 0, in: parsed, tx: tx)
        }
        let insertId = try XCTUnwrap(blockResult?.insertId)

        doc.transact("Explode") { tx in
            _ = EntityExploder.explode(ids: [insertId], store: doc.store, parsed: parsed, tx: tx)
        }
        XCTAssertTrue(doc.store.isDeleted(insertId))

        doc.undo()
        XCTAssertFalse(doc.store.isDeleted(insertId), "undo must restore the exploded INSERT")
    }

    // MARK: - Non-uniform scale: circle/arc -> ellipse via SVD

    func testExplodeNonUniformInsertConvertsCircleToEllipse() throws {
        let parsed = makeParsed()
        let doc = parsed.document
        var circleId: EntityID!
        doc.transact("Draw") { tx in
            circleId = tx.add(EntityPrototype(type: .circle, layerId: 0,
                payload: .circle(CirclePayload(center: Vec3(x: 0, y: 0), radius: 5))))
        }
        var blockResult: BlockEditor.CreateBlockResult?
        doc.transact("Block") { tx in
            blockResult = BlockEditor.createBlock(name: "C", basePoint: .zero, from: [circleId],
                                                  insertLayerId: 0, in: parsed, tx: tx)
        }
        let insertId = try XCTUnwrap(blockResult?.insertId)
        doc.transact("Non-uniform scale") { tx in
            tx.modifyPayload(insertId) { copy in
                guard case .insert(var p) = copy else { return }
                p.scale = Vec3(x: 2, y: 1, z: 1)   // non-uniform: X doubled, Y unchanged
                copy = .insert(p)
            }
        }

        var result: EntityExploder.Result!
        doc.transact("Explode") { tx in
            result = EntityExploder.explode(ids: [insertId], store: doc.store, parsed: parsed, tx: tx)
        }
        XCTAssertEqual(result.explodedCount, 1)
        guard let newId = result.newIDs.first, let h = doc.store.header(newId) else {
            return XCTFail("expected exactly one exploded entity")
        }
        XCTAssertEqual(h.type, .ellipse, "a circle under non-uniform scale must explode to an ELLIPSE, not stay a CIRCLE")
        let e = doc.store.ellipses[Int(h.payload)]
        // Original radius 5, scale x=2,y=1 -> major axis length 10 along X, ratio 0.5.
        let majorLen = hypot(e.majorAxisEndpoint.x, e.majorAxisEndpoint.y)
        XCTAssertEqual(majorLen, 10, accuracy: 1e-6)
        XCTAssertEqual(e.ratio, 0.5, accuracy: 1e-6)
        XCTAssertEqual(e.center.x, 0, accuracy: 1e-6)
        XCTAssertEqual(e.center.y, 0, accuracy: 1e-6)
    }

    func testExplodeNonUniformInsertConvertsArcToEllipseArc() throws {
        let parsed = makeParsed()
        let doc = parsed.document
        var arcId: EntityID!
        doc.transact("Draw") { tx in
            arcId = tx.add(EntityPrototype(type: .arc, layerId: 0,
                payload: .arc(ArcPayload(center: Vec3(x: 0, y: 0), radius: 4, startAngleDeg: 0, endAngleDeg: 90))))
        }
        var blockResult: BlockEditor.CreateBlockResult?
        doc.transact("Block") { tx in
            blockResult = BlockEditor.createBlock(name: "A", basePoint: .zero, from: [arcId],
                                                  insertLayerId: 0, in: parsed, tx: tx)
        }
        let insertId = try XCTUnwrap(blockResult?.insertId)
        doc.transact("Non-uniform scale") { tx in
            tx.modifyPayload(insertId) { copy in
                guard case .insert(var p) = copy else { return }
                p.scale = Vec3(x: 1, y: 3, z: 1)
                copy = .insert(p)
            }
        }
        var result: EntityExploder.Result!
        doc.transact("Explode") { tx in
            result = EntityExploder.explode(ids: [insertId], store: doc.store, parsed: parsed, tx: tx)
        }
        guard let newId = result.newIDs.first, let h = doc.store.header(newId) else {
            return XCTFail("expected exactly one exploded entity")
        }
        XCTAssertEqual(h.type, .ellipse, "an arc under non-uniform scale must explode to an ELLIPSE-ARC")
        let e = doc.store.ellipses[Int(h.payload)]
        XCTAssertNotEqual(e.startParam, 0, accuracy: 1e-9)
        // start=0deg end=90deg over a full sweep window: endParam - startParam should be pi/2 (unchanged sweep, since
        // the transform's V-rotation for this axis-aligned scale is 0).
        XCTAssertEqual(e.endParam - e.startParam, .pi / 2, accuracy: 1e-6)
    }

    /// End-to-end check that a rotated + non-uniformly-scaled INSERT's arc
    /// child explodes to an ellipse-arc whose ENDPOINTS (evaluated via the
    /// DXF parametric formula) land exactly where the original arc's
    /// endpoints directly transform to. NOTE: an INSERT's own position/
    /// rotation/scale composition (translate*rotate*scale, with scale
    /// diagonal) can NEVER introduce genuine shear on its own — a circle/
    /// arc's local geometry is rotationally symmetric, so composing it with
    /// ANY rotate-then-diagonal-scale transform always keeps `svd2x2`'s
    /// `vAngle` at exactly 0 regardless of the (a1-a2)/2 vs (a2-a1)/2 sign
    /// choice (verified: this specific test's transform has a1==a2==25°
    /// numerically). This test is still valuable as an end-to-end sanity
    /// check of the whole rotate+non-uniform-scale pipeline, but it is NOT
    /// the test that would have caught the vAngle sign bug —
    /// `testExplodeEllipseUnderNonUniformScaleMatchesDirectTransform` below
    /// is: exploding an EXISTING ellipse (whose own major/minor axis matrix
    /// is generally NOT axis-aligned with the insert's transform) under a
    /// non-uniform scale DOES produce genuine shear when composed, which is
    /// exactly where the sign bug was caught (see `svd2x2`'s own doc
    /// comment for the full derivation history).
    func testExplodeArcToEllipseArcEndpointsMatchDirectTransformUnderRotatedNonUniformInsert() throws {
        let parsed = makeParsed()
        let doc = parsed.document
        // A quarter-circle arc from 30 to 120 degrees (chord not aligned to
        // either local axis) at local origin, radius 4.
        var arcId: EntityID!
        doc.transact("Draw") { tx in
            arcId = tx.add(EntityPrototype(type: .arc, layerId: 0,
                payload: .arc(ArcPayload(center: Vec3(x: 0, y: 0), radius: 4, startAngleDeg: 30, endAngleDeg: 120))))
        }
        var blockResult: BlockEditor.CreateBlockResult?
        doc.transact("Block") { tx in
            blockResult = BlockEditor.createBlock(name: "RA", basePoint: .zero, from: [arcId],
                                                  insertLayerId: 0, in: parsed, tx: tx)
        }
        let insertId = try XCTUnwrap(blockResult?.insertId)
        // Rotated 25 degrees AND non-uniformly scaled (x=2, y=1) — the
        // composition that produces a non-zero vAngle.
        doc.transact("Rotate + non-uniform scale") { tx in
            tx.modifyPayload(insertId) { copy in
                guard case .insert(var p) = copy else { return }
                p.rotationDeg = 25
                p.scale = Vec3(x: 2, y: 1, z: 1)
                copy = .insert(p)
            }
        }

        // Direct transform of the ORIGINAL arc's endpoints (ground truth,
        // computed independently of EntityExploder's own math): rotate then
        // scale (matching CGAffineTransform's translatedBy/rotated/scaledBy
        // composition order used throughout this codebase for INSERT).
        func directTransform(_ deg: Double) -> (x: Double, y: Double) {
            let rad = deg * .pi / 180
            let localX = 4 * cos(rad), localY = 4 * sin(rad)
            let rot = 25.0 * .pi / 180
            // CGAffineTransform: translatedBy(pos).rotated(rot).scaledBy(2,1)
            // applied to a LOCAL point means: scale first, then rotate,
            // then translate (pos is (0,0) here, so translate is a no-op).
            let sx = localX * 2, sy = localY * 1
            let rx = sx * cos(rot) - sy * sin(rot)
            let ry = sx * sin(rot) + sy * cos(rot)
            return (rx, ry)
        }
        let expectedStart = directTransform(30)
        let expectedEnd = directTransform(120)

        var result: EntityExploder.Result!
        doc.transact("Explode") { tx in
            result = EntityExploder.explode(ids: [insertId], store: doc.store, parsed: parsed, tx: tx)
        }
        let newId = try XCTUnwrap(result.newIDs.first)
        let h = try XCTUnwrap(doc.store.header(newId))
        XCTAssertEqual(h.type, .ellipse)
        let e = doc.store.ellipses[Int(h.payload)]

        // Evaluate the ellipse at its OWN startParam/endParam via the DXF
        // parametric formula: point(t) = center + majorAxis*cos(t) + minorAxis*sin(t).
        func ellipsePoint(_ t: Double) -> (x: Double, y: Double) {
            let majorX = e.majorAxisEndpoint.x, majorY = e.majorAxisEndpoint.y
            let minorX = -majorY * e.ratio, minorY = majorX * e.ratio
            return (e.center.x + majorX * cos(t) + minorX * sin(t),
                    e.center.y + majorY * cos(t) + minorY * sin(t))
        }
        let actualStart = ellipsePoint(e.startParam)
        let actualEnd = ellipsePoint(e.endParam)

        XCTAssertEqual(actualStart.x, expectedStart.x, accuracy: 1e-6, "ellipse-arc START must match the arc's directly-transformed start endpoint")
        XCTAssertEqual(actualStart.y, expectedStart.y, accuracy: 1e-6)
        XCTAssertEqual(actualEnd.x, expectedEnd.x, accuracy: 1e-6, "ellipse-arc END must match the arc's directly-transformed end endpoint")
        XCTAssertEqual(actualEnd.y, expectedEnd.y, accuracy: 1e-6)
    }

    /// THE regression test for the `vAngle` sign bug (see `svd2x2`'s doc
    /// comment for the full derivation history): an ellipse whose major
    /// axis is NOT axis-aligned (35 degrees), exploded through an INSERT
    /// with a NON-UNIFORM scale — composing the ellipse's own (non-axis-
    /// aligned) axis matrix with the insert's non-uniform scale DOES
    /// introduce genuine shear (unlike any circle/arc composition, which
    /// stays shear-free — see the note on the test above), so this is the
    /// scenario that actually exercises the wrong-vs-right sign difference.
    /// Verified end-to-end: samples several points along the ORIGINAL
    /// ellipse's parametric curve, transforms each directly (ground truth,
    /// independent of EntityExploder's own math), and checks each one lies
    /// exactly on the EXPLODED ellipse (evaluated at ITS OWN, possibly
    /// different, parameter — so this checks the exploded ellipse traces
    /// the same curve, not that parameters correspond 1:1, which they need
    /// not for a full ellipse).
    func testExplodeEllipseUnderNonUniformScaleMatchesDirectTransform() throws {
        let parsed = makeParsed()
        let doc = parsed.document
        let majorAngle = 35.0 * .pi / 180
        let majorLen = 6.0, ratio = 0.4
        let major0 = Vec3(x: majorLen * cos(majorAngle), y: majorLen * sin(majorAngle))
        var ellipseId: EntityID!
        doc.transact("Draw") { tx in
            ellipseId = tx.add(EntityPrototype(type: .ellipse, layerId: 0,
                payload: .ellipse(EllipsePayload(center: Vec3(x: 0, y: 0), majorAxisEndpoint: major0,
                                                 ratio: ratio, startParam: 0, endParam: 2 * .pi))))
        }
        var blockResult: BlockEditor.CreateBlockResult?
        doc.transact("Block") { tx in
            blockResult = BlockEditor.createBlock(name: "EL", basePoint: .zero, from: [ellipseId],
                                                  insertLayerId: 0, in: parsed, tx: tx)
        }
        let insertId = try XCTUnwrap(blockResult?.insertId)
        doc.transact("Non-uniform scale") { tx in
            tx.modifyPayload(insertId) { copy in
                guard case .insert(var p) = copy else { return }
                p.scale = Vec3(x: 2, y: 1, z: 1)   // no rotation — the ellipse's OWN axes provide the asymmetry
                copy = .insert(p)
            }
        }

        // Ground truth: directly transform points on the ORIGINAL ellipse.
        func originalEllipsePoint(_ t: Double) -> (x: Double, y: Double) {
            let minorX = -major0.y * ratio, minorY = major0.x * ratio
            let x = major0.x * cos(t) + minorX * sin(t)
            let y = major0.y * cos(t) + minorY * sin(t)
            return (x * 2, y * 1)   // apply the insert's non-uniform scale directly
        }

        var result: EntityExploder.Result!
        doc.transact("Explode") { tx in
            result = EntityExploder.explode(ids: [insertId], store: doc.store, parsed: parsed, tx: tx)
        }
        let newId = try XCTUnwrap(result.newIDs.first)
        let h = try XCTUnwrap(doc.store.header(newId))
        XCTAssertEqual(h.type, .ellipse)
        let e = doc.store.ellipses[Int(h.payload)]
        func explodedEllipsePoint(_ t: Double) -> (x: Double, y: Double) {
            let majorX = e.majorAxisEndpoint.x, majorY = e.majorAxisEndpoint.y
            let minorX = -majorY * e.ratio, minorY = majorX * e.ratio
            return (e.center.x + majorX * cos(t) + minorX * sin(t),
                    e.center.y + majorY * cos(t) + minorY * sin(t))
        }

        // For each ground-truth point, find the closest point on the
        // exploded ellipse and require it to coincide — proves the
        // exploded ellipse traces the SAME curve as the direct transform,
        // which is what "the ellipse conversion is correct" actually means
        // (parameter correspondence isn't required to match 1:1, only the
        // traced shape). A coarse-then-refine search (coarse pass to find
        // the neighborhood, then ternary-search refinement around it) is
        // used rather than one huge fixed sample count, since a purely
        // fixed-resolution search's discretization error (arc length per
        // sample) scales with the ellipse's own size — a naive 720-sample
        // pass over a semi-major-axis-10 ellipse has ~0.09 unit resolution,
        // which nearly masked a real bug during development by looking
        // like "close enough" noise; refining down to a true local minimum
        // avoids that ambiguity entirely.
        func closestDistance(to truth: (x: Double, y: Double)) -> Double {
            var bestT = 0.0, bestD = Double.greatestFiniteMagnitude
            for j in 0..<360 {
                let tj = Double(j) * .pi / 180
                let p = explodedEllipsePoint(tj)
                let d = hypot(p.x - truth.x, p.y - truth.y)
                if d < bestD { bestD = d; bestT = tj }
            }
            // Ternary-search refinement in a window around the coarse best.
            var lo = bestT - (.pi / 180), hi = bestT + (.pi / 180)
            for _ in 0..<60 {
                let m1 = lo + (hi - lo) / 3, m2 = hi - (hi - lo) / 3
                let p1 = explodedEllipsePoint(m1), p2 = explodedEllipsePoint(m2)
                let d1 = hypot(p1.x - truth.x, p1.y - truth.y)
                let d2 = hypot(p2.x - truth.x, p2.y - truth.y)
                if d1 < d2 { hi = m2 } else { lo = m1 }
            }
            let pFinal = explodedEllipsePoint((lo + hi) / 2)
            return hypot(pFinal.x - truth.x, pFinal.y - truth.y)
        }

        for k in stride(from: 0, to: 360, by: 30) {
            let t = Double(k) * .pi / 180
            let truth = originalEllipsePoint(t)
            let minDist = closestDistance(to: truth)
            XCTAssertLessThan(minDist, 1e-6, "ground-truth point at t=\(k)deg (\(truth)) must lie on the exploded ellipse's traced curve")
        }
    }

    // MARK: - LWPOLYLINE bulge preservation

    func testExplodePolylinePreservesStraightAndBulgedSegments() throws {
        let parsed = makeParsed()
        let doc = parsed.document
        var polyId: EntityID!
        doc.transact("Draw") { tx in
            // Square-ish polyline: straight segment (0,0)->(10,0), then a
            // bulged segment (10,0)->(10,10) with bulge 1 (semicircle).
            polyId = tx.add(EntityPrototype(type: .lwpolyline, layerId: 0,
                payload: .polyline(PolylinePayload(closed: false),
                                   vertices: [Vec3(x: 0, y: 0), Vec3(x: 10, y: 0), Vec3(x: 10, y: 10)],
                                   bulges: [0, 1, 0])))
        }
        var result: EntityExploder.Result!
        doc.transact("Explode") { tx in
            result = EntityExploder.explode(ids: [polyId], store: doc.store, parsed: parsed, tx: tx)
        }
        XCTAssertEqual(result.explodedCount, 1)
        XCTAssertEqual(result.newIDs.count, 2, "2 segments (1 straight, 1 bulged) must produce 2 entities")
        var sawLine = false, sawArc = false
        for id in result.newIDs {
            guard let h = doc.store.header(id) else { continue }
            if h.type == .line { sawLine = true }
            if h.type == .arc { sawArc = true }
        }
        XCTAssertTrue(sawLine, "the straight segment must become a LINE")
        XCTAssertTrue(sawArc, "the bulged segment must become an ARC")
    }

    func testExplodeClosedPolylineProducesMatchingSegmentCount() throws {
        let parsed = makeParsed()
        let doc = parsed.document
        var polyId: EntityID!
        doc.transact("Draw") { tx in
            polyId = tx.add(EntityPrototype(type: .lwpolyline, layerId: 0,
                payload: .polyline(PolylinePayload(closed: true),
                                   vertices: [Vec3(x: 0, y: 0), Vec3(x: 10, y: 0), Vec3(x: 10, y: 10), Vec3(x: 0, y: 10)],
                                   bulges: [0, 0, 0, 0])))
        }
        var result: EntityExploder.Result!
        doc.transact("Explode") { tx in
            result = EntityExploder.explode(ids: [polyId], store: doc.store, parsed: parsed, tx: tx)
        }
        XCTAssertEqual(result.newIDs.count, 4, "a closed 4-vertex polyline has 4 segments (including the closing one)")
    }

    // MARK: - MINSERT -> rows*cols individual INSERTs

    func testExplodeMinsertProducesRowsTimesColsInsertsAtGridPositions() throws {
        let parsed = makeParsed()
        let doc = parsed.document
        var lineId: EntityID!
        doc.transact("Draw") { tx in
            lineId = tx.add(EntityPrototype(type: .line, layerId: 0,
                payload: .line(LinePayload(a: Vec3(x: 0, y: 0), b: Vec3(x: 1, y: 0)))))
        }
        var blockResult: BlockEditor.CreateBlockResult?
        doc.transact("Block") { tx in
            blockResult = BlockEditor.createBlock(name: "M", basePoint: .zero, from: [lineId],
                                                  insertLayerId: 0, in: parsed, tx: tx)
        }
        let insertId = try XCTUnwrap(blockResult?.insertId)
        doc.transact("Minsert-ify") { tx in
            tx.modifyPayload(insertId) { copy in
                guard case .insert(var p) = copy else { return }
                p.position = Vec3(x: 0, y: 0)
                p.cols = 3; p.rows = 2
                p.colSpacing = 100; p.rowSpacing = 50
                copy = .insert(p)
            }
        }
        var result: EntityExploder.Result!
        doc.transact("Explode") { tx in
            result = EntityExploder.explode(ids: [insertId], store: doc.store, parsed: parsed, tx: tx)
        }
        // 3 cols x 2 rows = 6 grid cells, one LINE each (since the block has
        // exactly one entity and no MINSERT-of-MINSERT complexity here).
        XCTAssertEqual(result.newIDs.count, 6)
        var lineXPositions = Set<Double>()
        var lineYPositions = Set<Double>()
        for id in result.newIDs {
            guard let h = doc.store.header(id), h.type == .line else { continue }
            let l = doc.store.lines[Int(h.payload)]
            lineXPositions.insert((l.a.x / 10).rounded() * 10)   // bucket to avoid fp noise
            lineYPositions.insert((l.a.y / 10).rounded() * 10)
        }
        XCTAssertEqual(lineXPositions, [0, 100, 200])
        XCTAssertEqual(lineYPositions, [0, 50])
    }

    // MARK: - ATTRIB -> TEXT

    func testExplodeInsertConvertsAttribToText() throws {
        let parsed = makeParsed()
        let doc = parsed.document
        let block = EditableBlockDef()
        block.name = "T"
        block.blockIndex = BlockEditor.nextBlockIndex(in: parsed)
        parsed.blocks["T"] = block
        doc.transact("Attdef") { tx in
            _ = BlockEditor.createAttdef(tag: "NAME", prompt: "", defaultValue: "default",
                                        at: .zero, height: 2, layerId: 0, inBlockNamed: "T", in: parsed, tx: tx)
        }
        var insertId: EntityID?
        doc.transact("Insert") { tx in
            insertId = BlockEditor.insert(blockName: "T", at: CGPoint(x: 50, y: 50),
                                          layerId: 0, attributeValues: ["NAME": "Hello"], in: parsed, tx: tx)
        }
        let iid = try XCTUnwrap(insertId)

        // Capture the ORIGINAL ATTRIB's id BEFORE exploding, so we can
        // verify it's actually deleted afterward (adversarial-review
        // regression: a prior version added the replacement TEXT but never
        // deleted the source ATTRIB, leaking it as a permanently live,
        // orphaned entity).
        let attribsBefore = BlockEditor.attributes(of: iid, in: doc.store)
        XCTAssertEqual(attribsBefore.count, 1)
        let originalAttribId = attribsBefore[0].id

        var result: EntityExploder.Result!
        doc.transact("Explode") { tx in
            result = EntityExploder.explode(ids: [iid], store: doc.store, parsed: parsed, tx: tx)
        }
        var foundTextWithValue = false
        for id in result.newIDs {
            guard let h = doc.store.header(id), h.type == .text, h.payload >= 0 else { continue }
            let t = doc.store.texts[Int(h.payload)]
            if doc.store.strings.string(for: t.stringId) == "Hello" { foundTextWithValue = true }
        }
        XCTAssertTrue(foundTextWithValue, "the ATTRIB's current VALUE must survive as plain TEXT after explode")
        // No ATTRIB entities should remain live among the NEW entities (they were consumed into TEXT).
        for id in result.newIDs {
            if let h = doc.store.header(id) { XCTAssertNotEqual(h.type, .attrib) }
        }
        // The ORIGINAL ATTRIB entity itself must be deleted, not merely
        // superseded — a leaked live ATTRIB still owned via
        // .parentEntity(iid) after iid itself is deleted would be a
        // dangling/orphaned entity.
        XCTAssertTrue(doc.store.isDeleted(originalAttribId), "the original ATTRIB entity must be deleted after explode, not leaked as an orphan")
    }

    // MARK: - Nested inserts stay inserts unless `nested: true`

    func testExplodeNestedInsertStaysInsertByDefault() throws {
        let parsed = makeParsed()
        let doc = parsed.document
        var innerLineId: EntityID!
        doc.transact("Draw") { tx in
            innerLineId = tx.add(EntityPrototype(type: .line, layerId: 0,
                payload: .line(LinePayload(a: Vec3(x: 0, y: 0), b: Vec3(x: 1, y: 0)))))
        }
        var innerBlock: BlockEditor.CreateBlockResult?
        doc.transact("Inner block") { tx in
            innerBlock = BlockEditor.createBlock(name: "INNER", basePoint: .zero, from: [innerLineId],
                                                 insertLayerId: 0, in: parsed, tx: tx)
        }
        let innerInsertId = try XCTUnwrap(innerBlock?.insertId)
        // Wrap the inner insert into an outer block.
        var outerBlock: BlockEditor.CreateBlockResult?
        doc.transact("Outer block") { tx in
            outerBlock = BlockEditor.createBlock(name: "OUTER", basePoint: .zero, from: [innerInsertId],
                                                 insertLayerId: 0, in: parsed, tx: tx)
        }
        let outerInsertId = try XCTUnwrap(outerBlock?.insertId)

        var result: EntityExploder.Result!
        doc.transact("Explode outer (default, no nested)") { tx in
            result = EntityExploder.explode(ids: [outerInsertId], nested: false, store: doc.store, parsed: parsed, tx: tx)
        }
        XCTAssertEqual(result.newIDs.count, 1)
        let newId = try XCTUnwrap(result.newIDs.first)
        let h = try XCTUnwrap(doc.store.header(newId))
        XCTAssertEqual(h.type, .insert, "a nested INSERT must stay an INSERT (transform-baked) when nested==false")
        let ip = doc.store.inserts[Int(h.payload)]
        XCTAssertEqual(doc.store.strings.string(for: ip.blockNameId), "INNER")
    }

    func testExplodeNestedInsertRecursesWhenNestedTrue() throws {
        let parsed = makeParsed()
        let doc = parsed.document
        var innerLineId: EntityID!
        doc.transact("Draw") { tx in
            innerLineId = tx.add(EntityPrototype(type: .line, layerId: 0,
                payload: .line(LinePayload(a: Vec3(x: 0, y: 0), b: Vec3(x: 1, y: 0)))))
        }
        var innerBlock: BlockEditor.CreateBlockResult?
        doc.transact("Inner block") { tx in
            innerBlock = BlockEditor.createBlock(name: "INNER2", basePoint: .zero, from: [innerLineId],
                                                 insertLayerId: 0, in: parsed, tx: tx)
        }
        let innerInsertId = try XCTUnwrap(innerBlock?.insertId)
        var outerBlock: BlockEditor.CreateBlockResult?
        doc.transact("Outer block") { tx in
            outerBlock = BlockEditor.createBlock(name: "OUTER2", basePoint: .zero, from: [innerInsertId],
                                                 insertLayerId: 0, in: parsed, tx: tx)
        }
        let outerInsertId = try XCTUnwrap(outerBlock?.insertId)

        var result: EntityExploder.Result!
        doc.transact("Explode outer (nested=true)") { tx in
            result = EntityExploder.explode(ids: [outerInsertId], nested: true, store: doc.store, parsed: parsed, tx: tx)
        }
        XCTAssertEqual(result.newIDs.count, 1, "the inner insert recurses to its 1 LINE child")
        let newId = try XCTUnwrap(result.newIDs.first)
        let h = try XCTUnwrap(doc.store.header(newId))
        XCTAssertEqual(h.type, .line, "nested=true must recurse through the inner insert down to its LINE")
    }

    /// Adversarial-review regression: `bakeInsertTransform`'s rotation
    /// extraction was derived from the composed matrix's FIRST column
    /// (a,b) via `atan2(b,a)`, which implicitly assumes a positive scaleX
    /// — wrong by exactly 180 degrees whenever the composed transform has
    /// a NEGATIVE determinant (an odd number of mirrors in the nested-
    /// insert chain, e.g. a mirrored door/window block nested inside an
    /// unmirrored wall-assembly block — an entirely ordinary drawing
    /// pattern). Verified end-to-end via direct point comparison: the
    /// nested insert's OWN scale is mirrored (x = -2), composed with an
    /// enclosing insert that has its own rotation+uniform scale (no
    /// mirror) — an odd number of mirrors overall, exactly the trigger
    /// condition. A point on the inner LINE, transformed DIRECTLY through
    /// both matrices by hand, must land exactly where the baked
    /// (position, rotationDeg, scale) nested INSERT places it (verified by
    /// checking the baked-and-then-`nested:true`-recursed LINE's final
    /// endpoint, which composes the SAME baked transform with the LINE's
    /// own local coordinates).
    func testBakeInsertTransformWithMirroredNestedInsertMatchesDirectComposition() throws {
        let parsed = makeParsed()
        let doc = parsed.document
        var innerLineId: EntityID!
        doc.transact("Draw") { tx in
            // A single point-like reference: line from (1,0) to (1,0) is
            // degenerate, so use (1,0)->(2,0) and check the START endpoint
            // (1,0), matching the hand-computed reference below exactly.
            innerLineId = tx.add(EntityPrototype(type: .line, layerId: 0,
                payload: .line(LinePayload(a: Vec3(x: 1, y: 0), b: Vec3(x: 2, y: 0)))))
        }
        var innerBlock: BlockEditor.CreateBlockResult?
        doc.transact("Inner block") { tx in
            innerBlock = BlockEditor.createBlock(name: "MIRRORINNER", basePoint: .zero, from: [innerLineId],
                                                 insertLayerId: 0, in: parsed, tx: tx)
        }
        let innerInsertId = try XCTUnwrap(innerBlock?.insertId)
        // Inner insert: position (1,1), rotation 10 deg, scale (-2,2) — mirrored.
        doc.transact("Set inner insert transform") { tx in
            tx.modifyPayload(innerInsertId) { copy in
                guard case .insert(var p) = copy else { return }
                p.position = Vec3(x: 1, y: 1)
                p.rotationDeg = 10
                p.scale = Vec3(x: -2, y: 2, z: 1)
                copy = .insert(p)
            }
        }
        var outerBlock: BlockEditor.CreateBlockResult?
        doc.transact("Outer block") { tx in
            outerBlock = BlockEditor.createBlock(name: "MIRROROUTER", basePoint: .zero, from: [innerInsertId],
                                                 insertLayerId: 0, in: parsed, tx: tx)
        }
        let outerInsertId = try XCTUnwrap(outerBlock?.insertId)
        // Outer insert: position (50,20), rotation 15 deg, scale (3,3) — NOT mirrored.
        doc.transact("Set outer insert transform") { tx in
            tx.modifyPayload(outerInsertId) { copy in
                guard case .insert(var p) = copy else { return }
                p.position = Vec3(x: 50, y: 20)
                p.rotationDeg = 15
                p.scale = Vec3(x: 3, y: 3, z: 1)
                copy = .insert(p)
            }
        }

        // Hand-computed ground truth (independently verified via NumPy
        // during development): composing child (pos=(1,1), rot=10,
        // scale=(-2,2)) then enclosing (pos=(50,20), rot=15, scale=(3,3))
        // and transforming the LINE's start point (1,0) directly.
        func directTransform(_ p: (x: Double, y: Double)) -> (x: Double, y: Double) {
            func applyInsert(_ pt: (x: Double, y: Double), pos: (x: Double, y: Double), rotDeg: Double, scale: (x: Double, y: Double)) -> (x: Double, y: Double) {
                let sx = pt.x * scale.x, sy = pt.y * scale.y
                let rot = rotDeg * .pi / 180
                let rx = sx * cos(rot) - sy * sin(rot)
                let ry = sx * sin(rot) + sy * cos(rot)
                return (pos.x + rx, pos.y + ry)
            }
            let afterChild = applyInsert(p, pos: (1, 1), rotDeg: 10, scale: (-2, 2))
            let afterEnclosing = applyInsert(afterChild, pos: (50, 20), rotDeg: 15, scale: (3, 3))
            return afterEnclosing
        }
        let expectedStart = directTransform((1, 0))

        // Explode the OUTER insert with nested:true, which bakes the inner
        // insert's transform via bakeInsertTransform, then immediately
        // recurses into it, ultimately producing the LINE at its true
        // world position.
        var result: EntityExploder.Result!
        doc.transact("Explode outer (nested=true, mirrored inner)") { tx in
            result = EntityExploder.explode(ids: [outerInsertId], nested: true, store: doc.store, parsed: parsed, tx: tx)
        }
        let newId = try XCTUnwrap(result.newIDs.first)
        let h = try XCTUnwrap(doc.store.header(newId))
        XCTAssertEqual(h.type, .line, "nested=true must recurse all the way to the LINE")
        let line = doc.store.lines[Int(h.payload)]

        // The LINE's start point (originally (1,0)) must match the
        // directly-composed ground truth exactly — this is the check that
        // fails (by ~180-degree-rotation-sized error, tens of units) under
        // the pre-fix `atan2(b,a)` formula.
        XCTAssertEqual(line.a.x, expectedStart.x, accuracy: 1e-6)
        XCTAssertEqual(line.a.y, expectedStart.y, accuracy: 1e-6)
    }

    // MARK: - Atomic entities cannot explode further

    func testExplodeLineReturnsSkipped() throws {
        let parsed = makeParsed()
        let doc = parsed.document
        var lineId: EntityID!
        doc.transact("Draw") { tx in
            lineId = tx.add(EntityPrototype(type: .line, layerId: 0,
                payload: .line(LinePayload(a: Vec3(x: 0, y: 0), b: Vec3(x: 1, y: 1)))))
        }
        var result: EntityExploder.Result!
        doc.transact("Explode") { tx in
            result = EntityExploder.explode(ids: [lineId], store: doc.store, parsed: parsed, tx: tx)
        }
        XCTAssertEqual(result.skippedCount, 1)
        XCTAssertEqual(result.explodedCount, 0)
        XCTAssertFalse(doc.store.isDeleted(lineId), "an atomic entity must be left untouched, not deleted")
    }

    func testExplodeSplineCannotExplode() throws {
        let parsed = makeParsed()
        let doc = parsed.document
        var splineId: EntityID!
        doc.transact("Draw") { tx in
            splineId = tx.add(EntityPrototype(type: .spline, layerId: 0,
                payload: .spline(SplinePayload(degree: 3),
                                 control: [Vec3(x: 0, y: 0), Vec3(x: 1, y: 1), Vec3(x: 2, y: 0), Vec3(x: 3, y: 1)],
                                 knots: [0, 0, 0, 0, 1, 1, 1, 1], weights: [])))
        }
        var result: EntityExploder.Result!
        doc.transact("Explode") { tx in
            result = EntityExploder.explode(ids: [splineId], store: doc.store, parsed: parsed, tx: tx)
        }
        XCTAssertEqual(result.skippedCount, 1)
        XCTAssertFalse(doc.store.isDeleted(splineId))
    }

    func testExplodeEllipseCannotExplode() throws {
        let parsed = makeParsed()
        let doc = parsed.document
        var ellipseId: EntityID!
        doc.transact("Draw") { tx in
            ellipseId = tx.add(EntityPrototype(type: .ellipse, layerId: 0,
                payload: .ellipse(EllipsePayload(center: Vec3(x: 0, y: 0), majorAxisEndpoint: Vec3(x: 5, y: 0),
                                                 ratio: 0.5, startParam: 0, endParam: 2 * .pi))))
        }
        var result: EntityExploder.Result!
        doc.transact("Explode") { tx in
            result = EntityExploder.explode(ids: [ellipseId], store: doc.store, parsed: parsed, tx: tx)
        }
        XCTAssertEqual(result.skippedCount, 1)
    }

    // MARK: - Multi-select in one transaction

    func testExplodeMultipleInsertsInOneTransaction() throws {
        let parsed = makeParsed()
        let doc = parsed.document
        var line1: EntityID!, line2: EntityID!
        doc.transact("Draw") { tx in
            line1 = tx.add(EntityPrototype(type: .line, layerId: 0,
                payload: .line(LinePayload(a: Vec3(x: 0, y: 0), b: Vec3(x: 1, y: 0)))))
            line2 = tx.add(EntityPrototype(type: .line, layerId: 0,
                payload: .line(LinePayload(a: Vec3(x: 0, y: 0), b: Vec3(x: 0, y: 1)))))
        }
        var block1: BlockEditor.CreateBlockResult?, block2: BlockEditor.CreateBlockResult?
        doc.transact("Blocks") { tx in
            block1 = BlockEditor.createBlock(name: "MULTI1", basePoint: .zero, from: [line1], insertLayerId: 0, in: parsed, tx: tx)
            block2 = BlockEditor.createBlock(name: "MULTI2", basePoint: .zero, from: [line2], insertLayerId: 0, in: parsed, tx: tx)
        }
        let id1 = try XCTUnwrap(block1?.insertId)
        let id2 = try XCTUnwrap(block2?.insertId)

        var result: EntityExploder.Result!
        doc.transact("Explode both") { tx in
            result = EntityExploder.explode(ids: [id1, id2], store: doc.store, parsed: parsed, tx: tx)
        }
        XCTAssertEqual(result.explodedCount, 2)
        XCTAssertEqual(result.newIDs.count, 2)
        XCTAssertEqual(doc.undoStack.count, 3)   // Draw, Blocks, "Explode both" — confirms ONE transaction for both explodes
        doc.undo()
        XCTAssertFalse(doc.store.isDeleted(id1), "undoing the single explode transaction must restore BOTH inserts")
        XCTAssertFalse(doc.store.isDeleted(id2))
    }

    // MARK: - HATCH boundary-only explosion

    func testExplodeHatchProducesBoundaryLines() throws {
        let parsed = makeParsed()
        let doc = parsed.document
        var hatchId: EntityID!
        doc.transact("Draw") { tx in
            let loop = [Vec3(x: 0, y: 0), Vec3(x: 10, y: 0), Vec3(x: 10, y: 10), Vec3(x: 0, y: 10)]
            hatchId = tx.add(EntityPrototype(type: .hatch, layerId: 0,
                payload: .hatch(HatchPayload(isSolid: true), loops: [loop])))
        }
        var result: EntityExploder.Result!
        doc.transact("Explode") { tx in
            result = EntityExploder.explode(ids: [hatchId], store: doc.store, parsed: parsed, tx: tx)
        }
        XCTAssertEqual(result.explodedCount, 1)
        XCTAssertEqual(result.newIDs.count, 4, "a 4-point loop boundary explodes to 4 LINEs")
        for id in result.newIDs {
            let h = try XCTUnwrap(doc.store.header(id))
            XCTAssertEqual(h.type, .line)
        }
    }

    // MARK: - PropertyResolver integration (BYBLOCK/layer-0 inheritance during explode)

    func testExplodeResolvesLayerZeroToInsertsLayer() throws {
        let parsed = makeParsed()
        let doc = parsed.document
        var lineId: EntityID!
        doc.transact("Draw") { tx in
            // layer 0 (index 0) inside the block.
            lineId = tx.add(EntityPrototype(type: .line, layerId: 0,
                payload: .line(LinePayload(a: Vec3(x: 0, y: 0), b: Vec3(x: 1, y: 0)))))
        }
        var blockResult: BlockEditor.CreateBlockResult?
        doc.transact("Block") { tx in
            blockResult = BlockEditor.createBlock(name: "L0", basePoint: .zero, from: [lineId],
                                                  insertLayerId: 1 /* SYMBOLS */, in: parsed, tx: tx)
        }
        let insertId = try XCTUnwrap(blockResult?.insertId)

        var result: EntityExploder.Result!
        doc.transact("Explode") { tx in
            result = EntityExploder.explode(ids: [insertId], store: doc.store, parsed: parsed, tx: tx)
        }
        let newId = try XCTUnwrap(result.newIDs.first)
        let h = try XCTUnwrap(doc.store.header(newId))
        XCTAssertEqual(h.layerId, 1, "a layer-0 entity inside the block must inherit the INSERT's layer (SYMBOLS=1) after explode")
    }

    func testExplodeBakesByBlockColorToInsertsResolvedColor() throws {
        let parsed = makeParsed()
        let doc = parsed.document
        var lineId: EntityID!
        doc.transact("Draw") { tx in
            lineId = tx.add(EntityPrototype(type: .line, layerId: 0, aci: 0 /* BYBLOCK */,
                payload: .line(LinePayload(a: Vec3(x: 0, y: 0), b: Vec3(x: 1, y: 0)))))
        }
        var blockResult: BlockEditor.CreateBlockResult?
        doc.transact("Block") { tx in
            blockResult = BlockEditor.createBlock(name: "BB", basePoint: .zero, from: [lineId],
                                                  insertLayerId: 0, in: parsed, tx: tx)
        }
        let insertId = try XCTUnwrap(blockResult?.insertId)
        doc.transact("Set insert color") { tx in
            tx.modifyHeader(insertId) { $0.aci = 3 }   // insert itself explicitly green (ACI 3)
        }

        var result: EntityExploder.Result!
        doc.transact("Explode") { tx in
            result = EntityExploder.explode(ids: [insertId], store: doc.store, parsed: parsed, tx: tx)
        }
        let newId = try XCTUnwrap(result.newIDs.first)
        let h = try XCTUnwrap(doc.store.header(newId))
        XCTAssertEqual(h.aci, 3, "a BYBLOCK entity must bake to the insert's own resolved color after explode")
    }
}
