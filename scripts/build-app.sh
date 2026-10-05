#!/bin/bash
# Build Sidekick in release and assemble build/Sidekick.app with an ad hoc signature.
# The version and build number come from Sources/SidekickCore/Version.swift.
#
# Test builds only (never for a release): these override the bundle without touching the source.
#   SIDEKICK_APP_OUT     where the app goes, instead of build/Sidekick.app
#   SIDEKICK_BUNDLE_ID   a test bundle id, so a test copy keeps its own settings
#   SIDEKICK_VERSION     CFBundleShortVersionString, for example 0.2.0
#   SIDEKICK_BUILD       CFBundleVersion, an integer
#   SIDEKICK_FEED_URL    SUFeedURL, for example a localhost appcast
#   SIDEKICK_PUBLIC_KEY  SUPublicEDKey, a throwaway test key
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${SIDEKICK_APP_OUT:-$ROOT/build/Sidekick.app}"

cd "$ROOT"
VERSION=$(sed -n 's/^public let SidekickVersion = "\([^"]*\)"$/\1/p' Sources/SidekickCore/Version.swift)
BUILD=$(sed -n 's/^public let SidekickBuild = \([0-9][0-9]*\)$/\1/p' Sources/SidekickCore/Version.swift)
if [[ -z "$VERSION" || -z "$BUILD" ]]; then
    echo "could not read SidekickVersion and SidekickBuild from Sources/SidekickCore/Version.swift" >&2
    exit 1
fi
VERSION="${SIDEKICK_VERSION:-$VERSION}"
BUILD="${SIDEKICK_BUILD:-$BUILD}"

if ! OUT=$(swift build -c release --product Sidekick 2>&1); then
    printf '%s\n' "$OUT" | /usr/bin/grep -E "error" >&2 || printf '%s\n' "$OUT" | /usr/bin/tail -20 >&2
    exit 1
fi
BIN="$(swift build -c release --show-bin-path)"

rm -rf "${APP:?}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Sidekick" "$APP/Contents/MacOS/Sidekick"
# Sparkle: the framework from the SwiftPM artifact goes into Contents/Frameworks, with
# Autoupdate, Updater.app and the XPC services inside it. The executable finds it through
# @rpath, so add the standard rpath in case the linker only recorded the .build path.
SPARKLE="$(ls -d .build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-*/Sparkle.framework | head -1)"
mkdir -p "$APP/Contents/Frameworks"
cp -R "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"
if ! otool -l "$APP/Contents/MacOS/Sidekick" | /usr/bin/grep -q '@executable_path/../Frameworks'; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Sidekick"
fi
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# KeyboardShortcuts' strings (the Settings recorder). Its Bundle.module looks in Contents/Resources
# and stops the app when the bundle is missing.
cp -R "$BIN/KeyboardShortcuts_KeyboardShortcuts.bundle" "$APP/Contents/Resources/"
PLIST="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$PLIST"
[[ -n "${SIDEKICK_BUNDLE_ID:-}" ]] && /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $SIDEKICK_BUNDLE_ID" "$PLIST"
[[ -n "${SIDEKICK_FEED_URL:-}" ]] && /usr/libexec/PlistBuddy -c "Set :SUFeedURL $SIDEKICK_FEED_URL" "$PLIST"
[[ -n "${SIDEKICK_PUBLIC_KEY:-}" ]] && /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $SIDEKICK_PUBLIC_KEY" "$PLIST"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad hoc sign inside out: Sparkle's helpers first, then the framework, then the app.
FW="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
codesign --force -s - "$FW/XPCServices/Installer.xpc"
codesign --force -s - "$FW/XPCServices/Downloader.xpc"
codesign --force -s - "$FW/Autoupdate"
codesign --force -s - "$FW/Updater.app"
codesign --force -s - "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force -s - "$APP"
codesign --verify --strict "$APP"
echo "built $APP (version $VERSION, build $BUILD, $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST"))"
