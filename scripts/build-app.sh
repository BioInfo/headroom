#!/usr/bin/env bash
# Build Headroom.app — a menu-bar agent bundle around the SwiftPM executable, with an
# AppIcon.icns rendered from the ChefHat and Sparkle embedded for auto-update.
#
# Signing is automatic: if a "Developer ID Application" identity is in the keychain, the app is
# Developer-ID signed with the hardened runtime (inside-out through Sparkle's framework + XPC
# helpers); otherwise it falls back to an ad-hoc signature (runs locally, no Gatekeeper-clean
# download). Set NOTARIZE=1 to also notarize + staple a signed build (needs the
# `headroom-notary` keychain profile). See docs/APPLE-DEVELOPER-SETUP.md.
set -uo pipefail
cd "$(dirname "$0")/.."

APP="Headroom.app"
BUNDLE_ID="io.rundatarun.headroom"
VERSION="${HEADROOM_VERSION:-1.4.0}"
EXE="HeadroomApp"
CONFIG="${1:-release}"

# --- Sparkle auto-update config (overridable via env) ---
SU_FEED_URL="${SU_FEED_URL:-https://raw.githubusercontent.com/BioInfo/headroom/main/appcast.xml}"
SU_PUBLIC_ED_KEY="${SU_PUBLIC_ED_KEY:-wUsHz7ZiByzy6pAw8bPjcSRkG8kwsEIygjYCelTTa6k=}"

# --- signing identity (auto-detected) ---
ENTITLEMENTS="Headroom.entitlements"
NOTARY_PROFILE="${NOTARY_PROFILE:-headroom-notary}"
SIGN_ID="${SIGN_ID:-$(security find-identity -v -p codesigning 2>/dev/null \
  | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)".*/\1/')}"

echo "▶ swift build -c $CONFIG"
swift build -c "$CONFIG" || { echo "build failed"; exit 1; }
BIN=".build/$CONFIG/$EXE"
[ -x "$BIN" ] || { echo "missing $BIN"; exit 1; }

echo "▶ assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/Headroom"

# --- embed Sparkle.framework (the binary links @rpath/Sparkle.framework) ---
echo "▶ embedding Sparkle.framework"
SPARKLE_SRC=".build/$CONFIG/Sparkle.framework"
[ -d "$SPARKLE_SRC" ] || { echo "missing $SPARKLE_SRC (run swift build)"; exit 1; }
ditto "$SPARKLE_SRC" "$APP/Contents/Frameworks/Sparkle.framework"
# the binary's only useful rpath is @loader_path; add the standard Frameworks search path
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Headroom" 2>/dev/null \
  && echo "  +rpath @executable_path/../Frameworks" || echo "  rpath already present"

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
  <key>SUFeedURL</key><string>$SU_FEED_URL</string>
  <key>SUPublicEDKey</key><string>$SU_PUBLIC_ED_KEY</string>
  <key>SUEnableAutomaticChecks</key><true/>
</dict>
</plist>
PLIST

# --- codesign ---
SP="$APP/Contents/Frameworks/Sparkle.framework"
if [ -n "$SIGN_ID" ]; then
  echo "▶ Developer ID codesign — $SIGN_ID"
  # Inside-out: Sparkle's nested helpers + framework first, then the app. Hardened runtime
  # everywhere; the app also carries our (empty, non-sandboxed) entitlements.
  for ITEM in \
    "$SP/Versions/B/XPCServices/Installer.xpc" \
    "$SP/Versions/B/XPCServices/Downloader.xpc" \
    "$SP/Versions/B/Updater.app" \
    "$SP/Versions/B/Autoupdate" \
    "$SP"; do
    codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$ITEM" \
      || { echo "  ✗ sign failed: $ITEM"; exit 1; }
  done
  codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" --sign "$SIGN_ID" "$APP" \
    || { echo "  ✗ sign failed: $APP"; exit 1; }
  codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | tail -2
  echo "  signed (Developer ID, hardened runtime)"
  SIGNED=1
else
  echo "▶ ad-hoc codesign (no Developer ID identity found)"
  codesign --force --deep --sign - "$APP" 2>/dev/null && echo "  signed (ad-hoc)" || echo "  ⚠ ad-hoc sign failed (still runnable)"
  SIGNED=0
fi

# --- notarize + staple (opt-in, signed builds only) ---
if [ "${NOTARIZE:-0}" = "1" ] && [ "$SIGNED" = "1" ]; then
  echo "▶ notarizing (profile: $NOTARY_PROFILE)"
  ZIP="${APP%.app}-${VERSION}.zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  if xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1 | tee /tmp/headroom-notary.log | tail -8; then
    if grep -q "status: Accepted" /tmp/headroom-notary.log; then
      xcrun stapler staple "$APP" && echo "  stapled"
      spctl -a -vvv --type exec "$APP" 2>&1 | tail -3
      # re-zip the stapled app so the distributed artifact carries the ticket offline
      rm -f "$ZIP"; ditto -c -k --keepParent "$APP" "$ZIP"
      echo "  ✓ notarized + stapled → $ZIP"
    else
      echo "  ✗ notarization not Accepted — see /tmp/headroom-notary.log"; exit 1
    fi
  else
    echo "  ✗ notarytool submit failed"; exit 1
  fi
elif [ "${NOTARIZE:-0}" = "1" ]; then
  echo "  ⚠ NOTARIZE=1 ignored — build is ad-hoc signed (no Developer ID)"
fi

echo "✓ built $APP ($VERSION)"
echo "  run:  open $APP        (or copy to /Applications)"
[ "$SIGNED" = "1" ] || echo "  note: ad-hoc build — for a Gatekeeper-clean download, sign with a Developer ID + NOTARIZE=1."
