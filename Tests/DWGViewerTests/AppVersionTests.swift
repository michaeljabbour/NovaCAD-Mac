import XCTest
@testable import DWGViewer

/// Tests for `AppVersion` — the single source of truth for NovaCAD's
/// marketing version string (About panel, Welcome screen, and the shared
/// `.pkg`'s own filename via `Scripts/build_pkg.sh`).
final class AppVersionTests: XCTestCase {
    /// `current` must always resolve to SOME non-empty string — either the
    /// real bundle's `CFBundleShortVersionString` (the xctest host bundle
    /// carries its own, e.g. "16.0" from the SDK, in a `swift test` process)
    /// or `fallback` when no bundle version is present at all (a real app
    /// launch with `Info.plist` unset, or a bare `swift run`). Doesn't assert
    /// a specific value since the xctest host's own bundle version is
    /// environment-dependent and not something this test should pin down.
    func testCurrentNeverReturnsEmpty() {
        XCTAssertFalse(AppVersion.current.isEmpty)
    }

    /// A loose sanity check on the format `Scripts/build_app.sh`/
    /// `Scripts/build_pkg.sh` both `sed` this value out of — it must parse
    /// as a plain `X.Y.Z`-shaped string, not something that would produce a
    /// malformed CFBundleShortVersionString or an awkward .pkg filename.
    func testFallbackIsADotSeparatedVersionString() {
        let parts = AppVersion.fallback.split(separator: ".")
        XCTAssertGreaterThanOrEqual(parts.count, 2, "expected at least a MAJOR.MINOR form")
        for part in parts {
            XCTAssertNotNil(Int(part), "\(part) in \(AppVersion.fallback) must be numeric")
        }
    }
}
