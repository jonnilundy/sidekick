#!/bin/bash
# Cut a release: bump the version, test, build, zip, tag, and publish a GitHub release.
#   scripts/release.sh 0.2.0              dry run: bump, test, build and zip, print what would publish
#   scripts/release.sh 0.2.0 --publish    also commit the bump, tag, push and create the GitHub release
# The build number goes up by one each release. Notes come from release-notes/<version>.md when present.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="${1:?usage: scripts/release.sh X.Y.Z [--publish]}"
PUBLISH="${2:-}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "release: version must look like 1.2.3" >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "release: commit or stash your changes first" >&2; exit 1; }

BUILD=$(( $(sed -n 's/^public let SidekickBuild = \([0-9][0-9]*\)$/\1/p' Sources/SidekickCore/Version.swift) + 1 ))
sed -i '' "s/^public let SidekickVersion = .*/public let SidekickVersion = \"$VERSION\"/; s/^public let SidekickBuild = .*/public let SidekickBuild = $BUILD/" Sources/SidekickCore/Version.swift

scripts/test.sh
scripts/build-app.sh
ZIP="build/Sidekick-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent build/Sidekick.app "$ZIP"
echo "release: built $ZIP (version $VERSION, build $BUILD)"

if [[ "$PUBLISH" != "--publish" ]]; then
    git checkout -- Sources/SidekickCore/Version.swift
    echo "release: dry run, nothing published. Add --publish to tag and publish v$VERSION."
    exit 0
fi

git commit -qam "Release $VERSION"
git tag "v$VERSION"
git push -q origin HEAD:main "v$VERSION"
NOTES="release-notes/$VERSION.md"
if [[ -f "$NOTES" ]]; then
    gh release create "v$VERSION" "$ZIP" --title "Sidekick $VERSION" --notes-file "$NOTES"
else
    gh release create "v$VERSION" "$ZIP" --title "Sidekick $VERSION" --generate-notes
fi
echo "release: published v$VERSION"
