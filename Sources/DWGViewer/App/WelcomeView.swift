import SwiftUI

/// "Welcome to NovaCAD" screen, shown as a sheet over `DocumentTabsView` the
/// first time NovaCAD is opened AFTER a fresh install OR an update (see
/// `WelcomeScreenState.shouldShow`'s doc comment for exactly how "an update
/// happened" is detected), with a "Don't show this again" acknowledgment
/// button that dismisses it UNTIL THE NEXT update/install. Persisted via
/// `UserDefaults` (the same mechanism `AppSettings` already uses for every
/// other durable app preference — see that type's own doc comment on why
/// `@AppStorage` itself isn't used directly on a plain `ObservableObject`),
/// so it survives quitting and relaunching NovaCAD but is naturally scoped
/// per-user/per-Mac like every other preference here.
///
/// Deliberately a SHEET over the main window (not a separate `Window` scene
/// like `AboutView`): a welcome screen should block/introduce the very first
/// thing a user sees after opening a new build, whereas About is something
/// the user explicitly summons later and may want to leave open alongside
/// their work — the two have different lifecycles even though their content
/// (author credit, project link) overlaps.
struct WelcomeView: View {
    let onDismiss: () -> Void
    /// Whether "Don't show this again" is currently checked — starts true so
    /// the common path (a user who reads this once and moves on) is a single
    /// click on "Get Started" rather than requiring a second explicit
    /// checkbox interaction; unchecking it is how a user who wants to see
    /// this again next launch (e.g. before showing a coworker) opts back in.
    @State private var dontShowAgain = true

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 14) {
                    if let icon = NSApplication.shared.applicationIconImage {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 80, height: 80)
                    }
                    Text("Welcome to NovaCAD")
                        .font(.title2).bold()
                    Text("Version \(AppVersion.current)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("A native macOS DWG/DXF viewer for plant layouts — drawing exploration, layer/attribute editing, and an AI Assistant for aisle networks, dock aprons, and bulk attribute edits.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 360)

                    whatsNewSection

                    Divider().frame(width: 260).padding(.vertical, 4)

                    VStack(spacing: 3) {
                        Text("Created by Ryan DiRezze")
                            .font(.callout)
                        Link("github.com/ryandirezze", destination: URL(string: "https://github.com/ryandirezze")!)
                            .font(.callout)
                        Text("Project on GitHub")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(28)
            }
            .frame(maxHeight: 460)

            Divider()

            HStack {
                Toggle("Don't show this again", isOn: $dontShowAgain)
                    .toggleStyle(.checkbox)
                Spacer()
                Button("Get Started") {
                    if dontShowAgain {
                        WelcomeScreenState.markCurrentVersionSeen()
                    }
                    onDismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 440)
    }

    /// A simplified, end-user-facing summary of what changed recently —
    /// shown on EVERY appearance of this screen (both the very first launch
    /// and every subsequent post-update reappearance), per an explicit
    /// request: "the 'what's new' section should be a simplified summary for
    /// end-users of added/changed content since the last update/install."
    /// Content is `WhatsNew.recentHighlights` — see that constant's own doc
    /// comment for the maintenance contract (update it by hand alongside
    /// each feature that should be user-visible; this is NOT auto-generated
    /// from commit history, which would surface internal implementation
    /// detail no end user should see).
    private var whatsNewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("What's New", systemImage: "sparkles")
                .font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(WhatsNew.recentHighlights, id: \.self) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.tint)
                            .font(.caption)
                            .padding(.top, 2)
                        Text(item)
                            .font(.callout)
                            .foregroundColor(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(width: 360, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.accentColor.opacity(0.08)))
    }
}

/// The curated "What's New" content shown in `WelcomeView`.
///
/// MAINTENANCE CONTRACT: this is a plain, hand-maintained list of
/// SIMPLIFIED, END-USER-FACING summaries — not auto-generated from git log
/// or commit messages, which are written for other engineers/agents and
/// routinely describe internal implementation detail (render-group keys,
/// XDATA wire formats, transaction shapes) that would be meaningless or
/// actively confusing to an end user reading this screen. Whenever a
/// feature significant enough that an end user should know it exists ships,
/// add ONE short bullet describing what changed IN PRODUCT-BEHAVIOR TERMS
/// ("you can now do X") — not how it was implemented. Keep this list to a
/// small, current set of recent highlights rather than an ever-growing full
/// changelog; older entries should be trimmed as they stop being "new."
enum WhatsNew {
    static let recentHighlights: [String] = [
        "You can now choose NovaCAD in Finder's Open With menu for DWG and DXF drawings immediately after installation.",
        "You're now notified after opening a drawing if any external references couldn't be found or if the drawing was too large to fully resolve them all.",
        "Select a line or polyline to set its thickness right in the Properties pane — and it now actually draws thicker on screen.",
        "Select an enclosed shape (a closed polyline, rectangle, or circle) to fill/hatch it with a solid color or diagonal lines, with adjustable density and transparency.",
        "Travel distances are now measured down the middle of each aisle instead of along its edge lines — the old method could report nearly double the real distance.",
        "Ask for travel distances from a marketplace to every station in one step, and get a CSV with both one-way and round-trip figures on every row.",
        "Select an object on the drawing and say \"measure from this\" — the AI Assistant can now see what you have selected.",
        "The AI Assistant can draw each travel path on the drawing so you can check the route it measured and adjust it yourself.",
        "The AI Assistant now shows whether it's working or stalled, and a new reset button restarts it WITHOUT clearing your conversation.",
        "The AI Assistant is now a movable, resizable floating window — drag it anywhere over the drawing, or dock it back to the side.",
        "Shaded aisles, dock aprons, and any filled/hatched area are now fully editable — drag a corner, or use Stretch to extend one.",
        "The AI Assistant is more reliable — it keeps your chosen model when you open Settings and now tells you clearly when the model or local opencode server can't be reached instead of going quiet.",
    ]
}

/// Persistence for the Welcome screen's dismissal — tracks the LAST APP
/// VERSION the user acknowledged, not just a one-time bool, so the screen
/// (with its "What's New" section) reappears automatically the first time
/// NovaCAD is opened after any update/reinstall, then stays dismissed again
/// until the NEXT one. Backed by `UserDefaults`, same mechanism/rationale as
/// `AppSettings`'s other durable preferences (see that type's own doc
/// comment) — kept as a standalone enum rather than a property on
/// `AppSettings` itself since this is read exactly ONCE per app launch (at
/// `DocumentTabsView`'s init) rather than being an ongoing, view-observed
/// preference.
enum WelcomeScreenState {
    private static let key = "welcomeScreenLastSeenVersion"

    /// The running build's marketing version — `AppVersion.current` (see that
    /// type's own doc comment for the "bump `AppVersion.fallback` to re-show
    /// this screen" update convention, and for why a short hand-bumped
    /// "1.0.0"-style string is used rather than a noisy `git describe`
    /// string).
    private static var currentVersion: String { AppVersion.current }

    /// Whether the Welcome screen should be shown THIS launch — true when
    /// the currently-running version differs from the last version the user
    /// explicitly dismissed it at (which includes "never dismissed at all,"
    /// the fresh-install case, since the stored value is then `nil`). Once
    /// the user dismisses at version V, this returns `false` for every
    /// subsequent launch of THAT SAME build, and flips back to `true`
    /// automatically the moment a build with a different version is
    /// installed and launched — satisfying "permanently dismissed... until
    /// the next update/install" without any separate migration/reset step.
    static var shouldShow: Bool {
        UserDefaults.standard.string(forKey: key) != currentVersion
    }

    /// Records that the user has seen (and dismissed) the Welcome screen for
    /// the CURRENTLY RUNNING version — named to make that scoping explicit,
    /// unlike the old unconditional "permanently dismissed" wording this
    /// replaces (this dismissal is only permanent FOR THIS VERSION).
    static func markCurrentVersionSeen() {
        UserDefaults.standard.set(currentVersion, forKey: key)
    }
}
