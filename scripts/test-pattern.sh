#!/bin/zsh
# Builds build/Teleport Test Pattern.app: a window that stamps a frame counter and the time into
# its pixels, for measuring Teleport's latency and frame rate (docs/video-quality.md).
# Run it on the host and add it under Shared apps; it needs a bundle ID for that.
#
# Usage: scripts/test-pattern.sh [debug|release]
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Teleport Test Pattern.app"

cd "$ROOT"
echo "building TeleportTestPattern ($CONFIG)…"
swift build -c "$CONFIG" --product TeleportTestPattern 2>&1 | grep -E "error:|complete!" || true
BIN="$(swift build -c "$CONFIG" --show-bin-path)/TeleportTestPattern"
[ -x "$BIN" ] || { echo "build failed"; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/TeleportTestPattern"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>TeleportTestPattern</string>
  <key>CFBundleIdentifier</key><string>ai.teleport.testpattern</string>
  <key>CFBundleName</key><string>Teleport Test Pattern</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1
echo "built $APP"
