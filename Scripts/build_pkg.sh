#!/bin/bash
# Builds NovaCAD.app (via build_app.sh, into a throwaway staging root rather
# than /Applications) and packages it into a distributable
# NovaCAD-<version>.pkg installer — the artifact to hand a coworker instead of
# a raw .app/.zip, since pkgbuild/productbuild produce the standard macOS
# double-click "Install NovaCAD" experience (progress bar, /Applications
# placement, Finder-recognized .pkg icon) rather than requiring the recipient
# to know to drag a .app bundle into /Applications themselves. The version in
# the filename (same one embedded as the app's own CFBundleVersion) means
# every new build produces a DIFFERENTLY NAMED file rather than silently
# overwriting whatever .pkg was built before it — so two shared .pkg files
# (e.g. one you sent a coworker last week, one you're about to send today)
# are distinguishable at a glance without opening either.
#
# NOT signed with a paid Apple Developer ID / notarized (this project has no
# such certificate — see `codesign`'s ad-hoc fallback in build_app.sh) so the
# recipient will see one Gatekeeper "unidentified developer" prompt on first
# install, exactly like the .app itself already requires. That is expected
# and does not indicate a bad build.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

APP_NAME="NovaCAD"
BUNDLE_ID="com.novacad.app"
# Marketing version — read from AppVersion.swift's `fallback`, the SINGLE
# source of truth shared with build_app.sh's CFBundleShortVersionString and
# with the About/Welcome screens' displayed "Version X.Y.Z" (see AppVersion's
# own doc comment). Reading it here rather than hardcoding a second copy is
# what guarantees the .pkg's filename always matches the version the app
# actually reports in its UI.
VERSION="$(sed -n 's/.*static let fallback = "\([^"]*\)".*/\1/p' \
    "$PROJECT_DIR/Sources/DWGViewer/App/AppVersion.swift" 2>/dev/null | head -1)"
VERSION="${VERSION:-1.0.0}"
# Explicit path argument (unusual case) is used verbatim; the default output
# name bakes VERSION in — e.g. NovaCAD-1.0.0.pkg — so every version bump
# produces a distinctly-named file instead of silently overwriting the
# previous build.
OUT="${1:-$PROJECT_DIR/$APP_NAME-$VERSION.pkg}"

STAGE_ROOT="$(mktemp -d)"
STAGE_APPS="$STAGE_ROOT/Applications"
mkdir -p "$STAGE_APPS"

echo "▸ Building $APP_NAME.app into a staging root (not /Applications) …"
# Reuses build_app.sh's existing build/assemble/sign logic verbatim (single
# source of truth for the bundle's contents) by pointing its INSTALL_DIR
# argument at the staging root instead of the real /Applications — this
# script never touches whatever NovaCAD.app is currently installed on THIS
# Mac, so packaging for a coworker can't accidentally disturb your own
# working copy.
"$PROJECT_DIR/Scripts/build_app.sh" "$STAGE_APPS" >/dev/null

echo "▸ Building $APP_NAME.pkg (version $VERSION) …"
pkgbuild \
    --root "$STAGE_ROOT" \
    --identifier "$BUNDLE_ID" \
    --version "$VERSION" \
    --install-location "/" \
    "$OUT" >/dev/null

rm -rf "$STAGE_ROOT"

echo "✓ Built $OUT"
echo ""
echo "Share this .pkg file. On first install, the recipient's Mac will show a"
echo "Gatekeeper \"unidentified developer\" warning (this build isn't signed"
echo "with a paid Apple Developer ID) — they can proceed via:"
echo "  System Settings → Privacy & Security → \"Open Anyway\""
echo "or by right-clicking the .pkg and choosing Open instead of double-clicking."
