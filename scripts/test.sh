#!/bin/bash
# The fast tests. Safe on any Mac: no windows, no focus, no real claude.
#   scripts/test.sh          checks (stream parser, markdown, springs, the session against fake-claude)
#                            and a compile of the app
#   scripts/test.sh --vm     then build the app and run the window probe in the Tart VM on iris-agi
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
START=$(date +%s)

# One product per call: with two --product flags the Swift Build backend builds only the last one.
for product in sidekick-checks Sidekick; do
    if ! OUT=$(swift build --product "$product" 2>&1); then
        printf '%s\n' "$OUT" | /usr/bin/grep -E "error" >&2 || printf '%s\n' "$OUT" | /usr/bin/tail -20 >&2
        echo "test.sh: $product did not build" >&2
        exit 1
    fi
    printf '%s\n' "$OUT" | /usr/bin/grep -E "warning: " | /usr/bin/grep -v "^warning: 'sidekick'" || true
done
"$(swift build --show-bin-path)/sidekick-checks"

if [[ "${1:-}" == "--vm" ]]; then
    scripts/build-app.sh >/dev/null
    VM_DIR="${VM_DIR:-sidekick}" scripts/vm-run.sh
fi
echo "test.sh: done in $(( $(date +%s) - START ))s"
