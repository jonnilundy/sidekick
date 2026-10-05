#!/bin/bash
# Build Sidekick, quit the running copy, install to /Applications, start it.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="/Applications/Sidekick.app"
PATTERN="Sidekick.app/Contents/MacOS/Sidekick"
BUNDLE_ID="com.jonnilundy.sidekick"

"$ROOT/scripts/build-app.sh"

if pgrep -f "$PATTERN" >/dev/null; then
    echo "quitting the running copy"
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || pkill -f "$PATTERN" || true
    for _ in $(seq 1 20); do
        pgrep -f "$PATTERN" >/dev/null || break
        sleep 0.25
    done
    pgrep -f "$PATTERN" >/dev/null && pkill -9 -f "$PATTERN" || true
fi

rm -rf "${DEST:?}"
ditto "$ROOT/build/Sidekick.app" "$DEST"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST"
open "$DEST" 2>/dev/null || { sleep 1; open "$DEST"; }
echo "installed and started $DEST"
