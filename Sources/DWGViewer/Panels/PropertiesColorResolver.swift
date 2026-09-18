import Foundation
import CoreGraphics
import CADCore

// MARK: - Effective color of a selection (Properties panel)
//
// Answers "what color IS this object, as drawn?" for the Properties panel's
// Color swatch.
//
// ---- Why this exists rather than reading EntityHeader.aci directly ----
//
// This is the same bug class as `PropertiesPanelLayerResolutionTests`' "the
// layer always says 0 in properties": the panel read a RAW header field
// instead of the RESOLVED value the renderer paints with, so any object whose
// appearance is INHERITED rather than stored locally displayed something
// wrong.
//
// A DXF entity's color is frequently not on the entity at all:
//
//  - `aci == 256` (BYLAYER) — the color lives on the layer. This is the
//    overwhelming majority of real geometry.
//  - `aci == 0` (BYBLOCK) — the color comes from the owning INSERT.
//  - Block/xref content authored on layer 0 — inherits the owning INSERT's
//    LAYER (and therefore that layer's color) via layer-0 substitution, the
//    standard authoring convention. Reading its stored `layerId == 0` yields
//    layer 0's color, which is usually not what is drawn.
//
// So this resolves through the same render model (`RenderGroup.color`,
// `InsertInstance.layerId`) that `HitTester.properties(for:)` and the
// renderer already agree on, via `RegenCoordinator.resolveToRefs` — exactly
// the path `PropertiesPanel.layerBinding`'s getter was corrected to use.
enum PropertiesColorResolver {

    /// The single effective color of `selection`, or `.foreground` when the
    /// selection is empty, unresolvable, or genuinely mixed.
    ///
    /// A mixed selection deliberately reports `.foreground` rather than the
    /// first entity's color: showing one member's color as though it applied
    /// to all of them is how a user ends up believing they've inspected
    /// something they haven't. Callers that need to distinguish "mixed" from
    /// "genuinely foreground" use `isMixed` alongside this.
    static func color(for selection: Set<EntityID>, parsed: EditableParsedDocument,
                      document: DXFDocument, space: SpaceID) -> ResolvedColor {
        let colors = distinctColors(for: selection, parsed: parsed, document: document, space: space)
        guard colors.count == 1, let only = colors.first else { return .foreground }
        return only
    }

    /// True when the selection resolves to more than one distinct color.
    static func isMixed(for selection: Set<EntityID>, parsed: EditableParsedDocument,
                        document: DXFDocument, space: SpaceID) -> Bool {
        distinctColors(for: selection, parsed: parsed, document: document, space: space).count > 1
    }

    /// Every distinct effective color across the selection.
    static func distinctColors(for selection: Set<EntityID>, parsed: EditableParsedDocument,
                               document: DXFDocument, space: SpaceID) -> Set<ResolvedColor> {
        guard !selection.isEmpty else { return [] }
        var result: Set<ResolvedColor> = []
        let store = parsed.store

        for id in selection {
            guard let header = store.header(id), !header.flags.contains(.deleted) else { continue }

            // An explicit TRUE COLOR on the entity always wins — it is a
            // concrete paint value, never inherited.
            if (header.trueColor >> 24) != 0xFF {
                result.insert(.rgb(header.trueColor & 0x00FF_FFFF))
                continue
            }

            // An explicit INDEX color (not BYLAYER 256, not BYBLOCK 0) is
            // likewise concrete. ACI 7 is `.foreground`, not literal white —
            // that distinction is the whole point of `ResolvedColor`.
            if header.aci != 256 && header.aci != 0 {
                result.insert(header.aci == 7 ? .foreground
                                              : .rgb(ACIPalette.rgb(forACI: Int(header.aci))))
                continue
            }

            // Inherited (BYLAYER / BYBLOCK): resolve through the render model,
            // which has already applied layer-0 substitution and BYBLOCK
            // inheritance for us.
            if let inherited = resolvedColorFromRenderModel(id, document: document, space: space) {
                result.insert(inherited)
                continue
            }

            // Last resort: the entity's own stored layer. Reached only when
            // the render model has no ref for this id (e.g. it is inside a
            // block definition that isn't currently instanced anywhere).
            let layerIndex = Int(header.layerId)
            if layerIndex >= 0, layerIndex < document.layers.count {
                result.insert(document.layers[layerIndex].color)
            } else {
                result.insert(.foreground)
            }
        }
        return result
    }

    /// The color the RENDERER uses for this entity, looked up through the same
    /// `resolveToRefs` mapping the rest of the panel relies on.
    private static func resolvedColorFromRenderModel(_ id: EntityID, document: DXFDocument,
                                                     space: SpaceID) -> ResolvedColor? {
        let groups = space == .paper ? document.paperGroups : document.modelGroups

        // A loose primitive: its RenderGroup already carries the fully
        // resolved color.
        for (index, group) in groups.enumerated() {
            _ = index
            if group.strokes.runs.contains(where: { $0.entityId == id.raw })
                || group.strokes.arcs.contains(where: { $0.entityId == id.raw })
                || group.texts.contains(where: { $0.entityId == id.raw }) {
                return group.color
            }
        }

        // An INSERT: use its resolved layer's color (an INSERT drawn BYLAYER
        // takes the layer it is placed on, which is what the user sees).
        for insert in document.inserts where insert.entityId == id.raw {
            let layerIndex = Int(insert.layerId)
            guard layerIndex >= 0, layerIndex < document.layers.count else { return nil }
            return document.layers[layerIndex].color
        }
        return nil
    }
}
