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

# SwiftPM doesn't know it's targeting a .app bundle, so the binary's rpath only
# includes @loader_path. dyld then can't find @rpath/Sparkle.framework when we
# stage it under Contents/Frameworks/. Add the standard app-bundle rpath so the
# framework resolves at runtime. install_name_tool -add_rpath is idempotent-
# unfriendly (it errors if the path already exists), hence the `|| true` guard
# for repeat local builds.
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/CodingBar" 2>/dev/null || true

cp "$ROOT/Scripts/Info.plist" "$APP/Contents/Info.plist"

# App icon (DIRECTION 03 pulse squircle). Committed as Scripts/AppIcon.icns;
# regenerate with `make icon`. CFBundleIconFile in Info.plist points at it.
[ -f "$ROOT/Scripts/AppIcon.icns" ] && cp "$ROOT/Scripts/AppIcon.icns" "$APP/Contents/Resources/CodingBar.icns"

# Embed Sparkle.framework so the packaged app can self-update. SwiftPM already
# stages the full framework (with Autoupdate / Updater.app / XPCServices, all
# pre-signed ad-hoc by upstream) at .build/release/Sparkle.framework — we just
# move it under Contents/Frameworks/ at the location dyld expects.
SPARKLE_SRC="$ROOT/.build/release/Sparkle.framework"
[ -d "$SPARKLE_SRC" ] || { echo "Sparkle.framework not found at $SPARKLE_SRC — run swift build -c release first"; exit 1; }
mkdir -p "$APP/Contents/Frameworks"
# Use ditto so framework symlinks are preserved exactly (cp -R can mangle them).
ditto "$SPARKLE_SRC" "$APP/Contents/Frameworks/Sparkle.framework"

# Stamp the version from $CODINGBAR_VERSION when set (CI passes the git tag);
# local builds keep the value baked into Info.plist.
if [ -n "${CODINGBAR_VERSION:-}" ]; then
  VER="${CODINGBAR_VERSION#v}"
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VER" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VER" "$APP/Contents/Info.plist"
  echo "▸ stamped version $VER"
fi

# Ad-hoc sign so Gatekeeper lets it run locally (no Developer ID, so users still
# right-click → Open or clear the quarantine flag on first launch). Sparkle's
# nested helpers (XPCServices, Updater.app, Autoupdate) ship pre-signed by
# upstream; signing inner-first WITHOUT --deep on the outer .app preserves
# those signatures intact. `--deep` here would rewrite them and break Sparkle's
# internal trust chain. Fail LOUDLY — `set -e` aborts on any codesign failure.
SPARKLE_VER="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
codesign --force --sign - --options runtime "$SPARKLE_VER/XPCServices/Installer.xpc"
codesign --force --sign - --options runtime "$SPARKLE_VER/XPCServices/Downloader.xpc"
codesign --force --sign - --options runtime "$SPARKLE_VER/Updater.app"
codesign --force --sign - --options runtime "$SPARKLE_VER/Autoupdate"
codesign --force --sign - --options runtime "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"

echo "✓ Built $APP"
echo "  Launch:  open \"$APP\"   (look for the pulse icon in your menu bar)"
