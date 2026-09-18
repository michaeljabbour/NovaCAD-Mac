import XCTest
@testable import DWGViewer

/// Regression coverage for a real bug found by adversarial review of Phase
/// 3.1: `DXFOutputStream.write(_:)` was the ONLY method that checked
/// `buffer.utf8.count >= flushThreshold` and called `flush()`. But
/// `pair(_:_:)` (String/Int/Int32/Int64/Double overloads) and
/// `handlePair(_:_:)` — used for essentially every group-code/value pair
/// emitted by every DXF section, i.e. almost 100% of a structural writer's
/// output — appended straight to the private `buffer` via `+=` and never
/// checked the threshold or called `flush()` at all. Net effect: the entire
/// output file was built as one giant in-memory `String` regardless of
/// size, directly contradicting this class's own "bounded, constant memory"
/// doc comment. Fixed by routing `pair`/`handlePair` through `write(_:)`.
///
/// These tests can't observe process RSS directly (that's verified
/// separately against the real 731MB reference file — see the session's
/// final report for the actual numbers), but they CAN observe the
/// externally-visible contract `write(_:)` promises: bytes reach the
/// underlying `FileHandle` once `flushThreshold` (4MB) is crossed, without
/// requiring `flush()` or stream teardown to be called first. Before the
/// fix, a test driving only `pair`/`handlePair` past 4MB would see zero
/// bytes written until an explicit trailing `flush()`.
final class DXFOutputStreamTests: XCTestCase {

    private func makeStream() -> (DXFOutputStream, URL, FileHandle) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("dxf-output-stream-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        let handle = try! FileHandle(forWritingTo: tmp)
        return (DXFOutputStream(handle: handle), tmp, handle)
    }

    /// Drives ONLY `pair(_:_:String)` (never the raw `write(_:)` API a caller
    /// might use for section boilerplate) past the 4MB flush threshold, then
    /// checks the file ALREADY has bytes on disk without calling `flush()`
    /// or closing the handle — i.e. the threshold-triggered auto-flush fired
    /// from inside `pair` itself, not just from `write`.
    func testPairTriggersAutoFlushPastThreshold() throws {
        let (out, url, handle) = makeStream()
        defer { try? handle.close(); try? FileManager.default.removeItem(at: url) }

        // Each call appends "<code>\n<value>\n" — use a long value so we
        // cross 4MB (4*1024*1024 bytes) in a modest number of calls rather
        // than millions of tiny ones.
        let longValue = String(repeating: "A", count: 1024)
        let bytesPerCall = 1 /*"1"*/ + 1 /*\n*/ + longValue.utf8.count + 1 /*\n*/
        let callsNeededToCrossThreshold = (4 * 1024 * 1024 / bytesPerCall) + 10
        for _ in 0..<callsNeededToCrossThreshold {
            out.pair(1, longValue)
        }

        // Do NOT call out.flush() here — the whole point is that `pair`
        // itself must have already flushed once the threshold was crossed.
        let onDiskBeforeExplicitFlush = try Data(contentsOf: url).count
        XCTAssertGreaterThan(onDiskBeforeExplicitFlush, 0,
            "pair(_:_:) must trigger an automatic flush once the 4MB threshold is crossed, "
            + "the same as write(_:) does — otherwise the whole output file is buffered in memory")
        XCTAssertEqual(out.bytesWritten, onDiskBeforeExplicitFlush,
            "bytesWritten bookkeeping must match what's actually reached the FileHandle")
    }

    /// Same check for `handlePair`, the other hot call site that bypassed
    /// the threshold check prior to the fix.
    func testHandlePairTriggersAutoFlushPastThreshold() throws {
        let (out, url, handle) = makeStream()
        defer { try? handle.close(); try? FileManager.default.removeItem(at: url) }

        // handlePair's formatted value is short (hex handle: "5\n<hex>\n" is
        // roughly 6-10 bytes per call), so many more calls are needed to
        // cross 4MB purely via this API than via the long-string test above.
        let approxBytesPerCall = 8
        let callsNeededToCrossThreshold = (4 * 1024 * 1024 / approxBytesPerCall) + 100_000
        for i in 0..<callsNeededToCrossThreshold {
            out.handlePair(5, UInt64(i))
        }

        let onDiskBeforeExplicitFlush = try Data(contentsOf: url).count
        XCTAssertGreaterThan(onDiskBeforeExplicitFlush, 0,
            "handlePair(_:_:) must trigger an automatic flush once the 4MB threshold is crossed")
        XCTAssertEqual(out.bytesWritten, onDiskBeforeExplicitFlush)
    }

    /// Sanity check the OTHER direction: with a tiny amount of output, no
    /// premature flush should occur (the buffer should still be doing its
    /// job of coalescing small writes) — guards against a naive fix like
    /// "flush on every call" that would defeat the buffering's whole
    /// purpose just to pass the two tests above.
    func testSmallOutputDoesNotFlushPrematurely() throws {
        let (out, url, handle) = makeStream()
        defer { try? handle.close(); try? FileManager.default.removeItem(at: url) }

        out.pair(0, "LINE")
        out.handlePair(5, 0x1A2B)
        out.pair(10, 1.5)

        let onDiskBeforeFlush = try Data(contentsOf: url).count
        XCTAssertEqual(onDiskBeforeFlush, 0,
            "small writes well under the 4MB threshold should stay buffered, not flush immediately")

        out.flush()
        let onDiskAfterFlush = try Data(contentsOf: url).count
        XCTAssertGreaterThan(onDiskAfterFlush, 0, "explicit flush() should still work")
    }
}
