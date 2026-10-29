#!/bin/zsh
# Builds Teleport and wraps it in build/Teleport.app.
# A bundle gives the app its own TCC identity (Screen Recording, Accessibility), an icon,
# and lets LaunchServices start it; bare executables launched from a shell get none of that.
#
# Usage: scripts/bundle.sh [debug|release]
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/.build/$CONFIG"
APP="$ROOT/build/Teleport.app"
VERSION="$(python3 -c "import json;print(json.load(open('$ROOT/package.json'))['version'])")"

cd "$ROOT"
swift build -c "$CONFIG" 2>&1 | grep -E "error:|Build complete" || true
[ -x "$BIN/Teleport" ] || { echo "build failed"; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$BIN/Teleport" "$BIN/TeleportDockTile" "$APP/Contents/MacOS/"
# SwiftPM's LiveKit frameworks (xcframework slices) and resource bundles live beside the binary.
for fw in "$BIN"/*.framework; do [ -d "$fw" ] && cp -R "$fw" "$APP/Contents/Frameworks/"; done
for rb in "$BIN"/*.bundle; do [ -d "$rb" ] && cp -R "$rb" "$APP/Contents/MacOS/"; done
[ -f "$ROOT/Resources/AppIcon.icns" ] || swift "$ROOT/scripts/make-icon.swift" "$ROOT/Resources/AppIcon.icns"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
# SwiftPM bakes an absolute rpath to .build/; add one that works when the bundle is copied elsewhere.
for exe in Teleport TeleportDockTile; do
  install_name_tool -add_rpath @executable_path/../Frameworks "$APP/Contents/MacOS/$exe" 2>/dev/null || true
done

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>Teleport</string>
  <key>CFBundleIdentifier</key><string>ai.teleport.app</string>
  <key>CFBundleName</key><string>Teleport</string>
  <key>CFBundleDisplayName</key><string>Teleport</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSScreenCaptureUsageDescription</key><string>Teleport streams your windows to your other Mac.</string>
  <key>NSLocalNetworkUsageDescription</key><string>Teleport connects to your other Macs on this network.</string>
  <key>NSBonjourServices</key><array><string>_teleport._tcp</string></array>
  <key>NSAppTransportSecurity</key><dict>
    <key>NSAllowsArbitraryLoads</key><true/>
    <key>NSAllowsLocalNetworking</key><true/>
  </dict>
</dict></plist>
PLIST

# Sign with a Developer ID when the keychain has one: its designated requirement is stable across
# builds, so macOS keeps the Screen Recording and Accessibility grants. An ad-hoc signature changes
# with every build (cdhash) and the grants would have to be redone each time.
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')}"
if [ -n "$IDENTITY" ]; then
  codesign --force --deep --options runtime --entitlements "$ROOT/scripts/entitlements.plist" --sign "$IDENTITY" "$APP"
  echo "signed as $IDENTITY"
else
  codesign --force --deep --sign - "$APP" 2>/dev/null
  echo "signed ad hoc (grants reset on every rebuild)"
fi
echo "built $APP ($CONFIG, $VERSION)"
