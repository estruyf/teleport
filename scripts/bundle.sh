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
# Never leave a half-built bundle behind: an unsigned app installed by mistake gets no
# Screen Recording or Accessibility grants, however often they are switched on.
trap '[ $? -eq 0 ] || { rm -rf "$APP"; echo "bundle failed; removed $APP" >&2; }' EXIT
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$BIN/Teleport" "$BIN/TeleportDockTile" "$APP/Contents/MacOS/"
# SwiftPM's LiveKit frameworks (xcframework slices) and resource bundles live beside the binary.
# The resource bundles go in Resources: codesign rejects them in MacOS. Nothing loads them
# through Bundle.module (LiveKit's only holds its privacy manifest).
for fw in "$BIN"/*.framework; do [ -d "$fw" ] && cp -R "$fw" "$APP/Contents/Frameworks/"; done
for rb in "$BIN"/*.bundle; do [ -d "$rb" ] && cp -R "$rb" "$APP/Contents/Resources/"; done
# livekit-server: LiveKit ships macOS builds only through Homebrew. Take the bottle for this
# arch, and the other arch's bottle when brew can fetch it, so the bundle runs on both kinds of Mac.
LIVEKIT_VERSION="1.13.11"
bundle_livekit() {
  local out="$APP/Contents/MacOS/livekit-server"
  local here; here="$(brew --prefix livekit 2>/dev/null)/bin/livekit-server"
  if [ ! -x "$here" ]; then
    echo "livekit-server not installed (brew install livekit); the host will need it on its own Mac"
    return 0
  fi
  local have; have="$("$here" --version 2>/dev/null | awk '{print $3}')"
  [ "$have" = "$LIVEKIT_VERSION" ] || echo "note: bundling livekit-server $have, pinned version is $LIVEKIT_VERSION"
  cp "$here" "$out"
  # The other architecture, best effort.
  local other_tag; [ "$(uname -m)" = "arm64" ] && other_tag="x86_64_sonoma" || other_tag="arm64_sonoma"
  local tmp; tmp="$(mktemp -d)"
  if brew fetch --quiet --bottle-tag="$other_tag" livekit >/dev/null 2>&1; then
    local bottle; bottle="$(brew --cache --bottle-tag="$other_tag" livekit 2>/dev/null)"
    if [ -f "$bottle" ] && tar -xzf "$bottle" -C "$tmp" 2>/dev/null; then
      local other; other="$(find "$tmp" -name livekit-server -type f | head -1)"
      if [ -n "$other" ] && lipo -create "$here" "$other" -output "$out" 2>/dev/null; then
        echo "livekit-server bundled as a universal binary"
      fi
    fi
  fi
  rm -rf "$tmp"
  [ -x "$out" ] && echo "livekit-server $(lipo -archs "$out" 2>/dev/null) bundled"
}
bundle_livekit

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
  codesign --force --deep --sign - "$APP"
  echo "signed ad hoc (grants reset on every rebuild)"
fi
echo "built $APP ($CONFIG, $VERSION)"
