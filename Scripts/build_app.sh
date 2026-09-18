#!/bin/bash
# Builds NovaCAD.app and installs it into /Applications so it launches like a
# normal Mac app. Re-run after code changes to update the installed app.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

APP_NAME="NovaCAD"
BUNDLE_ID="com.novacad.app"
INSTALL_DIR="${1:-/Applications}"
APP="$INSTALL_DIR/$APP_NAME.app"

echo "▸ Building release binary…"
swift build -c release --product "$APP_NAME"
BIN="$(swift build -c release --product "$APP_NAME" --show-bin-path)/$APP_NAME"
# Marketing version — read straight out of AppVersion.swift's `fallback` so
# that Swift constant is the SINGLE source of truth (bumping it is the only
# edit needed to re-show the Welcome/What's New screen and to change the
# shared .pkg's filename; see AppVersion's own doc comment). Falls back to
# 1.0.0 only if that line can't be parsed, which would mean the file moved.
VERSION="$(sed -n 's/.*static let fallback = "\([^"]*\)".*/\1/p' \
    "$PROJECT_DIR/Sources/DWGViewer/App/AppVersion.swift" 2>/dev/null | head -1)"
VERSION="${VERSION:-1.0.0}"
# Build metadata (CFBundleVersion) stays git-derived — it's the "which exact
# commit is this" identifier, distinct from the marketing version above, and
# is never shown in the UI or used for the Welcome screen's gating.
BUILD="$(git describe --tags --always 2>/dev/null || echo 1)"

echo "▸ Assembling $APP …"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
# No SwiftPM resource bundle to copy — see Package.swift's own comment on
# why the one resource this target used to declare (acad.pgp) is now
# embedded as a Swift string literal (PGPFile.defaultContents) instead of a
# runtime `Bundle.module` lookup, which is fundamentally incompatible with a
# validly-signed .app (its required top-level bundle location is a place
# `codesign --deep` refuses to seal).

# ---- Icon ----
ICONSET="$(mktemp -d)/$APP_NAME.iconset"
mkdir -p "$ICONSET"
MASTER="$(mktemp -d)/icon_1024.png"
if python3 "$PROJECT_DIR/Scripts/make_icon.py" "$MASTER" >/dev/null 2>&1; then
    for s in 16 32 64 128 256 512 1024; do
        sips -z $s $s "$MASTER" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    done
    # Retina @2x variants.
    for s in 16 32 128 256 512; do
        d=$((s * 2))
        sips -z $d $d "$MASTER" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/$APP_NAME.icns" || true
fi

# ---- Info.plist ----
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIconFile</key><string>$APP_NAME</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHumanReadableCopyright</key><string>Created by Ryan DiRezze.</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Drawing</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>com.autodesk.dwg</string>
                <string>public.item</string>
            </array>
            <key>CFBundleTypeExtensions</key>
            <array><string>dxf</string><string>dwg</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

# Ad-hoc code signature so Gatekeeper lets it launch locally.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "✓ Installed $APP"
