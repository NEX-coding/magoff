#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BUILD_DIR="$ROOT/.build"
APP_DIR="$ROOT/dist/暗灯.app"
HELPERS="$APP_DIR/Contents/Helpers"

echo "==> Building MagOff (release)"
swift build -c release --product MagOff
swift build -c release --product magoff-helper

BIN_DIR="$BUILD_DIR/release"
test -x "$BIN_DIR/MagOff"
test -x "$BIN_DIR/magoff-helper"

echo "==> Assembling app bundle"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
mkdir -p "$HELPERS"

cp "$BIN_DIR/MagOff" "$APP_DIR/Contents/MacOS/MagOff"
cp "$BIN_DIR/magoff-helper" "$HELPERS/magoff-helper"
cp "$ROOT/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

# Ad-hoc sign so Gatekeeper is less noisy for local use.
codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || true

echo "==> Probe ACLC"
"$HELPERS/magoff-helper" --probe || true

echo
echo "Built: $APP_DIR"
echo "Open with: open \"$APP_DIR\""
echo "First time you pick a mode, macOS will ask for your password to install the helper."
