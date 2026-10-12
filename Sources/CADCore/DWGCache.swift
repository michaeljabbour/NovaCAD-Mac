import Foundation
import CryptoKit

/// Persistent, cross-session cache of DWG→DXF conversions.
///
/// The first time a DWG-heavy folder is opened, converting every drawing (main
/// + xrefs) via the ODA File Converter can take minutes. Without a cache, that
/// cost is paid again on every re-open. This type persists converted DXFs to a
/// stable location keyed by the SOURCE dwg's path + size + modification time,
/// so re-opening the same folder reuses the DXFs and only re-converts the
/// individual drawings that actually changed on disk.
///
/// Layout (default under the app cache directory):
/// ```
/// <root>/dwgcache/<packageHash>/
///     manifest.json                     ← source → cached-dxf freshness map
///     <relative source subtree>/*.dxf   ← converted outputs, tree preserved
/// ```
/// The per-package bucket keeps one drawing set's DXFs together (so "Clear
/// Cache" and disk accounting are simple) and preserving the relative subtree
/// avoids the same-basename collisions the old flat temp scheme risked.
public enum DWGCache {

    // MARK: - Preferences (UserDefaults-backed)

    private static let enabledKey = "dwgCacheEnabled"
    private static let locationBookmarkKey = "dwgCacheLocationBookmark"

    /// Master on/off. Defaults to ON (the whole point is to save time).
    public static var isEnabled: Bool {
        get {
            if UserDefaults.standard.object(forKey: enabledKey) == nil { return true }
            return UserDefaults.standard.bool(forKey: enabledKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    /// A user-chosen cache root (via Settings → Choose Folder…), stored as a
    /// security-scoped bookmark so it survives relaunch and the sandbox. Nil =
    /// automatic (app cache directory).
    public static func userChosenRoot() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: locationBookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data,
                                 options: [.withSecurityScope],
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else { return nil }
        return url
    }

    public static func setUserChosenRoot(_ url: URL?) {
        guard let url else {
            UserDefaults.standard.removeObject(forKey: locationBookmarkKey)
            return
        }
        if let data = try? url.bookmarkData(options: [.withSecurityScope],
                                            includingResourceValuesForKeys: nil,
                                            relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: locationBookmarkKey)
        }
    }

    // MARK: - Locations

    /// The cache root — the user's chosen folder if set and writable, else the
    /// app's own cache directory (`~/Library/Caches/<bundle>/NovaCAD`).
    public static func root() -> URL {
        let fm = FileManager.default
        if let chosen = userChosenRoot() {
            let accessed = chosen.startAccessingSecurityScopedResource()
            defer { if accessed { chosen.stopAccessingSecurityScopedResource() } }
            let dir = chosen.appendingPathComponent("NovaCAD-dwgcache", isDirectory: true)
            if (try? fm.createDirectory(at: dir, withIntermediateDirectories: true)) != nil {
                return dir
            }
        }
        let base = (try? fm.url(for: .cachesDirectory, in: .userDomainMask,
                                appropriateFor: nil, create: true))
            ?? fm.temporaryDirectory
        let dir = base.appendingPathComponent("NovaCAD/dwgcache", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The per-package bucket for `packageDir`, keyed by a hash of its absolute
    /// path so re-opening the same folder maps to the same bucket.
    public static func bucket(forPackage packageDir: URL) -> URL {
        let key = packageDir.standardizedFileURL.path
        let hash = sha256Hex(key).prefix(16)
        let dir = root().appendingPathComponent(String(hash), isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Manifest

    /// One entry per source DWG: the size+mtime it was converted from, and the
    /// cached DXF's path relative to the bucket. `converter` records which tool
    /// produced it so switching converters invalidates the entry.
    public struct Entry: Codable {
        public var size: Int
        public var mtime: Double
        public var dxfRelPath: String
        public var converter: String
        public init(size: Int, mtime: Double, dxfRelPath: String, converter: String) {
            self.size = size; self.mtime = mtime; self.dxfRelPath = dxfRelPath; self.converter = converter
        }
    }

    public typealias Manifest = [String: Entry]

    public static func manifestURL(in bucket: URL) -> URL {
        bucket.appendingPathComponent("manifest.json")
    }

    public static func loadManifest(in bucket: URL) -> Manifest {
        guard let data = try? Data(contentsOf: manifestURL(in: bucket)),
              let m = try? JSONDecoder().decode(Manifest.self, from: data) else { return [:] }
        return m
    }

    public static func saveManifest(_ manifest: Manifest, in bucket: URL) {
        if let data = try? JSONEncoder().encode(manifest) {
            try? data.write(to: manifestURL(in: bucket), options: .atomic)
        }
    }

    // MARK: - Freshness

    /// (size, mtime) of a file, or nil if it can't be read.
    public static func stat(_ url: URL) -> (size: Int, mtime: Double)? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return (size, mtime)
    }

    /// True if `source`'s cached DXF exists and matches its current size+mtime
    /// and the current converter — i.e. it can be reused without re-converting.
    public static func isFresh(source: URL, relativeKey: String, bucket: URL,
                        manifest: Manifest, converter: String) -> Bool {
        guard let entry = manifest[relativeKey],
              entry.converter == converter,
              let st = stat(source),
              st.size == entry.size,
              abs(st.mtime - entry.mtime) < 0.000001 else { return false }
        return FileManager.default.fileExists(
            atPath: bucket.appendingPathComponent(entry.dxfRelPath).path)
    }

    // MARK: - Maintenance

    /// Deletes the entire cache. Returns bytes freed.
    @discardableResult
    public static func clearAll() -> UInt64 {
        let r = root()
        let size = directorySize(r)
        try? FileManager.default.removeItem(at: r)
        try? FileManager.default.createDirectory(at: r, withIntermediateDirectories: true)
        return size
    }

    /// Deletes the cache bucket for a specific package directory.
    public static func clearBucket(forPackage packageDir: URL) {
        let b = bucket(forPackage: packageDir)
        try? FileManager.default.removeItem(at: b)
    }

    /// Total bytes currently used by the cache (for the Settings readout).
    public static func currentSize() -> UInt64 { directorySize(root()) }

    // MARK: - Helpers

    /// An identifier for the active converter, so a different converter (or a
    /// switch ODA↔LibreDWG) invalidates previously cached outputs.
    public static func currentConverterId() -> String {
        if let oda = DWGConverter.locateConverter() {
            return "oda:" + URL(fileURLWithPath: oda).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
        }
        if DWGConverter.locateLibreDWG() != nil { return "libredwg" }
        return "none"
    }

    public static func sha256Hex(_ s: String) -> String {
        let digest = SHA256.hash(data: Data(s.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func directorySize(_ url: URL) -> UInt64 {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: url,
                                         includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]) else {
            return 0
        }
        var total: UInt64 = 0
        for case let file as URL in walker {
            let vals = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            total += UInt64(vals?.totalFileAllocatedSize ?? vals?.fileAllocatedSize ?? 0)
        }
        return total
    }
}
