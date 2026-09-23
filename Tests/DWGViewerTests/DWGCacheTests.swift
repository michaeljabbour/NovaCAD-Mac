import XCTest
@testable import DWGViewer
import CADCore

/// Unit tests for the persistent DWG→DXF cache freshness/manifest logic. These
/// don't run the real converter (that needs ODA/LibreDWG installed); they pin
/// the pure bookkeeping that decides reuse-vs-reconvert.
final class DWGCacheTests: XCTestCase {

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("dwgcache-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func writeFile(_ name: String, _ contents: String) throws -> URL {
        let url = tmp.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testSubsecondChangeInvalidatesCacheEvenWithSameSize() throws {
        let src = try writeFile("rapid.dwg", "first")
        _ = try writeFile("rapid.dxf", "cached geometry")
        let before = try XCTUnwrap(DWGCache.stat(src))
        let manifest = ["rapid.dwg": DWGCache.Entry(size: before.size, mtime: before.mtime,
            dxfRelPath: "rapid.dxf", converter: "test")]
        try Data("later".utf8).write(to: src)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: before.mtime + 0.25)],
                                              ofItemAtPath: src.path)
        XCTAssertFalse(DWGCache.isFresh(source: src, relativeKey: "rapid.dwg", bucket: tmp,
                                        manifest: manifest, converter: "test"))
    }

    func testStandaloneDWGLoadsCacheWithoutLaunchingConverterOrScanningFolder() throws {
        let originalPreference = UserDefaults.standard.object(forKey: "dwgCacheEnabled")
        UserDefaults.standard.set(true, forKey: "dwgCacheEnabled")
        defer {
            if let originalPreference { UserDefaults.standard.set(originalPreference, forKey: "dwgCacheEnabled") }
            else { UserDefaults.standard.removeObject(forKey: "dwgCacheEnabled") }
        }
        // Deliberately not a real DWG: this can only succeed through the cache.
        let src = try writeFile("standalone.dwg", "dummy source")
        let bucket = DWGCache.bucket(forPackage: tmp)
        defer { try? FileManager.default.removeItem(at: bucket) }
        let converted = bucket.appendingPathComponent("cached.dxf")
        try FileManager.default.copyItem(at: TestFixtures.url("basic_entities.dxf"), to: converted)
        let st = try XCTUnwrap(DWGCache.stat(src))
        let key = "abs:" + DWGCache.sha256Hex(src.standardizedFileURL.path)
        DWGCache.saveManifest([key: .init(size: st.size, mtime: st.mtime, dxfRelPath: "cached.dxf",
                                         converter: DWGCache.currentConverterId())], in: bucket)
        let parsed = try PackageLoader.loadIntoStore(url: src, drawingIndexer: { _, _ in
            XCTFail("A standalone drawing with no xrefs must not scan its folder")
            return [:]
        })
        XCTAssertGreaterThan(parsed.store.count, 0)
        XCTAssertTrue(parsed.resourceDirectories.contains(tmp))
        XCTAssertEqual(try String(contentsOf: src, encoding: .utf8), "dummy source")
    }

    func testManifestRoundTrips() throws {
        let bucket = tmp.appendingPathComponent("bucket", isDirectory: true)
        try FileManager.default.createDirectory(at: bucket, withIntermediateDirectories: true)
        var m = DWGCache.Manifest()
        m["a/b.dwg"] = DWGCache.Entry(size: 123, mtime: 456.0, dxfRelPath: "a/b.dxf", converter: "oda:X")
        DWGCache.saveManifest(m, in: bucket)
        let loaded = DWGCache.loadManifest(in: bucket)
        XCTAssertEqual(loaded["a/b.dwg"]?.size, 123)
        XCTAssertEqual(loaded["a/b.dwg"]?.dxfRelPath, "a/b.dxf")
        XCTAssertEqual(loaded["a/b.dwg"]?.converter, "oda:X")
    }

    func testFreshWhenSizeMtimeAndConverterMatchAndDXFExists() throws {
        let src = try writeFile("drawing.dwg", "dummy dwg bytes")
        let bucket = tmp.appendingPathComponent("bucket", isDirectory: true)
        try FileManager.default.createDirectory(at: bucket, withIntermediateDirectories: true)
        // Simulate a produced dxf.
        let dxf = bucket.appendingPathComponent("drawing.dxf")
        try "dxf".write(to: dxf, atomically: true, encoding: .utf8)

        let st = try XCTUnwrap(DWGCache.stat(src))
        var m = DWGCache.Manifest()
        m["drawing.dwg"] = DWGCache.Entry(size: st.size, mtime: st.mtime,
                                          dxfRelPath: "drawing.dxf", converter: "oda:V")

        XCTAssertTrue(DWGCache.isFresh(source: src, relativeKey: "drawing.dwg",
                                       bucket: bucket, manifest: m, converter: "oda:V"))
    }

    func testStaleWhenConverterDiffers() throws {
        let src = try writeFile("drawing.dwg", "dummy")
        let bucket = tmp.appendingPathComponent("bucket", isDirectory: true)
        try FileManager.default.createDirectory(at: bucket, withIntermediateDirectories: true)
        try "dxf".write(to: bucket.appendingPathComponent("drawing.dxf"),
                        atomically: true, encoding: .utf8)
        let st = try XCTUnwrap(DWGCache.stat(src))
        var m = DWGCache.Manifest()
        m["drawing.dwg"] = DWGCache.Entry(size: st.size, mtime: st.mtime,
                                          dxfRelPath: "drawing.dxf", converter: "oda:OLD")
        XCTAssertFalse(DWGCache.isFresh(source: src, relativeKey: "drawing.dwg",
                                        bucket: bucket, manifest: m, converter: "oda:NEW"))
    }

    func testStaleWhenSourceContentChanges() throws {
        let src = try writeFile("drawing.dwg", "v1")
        let bucket = tmp.appendingPathComponent("bucket", isDirectory: true)
        try FileManager.default.createDirectory(at: bucket, withIntermediateDirectories: true)
        try "dxf".write(to: bucket.appendingPathComponent("drawing.dxf"),
                        atomically: true, encoding: .utf8)
        let st1 = try XCTUnwrap(DWGCache.stat(src))
        var m = DWGCache.Manifest()
        m["drawing.dwg"] = DWGCache.Entry(size: st1.size, mtime: st1.mtime,
                                          dxfRelPath: "drawing.dxf", converter: "c")
        // Edit the source (bigger + newer mtime).
        try "v2-longer-content".write(to: src, atomically: true, encoding: .utf8)
        XCTAssertFalse(DWGCache.isFresh(source: src, relativeKey: "drawing.dwg",
                                        bucket: bucket, manifest: m, converter: "c"))
    }

    func testStaleWhenCachedDXFMissing() throws {
        let src = try writeFile("drawing.dwg", "x")
        let bucket = tmp.appendingPathComponent("bucket", isDirectory: true)
        try FileManager.default.createDirectory(at: bucket, withIntermediateDirectories: true)
        let st = try XCTUnwrap(DWGCache.stat(src))
        var m = DWGCache.Manifest()
        // Manifest points at a dxf that was deleted from the bucket.
        m["drawing.dwg"] = DWGCache.Entry(size: st.size, mtime: st.mtime,
                                          dxfRelPath: "gone.dxf", converter: "c")
        XCTAssertFalse(DWGCache.isFresh(source: src, relativeKey: "drawing.dwg",
                                        bucket: bucket, manifest: m, converter: "c"))
    }

    func testDifferentPackagesGetDifferentBuckets() {
        let a = URL(fileURLWithPath: "/tmp/folderA")
        let b = URL(fileURLWithPath: "/tmp/folderB")
        XCTAssertNotEqual(DWGCache.bucket(forPackage: a).lastPathComponent,
                          DWGCache.bucket(forPackage: b).lastPathComponent)
        // Same package → same bucket (stable across opens).
        XCTAssertEqual(DWGCache.bucket(forPackage: a).lastPathComponent,
                       DWGCache.bucket(forPackage: a).lastPathComponent)
    }

    func testSha256HexIsStable() {
        XCTAssertEqual(DWGCache.sha256Hex("abc"),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}
