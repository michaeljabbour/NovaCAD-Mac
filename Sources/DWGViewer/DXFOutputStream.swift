import Foundation

/// A small append-only text buffer that flushes to a `FileHandle` in
/// bounded-size chunks — the mechanism that keeps `DXFStructuralWriter` from
/// ever holding the whole output file in memory. Every section emitter in
/// this writer funnels its group-code lines through one shared instance of
/// this type for the whole write, so a 731MB / 2.35M-entity file writes with
/// a small, constant memory footprint instead of one giant `String`/`Data`.
///
/// Not thread-safe and not meant to be — the writer is single-threaded by
/// design (matches every other perf-sensitive path in this codebase, e.g.
/// `EntityStoreParser`'s scanner).
final class DXFOutputStream {
    private let handle: FileHandle
    /// ~4MB per the plan's spec. `String`'s UTF-8 view is used for the
    /// flush, so this buffer holds Swift `String`s until flush time, not raw
    /// bytes — simpler call sites (`write("...")` everywhere) at the cost of
    /// a small transient UTF-8 re-encode per flush, which is negligible next
    /// to the I/O itself.
    private static let flushThreshold = 4 * 1024 * 1024
    private var buffer: String
    private(set) var bytesWritten: Int = 0

    init(handle: FileHandle) {
        self.handle = handle
        buffer = ""
        buffer.reserveCapacity(Self.flushThreshold + 4096)
    }

    /// Appends raw text (caller is responsible for including trailing
    /// newlines where DXF's line-oriented format needs them) and flushes to
    /// disk once the buffer crosses `flushThreshold`. This is the ONE
    /// chokepoint that enforces the bounded-memory contract described in
    /// this class's doc comment — every other append method in this class
    /// (`pair`, `handlePair`, and their overloads) MUST route through this
    /// method rather than touching `buffer` directly, or the threshold check
    /// silently stops applying to whatever bypassed it (this happened for
    /// literally every group-code/value pair in the file until this
    /// comment/method were added — `pair`/`handlePair` used to append via
    /// `buffer +=` with no threshold check at all, making the "4MB chunked
    /// flush" a no-op for ~100% of output and defeating the entire point of
    /// this class on multi-hundred-MB files).
    @inline(__always)
    func write(_ s: String) {
        buffer += s
        if buffer.utf8.count >= Self.flushThreshold { flush() }
    }

    /// Writes one DXF group-code/value pair as two lines: `"<code>\n<value>\n"`.
    /// This is the single hottest call site in the whole writer (every field
    /// of every one of 2.35M+ entities goes through it). Routes through
    /// `write(_:)` (rather than appending to `buffer` directly) so the
    /// chunked-flush threshold check actually applies here too — see
    /// `write(_:)`'s doc comment.
    @inline(__always)
    func pair(_ code: Int, _ value: String) {
        write("\(code)\n\(value)\n")
    }

    @inline(__always) func pair(_ code: Int, _ value: Int) { pair(code, String(value)) }
    @inline(__always) func pair(_ code: Int, _ value: Int32) { pair(code, String(value)) }
    @inline(__always) func pair(_ code: Int, _ value: Int64) { pair(code, String(value)) }

    /// DXF floating-point convention: always has a decimal point (AutoCAD
    /// itself writes e.g. "0.0", never bare "0"), full double precision —
    /// matches `DXFWriter.swift`'s existing `%.8f`-style formatting
    /// philosophy for its own entity records, generalized to full precision
    /// here since the structural writer's round-trip fidelity bar (1e-9)
    /// is tighter than the markup writer's cosmetic needs.
    @inline(__always)
    func pair(_ code: Int, _ value: Double) {
        pair(code, Self.formatDouble(value))
    }

    /// Handle-shaped value: uppercase hex, no leading zeros (matches every
    /// real AutoCAD file and this codebase's own `DXFWriter.writeMergedCopy`
    /// convention: `String(handle, radix: 16, uppercase: true)`). Routes
    /// through `pair(_:_:String)` (and therefore `write(_:)`) like every
    /// other value-typed overload — see `write(_:)`'s doc comment.
    @inline(__always)
    func handlePair(_ code: Int, _ handle: UInt64) {
        pair(code, String(handle, radix: 16, uppercase: true))
    }

    /// Formats via C's `snprintf` directly rather than Foundation's
    /// `String(format:)` — measured to matter at this writer's scale: this
    /// is called for essentially every coordinate of a 2.7M-vertex, 2M+
    /// entity file, and `String(format:)` routes through an NSString-based
    /// formatter with locale-lookup overhead per call that shows up
    /// meaningfully in the writer's total wall-clock time on the 731MB
    /// production file. `snprintf` into a small fixed stack buffer avoids
    /// that entirely; 64 bytes is always enough for `%.17g` (worst case ~25
    /// characters: sign, leading digit, decimal point, 17 significant
    /// digits, "e", exponent sign, up to 3 exponent digits).
    static func formatDouble(_ value: Double) -> String {
        var buf = [CChar](repeating: 0, count: 64)
        let isWhole = value == value.rounded() && abs(value) < 1e15
        buf.withUnsafeMutableBufferPointer { ptr in
            // Whole numbers still get a ".0" — matches AutoCAD's own output
            // and avoids ambiguity with an integer-typed group at a glance.
            // Non-whole values use %.17g (provably sufficient to round-trip
            // any IEEE 754 double exactly) while staying far shorter than a
            // fixed %.8f for very small/large magnitudes — important for
            // the 1e-9 coordinate-fidelity round-trip bar RoundTripTests
            // holds this writer to.
            if isWhole {
                _ = withVaList([value]) { vsnprintf(ptr.baseAddress!, 64, "%.1f", $0) }
            } else {
                _ = withVaList([value]) { vsnprintf(ptr.baseAddress!, 64, "%.17g", $0) }
            }
        }
        var s = String(cString: buf)
        // %g may emit exponent form ("1e+20"); DXF readers (including
        // AutoCAD itself) accept that, so no special-casing needed there.
        if !isWhole && !s.contains(".") && !s.contains("e") && !s.contains("E") { s += ".0" }
        return s
    }

    /// Flushes any buffered text to disk. Safe to call redundantly (e.g. at
    /// the very end of a write) — a no-op on an empty buffer.
    func flush() {
        guard !buffer.isEmpty else { return }
        let data = Data(buffer.utf8)
        bytesWritten += data.count
        handle.write(data)
        buffer.removeAll(keepingCapacity: true)
    }
}
