import SwiftUI
import AppKit

/// `NSApplicationDelegate` for the OpenCode (agentic) AI backend's process
/// lifecycle (ported from an earlier internal project's app delegate per
/// `Resources/Specs/AI_ASSISTANT_PORTING_GUIDE.md` §6/§8), AND for receiving
/// externally-delivered "open this file" requests — Finder double-click,
/// Launch Services "Open With", or another app (e.g. an earlier internal
/// project's "Edit Layout" action) launching NovaCAD via
/// `NSWorkspace.open(urls:withApplicationAt:)`.
///
/// Without `application(_:open:)` below, NovaCAD had NO code path that ever
/// consumed such a request: the app's scene is a plain `WindowGroup` (not a
/// `DocumentGroup`, which is the SwiftUI scene type that auto-wires
/// `CFBundleDocumentTypes` Info.plist declarations to file loading), so
/// despite advertising itself as a `.dxf`/`.dwg` viewer, it always launched
/// with a permanently blank/default empty tab regardless of the file Launch
/// Services/`NSWorkspace` handed it — the "opens NovaCAD but shows a blank
/// window instead of the drawing" bug.
final class NovaCADAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Best-effort cleanup of any `opencode serve` process left running
        // from a prior crashed/force-quit NovaCAD session (reparented to
        // launchd, PPID 1) — see `OpenCodeServerClient.sweepOrphanedServers`'s
        // own doc comment for why this accumulates over time if left
        // unchecked. Off the main thread's synchronous startup path (spawns
        // a `ps` subprocess) so app launch is never blocked by it.
        DispatchQueue.global(qos: .utility).async {
            OpenCodeServerClient.sweepOrphanedServers()
        }
    }

    /// The macOS/AppKit hook for BOTH the "cold launch with a file" case
    /// (Launch Services delivers this once, shortly after
    /// `applicationDidFinishLaunching`) AND the "warm — app already running,
    /// user opens another file" case (delivered directly, no relaunch). Both
    /// funnel into the SAME notification so `DocumentTabsView` has exactly
    /// one place that decides "load into the current empty tab" vs. "open a
    /// new tab" — see that type's `.onReceive` handler for the split logic.
    /// (`application(_:openFiles:)`, the pre-Big-Sur equivalent, is
    /// deliberately NOT also implemented: AppKit calls at most one of the
    /// two per launch depending on the target's deployment/SDK, and this
    /// app's minimum deployment target supports the modern `open urls:` form.)
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            ExternalOpenRequestQueue.shared.enqueue(url)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Synchronous SIGTERM to the currently-managed `opencode serve`
        // process, if any — `applicationWillTerminate` does not reliably
        // support `await`ing the actor-isolated `OpenCodeServerClient
        // .shutdown()` before the process exits, so this uses the
        // lock-protected PID mirror instead (see that type's own doc
        // comment).
        OpenCodeServerClient.terminateManagedServerProcessSynchronously()
    }
}

@main
struct DWGViewerApp: App {
    @NSApplicationDelegateAdaptor(NovaCADAppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow

    init() {
        SnapshotMode.runIfRequested()   // headless mode: renders a PNG and exits
    }

    var body: some Scene {
        WindowGroup("NovaCAD") {
            DocumentTabsView()
                // Without an explicit minimum, `WindowGroup` can open (and
                // be resized) narrower than the toolbar/ribbon's natural
                // content width, silently clipping trailing buttons off the
                // right edge — reported by a user as "not all menu bar
                // content displays... forcing me to resize the window."
                // 1150 comfortably fits the toolbar's ~20 leading buttons +
                // the ribbon's 6 groups at default sizing; `toolbar`/
                // `RibbonView` are ALSO wrapped in a horizontal `ScrollView`
                // each (see ContentView.swift/RibbonView.swift) as a second,
                // independent guarantee — so even content that somehow still
                // exceeds this minimum (a future addition, an unusually
                // small external display) stays reachable by scrolling
                // rather than silently clipped, satisfying "regardless of
                // window size" for real rather than just raising the floor.
                .frame(minWidth: 1150, minHeight: 700)
        }
        .windowStyle(DefaultWindowStyle())
        .defaultSize(width: 1280, height: 800)
        // Phase 5.1: native File/Edit/View/Insert/Format/Tools/Draw/
        // Dimension/Modify menu items, sourced from CommandRegistry.all and
        // routed through the same funnel the command bar uses — see
        // App/MainMenuCommands.swift.
        .commands {
            MainMenuCommands()
            // Replaces the default system-generated "About NovaCAD" item
            // (which shows only the bare Info.plist name/version/copyright)
            // with one that opens the custom `AboutWindow` scene below —
            // credits the author and lists a support contact, per an
            // explicit request.
            CommandGroup(replacing: .appInfo) {
                Button("About NovaCAD") {
                    openWindow(id: "about")
                }
                // Re-opens the Welcome/"What's New" sheet on demand — the
                // NORMAL trigger (`WelcomeScreenState.shouldShow`) only shows
                // it automatically once per version, so without this a user
                // who already dismissed it for the current build (or a
                // curious coworker on someone else's already-set-up Mac) had
                // no way to see it again short of clearing app data. Posts a
                // notification rather than opening a `Window` scene (see
                // `Notification.Name.novaCADShowWelcome`'s own doc comment
                // for why) since the Welcome screen is a sheet owned by
                // `DocumentTabsView`, not an independent window.
                Button("What's New…") {
                    NotificationCenter.default.post(name: .novaCADShowWelcome, object: nil)
                }
            }
        }

        // NovaCAD ▸ Settings… (⌘,) — DWG→DXF conversion cache controls +
        // AI Assistant backend configuration.
        Settings {
            TabView {
                SettingsView()
                    .tabItem { Label("General", systemImage: "gearshape") }
                AISettingsView()
                    .tabItem { Label("AI Assistant", systemImage: "sparkles") }
            }
        }

        // "About NovaCAD" — a real, independently-closable window (not an
        // alert/sheet) so it matches every other Mac app's About box and can
        // be left open while the user keeps working. `.windowResizability
        // (.contentSize)` locks it to AboutView's own `.fixedSize()` content
        // rather than letting the user drag it into an oddly-stretched shape.
        Window("About NovaCAD", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
    }
}
