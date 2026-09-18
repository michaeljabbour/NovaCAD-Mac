import Foundation

/// Shared BYLAYER/BYBLOCK/true-color/layer-0-in-block inheritance logic,
/// operating on `EntityStore`/`EditableParsedDocument`'s NATIVE header
/// representation (`aci`/`trueColor`/`linetypeId` sentinels), not the
/// render-facing `ResolvedColor` enum `Regenerator` produces for painting.
///
/// This is the Phase 6.2 "PropertyResolver extracted from GeometryBuilder's
/// resolve (lines 205-228)" the plan calls for — but literally extracted
/// from `Regenerator.resolveAppearance` (the NEW-path equivalent that
/// already operates on `EntityStore`/`EditableParsedDocument` types), not
/// from `GeometryBuilder.swift` itself, which is permanently frozen (see
/// that file's header comment / this project's non-negotiable constraints).
/// `GeometryBuilder.swift` predates `EntityStore` entirely — it has no
/// access to the types this resolver needs — so a literal move from there
/// was never possible; `Regenerator.resolveAppearance`'s logic is verified
/// byte-for-byte identical to `GeometryBuilder.resolve`'s (both hand-audited
/// against each other when Regenerator was first written), so extracting
/// from Regenerator carries the exact same load-bearing behavior forward.
///
/// `Regenerator.resolveAppearance` becomes a thin wrapper around this that
/// maps the native result to `ResolvedColor` for rendering — see that
/// function's updated body. EXPLODE (`Editing/Explode.swift`) is the other
/// consumer: it needs the resolved values in NATIVE header form (so it can
/// write a concrete `aci`/`trueColor`/`linetypeId`/`layerId` onto a
/// newly-created top-level entity), which `ResolvedColor` cannot express
/// (it collapses BYLAYER-vs-explicit-ACI-vs-true-color into a single "here
/// is a paintable color" value, discarding exactly the distinction EXPLODE
/// needs to preserve/bake correctly).
enum PropertyResolver {

    /// The inherited-from-parent-INSERT context a block's content is walked
    /// under. Mirrors `Regenerator.Ctx`'s three inheritance-relevant fields
    /// exactly (`subLayer`/`byBlockColor`/`byBlockLinetype`), but keeps
    /// BYBLOCK color in NATIVE form (aci + trueColor) instead of
    /// `ResolvedColor`, so a chain of nested BYBLOCK inheritance (an entity
    /// inside a block-within-a-block, itself BYBLOCK) round-trips exactly
    /// through repeated calls to this resolver without ever materializing a
    /// render-only color type in between.
    struct BlockContext {
        /// The layer a child entity declared as layer "0" should use instead
        /// — set to the owning INSERT's own RESOLVED layer. `nil` at the top
        /// level (model/paper space; no inheritance in effect).
        var subLayer: Int32?
        /// The owning INSERT's resolved color, in native form — used when a
        /// child entity's `aci == 0` (BYBLOCK).
        var byBlockAci: Int16
        var byBlockTrueColor: UInt32
        /// The owning INSERT's resolved linetype id — used when a child
        /// entity's `linetypeId == -2` (BYBLOCK).
        var byBlockLinetypeId: Int16

        /// The context at the top level (model/paper space, or an
        /// orphan-root block with no owning INSERT) — no substitution layer,
        /// and BYBLOCK falls back to "foreground"/CONTINUOUS exactly like
        /// `Regenerator.Ctx()`'s default (`byBlockColor = .foreground`,
        /// `byBlockLinetype = 0`).
        static let topLevel = BlockContext(subLayer: nil, byBlockAci: 7, byBlockTrueColor: 0xFF00_0000, byBlockLinetypeId: 0)
    }

    /// One entity's fully-resolved appearance, in native header form —
    /// ready to be written directly onto a new `EntityHeader`/`EntityPrototype`.
    struct Resolved {
        var layerId: Int32
        /// Final ACI. Never 0 (BYBLOCK) — always either 256 (BYLAYER, when
        /// the source entity itself was declared BYLAYER and the caller
        /// wants to preserve that dynamism rather than bake a color) or an
        /// explicit 1-255 ACI. See `resolveForExplode` for the BYBLOCK vs
        /// BYLAYER preservation policy.
        var aci: Int16
        var trueColor: UInt32
        /// Final linetype id. Same BYLAYER-preservation convention as `aci`.
        var linetypeId: Int16
    }

    /// Core inheritance algorithm — identical decision tree to
    /// `GeometryBuilder.resolve`/`Regenerator.resolveAppearance`:
    /// 1. Layer "0" inside a block substitutes the owning INSERT's layer.
    /// 2. True color (if set) wins outright.
    /// 3. ACI 0 = BYBLOCK -> inherit the owning INSERT's resolved color.
    /// 4. ACI 256 = BYLAYER -> left AS BYLAYER here (native form keeps this
    ///    dynamic rather than eagerly looking up the layer's paint color,
    ///    unlike `Regenerator`'s `ResolvedColor` output, which must be a
    ///    concrete paintable value) — callers that need a concrete color
    ///    call `layerColor`/`layerLinetype` on the RETURNED `layerId`
    ///    themselves (`Regenerator`'s wrapper does exactly this).
    /// 5. Explicit ACI/linetype pass through unchanged.
    /// Linetype: -1 = BYLAYER (kept dynamic, same rationale as color), -2 =
    /// BYBLOCK -> inherit the owning INSERT's resolved linetype, else explicit.
    static func resolve(layerId: Int32, aci: Int16, trueColor: UInt32, linetypeId: Int16,
                        in ctx: BlockContext) -> Resolved {
        let layer: Int32 = (layerId == 0 && ctx.subLayer != nil) ? ctx.subLayer! : layerId

        let outAci: Int16
        let outTrueColor: UInt32
        if trueColor != 0xFF00_0000 {
            // `aci` is "preserved for fidelity" here ONLY when it isn't
            // itself BYBLOCK — an entity that is simultaneously BYBLOCK
            // (aci==0) AND has an explicit true color set is a real DXF
            // shape (some writers stamp both group 62=0 and group 420) and
            // must still resolve `aci` to `ctx.byBlockAci`, not leak the
            // raw 0 through: `Resolved.aci`'s own documented invariant is
            // "never 0," and downstream consumers (the DXF writer's own
            // color-emission logic, and EXPLODE baking this onto a
            // brand-new top-level header) both assume that invariant holds
            // — a leaked aci==0 on a top-level (no owning INSERT) entity is
            // undefined in real AutoCAD and round-trips as malformed BYBLOCK
            // usage outside any block reference. Found by adversarial
            // review; the trueColor value itself is unaffected either way
            // (it always wins as the actual paint color).
            outAci = aci == 0 ? ctx.byBlockAci : aci
            outTrueColor = trueColor
        } else if aci == 0 {
            outAci = ctx.byBlockAci
            outTrueColor = ctx.byBlockTrueColor
        } else {
            outAci = aci   // BYLAYER (256), foreground (7), or explicit — passthrough
            outTrueColor = 0xFF00_0000
        }

        let outLinetype: Int16
        switch linetypeId {
        case -2: outLinetype = ctx.byBlockLinetypeId
        default: outLinetype = linetypeId   // BYLAYER (-1) or explicit — passthrough
        }

        return Resolved(layerId: layer, aci: outAci, trueColor: outTrueColor, linetypeId: outLinetype)
    }

    /// EXPLODE-oriented convenience: resolves a child entity's appearance
    /// against its owning INSERT's OWN resolved appearance (which the
    /// caller has already computed via a top-level `resolve` call against
    /// THAT insert's header), producing header fields ready to paste onto
    /// the new top-level entity `tx.replace`/`tx.add` will create.
    ///
    /// AutoCAD's real EXPLODE behavior this preserves: an entity that was
    /// BYBLOCK bakes to the insert's resolved concrete color/linetype
    /// (matching AutoCAD — BYBLOCK has no meaning once the entity is no
    /// longer inside a block reference); an entity that was BYLAYER STAYS
    /// BYLAYER (on its resolved layer, which may now differ from its
    /// original declared layer if it was layer "0" inside the block) rather
    /// than baking a concrete color, since BYLAYER remains meaningful at
    /// the top level and AutoCAD does not eagerly bake it either.
    static func resolveForExplode(entityLayerId: Int32, entityAci: Int16, entityTrueColor: UInt32,
                                  entityLinetypeId: Int16, insertResolved: Resolved) -> Resolved {
        let ctx = BlockContext(subLayer: insertResolved.layerId,
                               byBlockAci: insertResolved.aci,
                               byBlockTrueColor: insertResolved.trueColor,
                               byBlockLinetypeId: insertResolved.linetypeId)
        return resolve(layerId: entityLayerId, aci: entityAci, trueColor: entityTrueColor,
                       linetypeId: entityLinetypeId, in: ctx)
    }

    /// Resolves a top-level INSERT's own appearance (no parent context —
    /// an INSERT sitting directly in model/paper space, or one already
    /// baked one level deep for a nested-INSERT explode). Thin convenience
    /// so call sites don't need to spell out `BlockContext.topLevel` by hand.
    static func resolveTopLevel(layerId: Int32, aci: Int16, trueColor: UInt32, linetypeId: Int16) -> Resolved {
        resolve(layerId: layerId, aci: aci, trueColor: trueColor, linetypeId: linetypeId, in: .topLevel)
    }
}
