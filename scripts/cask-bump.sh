#!/bin/bash
# Point the Homebrew cask at a release: scripts/cask-bump.sh X.Y.Z path/to/Sidekick-X.Y.Z.zip
#
# Clones the tap (jonnilundy/homebrew-tap) into a temp folder, sets `version` and `sha256` in
# Casks/sidekick.rb, commits and pushes main. release.sh --publish runs it last, after the GitHub
# release exists, so the cask never points at a missing zip. A failure here leaves the release as is;
# run this again by hand.
#
# SIDEKICK_TAP_URL clones another copy of the tap (tests use a local bare repo).
set -euo pipefail

VERSION="${1:-}"
ZIP="${2:-}"
[[ -n "$VERSION" && -f "$ZIP" && $# -eq 2 ]] || { echo "usage: scripts/cask-bump.sh X.Y.Z path/to/zip" >&2; exit 2; }

TAP_URL="${SIDEKICK_TAP_URL:-https://github.com/jonnilundy/homebrew-tap.git}"
SHA=$(shasum -a 256 "$ZIP" | cut -d ' ' -f 1)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

git clone -q --depth 1 "$TAP_URL" "$WORK/tap"
CASK="$WORK/tap/Casks/sidekick.rb"
sed -i '' -E "s/^  version \"[^\"]*\"$/  version \"$VERSION\"/; s/^  sha256 \"[0-9a-f]*\"$/  sha256 \"$SHA\"/" "$CASK"
grep -q "^  version \"$VERSION\"$" "$CASK" && grep -q "^  sha256 \"$SHA\"$" "$CASK" \
    || { echo "cask-bump: could not set version and sha256 in Casks/sidekick.rb" >&2; exit 1; }

if git -C "$WORK/tap" diff --quiet; then
    echo "cask-bump: the cask is at $VERSION already"
    exit 0
fi
git -C "$WORK/tap" commit -q -am "Sidekick $VERSION"
git -C "$WORK/tap" push -q origin HEAD:main
echo "cask-bump: the cask is at $VERSION ($SHA)"
