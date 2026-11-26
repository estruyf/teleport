#!/bin/zsh
# Writes a Sparkle appcast for one release archive, signed with the Teleport EdDSA key.
#
#   scripts/appcast.sh <zip> <download-url> [release-notes.html] > appcast.xml
#
#   SPARKLE_PRIVATE_KEY  the private key (as exported by `generate_keys -x`); CI passes the secret.
#                        Without it, sign_update reads the key from the login keychain
#                        (account "teleport", made with `generate_keys --account teleport`).
#   VERSION              default: package.json
#
# The appcast holds only this release: it is attached to the release, and the app reads
# releases/latest/download/appcast.xml, so the newest published release is always the feed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ZIP="${1:?usage: appcast.sh <zip> <download-url> [notes.html]}"
URL="${2:?usage: appcast.sh <zip> <download-url> [notes.html]}"
NOTES="${3:-}"
VERSION="${VERSION:-$(python3 -c "import json;print(json.load(open('$ROOT/package.json'))['version'])")}"
SIGN_UPDATE="${SIGN_UPDATE:-$ROOT/.build/artifacts/sparkle/Sparkle/bin/sign_update}"

[ -f "$ZIP" ] || { echo "no archive: $ZIP" >&2; exit 1; }
[ -x "$SIGN_UPDATE" ] || { echo "sign_update not found at $SIGN_UPDATE (run swift build first)" >&2; exit 1; }

# Prints: sparkle:edSignature="…" length="…"
if [ -n "${SPARKLE_PRIVATE_KEY:-}" ]; then
  ENCLOSURE="$(printf '%s' "$SPARKLE_PRIVATE_KEY" | "$SIGN_UPDATE" --ed-key-file - "$ZIP")"
else
  ENCLOSURE="$("$SIGN_UPDATE" --account teleport "$ZIP")"
fi
[[ "$ENCLOSURE" == *edSignature=* ]] || { echo "signing failed: $ENCLOSURE" >&2; exit 1; }

DESCRIPTION=""
if [ -n "$NOTES" ] && [ -s "$NOTES" ]; then
  # CDATA can't hold "]]>"; split it if the notes ever contain one.
  DESCRIPTION="<description><![CDATA[$(sed 's/]]>/]]]]><![CDATA[>/g' "$NOTES")]]></description>"
fi

PUBDATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"

cat <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Teleport</title>
    <link>https://github.com/estruyf/teleport</link>
    <item>
      <title>Teleport $VERSION</title>
      <pubDate>$PUBDATE</pubDate>
      <sparkle:version>$VERSION</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>https://github.com/estruyf/teleport/releases/tag/v$VERSION</sparkle:fullReleaseNotesLink>
      $DESCRIPTION
      <enclosure url="$URL" type="application/octet-stream" $ENCLOSURE/>
    </item>
  </channel>
</rss>
XML
