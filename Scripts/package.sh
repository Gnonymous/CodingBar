#!/bin/bash
# Build a double-clickable CodingBar.app bundle (no Xcode required).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/CodingBar.app"

echo "▸ swift build -c release"
swift build -c release --package-path "$ROOT"

BIN="$ROOT/.build/release/CodingBar"
[ -f "$BIN" ] || { echo "release binary not found at $BIN"; exit 1; }

echo "▸ assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/CodingBar"

cp "$ROOT/Scripts/Info.plist" "$APP/Contents/Info.plist"

# App icon (DIRECTION 03 pulse squircle). Committed as Scripts/AppIcon.icns;
# regenerate with `make icon`. CFBundleIconFile in Info.plist points at it.
[ -f "$ROOT/Scripts/AppIcon.icns" ] && cp "$ROOT/Scripts/AppIcon.icns" "$APP/Contents/Resources/CodingBar.icns"

# Stamp the version from $CODINGBAR_VERSION when set (CI passes the git tag);
# local builds keep the value baked into Info.plist.
if [ -n "${CODINGBAR_VERSION:-}" ]; then
  VER="${CODINGBAR_VERSION#v}"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VER" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VER" "$APP/Contents/Info.plist"
  echo "▸ stamped version $VER"
fi

# Ad-hoc sign so Gatekeeper lets it run locally (no Developer ID, so users still
# right-click → Open or clear the quarantine flag on first launch). Fail LOUDLY:
# a silently-unsigned .app was shipping before because a stray SwiftPM resource
# bundle in Contents/MacOS tripped `codesign --deep`. `set -e` aborts on failure.
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"

echo "✓ Built $APP"
echo "  Launch:  open \"$APP\"   (look for the pulse icon in your menu bar)"
