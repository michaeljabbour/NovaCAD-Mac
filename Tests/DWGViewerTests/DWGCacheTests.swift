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
