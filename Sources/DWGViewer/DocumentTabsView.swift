import SwiftUI

/// One open drawing tab. A tab is "one drawing and everything resolved into
/// it" — a drawing's xrefs are merged into its own DocumentSession (as
/// they've always been, via PackageLoader) and are never separate tabs
/// themselves; only top-level "Open File" calls create new tabs.
@MainActor
final class DocumentTab: Identifiable, ObservableObject {
    let id = UUID()
    @Published var session = DocumentSession()

    var displayName: String {
        if session.isLoading { return "Loading…" }
        return session.currentSourceURL?.deletingPathExtension().lastPathComponent ?? "Untitled"
    }
}

/// Hosts one window's set of open-drawing tabs, the tab strip UI, and the
/// app-wide preferences shared across all of them (render quality, unit
/// format, markup color are user preferences, not per-drawing state, so they
/// live here — one instance — rather than on each tab's DocumentSession).
struct DocumentTabsView: View {
    @StateObject private var settings = AppSettings()
    @State private var tabs: [DocumentTab]
    @State private var activeTabID: DocumentTab.ID
    /// First-launch Welcome screen (see `WelcomeView`/`WelcomeScreenState`) —
    /// read once at init from the SAME persisted flag `WelcomeScreenState
    /// .shouldShow` checks, rather than re-evaluating it live, so checking
    /// "Don't show this again" during THIS session's Welcome screen can't
    /// cause the sheet to reappear mid-session from some other state change
    /// re-triggering the `.sheet(isPresented:)` binding.
    @State private var showingWelcome: Bool

    init() {
        let first = DocumentTab()
        _tabs = State(initialValue: [first])
        _activeTabID = State(initialValue: first.id)
        _showingWelcome = State(initialValue: WelcomeScreenState.shouldShow)
    }

    private var activeTab: DocumentTab {
        tabs.first { $0.id == activeTabID } ?? tabs[0]
    }

    var body: some View {
        VStack(spacing: 0) {
            // Only show the strip once there's something to switch between —
            // a single empty tab doesn't need a tab bar cluttering the window.
            if tabs.count > 1 {
                tabBar
                Divider()
            }
            ContentView(session: activeTab.session, settings: settings,
                       onOpenInNewTab: { url in openInNewTab(url: url) })
                // Fresh view identity per tab: each tab gets its own ContentView
                // @State (command bar text, popovers, etc.) rather than
                // inheriting whatever the previously active tab left behind.
                // The document/selection/markup/view-transform state that
                // actually matters survives regardless, since all of that
                // lives on the DocumentSession the tab owns, not on the view.
                .id(activeTab.id)
        }
        .onAppear {
            // Drain any external "open this file" request that arrived
            // before this view existed (the common cold-launch ordering —
            // see `ExternalOpenRequestQueue`'s doc comment) into the
            // already-empty first tab, so Finder/Launch Services/another
            // app's "open with NovaCAD" (e.g. another app's "Edit Layout") loads
            // the drawing instead of leaving the window blank.
            for url in ExternalOpenRequestQueue.shared.drainPending() {
                loadExternalURL(url)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .novaCADOpenExternalURL)) { note in
            // A LATER (warm-launch) request — NovaCAD was already running
            // when the OS delivered it. `enqueue` already fired this same
            // notification for anything caught by the `onAppear` drain
            // above too, so this handler must ignore duplicates; it does so
            // implicitly by being registered only AFTER `onAppear`'s drain
            // already consumed the backlog (`drainPending()` empties it),
            // so nothing here double-fires for a cold-launch URL.
            guard let url = note.userInfo?[DocumentNotificationKey.url] as? URL else { return }
            loadExternalURL(url)
        }
        // First-launch Welcome screen — see `WelcomeView`/`WelcomeScreenState`.
        // A `.sheet`, not a separate `Window` scene (contrast `AboutView`):
        // this should introduce/block the very first thing a new user sees
        // on THIS window, not persist as an independently-closable window a
        // user could leave open alongside their work.
        .sheet(isPresented: $showingWelcome) {
            WelcomeView(onDismiss: { showingWelcome = false })
        }
        // NovaCAD ▸ What's New… (app menu, next to About NovaCAD) re-opens
        // this same sheet on demand, bypassing `WelcomeScreenState.shouldShow`'s
        // normal "only once per version" gating — see
        // `Notification.Name.novaCADShowWelcome`'s own doc comment.
        .onReceive(NotificationCenter.default.publisher(for: .novaCADShowWelcome)) { _ in
            showingWelcome = true
        }
    }

    /// Routes one externally-delivered file URL into the app: the CURRENT
    /// tab if it has nothing loaded yet (the typical cold-launch state — one
    /// fresh empty `DocumentTab()`), otherwise a new tab (mirrors "Open File"
    /// while a document is already showing, same as `onOpenInNewTab`).
    private func loadExternalURL(_ url: URL) {
        if activeTab.session.currentSourceURL == nil, !activeTab.session.isLoading {
            activeTab.session.pendingOpenURL = url
        } else {
            openInNewTab(url: url)
        }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 1) {
                    ForEach(tabs) { tab in
                        tabButton(tab)
                    }
                }
            }
            Button {
                addTab()
            } label: {
                Image(systemName: "plus")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("New tab")
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func tabButton(_ tab: DocumentTab) -> some View {
        let isActive = tab.id == activeTabID
        return HStack(spacing: 6) {
            Text(tab.displayName)
                .lineLimit(1)
                .truncationMode(.middle)
                .font(.caption)
                .frame(maxWidth: 160, alignment: .leading)
            Button {
                closeTab(tab)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            .opacity(tabs.count > 1 ? 1 : 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isActive ? Color.accentColor.opacity(0.22) : Color.clear)
        .overlay(Rectangle().frame(width: 1).foregroundColor(.black.opacity(0.15)), alignment: .trailing)
        .contentShape(Rectangle())
        .onTapGesture { activeTabID = tab.id }
    }

    private func addTab() {
        let t = DocumentTab()
        tabs.append(t)
        activeTabID = t.id
    }

    private func closeTab(_ tab: DocumentTab) {
        guard tabs.count > 1 else {
            // Never go to zero tabs — reset the last one to a fresh empty tab.
            let fresh = DocumentTab()
            tabs = [fresh]
            activeTabID = fresh.id
            return
        }
        guard let idx = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs.remove(at: idx)
        if activeTabID == tab.id {
            activeTabID = tabs[max(0, idx - 1)].id
        }
    }

    /// "Open File" when the current tab already has a document loaded: make
    /// a new tab and hand it the URL to load once its ContentView appears
    /// (see ContentView's `.onAppear` / `session.pendingOpenURL`).
    private func openInNewTab(url: URL) {
        let t = DocumentTab()
        t.session.pendingOpenURL = url
        tabs.append(t)
        activeTabID = t.id
    }
}
