#!/bin/zsh
# Release build, notarized and stapled, zipped into dist/Teleport-<version>-arm64-mac.zip.
#
# Notarization credentials, either of:
#   NOTARY_PROFILE=teleport        a keychain profile, made once with
#                                  xcrun notarytool store-credentials teleport --apple-id <id> --team-id <team>
#   NOTARY_APPLE_ID, NOTARY_TEAM_ID, NOTARY_PASSWORD   an app-specific password (what CI uses)
# Without either the zip is built but not notarized.
#
# CODESIGN_IDENTITY picks the Developer ID (bundle.sh finds one in the keychain otherwise).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Teleport.app"
VERSION="$(python3 -c "import json;print(json.load(open('$ROOT/package.json'))['version'])")"
DIST="$ROOT/dist"
# The arch is in the name: only an Apple Silicon build is released for now.
ZIP="$DIST/Teleport-$VERSION-arm64-mac.zip"

# ditto as Sparkle recommends: keeps symlinks, permissions and code signatures intact.
pack() { rm -f "$ZIP"; ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"; }

"$ROOT/scripts/bundle.sh" release
codesign --verify --deep --strict "$APP"
mkdir -p "$DIST"
pack

notarize() {
  if [ -n "${NOTARY_PROFILE:-}" ]; then
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  else
    xcrun notarytool submit "$ZIP" --apple-id "$NOTARY_APPLE_ID" --team-id "$NOTARY_TEAM_ID" --password "$NOTARY_PASSWORD" --wait
  fi
}

if [ -n "${NOTARY_PROFILE:-}" ] || [ -n "${NOTARY_APPLE_ID:-}" ]; then
  # notarytool exits 0 for an Invalid result too; the status line is what counts.
  OUT="$(notarize 2>&1)" || true
  echo "$OUT"
  echo "$OUT" | grep -q "status: Accepted" || { echo "notarization was not accepted" >&2; exit 1; }
  xcrun stapler staple "$APP"
  pack
  spctl --assess --type execute -vv "$APP" 2>&1 | tail -2
else
  echo "not notarized (set NOTARY_PROFILE or NOTARY_APPLE_ID); Gatekeeper will ask on another Mac"
fi
shasum -a 256 "$ZIP"
echo "release: $ZIP"
