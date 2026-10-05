#!/bin/bash
# Build Sidekick in release and assemble build/Sidekick.app with an ad hoc signature.
# The version and build number come from Sources/SidekickCore/Version.swift.
#
# Test builds only (never for a release): these override the bundle without touching the source.
#   SIDEKICK_APP_OUT     where the app goes, instead of build/Sidekick.app
#   SIDEKICK_BUNDLE_ID   a test bundle id, so a test copy keeps its own settings
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

if ! OUT=$(swift build -c release --product Sidekick 2>&1); then
    printf '%s\n' "$OUT" | /usr/bin/grep -E "error" >&2 || printf '%s\n' "$OUT" | /usr/bin/tail -20 >&2
    exit 1
fi
BIN="$(swift build -c release --show-bin-path)"

rm -rf "${APP:?}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/Sidekick" "$APP/Contents/MacOS/Sidekick"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# KeyboardShortcuts' strings (the Settings recorder). Its Bundle.module looks in Contents/Resources
# and stops the app when the bundle is missing.
cp -R "$BIN/KeyboardShortcuts_KeyboardShortcuts.bundle" "$APP/Contents/Resources/"
PLIST="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$PLIST"
[[ -n "${SIDEKICK_BUNDLE_ID:-}" ]] && /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $SIDEKICK_BUNDLE_ID" "$PLIST"
printf 'APPL????' > "$APP/Contents/PkgInfo"

codesign --force -s - "$APP"
codesign --verify --strict "$APP"
echo "built $APP (version $VERSION, build $BUILD, $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST"))"
