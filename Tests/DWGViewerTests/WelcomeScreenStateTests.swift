import XCTest
@testable import DWGViewer

/// Tests for `WelcomeScreenState` — the Welcome screen's VERSION-AWARE
/// dismissal persistence, per an explicit request: the screen (with its
/// "What's New" section) should reappear the first time NovaCAD is opened
/// after ANY update/install, then stay dismissed again until the next one —
/// not a one-time-forever dismissal.
///
/// Uses a real `UserDefaults.standard` key (`WelcomeScreenState` is a thin
/// wrapper with no injectable store, matching every other preference in this
/// codebase's `AppSettings` — see that type's own doc comment), so every test
/// explicitly resets the key in `setUp`/`tearDown` rather than relying on
/// suite ordering, keeping this suite safe to run in any order and without
/// polluting a developer's real defaults across test runs.
final class WelcomeScreenStateTests: XCTestCase {
    private static let key = "welcomeScreenLastSeenVersion"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: Self.key)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: Self.key)
        super.tearDown()
    }

    func testShouldShowIsTrueByDefaultOnAFreshInstall() {
        // No prior launch has ever dismissed it (the key is simply absent) ->
        // the very first launch of a fresh install must show the screen.
        XCTAssertTrue(WelcomeScreenState.shouldShow)
    }

    func testMarkCurrentVersionSeenStopsShowingForThisSameVersion() {
        XCTAssertTrue(WelcomeScreenState.shouldShow, "sanity: shows before dismissal")
        WelcomeScreenState.markCurrentVersionSeen()
        XCTAssertFalse(WelcomeScreenState.shouldShow,
                       "after dismissing, the welcome screen must not show again for the SAME running version")
    }

    func testDismissalPersistsAcrossRepeatedChecksOfTheSameVersion() {
        // Simulates re-checking across multiple app launches of the SAME
        // build within the same test process — `shouldShow` must keep
        // returning false, not flip back after being read once.
        WelcomeScreenState.markCurrentVersionSeen()
        XCTAssertFalse(WelcomeScreenState.shouldShow)
        XCTAssertFalse(WelcomeScreenState.shouldShow)
        XCTAssertFalse(WelcomeScreenState.shouldShow)
    }

    func testMarkCurrentVersionSeenIsIdempotent() {
        WelcomeScreenState.markCurrentVersionSeen()
        WelcomeScreenState.markCurrentVersionSeen()
        XCTAssertFalse(WelcomeScreenState.shouldShow)
    }

    /// THE headline behavior this feature exists for: a version dismissed
    /// previously must NOT suppress the screen for a DIFFERENT (newer)
    /// version — i.e. an update/reinstall must make it reappear
    /// automatically, with no separate "reset" step required. Simulated by
    /// writing an arbitrary stale version string directly into the same
    /// UserDefaults key `markCurrentVersionSeen` would have written for some
    /// OTHER (older) build, since `currentVersion` itself isn't independently
    /// injectable (it reads `Bundle.main`, which is fixed for the test
    /// process) — this still exercises the real comparison logic in
    /// `shouldShow` against a version that provably differs from whatever
    /// the test bundle's own `CFBundleVersion` is.
    func testDifferentPreviouslyDismissedVersionStillShowsForANewOne() {
        UserDefaults.standard.set("some-stale-version-from-a-prior-build-\(UUID().uuidString)",
                                  forKey: Self.key)
        XCTAssertTrue(WelcomeScreenState.shouldShow,
                      "dismissing an OLDER version must not suppress the screen after an update to a new one")
    }

    func testMarkingSeenRecordsExactlyTheCurrentRunningVersion() {
        // After dismissing, the stored value must be readable as "the
        // current version" from `shouldShow`'s own perspective — re-checking
        // immediately (still the same running build) must show false, the
        // same invariant `testMarkCurrentVersionSeenStopsShowingForThisSameVersion`
        // covers, restated here to make explicit that dismissal is scoped to
        // a VERSION STRING, not a plain boolean.
        WelcomeScreenState.markCurrentVersionSeen()
        let stored = UserDefaults.standard.string(forKey: Self.key)
        XCTAssertNotNil(stored, "dismissal must record a version string, not just a bare flag")
        XCTAssertFalse(WelcomeScreenState.shouldShow)
    }
}
