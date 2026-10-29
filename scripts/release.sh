#!/bin/zsh
# Release build, notarized and stapled, zipped into dist/.
#
# One-time setup (an app-specific password from appleid.apple.com):
#   xcrun notarytool store-credentials teleport --apple-id you@example.com --team-id 9YX7DQ75N5
# Then: NOTARY_PROFILE=teleport scripts/release.sh
# Without NOTARY_PROFILE the zip is built but not notarized.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Teleport.app"
VERSION="$(python3 -c "import json;print(json.load(open('$ROOT/package.json'))['version'])")"
DIST="$ROOT/dist"
ZIP="$DIST/Teleport-$VERSION.zip"

"$ROOT/scripts/bundle.sh" release
codesign --verify --deep --strict "$APP"
mkdir -p "$DIST"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

if [ -n "${NOTARY_PROFILE:-}" ]; then
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  spctl --assess --type execute -vv "$APP" 2>&1 | tail -2
else
  echo "not notarized (set NOTARY_PROFILE); Gatekeeper will ask on another Mac"
fi
shasum -a 256 "$ZIP"
echo "release: $ZIP"
