#!/bin/zsh
# Wraps the SwiftPM executables in minimal .app bundles under build/.
# Bundles give each process its own TCC identity (Screen Recording, Accessibility)
# and let LaunchServices start them, which bare executables launched from a shell don't get.
#
# Usage: scripts/bundle.sh [debug|release]
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/.build/$CONFIG"
OUT="$ROOT/build"

cd "$ROOT"
swift build -c "$CONFIG" 2>&1 | grep -E "error:|Build complete" || true

make_app() {
  local name="$1" bundle_id="$2" ui_element="$3"
  local app="$OUT/$name.app"
  rm -rf "$app"
  mkdir -p "$app/Contents/MacOS"
  cp "$BIN/$name" "$app/Contents/MacOS/$name"
  # Sibling executables and resources the main binary expects next to itself.
  shift 3
  for extra in "$@"; do cp -R "$BIN/$extra" "$app/Contents/MacOS/"; done
  # SwiftPM's LiveKit frameworks (xcframework slices) live beside the binary.
  for fw in "$BIN"/*.framework; do
    [ -d "$fw" ] && { mkdir -p "$app/Contents/Frameworks"; cp -R "$fw" "$app/Contents/Frameworks/"; }
  done
  [ -d "$BIN/LiveKit_LiveKit.bundle" ] && cp -R "$BIN/LiveKit_LiveKit.bundle" "$app/Contents/MacOS/"
  # SwiftPM bakes an absolute rpath to .build/; add one that works when the bundle is copied elsewhere.
  install_name_tool -add_rpath @executable_path/../Frameworks "$app/Contents/MacOS/$name" 2>/dev/null || true

  cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>$name</string>
  <key>CFBundleIdentifier</key><string>$bundle_id</string>
  <key>CFBundleName</key><string>$name</string>
  <key>CFBundleDisplayName</key><string>$name</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><$ui_element/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSScreenCaptureUsageDescription</key><string>Teleport streams your windows to your other Mac.</string>
  <key>NSLocalNetworkUsageDescription</key><string>Teleport connects to your other Macs on this network.</string>
  <key>NSBonjourServices</key><array><string>_teleport._tcp</string></array>
</dict></plist>
PLIST
  # Ad-hoc signature so TCC keeps the grant across rebuilds (identity = bundle id + cdhash).
  codesign --force --deep --sign - "$app" 2>/dev/null
  echo "built $app"
}

make_app TeleportHost   ai.teleport.host   true
make_app TeleportViewer ai.teleport.viewer false TeleportDockTile
