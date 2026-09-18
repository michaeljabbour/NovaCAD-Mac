import Foundation

// MARK: - Phase 3: OBJECTS section emitter
//
// Per the plan's spec: root dictionary first, ACAD_LAYOUT dict + layouts,
// ACAD_GROUP, ACAD_IMAGE_DICT, raw objects echoed. Since pass 1 never
// reassigns a handle that already existed in the source (see
// HandleAllocator.swift's doc comment), every 330/350/360/340 pointer
// captured in `ObjectsModel` still resolves correctly without this emitter
// needing to understand what a given object type's pointers MEAN — it just
// echoes `rawPairs` verbatim, exactly as captured, for every object
// (dictionaries' `entries` are also re-derived from their own typed fields
// rather than needing separate handling, since `rawPairs` already contains
// their group-3/350/360 pairs verbatim too).
extension DXFStructuralWriter {

    static func writeObjectsSection(parsed: EditableParsedDocument, version: DXFVersion,
                                    graph: HandleGraph, out: DXFOutputStream) {
        out.pair(0, "SECTION")
        out.pair(2, "OBJECTS")

        let objects = parsed.objects

        if let rootHandle = objects.rootDictionaryHandle, let root = objects.dictionaries[rootHandle] {
            writeDictionary(root, out: out)
            for (handle, dict) in objects.dictionaries where handle != rootHandle {
                writeDictionary(dict, out: out)
            }
        } else if let synthetic = graph.syntheticRootDictionaryHandle {
            // Source had no OBJECTS section at all (R12 source, or a
            // minimal/hand-authored fixture) — synthesize the minimal root
            // Named Object Dictionary AutoCAD expects to exist. Empty (no
            // entries) is legal; this keeps the file structurally valid
            // without inventing content this codebase doesn't actually have
            // (no groups/layouts/image defs to point at).
            out.pair(0, "DICTIONARY")
            out.handlePair(5, synthetic)
            out.handlePair(330, 0)
            out.pair(100, "AcDbDictionary")
            out.pair(281, 1)
            for (handle, dict) in objects.dictionaries where handle != 0 {
                writeDictionary(dict, out: out)
            }
        } else {
            for dict in objects.dictionaries.values { writeDictionary(dict, out: out) }
        }

        for layout in objects.layouts.values { writeLayout(layout, out: out) }
        for group in objects.groups.values { writeGroup(group, out: out) }
        for imageDef in objects.imageDefs.values { writeImageDef(imageDef, out: out) }
        for raw in objects.rawObjects.values { writeRawObject(raw, out: out) }

        out.pair(0, "ENDSEC")
    }

    private static func writeDictionary(_ d: DictionaryObject, out: DXFOutputStream) {
        out.pair(0, "DICTIONARY")
        for p in d.rawPairs { out.pair(Int(p.code), p.value) }
    }

    private static func writeLayout(_ l: LayoutObject, out: DXFOutputStream) {
        out.pair(0, "LAYOUT")
        for p in l.rawPairs { out.pair(Int(p.code), p.value) }
    }

    private static func writeGroup(_ g: GroupObject, out: DXFOutputStream) {
        out.pair(0, "GROUP")
        for p in g.rawPairs { out.pair(Int(p.code), p.value) }
    }

    private static func writeImageDef(_ i: ImageDefObject, out: DXFOutputStream) {
        out.pair(0, "IMAGEDEF")
        for p in i.rawPairs { out.pair(Int(p.code), p.value) }
    }

    private static func writeRawObject(_ r: RawObject, out: DXFOutputStream) {
        out.pair(0, r.objectType)
        for p in r.rawPairs { out.pair(Int(p.code), p.value) }
    }
}
