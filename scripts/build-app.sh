#!/usr/bin/env bash
# Build Headroom.app — a menu-bar agent bundle around the SwiftPM executable, with an
# AppIcon.icns rendered from the ChefHat. Unsigned (ad-hoc); signing/notarization is a
# separate, gated step (needs a Developer ID). See docs/ROADMAP.md Phase 6.
set -uo pipefail
cd "$(dirname "$0")/.."

APP="Headroom.app"
BUNDLE_ID="io.rundatarun.headroom"
VERSION="${HEADROOM_VERSION:-0.1.0}"
EXE="HeadroomApp"
CONFIG="${1:-release}"

echo "▶ swift build -c $CONFIG"
swift build -c "$CONFIG" || { echo "build failed"; exit 1; }
BIN=".build/$CONFIG/$EXE"
[ -x "$BIN" ] || { echo "missing $BIN"; exit 1; }

echo "▶ assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Headroom"

# --- icon: render PNGs from the ChefHat, assemble an .icns ---
echo "▶ rendering icon"
ICONSET="$(mktemp -d)/AppIcon.iconset"; mkdir -p "$ICONSET"
render() { "$BIN" --render-icon "$ICONSET/$1" "$2" >/dev/null 2>&1; }
render icon_16x16.png 16;      render icon_16x16@2x.png 32
render icon_32x32.png 32;      render icon_32x32@2x.png 64
render icon_128x128.png 128;   render icon_128x128@2x.png 256
render icon_256x256.png 256;   render icon_256x256@2x.png 512
render icon_512x512.png 512;   render icon_512x512@2x.png 1024
if iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null; then
  echo "  AppIcon.icns ok"
else
  echo "  ⚠ iconutil failed — bundle will use the default icon"
fi

# --- Info.plist (LSUIElement = menu-bar agent, no dock) ---
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Headroom</string>
  <key>CFBundleDisplayName</key><string>Headroom</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>Headroom</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHumanReadableCopyright</key><string>MIT licensed</string>
</dict>
</plist>
PLIST

# --- ad-hoc sign so notifications / launch-at-login / Keychain ACLs behave locally ---
echo "▶ ad-hoc codesign"
codesign --force --deep --sign - "$APP" 2>/dev/null && echo "  signed (ad-hoc)" || echo "  ⚠ ad-hoc sign failed (still runnable)"

echo "✓ built $APP ($VERSION)"
echo "  run:  open $APP        (or copy to /Applications)"
echo "  note: real signing + notarization is a separate gated step (Developer ID)."
