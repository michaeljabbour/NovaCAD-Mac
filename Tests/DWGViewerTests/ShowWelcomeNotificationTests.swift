import XCTest
@testable import DWGViewer

/// Tests for the `.novaCADShowWelcome` notification — the mechanism behind
/// NovaCAD's app-menu "What's New…" item (next to About NovaCAD), which
/// re-opens the Welcome/What's New sheet on demand, bypassing
/// `WelcomeScreenState.shouldShow`'s normal "only once per version" gating.
///
/// `DocumentTabsView`'s actual `.sheet`/`.onReceive` wiring isn't
/// independently unit-testable (it's SwiftUI view body content with no
/// externally observable state to assert against outside a live window), so
/// this covers the notification contract itself — the same scope
/// `ExternalOpenRequestQueueTests.testEnqueuePostsNotificationWithTheURL`
/// already establishes as this codebase's precedent for testing a
/// menu-command-to-window notification bridge.
final class ShowWelcomeNotificationTests: XCTestCase {
    func testPostingShowWelcomeIsObservable() {
        let expectation = expectation(description: "notification received")
        let observer = NotificationCenter.default.addObserver(
            forName: .novaCADShowWelcome, object: nil, queue: nil) { _ in
            expectation.fulfill()
        }
        NotificationCenter.default.post(name: .novaCADShowWelcome, object: nil)
        wait(for: [expectation], timeout: 1)
        NotificationCenter.default.removeObserver(observer)
    }

    /// Posting must not depend on `WelcomeScreenState`'s per-version
    /// dismissal state at all — "What's New…" is an explicit, on-demand
    /// re-show that should work identically whether or not the user already
    /// dismissed the screen for the currently running version.
    func testShowWelcomeIsObservableRegardlessOfDismissalState() {
        WelcomeScreenState.markCurrentVersionSeen()
        XCTAssertFalse(WelcomeScreenState.shouldShow, "sanity: already dismissed for this version")

        let expectation = expectation(description: "notification received")
        let observer = NotificationCenter.default.addObserver(
            forName: .novaCADShowWelcome, object: nil, queue: nil) { _ in
            expectation.fulfill()
        }
        NotificationCenter.default.post(name: .novaCADShowWelcome, object: nil)
        wait(for: [expectation], timeout: 1)
        NotificationCenter.default.removeObserver(observer)

        // Cleanup: leave WelcomeScreenState as this test found it, so this
        // suite doesn't affect other tests' expectations about a fresh
        // UserDefaults state.
        UserDefaults.standard.removeObject(forKey: "welcomeScreenLastSeenVersion")
    }
}
