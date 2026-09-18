import Foundation
import CADCore
import CoreGraphics

// MARK: - Drafting state

/// Result of feeding one point/keyword into `DraftState` — Phase 6.3 widens
/// the old `DrawnEntity?` return into a 3-case enum per the plan's exact
/// spec shape. Most tools just finish-or-don't (`.none`/`.entity`).
/// `.needsBoundaryPick` exists for the plan's literal `DraftOutput` shape
/// but is NOT actually produced by `addPoint` today: `region`'s fallback
/// ("select a closed polyline/circle/ellipse" — see the plan's own scoping
/// text) needs a hit test, which `DraftState` itself can't perform (no
/// `EntityStore` access — it's a pure, store-free struct by design, see its
/// own doc comment) — rather than round-tripping through this case, the
/// host (`ContentView.feedTypedPoint`/`handleClick`) special-cases
/// `draft.mode == .region` BEFORE ever calling `addPoint` at all, routing
/// straight to `commitRegionPick`. This case is kept in the enum (matching
/// the plan's spec verbatim, and so `commitDraftOutput`'s `guard case
/// .entity(...) else { return nil }` handles it as a safe no-op if a future
/// change ever does produce it) even though nothing currently constructs it.
enum DraftOutput {
    case none
    case entity(EntityPrototype)
    case needsBoundaryPick(Vec2)
}

/// Active drawing tool state (world coordinates), driving the canvas preview.
///
/// Phase 6.3: `addPoint` now returns a `DraftOutput` carrying a ready-to-add
/// `EntityPrototype` instead of the legacy `DrawnEntity?` — per the plan,
/// "all existing modes switch from producing DrawnEntity to prototypes
/// targeting CurrentProperties." `DraftState` itself stays store-free (no
/// `EntityStore`/`StringTable` reference), matching its pre-existing design:
/// prototype construction needs a `layerId` (from `CurrentProperties` or the
/// legacy markup layer, depending on mode — see `DraftContext` below) and,
/// for TEXT-family shapes, a live `StringTable` to intern into — both
/// supplied by the caller via `DraftContext` at the point `addPoint` is
/// called, not stored on `DraftState` itself (which must stay `Equatable`
/// and safely copyable for SwiftUI's `@Published` diffing).
struct DraftState: Equatable {
    enum Mode: Equatable {
        case none, line, polyline, circle, arc3pt, rect, polygon, text, stamp, erase
        // Phase 6.3 new entity tools.
        case ellipse, ellipseAxis, splineFit, splineCV, pointEnt, face3d, region
    }
    var mode: Mode = .none
    var points: [CGPoint] = []
    var hover: CGPoint? = nil
    var snap: SnapResult? = nil
    /// Regular-polygon side count (POLYGON tool).
    var polygonSides = 6
    /// ELLIPSE: true once "R" (rotation mode: 3rd click sets a rotation
    /// angle about the major axis, `ratio = cos(angle)`) has been typed for
    /// THIS ellipse — cleared on completion/reset like every other
    /// per-invocation flag in this struct (mirrors `OffsetToolState.
    /// throughPointMode`'s "fixed for this command's lifetime" shape, except
    /// ELLIPSE's own R keyword is per-shape, not per `begin(...)`, since
    /// AutoCAD's ELLIPSE re-prompts center/axis/ratio-or-R fresh every time).
    var ellipseRotationMode = false
    /// SPLINE-fit: true once "CLOSE" has been typed — the NEXT Enter finishes
    /// a closed spline through all fit points so far, mirroring PLINE's own
    /// `C` mid-gesture keyword.
    var splineClose = false

    var isActive: Bool { mode != .none }

    var prompt: String {
        switch mode {
        case .none: return ""
        case .line:
            return points.isEmpty ? "LINE — specify first point"
                                  : "LINE — specify second point"
        case .polyline:
            return points.isEmpty ? "PLINE — specify first point"
                : "PLINE — next point (⏎ to finish, C to close)"
        case .circle:
            return points.isEmpty ? "CIRCLE — specify center"
                                  : "CIRCLE — specify radius point"
        case .arc3pt:
            switch points.count {
            case 0: return "ARC — specify start point"
            case 1: return "ARC — specify point on arc"
            default: return "ARC — specify end point"
            }
        case .rect:
            return points.isEmpty ? "RECTANGLE — specify first corner"
                                  : "RECTANGLE — specify opposite corner"
        case .polygon:
            return points.isEmpty ? "POLYGON (\(polygonSides) sides) — specify center"
                                  : "POLYGON — specify a corner (radius)"
        case .text:
            return "TEXT — click to place a note"
        case .stamp:
            return "STAMP — click to place the chosen block symbol"
        case .erase:
            return "ERASE — click markup to delete (use Undo to restore)"
        case .ellipse:
            switch points.count {
            case 0: return "ELLIPSE — specify center (or A for Axis endpoint)"
            case 1: return "ELLIPSE — specify major axis endpoint"
            default: return ellipseRotationMode
                ? "ELLIPSE — specify rotation angle (or click)"
                : "ELLIPSE — specify other axis distance (or R for Rotation, or click)"
            }
        case .ellipseAxis:
            switch points.count {
            case 0: return "ELLIPSE — specify axis endpoint"
            case 1: return "ELLIPSE — specify other axis endpoint"
            default: return "ELLIPSE — specify other axis distance"
            }
        case .splineFit:
            return points.isEmpty ? "SPLINE — specify first fit point"
                : "SPLINE — next fit point (⏎ to finish ≥2 pts, CLOSE to close)"
        case .splineCV:
            return points.isEmpty ? "SPLINE (CV) — specify first control vertex"
                : "SPLINE (CV) — next control vertex (⏎ to finish ≥4 pts)"
        case .pointEnt:
            return "POINT — click to place (repeats until Esc)"
        case .face3d:
            switch points.count {
            case 0: return "3DFACE — specify first point"
            case 1: return "3DFACE — specify second point"
            case 2: return "3DFACE — specify third point"
            default: return "3DFACE — specify fourth point (same as third to close as a triangle)"
            }
        case .region:
            return "REGION — select a closed polyline, circle, or ellipse"
        }
    }

    /// Feeds one point; returns what completed (if anything) — see
    /// `DraftOutput`'s doc comment. `ctx` supplies the store-dependent bits
    /// (target layer/color/linetype, string interning) a bare `DraftState`
    /// can't hold itself.
    mutating func addPoint(_ p: CGPoint, ctx: DraftContext) -> DraftOutput {
        switch mode {
        case .none, .erase, .text, .stamp, .region:
            // .text/.stamp are handled by the host; .region's click is
            // routed by the host straight to `.needsBoundaryPick` (see
            // `ContentView.feedTypedPoint`) since it needs a hit test this
            // struct can't perform itself — addPoint is never actually
            // called for `.region` in practice, but returning `.none`
            // defensively (rather than crashing) matches every other
            // host-handled mode above.
            return .none
        case .polygon:
            points.append(p)
            if points.count == 2 {
                let proto = DraftState.regularPolygon(center: points[0], through: points[1],
                                                       sides: polygonSides, ctx: ctx)
                points = []
                return proto.map { .entity($0) } ?? .none
            }
        case .line:
            points.append(p)
            if points.count == 2 {
                let proto = ctx.proto(.line, .line(LinePayload(a: Vec3(points[0]), b: Vec3(points[1]))))
                points = [p]     // chain: next line starts at this endpoint
                return .entity(proto)
            }
        case .polyline:
            points.append(p)
        case .circle:
            points.append(p)
            if points.count == 2 {
                let r = hypot(points[1].x - points[0].x, points[1].y - points[0].y)
                defer { points = [] }
                guard r > 0 else { return .none }
                return .entity(ctx.proto(.circle, .circle(CirclePayload(center: Vec3(points[0]), radius: Double(r)))))
            }
        case .arc3pt:
            points.append(p)
            if points.count == 3 {
                let proto = DraftState.arcThrough(points[0], points[1], points[2], ctx: ctx)
                points = []
                return .entity(proto)
            }
        case .rect:
            points.append(p)
            if points.count == 2 {
                let pts = [CGPoint(x: points[0].x, y: points[0].y), CGPoint(x: points[1].x, y: points[0].y),
                          CGPoint(x: points[1].x, y: points[1].y), CGPoint(x: points[0].x, y: points[1].y)]
                let bulges = [Double](repeating: 0, count: 4)
                let proto = ctx.proto(.lwpolyline, .polyline(PolylinePayload(closed: true),
                                                              vertices: pts.map { Vec3($0) }, bulges: bulges))
                points = []
                return .entity(proto)
            }
        case .ellipse:
            return addEllipsePoint(p, ctx: ctx, axisEndpointForm: false)
        case .ellipseAxis:
            return addEllipsePoint(p, ctx: ctx, axisEndpointForm: true)
        case .splineFit, .splineCV:
            points.append(p)
        case .pointEnt:
            // Repeating — every click immediately completes one POINT
            // entity and stays active for the next (AutoCAD's own default
            // POINT behavior without PDMODE-driven multi-point tools).
            return .entity(ctx.proto(.point, .point(PointPayload(p: Vec3(p)))))
        case .face3d:
            points.append(p)
            if points.count == 4 {
                let proto = DraftState.face3DPrototype(points, ctx: ctx)
                points = []
                return .entity(proto)
            }
        }
        return .none
    }

    /// ELLIPSE: shared logic for both the "center → major endpoint → ratio
    /// point/R" form (`axisEndpointForm == false`) and the AutoCAD "Axis
    /// endpoint" variant (first click is ONE end of an axis, second is the
    /// OTHER end — center is the midpoint — third is still the ratio
    /// point/distance, `axisEndpointForm == true`).
    private mutating func addEllipsePoint(_ p: CGPoint, ctx: DraftContext, axisEndpointForm: Bool) -> DraftOutput {
        points.append(p)
        if axisEndpointForm {
            // Axis-endpoint form: [axisEnd1, axisEnd2, ratioPointOrCenter-relative].
            guard points.count == 3 else { return .none }
            let a0 = points[0], a1 = points[1], ratioPoint = points[2]
            let center = CGPoint(x: (a0.x + a1.x) / 2, y: (a0.y + a1.y) / 2)
            let major = CGPoint(x: a1.x - center.x, y: a1.y - center.y)
            defer { points = []; ellipseRotationMode = false }
            return DraftState.ellipsePrototype(center: center, major: major, ratioPoint: ratioPoint,
                                               rotationMode: ellipseRotationMode, ctx: ctx)
        } else {
            // Center form: [center, majorAxisEndpoint, ratioPointOrAngle].
            guard points.count == 3 else { return .none }
            let center = points[0]
            let major = CGPoint(x: points[1].x - center.x, y: points[1].y - center.y)
            let ratioPoint = points[2]
            defer { points = []; ellipseRotationMode = false }
            return DraftState.ellipsePrototype(center: center, major: major, ratioPoint: ratioPoint,
                                               rotationMode: ellipseRotationMode, ctx: ctx)
        }
    }

    /// Builds an ELLIPSE `EntityPrototype` from a center, major-axis vector
    /// (center -> major endpoint), and a third pick that is EITHER a ratio
    /// point (perpendicular distance from the major axis line determines
    /// `minorLen`, so `ratio = minorLen / majorLen`) OR — when
    /// `rotationMode` is set (the "R" keyword) — a point whose angle
    /// subtended from the ellipse's own minor-axis direction gives a
    /// rotation angle, with `ratio = cos(angle)` per AutoCAD's ELLIPSE
    /// rotation-around-major-axis convention (this is the standard
    /// "ellipse as a circle viewed from an angle" model: at angle 0 the
    /// ellipse is a circle (ratio 1); at 90 degrees it degenerates to a
    /// line (ratio 0)). `ratio > 1` (the ratio point is FARTHER from the
    /// major axis than half the major length) swaps the major/minor axes so
    /// the stored `ratio` is always <= 1, matching DXF's own ELLIPSE
    /// convention (`majorAxisEndpoint` is always the longer axis).
    static func ellipsePrototype(center: CGPoint, major: CGPoint, ratioPoint: CGPoint,
                                 rotationMode: Bool, ctx: DraftContext) -> DraftOutput {
        let majorLen = hypot(major.x, major.y)
        guard majorLen > 1e-9 else { return .none }
        let ux = major.x / majorLen, uy = major.y / majorLen   // unit major-axis direction

        let ratio: Double
        if rotationMode {
            // Angle between the major axis and the vector to `ratioPoint`,
            // measured from the CENTER — AutoCAD's Rotation option prompts
            // for an angle directly, but accepting a POINT pick (as this
            // tool's other two paths do) and deriving the angle from it is
            // the natural mouse-driven equivalent; the command-bar path
            // (typed degrees) is handled separately by `ellipsePrototypeByRotationAngle`.
            let dx = Double(ratioPoint.x - center.x), dy = Double(ratioPoint.y - center.y)
            let d = hypot(dx, dy)
            guard d > 1e-9 else { return .none }
            let cosAngle = (dx * Double(ux) + dy * Double(uy)) / d
            ratio = abs(cosAngle)
        } else {
            // Perpendicular distance from `ratioPoint` to the infinite major
            // axis line through `center`, divided by majorLen — the
            // standard "3rd point sets the minor-axis distance" ELLIPSE UX.
            let dx = Double(ratioPoint.x - center.x), dy = Double(ratioPoint.y - center.y)
            // Perp component = |d| projected onto the axis PERPENDICULAR
            // direction (-uy, ux).
            let perp = abs(dx * Double(-uy) + dy * Double(ux))
            ratio = perp / Double(majorLen)
        }
        guard ratio.isFinite, ratio > 1e-9 else { return .none }

        if ratio > 1 {
            // Swap: the "minor" axis is actually longer — the true major
            // axis is PERPENDICULAR to the picked `major` vector, with
            // length `perp` (= ratio * majorLen, before inverting `ratio`
            // below), NOT `majorLen`. Rotating `major` 90 degrees while
            // keeping its old length (a naive swap) would silently rescale
            // the whole ellipse down by a factor of `ratio` — the aspect
            // ratio would still look right but both axes would be the
            // wrong absolute size.
            let newMajorLen = ratio * majorLen
            let newMajor = Vec3(x: -Double(uy) * newMajorLen, y: Double(ux) * newMajorLen)
            return .entity(ctx.proto(.ellipse, .ellipse(EllipsePayload(
                center: Vec3(center), majorAxisEndpoint: newMajor,
                ratio: 1 / ratio, startParam: 0, endParam: 2 * .pi))))
        }
        return .entity(ctx.proto(.ellipse, .ellipse(EllipsePayload(
            center: Vec3(center), majorAxisEndpoint: Vec3(major),
            ratio: ratio, startParam: 0, endParam: 2 * .pi))))
    }

    /// Command-bar ("R" then a typed degree value) variant of the rotation
    /// path above — used when the user types a numeric angle instead of
    /// clicking a point for it (see `ContentView`'s ellipse-rotation typed
    /// input handling).
    static func ellipsePrototypeByRotationAngle(center: CGPoint, major: CGPoint, angleDeg: Double,
                                                ctx: DraftContext) -> DraftOutput {
        let majorLen = hypot(major.x, major.y)
        guard majorLen > 1e-9 else { return .none }
        let ratio = abs(cos(angleDeg * .pi / 180))
        guard ratio > 1e-9 else { return .none }
        // `ratio = |cos(angleDeg)|` is always <= 1, so (unlike
        // `ellipsePrototype`'s point-picked ratio, which can exceed 1) no
        // axis swap is ever needed here.
        return .entity(ctx.proto(.ellipse, .ellipse(EllipsePayload(
            center: Vec3(center), majorAxisEndpoint: Vec3(major),
            ratio: ratio, startParam: 0, endParam: 2 * .pi))))
    }

    /// Finishes an in-progress polyline (⏎ / double-click). `close` joins the
    /// last vertex back to the first (explicit "C"/close-gesture request —
    /// see `ContentView`'s `upper == "C"` handling and `.closePolyline`).
    ///
    /// Also AUTO-DETECTS closed-ness even when `close` is `false`: if the
    /// user's last clicked point lands back on (or extremely near) the
    /// FIRST point — typically via OSNAP endpoint-snapping onto the
    /// polyline's own start, a common "trace the boundary back to where I
    /// began, then just hit Enter" gesture — the polyline is treated as
    /// closed exactly as if "C" had been typed, and the redundant duplicate
    /// closing vertex (which would otherwise sit exactly on top of the
    /// first vertex) is dropped, since `closed` already implies an
    /// implicit last-to-first segment (see `Regenerator`'s `endRun(closed:)`
    /// / `CGRenderCore`'s `path.closeSubpath()`) — keeping the duplicate
    /// would draw a redundant zero-length segment on top of the real one.
    mutating func finishPolyline(close: Bool, ctx: DraftContext) -> DraftOutput {
        guard mode == .polyline, points.count >= 2 else { points = []; return .none }
        var verts = points
        var effectiveClose = close && verts.count >= 3
        if !effectiveClose, verts.count >= 4 {
            let first = verts[0], last = verts[verts.count - 1]
            if hypot(last.x - first.x, last.y - first.y) < Self.coincidentPointTolerance {
                verts.removeLast()
                effectiveClose = true
            }
        }
        let bulges = [Double](repeating: 0, count: verts.count)
        let proto = ctx.proto(.lwpolyline, .polyline(
            PolylinePayload(closed: effectiveClose), vertices: verts.map { Vec3($0) }, bulges: bulges))
        points = []
        return .entity(proto)
    }

    /// Point-coincidence threshold (drawing units) for auto-detecting a
    /// closed polyline — deliberately tight (matches this codebase's other
    /// exact/near-exact coincidence checks, e.g. `RegionTool`'s full-sweep
    /// ellipse guard) since the intended trigger is an OSNAP endpoint snap
    /// back onto the start point, which reproduces that point's coordinate
    /// bit-for-bit, not merely "visually close on screen."
    private static let coincidentPointTolerance: CGFloat = 1e-6

    /// Finishes an in-progress fit-point SPLINE (⏎, requires >= 2 points).
    /// `close` (typed "CLOSE") appends the first point again so
    /// `SplineFit.interpolate`'s own closed-curve handling produces a
    /// periodic-equivalent loop — see that function's doc comment.
    mutating func finishSplineFit(close: Bool, ctx: DraftContext) -> DraftOutput {
        guard mode == .splineFit, points.count >= 2 else { points = []; splineClose = false; return .none }
        let fitPoints = points.map { Vec2($0) }
        let nurbs = SplineFit.interpolate(fitPoints: fitPoints, closed: close)
        points = []
        splineClose = false
        guard nurbs.isValid else { return .none }
        return .entity(ctx.protoRaw(EntityCurveBridge.splinePayload(for: nurbs)))
    }

    /// Finishes an in-progress control-vertex SPLINE (⏎, requires >= 4
    /// points for a real cubic — degree 3 is fixed per the plan's spec
    /// text). A clamped-uniform knot vector is synthesized (no fit-point
    /// interpolation — the clicked points ARE the control net verbatim,
    /// matching AutoCAD's own SPLINE "control vertices" method).
    mutating func finishSplineCV(ctx: DraftContext) -> DraftOutput {
        guard mode == .splineCV, points.count >= 4 else { points = []; return .none }
        let degree = 3
        let control = points.map { Vec2($0) }
        let n = control.count - 1
        var knots = [Double](repeating: 0, count: n + degree + 2)
        for i in 0...degree { knots[i] = 0 }
        for i in 0...degree { knots[knots.count - 1 - i] = 1 }
        if n > degree {
            for j in 1...(n - degree) {
                knots[j + degree] = Double(j) / Double(n - degree + 1)
            }
        }
        let nurbs = NURBS(degree: degree, control: control, weights: [Double](repeating: 1, count: control.count), knots: knots)
        points = []
        guard nurbs.isValid else { return .none }
        return .entity(ctx.protoRaw(EntityCurveBridge.splinePayload(for: nurbs)))
    }

    /// Regular polygon inscribed in the circle through `corner`, with the first
    /// vertex at `corner` (AutoCAD "inscribed" POLYGON). Pure geometry (no
    /// `DraftContext`) — used both by the entity-producing `addPoint` path
    /// (wrapped into a prototype below) and by `DXFCanvasView`'s ghost
    /// preview (which only needs the vertex list to stroke, never a real
    /// entity).
    static func regularPolygonVertices(center: CGPoint, through corner: CGPoint, sides: Int) -> [CGPoint]? {
        let n = max(3, min(64, sides))
        let r = hypot(corner.x - center.x, corner.y - center.y)
        guard r > 1e-9 else { return nil }
        let a0 = atan2(corner.y - center.y, corner.x - center.x)
        var pts: [CGPoint] = []
        for k in 0..<n {
            let a = a0 + Double(k) * 2 * .pi / Double(n)
            pts.append(CGPoint(x: center.x + r * cos(a), y: center.y + r * sin(a)))
        }
        return pts
    }

    static func regularPolygon(center: CGPoint, through corner: CGPoint,
                               sides: Int, ctx: DraftContext) -> EntityPrototype? {
        guard let pts = regularPolygonVertices(center: center, through: corner, sides: sides) else { return nil }
        let bulges = [Double](repeating: 0, count: pts.count)
        return ctx.proto(.lwpolyline, .polyline(PolylinePayload(closed: true), vertices: pts.map { Vec3($0) }, bulges: bulges))
    }

    /// Circumscribed-arc geometry through three points (center, radius,
    /// start/end degrees — CCW, oriented so the middle point lies on the
    /// swept portion), or `nil` sentinel-via-degenerate-line for collinear
    /// input (see the `d` guard below) — pure geometry, no `DraftContext`,
    /// same "shared by both the real tool and the ghost preview" shape as
    /// `regularPolygonVertices` above.
    static func arcThroughGeometry(_ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint)
        -> (center: CGPoint, radius: CGFloat, startDeg: Double, endDeg: Double)? {
        let ax = p1.x, ay = p1.y, bx = p2.x, by = p2.y, cx = p3.x, cy = p3.y
        let d = 2 * (ax * (by - cy) + bx * (cy - ay) + cx * (ay - by))
        guard abs(d) > 1e-12 else { return nil }   // collinear
        let ux = ((ax * ax + ay * ay) * (by - cy) + (bx * bx + by * by) * (cy - ay)
                  + (cx * cx + cy * cy) * (ay - by)) / d
        let uy = ((ax * ax + ay * ay) * (cx - bx) + (bx * bx + by * by) * (ax - cx)
                  + (cx * cx + cy * cy) * (bx - ax)) / d
        let center = CGPoint(x: ux, y: uy)
        let r = hypot(ax - ux, ay - uy)
        var a1 = Double(atan2(ay - uy, ax - ux) * 180 / .pi)
        var a3 = Double(atan2(cy - uy, cx - ux) * 180 / .pi)
        let a2 = Double(atan2(by - uy, bx - ux) * 180 / .pi)
        // CCW from a1 to a3 must contain a2; otherwise swap direction.
        if !HitTester.angleWithinSweep(a2, from: a1, to: a3) { swap(&a1, &a3) }
        return (center, r, a1, a3)
    }

    /// Circumscribed arc through three points, oriented so the middle point
    /// lies on the swept portion. Collinear input degrades to a straight
    /// LINE prototype (DXF has no zero-curvature ARC).
    static func arcThrough(_ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, ctx: DraftContext) -> EntityPrototype {
        guard let g = arcThroughGeometry(p1, p2, p3) else {
            return ctx.proto(.line, .line(LinePayload(a: Vec3(p1), b: Vec3(p3))))
        }
        return ctx.proto(.arc, .arc(ArcPayload(center: Vec3(g.center), radius: Double(g.radius),
                                               startAngleDeg: g.startDeg, endAngleDeg: g.endDeg)))
    }

    /// 3DFACE: 4 clicks, all at Z=0 (this app is a 2D-plan-view editor — see
    /// the plan's own "Z=0" scoping note). A 3rd-equals-4th click (AutoCAD's
    /// own "repeat the last point to close as a triangle" convention)
    /// collapses to a 3-vertex face by duplicating the 3rd point as the
    /// 4th — `EntityStore`'s `.solid/.trace/.face3d` share `PolylinePayload`
    /// storage (see that struct's doc comment), so a 3DFACE is stored as a
    /// closed 4-vertex polyline exactly like SOLID/TRACE already are.
    static func face3DPrototype(_ pts: [CGPoint], ctx: DraftContext) -> EntityPrototype {
        let verts = pts.map { Vec3($0) }
        let bulges = [Double](repeating: 0, count: verts.count)
        return ctx.proto(.face3d, .polyline(PolylinePayload(closed: true), vertices: verts, bulges: bulges))
    }
}

/// Store-dependent context `DraftState.addPoint`/`finishPolyline`/etc. need
/// to build a real `EntityPrototype` — supplied fresh by the caller at each
/// call site (never stored on `DraftState` itself, which stays a plain,
/// store-free `Equatable` struct). Two flavors, matching the plan's own
/// "old tools keep their layer, new CAD tools use CLAYER" scope decision
/// (see `CurrentProperties.swift`'s header comment):
///   - `.markup(layerId:aci:)` — legacy tools (LINE/PLINE/CIRCLE/ARC/RECT/
///     POLYGON): always the NOVACAD-MARKUP layer, colored by the live
///     markup-color preference, exactly as before this phase.
///   - `.current(CurrentProperties resolved fields)` — Phase 6.3 tools
///     (ELLIPSE/SPLINE/POINT/FACE3D): CLAYER/CECOLOR/CELTYPE/CELTSCALE.
struct DraftContext {
    var layerId: Int32
    var aci: Int16
    var trueColor: UInt32 = 0xFF00_0000
    var linetypeId: Int16 = -1
    var ltScale: Float = 1.0
    var owner: OwnerRef
    /// Only needed by modes that intern strings (none of the CURRENT
    /// Phase 6.3 tools do — TEXT is still host-handled — but threaded
    /// through now so a future tool needs no signature change).
    var store: EntityStore?

    static func markup(layerId: Int32, aci: Int, isPaper: Bool, store: EntityStore?) -> DraftContext {
        DraftContext(layerId: layerId, aci: Int16(aci), owner: isPaper ? .paper : .model, store: store)
    }

    static func current(_ props: CurrentProperties, parsed: EditableParsedDocument, isPaper: Bool) -> DraftContext {
        DraftContext(layerId: props.resolvedLayerId(in: parsed), aci: props.aciOrByLayer,
                    linetypeId: props.resolvedLinetypeId(in: parsed), ltScale: Float(props.linetypeScale),
                    owner: isPaper ? .paper : .model, store: parsed.store)
    }

    func proto(_ type: DXFEntityType, _ payload: EntityPayloadCopy) -> EntityPrototype {
        EntityPrototype(type: type, layerId: layerId, aci: aci, trueColor: trueColor,
                        linetypeId: linetypeId, owner: owner, ltScale: ltScale, payload: payload)
    }

    /// Same as `proto(_:_:)`, but infers the DXF entity TYPE from the
    /// payload case itself — used by the spline finishers, which build an
    /// `EntityPayloadCopy` via `EntityCurveBridge.splinePayload(for:)`
    /// (already fully-formed) rather than constructing one inline.
    func protoRaw(_ payload: EntityPayloadCopy) -> EntityPrototype {
        let type: DXFEntityType
        switch payload {
        case .spline: type = .spline
        case .line: type = .line
        case .point: type = .point
        case .circle: type = .circle
        case .arc: type = .arc
        case .ellipse: type = .ellipse
        case .polyline: type = .lwpolyline
        case .text: type = .text
        case .mtext: type = .mtext
        case .insert: type = .insert
        case .hatch: type = .hatch
        case .image: type = .image
        case .viewport: type = .viewport
        case .dimension: type = .dimension
        case .unknown: type = .unknown
        }
        return proto(type, payload)
    }
}

// MARK: - Move (select + relocate markup with OSNAP)

/// Drives the two-click AutoCAD-style MOVE gesture: pick a base point on the
/// selection (often a corner/endpoint of the object being moved), then pick a
/// destination point; the selection translates by the vector between them so
/// the two snapped points land exactly on top of each other.
struct MoveState: Equatable {
    enum Phase: Equatable { case idle, pickingBase, pickingDestination }
    var phase: Phase = .idle
    var basePoint: CGPoint? = nil
    var hover: CGPoint? = nil
    var snap: SnapResult? = nil
    /// Entities being moved, snapshotted when the command starts. Stable
    /// `EntityID`s (Phase 1.7) — the Move tool now operates on ANY selected
    /// entity via `Transaction.modifyPayload`, not just markup, since
    /// markup is ordinary EntityStore content like everything else now.
    var objectIDs: Set<EntityID> = []

    var isActive: Bool { phase != .idle }

    var prompt: String {
        switch phase {
        case .idle: return ""
        case .pickingBase: return "MOVE — specify base point"
        case .pickingDestination: return "MOVE — specify destination point"
        }
    }
}

// MARK: - Object snapping (OSNAP)

struct SnapResult: Equatable {
    enum Kind: Equatable {
        case endpoint, midpoint, center, intersection, perpendicular, tangent
        var label: String {
            switch self {
            case .endpoint: return "Endpoint"
            case .midpoint: return "Midpoint"
            case .center: return "Center"
            case .intersection: return "Intersection"
            case .perpendicular: return "Perpendicular"
            case .tangent: return "Tangent"
            }
        }
    }
    var point: CGPoint
    var kind: Kind
}

enum Osnap {

    /// Finds the best snap near `wp`. Priorities: endpoint > intersection >
    /// midpoint/perpendicular > center/tangent. `from` (the current segment's
    /// start) enables perpendicular and tangent snaps. `excluding` (Phase
    /// 1.7) skips geometry belonging to the given entities — used by the
    /// Move tool's destination-pick so you never snap to the very object(s)
    /// you're dragging (their PRE-move position would otherwise be offered
    /// as a candidate, since the render model isn't updated until the move
    /// commits). Markup and ordinary drawing geometry are the same
    /// EntityStore content now, so this single path replaces the old
    /// document-only `snap` + markup-only `snapWithMarkup` split.
    static func snap(document: DXFDocument, usePaperSpace: Bool,
                     near wp: CGPoint, tolerance: CGFloat,
                     visibility: VisibilityState, from: CGPoint? = nil,
                     excluding: Set<EntityID> = []) -> SnapResult? {
        let groups = usePaperSpace ? document.paperGroups : document.modelGroups

        var segments: [(CGPoint, CGPoint)] = []
        var arcsNear: [StrokeStore.Arc] = []
        var best: (SnapResult, CGFloat, Int)? = nil    // result, dist, priority

        func consider(_ p: CGPoint, _ kind: SnapResult.Kind) {
            let d = hypot(p.x - wp.x, p.y - wp.y)
            guard d <= tolerance else { return }
            let pr = priority(for: kind)
            if let b = best {
                if pr < b.2 || (pr == b.2 && d < b.1) {
                    best = (SnapResult(point: p, kind: kind), d, pr)
                }
            } else {
                best = (SnapResult(point: p, kind: kind), d, pr)
            }
        }

        for g in groups {
            guard visibility.isSelectable(g) else { continue }
            guard g.bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(wp)
            else { continue }
            let pts = g.strokes.points

            for run in g.strokes.runs {
                if !excluding.isEmpty, run.entityId >= 0, excluding.contains(EntityID(raw: run.entityId)) { continue }
                guard run.bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(wp)
                else { continue }
                let s = Int(run.start), c = Int(run.count)
                for j in s..<(s + c) {
                    consider(pts[j], .endpoint)
                    if j < s + c - 1 {
                        let a = pts[j], b = pts[j + 1]
                        consider(CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2),
                                 .midpoint)
                        // Only keep segments near the cursor for intersection/perp.
                        if segments.count < 64,
                           distToSegment(wp, a, b) <= tolerance * 2 {
                            segments.append((a, b))
                        }
                    }
                }
                if run.closed, c > 2 {
                    let a = pts[s + c - 1], b = pts[s]
                    consider(CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2),
                             .midpoint)
                    if segments.count < 64, distToSegment(wp, a, b) <= tolerance * 2 {
                        segments.append((a, b))
                    }
                }
            }

            // Filled-area boundaries (solid/pattern HATCH) snap exactly like
            // stroked linework does. Without this, no OSNAP existed anywhere
            // on a shaded region — so extending/aligning to a shaded aisle
            // (`ShadeLayer` solid fill, the AI Assistant's aisle/dock
            // shading) had to be done by eye, even though those boundaries
            // are now fully grip-editable (see `GripEditing`'s `.hatch`
            // cases). Mirrors the `runs` loop above; fill runs are ALWAYS
            // closed (`addFillRun` hardcodes `closed: true`), so the
            // wrap-around edge is unconditional rather than run.closed-gated.
            let fillPts = g.strokes.fillPoints
            for run in g.strokes.fillRuns {
                if !excluding.isEmpty, run.entityId >= 0, excluding.contains(EntityID(raw: run.entityId)) { continue }
                guard run.bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(wp) else { continue }
                let s = Int(run.start), c = Int(run.count)
                guard c >= 3, s + c <= fillPts.count else { continue }
                for j in 0..<c {
                    let a = fillPts[s + j], b = fillPts[s + (j + 1) % c]
                    consider(a, .endpoint)
                    consider(CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), .midpoint)
                    if segments.count < 64, distToSegment(wp, a, b) <= tolerance * 2 {
                        segments.append((a, b))
                    }
                }
            }

            for arc in g.strokes.arcs {
                if !excluding.isEmpty, arc.entityId >= 0, excluding.contains(EntityID(raw: arc.entityId)) { continue }
                let dc = hypot(wp.x - arc.center.x, wp.y - arc.center.y)
                guard dc <= arc.radius + tolerance else { continue }
                consider(arc.center, .center)
                if arcsNear.count < 48 { arcsNear.append(arc) }
                if !arc.isFullCircle {
                    for deg in [arc.startAngleDeg, arc.endAngleDeg] {
                        let a = deg * .pi / 180
                        consider(CGPoint(x: arc.center.x + arc.radius * CoreGraphics.cos(a),
                                         y: arc.center.y + arc.radius * CoreGraphics.sin(a)),
                                 .endpoint)
                    }
                }
            }
        }

        // Segment-segment intersections near the cursor.
        if segments.count >= 2 {
            for i in 0..<(segments.count - 1) {
                for j in (i + 1)..<segments.count {
                    if let x = intersect(segments[i], segments[j]) {
                        consider(x, .intersection)
                    }
                }
            }
        }

        // Perpendicular and tangent require a reference point.
        if let from = from {
            for (a, b) in segments {
                let abx = b.x - a.x, aby = b.y - a.y
                let len2 = abx * abx + aby * aby
                guard len2 > 1e-12 else { continue }
                let t = ((from.x - a.x) * abx + (from.y - a.y) * aby) / len2
                let foot = CGPoint(x: a.x + t * abx, y: a.y + t * aby)
                consider(foot, .perpendicular)
            }
            for arc in arcsNear {
                for tp in tangentPoints(from: from, center: arc.center, radius: arc.radius) {
                    if arc.isFullCircle {
                        consider(tp, .tangent)
                    } else {
                        let ang = atan2(tp.y - arc.center.y, tp.x - arc.center.x) * 180 / .pi
                        if HitTester.angleWithinSweep(ang, from: arc.startAngleDeg,
                                                      to: arc.endAngleDeg) {
                            consider(tp, .tangent)
                        }
                    }
                }
            }
        }
        return best?.0
    }

    /// The two tangent points on a circle from an external point (empty if the
    /// point is inside the circle).
    private static func tangentPoints(from p: CGPoint, center c: CGPoint,
                                      radius r: CGFloat) -> [CGPoint] {
        let dx = p.x - c.x, dy = p.y - c.y
        let d = hypot(dx, dy)
        guard d > r + 1e-9, r > 1e-9 else { return [] }
        let base = atan2(dy, dx)
        let phi = acos(min(1, max(-1, r / d)))
        return [base + phi, base - phi].map {
            CGPoint(x: c.x + r * CoreGraphics.cos($0), y: c.y + r * CoreGraphics.sin($0))
        }
    }

    private static func distToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let abx = b.x - a.x, aby = b.y - a.y
        let len2 = abx * abx + aby * aby
        guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * abx + (p.y - a.y) * aby) / len2))
        return hypot(p.x - (a.x + t * abx), p.y - (a.y + t * aby))
    }

    private static func intersect(_ s1: (CGPoint, CGPoint),
                                  _ s2: (CGPoint, CGPoint)) -> CGPoint? {
        let (p, p2) = s1, (q, q2) = s2
        let r = CGPoint(x: p2.x - p.x, y: p2.y - p.y)
        let s = CGPoint(x: q2.x - q.x, y: q2.y - q.y)
        let denom = r.x * s.y - r.y * s.x
        guard abs(denom) > 1e-12 else { return nil }
        let t = ((q.x - p.x) * s.y - (q.y - p.y) * s.x) / denom
        let u = ((q.x - p.x) * r.y - (q.y - p.y) * r.x) / denom
        guard t >= 0, t <= 1, u >= 0, u <= 1 else { return nil }
        return CGPoint(x: p.x + t * r.x, y: p.y + t * r.y)
    }

    private static func priority(for kind: SnapResult.Kind) -> Int {
        switch kind {
        case .endpoint: return 0
        case .intersection: return 1
        case .midpoint, .perpendicular: return 2
        case .center, .tangent: return 3
        }
    }

    private static func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }
}

// MARK: - Command palette

enum CommandAction: Equatable {
    case tool(DraftState.Mode)
    case measureDistance, measureArea, measureRadius, measureAngle
    case selectMode
    case moveTool
    /// Phase 4.2: activates COPY/ROTATE/SCALE/MIRROR's `ModifyToolState`.
    /// MOVE deliberately stays on `.moveTool`/`MoveState` — see
    /// `ModifyToolState.swift`'s header comment for why.
    case modify(ModifyCommand)
    /// Phase 4.3: activates TRIM/EXTEND's `TrimExtendToolState` — see that
    /// type's header comment for why it's a third, separate state shape
    /// alongside `ModifyToolState`/`MoveState`.
    case trimExtend(TrimExtendCommand)
    /// STRETCH (new feature) — activates `StretchToolState`. See that
    /// type's header comment for why it's a fourth, separate state shape
    /// (crossing-window vertex acquisition, not whole-entity acquisition).
    case stretch
    /// Phase 4.4: activates FILLET/CHAMFER's `FilletChamferToolState`.
    case filletChamfer(FilletChamferCommand)
    /// Phase 4.5: activates OFFSET's `OffsetToolState`.
    case offset
    /// Activates DIMENSION's `DimensionToolState` — linear or aligned.
    case dimension(DimensionKind)
    /// Phase 6.1: activates BLOCK/INSERT's `BlockToolState`. INSERT's own
    /// block-name picker (a Menu, mirroring the Stamp tool's) runs BEFORE
    /// this action fires for the INSERT case — see ContentView's registry
    /// wiring — so `.blockCommand(.insert)` alone (with no name yet chosen)
    /// is reachable only via the command bar's bare "INSERT"/"I" text entry,
    /// which opens the SAME picker rather than immediately activating
    /// `BlockToolState` with no name.
    case blockCommand(BlockCommand)
    /// Phase 6.1: ATTDEF — defines a new attribute inside an existing block
    /// (see `BlockToolState`'s doc comment on scope: no BEDIT session exists
    /// yet, so this command prompts for a target block name directly rather
    /// than requiring an open block-edit context).
    case attdef
    /// Phase 6.1: ATTEDIT — pick an INSERT to open its attribute editor
    /// sheet (the same sheet a double-click on an attributed INSERT opens).
    case attedit
    /// Phase 6.2: EXPLODE — see `ContentView.startExplode`.
    case explode
    /// JOIN (new feature) — merges a selection of connected/collinear
    /// lines/arcs/polylines into a single entity. See `ContentView.startJoin`.
    case join
    /// Phase 6.4: ARRAY — see `ContentView.startArray`.
    case array
    /// Phase 6.3: CLAYER — see `ContentView.startClayerEntry`.
    case clayer
    /// Cross-drawing Copy/Paste (new feature) — see `CrossDocumentPaste.swift`'s
    /// header comment for the overall design. `.clipboardCopy` writes the
    /// current selection to `NSPasteboard`; `.clipboardPaste` reads it back
    /// and enters click-to-place mode (`ContentView.startClipboardPaste`).
    /// Deliberately DISTINCT from `.modify(.copy)` (the existing same-
    /// drawing interactive multi-copy tool, unaffected by this feature —
    /// see this session's own product decision) — these are two different
    /// commands that both happen to be called "copy," matching how real
    /// AutoCAD itself has both COPYCLIP (⌘C-equivalent) and COPY (the
    /// interactive command) as genuinely separate commands.
    case clipboardCopy
    case clipboardPaste
    /// Data Extraction (AutoCAD DATAEXTRACTION / "dx") — see
    /// `DataExtraction.swift`. `.extractData` exports every entity's data +
    /// INSERT attributes to a CSV; `.importData` reads an edited CSV back
    /// and bulk-applies the changes. A one-shot command pair like
    /// `.save`/`.saveAs`, dispatched to `ContentView.extractDataToCSV()` /
    /// `importDataFromCSV()`.
    case extractData
    case importData
    /// Writes ALL live edits (moves/copies/arrays/blocks/new entities/etc,
    /// not just markup) back to `document.sourceDXFURL` via
    /// `DXFStructuralWriter` — see `ContentView.saveDrawing`. Distinct from
    /// the older "Export Markup as DXF"/"Save Copy with Markup" (still
    /// `DXFWriter.writeMarkupDXF`/`writeMergedCopy`, markup-only, old path).
    case save
    /// Same as `.save` but always prompts for a destination via
    /// `NSSavePanel` — see `ContentView.saveDrawingAs`.
    case saveAs
    case zoomFit
    case closePolyline
    case undo
    case point(CGPoint)         // absolute coordinates
    case relative(dx: CGFloat, dy: CGFloat)
    case length(CGFloat)        // distance along current hover direction
    /// Phase 4.2: a bare typed number, recognized as a scale factor or
    /// rotation angle ONLY when `PromptContext.expectsScalar` says a modify
    /// command is actively asking for one — see `parse(_:context:)`.
    case scalar(Double)
    case unknown(String)
}

/// What the command bar should interpret a bare typed number AS — the same
/// numeric-looking input ("90", "2.5") means different things depending on
/// what's active: a drafting tool wants `.length` (distance along the
/// current hover direction), while an active ROTATE/SCALE prompt wants
/// `.scalar` (the angle/factor itself, not a distance). Mirrors how
/// `ContentView.executeCommand`'s existing SETVAR-shortcut gate already
/// checks ambient tool state before deciding how to interpret an input —
/// this is the same idea applied to `CommandParser` itself instead of only
/// at the call site.
struct PromptContext {
    /// True while a ROTATE/SCALE `ModifyToolState` is in `.pickAngle`/
    /// `.pickFactor` and has no reference-point-based value yet — a bare
    /// number should resolve to `.scalar`, not fall through to `.length`
    /// (which would otherwise misinterpret "90" as "90 drawing units in the
    /// hover direction" instead of "rotate by 90 degrees").
    var expectsScalar: Bool = false

    static let none = PromptContext()
}

enum CommandParser {

    /// Parses a command-palette entry: AutoCAD shortcuts or coordinate
    /// input. `context` disambiguates a bare number between `.length`
    /// (default — matches every pre-Phase-4.2 caller unchanged) and
    /// `.scalar` (when a modify command's angle/factor prompt is active).
    static func parse(_ input: String, context: PromptContext = .none) -> CommandAction {
        let t = input.trimmingCharacters(in: .whitespaces).uppercased()
        guard !t.isEmpty else { return .unknown("") }

        // Single source of truth for every recognized command name/alias —
        // see CommandRegistry.swift. Behavior-preserving refactor of what
        // used to be an inline switch statement here.
        if let spec = CommandRegistry.resolve(t) { return spec.action }

        // Coordinate input: "@dx,dy" relative, "x,y" absolute, "123.4" length/scalar.
        var body = t
        var isRelative = false
        if body.hasPrefix("@") { isRelative = true; body.removeFirst() }
        let parts = body.split(separator: ",").map {
            Double($0.trimmingCharacters(in: .whitespaces))
        }
        if parts.count == 2, let x = parts[0], let y = parts[1] {
            return isRelative ? .relative(dx: x, dy: y)
                              : .point(CGPoint(x: x, y: y))
        }
        if parts.count == 1, let v = parts[0], !isRelative {
            return context.expectsScalar ? .scalar(v) : .length(CGFloat(v))
        }
        return .unknown(input)
    }
}
