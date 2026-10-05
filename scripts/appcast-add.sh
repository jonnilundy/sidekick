#!/bin/bash
# Put one release first in a Sparkle appcast. release.sh runs it; the checks run it on a temp copy.
#   scripts/appcast-add.sh <appcast.xml> <version> <build> <zip> <ed-signature> <zip-url> [notes.md]
# The notes go in as Markdown (Sparkle renders them in its update window), without an "## Install"
# section: whoever reads them there has the app already. No notes file gives "Sidekick <version>.".
# A missing appcast file starts as an empty channel. The result must be well formed XML.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ $# -ge 6 && $# -le 7 ]] || { echo "usage: appcast-add.sh <appcast.xml> <version> <build> <zip> <ed-signature> <zip-url> [notes.md]" >&2; exit 2; }
APPCAST="$1"; VERSION="$2"; BUILD="$3"; ZIP="$4"; SIGNATURE="$5"; URL="$6"; NOTES_FILE="${7:-}"
[[ -f "$ZIP" ]] || { echo "appcast-add: no zip at $ZIP" >&2; exit 1; }
[[ -z "$NOTES_FILE" || -f "$NOTES_FILE" ]] || { echo "appcast-add: no notes file at $NOTES_FILE" >&2; exit 1; }

LENGTH=$(stat -f %z "$ZIP")
MIN_OS=$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$ROOT/Resources/Info.plist")
PUB_DATE=$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")
RELEASE_PAGE="https://github.com/jonnilundy/sidekick/releases/tag/v$VERSION"
if [[ -n "$NOTES_FILE" ]]; then
    # Drop the Install section and trailing blank lines, and keep "]]>" from closing the CDATA early.
    NOTES=$(awk '/^## Install/ { exit } { print }' "$NOTES_FILE" | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' | sed 's/]]>/]]]]><![CDATA[>/g')
else
    NOTES="Sidekick $VERSION."
fi

ITEM=$(mktemp)
trap 'rm -f "$ITEM"' EXIT
cat > "$ITEM" <<EOF
        <item>
            <title>Version $VERSION</title>
            <pubDate>$PUB_DATE</pubDate>
            <sparkle:version>$BUILD</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>$MIN_OS</sparkle:minimumSystemVersion>
            <sparkle:fullReleaseNotesLink>$RELEASE_PAGE</sparkle:fullReleaseNotesLink>
            <description sparkle:format="markdown"><![CDATA[$NOTES]]></description>
            <enclosure url="$URL" length="$LENGTH" type="application/octet-stream" sparkle:edSignature="$SIGNATURE"/>
        </item>
EOF

if [[ ! -f "$APPCAST" ]]; then
    cat > "$APPCAST" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
    <channel>
        <title>Sidekick</title>
        <link>https://raw.githubusercontent.com/jonnilundy/sidekick/main/appcast.xml</link>
        <description>Sidekick updates</description>
        <language>en</language>
    </channel>
</rss>
EOF
fi
# After the channel's <language> line, so the newest release is always the first item.
awk -v item="$ITEM" '
    BEGIN { while ((getline line < item) > 0) body = body line "\n" }
    { print }
    !done && /<language>/ { printf "%s", body; done = 1 }
    END { if (!done) exit 3 }
' "$APPCAST" > "$APPCAST.new" || { rm -f "$APPCAST.new"; echo "appcast-add: $APPCAST has no <language> line to insert after" >&2; exit 1; }
mv "$APPCAST.new" "$APPCAST"
xmllint --noout "$APPCAST" || { echo "appcast-add: $APPCAST is not well formed after the insert" >&2; exit 1; }
echo "appcast: $VERSION (build $BUILD, $LENGTH bytes) added first to $APPCAST"
