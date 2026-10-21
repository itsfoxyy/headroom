#!/bin/bash
# Builds Headroom.app.
#
#   ./build.sh               build, install in /Applications and start it
#   ./build.sh --no-install  just build into ./build
#   ./build.sh --release     build a signed zip for publishing into ./dist
#
# Optional environment:
#   VERSION=1.2.0                         version number (default below)
#   SIGN_IDENTITY="Developer ID Application: …"   certificate to sign with
#   BUNDLE_ID=…                           app identifier
#   Notarizing (Developer ID only), either:
#     NOTARY_PROFILE=name                 a profile saved with `xcrun notarytool store-credentials`
#   or APPLE_ID, APPLE_TEAM_ID, APPLE_APP_PASSWORD
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Headroom"
EXECUTABLE="Headroom"
BUNDLE_ID="${BUNDLE_ID:-io.github.itsfoxyy.headroom}"
VERSION="${VERSION:-1.0.0}"
MODE="${1:-install}"

if ! command -v swift >/dev/null 2>&1; then
  echo "Swift isn't installed. Install Apple's command line tools first:"
  echo "  xcode-select --install"
  exit 1
fi

echo "→ Compiling Headroom ${VERSION}…"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

APP="build/$APP_NAME.app"
echo "→ Packaging $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$EXECUTABLE" "$APP/Contents/MacOS/$EXECUTABLE"

echo "→ Drawing the app icon"
rm -rf build/AppIcon.iconset
swift Scripts/make_icon.swift build/AppIcon.iconset >/dev/null
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$EXECUTABLE</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT License · github.com/itsfoxyy/headroom</string>
</dict>
</plist>
PLIST

# ── Signing ─────────────────────────────────────────────────────────────
# Developer ID: works on any Mac (with notarization, no warnings at all).
# Apple Development: works on your own Macs.
# Neither: a local ("ad-hoc") signature; others must approve it once.
IDENTITY="${SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
  if [[ "$MODE" == "--release" ]]; then
    IDENTITY="$(echo "$IDENTITIES" | grep -E '"Developer ID Application' | head -1 | sed -E 's/.*"(.*)"/\1/' || true)"
  else
    IDENTITY="$(echo "$IDENTITIES" | grep -E '"(Developer ID Application|Apple Development|Mac Developer)' | head -1 | sed -E 's/.*"(.*)"/\1/' || true)"
  fi
fi

if [[ "$IDENTITY" == Developer\ ID* ]]; then
  echo "→ Signing as: $IDENTITY (hardened runtime)"
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
elif [[ -n "$IDENTITY" ]]; then
  echo "→ Signing as: $IDENTITY"
  codesign --force --timestamp=none --sign "$IDENTITY" "$APP"
else
  echo "⚠︎ No signing certificate found, so signing locally (ad-hoc)."
  codesign --force --sign - "$APP" >/dev/null
fi

if [[ "$MODE" == "--no-install" ]]; then
  echo "✓ Built $APP"
  exit 0
fi

# ── Release zip ─────────────────────────────────────────────────────────
if [[ "$MODE" == "--release" ]]; then
  mkdir -p dist
  ZIP="dist/$APP_NAME-$VERSION.zip"
  rm -f "$ZIP"

  if [[ "$IDENTITY" == Developer\ ID* ]] && { [[ -n "${NOTARY_PROFILE:-}" ]] || [[ -n "${APPLE_ID:-}" ]]; }; then
    echo "→ Sending to Apple for notarization (usually a few minutes)…"
    ditto -c -k --keepParent "$APP" build/notarize.zip
    if [[ -n "${NOTARY_PROFILE:-}" ]]; then
      xcrun notarytool submit build/notarize.zip --keychain-profile "$NOTARY_PROFILE" --wait
    else
      xcrun notarytool submit build/notarize.zip --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" \
        --password "$APPLE_APP_PASSWORD" --wait
    fi
    xcrun stapler staple "$APP"
    rm -f build/notarize.zip
  else
    echo "⚠︎ Not notarized: people downloading it will need to approve it once in"
    echo "  System Settings › Privacy & Security › Open Anyway."
  fi

  ditto -c -k --keepParent "$APP" "$ZIP"
  shasum -a 256 "$ZIP" | tee "$ZIP.sha256"
  echo "✓ Release ready: $ZIP"
  exit 0
fi

# ── Install ─────────────────────────────────────────────────────────────
# /Applications is where Raycast, Spotlight and menu bar managers look;
# fall back to ~/Applications if it isn't writable.
DEST="/Applications"
if [[ ! -w "$DEST" ]]; then
  DEST="$HOME/Applications"
  mkdir -p "$DEST"
fi
# Quit the running copy, including the old "Claude Usage" app this replaces.
pkill -x "$EXECUTABLE" 2>/dev/null || true
pkill -x "ClaudeUsageBar" 2>/dev/null || true
sleep 0.5
# Remove older installs so only one copy exists.
rm -rf "$DEST/$APP_NAME.app" "$HOME/Applications/$APP_NAME.app" "$HOME/Applications/Claude Usage.app"
cp -R "$APP" "$DEST/"
# Remove the build copy so Spotlight and Launchpad only list the installed app.
rm -rf "$APP"
open "$DEST/$APP_NAME.app"
echo "✓ Installed to $DEST/$APP_NAME.app and started it. Look for the rings in your menu bar."
