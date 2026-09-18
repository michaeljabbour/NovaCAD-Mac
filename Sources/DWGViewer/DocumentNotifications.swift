import Foundation

extension Notification.Name {
    /// Posted after a document tab successfully writes its DXF file. Other tabs
    /// whose host drawing references that path as an xref reload automatically.
    static let novaCADDrawingSaved = Notification.Name("NovaCADDrawingSaved")
    /// Posted by `NovaCADAppDelegate.application(_:open:)` when the OS delivers
    /// an external "open this file" request (Finder double-click, Launch
    /// Services "Open With", or another app launching NovaCAD via
    /// `NSWorkspace.open(urls:withApplicationAt:)` — e.g. another app's "Edit
    /// Layout" action). `DocumentTabsView` is the subscriber, since it's the
    /// thing that owns the tab list and can either load into the current
    /// empty tab (cold launch) or open a new one (warm — NovaCAD already had
    /// a document open when the request arrived).
    ///
    /// Without this notification (and nothing consuming it), NovaCAD had NO
    /// code path that ever reacted to an external open-file delivery at all —
    /// `WindowGroup` (unlike `DocumentGroup`) does not auto-wire
    /// `CFBundleDocumentTypes` to file loading, so the app always launched
    /// with a permanently blank/default tab regardless of the file Launch
    /// Services handed it. This is the fix for that "opens NovaCAD but shows
    /// a blank window instead of the drawing" bug.
    static let novaCADOpenExternalURL = Notification.Name("NovaCADOpenExternalURL")
    /// Posted by the "What's New…" app-menu item (NovaCAD ▸ What's New…, next
    /// to About NovaCAD — see `DWGViewerApp`'s `.commands`) to re-show the
    /// Welcome/What's New sheet on demand, independent of
    /// `WelcomeScreenState.shouldShow`'s normal "only after an update"
    /// gating. `DocumentTabsView` is the subscriber (it owns the
    /// `showingWelcome` sheet-presentation state) — a plain notification
    /// rather than a second `Window` scene like `AboutView` uses, because the
    /// Welcome screen is intentionally a SHEET over the active document
    /// window (see `WelcomeView`'s own doc comment on why), and a
    /// notification is the established way an app-menu command (scene-level)
    /// reaches a specific window's view-owned `@State` in this codebase
    /// (mirrors `.novaCADOpenExternalURL`'s own shape).
    static let novaCADShowWelcome = Notification.Name("NovaCADShowWelcome")
}

enum DocumentNotificationKey {
    static let url = "url"
}

/// Buffers external "open this file" requests (`NovaCADAppDelegate
/// .application(_:open:)`) that arrive before `DocumentTabsView` exists to
/// receive them — which is the COMMON case on a cold launch: AppKit can
/// (and per Apple's own docs, often does) call `application(_:open:)` before
/// `applicationDidFinishLaunching` returns, i.e. before SwiftUI has even
/// built the `WindowGroup`'s content view, so a plain
/// `NotificationCenter.post` at that moment would have no subscriber and be
/// dropped silently — reproducing the exact "blank window" bug this queue
/// exists to fix. `DocumentTabsView.onAppear` drains this queue (in FIFO
/// order, opening one tab per URL) THEN subscribes to `.novaCADOpenExternalURL`
/// for any later (warm-launch) request, so a request is never lost regardless
/// of arrival order relative to view construction.
///
/// Not an actor: `application(_:open:)` and `DocumentTabsView`'s SwiftUI body
/// are both guaranteed to run on the main thread (AppKit delegate callbacks
/// and SwiftUI view code), so a plain main-thread-only class with no locking
/// is correct and simpler than introducing cross-actor hops for a handful of
/// URLs at launch.
@MainActor
final class ExternalOpenRequestQueue {
    static let shared = ExternalOpenRequestQueue()
    private init() {}

    private var pending: [URL] = []
    /// Set true by the FIRST `drainPending()` call (`DocumentTabsView
    /// .onAppear`, which happens once near launch). Once a real subscriber
    /// has proven it exists and drained the backlog, every later delivery is
    /// live (the warm-launch case) and buffering it too would just leak
    /// memory for the rest of the app's lifetime with nothing to ever drain
    /// it again — so buffering stops once this flips.
    private var hasDrainedOnce = false

    func enqueue(_ url: URL) {
        if !hasDrainedOnce { pending.append(url) }
        NotificationCenter.default.post(name: .novaCADOpenExternalURL, object: nil,
                                        userInfo: [DocumentNotificationKey.url: url])
    }

    /// Drains and returns every URL buffered so far (e.g. from a cold-launch
    /// delivery that beat `DocumentTabsView` into existence). Also posts the
    /// notification for each on enqueue (above), so a subscriber that was
    /// ALREADY listening at delivery time (the warm-launch case) still gets
    /// it live — this method exists purely to catch what a not-yet-existing
    /// subscriber would otherwise have missed. Idempotent after the first
    /// call (returns `[]` thereafter; buffering has already stopped).
    func drainPending() -> [URL] {
        hasDrainedOnce = true
        let drained = pending
        pending.removeAll()
        return drained
    }

    /// Test-only: restores a fresh-launch state (empty buffer,
    /// `hasDrainedOnce` false) so each test in a suite that exercises this
    /// process-wide singleton doesn't observe state left behind by a
    /// previous test.
    func resetForTesting() {
        pending.removeAll()
        hasDrainedOnce = false
    }
}
