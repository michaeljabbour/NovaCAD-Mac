import CADCore
import Foundation

// MARK: - Phase 3: handle graph allocation for the structural DXF writer
//
// AutoCAD's file format is fundamentally a handle graph: every table record,
// block, entity, and object has a unique hex handle, and cross-references
// (330 owner, 340/360 various, 390 plot-style, etc.) are handle pointers into
// that same space. Getting this wrong is the single most likely reason a
// written file fails to open in real AutoCAD — worse than a cosmetic
// version-degrade miss, a bad or colliding handle can make AutoCAD refuse
// the whole file or silently corrupt the drawing database on save.
//
// Strategy (matches the plan's 3.1 spec exactly):
//   1. Seed the allocator at max($HANDSEED from the source, max handle
//      actually observed anywhere in the parsed document) + 1 — never reuse
//      a handle that already means something in the source file, even if
//      $HANDSEED under-reported it (some real files have a stale/low
//      $HANDSEED relative to their actual max handle; DXFWriter.swift's
//      existing `writeMergedCopy` uses the identical max-of-both strategy).
//   2. Pass 1 (before any bytes are written): walk every record that will be
//      emitted (tables, blocks, entities, objects) and assign a FRESH handle
//      to any one that doesn't already have one (new entities added via
//      Transaction, or R12-sourced content with no handles at all).
//      Existing handles are NEVER reassigned — foreign/unknown pointer
//      graphs the parser didn't fully interpret (residual pairs, XDATA
//      handle refs, OBJECTS entries) stay valid without this writer needing
//      to understand what they mean.
//   3. Pass 2 (during emission) reads the now-fully-populated handle map.
//
// This type is a pure bookkeeping allocator — it does not know about DXF
// section structure at all, just "give me a fresh handle" and "what handle
// did I already assign to this key".
final class HandleAllocator {
    private var next: UInt64

    init(startingAfter maxSeen: UInt64) {
        // Handle 0 is reserved ("no handle" sentinel throughout this
        // codebase's model types), so the allocator never hands it out even
        // if `maxSeen` is 0 (an all-R12/handle-less source).
        next = max(maxSeen, 0) + 1
    }

    /// Hands out a fresh, never-before-used handle.
    func allocate() -> UInt64 {
        defer { next += 1 }
        return next
    }

    /// Advances the allocator by `count` WITHOUT handing any of those
    /// handles out — used to reserve a range for a second, independent
    /// allocator to then draw from (see `HandleGraph.dynamicHandles`'s doc
    /// comment for why this two-allocator split exists).
    func skip(_ count: Int) {
        next += UInt64(count)
    }

    /// The value `$HANDSEED` must be written as, once allocation is done:
    /// one past the highest handle this allocator has ever handed out (DXF
    /// convention — $HANDSEED is "the next handle AutoCAD will use", not the
    /// last one used).
    var handseed: UInt64 { next }
}

// MARK: - Handle graph resolution result

/// Bookkeeping produced by the writer's pass 1 (handle assignment) that pass
/// 2 (emission) consults. Not persisted — rebuilt fresh on every `write`
/// call, scoped to the lifetime of one write operation.
final class HandleGraph {
    let allocator: HandleAllocator

    /// Entity handle, keyed by `EntityID.raw` — every entity that will be
    /// emitted (model/paper/block-owned, including ATTRIB/VERTEX-shaped
    /// children) gets an entry here during pass 1, whether it already had a
    /// parsed handle or needed a freshly allocated one.
    var entityHandles: [Int32: UInt64] = [:]

    /// BLOCK_RECORD handle for each block, keyed by block name
    /// (case-preserved as stored in `EditableParsedDocument.blocks`/the
    /// synthesized model/paper space names) — every block gets exactly one
    /// BLOCK_RECORD, shared by its `0/BLOCK` table-of-contents entry and every
    /// INSERT that references it by name.
    var blockRecordHandles: [String: UInt64] = [:]
    /// The `0/BLOCK`-record's own handle (distinct from its BLOCK_RECORD),
    /// keyed the same way.
    var blockEntityHandles: [String: UInt64] = [:]
    /// `0/ENDBLK`'s own handle, keyed the same way.
    var endBlkHandles: [String: UInt64] = [:]

    /// LAYER/LTYPE handles, keyed by id (`DXFLayer.id` / linetype index) —
    /// these two table types keep their own `handle` field on the model
    /// struct already (Phase 3 groundwork), but a NEWLY layer/linetype
    /// created after parse (not possible yet from any editing tool as of
    /// this session, but future-proofed) would have `handle == 0` and need
    /// one allocated here.
    var layerHandles: [Int32: UInt64] = [:]
    var linetypeHandles: [Int16: UInt64] = [:]

    /// VPORT/STYLE/VIEW/UCS/APPID/DIMSTYLE symbol-table record handles,
    /// keyed by (tableType, index-into-that-table's-array) since names are
    /// not guaranteed unique across malformed sources (they should be within
    /// a well-formed file, but index is unambiguous either way).
    var symbolRecordHandles: [String: [Int: UInt64]] = [:]

    /// A SECOND, independent allocator for "dynamic" handles — the ones
    /// consumed by a single entity's pass-2 emission expanding into
    /// MULTIPLE DXF records whose exact count isn't cheaply representable
    /// as a per-entity lookup table (POLYLINE's VERTEX/SEQEND children,
    /// degraded MTEXT's per-line TEXT records, degraded HATCH's
    /// boundary-loop chains, an INSERT-with-ATTRIB-children's closing
    /// SEQEND).
    ///
    /// Why TWO allocators instead of one: pass 1 (`DXFHandleGraphBuilder`)
    /// must determine the FINAL `$HANDSEED` — which has to account for
    /// every dynamic handle pass 2 will ever consume — before HEADER (the
    /// first section) is written. But pass 1 counting "how many extra
    /// handles will entity X need" is necessarily a SEPARATE walk from pass
    /// 2 actually consuming them during emission. If both walks pulled from
    /// the SAME counter, pass 1's counting walk would itself advance the
    /// counter, and pass 2 would then draw a DIFFERENT, higher range than
    /// what `$HANDSEED` (computed right after pass 1) accounted for —
    /// exactly the bug caught during development (`$HANDSEED` undercounting
    /// by exactly the number of dynamic handles, because pass 1's counting
    /// pass and pass 2's real pass both incremented the one shared
    /// allocator independently).
    ///
    /// The fix: pass 1 counts the TOTAL dynamic handles needed (pure
    /// arithmetic, no allocation), reserves that many on the MAIN allocator
    /// via `HandleAllocator.skip(_:)` (so `$HANDSEED` accounts for them),
    /// and hands pass 2 a FRESH allocator seeded at the range the main
    /// allocator had BEFORE that skip — since pass 1 and pass 2 walk
    /// entities in the identical order (`store.headers.indices`, ascending),
    /// pass 2's calls into `dynamicHandles.allocate()` consume exactly the
    /// same handles, in exactly the same order, that pass 1 reserved for
    /// them — no double-consumption, no drift.
    var dynamicHandles: HandleAllocator

    /// ATTRIB/VERTEX-style children, keyed by PARENT `EntityID.raw` — built
    /// once, O(n), by `DXFStructuralWriter`'s pass 1 (see
    /// `buildHandleGraph`), so the ENTITIES/BLOCKS pass-2 walk can look up
    /// "does this INSERT have ATTRIBs" in O(1) instead of `EntityStore
    /// .children(of:)`'s linear scan — which would make the whole write
    /// O(n^2) at 2.35M+ entities (that scan is fine for `children(of:)`'s
    /// existing UI-driven call sites, which fire once per user click, not
    /// once per entity in a bulk file write).
    var childrenByParent: [Int32: [EntityID]] = [:]

    /// Fixed, well-known handles this writer always allocates itself (never
    /// sourced from the parse) for the handful of root/table-owner objects
    /// every DXF needs: the TABLES section's own table-header records (e.g.
    /// "0/TABLE" itself carries a handle+330 pointing at nothing in
    /// practice for most tables) and — most importantly — the OBJECTS
    /// section root dictionary when the source had none at all (a bare-bones
    /// R12-esque source promoted to AC1015+ needs a minimal OBJECTS section
    /// synthesized).
    var syntheticRootDictionaryHandle: UInt64? = nil
    var syntheticLayoutDictHandle: UInt64? = nil
    var syntheticLayoutObjectHandle: UInt64? = nil
    var syntheticGroupDictHandle: UInt64? = nil
    var syntheticImageDictHandle: UInt64? = nil

    /// Table-header ("0\nTABLE\n5\n<handle>\n330\n0\n100\nAcDbSymbolTable")
    /// handles, one per TABLES table, keyed by table name ("VPORT", "LAYER", ...).
    var tableHeaderHandles: [String: UInt64] = [:]

    init(allocator: HandleAllocator, dynamicHandles: HandleAllocator) {
        self.allocator = allocator
        self.dynamicHandles = dynamicHandles
    }

    /// Every handle value this graph has already handed out via
    /// `reuseOrAllocate`, across EVERY call site — entities, layers,
    /// linetypes, the generic STYLE/VIEW/UCS/APPID/DIMSTYLE symbol tables,
    /// VPORT, and every block's `blockEntityHandles`/`blockRecordHandles`.
    /// Fresh handles drawn from `allocator`/`dynamicHandles` are guaranteed
    /// unique by construction (monotonically increasing counters), but
    /// REUSED (parsed-from-source) handles are not: nothing stops a
    /// malformed or hand-edited source file from assigning the same handle
    /// to, say, a LAYER and an ENTITY (illegal in a well-formed AutoCAD
    /// file, but not something this codebase's parser defends against). If
    /// two different pass-1 call sites both reused such a colliding source
    /// handle unchecked, pass 2 would silently emit two different DXF
    /// records sharing one `5`/handle — the exact invariant AutoCAD polices
    /// strictly (see HandleAllocator's file-level doc comment). Tracking
    /// claims HERE, inside the one chokepoint every call site already goes
    /// through, means the fix applies uniformly without relying on every
    /// future call site remembering to check a set by hand.
    private var claimedHandles: Set<UInt64> = []

    /// Returns `existing` unchanged if non-zero AND not already claimed by
    /// an earlier call, otherwise allocates and returns a fresh handle — the
    /// single chokepoint every "does this record already have a handle"
    /// check in pass 1 goes through, so the "never reassign an existing
    /// handle" invariant AND the "never hand out the same handle twice"
    /// invariant can't be violated by a call-site mistake. Callers do not
    /// need to (and should not) maintain their own dedup set — this method
    /// is the shared source of truth across the whole two-pass builder.
    func reuseOrAllocate(_ existing: UInt64) -> UInt64 {
        let candidate = (existing != 0 && !claimedHandles.contains(existing)) ? existing : 0
        let assigned = candidate != 0 ? candidate : allocator.allocate()
        claimedHandles.insert(assigned)
        return assigned
    }
}
