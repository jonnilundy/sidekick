#!/bin/bash
# End to end update test against a local feed, with a throwaway key. Builds here, runs in the VM.
#   scripts/update-test.sh          build the two test apps and the feed, then run scripts/vm-update-test.sh in the VM
#   scripts/update-test.sh --prep   only build them, into build/update-test/
# The test copies use the bundle id com.jonnilundy.sidekick.updatetest, version 0.0.1 and 0.0.2, and
# the feed http://127.0.0.1:8765/appcast.xml. The key is made for this run and only signs this feed.
# Set VM_DIR=sidekick-<task> as for vm-run.sh. Results land in build/vm-out/.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
OUT="$ROOT/build/update-test"
SPARKLE_BIN="$ROOT/.build/artifacts/sparkle/Sparkle/bin"
FEED="http://127.0.0.1:8765"
export SIDEKICK_BUNDLE_ID="com.jonnilundy.sidekick.updatetest"
export SIDEKICK_FEED_URL="$FEED/appcast.xml"

rm -rf "$OUT"
mkdir -p "$OUT/feed"
KEY=$(/opt/homebrew/bin/openssl genpkey -algorithm ed25519 | /opt/homebrew/bin/openssl pkey -outform DER | tail -c 32 | base64)
export SIDEKICK_PUBLIC_KEY=$(printf '%s' "$KEY" | swift scripts/ed-public-key.swift)

build() {
    SIDEKICK_VERSION="$1" SIDEKICK_BUILD="$2" SIDEKICK_APP_OUT="$OUT/$3/Sidekick.app" scripts/build-app.sh 2>&1 | tail -1
}
build 0.0.1 1 old
build 0.0.2 2 new

ZIP="$OUT/feed/Sidekick-0.0.2.zip"
ditto -c -k --keepParent "$OUT/new/Sidekick.app" "$ZIP"
SIGNATURE=$(printf '%s' "$KEY" | "$SPARKLE_BIN/sign_update" --ed-key-file - -p "$ZIP")
unset KEY
printf '## Test release\n\n- This is **0.0.2**, served from the VM.\n\n## Install\n\nNot shown.\n' > "$OUT/notes.md"
scripts/appcast-add.sh "$OUT/feed/appcast.xml" 0.0.2 2 "$ZIP" "$SIGNATURE" "$FEED/Sidekick-0.0.2.zip" "$OUT/notes.md"

[[ "${1:-}" == "--prep" ]] && exit 0
scripts/vm-run.sh scripts/vm-update-test.sh
