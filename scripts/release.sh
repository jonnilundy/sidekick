#!/bin/bash
# Cut a Sidekick release: scripts/release.sh X.Y.Z [--publish]
#
#   1. Bump SidekickVersion to X.Y.Z and SidekickBuild by one (Version.swift, Info.plist).
#   2. Run scripts/test.sh, then build and ad hoc sign build/Sidekick.app.
#   3. Zip the app with ditto and sign the zip with Sparkle's sign_update. The EdDSA private key is
#      read at runtime from 1Password and goes over a pipe, never to disk or the screen.
#   4. Put an item for the zip first in appcast.xml (scripts/appcast-add.sh). Notes come from
#      release-notes/X.Y.Z.md when present.
#   5. With --publish: commit, tag, push the tag, create the GitHub release with the zip, push main.
#      The release goes up before main, so the appcast never points at a missing zip.
#
# The default is a dry run: steps 1 to 4 run, the appcast as it would be is kept at
# build/appcast-preview.xml, and the bump and the appcast are undone. It prints the publish commands.
#
# Refuses to run while SUPublicEDKey in Resources/Info.plist is the placeholder, when the key in
# 1Password is missing, or when that key does not match SUPublicEDKey.
#
# The key: item "Sidekick Sparkle EdDSA key" (an API Credential), field credential, vault "Iris Agi", read with the
# service account (OP_SERVICE_ACCOUNT_TOKEN). SIDEKICK_KEY_REF points at another copy. It is base64
# of a 32 byte Ed25519 seed, made once with OpenSSL 3:
#   seed=$(openssl genpkey -algorithm ed25519 | openssl pkey -outform DER | tail -c 32 | base64)
# `op read ... | swift scripts/ed-public-key.swift` prints its public key, the SUPublicEDKey value.
# A lost key means no installed copy can update again until it is reinstalled by hand.
#
# Tests only, never with --publish: SIDEKICK_SPARKLE_KEY_FILE reads a throwaway key from a file,
# SIDEKICK_DOWNLOAD_BASE points the enclosure at a local server, and build-app.sh's test overrides
# (SIDEKICK_BUNDLE_ID, SIDEKICK_FEED_URL, SIDEKICK_PUBLIC_KEY, ...) pass through.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

KEY_REF="${SIDEKICK_KEY_REF:-op://Iris Agi/Sidekick Sparkle EdDSA key/credential}"
REPO="jonnilundy/sidekick"
PLACEHOLDER="REPLACE-WITH-PUBLIC-KEY"
SPARKLE_BIN="$ROOT/.build/artifacts/sparkle/Sparkle/bin"
VERSION_FILE="Sources/SidekickCore/Version.swift"
PLIST="Resources/Info.plist"
APPCAST="$ROOT/appcast.xml"

fail() { echo "release: $*" >&2; exit 1; }

NEW_VERSION="${1:-}"
PUBLISH="${2:-}"
[[ -n "$NEW_VERSION" && ( -z "$PUBLISH" || "$PUBLISH" == "--publish" ) && $# -le 2 ]] || { echo "usage: scripts/release.sh X.Y.Z [--publish]" >&2; exit 2; }
[[ "$NEW_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "version must look like 1.2.3, got '$NEW_VERSION'"

# --- Preconditions. Nothing is changed before all of these pass. ---

PUBLIC_KEY="${SIDEKICK_PUBLIC_KEY:-$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$PLIST" 2>/dev/null || true)}"
if [[ -z "$PUBLIC_KEY" || "$PUBLIC_KEY" == "$PLACEHOLDER" ]]; then
    fail "SUPublicEDKey in $PLIST is still the placeholder. Put the public key of the 1Password key there and commit (the header of scripts/release.sh says how)."
fi

if [[ "$PUBLISH" == "--publish" ]]; then
    for var in SIDEKICK_SPARKLE_KEY_FILE SIDEKICK_DOWNLOAD_BASE SIDEKICK_BUNDLE_ID SIDEKICK_FEED_URL SIDEKICK_PUBLIC_KEY SIDEKICK_VERSION SIDEKICK_BUILD SIDEKICK_APP_OUT; do
        [[ -z "${!var:-}" ]] || fail "$var is a test override; unset it before --publish"
    done
    # Any branch or worktree may publish, as long as it holds everything on origin/main: the push at the
    # end is HEAD:main, and it must be a fast forward.
    git fetch -q origin main || fail "could not fetch origin/main"
    git merge-base --is-ancestor origin/main HEAD || fail "--publish needs everything on origin/main; rebase first"
    command -v gh >/dev/null || fail "gh is not installed"
fi

[[ -z "${SIDEKICK_APP_OUT:-}" ]] || fail "SIDEKICK_APP_OUT is not supported here; the release app is build/Sidekick.app"
[[ -z "$(git status --porcelain)" ]] || fail "commit or stash your changes first"
git rev-parse -q --verify "refs/tags/v$NEW_VERSION" >/dev/null && fail "tag v$NEW_VERSION exists already"

OLD_VERSION=$(sed -n 's/^public let SidekickVersion = "\([^"]*\)"$/\1/p' "$VERSION_FILE")
OLD_BUILD=$(sed -n 's/^public let SidekickBuild = \([0-9][0-9]*\)$/\1/p' "$VERSION_FILE")
[[ -n "$OLD_VERSION" && -n "$OLD_BUILD" ]] || fail "could not read SidekickVersion and SidekickBuild from $VERSION_FILE"
[[ "$NEW_VERSION" != "$OLD_VERSION" ]] || fail "$NEW_VERSION is the current version"
NEW_BUILD=$((OLD_BUILD + 1))

[[ -x "$SPARKLE_BIN/sign_update" ]] || swift package resolve >/dev/null
[[ -x "$SPARKLE_BIN/sign_update" ]] || fail "no sign_update in $SPARKLE_BIN; run swift build once"

# The private key: in a variable for the length of this script, never echoed or written.
if [[ -n "${SIDEKICK_SPARKLE_KEY_FILE:-}" ]]; then
    echo "release: test key from SIDEKICK_SPARKLE_KEY_FILE"
    PRIVATE_KEY=$(cat "$SIDEKICK_SPARKLE_KEY_FILE")
else
    command -v op >/dev/null || fail "the 1Password CLI (op) is not installed"
    OP_ERR=$(mktemp)
    if ! PRIVATE_KEY=$(op read "$KEY_REF" 2>"$OP_ERR"); then
        echo "release: could not read the Sparkle signing key from 1Password at $KEY_REF" >&2
        echo "release: op said: $(tr '\n' ' ' < "$OP_ERR")" >&2
        rm -f "$OP_ERR"
        exit 1
    fi
    rm -f "$OP_ERR"
fi
[[ -n "$PRIVATE_KEY" ]] || fail "the Sparkle signing key is empty"
DERIVED=$(printf '%s' "$PRIVATE_KEY" | swift scripts/ed-public-key.swift) || fail "the Sparkle signing key is not base64 of a 32 byte Ed25519 seed"
[[ "$DERIVED" == "$PUBLIC_KEY" ]] || fail "the signing key does not match SUPublicEDKey (its public key is $DERIVED). Updates signed with it would be refused."

# --- Bump. A dry run undoes it on exit. ---

if [[ "$PUBLISH" != "--publish" ]]; then
    trap 'git checkout -- "$VERSION_FILE" "$PLIST" appcast.xml 2>/dev/null || true' EXIT
fi
echo "release: $NEW_VERSION (build $NEW_BUILD), from $OLD_VERSION (build $OLD_BUILD)"
sed -i '' "s/^public let SidekickVersion = \".*\"$/public let SidekickVersion = \"$NEW_VERSION\"/" "$VERSION_FILE"
sed -i '' "s/^public let SidekickBuild = [0-9][0-9]*$/public let SidekickBuild = $NEW_BUILD/" "$VERSION_FILE"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NEW_VERSION" "$PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_BUILD" "$PLIST"

# --- Test, build, zip. ---

scripts/test.sh
scripts/build-app.sh 2>&1 | /usr/bin/grep -v "replacing existing signature"
APP="$ROOT/build/Sidekick.app"
BUILT_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
[[ "$BUILT_VERSION" == "${SIDEKICK_VERSION:-$NEW_VERSION}" ]] || fail "the built app has version $BUILT_VERSION, expected $NEW_VERSION"
BUILT_KEY=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$APP/Contents/Info.plist")
[[ "$BUILT_KEY" == "$PUBLIC_KEY" ]] || fail "the built app carries a different SUPublicEDKey"

ZIP_NAME="Sidekick-$NEW_VERSION.zip"
ZIP="$ROOT/build/$ZIP_NAME"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

# --- Sign the zip. ---

SIGNATURE=$(printf '%s' "$PRIVATE_KEY" | "$SPARKLE_BIN/sign_update" --ed-key-file - -p "$ZIP")
printf '%s' "$PRIVATE_KEY" | "$SPARKLE_BIN/sign_update" --verify --ed-key-file - "$ZIP" "$SIGNATURE" >/dev/null \
    || fail "sign_update could not verify its own signature"
unset PRIVATE_KEY
echo "release: signed $ZIP_NAME ($(stat -f %z "$ZIP") bytes)"

# --- Appcast. ---

DOWNLOAD_BASE="${SIDEKICK_DOWNLOAD_BASE:-https://github.com/$REPO/releases/download/v$NEW_VERSION}"
NOTES="release-notes/$NEW_VERSION.md"
[[ -f "$NOTES" ]] || NOTES=""
scripts/appcast-add.sh "$APPCAST" "$NEW_VERSION" "$NEW_BUILD" "$ZIP" "$SIGNATURE" "$DOWNLOAD_BASE/$ZIP_NAME" ${NOTES:+"$NOTES"}
cp "$APPCAST" "$ROOT/build/appcast-preview.xml"

# --- Publish, or print how. ---

if [[ -n "$NOTES" ]]; then
    NOTES_ARG="--notes-file $NOTES"
else
    NOTES_ARG="--generate-notes"
fi
COMMANDS=(
    "git add $VERSION_FILE $PLIST appcast.xml"
    "git commit -q -m 'Release $NEW_VERSION'"
    "git tag v$NEW_VERSION"
    "git push -q origin v$NEW_VERSION"
    "gh release create v$NEW_VERSION build/$ZIP_NAME --repo $REPO --title 'Sidekick $NEW_VERSION' $NOTES_ARG"
    # HEAD, not main: releases run from a worktree on its own branch (code-AGENTS.md).
    "git push -q origin HEAD:main"
)

if [[ "$PUBLISH" == "--publish" ]]; then
    for command in "${COMMANDS[@]}"; do
        echo "+ $command"
        eval "$command"
    done
    echo "release: published v$NEW_VERSION"
else
    echo
    echo "release: dry run, nothing published. Built build/$ZIP_NAME; the appcast as it would be is build/appcast-preview.xml."
    echo "release: the bump and appcast.xml are undone. --publish runs:"
    for command in "${COMMANDS[@]}"; do
        echo "  $command"
    done
fi
