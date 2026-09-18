//
//  ArrayTool.swift
//  DWGViewer / Editing
//
//  Phase 6.4 — ARRAY (rectangular + polar; path deferred — see below).
//
//  LOCKED STORAGE DECISION (per the plan): plain entity copies + a
//  NovaCAD-side `ArrayDefinition` associativity record, NOT ACAD_ASSOCARRAY.
//  The real AutoCAD associative-array object graph (ACAD_ASSOCARRAY /
//  ACAD_EVALUATION_GRAPH / ACAD_ASSOCACTION / etc.) is a large,
//  poorly-documented subsystem; a wrong round-trip of it corrupts drawings
//  in ways that are hard to detect. Plain entity copies interoperate
//  perfectly with any DXF reader (they're just ordinary entities); the
//  associativity ("this is an array, edit it as a whole") lives ENTIRELY in
//  NovaCAD's own session-side `DocumentSession.arrays` table plus
//  `ARRAYDEF` XDATA on each member (so a save/reload round-trip within
//  NovaCAD itself can still offer "Edit Array" — any OTHER DXF reader just
//  sees N independent entities plus one ignorable custom XDATA app group
//  per member, exactly how unrecognized XDATA is supposed to degrade).
//
//  Per-cell transforms (all built from the SAME conformal `Transform2` +
//  `EntityTransform`/`Transaction.copyTransformed` machinery MOVE/COPY/
//  ROTATE/SCALE/MIRROR already use — reused directly, not reinvented, per
//  the task brief):
//    - rectangular: translation by (row*rowSpacing, col*colSpacing) rotated
//      by `axisAngle` about the origin — i.e. the array's row/column grid
//      itself is rotated, not just each cell's content.
//    - polar: rotation about `center` by `k * (fillAngle / effectiveCount)`
//      for cell k, composed with an inverse item-rotation when
//      `rotateItems == false` (AutoCAD's own "keep items upright" option —
//      each copy's CONTENT stays at its original orientation even though
//      its POSITION orbits the center).
//    - path: `pointAtLength` positions + tangent alignment — Curve2's
//      `pointAtLength`/tangent machinery already exists (Geometry/Curve.swift)
//      but wiring an entity-picker for "which curve is the path" and the
//      divide/measure UI is deferred (see the plan's own scoping guidance
//      ranking PATH array as lower priority than rect/polar) — `path` cases
//      below compute member COUNT/positions is NOT implemented; `regenerate`
//      and `previewCells` both report a clear "not yet supported" result
//      rather than silently producing wrong geometry.
//
//  Live ghost preview is capped at 500 cells (`maxPreviewCells`) per the
//  plan — `previewCells` returns cell TRANSFORMS only (no entity creation),
//  used by `ContentView`'s canvas overlay to stroke a ghost outline per
//  cell without ever touching the EntityStore.
//

import Foundation
import CADCore
import CoreGraphics

/// One array's associativity record — the entire "this group of entities is
/// actually one ARRAY" fact NovaCAD tracks outside plain entity storage.
/// `Vec2`-typed fields (not `CGPoint`) since this struct is also the
/// natural home for `ArrayDefinition.Codable` (JSON XDATA payload) and
/// `Vec2`/`Double` round-trip through `Codable` with no CoreGraphics
/// dependency needed on the decode side.
struct ArrayDefinition: Equatable, Codable {
    enum PathDivision: Equatable, Codable {
        case divide(Int)       // n copies evenly spaced along the whole path
        case measure(Double)   // copies every `d` units along the path
    }

    enum Kind: Equatable, Codable {
        case rectangular(rows: Int, cols: Int, rowSpacing: Double, colSpacing: Double, axisAngle: Double)
        case polar(center: CodableVec2, count: Int, fillAngle: Double, rotateItems: Bool)
        case path(pathHandle: Int32, division: PathDivision, alignToPath: Bool)
    }

    var kind: Kind
    /// The ORIGINAL entities the array was built from (kept alive as the
    /// first "member" cell — matches AutoCAD's own ARRAY, which treats the
    /// source selection as array item #1 rather than leaving an untouched
    /// original plus N new copies).
    var sourceHandles: [EntityID]
    /// EVERY member entity currently representing one array cell, including
    /// the originals in `sourceHandles` — `regenerate` replaces this whole
    /// set. Order is cell-major (all of source-set #1's cells, i.e. member
    /// entity k is `sourceHandles[k % sourceHandles.count]`'s copy in cell
    /// `k / sourceHandles.count`) — see `ArrayTool.memberCellIndex`.
    var memberHandles: [EntityID]

    /// JSON-encodable `Vec2` substitute (plain `SIMD2<Double>` isn't
    /// `Codable` in a stable, hand-controlled shape) — kept minimal on
    /// purpose since this only needs to round-trip through XDATA JSON, not
    /// serve as a general-purpose vector type.
    struct CodableVec2: Equatable, Codable {
        var x: Double
        var y: Double
        var cgPoint: CGPoint { CGPoint(x: x, y: y) }
        init(_ p: CGPoint) { x = Double(p.x); y = Double(p.y) }
        init(x: Double, y: Double) { self.x = x; self.y = y }
    }
}

enum ArrayTool {

    /// Live ghost preview cap per the plan.
    static let maxPreviewCells = 500

    // MARK: - Per-cell transforms

    /// Rectangular array cell transforms, in row-major order (cell 0 is
    /// always `.identity` — the ORIGINAL position — matching AutoCAD's own
    /// "item 1 stays where the source was"). `axisAngle` rotates the WHOLE
    /// grid (both row and column directions) about the world origin — i.e.
    /// cell (r, c)'s untransformed offset is `(c*colSpacing, r*rowSpacing)`,
    /// which is then rotated by `axisAngle` before being used as a
    /// translation. This matches AutoCAD's ARRAYRECT "Axis angle" option,
    /// which rotates the array's row/column directions together, not each
    /// item independently.
    static func rectangularCellTransforms(rows: Int, cols: Int, rowSpacing: Double,
                                          colSpacing: Double, axisAngleDeg: Double) -> [Transform2] {
        guard rows > 0, cols > 0 else { return [] }
        let angleRad = axisAngleDeg * .pi / 180
        let ca = cos(angleRad), sa = sin(angleRad)
        var result: [Transform2] = []
        result.reserveCapacity(rows * cols)
        for r in 0..<rows {
            for c in 0..<cols {
                let dx = Double(c) * colSpacing
                let dy = Double(r) * rowSpacing
                // Rotate the (dx,dy) grid offset by axisAngle, then use it
                // as a pure translation — this is NOT the same as
                // `Transform2.rotation(about:)` composed after translation,
                // since that would also spin the CONTENT of each cell; the
                // grid direction rotates, individual items don't (matching
                // AutoCAD's rectangular array — items keep their original
                // orientation regardless of axis angle).
                let rx = dx * ca - dy * sa
                let ry = dx * sa + dy * ca
                result.append(.translation(dx: rx, dy: ry))
            }
        }
        return result
    }

    /// Polar array angle step, shared by both `rotateItems` modes: cell k
    /// sits at `k * stepDeg` degrees around `center` from the source
    /// position, where `effectiveCount` is `count` for a full 360-degree
    /// fill (items evenly spaced with no coincident start/end) or
    /// `count - 1` for a PARTIAL fill (< 360 degrees — AutoCAD spaces a
    /// partial polar array so the LAST item lands exactly at the fill
    /// angle, meaning there are `count - 1` gaps, not `count`).
    static func polarStepDeg(count: Int, fillAngleDeg: Double) -> Double {
        guard count > 1 else { return 0 }
        let fullCircle = abs(abs(fillAngleDeg) - 360) < 1e-9
        let effectiveCount = fullCircle ? count : count - 1
        guard effectiveCount > 0 else { return 0 }
        return fillAngleDeg / Double(effectiveCount)
    }

    /// Polar array cell transforms when `rotateItems == true` (the common
    /// case): cell k is a plain rotation of the WHOLE source geometry by
    /// `k * step` about `center` — cell 0 is exactly `.identity`. One
    /// `Transform2` validly applies to every source entity uniformly here,
    /// since a rotation-about-a-fixed-point needs no per-entity anchor.
    static func polarCellTransforms(center: Vec2, count: Int, fillAngleDeg: Double) -> [Transform2] {
        guard count > 0 else { return [] }
        let step = polarStepDeg(count: count, fillAngleDeg: fillAngleDeg)
        return (0..<count).map { k in
            Transform2.rotation(about: center, angleRad: Double(k) * step * .pi / 180)
        }
    }

    /// Polar array cell transform for ONE source entity when
    /// `rotateItems == false` ("keep items upright" — AutoCAD's own
    /// ARRAYPOLAR option): the entity's OWN reference point `anchor`
    /// (this codebase uses `EntityStore.bounds(id)`'s center — a
    /// deterministic, always-available per-entity anchor, standing in for
    /// AutoCAD's user-settable "base point," which this app's ARRAY does
    /// not yet expose as a separate pick) orbits to
    /// `R(k*step, about: center)·(anchor - center) + center`, but the
    /// entity's SHAPE keeps its original orientation — i.e. every point of
    /// the entity shifts by the SAME translation vector the anchor itself
    /// experiences. This is necessarily a PER-ENTITY transform (unlike the
    /// `rotateItems == true` case above, one shared `Transform2` cannot
    /// serve every source entity when their anchors differ) — concrete
    /// numeric check (see `ArrayToolTests`): anchor (10,0), center (0,0),
    /// k=1, step=90 degrees -> new anchor (0,10); a point at anchor+(1,0) =
    /// (11,0) on the source must map to (0,10)+(1,0) = (1,10), NOT to
    /// (0,10) rotated further — i.e. translation-only, verified against a
    /// hand-computed expectation, not a symmetric round-trip.
    static func polarCellTransformKeepingUpright(anchor: Vec2, center: Vec2, k: Int,
                                                 count: Int, fillAngleDeg: Double) -> Transform2 {
        let step = polarStepDeg(count: count, fillAngleDeg: fillAngleDeg)
        let angleRad = Double(k) * step * .pi / 180
        let newAnchor = Transform2.rotation(about: center, angleRad: angleRad).apply(anchor)
        let delta = newAnchor - anchor
        return .translation(dx: delta.x, dy: delta.y)
    }

    // MARK: - Member creation

    /// Creates one array's worth of member entities from `sourceIDs`,
    /// applying `transform(sourceIndex, cellIndex)` for every (source,
    /// cell) pair except cell 0 (the original source entities themselves
    /// serve as cell 0, matching AutoCAD — never re-copied even if
    /// `transform` would return `.identity` for it, so an entity is never
    /// accidentally duplicated on top of itself) via `Transaction.
    /// copyTransformed` (the exact MOVE/COPY engine — see this file's
    /// header comment). Per-(source,cell) rather than per-cell-only because
    /// `rotateItems == false` polar arrays need a DIFFERENT transform per
    /// source entity (see `polarCellTransformKeepingUpright`'s doc comment
    /// for why one shared `Transform2` can't serve every source there).
    /// Tags every member (including the untouched originals) with
    /// `ARRAYDEF` XDATA carrying the JSON-encoded `ArrayDefinition` — via
    /// the caller's own follow-up `tagMembers` call, not here, so this
    /// function stays a pure "build the cells" primitive independent of
    /// which `ArrayDefinition.Kind` is being committed.
    @discardableResult
    static func createArray(sourceIDs: [EntityID], cellCount: Int,
                            transform: (_ sourceIndex: Int, _ cellIndex: Int) -> Transform2,
                            store: EntityStore, tx: Transaction) -> ArrayDefinition? {
        guard !sourceIDs.isEmpty, cellCount > 0 else { return nil }
        var memberHandles: [EntityID] = []
        memberHandles.reserveCapacity(sourceIDs.count * cellCount)
        for cell in 0..<cellCount {
            for (si, id) in sourceIDs.enumerated() {
                if cell == 0 {
                    memberHandles.append(id)
                    continue
                }
                let t = transform(si, cell)
                if let newId = tx.copyTransformed(id, by: t, mirrtext: false) {
                    memberHandles.append(newId)
                }
            }
        }
        guard !memberHandles.isEmpty else { return nil }
        return ArrayDefinition(kind: .rectangular(rows: 0, cols: 0, rowSpacing: 0, colSpacing: 0, axisAngle: 0),
                               sourceHandles: sourceIDs, memberHandles: memberHandles)
    }

    /// Full rectangular-array commit: builds the cell transforms, creates
    /// members, tags XDATA on every member, and returns the definition.
    @discardableResult
    static func commitRectangular(sourceIDs: [EntityID], rows: Int, cols: Int, rowSpacing: Double,
                                  colSpacing: Double, axisAngleDeg: Double,
                                  store: EntityStore, tx: Transaction) -> ArrayDefinition? {
        let transforms = rectangularCellTransforms(rows: rows, cols: cols, rowSpacing: rowSpacing,
                                                   colSpacing: colSpacing, axisAngleDeg: axisAngleDeg)
        guard !transforms.isEmpty,
              var def = createArray(sourceIDs: sourceIDs, cellCount: transforms.count,
                                    transform: { _, cell in transforms[cell] }, store: store, tx: tx)
        else { return nil }
        def.kind = .rectangular(rows: rows, cols: cols, rowSpacing: rowSpacing, colSpacing: colSpacing, axisAngle: axisAngleDeg)
        tagMembers(def, store: store, tx: tx)
        return def
    }

    /// Full polar-array commit. `rotateItems == false` computes a
    /// per-source-entity transform (see `polarCellTransformKeepingUpright`);
    /// `rotateItems == true` shares one `Transform2` per cell across every
    /// source entity (see `polarCellTransforms`).
    @discardableResult
    static func commitPolar(sourceIDs: [EntityID], center: CGPoint, count: Int, fillAngleDeg: Double,
                            rotateItems: Bool, store: EntityStore, tx: Transaction) -> ArrayDefinition? {
        guard count > 0 else { return nil }
        let centerVec = Vec2(center)
        let sharedTransforms = rotateItems ? polarCellTransforms(center: centerVec, count: count, fillAngleDeg: fillAngleDeg) : []
        let anchors: [Vec2] = rotateItems ? [] : sourceIDs.map { id in
            let b = store.bounds(id)
            return Vec2(Double(b.midX), Double(b.midY))
        }
        guard var def = createArray(sourceIDs: sourceIDs, cellCount: count, transform: { si, cell in
            if rotateItems {
                return sharedTransforms[cell]
            } else {
                return ArrayTool.polarCellTransformKeepingUpright(
                    anchor: anchors[si], center: centerVec, k: cell, count: count, fillAngleDeg: fillAngleDeg)
            }
        }, store: store, tx: tx) else { return nil }
        def.kind = .polar(center: ArrayDefinition.CodableVec2(center), count: count,
                          fillAngle: fillAngleDeg, rotateItems: rotateItems)
        tagMembers(def, store: store, tx: tx)
        return def
    }

    // MARK: - XDATA persistence

    static let xdataAppId = "NOVACAD"
    static let xdataCode: Int16 = 1000
    /// Marker prefix distinguishing an ARRAYDEF XDATA string from any other
    /// "NOVACAD"-app-id XDATA a future feature might add (e.g. REGION's own
    /// marker — see RegionTool.swift) — both share the SAME app id
    /// (`NOVACAD`) per the plan's literal spec text ("1001 NOVACAD / 1000
    /// ARRAYDEF <json>"), so the 1000-code STRING VALUE itself carries the
    /// distinguishing "ARRAYDEF" prefix, not the app id.
    static let arrayDefPrefix = "ARRAYDEF "

    /// Encodes `def` as JSON and appends an `ARRAYDEF <json>` XDATA pair
    /// (app id `NOVACAD`, code 1000) to every member in `def.memberHandles`.
    /// `EntityStore.xdata` is a side dictionary the `Transaction.Op` enum
    /// has no case for (same situation `RegionTool.tagAsRegionXData`/
    /// `BlockEditor`'s block-table writes are in) — this function registers
    /// its OWN `tx.registerSideEffect` covering exactly the XDATA it just
    /// wrote (snapshotting each member's PRIOR blob first), rather than
    /// requiring every call site to do so itself. This matters specifically
    /// for `regenerate`'s SOURCE entities, which survive an Edit Array
    /// unchanged in every other respect but get their XDATA REPLACED (old
    /// ArrayDef JSON -> new) — those entities are never touched by
    /// `Transaction.delete`/`add` at all, so nothing else in the undo
    /// system would otherwise reverse this write (found by adversarial
    /// review: the original version left this entirely untracked, which
    /// would have shown up as a real save/reload inconsistency once a
    /// future phase re-parses ARRAYDEF XDATA back into `session.arrays`,
    /// even though no CURRENTLY reachable live-session bug results from it
    /// today since nothing re-reads XDATA back into session state yet).
    static func tagMembers(_ def: ArrayDefinition, store: EntityStore, tx: Transaction) {
        guard let json = try? JSONEncoder().encode(def), let jsonString = String(data: json, encoding: .utf8) else { return }
        var before: [Int32: XDataBlob?] = [:]
        var after: [Int32: XDataBlob?] = [:]
        for id in def.memberHandles {
            before[id.raw] = store.xdata[id.raw]
            var blob = store.xdata[id.raw] ?? XDataBlob(appId: xdataAppId, pairs: [])
            // Replace any PRIOR ArrayDef marker on this entity (re-tagging
            // after `regenerate`) rather than accumulating duplicates.
            blob.pairs.removeAll { $0.code == xdataCode && isArrayDefPair($0.value) }
            blob.pairs.append((code: xdataCode, value: .string(arrayDefPrefix + jsonString)))
            store.xdata[id.raw] = blob
            after[id.raw] = blob
        }
        guard !before.isEmpty else { return }
        tx.registerSideEffect(
            undo: { for (raw, blob) in before { store.xdata[raw] = blob } },
            redo: { for (raw, blob) in after { store.xdata[raw] = blob } })
    }

    private static func isArrayDefPair(_ v: XDataValue) -> Bool {
        if case .string(let s) = v { return s.hasPrefix(arrayDefPrefix) }
        return false
    }

    // MARK: - Edit Array (regenerate)

    /// Regenerates an existing array from a NEW definition: deletes every
    /// CURRENT member except the original `sourceHandles` (which are
    /// restored to their pre-array position/orientation implicitly by
    /// virtue of never having moved — cell 0 is always identity), then
    /// re-creates every other cell fresh from `newDef`'s parameters.
    ///
    /// Reconciliation of user-deleted members (per the plan's "reconcile
    /// user-deleted members" instruction): if the user manually deleted one
    /// or more array members (via ordinary ERASE) BEFORE running Edit
    /// Array, those entities are already tombstoned in the store —
    /// `tx.delete` on an already-deleted id is a documented no-op
    /// (`Transaction.delete`'s own guard), so this is naturally idempotent
    /// and never double-deletes or errors on a stale handle. The
    /// regeneration always rebuilds the FULL cell count from `newDef`
    /// (i.e. a user-deleted cell reappears after Edit Array) — this matches
    /// real AutoCAD's own associative-array behavior for a full
    /// regenerate-from-parameters edit (item-level deletion in a REAL
    /// associative array is a separate "ARRAYITEM remove" operation this
    /// app doesn't model at all, consistent with the plain-copies storage
    /// decision).
    @discardableResult
    static func regenerate(_ oldDef: ArrayDefinition, sourceIDs: [EntityID], newKindParams: ArrayDefinition.Kind,
                           store: EntityStore, tx: Transaction) -> ArrayDefinition? {
        // Delete every OLD member that is not itself an original source
        // entity (the sources are reused as cell 0 again below). Their
        // XDATA is left AS-IS on the tombstoned entity (no `untagMember`
        // call here) — `Transaction.delete`'s own snapshot/restore
        // (`EntityImage`) only covers header+payload, NOT the sparse
        // `EntityStore.xdata` dictionary (confirmed against `EntityImage`'s
        // own field list), so stripping XDATA here with no undo tracking
        // would corrupt undo (a resurrected tombstone would come back with
        // its ARRAYDEF tag permanently gone) — found by adversarial review.
        // Leaving a stale ARRAYDEF tag on a permanently-deleted entity is
        // harmless (nothing reads XDATA off a tombstoned/compacted-away
        // entity), so simply NOT touching it here is both simpler and
        // correct, unlike the previous version's untracked strip.
        let sourceSet = Set(sourceIDs)
        for id in oldDef.memberHandles where !sourceSet.contains(id) {
            if !store.isDeleted(id) { tx.delete(id) }
        }
        // The SOURCE entities' own XDATA does not need pre-stripping either
        // — `tagMembers` (called by `commitRectangular`/`commitPolar` below,
        // since `sourceIDs` are always cell 0 again) already replaces any
        // PRIOR ArrayDef marker via its own dedup pass (`isArrayDefPair`),
        // and — per this same fix — `tagMembers` now registers its own
        // undo-safe side effect, so no separate handling is needed here.

        switch newKindParams {
        case .rectangular(let rows, let cols, let rowSpacing, let colSpacing, let axisAngle):
            return commitRectangular(sourceIDs: sourceIDs, rows: rows, cols: cols, rowSpacing: rowSpacing,
                                     colSpacing: colSpacing, axisAngleDeg: axisAngle, store: store, tx: tx)
        case .polar(let center, let count, let fillAngle, let rotateItems):
            return commitPolar(sourceIDs: sourceIDs, center: center.cgPoint, count: count,
                               fillAngleDeg: fillAngle, rotateItems: rotateItems, store: store, tx: tx)
        case .path:
            return nil   // deferred — see this file's header comment.
        }
    }

    // MARK: - Live ghost preview (no entity creation)

    /// Returns up to `maxPreviewCells` cell transforms for a rectangular
    /// array-in-progress — same math as `rectangularCellTransforms`,
    /// exposed separately so the live preview can cap the count WITHOUT
    /// truncating the actual commit (a user typing "50 rows" sees a capped
    /// preview but still gets all 50 rows on commit).
    static func previewRectangular(rows: Int, cols: Int, rowSpacing: Double, colSpacing: Double,
                                   axisAngleDeg: Double) -> [Transform2] {
        Array(rectangularCellTransforms(rows: rows, cols: cols, rowSpacing: rowSpacing,
                                        colSpacing: colSpacing, axisAngleDeg: axisAngleDeg).prefix(maxPreviewCells))
    }

    /// Ghost-preview transforms for ONE source entity's polar array cells
    /// (the canvas overlay calls this once per selected source entity,
    /// passing that entity's own `anchor` — its bounds center, matching
    /// `commitPolar`'s real anchor choice exactly, so the preview can never
    /// visually disagree with what commit will actually produce).
    static func previewPolar(anchor: CGPoint, center: CGPoint, count: Int, fillAngleDeg: Double,
                             rotateItems: Bool) -> [Transform2] {
        guard count > 0 else { return [] }
        let centerVec = Vec2(center)
        let transforms: [Transform2]
        if rotateItems {
            transforms = polarCellTransforms(center: centerVec, count: count, fillAngleDeg: fillAngleDeg)
        } else {
            let anchorVec = Vec2(anchor)
            transforms = (0..<count).map { k in
                polarCellTransformKeepingUpright(anchor: anchorVec, center: centerVec, k: k,
                                                 count: count, fillAngleDeg: fillAngleDeg)
            }
        }
        return Array(transforms.prefix(maxPreviewCells))
    }
}
