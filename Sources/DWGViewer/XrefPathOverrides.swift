import Foundation

/// User-provided file locations for xrefs that a drawing references but that
/// weren't found in the opened package ("Not embedded in this DXF"). When the
/// user right-clicks such an xref and points it at a file on disk, the choice
/// is remembered here (as a security-scoped bookmark) and consulted by
/// `PackageLoader` during xref resolution so the xref loads on this and future
/// opens.
///
/// Keyed by the xref's SOURCE drawing name (the terminal `$`-segment of the
/// block name, case-folded) so one link covers every place that source is
/// referenced — matching the panel's source-drawing grouping.
enum XrefPathOverrides {

    private static let defaultsKey = "xrefPathOverrides"   // [sourceKey: bookmarkData]

    /// The source-drawing key used for override lookup (terminal `$`-segment,
    /// lowercased) — mirrors `XrefInfo.sourceDrawingKey`.
    static func key(forBlockName blockName: String) -> String {
        (blockName.split(separator: "$").last.map(String.init) ?? blockName).lowercased()
    }

    private static func load() -> [String: Data] {
        (UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: Data]) ?? [:]
    }

    private static func save(_ map: [String: Data]) {
        UserDefaults.standard.set(map, forKey: defaultsKey)
    }

    /// Records `fileURL` as the location for the xref identified by `blockName`.
    static func set(blockName: String, fileURL: URL) {
        let k = key(forBlockName: blockName)
        var map = load()
        if let data = try? fileURL.bookmarkData(options: [.withSecurityScope],
                                                includingResourceValuesForKeys: nil,
                                                relativeTo: nil) {
            map[k] = data
        } else if let data = try? fileURL.bookmarkData() {
            map[k] = data   // non-scoped fallback
        }
        save(map)
    }

    /// Forgets any override for `blockName`.
    static func clear(blockName: String) {
        var map = load()
        map.removeValue(forKey: key(forBlockName: blockName))
        save(map)
    }

    /// The resolved file URL previously chosen for this xref source, if any and
    /// still present on disk. Does NOT start security-scoped access — the caller
    /// is responsible for `startAccessingSecurityScopedResource()` around reads.
    static func resolvedURL(forBlockName blockName: String) -> URL? {
        let k = key(forBlockName: blockName)
        guard let data = load()[k] else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data,
                                 options: [.withSecurityScope],
                                 relativeTo: nil, bookmarkDataIsStale: &stale),
              FileManager.default.fileExists(atPath: url.path) else {
            // Try a non-scoped resolve as a fallback.
            if let url2 = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale),
               FileManager.default.fileExists(atPath: url2.path) {
                return url2
            }
            return nil
        }
        return url
    }

    /// True if any override is stored for this xref source.
    static func hasOverride(forBlockName blockName: String) -> Bool {
        load()[key(forBlockName: blockName)] != nil
    }
}
