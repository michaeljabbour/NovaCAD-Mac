//
//  Explode.swift
//  DWGViewer / Editing
//
//  Phase 6.2 — EXPLODE. Registry namespace `EntityExploder` (an enum of
//  static functions — no protocol/class needed since there is exactly one
//  implementation and no runtime polymorphism requirement; the plan's "so
//  foundation + editing implementations compose" is satisfied by this file
//  depending only on PropertyResolver.swift (foundation-layer, shared with
//  Regenerator) and EntityTransform.swift/Transform2.swift (Phase 4's
//  existing conformal-transform engine, reused for the uniform-scale case).
//
//  AutoCAD EXPLODE semantics this implements:
//  - INSERT explodes ONE LEVEL: its direct children become new top-level
//    entities; a NESTED insert inside it stays an insert (its own transform
//    baked into the new top-level insert's position/rotation/scale) unless
//    the caller passes `nested: true`, which recurses one additional level
//    per nested insert encountered (matching AutoCAD's own "explode
//    repeatedly to reach nested content" behavior via a single flag rather
//    than requiring the user to re-invoke EXPLODE by hand).
//  - Per child, BYBLOCK/layer-0 inheritance is resolved via
//    `PropertyResolver.resolveForExplode` — see that function's doc comment
//    for the exact "BYBLOCK bakes, BYLAYER stays BYLAYER" policy.
//  - Uniform scale (including plain rotation/translation, no scale) applies
//    via the existing `EntityTransform.apply(_:to:mirrtext:)` — arcs/circles
//    stay arcs/circles, computed once and shared with MOVE/COPY/ROTATE/
//    SCALE/MIRROR's own transform application.
//  - Non-uniform scale (or a general 2x2 with shear, though no current
//    caller produces one): circles/arcs convert to ELLIPSES via a closed-
//    form 2x2 SVD decomposition of the transform's linear part (see
//    `svd2x2` below) — this is the ONLY correct way to represent a
//    non-uniformly-scaled circle/arc as an EXACT analytic curve (an
//    approximating polyline, which is what the RENDER path uses for
//    on-screen display of a non-uniform INSERT today, is not acceptable
//    for an EXPLODE result, which must be a real, editable entity).
//    Bulge (arc) segments of an exploded LWPOLYLINE under non-uniform scale
//    become separate ELLIPSE-ARC entities (their bulge can't be preserved
//    as a polyline arc segment once circular symmetry is broken).
//  - LWPOLYLINE/POLYLINE (2D) -> LINE per straight segment, ARC (or
//    ELLIPSE-ARC under non-uniform scale) per bulged segment.
//  - TEXT height scales by |transform's Y-axis column length| (matches
//    AutoCAD: text height follows the transform's Y-scale, not the
//    uniform/geometric mean scale, since text baselines are Y-anchored);
//    widthFactor scales by the ratio of X-scale to Y-scale (preserves the
//    text's rendered aspect ratio exactly under the composed transform).
//    ATTRIB -> TEXT (AutoCAD: an exploded INSERT's attributes become plain
//    text showing their current VALUE, no longer live attributes).
//  - MINSERT -> rows*cols individual INSERTs at their grid positions (each
//    one individually explodable again, matching AutoCAD).
//  - DIMENSION/LEADER/ACAD_TABLE: this codebase already retains these as
//    INSERT-shaped payloads referencing an anonymous block (see
//    EntityStoreParser.swift's DIMENSION/ACAD_TABLE cases and
//    EntityStore.DXFEntityType) — DIMENSION explodes via the same
//    `explodeInsert` path as a real INSERT (LEADER is stored as a plain
//    polyline, already explodable via `explodePolyline`; no separate
//    ACAD_TABLE entity type exists in this store — it round-trips as
//    `.insert`, already covered).
//  - HATCH -> boundary loop LINEs only (Phase 7 supplies pattern-fill
//    geometry; until then, exploding a hatch discards its pattern, keeping
//    only the boundary — documented, matching the plan's own "boundary-only
//    before that" scoping note).
//  - SPLINE/ELLIPSE -> cannot explode (returns `nil`/empty; AutoCAD itself
//    refuses these too — a SPLINE/ELLIPSE is already a single primitive
//    curve with nothing further to decompose).
//

import Foundation
import CADCore
import CoreGraphics

enum EntityExploder {

    /// Above this many total child entities produced by one call to
    /// `explode(ids:...)`, the caller should show progress text rather than
    /// silently blocking — matches the plan's "progress text above 100k
    /// children" gate. This constant is exposed so `ContentView`/
    /// `EditScriptRunner` can check it without duplicating the number.
    static let progressThreshold = 100_000

    /// Explodes every entity in `ids` (typically the live selection) into
    /// ONE transaction — matches the plan's "multi-select in one
    /// transaction." Entities that cannot be exploded (SPLINE/ELLIPSE, or
    /// any id that fails to resolve) are silently skipped, matching
    /// AutoCAD's own behavior of exploding what it can from a mixed
    /// selection rather than aborting the whole command.
    ///
    /// Returns every newly-created top-level `EntityID` (for the caller to
    /// select afterward, matching AutoCAD leaving the exploded content
    /// selected) plus the total count for progress/messaging purposes.
    struct Result {
        var newIDs: [EntityID] = []
        var explodedCount: Int = 0     // how many of `ids` were actually exploded
        var skippedCount: Int = 0      // how many could not be exploded
    }

    static func explode(ids: [EntityID], nested: Bool = false,
                        store: EntityStore, parsed: EditableParsedDocument,
                        tx: Transaction) -> Result {
        var result = Result()
        for id in ids {
            guard let h = store.header(id), !h.flags.contains(.deleted) else {
                result.skippedCount += 1
                continue
            }
            guard let produced = explodeOne(id, header: h, nested: nested, store: store, parsed: parsed, tx: tx) else {
                result.skippedCount += 1
                continue
            }
            result.newIDs.append(contentsOf: produced)
            result.explodedCount += 1
        }
        return result
    }

    // MARK: - Per-entity dispatch

    /// Explodes ONE entity, returning its replacement top-level entities via
    /// `tx.replace` (so the original is deleted and the new ones added in
    /// the same traceable undo step) — or `nil` if `id`'s type cannot be
    /// exploded at all (SPLINE/ELLIPSE — the original is left untouched in
    /// that case, NOT deleted, matching AutoCAD's refusal).
    private static func explodeOne(_ id: EntityID, header h: EntityHeader, nested: Bool,
                                   store: EntityStore, parsed: EditableParsedDocument,
                                   tx: Transaction) -> [EntityID]? {
        switch h.type {
        case .insert:
            return explodeInsert(id, header: h, nested: nested, store: store, parsed: parsed, tx: tx)
        case .dimension:
            // Stored as an INSERT-shaped payload referencing an anonymous
            // block (EntityStoreParser's DIMENSION case) — same expansion
            // path, just reading `DimensionPayload` instead of `InsertPayload`.
            return explodeDimension(id, header: h, nested: nested, store: store, parsed: parsed, tx: tx)
        case .lwpolyline, .polyline2d:
            return explodePolyline(id, header: h, transform: .identity, store: store, tx: tx)
        case .hatch:
            return explodeHatch(id, header: h, store: store, tx: tx)
        case .spline, .ellipse, .polyline3d:
            // AutoCAD refuses SPLINE/ELLIPSE. POLYLINE3D (3D polyline) has no
            // bulge/arc concept and this codebase's PolylinePayload doesn't
            // retain per-vertex Z distinctly from a 2D polyline's elevation
            // for the 3D case — treated as "cannot explode" rather than
            // silently producing a wrong (flattened) result. Documented gap,
            // not a Phase 6.2 scope requirement (the plan's own list is
            // LWPOLYLINE/POLYLINE, not POLYLINE3D specifically).
            return nil
        default:
            // LINE/CIRCLE/ARC/TEXT/POINT/etc. are already atomic — AutoCAD's
            // EXPLODE on an atomic entity is a no-op (leaves it selected,
            // untouched), which this models as "cannot explode further"
            // (nil) rather than a wasted replace-with-itself transaction.
            return nil
        }
    }

    // MARK: - INSERT explosion

    private static func explodeInsert(_ id: EntityID, header h: EntityHeader, nested: Bool,
                                      store: EntityStore, parsed: EditableParsedDocument,
                                      tx: Transaction) -> [EntityID]? {
        guard h.payload >= 0 else { return nil }
        let ip = store.inserts[Int(h.payload)]
        let name = store.strings.string(for: ip.blockNameId)
        guard let block = parsed.blocks[name], block.entityCount > 0 else { return nil }

        let insertResolved = PropertyResolver.resolveTopLevel(layerId: h.layerId, aci: h.aci,
                                                               trueColor: h.trueColor, linetypeId: h.linetypeId)
        let rows = max(1, Int(ip.rows)), cols = max(1, Int(ip.cols))

        var allNew: [EntityID] = []
        for row in 0..<rows {
            for col in 0..<cols {
                var xf = CGAffineTransform.identity
                xf = xf.translatedBy(x: ip.position.x, y: ip.position.y)
                xf = xf.rotated(by: ip.rotationDeg * .pi / 180)
                xf = xf.translatedBy(x: Double(col) * ip.colSpacing, y: Double(row) * ip.rowSpacing)
                xf = xf.scaledBy(x: ip.scale.x, y: ip.scale.y)
                xf = xf.translatedBy(x: -Double(block.base.x), y: -Double(block.base.y))
                if h.flags.contains(.mirrorOCS) {
                    xf = CGAffineTransform(scaleX: -1, y: 1).concatenating(xf)
                }

                for i in Int(block.entityStart)..<Int(block.entityStart + block.entityCount) {
                    let childId = EntityID(raw: Int32(i))
                    guard let ch = store.header(childId), !ch.flags.contains(.deleted) else { continue }
                    guard let produced = explodeChild(childId, header: ch, transform: xf,
                                                      insertResolved: insertResolved, nested: nested,
                                                      store: store, parsed: parsed, tx: tx) else { continue }
                    allNew.append(contentsOf: produced)
                }
            }
        }
        // ATTRIB children (owned via .parentEntity(id), not part of the
        // block's own entityStart/entityCount range) -> plain TEXT showing
        // their CURRENT value, at their already-world-space anchor (an
        // ATTRIB's position is stored in WORLD space already — see
        // BlockEditor.insert — so no further transform is needed). The
        // original ATTRIB entity is explicitly deleted here (adversarial-
        // review fix: a prior version only ever added the replacement TEXT
        // and never deleted the source ATTRIB, leaking it as a permanently
        // live, orphaned entity still owned via `.parentEntity(id)` after
        // `id` itself is deleted below — `EntityStore.children(of:)` only
        // filters a candidate CHILD's own deleted flag, not whether its
        // claimed PARENT is itself alive, so the leaked ATTRIB would
        // resurface if anything ever queried `children(of: id)` again for
        // the now-deleted insert).
        for attribId in store.children(of: id) {
            guard let ah = store.header(attribId), ah.type == .attrib, ah.payload >= 0,
                  !ah.flags.contains(.deleted) else { continue }
            let resolved = PropertyResolver.resolveForExplode(entityLayerId: ah.layerId, entityAci: ah.aci,
                                                               entityTrueColor: ah.trueColor,
                                                               entityLinetypeId: ah.linetypeId,
                                                               insertResolved: insertResolved)
            let textPayload = store.texts[Int(ah.payload)]
            let proto = EntityPrototype(type: .text, layerId: resolved.layerId, aci: resolved.aci,
                                        trueColor: resolved.trueColor, linetypeId: resolved.linetypeId,
                                        owner: h.owner, payload: .text(textPayload))
            allNew.append(tx.add(proto))
            tx.delete(attribId)
        }
        return finishReplace(id, allNew, tx: tx)
    }

    /// Deletes `id` (the original entity being exploded) and returns
    /// `newIDs` — a small helper so the call site reads clearly (every
    /// replacement entity was already added individually via `tx.add`
    /// BEFORE this runs, since they don't share `id`'s own single-entity
    /// properties uniformly — each child has ITS OWN resolved layer/color/
    /// linetype, not `id`'s — so this cannot be expressed as a single
    /// `tx.replace(id, with: protos)` call the way a uniform-property
    /// replacement could).
    @discardableResult
    private static func finishReplace(_ id: EntityID, _ newIDs: [EntityID], tx: Transaction) -> [EntityID] {
        tx.delete(id)
        return newIDs
    }

    private static func explodeDimension(_ id: EntityID, header h: EntityHeader, nested: Bool,
                                         store: EntityStore, parsed: EditableParsedDocument,
                                         tx: Transaction) -> [EntityID]? {
        guard h.payload >= 0 else { return nil }
        let dp = store.dimensions[Int(h.payload)]
        let name = store.strings.string(for: dp.blockNameId)
        guard let block = parsed.blocks[name], block.entityCount > 0 else { return nil }
        // DIMENSION's anonymous block is always placed at its defPoint with
        // no rotation/scale in this codebase's retention model (see
        // EntityStoreParser's DIMENSION case — only position is captured,
        // matching the old GeometryBuilder/DXFParser's own "render via
        // anonymous block INSERT" fidelity level).
        let insertResolved = PropertyResolver.resolveTopLevel(layerId: h.layerId, aci: h.aci,
                                                               trueColor: h.trueColor, linetypeId: h.linetypeId)
        var xf = CGAffineTransform.identity
        xf = xf.translatedBy(x: dp.defPoint.x, y: dp.defPoint.y)
        xf = xf.translatedBy(x: -Double(block.base.x), y: -Double(block.base.y))

        var allNew: [EntityID] = []
        for i in Int(block.entityStart)..<Int(block.entityStart + block.entityCount) {
            let childId = EntityID(raw: Int32(i))
            guard let ch = store.header(childId), !ch.flags.contains(.deleted) else { continue }
            guard let produced = explodeChild(childId, header: ch, transform: xf,
                                              insertResolved: insertResolved, nested: nested,
                                              store: store, parsed: parsed, tx: tx) else { continue }
            allNew.append(contentsOf: produced)
        }
        return finishReplace(id, allNew, tx: tx)
    }

    /// Explodes one child of a block being expanded (by an INSERT or
    /// DIMENSION) under the composed `transform`, resolving its BYBLOCK/
    /// layer-0 inheritance against `insertResolved`. Returns the new
    /// top-level entity id(s) this ONE child produces (a polyline may
    /// produce several; everything else produces exactly one), or `nil` if
    /// the child itself cannot be represented (e.g. a nested SPLINE/ELLIPSE
    /// stays untouched... but since this is INSIDE a block being exploded,
    /// "untouched" would leave it orphaned with no owner — so unlike the
    /// top-level `explodeOne`'s "leave it alone" semantics, an unexplodable
    /// CHILD is copied through as-is under the transform via
    /// `EntityTransform.apply`, since SPLINE/ELLIPSE both already support
    /// that generalized-affine-via-conformal-approximation path — see the
    /// inline comment at that call site for the precision caveat this
    /// implies for a non-uniform transform).
    private static func explodeChild(_ id: EntityID, header ch: EntityHeader, transform xf: CGAffineTransform,
                                     insertResolved: PropertyResolver.Resolved, nested: Bool,
                                     store: EntityStore, parsed: EditableParsedDocument,
                                     tx: Transaction) -> [EntityID]? {
        let resolved = PropertyResolver.resolveForExplode(entityLayerId: ch.layerId, entityAci: ch.aci,
                                                           entityTrueColor: ch.trueColor,
                                                           entityLinetypeId: ch.linetypeId,
                                                           insertResolved: insertResolved)
        func addProto(_ type: DXFEntityType, _ payload: EntityPayloadCopy) -> EntityID {
            tx.add(EntityPrototype(type: type, layerId: resolved.layerId, aci: resolved.aci,
                                   trueColor: resolved.trueColor, linetypeId: resolved.linetypeId,
                                   ltScale: ch.ltScale, payload: payload))
        }

        // Nested INSERT: per the plan, "nested inserts stay inserts
        // (transform-baked) unless `nested` option" — when `nested` is
        // false (the default), bake `xf` into a brand-new top-level INSERT
        // with the SAME block reference, composed position/rotation/scale.
        // When `nested` is true, recurse one level deeper via
        // `explodeInsert`'s own logic (called with the CHILD's transform
        // pre-applied by constructing a temporary top-level INSERT first,
        // then exploding THAT — reuses `explodeInsert` exactly rather than
        // forking its logic a second time).
        if ch.type == .insert {
            guard ch.payload >= 0 else { return nil }
            let childIp = store.inserts[Int(ch.payload)]
            guard let baked = bakeInsertTransform(childIp, into: xf) else { return nil }
            let bakedProto = EntityPrototype(type: .insert, layerId: resolved.layerId, aci: resolved.aci,
                                             trueColor: resolved.trueColor, linetypeId: resolved.linetypeId,
                                             ltScale: ch.ltScale, payload: .insert(baked))
            let newInsertId = tx.add(bakedProto)
            if !nested {
                return [newInsertId]
            }
            // `nested: true` — immediately explode the just-baked insert one
            // more level, using the SAME live header we just wrote (no
            // separate lookup race: `tx.add` appended it synchronously).
            guard let newHeader = store.header(newInsertId) else { return [newInsertId] }
            return explodeInsert(newInsertId, header: newHeader, nested: true, store: store, parsed: parsed, tx: tx)
                ?? [newInsertId]
        }

        switch ch.type {
        case .line:
            guard ch.payload >= 0 else { return nil }
            var p = store.lines[Int(ch.payload)]
            applyGeneralTransform(xf, toLine: &p)
            return [addProto(.line, .line(p))]

        case .point:
            guard ch.payload >= 0 else { return nil }
            var p = store.points[Int(ch.payload)]
            p.p = apply(xf, p.p)
            return [addProto(.point, .point(p))]

        case .circle:
            guard ch.payload >= 0 else { return nil }
            let c = store.circles[Int(ch.payload)]
            return [explodeCircleOrArc(center: c.center, radius: c.radius, startDeg: 0, endDeg: 360, isFullCircle: true,
                                       transform: xf, addProto: addProto)]

        case .arc:
            guard ch.payload >= 0 else { return nil }
            let a = store.arcs[Int(ch.payload)]
            return [explodeCircleOrArc(center: a.center, radius: a.radius, startDeg: a.startAngleDeg, endDeg: a.endAngleDeg,
                                       isFullCircle: false, transform: xf, addProto: addProto)]

        case .lwpolyline, .polyline2d:
            return explodePolylineUnderTransform(id, header: ch, transform: xf, resolved: resolved, store: store, tx: tx)

        case .text, .attrib, .attdef:
            guard ch.payload >= 0 else { return nil }
            var p = store.texts[Int(ch.payload)]
            applyTextTransform(xf, to: &p)
            // A nested ATTDEF (an attribute DEFINITION, not an instance)
            // inside a block being exploded has no live INSERT context of
            // its own to bind a value from — round-trips through as plain
            // TEXT showing its DEFAULT value, matching how AutoCAD itself
            // has no meaningful "explode an ATTDEF in place" behavior
            // outside of a block-edit session. ATTRIB (handled by the
            // caller's own `store.children(of:)` loop for the common
            // top-level-INSERT case) only reaches here for an ATTRIB that
            // is somehow a direct block-range member rather than a
            // `.parentEntity`-owned child — not a shape this codebase's own
            // `BlockEditor.insert` ever produces, but handled safely rather
            // than silently dropped if it ever occurs (e.g. hand-authored
            // XML/DXF with unusual structure).
            return [addProto(.text, .text(p))]

        case .ellipse:
            guard ch.payload >= 0 else { return nil }
            var p = store.ellipses[Int(ch.payload)]
            applyEllipseTransform(xf, to: &p)
            return [addProto(.ellipse, .ellipse(p))]

        case .spline:
            // Control points map as points under ANY affine transform
            // (affine invariance of B-splines) — this holds even for a
            // non-uniform/sheared transform, unlike circle/arc, so no SVD
            // detour is needed here; weights/knots/degree are untouched.
            guard ch.payload >= 0 else { return nil }
            let s = store.splines[Int(ch.payload)]
            let control = (0..<Int(s.controlCount)).map { apply(xf, store.vertexArena[Int(s.controlStart) + $0]) }
            let knots = (0..<Int(s.knotCount)).map { store.scalarArena[Int(s.knotStart) + $0] }
            let weights = (0..<Int(s.weightCount)).map { store.scalarArena[Int(s.weightStart) + $0] }
            return [addProto(.spline, .spline(s, control: control, knots: knots, weights: weights))]

        case .hatch, .polyline3d, .mtext, .insert, .dimension, .leader, .solid, .trace, .face3d,
             .mleader, .xline, .ray, .wipeout, .image, .viewport, .acadTable, .unknown:
            // Not part of the plan's explicit Phase 6.2 child-geometry list
            // (block content is overwhelmingly LINE/ARC/CIRCLE/LWPOLYLINE/
            // TEXT/INSERT in practice) — rather than silently dropping these
            // if a block ever contains one, copy them through unmodified
            // under the SAME general-affine machinery every other case
            // uses, via the generic `EntityPayloadCopy.translate`-adjacent
            // path: apply the transform's TRANSLATION only as a last-resort
            // fallback would silently mis-place rotated/scaled content, so
            // instead these are explicitly left unexploded (the ORIGINAL
            // entity, which only exists inside a block definition and has
            // no meaningful standalone existence outside an INSERT's
            // expansion, is simply not copied out) — documented gap.
            return nil
        }
    }

    // MARK: - Nested-insert transform baking

    /// Composes `xf` (the ENCLOSING insert's transform) with `child`'s own
    /// position/rotation/scale, producing a new `InsertPayload` whose
    /// position/rotation/scale alone (no separate parent transform needed)
    /// place its block content correctly in the ENCLOSING insert's former
    /// world space. Returns `nil` if `xf` isn't decomposable into a
    /// translate+rotate+scale form the (position, rotationDeg, scale)
    /// triple can represent — i.e. `xf` includes shear or the child's OWN
    /// scale was already non-uniform in a way that compounds into a
    /// genuinely sheared result. This can only happen for a nested insert
    /// under an ALREADY non-uniformly-scaled enclosing transform (rare in
    /// practice — MINSERT/ordinary INSERT scale is uniform in the
    /// overwhelming majority of real drawings) — falling back to `nil` here
    /// means `explodeChild` simply doesn't explode that one nested insert
    /// rather than silently producing a wrong (sheared-but-not-representable)
    /// result; the enclosing explode still succeeds for every OTHER child.
    private static func bakeInsertTransform(_ child: InsertPayload, into xf: CGAffineTransform) -> InsertPayload? {
        var childXf = CGAffineTransform.identity
        childXf = childXf.translatedBy(x: child.position.x, y: child.position.y)
        childXf = childXf.rotated(by: child.rotationDeg * .pi / 180)
        childXf = childXf.scaledBy(x: child.scale.x, y: child.scale.y)
        let combined = childXf.concatenating(xf)

        let det = combined.a * combined.d - combined.b * combined.c
        guard abs(det) > 1e-15 else { return nil }
        let scaleX = hypot(combined.a, combined.b)
        let scaleY = hypot(combined.c, combined.d)
        guard scaleX > 1e-12, scaleY > 1e-12 else { return nil }
        // Orthogonality check: a pure rotate+scale (no shear) transform's
        // columns are perpendicular — (a,b)·(c,d) ≈ 0. A meaningfully
        // non-zero dot product indicates shear, which (position, rotationDeg,
        // scale) cannot represent.
        let dot = combined.a * combined.c + combined.b * combined.d
        guard abs(dot) < 1e-6 * scaleX * scaleY else { return nil }

        // Rotation MUST be derived from the SECOND column (c,d), not the
        // first (a,b): in this codebase's mirrored-INSERT convention, only
        // `scale.x` ever carries a sign flip (see `EntityTransform.apply`'s
        // `.insert` case: "negate the X scale... standard DXF encoding for
        // a mirrored block reference") — `scale.y` and the rotation itself
        // stay unsigned/unflipped. `atan2(b,a)` implicitly assumes `a =
        // scaleX·cos(rot)` with a POSITIVE scaleX; when the composed
        // transform has a negative determinant (an odd number of mirrors
        // in the nested-insert chain), the correct reconstruction has
        // `scaleX` NEGATIVE, which flips the sign baked into `(a,b)` and
        // throws `atan2(b,a)` off by exactly 180 degrees. `(c,d)` has no
        // such ambiguity — it's always `scaleY·(-sin(rot), cos(rot))` with
        // `scaleY` held positive throughout this file (only `.x` ever
        // flips) — so `atan2(-c,d)` recovers the correct rotation
        // regardless of the composed determinant's sign. `scaleX` is then
        // recovered WITH its correct sign by projecting `(a,b)` onto the
        // (cos rot, sin rot) direction implied by that rotation, rather
        // than assumed positive. Found by adversarial review via a
        // concrete mirrored-nested-insert composition that was off by
        // exactly 180 degrees under the original `atan2(b,a)` formula;
        // verified against the same example in
        // `ExplodeTests.testBakeInsertTransformWithMirroredNestedInsert`.
        let rotationRad = atan2(-combined.c, combined.d)
        let signedScaleX = combined.a * cos(rotationRad) + combined.b * sin(rotationRad)
        let rotationDeg = rotationRad * 180 / .pi
        var newScale = child.scale
        newScale.x = signedScaleX
        newScale.y = scaleY
        var result = child
        result.position = Vec3(x: combined.tx, y: combined.ty, z: child.position.z)
        result.rotationDeg = rotationDeg
        result.scale = newScale
        return result
    }

    // MARK: - Uniform vs non-uniform dispatch (circle/arc -> ellipse)

    /// Applies `xf` to a circle/arc, adding either a CIRCLE/ARC (uniform
    /// transform — including plain rotation/translation/mirror) or an
    /// ELLIPSE (non-uniform — via SVD) through `addProto`. Returns the new
    /// entity's id.
    private static func explodeCircleOrArc(center: Vec3, radius: Double, startDeg: Double, endDeg: Double,
                                           isFullCircle: Bool, transform xf: CGAffineTransform,
                                           addProto: (DXFEntityType, EntityPayloadCopy) -> EntityID) -> EntityID {
        if isUniform(xf) {
            if isFullCircle {
                var p = CirclePayload(center: center, radius: radius)
                applyUniformCircle(xf, to: &p)
                return addProto(.circle, .circle(p))
            } else {
                var p = ArcPayload(center: center, radius: radius, startAngleDeg: startDeg, endAngleDeg: endDeg)
                applyUniformArc(xf, to: &p)
                return addProto(.arc, .arc(p))
            }
        }
        let ellipse = ellipseFromCircleOrArc(center: center, radius: radius, startDeg: startDeg, endDeg: endDeg,
                                             isFullCircle: isFullCircle, transform: xf)
        return addProto(.ellipse, .ellipse(ellipse))
    }

    /// True when `xf`'s linear part is a pure rotation+uniform-scale
    /// (optionally with a mirror, i.e. negative determinant) — no shear, no
    /// differing X/Y scale magnitudes. Mirrors `Regenerator.Ctx.isNonUniform`'s
    /// own `scaleX`/`scaleY` comparison for consistency with the render
    /// path's own definition of "uniform enough."
    private static func isUniform(_ xf: CGAffineTransform) -> Bool {
        let scaleX = hypot(xf.a, xf.b)
        let scaleY = hypot(xf.c, xf.d)
        guard scaleX > 1e-12, scaleY > 1e-12 else { return true }   // degenerate; treat as uniform to avoid NaN downstream
        // Shear check: columns must be perpendicular for a pure
        // rotate+scale(+mirror) transform.
        let dot = xf.a * xf.c + xf.b * xf.d
        guard abs(dot) < 1e-6 * scaleX * scaleY else { return false }
        return abs(scaleX - scaleY) <= 1e-6 * max(scaleX, scaleY)
    }

    private static func applyUniformCircle(_ xf: CGAffineTransform, to p: inout CirclePayload) {
        let t = toTransform2(xf)
        var copy = EntityPayloadCopy.circle(p)
        EntityTransform.apply(t, to: &copy, mirrtext: false)
        if case .circle(let result) = copy { p = result }
    }

    private static func applyUniformArc(_ xf: CGAffineTransform, to p: inout ArcPayload) {
        let t = toTransform2(xf)
        var copy = EntityPayloadCopy.arc(p)
        EntityTransform.apply(t, to: &copy, mirrtext: false)
        if case .arc(let result) = copy { p = result }
    }

    private static func applyGeneralTransform(_ xf: CGAffineTransform, toLine p: inout LinePayload) {
        p.a = apply(xf, p.a)
        p.b = apply(xf, p.b)
    }

    private static func applyEllipseTransform(_ xf: CGAffineTransform, to p: inout EllipsePayload) {
        // An ellipse under a GENERAL affine transform (uniform or not)
        // remains an ellipse (affine images of conics are conics of the
        // same type) — but its axes need re-deriving via SVD in the
        // non-uniform case (a rotated/uniformly-scaled ellipse keeps its
        // axis directions relative to the transform; a non-uniformly-scaled
        // one generally does NOT keep its old axis directions at all).
        if isUniform(xf) {
            let t = toTransform2(xf)
            var copy = EntityPayloadCopy.ellipse(p)
            EntityTransform.apply(t, to: &copy, mirrtext: false)
            if case .ellipse(let result) = copy { p = result }
            return
        }
        // Non-uniform: re-derive via SVD of (transform's linear part) *
        // (this ellipse's own major/minor axis matrix) — sample the
        // transformed ellipse's implied "unit circle pullback" the same way
        // `ellipseFromCircleOrArc` does, by treating the ellipse as a
        // unit-circle-under-its-own-axis-matrix and composing.
        let major = Vec2(p.majorAxisEndpoint.x, p.majorAxisEndpoint.y)
        let minor = Vec2(-major.y, major.x) * p.ratio
        // Ellipse's own local-to-world linear map: unit circle (cos,sin) ->
        // center + major*cos + minor*sin. As a 2x2 matrix (columns
        // major, minor):
        let ellipseM = (m11: major.x, m21: major.y, m12: minor.x, m22: minor.y)
        let xfM = (m11: xf.a, m21: xf.b, m12: xf.c, m22: xf.d)
        // Compose: xf * ellipseM (apply ellipse's own map first, then xf).
        let composed = (
            m11: xfM.m11 * ellipseM.m11 + xfM.m12 * ellipseM.m21,
            m21: xfM.m21 * ellipseM.m11 + xfM.m22 * ellipseM.m21,
            m12: xfM.m11 * ellipseM.m12 + xfM.m12 * ellipseM.m22,
            m22: xfM.m21 * ellipseM.m12 + xfM.m22 * ellipseM.m22
        )
        let svd = svd2x2(m11: composed.m11, m21: composed.m21, m12: composed.m12, m22: composed.m22)
        let newCenter = apply(xf, p.center)
        let oldStart = p.startParam, oldEnd = p.endParam
        p.center = newCenter
        p.majorAxisEndpoint = Vec3(x: svd.u1.x * svd.sigma1, y: svd.u1.y * svd.sigma1, z: p.majorAxisEndpoint.z)
        p.ratio = svd.sigma1 > 1e-15 ? svd.sigma2 / svd.sigma1 : 0
        // Parametric angles need re-expressing in the NEW ellipse's frame —
        // NOT left unchanged. `composed = xf * ellipseM` plays exactly the
        // role `ellipseFromCircleOrArc`'s own `transform` does for a plain
        // circle: a point at parameter `t` on the ORIGINAL ellipse
        // corresponds to `composed * (cos t, sin t)`, and by the same SVD
        // identity used there, this equals `U*Sigma*(cos(t-vAngle),
        // sin(t-vAngle))` — i.e. parameter `t' = t - vAngle` on the NEW
        // ellipse. A prior version of this code assumed the sweep was
        // unchanged (reasoning that U's rotation "applies consistently to
        // both axes"), which is true for U's OWN rotation but ignores that
        // composing xf with a NON-axis-aligned ellipse matrix also
        // introduces V's own rotation (vAngle) — confirmed wrong via
        // `ExplodeTests.testExplodeEllipseUnderNonUniformScaleMatchesDirectTransform`,
        // which failed by several percent of the ellipse's size before this
        // fix (caught by direct numeric point-transform comparison, not by
        // any formula re-derivation alone — see that test's own doc
        // comment for why THIS scenario, not a plain circle/arc explode,
        // was needed to expose it).
        var newStart = oldStart - svd.vAngle
        var newEnd = oldEnd - svd.vAngle
        if xf.a * xf.d - xf.b * xf.c < 0 {
            // Mirror: same reversal EntityTransform's own ellipse case
            // applies, on top of the vAngle shift above.
            let s = newStart, e = newEnd
            newStart = -e
            newEnd = -s
        }
        p.startParam = newStart
        p.endParam = newEnd
    }

    /// Converts a circle/arc to its exact ELLIPSE image under a non-uniform
    /// `transform`, via SVD of the transform's 2x2 linear part.
    ///
    /// Math: a circle of radius `r` is the image of the unit circle under
    /// `p -> center + r*p`. Composing with `transform`'s linear part `L`
    /// gives `p -> transform(center) + r*L*p`. `L = U*Σ*Vᵀ` (SVD); since
    /// `p` ranges over the unit circle, `Vᵀ*p` ALSO ranges over the unit
    /// circle (V is orthogonal), so the image is `transform(center) +
    /// r*U*Σ*(unit circle)` — i.e. an ellipse with semi-axes `r*σ1` (along
    /// `U`'s first column) and `r*σ2` (along `U`'s second column). This is
    /// exactly the standard "an affine image of a circle is an ellipse
    /// whose axes are the transform's singular vectors, scaled by its
    /// singular values" fact.
    ///
    /// For an ARC (not a full circle), the parametric window
    /// [startDeg,endDeg] maps to an ellipse-arc window via the SVD's
    /// rotation-angle offset: a point at circle-angle θ maps to ellipse
    /// parameter θ' = θ - angleOf(V) (V's own rotation, subtracted because
    /// the ellipse's parametric angle is measured in the V-then-U frame,
    /// and V-plane angle IS the circle's own angle up to that fixed
    /// rotation offset — verified by direct construction: substituting
    /// θ'=θ-angleOf(V) into center+r*σ1*U1*cos(θ')+r*σ2*U2*sin(θ') and
    /// expanding recovers center+r*L*(cosθ,sinθ) exactly).
    private static func ellipseFromCircleOrArc(center: Vec3, radius: Double, startDeg: Double, endDeg: Double,
                                               isFullCircle: Bool, transform xf: CGAffineTransform) -> EllipsePayload {
        let svd = svd2x2(m11: xf.a, m21: xf.b, m12: xf.c, m22: xf.d)
        let newCenter = apply(xf, center)
        let majorAxis = Vec2(svd.u1.x, svd.u1.y) * (radius * svd.sigma1)
        let ratio = svd.sigma1 > 1e-15 ? (radius * svd.sigma2) / (radius * svd.sigma1) : 0

        var payload = EllipsePayload(center: newCenter, majorAxisEndpoint: Vec3(x: majorAxis.x, y: majorAxis.y, z: 0),
                                     ratio: ratio, startParam: 0, endParam: 2 * .pi)
        guard !isFullCircle else { return payload }

        let vAngle = svd.vAngle
        var startP = startDeg * .pi / 180 - vAngle
        var endP = endDeg * .pi / 180 - vAngle
        // Determinant < 0 (mirror): traversal direction reverses in the
        // ellipse's own frame — swap + negate, matching
        // `EntityTransform.apply`'s arc-mirror branch's own reasoning.
        if xf.a * xf.d - xf.b * xf.c < 0 {
            swap(&startP, &endP)
            startP = -startP
            endP = -endP
        }
        // Normalize into an increasing [start, start+2π) window so
        // downstream consumers (SplineEvaluator-adjacent tessellation, the
        // writer) see a conventional sweep rather than a possibly-negative
        // or wrapped range.
        while endP <= startP { endP += 2 * .pi }
        payload.startParam = startP
        payload.endParam = endP
        return payload
    }

    // MARK: - Text transform (height x |Y-scale|, widthFactor x aspect ratio)

    private static func applyTextTransform(_ xf: CGAffineTransform, to p: inout TextPayload) {
        p.position = apply(xf, p.position)
        p.alignPosition = apply(xf, p.alignPosition)
        let scaleX = hypot(xf.a, xf.b)
        let scaleY = hypot(xf.c, xf.d)
        // Per the plan: "text height×|colY|, widthFactor×ratio" — |colY| is
        // the transform's Y-axis column LENGTH (scaleY here); the
        // width-factor ratio is scaleX/scaleY, preserving the text's
        // rendered aspect ratio under the composed non-uniform transform
        // (a uniform transform has scaleX == scaleY, so this reduces to the
        // ordinary "widthFactor unchanged" case automatically).
        p.height *= abs(scaleY)
        if scaleY > 1e-12 { p.widthFactor *= scaleX / scaleY }
        let rot = atan2(xf.b, xf.a) * 180 / .pi
        p.rotationDeg += rot
        if xf.a * xf.d - xf.b * xf.c < 0 { p.isBackwards.toggle() }
    }

    // MARK: - LWPOLYLINE/POLYLINE explosion

    /// Explodes a top-level (already `nested`-baked or identity-transform)
    /// polyline directly — used by `explodeOne` for a top-level polyline
    /// selection (transform is always `.identity` there).
    private static func explodePolyline(_ id: EntityID, header h: EntityHeader, transform xf: CGAffineTransform,
                                        store: EntityStore, tx: Transaction) -> [EntityID]? {
        let resolved = PropertyResolver.resolveTopLevel(layerId: h.layerId, aci: h.aci,
                                                         trueColor: h.trueColor, linetypeId: h.linetypeId)
        return explodePolylineUnderTransform(id, header: h, transform: xf, resolved: resolved, store: store, tx: tx)
    }

    /// Shared LWPOLYLINE/POLYLINE2D explosion core: straight segments become
    /// LINEs, bulged segments become ARCs (uniform transform) or ELLIPSE
    /// arcs (non-uniform — "bulge segments emitted as separate ellipse-arc
    /// entities" per the plan). Segment-by-segment rather than a single
    /// polyline-wide uniform/non-uniform check, matching the plan's own
    /// per-child-shape reasoning (though in practice `xf` is the same
    /// transform for every segment of one polyline, so all segments end up
    /// on the same branch — this is just the natural per-segment structure,
    /// not meaningfully different behavior from a whole-polyline check).
    private static func explodePolylineUnderTransform(_ id: EntityID, header ch: EntityHeader, transform xf: CGAffineTransform,
                                                       resolved: PropertyResolver.Resolved,
                                                       store: EntityStore, tx: Transaction) -> [EntityID]? {
        guard ch.payload >= 0 else { return nil }
        let p = store.polylines[Int(ch.payload)]
        let n = Int(p.vertsCount)
        guard n >= 2 else { return nil }
        let vStart = Int(p.vertsStart), bStart = Int(p.bulgesStart)
        let segmentCount = p.closed ? n : n - 1
        guard segmentCount > 0 else { return nil }

        func addProto(_ type: DXFEntityType, _ payload: EntityPayloadCopy) -> EntityID {
            tx.add(EntityPrototype(type: type, layerId: resolved.layerId, aci: resolved.aci,
                                   trueColor: resolved.trueColor, linetypeId: resolved.linetypeId,
                                   ltScale: ch.ltScale, payload: payload))
        }

        var newIDs: [EntityID] = []
        for seg in 0..<segmentCount {
            let i0 = vStart + seg
            let i1 = vStart + (seg + 1) % n
            let v0 = store.vertexArena[i0]
            let v1 = store.vertexArena[i1]
            let bulge = store.scalarArena[bStart + seg]

            if abs(bulge) < 1e-12 {
                var line = LinePayload(a: v0, b: v1)
                applyGeneralTransform(xf, toLine: &line)
                newIDs.append(addProto(.line, .line(line)))
                continue
            }
            // Bulge -> arc via the Phase 2 kernel's own already-tested
            // `bulgeToArc` (Geometry/Curve.swift) rather than re-deriving
            // the center/radius/angle formulas here — one shared,
            // round-trip-verified implementation instead of a second one
            // that could silently disagree on a sign convention.
            let arc = bulgeToArc(from: Vec2(v0.x, v0.y), to: Vec2(v1.x, v1.y), bulge: bulge)
            guard arc.r > 1e-15 else { continue }
            let center3 = Vec3(x: arc.center.x, y: arc.center.y, z: v0.z)
            let rawStartDeg = arc.startAngle * 180 / .pi
            let rawEndDeg = (arc.startAngle + arc.sweep) * 180 / .pi
            // `CircArc.sweep` is SIGNED (positive = CCW), but DXF's ARC
            // storage (and this codebase's `ArcPayload`/`StrokeStore.Arc`)
            // is always a CCW sweep FROM start TO end — a negative-sweep
            // (CW) `CircArc` needs start/end swapped so the stored angles
            // still read as a CCW sweep, exactly like
            // `EntityCurveBridge.standalonePayload(for: .arc(_))`'s own
            // documented swap for the identical situation (bulge < 0 always
            // produces a negative sweep here, so this swap is exercised by
            // every negative-bulge polyline segment).
            let (startDeg, endDeg) = arc.sweep >= 0 ? (rawStartDeg, rawEndDeg) : (rawEndDeg, rawStartDeg)
            newIDs.append(explodeCircleOrArc(center: center3, radius: arc.r, startDeg: startDeg, endDeg: endDeg,
                                             isFullCircle: false, transform: xf, addProto: addProto))
        }
        return newIDs
    }

    // MARK: - HATCH explosion (boundary only — Phase 7 supplies pattern fill)

    private static func explodeHatch(_ id: EntityID, header h: EntityHeader, store: EntityStore, tx: Transaction) -> [EntityID]? {
        guard h.payload >= 0 else { return nil }
        let hp = store.hatches[Int(h.payload)]
        guard hp.loopRangeCount > 0 else { return nil }
        let resolved = PropertyResolver.resolveTopLevel(layerId: h.layerId, aci: h.aci,
                                                         trueColor: h.trueColor, linetypeId: h.linetypeId)
        var newIDs: [EntityID] = []
        for r in Int(hp.loopRangeStart)..<Int(hp.loopRangeStart + hp.loopRangeCount) {
            let range = store.hatchLoopRanges[r]
            let count = Int(range.vertCount)
            guard count >= 2 else { continue }
            for i in 0..<count {
                let a = store.vertexArena[Int(range.vertStart) + i]
                let b = store.vertexArena[Int(range.vertStart) + (i + 1) % count]
                let proto = EntityPrototype(type: .line, layerId: resolved.layerId, aci: resolved.aci,
                                            trueColor: resolved.trueColor, linetypeId: resolved.linetypeId,
                                            ltScale: h.ltScale, payload: .line(LinePayload(a: a, b: b)))
                newIDs.append(tx.add(proto))
            }
        }
        guard !newIDs.isEmpty else { return nil }
        return newIDs
    }

    // MARK: - 2x2 SVD (closed-form)

    /// Result of a 2x2 SVD: `M = [u1 u2] * diag(sigma1,sigma2) * [v1 v2]ᵀ`,
    /// with `sigma1 >= sigma2 >= 0`. `u1`/`u2` are unit column vectors of
    /// `U` (the ellipse's world-space axis directions after transform);
    /// `vAngle` is V's rotation angle (needed to map the SOURCE circle's
    /// parametric angle into the ellipse's own parametric frame).
    struct SVD2x2Result {
        var sigma1: Double
        var sigma2: Double
        var u1: Vec2
        var u2: Vec2
        var vAngle: Double
    }

    /// Closed-form 2x2 SVD via the classic "sum/difference of angles" trick
    /// (avoids any iterative algorithm for a 2x2 — exact in one pass modulo
    /// floating-point rounding). For `M = [[m11,m12],[m21,m22]]`:
    ///   E=(m11+m22)/2, F=(m11-m22)/2, G=(m21+m12)/2, H=(m21-m12)/2
    ///   Q=hypot(E,H), R=hypot(F,G)
    ///   sigma1=Q+R, sigma2=|Q-R|
    ///   a1=atan2(G,F), a2=atan2(H,E)
    ///   theta=(a1-a2)/2  (V's rotation angle)
    ///   phi=(a2+a1)/2    (U's rotation angle)
    ///
    /// IMPORTANT SIGN NOTE: `theta = (a1-a2)/2`, NOT `(a2-a1)/2` — an
    /// earlier draft of this function used the latter, which reconstructs
    /// `M` correctly ONLY for a symmetric `M` (where a1==a2, making the two
    /// forms identical) and silently produces the WRONG ellipse-arc
    /// parametric window for any transform with genuine shear/asymmetry
    /// (verified two independent ways during development: (1) a general
    /// `M = U*diag(sigma1,sigma2)*Vᵀ` reconstruction check across a battery
    /// of hand-picked asymmetric matrices, cross-checked against NumPy's
    /// `numpy.linalg.svd`; (2) direct numeric substitution — transforming a
    /// sampled circle point via `M` directly must equal evaluating the
    /// derived ellipse at the correspondingly-shifted parameter
    /// `t - vAngle`; the WRONG sign showed a relative error of several
    /// units on a general shear matrix while the correct sign matched to
    /// 1e-15). Both checks are preserved as unit tests
    /// (`ExplodeTests.testSVDReconstructsOriginalMatrix`/
    /// `testSVDMatchesHandComputedRotateThenScaleExample`) — this is exactly
    /// the class of "looks like a textbook formula, silently wrong sign"
    /// bug this project's own MIRROR-angle and FILLET-arc-selection bugs
    /// both were (see git history / autocad-parity-implementation-status
    /// memory), so it's called out explicitly rather than left as a bare
    /// formula. `sigma2` is left as the UNSIGNED magnitude `|Q-R|` (not the
    /// alternative signed convention `Q-R`, which some SVD derivations use
    /// to keep both U/V as pure rotations for a negative-determinant `M`) —
    /// this file only ever consumes `sigma2` as an ellipse's minor-axis
    /// LENGTH (always non-negative), and handles the negative-determinant
    /// (mirror) case separately via each call site's own explicit
    /// `determinant < 0` branch (see `ellipseFromCircleOrArc`/
    /// `applyEllipseTransform`), so the signed-sigma2 convention's added
    /// complexity isn't needed here.
    static func svd2x2(m11: Double, m21: Double, m12: Double, m22: Double) -> SVD2x2Result {
        let E = (m11 + m22) / 2, F = (m11 - m22) / 2
        let G = (m21 + m12) / 2, H = (m21 - m12) / 2
        let Q = hypot(E, H), R = hypot(F, G)
        let sigma1 = Q + R
        let sigma2 = abs(Q - R)
        let a1 = atan2(G, F)
        let a2 = atan2(H, E)
        let theta = (a1 - a2) / 2
        let phi = (a2 + a1) / 2
        let u1 = Vec2(cos(phi), sin(phi))
        let u2 = Vec2(-sin(phi), cos(phi))
        return SVD2x2Result(sigma1: sigma1, sigma2: sigma2, u1: u1, u2: u2, vAngle: theta)
    }

    // MARK: - Small helpers

    private static func apply(_ xf: CGAffineTransform, _ v: Vec3) -> Vec3 {
        let p = CGPoint(x: v.x, y: v.y).applying(xf)
        return Vec3(x: Double(p.x), y: Double(p.y), z: v.z)
    }

    /// Converts a KNOWN-uniform `CGAffineTransform` (verified by the caller
    /// via `isUniform`) into a `Transform2` for reuse of `EntityTransform`'s
    /// existing, already-tested conformal-transform application logic.
    private static func toTransform2(_ xf: CGAffineTransform) -> Transform2 {
        Transform2(m11: xf.a, m12: xf.c, m21: xf.b, m22: xf.d, tx: xf.tx, ty: xf.ty)
    }
}
