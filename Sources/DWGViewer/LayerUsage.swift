import CADCore
import CoreGraphics

struct LayerUsage {
    var count = 0
    var bounds = CGRect.null
    static func summary(document: DXFDocument, paper: Bool) -> [Int: LayerUsage] {
        var result: [Int: LayerUsage] = [:]
        for group in paper ? document.paperGroups : document.modelGroups {
            var entry = result[group.layerId] ?? LayerUsage()
            entry.count += group.entityCount
            entry.bounds = entry.bounds.union(group.bounds)
            result[group.layerId] = entry
        }
        for image in paper ? document.paperImages : document.modelImages {
            var entry = result[image.layerId] ?? LayerUsage()
            entry.count += 1; entry.bounds = entry.bounds.union(image.bounds)
            result[image.layerId] = entry
        }
        if paper {
            for viewport in document.paperViewports {
                for group in document.modelGroups where !viewport.frozenLayerIDs.contains(group.layerId) {
                    let projected = group.bounds.applying(viewport.modelToPaper).intersection(viewport.bounds)
                    guard !projected.isNull else { continue }
                    var entry = result[group.layerId] ?? LayerUsage()
                    // Counts are model objects intersecting the viewport rectangle.
                    for run in group.strokes.runs where run.bounds.applying(viewport.modelToPaper).intersects(viewport.bounds) { entry.count += 1 }
                    for arc in group.strokes.arcs {
                        let box = CGRect(x: arc.center.x - arc.radius, y: arc.center.y - arc.radius, width: 2 * arc.radius, height: 2 * arc.radius)
                        if box.applying(viewport.modelToPaper).intersects(viewport.bounds) { entry.count += 1 }
                    }
                    for text in group.texts where viewport.bounds.contains(text.position.applying(viewport.modelToPaper)) { entry.count += 1 }
                    entry.bounds = entry.bounds.union(projected)
                    result[group.layerId] = entry
                }
            }
        }
        return result
    }
}
