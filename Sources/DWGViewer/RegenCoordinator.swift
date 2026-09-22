import Foundation
import CADCore
import CoreGraphics

// MARK: - Phase 1.6: incremental regeneration + EntityRef stability
//
// `Regenerator.build` (Regenerator.swift) does a full one-shot expansion of
// an `EntityStore` into a `DXFDocument`'s `modelGroups`/`paperGroups`. That
// costs ~3s on the 731MB/3.4M-entity file — far too slow to pay on every
// single-entity edit. `RegenCoordinator` makes edits cheap:
//
//   - Per commit, only the entities the transaction actually touched
//     (added/modified/deleted) get new geometry emitted, appended as NEW
//     `RenderGroup`s ("delta groups") to `modelGroups`/`paperGroups`.
//   - The OLD stale primitives belonging to modified/deleted entities are
//     tombstoned IN PLACE inside their original groups (a per-group,
//     per-primitive-kind bitset) so the renderer/hit-tester skip them.
//   - Existing group ARRAY INDICES never move or shrink — any code holding a
//     positional `EntityRef.primitive(group:store:index:)` stays valid.
//
// Compaction (tombstoned-ratio or delta-group-count over a threshold) throws
// this all away and does a full `Regenerator.build` rebuild on the existing
// render queue, then swaps the result in. Selection survives compaction
// because `EditableDocument`/harness selection is `Set<EntityID>`, not
// positional.

/// Per-group tombstone bitsets, one per `PrimitiveStore` kind. Lazily
/// allocated (a freshly-loaded, never-edited group carries no tombstone
/// storage at all — zero overhead for the read-only old path and for any
/// group nothing has touched yet).
final class GroupTombstones {
    var runs: [Bool] = []
    var arcs: [Bool] = []
    var texts: [Bool] = []
    var points: [Bool] = []
    var fillRuns: [Bool] = []

    @inline(__always) func isDead(_ store: PrimitiveStore, _ index: Int32) -> Bool {
        let i = Int(index)
        switch store {
        case .run: return i < runs.count && runs[i]
        case .arc: return i < arcs.count && arcs[i]
        case .text: return i < texts.count && texts[i]
        case .point: return i < points.count && points[i]
        case .fillRun: return i < fillRuns.count && fillRuns[i]
        }
    }

    /// Marks index dead, growing the bitset lazily. Returns true if this call
    /// actually flipped a live primitive to dead (used for the tombstoned-
    /// primitive-count compaction heuristic — re-tombstoning an already-dead
    /// slot must not double count).
    @discardableResult
    func markDead(_ store: PrimitiveStore, _ index: Int32) -> Bool {
        let i = Int(index)
        switch store {
        case .run:
            if runs.count <= i { runs.append(contentsOf: repeatElement(false, count: i - runs.count + 1)) }
            guard !runs[i] else { return false }
            runs[i] = true; return true
        case .arc:
            if arcs.count <= i { arcs.append(contentsOf: repeatElement(false, count: i - arcs.count + 1)) }
            guard !arcs[i] else { return false }
            arcs[i] = true; return true
        case .text:
            if texts.count <= i { texts.append(contentsOf: repeatElement(false, count: i - texts.count + 1)) }
            guard !texts[i] else { return false }
            texts[i] = true; return true
        case .point:
            if points.count <= i { points.append(contentsOf: repeatElement(false, count: i - points.count + 1)) }
            guard !points[i] else { return false }
            points[i] = true; return true
        case .fillRun:
            if fillRuns.count <= i { fillRuns.append(contentsOf: repeatElement(false, count: i - fillRuns.count + 1)) }
            guard !fillRuns[i] else { return false }
            fillRuns[i] = true; return true
        }
    }
}

/// Out-of-band tombstone lookup keyed by `RenderGroup` identity.
///
/// CADCore's `RenderGroup` (the shared, extracted geometry-kernel type) no
/// longer carries a `tombstones` field: incremental-regen tombstoning is an
/// editing-layer concept that belongs in NovaCAD, not the shared
/// parsing/geometry kernel CADCore also serves to other consumers.
/// `RegenCoordinator.tombstone(_:)` is the only writer; `CGRenderCore`
/// and `HitTesting` (hot-path static functions that only ever receive a
/// `DXFDocument`, not a `RegenCoordinator`) are the readers. A global registry
/// keyed by `ObjectIdentifier` avoids threading a `RegenCoordinator`
/// reference through every rendering/hit-testing call site in
/// `DXFRenderer.swift`/`ContentView.swift` for what is, in the overwhelming
/// common case (a never-edited group), a nil lookup.
///
/// Thread-safe: rendering runs off the main thread (`DXFRenderer`'s async
/// drain worker), so reads/writes are serialized behind a lock.
///
/// WS-N3 fix: this was previously backed by a plain `[ObjectIdentifier:
/// GroupTombstones]` dictionary that NOTHING ever pruned. `ObjectIdentifier`
/// is just a `RenderGroup`'s current memory address — once a `RenderGroup`
/// deallocates (e.g. after a `fullRebuild()`/compaction swaps in a fresh
/// `DXFDocument`, or a whole `RegenCoordinator` goes out of scope, as happens
/// constantly across short-lived test fixtures), ARC is free to hand that
/// exact address to a brand-new, never-edited `RenderGroup`. The stale
/// dictionary entry then silently applied the PREVIOUS group's tombstone
/// bitset to the new group — a use-after-free-shaped identity bug that
/// surfaced as intermittent, run-order-dependent failures in
/// `RegenCoordinatorTests`/`SelectionEngineTests` (whichever test's newly
/// allocated `RenderGroup` happened to land on a just-freed address with a
/// leftover entry). Backing this with `NSMapTable(keyOptions: .weakMemory,
/// ...)` instead means an entry is automatically removed the moment its key
/// `RenderGroup` deallocates, closing the address-reuse window entirely.
final class GroupTombstoneRegistry {
    static let shared = GroupTombstoneRegistry()
    private let lock = NSLock()
    private let storage = NSMapTable<RenderGroup, GroupTombstones>(keyOptions: .weakMemory,
                                                                    valueOptions: .strongMemory)

    /// Returns the existing tombstone table for `group`, or `nil` if it has
    /// never been edited.
    static func tombstones(for group: RenderGroup) -> GroupTombstones? {
        shared.lock.lock()
        defer { shared.lock.unlock() }
        return shared.storage.object(forKey: group)
    }

    /// Returns the tombstone table for `group`, creating one on first use.
    static func tombstonesCreatingIfNeeded(for group: RenderGroup) -> GroupTombstones {
        shared.lock.lock()
        defer { shared.lock.unlock() }
        if let existing = shared.storage.object(forKey: group) {
            return existing
        }
        let table = GroupTombstones()
        shared.storage.setObject(table, forKey: group)
        return table
    }
}

/// One primitive belonging to a given `EntityID`, addressed exactly like an
/// `EntityRef.primitive` — the unit `entityLocator` maps an `EntityID` to a
/// list of.
struct PrimitiveSpan: Equatable {
    var space: SpaceID
    var group: Int32
    var store: PrimitiveStore
    var index: Int32
}

/// Describes what changed in the render model as a result of one commit —
/// published so callers (renderer, hit-tester, search index) can patch
/// incrementally instead of re-scanning the whole document.
struct RegenDelta {
    /// Newly appended group indices, per space, from this commit (empty on a
    /// no-op commit; also empty when `fullRebuild` is true — in that case the
    /// entire group array changed shape and callers should treat it as if
    /// the document were freshly loaded).
    var appendedModelGroups: [Int32] = []
    var appendedPaperGroups: [Int32] = []
    /// Existing group indices whose tombstone bitsets changed (primitives
    /// newly marked dead) — callers that cache per-group derived state
    /// (e.g. a spatial index) know to invalidate just these.
    var touchedModelGroups: Set<Int32> = []
    var touchedPaperGroups: Set<Int32> = []
    var fullRebuild: Bool = false
    var revision: UInt64 = 0
}

/// Drives incremental regeneration of a `DXFDocument`'s render groups from
/// `EntityStore` commits, per the Phase 1.6 spec. Owns the `entityLocator`
/// and per-group tombstone bitsets; `EditableDocument`/`Transaction` remain
/// unaware of rendering — this is the glue between "a transaction committed"
/// and "the render model reflects it," analogous to how `Regenerator` is the
/// glue between "a freshly parsed store" and "a render model."
final class RegenCoordinator {
    let parsed: EditableParsedDocument
    private(set) var document: DXFDocument
    private(set) var revision: UInt64 = 0

    /// Only entities touched since load appear here — lazily located on
    /// first edit (never populated in bulk; a 3.4M-entity file that's never
    /// edited pays zero cost for this).
    private var entityLocator: [Int32: [PrimitiveSpan]] = [:]

    /// Per-GROUP reverse index (entityId -> local primitive spans), built
    /// lazily THE FIRST TIME any entity inside that group is located, and
    /// reused for every subsequent entity that also turns out to live in the
    /// same group. Without this, locating N touched entities that all
    /// happen to share a handful of large groups costs O(N * that group's
    /// primitive count) — a single `select-box` + `move` touching 10k+
    /// entities on the 731MB file measured ~20s before this cache existed
    /// (see git history / implementation report), versus single-digit
    /// milliseconds after: the group's primitives are scanned ONCE (O(group
    /// size)) no matter how many of the N touched entities live in it.
    private struct GroupSlot: Hashable { var space: SpaceID; var group: Int32 }
    private var groupReverseIndex: [GroupSlot: [Int32: [PrimitiveSpan]]] = [:]

    /// Running counts backing the compaction heuristic. Tracked incrementally
    /// (not recomputed by scanning) so `commit` stays O(touched entities).
    private var tombstonedPrimitiveCount = 0
    private var totalPrimitiveCountAtLastCompaction = 0
    private var deltaGroupCount = 0

    /// Compaction thresholds per the plan: >5% of primitives tombstoned, or
    /// more than 200 delta groups accumulated.
    static let tombstoneRatioThreshold = 0.05
    static let deltaGroupCountThreshold = 200

    /// Blocks touched by a redefinition since the last compaction — every
    /// INSERT of a dirty block needs its expansion regenerated. Phase 1.6
    /// only tracks the set; `regenerateDirtyBlocks` (below) does the actual
    /// work on request (block redefinition isn't reachable from the
    /// `--edit-script` grammar yet, so this is exercised by unit tests only).
    private(set) var dirtyBlocks: Set<String> = []

    /// `OwnerRef.block(index)` -> (base point, xrefId) for every ORPHAN-ROOT
    /// block (a block with real geometry nothing ever INSERTs — see
    /// `Regenerator.build`'s `syntheticRoots`/`walkSyntheticRoot`, whose
    /// exact "which blocks qualify" rule this mirrors). Built lazily once,
    /// on first use, and invalidated by `fullRebuild()` — this is what lets
    /// `emitDelta` recognize "this touched entity lives in an orphan root"
    /// and place it correctly without a full re-walk. This file's real
    /// 731MB fixture is almost ENTIRELY orphan-root content (its model space
    /// is nearly empty by design — see the plan's load-bearing note), so
    /// this table is what makes editing that file's actual geometry cheap.
    private var orphanRootByBlockIndex: [Int32: (base: CGPoint, xrefId: Int16)]? = nil

    /// Whether `blockIndex` is an ORPHAN-ROOT block (see `orphanRootTable()`'s
    /// own doc comment) — exposed (unlike `orphanRootTable()` itself, which
    /// stays `private`) so callers outside this file can tell whether a
    /// block-owned entity (`OwnerRef.block(blockIndex)`) is actually rendered
    /// as top-level content, without needing the full base-point/xrefId
    /// table this file's own incremental-emission path requires. `HatchTool
    /// .isFillable`/`.hatch` use this: a real plant-layout DXF's drawn
    /// content lives almost entirely in orphan-root blocks (this project's
    /// "nearly empty model space" architecture — see this property's own
    /// sibling doc comment), so gating "Fill / Hatch…" on `h.owner.isModel ||
    /// h.owner.isPaper` alone made the button silently never appear for the
    /// overwhelming majority of a real drawing's closed shapes — reported as
    /// "it isn't visible/displaying in the properties pane when selecting
    /// enclosed objects."
    func isOrphanRootBlock(_ blockIndex: Int32) -> Bool {
        orphanRootTable()[blockIndex] != nil
    }

    private func orphanRootTable() -> [Int32: (base: CGPoint, xrefId: Int16)] {
        if let cached = orphanRootByBlockIndex { return cached }
        var insertCounts: [String: Int] = [:]
        for h in parsed.store.headers where h.type == .insert && !h.flags.contains(.deleted) {
            let ip = parsed.store.inserts[Int(h.payload)]
            insertCounts[parsed.store.strings.string(for: ip.blockNameId), default: 0] += 1
        }
        var xrefIdByBlock: [String: Int16] = [:]
        var xrefCount: Int16 = 0
        for (name, b) in parsed.blocks.sorted(by: { $0.key < $1.key }) where b.isXref {
            xrefIdByBlock[name] = xrefCount
            xrefCount += 1
        }
        var table: [Int32: (base: CGPoint, xrefId: Int16)] = [:]
        for (name, b) in parsed.blocks {
            guard b.entityCount > 0, insertCounts[name] == nil, !b.isXrefDependent else { continue }
            let upper = name.uppercased()
            guard !upper.hasPrefix("*"), !upper.hasPrefix("$") else { continue }
            table[b.blockIndex] = (base: b.base, xrefId: xrefIdByBlock[name] ?? -1)
        }
        orphanRootByBlockIndex = table
        return table
    }

    init(parsed: EditableParsedDocument, document: DXFDocument) {
        self.parsed = parsed
        self.document = document
        totalPrimitiveCountAtLastCompaction = Self.totalPrimitiveCount(document)
    }

    /// Convenience: parses (single plain ASCII .dxf ONLY, no xref
    /// resolution/folders/zips/DWG conversion) + fully regenerates, then
    /// wraps the result in a coordinator — the form `--edit-script` and unit
    /// tests use to go from a plain fixture file to an editable,
    /// incrementally-regenerable session. The LIVE APP must NOT use this for
    /// its real "Open File" flow — see `loadPackage(url:progress:)` below,
    /// which is the one that actually matches everything `PackageLoader.load`
    /// (the old, render-only path's entry point) handles.
    static func load(url: URL, progress: @escaping (Double) -> Void = { _ in }) throws -> RegenCoordinator {
        let parsed = try EntityStoreParser.parse(url: url) { progress($0 * 0.7) }
        let doc = Regenerator.build(from: parsed, parseSeconds: 0) { progress(0.7 + $0 * 0.3) }
        return RegenCoordinator(parsed: parsed, document: doc)
    }

    /// The live app's real "Open File" / Reload entry point (Phase 1.7 live
    /// cutover): same input shapes as `PackageLoader.load` (plain .dxf/.dwg,
    /// a folder, an eTransmit .zip) via `PackageLoader.loadIntoStore`
    /// (xrefs resolved, DWG batch-converted, main-drawing heuristic —
    /// everything `load` does), THEN registers the NOVACAD-MARKUP layer
    /// (`MarkupStore.ensureMarkupLayer`) before the first `Regenerator.build`
    /// so it has a real, stable layer id from the very first render (see
    /// that function's doc comment for why the ordering matters — layers are
    /// immutable-after-build, unlike modelGroups/paperGroups). Distinct from
    /// `load(url:progress:)` above, which is deliberately narrower (plain
    /// ASCII DXF only, no markup-layer pre-registration) for the
    /// `--edit-script`/unit-test harness that doesn't need either.
    ///
    /// `isCancelled` and `xrefProgress` pass straight through to
    /// `PackageLoader.loadIntoStore` — see its own doc comments. A large
    /// eTransmit package's xref resolution is the single slowest stage of
    /// opening a file (see `EntityStore.childrenByParent()`'s doc comment
    /// for why that used to be far worse than it needed to be), so it's the
    /// one stage worth reporting per-file progress and honoring
    /// cancellation for.
    static func loadPackage(url: URL,
                            isCancelled: (() -> Bool)? = nil,
                            xrefProgress: ((PackageLoader.XrefProgress) -> Void)? = nil,
                            progress: ((Double) -> Void)? = nil) throws -> RegenCoordinator {
        let parsed = try PackageLoader.loadIntoStore(url: url, isCancelled: isCancelled,
                                                    xrefProgress: xrefProgress,
                                                    progress: { p in progress?(p * 0.85) })
        MarkupStore.ensureMarkupLayer(in: parsed)
        let doc = Regenerator.build(from: parsed, parseSeconds: 0) { p in progress?(0.85 + p * 0.15) }
        return RegenCoordinator(parsed: parsed, document: doc)
    }

    // MARK: - Commit

    /// Computes a LOCAL-space bbox directly from a captured `EntityImage`'s
    /// payload — self-contained, no live-store lookup. Used ONLY to locate
    /// an entity's PRE-EDIT render primitives for tombstoning (see `apply`'s
    /// `beforeBBoxHint`); mirrors `EntityStore.bounds(_:)`'s per-type
    /// geometry exactly (kept in sync manually — both read the same payload
    /// shapes) but never touches store state that a transaction may have
    /// already overwritten.
    private static func bounds(of image: EntityImage) -> CGRect {
        func pointRect(_ p: Vec3) -> CGRect { CGRect(origin: p.cgPoint, size: .zero) }
        func rangeRect(_ pts: [Vec3]) -> CGRect {
            guard !pts.isEmpty else { return .zero }
            var minX = Double.greatestFiniteMagnitude, minY = Double.greatestFiniteMagnitude
            var maxX = -Double.greatestFiniteMagnitude, maxY = -Double.greatestFiniteMagnitude
            for v in pts {
                minX = min(minX, v.x); maxX = max(maxX, v.x)
                minY = min(minY, v.y); maxY = max(maxY, v.y)
            }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
        switch image.payloadCopy {
        case .line(let p): return pointRect(p.a).union(pointRect(p.b))
        case .point(let p): return pointRect(p.p)
        case .circle(let p):
            return CGRect(x: p.center.x - p.radius, y: p.center.y - p.radius, width: p.radius * 2, height: p.radius * 2)
        case .arc(let p):
            // Conservative full-circle bbox, matching EntityStore.bounds(_:).
            return CGRect(x: p.center.x - p.radius, y: p.center.y - p.radius, width: p.radius * 2, height: p.radius * 2)
        case .ellipse(let p):
            let extent = max(p.majorAxisEndpoint.length, p.majorAxisEndpoint.length * p.ratio)
            return CGRect(x: p.center.x - extent, y: p.center.y - extent, width: extent * 2, height: extent * 2)
        case .polyline(_, let verts, _): return rangeRect(verts)
        case .spline(_, let control, _, _): return rangeRect(control)
        case .text(let p): return pointRect(p.position)
        case .mtext(let p): return pointRect(p.insertion)
        case .insert(let p): return pointRect(p.position)
        case .hatch(_, let loops): return loops.reduce(CGRect.null) { $0.union(rangeRect($1)) }
        case .image(let p): return pointRect(p.origin)
        case .viewport(let p): return pointRect(p.centerPaper)
        case .dimension(let p): return pointRect(p.defPoint)
        case .unknown: return .zero
        }
    }

    /// Applies a just-finalized transaction's ops to the render model
    /// incrementally. Must be called AFTER `EditableDocument.commit(tx)` (the
    /// store already reflects the new state) — this only touches the render
    /// side. Returns the delta describing what changed; triggers a full
    /// background-queue-equivalent rebuild internally (synchronous today —
    /// see note below) when compaction thresholds are crossed.
    @discardableResult
    func apply(_ ops: [Transaction.Op]) -> RegenDelta {
        revision += 1
        guard !ops.isEmpty else { return RegenDelta(revision: revision) }

        // `document.layers` is an IMMUTABLE `let` array on `DXFDocument` —
        // there is no way to append a single new entry to it short of
        // replacing `document` wholesale, which is exactly what a full
        // rebuild does. So whenever `parsed.layers` (the live, mutable
        // layer table every `MarkupStore.ensureLayer(...)` call — used by
        // every overlay-layer feature: the AI Assistant's aisle/dock tools,
        // `ShadeLayer`, `DimensionTool`'s auto-created dimension-block
        // layers, "+ New Layer" — appends to) has grown past what
        // `document.layers` currently holds, the render-facing snapshot is
        // now STALE in a way the ordinary incremental primitive-emission
        // path cannot fix on its own, and a full rebuild is required.
        //
        // Before this fix, adding an entity to a genuinely NEW layer stayed
        // on the fast incremental path (new primitives render fine — that
        // part is layer-id-agnostic), silently leaving `document.layers`
        // one or more entries short of `parsed.layers` until something else
        // happened to trigger a full rebuild. `document.layers[i]
        // .entityCount` staying stuck at 0 for that layer (a user-visible
        // symptom on its own — see `layerIdsWithLiveEntities()`'s doc
        // comment) was actually the SMALLER half of the bug: the layer
        // wasn't merely mis-reported, it was flatly ABSENT as an element of
        // `document.layers` at all, which is what made it invisible to the
        // Layers panel and its search box regardless of any `entityCount`
        // filtering fix — a `.count`-bounded array iteration cannot find an
        // index past its own end. Found via `RegenCoordinatorTests
        // .testEntityCountStaysZeroAfterIncrementalAddToANewLayer`
        // attempting to read `document.layers[Int(newLayerId)]`, which
        // crashed outright (index out of range) rather than merely reading
        // a stale 0, since the array was actually too short to hold that
        // index at all.
        if parsed.layers.count > document.layers.count {
            fullRebuild()
            return RegenDelta(fullRebuild: true, revision: revision)
        }

        var touchedIDs = Set<EntityID>()
        // Per-entity "before" bbox hint from the op's captured `EntityImage`
        // (delete/modify only — `add` has no prior state). CRITICAL: this
        // must NOT be derived by calling `parsed.store.bounds(id)` at this
        // point, because `Transaction.modifyPayload`/`setHeader` already
        // wrote the NEW payload into the live store by the time `commit`
        // finishes (see Transactions.swift: "the result is written back
        // immediately") — the live store's bbox for a moved entity is
        // already its NEW position, which can be arbitrarily far from where
        // its OLD, still-rendered (not yet tombstoned) primitives actually
        // sit. Using the current bbox to find those OLD primitives silently
        // filters out the correct candidate group whenever the move
        // distance exceeds the group's own extent — found via a failing
        // unit test (`testModifyTombstonesOldPrimitiveAndEmitsNewOne`)
        // before this fix, where a same-fixture entity moved +100 units in X
        // was never tombstoned because its post-move bbox no longer
        // intersected the delta group holding its pre-move primitive.
        var beforeBBoxHint: [Int32: CGRect] = [:]
        // A pre-existing top-level INSERT being MODIFIED or DELETED (not
        // freshly added) can't be handled incrementally: its block-content
        // primitives are tagged with each LEAF entity's own id (see
        // `Regenerator.emitPrimitive`'s `entityId = e.id.raw`), never the
        // INSERT's own id, and `EntityStore.bounds(_:)` for an `.insert`
        // returns only its single insertion POINT, not the expanded
        // content's world extent — so `locateAll`'s bounds-based candidate
        // search structurally cannot find (to tombstone) or correctly scope
        // (to re-place) that content the way it does for an ordinary
        // entity. `regenerateDirtyBlocks` solves the equivalent problem for
        // BLOCK-DEFINITION edits via `collectDescendantEntityIDs`; a moved/
        // deleted top-level INSERT is the same shape of problem one level
        // up. Rather than duplicate that machinery here for a case no
        // current UI command actually exercises (MOVE/COPY/ROTATE/SCALE/
        // MIRROR of a whole INSERT selection IS reachable today via
        // EntityTransform's `.insert` case, but until now its incremental
        // repaint was silently a no-op/stale-geometry bug, not a crash —
        // conservatively fall back to a full rebuild, matching the exact
        // precedent already used for ATTRIB/VERTEX children and
        // normally-inserted block content below. A freshly ADDED insert
        // (BlockEditor.createBlock/insert, the Stamp-tool rewire — this
        // phase's only INSERT-creating call sites) is unaffected: it has no
        // "before" state to tombstone, so it stays on the fast incremental
        // path via `insertLikeIDs`/`emitInsertSubtree` in `emitDelta` below.
        var forceFullRebuildForInsertChange = false
        for op in ops {
            switch op {
            case .add(let id): touchedIDs.insert(id)
            case .delete(let id, let before):
                touchedIDs.insert(id)
                beforeBBoxHint[id.raw] = Self.bounds(of: before)
                if before.header.type == .insert { forceFullRebuildForInsertChange = true }
            case .modify(let id, let before, _):
                touchedIDs.insert(id)
                beforeBBoxHint[id.raw] = Self.bounds(of: before)
                if before.header.type == .insert { forceFullRebuildForInsertChange = true }
            }
        }
        if forceFullRebuildForInsertChange {
            fullRebuild()
            return RegenDelta(fullRebuild: true, revision: revision)
        }

        var delta = RegenDelta(revision: revision)

        let __t0 = Date()
        // 1) Tombstone every OLD primitive belonging to a touched entity that
        //    already has render geometry (modify/delete of a previously
        //    regenerated entity — a fresh `add` has none yet). Batched
        //    (`locateAll`, not a `locate(_:)` call per id) so a bulk edit
        //    touching thousands of entities that share one huge group scans
        //    that group ONCE for exactly the needed ids, not once per id and
        //    not indexing every OTHER entity in the group we'll never query.
        for (id, spans) in locateAll(Array(touchedIDs), beforeBBoxHint: beforeBBoxHint) {
            for span in spans {
                tombstone(span)
                switch span.space {
                case .model: delta.touchedModelGroups.insert(span.group)
                case .paper: delta.touchedPaperGroups.insert(span.group)
                }
            }
            entityLocator[id] = nil
        }
        let __t1 = Date()

        // 2) Re-emit current geometry for every touched entity that is still
        //    alive (adds and modifies; deletes emit nothing). An entity
        //    whose placement can't be determined unambiguously (content of a
        //    normally-inserted block, or an ATTRIB/VERTEX child) forces a
        //    full rebuild instead — correct, just not incremental for that
        //    case; see `emitDelta`'s doc comment.
        let alive = touchedIDs.filter { !parsed.store.isDeleted($0) }
        var forcedFullRebuild = false
        if !alive.isEmpty {
            let (emitted, needsFullRebuild) = emitDelta(for: Array(alive))
            if needsFullRebuild {
                forcedFullRebuild = true
            } else {
                delta.appendedModelGroups = emitted.modelGroupIndices
                delta.appendedPaperGroups = emitted.paperGroupIndices
                deltaGroupCount += emitted.modelGroupIndices.count + emitted.paperGroupIndices.count
                // The tombstone-ratio compaction heuristic's denominator must
                // grow as new primitives are appended — otherwise it stays
                // pinned at the primitive count from the last full rebuild
                // (or initial load) forever, so ANY tombstone on a document
                // that's since grown via edits looks like it tombstoned a
                // huge fraction of a now-stale, too-small total. (Caught by
                // RegenCoordinatorTests padding a tiny fixture with hundreds
                // of new lines then expecting a SMALL subsequent delete to
                // stay under threshold — it didn't, until this fix.)
                for gi in emitted.modelGroupIndices { totalPrimitiveCountAtLastCompaction += primitiveCount(document.modelGroups[Int(gi)]) }
                for gi in emitted.paperGroupIndices { totalPrimitiveCountAtLastCompaction += primitiveCount(document.paperGroups[Int(gi)]) }
            }
        }
        let __t2 = Date()

        // 3) Compaction check (also forced by step 2's ambiguous-placement case).
        if forcedFullRebuild || shouldCompact() {
            fullRebuild()
            delta.fullRebuild = true
            delta.appendedModelGroups = []
            delta.appendedPaperGroups = []
            delta.touchedModelGroups = []
            delta.touchedPaperGroups = []
        }
        if ProcessInfo.processInfo.environment["NOVACAD_DEBUG_TIMING"] != nil {
            FileHandle.standardError.write(Data(String(
                format: "apply timing: tombstone=%.1fms emit=%.1fms compact=%.1fms\n",
                __t1.timeIntervalSince(__t0) * 1000, __t2.timeIntervalSince(__t1) * 1000,
                Date().timeIntervalSince(__t2) * 1000).utf8))
        }

        return delta
    }

    private func shouldCompact() -> Bool {
        if deltaGroupCount > Self.deltaGroupCountThreshold { return true }
        let total = max(1, totalPrimitiveCountAtLastCompaction)
        let ratio = Double(tombstonedPrimitiveCount) / Double(total)
        return ratio > Self.tombstoneRatioThreshold
    }

    private func tombstone(_ span: PrimitiveSpan) {
        let groups = span.space == .model ? document.modelGroups : document.paperGroups
        guard Int(span.group) < groups.count else { return }
        let group = groups[Int(span.group)]
        let table = GroupTombstoneRegistry.tombstonesCreatingIfNeeded(for: group)
        if table.markDead(span.store, span.index) {
            tombstonedPrimitiveCount += 1
        }
    }

    // MARK: - Locator

    /// Resolves `id` to its current live primitive spans, locating lazily on
    /// first touch by scanning the groups whose bounds intersect `id`'s
    /// bounds (per the plan: "lazily located on first edit by scanning
    /// owning groups within bounds(id)"). A brand-new (never-regenerated)
    /// entity returns empty — nothing to tombstone. Cached afterward so a
    /// second edit to the same entity in a later transaction is O(1).
    /// Batched form of `locate` used by `apply(_:)`: resolves MANY entities'
    /// current primitive spans with ONE targeted pass per candidate group,
    /// instead of one `reverseIndex(for:)` full-group-dictionary build per
    /// entity. This is the difference between O(sum of distinct touched
    /// groups' sizes) [this] and O(touched entities × average group size)
    /// [calling `locate` in a loop] for a bulk edit whose entities share a
    /// small number of very large groups — exactly the 731MB file's shape
    /// (a handful of orphan-root blocks with hundreds of thousands of
    /// primitives each). Falls back to the same per-group candidate
    /// prefilter as `locate`; entities already cached in `entityLocator`
    /// are skipped (no rescan needed).
    private func locateAll(_ ids: [EntityID], beforeBBoxHint: [Int32: CGRect] = [:]) -> [Int32: [PrimitiveSpan]] {
        var result: [Int32: [PrimitiveSpan]] = [:]
        var need: [GroupSlot: Set<Int32>] = [:]
        var wantedRaws = Set<Int32>()

        for id in ids {
            if let cached = entityLocator[id.raw] { result[id.raw] = cached; continue }
            wantedRaws.insert(id.raw)
            for slot in candidateSlots(for: id, beforeBBoxHint: beforeBBoxHint[id.raw]) {
                need[slot, default: []].insert(id.raw)
            }
        }

        for (slot, raws) in need {
            for (raw, spans) in scanForEntities(raws, in: slot) {
                result[raw, default: []].append(contentsOf: spans)
            }
        }
        // Entities that matched no candidate group at all (brand-new, never
        // regenerated) still need a `[:]`-equivalent entry so callers don't
        // re-scan them — `result` simply won't contain them, which the
        // caller treats identically to "empty spans" via dictionary default.
        for raw in wantedRaws where result[raw] == nil { result[raw] = [] }
        return result
    }

    /// The exact same candidate-group prefilter `locate` uses, factored out
    /// so both the single-entity and batched paths share one implementation.
    /// `beforeBBoxHint`, when supplied, is UNIONED with the entity's current
    /// local bbox before computing the world-space candidate box — this is
    /// what makes tombstoning correct after a `modifyPayload`/`setHeader`
    /// edit: by the time `apply(_:)` runs, `parsed.store` already holds the
    /// NEW (post-edit) payload (`Transaction.modifyPayload` writes back
    /// immediately), so the entity's CURRENT bbox reflects where it's
    /// MOVING TO, not where its still-live OLD primitives are rendered.
    /// Using only the current bbox silently drops the group holding those
    /// old primitives whenever the edit moves the entity far enough that the
    /// old and new positions no longer share a candidate group — caught by
    /// `RegenCoordinatorTests.testModifyTombstonesOldPrimitiveAndEmitsNewOne`.
    private func candidateSlots(for id: EntityID, beforeBBoxHint: CGRect? = nil) -> [GroupSlot] {
        let h = parsed.store.header(id)
        let haveLocalBounds = h.map { !($0.payload < 0) } ?? false
        let localBBox = parsed.store.bounds(id)
        var worldBBox: CGRect? = haveLocalBounds ? localBBox : nil
        if let h, h.owner.isBlock {
            if let root = orphanRootTable()[h.owner.raw] {
                worldBBox = haveLocalBounds ? localBBox.offsetBy(dx: -root.base.x, dy: -root.base.y) : nil
            } else {
                worldBBox = nil
            }
        }
        if let hint = beforeBBoxHint {
            // Same local-vs-world adjustment as above, applied to the
            // "before" hint so it lands in the same coordinate space. A
            // hint is always usable (even a zero-SIZE one is a valid single
            // point — see the `CGRect.isEmpty` pitfall noted above) as long
            // as it was actually supplied.
            var hintWorld = hint
            if let h, h.owner.isBlock, let root = orphanRootTable()[h.owner.raw] {
                hintWorld = hint.offsetBy(dx: -root.base.x, dy: -root.base.y)
            }
            worldBBox = worldBBox.map { $0.union(hintWorld) } ?? hintWorld
        }
        var candidates: [GroupSlot] = []
        func collect(_ groups: [RenderGroup], space: SpaceID) {
            for (gi, g) in groups.enumerated() {
                if let wb = worldBBox, !g.bounds.isNull,
                   !g.bounds.intersects(wb.insetBy(dx: -1e-6, dy: -1e-6)) {
                    continue
                }
                candidates.append(GroupSlot(space: space, group: Int32(gi)))
            }
        }
        collect(document.modelGroups, space: .model)
        collect(document.paperGroups, space: .paper)
        return candidates
    }

    /// Scans group `slot` ONCE, returning spans for exactly the entity ids in
    /// `raws` that appear in it (everything else in the group is skipped —
    /// no dictionary entries are allocated for entities nobody asked about).
    /// Does NOT populate `groupReverseIndex` (that cache is for the
    /// full-group case — see `reverseIndex(for:)`, still used by
    /// `regenerateDirtyBlocks`); if `groupReverseIndex` already has this slot
    /// cached (e.g. from an earlier commit), reuses it instead of rescanning.
    private func scanForEntities(_ raws: Set<Int32>, in slot: GroupSlot) -> [Int32: [PrimitiveSpan]] {
        let groups = slot.space == .model ? document.modelGroups : document.paperGroups
        guard Int(slot.group) < groups.count else { return [:] }
        let g = groups[Int(slot.group)]
        // Read the group's CURRENT tombstone state at query time, never
        // cached alongside `groupReverseIndex` — a primitive can be
        // tombstoned by a LATER edit than whenever that cache entry (or this
        // group's own arrays) was populated, and `groupReverseIndex` is only
        // invalidated wholesale on `fullRebuild()`, not per-tombstone. Filter
        // dead spans out of BOTH the cached-index branch and the fresh-scan
        // branch below so a caller (e.g. `resolveToRefs`, used to populate
        // `p.selection`) never resolves a stale/dead primitive that the main
        // render pass would skip — see `CGRenderCore.drawSelection`'s
        // matching tombstone guard for the other half of this fix.
        let tombstones = GroupTombstoneRegistry.tombstones(for: g)
        func isLive(_ span: PrimitiveSpan) -> Bool {
            guard let tombstones else { return true }
            return !tombstones.isDead(span.store, span.index)
        }

        if let cached = groupReverseIndex[slot] {
            var result: [Int32: [PrimitiveSpan]] = [:]
            for raw in raws {
                guard let hit = cached[raw] else { continue }
                let live = hit.filter(isLive)
                if !live.isEmpty { result[raw] = live }
            }
            return result
        }
        var result: [Int32: [PrimitiveSpan]] = [:]
        for (ri, run) in g.strokes.runs.enumerated() where raws.contains(run.entityId) {
            let span = PrimitiveSpan(space: slot.space, group: slot.group, store: .run, index: Int32(ri))
            if isLive(span) { result[run.entityId, default: []].append(span) }
        }
        for (ai, arc) in g.strokes.arcs.enumerated() where raws.contains(arc.entityId) {
            let span = PrimitiveSpan(space: slot.space, group: slot.group, store: .arc, index: Int32(ai))
            if isLive(span) { result[arc.entityId, default: []].append(span) }
        }
        for (ti, t) in g.texts.enumerated() where raws.contains(t.entityId) {
            let span = PrimitiveSpan(space: slot.space, group: slot.group, store: .text, index: Int32(ti))
            if isLive(span) { result[t.entityId, default: []].append(span) }
        }
        for (pi, eid) in g.strokes.pointEntityIds.enumerated() where raws.contains(eid) {
            let span = PrimitiveSpan(space: slot.space, group: slot.group, store: .point, index: Int32(pi))
            if isLive(span) { result[eid, default: []].append(span) }
        }
        for (fi, run) in g.strokes.fillRuns.enumerated() where raws.contains(run.entityId) {
            let span = PrimitiveSpan(space: slot.space, group: slot.group, store: .fillRun, index: Int32(fi))
            if isLive(span) { result[run.entityId, default: []].append(span) }
        }
        return result
    }

    private func locate(_ id: EntityID) -> [PrimitiveSpan] {
        if let cached = entityLocator[id.raw] { return cached }
        let raw = id.raw

        // `EntityStore.bounds(id)` is in the entity's OWN local space — for
        // a true top-level (.model/.paper-owned) entity that IS world space
        // (no transform), but an orphan-root member's rendered position is
        // translated by `-rootBase` (see Regenerator.emitOrphanRootMember),
        // so its local bbox and its actual on-screen bbox differ whenever
        // the root's base isn't the origin. Getting this wrong silently
        // drops the correct candidate group from the prefilter below and
        // leaves a moved/erased entity's OLD primitives un-tombstoned — so
        // this computes the real WORLD bbox per ownership kind, and falls
        // back to "no spatial prefilter" (scan every group) for the one case
        // that can't be resolved this cheaply (content of a normally
        // -inserted block, which can appear at many different transforms).
        //
        // IMPORTANT: `CGRect.isEmpty` is true for any DEGENERATE-but-valid
        // point bbox (zero width AND/OR height — which is EVERY point/text/
        // attrib entity's bbox, `pointRect` in `EntityStore.bounds`), not
        // just for "no bbox available." Conflating those two meanings here
        // previously meant every point-like entity fell into the "unknown
        // bbox, scan every group" branch — on the 731MB file that rebuilt
        // the reverse index for the ENTIRE ~2M-entity document (measured
        // ~300ms) instead of the handful of groups actually containing it.
        // `haveLocalBounds` distinguishes the two: `nil` truly means
        // "we don't know", while `CGRect(origin, .zero)` is a legitimate
        // single-point candidate box.
        let h = parsed.store.header(id)
        let haveLocalBounds = h.map { !($0.payload < 0) } ?? false
        let localBBox = parsed.store.bounds(id)
        var worldBBox: CGRect? = haveLocalBounds ? localBBox : nil
        if let h, h.owner.isBlock {
            if let root = orphanRootTable()[h.owner.raw] {
                worldBBox = haveLocalBounds ? localBBox.offsetBy(dx: -root.base.x, dy: -root.base.y) : nil
            } else {
                worldBBox = nil   // normally-inserted block content: unknown transform, skip prefilter
            }
        }

        // Candidate groups: only those whose bounds could possibly contain
        // the entity (cheap prefilter — a few hundred groups on the 731MB
        // file, checked once per NEW entity, not per primitive). When
        // `worldBBox` is nil, every group is a candidate (correct but
        // O(groups) instead of O(matching groups) — still cheap since group
        // COUNT stays in the hundreds even on the 731MB file).
        var candidates: [GroupSlot] = []
        func collectCandidates(_ groups: [RenderGroup], space: SpaceID) {
            for (gi, g) in groups.enumerated() {
                if let wb = worldBBox, !g.bounds.isNull,
                   !g.bounds.intersects(wb.insetBy(dx: -1e-6, dy: -1e-6)) {
                    continue
                }
                candidates.append(GroupSlot(space: space, group: Int32(gi)))
            }
        }
        collectCandidates(document.modelGroups, space: .model)
        collectCandidates(document.paperGroups, space: .paper)

        var spans: [PrimitiveSpan] = []
        for slot in candidates {
            let index = reverseIndex(for: slot)
            guard let hit = index[raw] else { continue }
            // `reverseIndex`'s cached dictionary can outlive a LATER
            // tombstone written to this same group (the cache is only
            // invalidated wholesale on `fullRebuild()`) — filter live here,
            // at read time, rather than trusting the cache's staleness.
            // Mirrors `scanForEntities`'s identical guard and
            // `CGRenderCore.drawSelection`'s tombstone check; see that
            // function's doc comment for the user-visible bug this closes
            // (a re-selected, recently-edited entity resolving its stale
            // OLD primitive alongside its live new one).
            let groups = slot.space == .model ? document.modelGroups : document.paperGroups
            if Int(slot.group) < groups.count,
               let tombstones = GroupTombstoneRegistry.tombstones(for: groups[Int(slot.group)]) {
                spans.append(contentsOf: hit.filter { !tombstones.isDead($0.store, $0.index) })
            } else {
                spans.append(contentsOf: hit)
            }
        }
        entityLocator[raw] = spans
        return spans
    }

    /// Builds (once) or returns the cached entityId -> [PrimitiveSpan]
    /// reverse index for one group. Cost is O(that group's primitive count),
    /// paid once no matter how many distinct touched entities subsequently
    /// look themselves up in it — this is what turns a bulk edit touching
    /// thousands of entities sharing a handful of groups into O(sum of those
    /// groups' sizes) instead of O(entities × group size).
    private func reverseIndex(for slot: GroupSlot) -> [Int32: [PrimitiveSpan]] {
        if let cached = groupReverseIndex[slot] { return cached }
        let groups = slot.space == .model ? document.modelGroups : document.paperGroups
        guard Int(slot.group) < groups.count else { return [:] }
        let g = groups[Int(slot.group)]
        var index: [Int32: [PrimitiveSpan]] = [:]
        index.reserveCapacity(g.strokes.runs.count + g.strokes.arcs.count + g.texts.count
                              + g.strokes.pointEntityIds.count + g.strokes.fillRuns.count)
        for (ri, run) in g.strokes.runs.enumerated() where run.entityId >= 0 {
            index[run.entityId, default: []].append(
                PrimitiveSpan(space: slot.space, group: slot.group, store: .run, index: Int32(ri)))
        }
        for (ai, arc) in g.strokes.arcs.enumerated() where arc.entityId >= 0 {
            index[arc.entityId, default: []].append(
                PrimitiveSpan(space: slot.space, group: slot.group, store: .arc, index: Int32(ai)))
        }
        for (ti, t) in g.texts.enumerated() where t.entityId >= 0 {
            index[t.entityId, default: []].append(
                PrimitiveSpan(space: slot.space, group: slot.group, store: .text, index: Int32(ti)))
        }
        for (pi, eid) in g.strokes.pointEntityIds.enumerated() where eid >= 0 {
            index[eid, default: []].append(
                PrimitiveSpan(space: slot.space, group: slot.group, store: .point, index: Int32(pi)))
        }
        for (fi, run) in g.strokes.fillRuns.enumerated() where run.entityId >= 0 {
            index[run.entityId, default: []].append(
                PrimitiveSpan(space: slot.space, group: slot.group, store: .fillRun, index: Int32(fi)))
        }
        groupReverseIndex[slot] = index
        return index
    }

    // MARK: - Delta emission

    private struct EmitResult {
        var modelGroupIndices: [Int32] = []
        var paperGroupIndices: [Int32] = []
    }

    /// Emits fresh geometry for `ids` (top-level model/paper entities only —
    /// entities owned by a block are handled via `regenerateDirtyBlocks`, not
    /// here) using the same per-primitive semantics as `Regenerator`
    /// (GroupKey grouping, BYLAYER/BYBLOCK color resolution, mirrorOCS, ...),
    /// but appending brand-new `RenderGroup`s instead of touching existing
    /// ones. Reuses `Regenerator`'s single-entity emission logic via
    /// `Regenerator.emitSingleTopLevel`/`emitOrphanRootMember` (see
    /// Regenerator.swift) so the incremental and full-rebuild paths can't
    /// silently drift. Handles two placements unambiguously cheaply:
    ///   - `.model`/`.paper`-owned (true top-level) entities.
    ///   - Entities owned by an ORPHAN-ROOT block (real geometry nothing
    ///     ever INSERTs — this file's actual content is almost entirely
    ///     this shape; see `orphanRootTable()`).
    /// An entity owned by a NORMALLY-inserted block (placed by one or more
    /// real INSERTs, each with its own transform) can't be placed
    /// unambiguously from the entity alone — `needsFullRebuild` comes back
    /// true for that case and the caller should fall back to a full regen
    /// (or, for a genuine block-definition edit, `regenerateDirtyBlocks`).
    private func emitDelta(for ids: [EntityID]) -> (result: EmitResult, needsFullRebuild: Bool) {
        var modelPrims: [Regenerator.EmittedPrimitive] = []
        var paperPrims: [Regenerator.EmittedPrimitive] = []
        let orphanRoots = orphanRootTable()
        // Top-level INSERT/DIMENSION entities need their referenced block's
        // full subtree expanded (`emitInsertSubtree`), not `emitSingleTopLevel`
        // (which correctly emits nothing for an INSERT — it has no geometry
        // of its own; see that function's guard). Collected separately and
        // batched into one `emitInsertSubtree` call below rather than calling
        // it once per id, matching `regenerateDirtyBlocks`'s own batching.
        // Previously missing entirely: a transaction that ADDS a brand-new
        // INSERT (BlockEditor.createBlock's substituted insert, `insert(...)`,
        // and the Phase 6.1 Stamp-tool rewire all do this) rendered NOTHING
        // until the next full rebuild, because this function's `else`
        // branch below only recognizes ATTRIB/VERTEX children and
        // normally-inserted block CONTENT as "ambiguous, needs full
        // rebuild" — a top-level INSERT itself matched the `isModel`/
        // `isPaper` branch above and silently emitted zero primitives with
        // `needsFullRebuild` staying false, i.e. an apparently-successful
        // commit that was actually invisible until something else (undo/
        // redo, compaction) forced a full rebuild. Found via
        // `testAddingTopLevelInsertRendersImmediatelyWithoutFullRebuild`.
        // NOTE: intentionally `.insert` only, not `.dimension` — DIMENSION's
        // anonymous-block expansion isn't reachable from any Phase 6.1/6.2
        // code path this session adds (nothing here creates/moves a
        // DIMENSION), and `Regenerator.emitInsertSubtree`'s own outer guard
        // only recognizes `h.type == .insert` anyway (see that function) —
        // widening this set to include `.dimension` without also fixing
        // `emitInsertSubtree` itself would silently drop it, which is worse
        // than leaving DIMENSION exactly as ambiguous-placement (full
        // rebuild) as it already was before this change. Left as a
        // documented pre-existing gap, not touched.
        var insertLikeModelIDs: [EntityID] = []
        var insertLikePaperIDs: [EntityID] = []
        for id in ids {
            guard let h = parsed.store.header(id), !h.flags.contains(.deleted) else { continue }
            if h.owner.isModel, h.type == .insert {
                insertLikeModelIDs.append(id)
            } else if h.owner.isPaper, h.type == .insert {
                insertLikePaperIDs.append(id)
            } else if h.owner.isModel || h.owner.isPaper {
                let prim = Regenerator.emitSingleTopLevel(id: id, store: parsed.store, parsed: parsed)
                if h.owner.isModel { modelPrims.append(contentsOf: prim) } else { paperPrims.append(contentsOf: prim) }
            } else if h.owner.isBlock, let root = orphanRoots[h.owner.raw] {
                // Orphan-root content always renders into MODEL space (see
                // `Regenerator.build`: `walkSyntheticRoot` is only ever
                // called alongside `walk(.space(.model), ...)`, never paper).
                let prim = Regenerator.emitOrphanRootMember(id: id, rootBase: root.base, xrefId: root.xrefId,
                                                            store: parsed.store, parsed: parsed)
                modelPrims.append(contentsOf: prim)
            } else {
                // ATTRIB/VERTEX child, or content inside a normally-inserted
                // block — no single unambiguous placement to emit from the
                // entity alone.
                return (EmitResult(), true)
            }
        }
        // `startingIndex` must match EXACTLY what `document.appendInsert`
        // will actually assign — model-space inserts land at the current
        // `modelInsertCount` boundary (NOT `inserts.count`, which would be
        // wrong whenever paper-space inserts already exist — `inserts` is
        // split into two contiguous halves, model first, demarcated by
        // `modelInsertCount`; see `DXFDocument.appendInsert`'s own doc
        // comment), while paper-space inserts land at the true array end.
        //
        // IMPORTANT correctness caveat (found via
        // `RegenCoordinatorTests.testAddingModelInsertAfterExistingPaperInsertPreservesSpaceBoundary`
        // during development): inserting a MODEL-space entry at the
        // `modelInsertCount` boundary, when PAPER-space entries already
        // exist past that point, shifts every existing paper-space entry's
        // ARRAY INDEX up by one — but their ALREADY-EMITTED render
        // primitives (in `paperGroups`) have the OLD index baked into their
        // `insertId` field at emission time, which nothing here retroactively
        // fixes up. That would silently misroute a click on an EXISTING
        // paper-space insert's content to the newly-added model-space one.
        // Rather than implement a full retroactive re-index (a much larger
        // change touching every primitive-store's `insertId` field), this
        // narrow, easy-to-hit case falls back to a full rebuild — matching
        // this file's own established "ambiguous/unsafe incremental case ->
        // full rebuild" precedent used throughout (ATTRIB/VERTEX children,
        // normally-inserted block content, existing-insert modify/delete).
        // A model-space insert added when NO paper-space inserts exist yet
        // (by far the common case — plant-layout DXFs rarely mix paper-space
        // block references with live model-space editing in the same
        // session) stays on the fast incremental path below.
        if !insertLikeModelIDs.isEmpty && document.inserts.count > document.modelInsertCount {
            return (EmitResult(), true)
        }
        if !insertLikeModelIDs.isEmpty {
            let expansion = Regenerator.emitInsertSubtree(ids: insertLikeModelIDs, startingIndex: Int32(document.modelInsertCount),
                                                          store: parsed.store, parsed: parsed)
            for (_, instance) in expansion.instances {
                document.appendInsert(instance, space: .model)
            }
            modelPrims.append(contentsOf: expansion.modelPrimitives)
            paperPrims.append(contentsOf: expansion.paperPrimitives)
            insertIndexByEntityID = nil
        }
        if !insertLikePaperIDs.isEmpty {
            let expansion = Regenerator.emitInsertSubtree(ids: insertLikePaperIDs, startingIndex: Int32(document.inserts.count),
                                                          store: parsed.store, parsed: parsed)
            for (_, instance) in expansion.instances {
                document.appendInsert(instance, space: .paper)
            }
            modelPrims.append(contentsOf: expansion.modelPrimitives)
            paperPrims.append(contentsOf: expansion.paperPrimitives)
            insertIndexByEntityID = nil   // invalidate the cached entityId->index table
        }

        var result = EmitResult()
        if !modelPrims.isEmpty {
            let groups = Regenerator.groupPrimitives(modelPrims)
            for g in groups {
                document.appendGroup(g, space: .model)
                result.modelGroupIndices.append(Int32(document.modelGroups.count - 1))
            }
        }
        if !paperPrims.isEmpty {
            let groups = Regenerator.groupPrimitives(paperPrims)
            for g in groups {
                document.appendGroup(g, space: .paper)
                result.paperGroupIndices.append(Int32(document.paperGroups.count - 1))
            }
        }
        return (result, false)
    }

    // MARK: - Block redefinition (dirtyBlocks)

    /// Marks a block dirty — call after a transaction edits a BLOCK
    /// definition's own entities. All of that block's INSERTs need their
    /// expansion regenerated; per the plan, past the compaction threshold
    /// this should happen as a full background regen rather than an
    /// incremental patch (block content can fan out through many inserts,
    /// each at a different transform, which is exactly the case incremental
    /// per-entity delta emission handles badly).
    func markBlockDirty(_ name: String) {
        dirtyBlocks.insert(name)
    }

    /// Regenerates every INSERT of any block in `dirtyBlocks`. Small numbers
    /// of affected inserts are patched incrementally (tombstone + delta
    /// group, same as `apply`); once the touched-insert count crosses the
    /// same delta-group threshold used for edits, this instead does a full
    /// rebuild — matching the plan's "past threshold -> full regen,
    /// off-main-thread" note. (The `--edit-script` grammar has no block-edit
    /// command yet, so this is exercised by unit tests, not the CLI harness.)
    @discardableResult
    func regenerateDirtyBlocks() -> RegenDelta {
        defer { dirtyBlocks.removeAll() }
        guard !dirtyBlocks.isEmpty else { return RegenDelta(revision: revision) }

        var affectedInserts: [EntityID] = []
        for h in parsed.store.headers.enumerated() {
            let (i, header) = h
            guard !header.flags.contains(.deleted), header.type == .insert, header.payload >= 0 else { continue }
            let name = parsed.store.strings.string(for: parsed.store.inserts[Int(header.payload)].blockNameId)
            if dirtyBlocks.contains(name) {
                affectedInserts.append(EntityID(raw: Int32(i)))
            }
        }
        // Synthetic (never-inserted) orphan roots of a dirty block also need
        // to be re-walked, but they have no INSERT entity to key off of —
        // conservatively force a full rebuild whenever a dirty block has no
        // inserts (i.e. is only reachable as an orphan root), since there is
        // no cheap incremental path for that case.
        let hasOrphanOnlyDirtyBlock = dirtyBlocks.contains { name in
            guard let block = parsed.blocks[name] else { return false }
            return block.entityCount > 0 && !affectedInserts.contains { insertBlockName($0) == name }
        }

        revision += 1
        if hasOrphanOnlyDirtyBlock || affectedInserts.count > Self.deltaGroupCountThreshold {
            fullRebuild()
            return RegenDelta(fullRebuild: true, revision: revision)
        }

        var delta = RegenDelta(revision: revision)
        // Tombstone each affected INSERT's own prior expansion. IMPORTANT:
        // an insert's CHILD geometry (the block content it expands to) is
        // tagged with the CHILD's own `entityId` (e.g. the circle's id, not
        // the insert's) — `Regenerator.build`'s `insertId` field on those
        // same primitives is a POSITIONAL index into `DXFDocument.inserts`
        // (as of the Phase 6.1 fix below, `emitInsertSubtree` DOES stamp a
        // real index here rather than -1, but that index is a DIFFERENT
        // identity space from `entityId` regardless, so the same problem
        // this comment originally described still applies: it's the wrong
        // key to tombstone by). So neither `locate(insertEntityID)` (keys
        // on entityId, which never equals the INSERT's own id for child
        // geometry) nor a naive `insertId` scan (meaningless here) can find
        // the stale primitives directly — found via a failing unit test
        // (testRegenerateDirtyBlocksPatchesSingleInsertIncrementally) where
        // a block-circle-radius edit's re-expansion silently left the OLD
        // circle primitive live. The fix: recursively collect every
        // descendant EntityID the dirty block's content reaches (including
        // through nested INSERTs of OTHER blocks) and tombstone each one via
        // the already-correct entityId-keyed `locateAll`.
        var descendantIDs: [EntityID] = []
        for id in affectedInserts {
            guard let h = parsed.store.header(id), h.payload >= 0 else { continue }
            let name = parsed.store.strings.string(for: parsed.store.inserts[Int(h.payload)].blockNameId)
            collectDescendantEntityIDs(ofBlock: name, depth: 0, into: &descendantIDs)
        }
        for (_, spans) in locateAll(descendantIDs) {
            for span in spans { tombstone(span) }
        }
        for id in descendantIDs { entityLocator[id.raw] = nil }
        // `affectedInserts` are EXISTING top-level inserts (this is a block
        // REDEFINITION, not a fresh add) — each already has a
        // `document.inserts` entry from the last full build/incremental
        // add, so `emitInsertSubtree` must be told to reuse THOSE indices,
        // not allocate fresh ones (which would create duplicate entries for
        // the same EntityID and corrupt `insertIndexTable()`'s
        // one-entityId-to-one-index invariant). Since `emitInsertSubtree`'s
        // `startingIndex` parameter only supports one CONTIGUOUS block of
        // freshly-allocated indices (the shape the `apply(_:)` call site
        // needs), and existing indices for `affectedInserts` are generally
        // NOT contiguous, this call site emits (and re-indexes) ONE insert
        // at a time instead, immediately overwriting each one's existing
        // `document.inserts` slot in place via its ALREADY-known index.
        var expansion = Regenerator.InsertSubtreeResult()
        let insertTable = insertIndexTable()
        for insertID in affectedInserts {
            let insertSpace: SpaceID = (parsed.store.header(insertID)?.owner.isPaper ?? false) ? .paper : .model
            guard let existingIndex = insertTable[insertID.raw] else {
                // No prior document.inserts entry for this id (shouldn't
                // happen for a real, already-rendered insert, but handled
                // defensively rather than silently dropping its geometry):
                // fall back to appending a fresh entry via the same
                // space-aware `appendInsert` the `apply(_:)` call site uses
                // for a brand-new insert.
                let startIdx = insertSpace == .model ? Int32(document.modelInsertCount) : Int32(document.inserts.count)
                let sub = Regenerator.emitInsertSubtree(ids: [insertID], startingIndex: startIdx,
                                                        store: parsed.store, parsed: parsed)
                for (_, instance) in sub.instances { document.appendInsert(instance, space: insertSpace) }
                expansion.modelPrimitives.append(contentsOf: sub.modelPrimitives)
                expansion.paperPrimitives.append(contentsOf: sub.paperPrimitives)
                insertIndexByEntityID = nil   // grew document.inserts — invalidate the cached lookup
                continue
            }
            let sub = Regenerator.emitInsertSubtree(ids: [insertID], startingIndex: existingIndex,
                                                    store: parsed.store, parsed: parsed)
            // Overwrite the existing slot in place (same index, updated
            // position/scale/rotation/layer in case the edit changed the
            // INSERT's own header too — matches what a full rebuild would
            // show) rather than appending.
            if let (_, instance) = sub.instances.first {
                document.setInsert(instance, at: existingIndex)
            }
            expansion.modelPrimitives.append(contentsOf: sub.modelPrimitives)
            expansion.paperPrimitives.append(contentsOf: sub.paperPrimitives)
        }
        if !expansion.modelPrimitives.isEmpty {
            for g in Regenerator.groupPrimitives(expansion.modelPrimitives) {
                document.appendGroup(g, space: .model)
                delta.appendedModelGroups.append(Int32(document.modelGroups.count - 1))
            }
        }
        if !expansion.paperPrimitives.isEmpty {
            for g in Regenerator.groupPrimitives(expansion.paperPrimitives) {
                document.appendGroup(g, space: .paper)
                delta.appendedPaperGroups.append(Int32(document.paperGroups.count - 1))
            }
        }
        deltaGroupCount += delta.appendedModelGroups.count + delta.appendedPaperGroups.count
        if shouldCompact() {
            fullRebuild()
            delta.fullRebuild = true
        }
        return delta
    }

    private func insertBlockName(_ id: EntityID) -> String? {
        guard let h = parsed.store.header(id), h.type == .insert, h.payload >= 0 else { return nil }
        return parsed.store.strings.string(for: parsed.store.inserts[Int(h.payload)].blockNameId)
    }

    /// Collects every `EntityID` that block `name`'s content reaches —
    /// its own direct entities, PLUS (recursively) every entity inside any
    /// block a nested INSERT within it references — since those are exactly
    /// the entities whose `entityId` tag appears somewhere in the block's
    /// expanded render primitives (per `Regenerator.emitPrimitive`, which
    /// always tags a primitive with the LEAF entity's own id, never the
    /// containing insert's). Depth-capped like `Regenerator.build`'s own
    /// walk to guard against a cyclic block reference.
    private func collectDescendantEntityIDs(ofBlock name: String, depth: Int, into out: inout [EntityID]) {
        guard depth <= 32, let block = parsed.blocks[name], block.entityCount > 0 else { return }
        for i in Int(block.entityStart)..<Int(block.entityStart + block.entityCount) {
            let id = EntityID(raw: Int32(i))
            out.append(id)
            if let h = parsed.store.header(id), h.type == .insert, h.payload >= 0 {
                let childName = parsed.store.strings.string(for: parsed.store.inserts[Int(h.payload)].blockNameId)
                collectDescendantEntityIDs(ofBlock: childName, depth: depth + 1, into: &out)
            }
        }
    }

    // MARK: - Compaction

    /// Throws away all delta/tombstone bookkeeping and does a full
    /// `Regenerator.build` rebuild, then swaps it in. Selection is untouched
    /// by this call (it lives in `Set<EntityID>` on the caller's side, per
    /// the plan) — group-index-based state (none exists outside this file)
    /// would need to be rebuilt, which is exactly why nothing outside
    /// `RegenCoordinator` is allowed to hold a bare group index across a
    /// commit boundary.
    ///
    /// NOTE ON THREADING: the plan calls for this to run "on the existing
    /// render queue" / "off-main-thread." `BitmapRenderer` already
    /// coalesces/backgrounds actual pixel rendering; regenerating the
    /// `DXFDocument` itself is a distinct, synchronous, CPU-bound step here
    /// (matching how `Regenerator.build` is invoked synchronously today from
    /// `SnapshotMode`/tests). Wiring compaction onto a background queue with
    /// a UI-visible progress callback is part of the live-app cutover (out
    /// of scope for this phase per the file-scope rules) — this method is
    /// safe to call from a background queue today; it just isn't invoked
    /// from one yet outside of tests written that way.
    func fullRebuild() {
        let newDoc = Regenerator.build(from: parsed, parseSeconds: document.stats.parseSeconds) { _ in }
        document = newDoc
        entityLocator.removeAll()
        groupReverseIndex.removeAll()   // old groups' indices/contents no longer exist
        orphanRootByBlockIndex = nil    // block set/entity counts may have changed
        insertIndexByEntityID = nil     // document.inserts was rebuilt from scratch
        tombstonedPrimitiveCount = 0
        deltaGroupCount = 0
        totalPrimitiveCountAtLastCompaction = Self.totalPrimitiveCount(newDoc)
        dirtyBlocks.removeAll()
    }

    private static func totalPrimitiveCount(_ doc: DXFDocument) -> Int {
        var total = 0
        for g in doc.modelGroups { total += primitiveCount(g) }
        for g in doc.paperGroups { total += primitiveCount(g) }
        return total
    }

    private static func primitiveCount(_ g: RenderGroup) -> Int {
        g.strokes.runs.count + g.strokes.arcs.count + g.texts.count + g.points.count + g.strokes.fillRuns.count
    }

    /// Instance-method convenience so `apply(_:)` can call it without the
    /// `Self.` qualifier noise.
    private func primitiveCount(_ g: RenderGroup) -> Int { Self.primitiveCount(g) }

    // MARK: - Diagnostics (used by --edit-script / tests)

    var tombstonedCount: Int { tombstonedPrimitiveCount }
    var deltaGroupTotal: Int { deltaGroupCount }
    var currentTotalPrimitives: Int { totalPrimitiveCountAtLastCompaction }

    // MARK: - EntityID -> EntityRef resolution (Phase 1.7 live cutover)
    //
    // The live app's rendering/hit-testing/OSNAP code is all wired for
    // positional `EntityRef`s (see `RenderParams.selection`,
    // `CGRenderCore.drawSelection`) — rewriting that whole pipeline to key
    // on `EntityID` is out of scope for this phase (it works correctly and
    // isn't part of what 1.7 asks to change). Selection itself, per the
    // plan, is `Set<EntityID>` end-to-end at the `DocumentSession` level, so
    // each frame needs a cheap `Set<EntityID> -> Set<EntityRef>` promotion
    // to feed the renderer — this reuses the SAME `locateAll` machinery
    // `apply(_:)` uses for tombstoning, so cost is proportional to
    // SELECTION size (typically tens to thousands of objects), not document
    // size, even on the 731MB/3.4M-entity fixture.

    /// entityId -> index into `document.inserts`, built lazily on first use
    /// and invalidated by `fullRebuild()` (inserts array is rebuilt from
    /// scratch then). INSERT entities never appear in `entityLocator`'s
    /// primitive spans (they emit no geometry of their own — see
    /// `emitSingleTopLevel`), so this is a separate index.
    private var insertIndexByEntityID: [Int32: Int32]? = nil

    private func insertIndexTable() -> [Int32: Int32] {
        if let cached = insertIndexByEntityID { return cached }
        var table: [Int32: Int32] = [:]
        table.reserveCapacity(document.inserts.count)
        for (i, ins) in document.inserts.enumerated() where ins.entityId >= 0 {
            table[ins.entityId] = Int32(i)
        }
        insertIndexByEntityID = table
        return table
    }

    /// Resolves a set of stable `EntityID`s (e.g. `DocumentSession.selection`)
    /// to the positional `EntityRef`s currently addressing their live render
    /// geometry — for feeding `RenderParams.selection`/anything else still
    /// keyed on `EntityRef`. An id with no resolvable geometry (freshly
    /// added but not yet regenerated — shouldn't happen post-commit since
    /// `apply` always emits geometry for surviving adds; or content of a
    /// normally-inserted block, whose members have no single unambiguous
    /// `EntityRef.primitive` — that content resolves via its owning INSERT's
    /// `EntityID` instead) is simply omitted, not an error.
    func resolveToRefs(_ ids: Set<EntityID>) -> Set<EntityRef> {
        guard !ids.isEmpty else { return [] }
        var result: Set<EntityRef> = []
        let insertTable = insertIndexTable()
        var loose: [EntityID] = []
        for id in ids {
            if let insertIdx = insertTable[id.raw] {
                result.insert(.insert(insertIdx))
            } else {
                loose.append(id)
            }
        }
        if !loose.isEmpty {
            for (raw, spans) in locateAll(loose) {
                for span in spans {
                    result.insert(.primitive(group: span.group, store: span.store, index: span.index))
                }
                _ = raw
            }
        }
        return result
    }

    /// The set of layer ids with at least one currently-alive entity —
    /// computed FRESH from `parsed.store.headers` (a single O(entities)
    /// linear scan), never from `document.layers[i].entityCount`.
    ///
    /// This distinction is exactly the bug behind a real user report: a
    /// layer created by an edit (the AI Assistant's overlay-layer tools,
    /// `ShadeLayer`, `DimensionTool`'s auto-created dimension-block layers,
    /// any `MarkupStore.ensureLayer(...)` call site) goes through
    /// `RegenCoordinator.apply`'s INCREMENTAL path, which emits new render
    /// groups but — unlike a full `Regenerator.build`/`fullRebuild()` — never
    /// recomputes `document.layers[i].entityCount`. That field is a `let`-
    /// like snapshot baked in at the last full rebuild; a freshly created
    /// layer starts at 0 and silently STAYS 0 (invisible to the Layers panel
    /// and its search box, which both gate on `entityCount > 0`) until
    /// something ELSE happens to trigger a full rebuild — which, on a small
    /// working session, may never happen. The layer still exists in
    /// `document.layers` (which is why "Current Layer" dropdown — driven
    /// straight off `document.layers.map(\.name)`, no `entityCount` gate at
    /// all — could see it fine while the panel/search couldn't), so the
    /// symptom was specifically "I can pick this layer from the dropdown but
    /// can never find it to select/delete its contents."
    ///
    /// Also incidentally covers a second, independent shape of the same
    /// user-visible symptom: entities that live inside a BLOCK DEFINITION
    /// that is never actually instantiated anywhere in model/paper space
    /// (`document.layers[i].entityCount` only counts entities reachable
    /// through the block-instantiation walk) — those entities are just as
    /// real and just as deserving of "found by search, deletable" as
    /// anything else, and this scan finds them too since it reads the raw
    /// store, not the render-reachability graph.
    func layerIdsWithLiveEntities() -> Set<Int32> {
        var ids = Set<Int32>()
        for h in parsed.store.headers {
            guard !h.flags.contains(.deleted), h.layerId >= 0 else { continue }
            ids.insert(h.layerId)
        }
        return ids
    }

    /// Deletes EVERY currently-alive entity whose header references
    /// `layerId` — the robust "Delete Layer" primitive that works regardless
    /// of whether those entities are reachable through block instantiation
    /// (unlike `selectLayer`-style approaches that walk `document.modelGroups`
    /// /`paperGroups`, which only contains entities the render walk actually
    /// reached). Reads directly from `parsed.store.headers`, exactly like
    /// `layerIdsWithLiveEntities()` above, for the identical reason: a stale/
    /// zero `entityCount` or an uninstantiated block must never make an
    /// entity "invisible" to deletion. Entities are queued as ordinary
    /// `Transaction.delete` ops, so this is fully undoable like any other
    /// edit — the caller commits them via `session.performEdit` (or an
    /// equivalent `Transaction`), never here directly, keeping this a pure
    /// query (find what to delete), not a document mutation.
    func entityIDsOnLayer(_ layerId: Int32) -> [EntityID] {
        var ids: [EntityID] = []
        for i in parsed.store.headers.indices {
            let h = parsed.store.headers[i]
            guard !h.flags.contains(.deleted), h.layerId == layerId else { continue }
            ids.append(EntityID(raw: Int32(i)))
        }
        return ids
    }
}
