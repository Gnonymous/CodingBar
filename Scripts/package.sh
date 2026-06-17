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

# SwiftPM resource bundle (pricing.json) must sit next to the executable for Bundle.module.
BUNDLE="$ROOT/.build/release/CodingBar_CodingBar.bundle"
[ -d "$BUNDLE" ] && cp -R "$BUNDLE" "$APP/Contents/MacOS/"

cp "$ROOT/Scripts/Info.plist" "$APP/Contents/Info.plist"

# Stamp the version from $CODINGBAR_VERSION when set (CI passes the git tag);
# local builds keep the value baked into Info.plist.
if [ -n "${CODINGBAR_VERSION:-}" ]; then
  VER="${CODINGBAR_VERSION#v}"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VER" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VER" "$APP/Contents/Info.plist"
  echo "▸ stamped version $VER"
fi

# Ad-hoc sign so Gatekeeper lets it run locally.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "  (codesign skipped)"

echo "✓ Built $APP"
echo "  Launch:  open \"$APP\"   (look for the pulse icon in your menu bar)"
