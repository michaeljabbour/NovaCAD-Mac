import Foundation

/// Single source of truth for NovaCAD's marketing version string — shown on
/// the About panel, the Welcome/What's New screen, and used by that screen's
/// per-version "don't show again" gating (`WelcomeScreenState.shouldShow`).
///
/// Mirrors the sibling app's own `AppVersion` convention (same author)
/// rather than deriving a version from `git describe` (the previous approach
/// here): a git-describe string drags along noisy internal milestone/branch
/// names (e.g. a "tag-142-g927a1e3"-style nearest-tag string) that are
/// meaningless to an end user and make the `.pkg` filename needlessly
/// long/cryptic. A short, hand-bumped "0.1.0"-style string is what both the
/// Welcome screen and the shared `.pkg`'s own filename should show.
///
/// **Update convention:** whenever a change is significant enough that the
/// Welcome/What's New screen should reappear for existing users on their next
/// launch, bump `fallback` here — this is the ONLY version number that needs
/// bumping (see `Scripts/build_pkg.sh`'s own comment: it reads this same
/// value, not a separate one, so the `.pkg` filename and the in-app version
/// can never drift apart).
enum AppVersion {
    static let fallback = "1.2.4"

    /// `Scripts/build_app.sh` bakes this into the installed `.app`'s
    /// `Info.plist` as `CFBundleShortVersionString`. A bare `swift run`/
    /// `swift test` process (no real app bundle/Info.plist) falls back to
    /// `fallback` above, so this always resolves to a sensible value in
    /// either context.
    static var current: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? fallback
    }
}
