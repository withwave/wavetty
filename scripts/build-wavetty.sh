#!/usr/bin/env bash
# Build Wavetty (withwave fork of Ghostty).
#
# This script:
#   1. Runs the standard zig build
#   2. Rebrands the app bundle (name, bundle ID, version, icon)
#   3. Signs with Developer ID
#   4. Submits for Apple notarization and staples
#   5. Optionally creates a DMG and uploads to GitHub release
#
# All rebranding is done post-build via plutil so that the upstream
# project files (project.pbxproj, Info.plist) remain untouched. This
# keeps `git rebase upstream/main` clean.
#
# Usage:
#   scripts/build-wavetty.sh          # build only
#   scripts/build-wavetty.sh --dmg    # build + DMG
#   scripts/build-wavetty.sh --release  # build + DMG + GitHub release upload

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
APP_NAME="Wavetty"
BUNDLE_ID="com.modincompany.wavetty"
VERSION="$(cat VERSION 2>/dev/null || echo "1.3.2-withwave")"
SIGNING_IDENTITY="Developer ID Application: MODIN COMPANY (8AC9KUZJ5P)"
NOTARY_PROFILE="modin-notary"
ENTITLEMENTS="macos/GhosttyReleaseLocal.entitlements"
GITHUB_REPO="withwave/ghostty"
RELEASE_TAG="v1.3.2-withwave"

# Use brew zig@0.15 (patched for Xcode 26.4)
export PATH="/opt/homebrew/opt/zig@0.15/bin:$PATH"

# ---------------------------------------------------------------------------
# Args
# ---------------------------------------------------------------------------
MAKE_DMG=0
DO_RELEASE=0
for arg in "$@"; do
    case "$arg" in
        --dmg)     MAKE_DMG=1 ;;
        --release) MAKE_DMG=1; DO_RELEASE=1 ;;
        *) echo "Unknown arg: $arg"; exit 1 ;;
    esac
done

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP="$ROOT/zig-out/Ghostty.app"
DMG="$ROOT/zig-out/$APP_NAME.dmg"

# Patch upstream sources before build, restore on exit so rebases stay clean.
SOURCE_BACKUP=$(mktemp -d)
ASSET_DIR="$ROOT/macos/Assets.xcassets/AppIconImage.imageset"
ICON_DIR="$ROOT/scripts/imageset_icons"
trap 'restore_sources' EXIT
restore_sources() {
    # Restore Swift sources
    if [ -f "$SOURCE_BACKUP/AboutView.swift" ]; then
        cp "$SOURCE_BACKUP/AboutView.swift" "$ROOT/macos/Sources/Features/About/AboutView.swift"
    fi
    if [ -f "$SOURCE_BACKUP/BaseTerminalController.swift" ]; then
        cp "$SOURCE_BACKUP/BaseTerminalController.swift" "$ROOT/macos/Sources/Features/Terminal/BaseTerminalController.swift"
    fi
    # Restore asset PNGs
    if [ -d "$SOURCE_BACKUP/imageset" ]; then
        cp -R "$SOURCE_BACKUP/imageset"/*.png "$ASSET_DIR/" 2>/dev/null || true
    fi
    rm -rf "$SOURCE_BACKUP"
    echo "    Sources restored."
}

# Backup and patch AboutView.swift to show the bundle's display name
ABOUT_VIEW="$ROOT/macos/Sources/Features/About/AboutView.swift"
if [ -f "$ABOUT_VIEW" ]; then
    cp "$ABOUT_VIEW" "$SOURCE_BACKUP/AboutView.swift"
    sed -i '' 's|Text("Ghostty")|Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Ghostty")|g' "$ABOUT_VIEW"
fi

# Patch BaseTerminalController.swift:
#   * Replace the proxy folder icon with the app icon
# Note: 👻 → 🌊 is committed directly to source (no patch needed).
BASE_TERM="$ROOT/macos/Sources/Features/Terminal/BaseTerminalController.swift"
if [ -f "$BASE_TERM" ]; then
    cp "$BASE_TERM" "$SOURCE_BACKUP/BaseTerminalController.swift"
    sed -i '' 's|window.representedURL = to|window.representedURL = to; window.standardWindowButton(.documentIconButton)?.image = NSApp.applicationIconImage|g' "$BASE_TERM"
    sed -i '' '/override func windowDidLoad() {/,/guard let window else { return }/{
        s|guard let window else { return }|guard let window else { return }\
\
        // Wavetty: replace the proxy icon with the app icon at window load\
        window.standardWindowButton(.documentIconButton)?.image = NSApp.applicationIconImage|
    }' "$BASE_TERM"
fi

# Backup and overlay Wavetty PNGs in AppIconImage.imageset.
# AppIconImage is referenced in SwiftUI views (titlebar small icon, About,
# Settings, ErrorView, etc.). Replacing source before build is the only
# way to change these without modifying upstream code.
if [ -d "$ICON_DIR" ] && [ -d "$ASSET_DIR" ]; then
    mkdir -p "$SOURCE_BACKUP/imageset"
    cp -R "$ASSET_DIR"/*.png "$SOURCE_BACKUP/imageset/"
    cp -R "$ICON_DIR"/*.png "$ASSET_DIR/"
    # Force asset catalog recompile by clearing Xcode cache
    rm -rf "$ROOT/macos/build" "$ROOT/.zig-cache" 2>/dev/null
fi

echo "==> Step 1: zig build (ReleaseFast)"
zig build -Doptimize=ReleaseFast
restore_sources
[ -x "$APP/Contents/MacOS/ghostty" ] || { echo "Build failed: binary missing"; exit 1; }

echo "==> Step 2: Rebrand bundle"
PLIST="$APP/Contents/Info.plist"

# Display name (Dock, Finder, Cmd+Tab, About)
plutil -replace CFBundleName -string "$APP_NAME" "$PLIST"
plutil -replace CFBundleDisplayName -string "$APP_NAME" "$PLIST"

# Bundle ID — separate app from upstream Ghostty
plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$PLIST"

# Version strings
plutil -replace CFBundleShortVersionString -string "$VERSION" "$PLIST"
plutil -replace CFBundleVersion -string "$VERSION" "$PLIST"

echo "    Display name : $APP_NAME"
echo "    Bundle ID    : $BUNDLE_ID"
echo "    Version      : $VERSION"

# Custom icon: macOS prioritizes CFBundleIconName (asset catalog) over
# CFBundleIconFile (.icns). Remove the asset-catalog reference so the
# .icns we drop in is actually used. Assets.car stays intact for
# AccentColor, Alternate Icons, etc.
if [ -f "$ROOT/scripts/icon.icns" ]; then
    cp "$ROOT/scripts/icon.icns" "$APP/Contents/Resources/Ghostty.icns"
    plutil -remove CFBundleIconName "$PLIST" 2>/dev/null || true
    echo "    Icon         : custom (scripts/icon.icns)"
fi

# Rename hardcoded user-facing menu/UI strings in the compiled .nib files.
# Only matches strings with spaces so we don't touch Swift mangled class
# names like _TtC7Ghostty11AppDelegate. "Ghostty" and "Wavetty" are both
# 7 characters, so binary length stays identical.
echo "    Rebrand nibs : in-place string replace (spaces only)"
for nib in "$APP/Contents/Resources"/*.nib; do
    [ -f "$nib" ] || continue
    LC_ALL=C sed -i '' \
        -e 's/About Ghostty/About Wavetty/g' \
        -e 's/Quit Ghostty/Quit Wavetty/g' \
        -e 's/Hide Ghostty/Hide Wavetty/g' \
        -e 's/Ghostty Help/Wavetty Help/g' \
        -e 's/Show Ghostty/Show Wavetty/g' \
        -e 's/Make Ghostty the Default Terminal/Make Wavetty the Default Terminal/g' \
        -e 's/Ghostty Application Icon/Wavetty Application Icon/g' \
        "$nib"
    # Replace "👻 Ghostty" (default window title) with "🌊 Wavetty".
    # Both are 4-byte UTF-8 emoji + " " + 7-char name = same byte length.
    LC_ALL=C sed -i '' 's|👻 Ghostty|🌊 Wavetty|g' "$nib"
done

# Disable Sparkle auto-update — upstream's appcast does not include
# our fork's releases. Users should check GitHub releases manually.
plutil -remove SUPublicEDKey "$PLIST" 2>/dev/null || true
plutil -replace SUEnableAutomaticChecks -bool false "$PLIST"
echo "    Auto-update  : disabled (manual via GitHub Releases)"

echo "==> Step 3: Sign with Developer ID + hardened runtime + timestamp"
codesign --force --deep --sign "$SIGNING_IDENTITY" \
    --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --timestamp \
    "$APP"
codesign --verify --deep --strict "$APP"
echo "    Signed and verified."

if [ "$MAKE_DMG" -eq 0 ]; then
    echo "==> Done (no DMG requested)"
    exit 0
fi

echo "==> Step 4: Create DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$APP" -ov -format UDZO "$DMG"
codesign --force --sign "$SIGNING_IDENTITY" --timestamp "$DMG"
echo "    DMG created and signed."

echo "==> Step 5: Notarize"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
spctl -a -t open --context context:primary-signature -v "$DMG"
echo "    Notarized and stapled."

if [ "$DO_RELEASE" -eq 0 ]; then
    echo "==> Done. DMG at: $DMG"
    exit 0
fi

echo "==> Step 6: Upload to GitHub Release"
gh release upload "$RELEASE_TAG" "$DMG" --repo "$GITHUB_REPO" --clobber
echo "    Uploaded to https://github.com/$GITHUB_REPO/releases/tag/$RELEASE_TAG"

echo "==> All done."
