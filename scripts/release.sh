#!/usr/bin/env bash
set -euo pipefail

# Local signed + notarized release build for AIWorkstation.
# Runs on YOUR Mac (which has Xcode 26 + your Developer ID cert), which is the reliable
# path — GitHub's hosted runners may not have the Xcode 26 / macOS 26 SDK that
# FoundationModels needs. See RELEASE.md for one-time setup.
#
# One-time prereqs:
#   1. "Developer ID Application" cert in your login keychain
#      (Xcode → Settings → Accounts → Manage Certificates → + Developer ID Application).
#   2. A notarytool credential profile in the keychain (so no keys live in this script):
#        xcrun notarytool store-credentials AIWorkstation \
#          --key /path/AuthKey_XXXX.p8 --key-id <KEY_ID> --issuer <ISSUER_ID>
#      (App Store Connect → Users and Access → Integrations → App Store Connect API → + key)
#   3. (optional, nicer DMG)  brew install create-dmg
#
# Usage:  ./scripts/release.sh [version]     e.g.  ./scripts/release.sh 0.1.0

cd "$(dirname "$0")/.."

VERSION="${1:-$(date +%Y.%m.%d)}"
APP_NAME="AIWorkstation"
PROFILE="${NOTARY_PROFILE:-AIWorkstation}"
NOTARIZE="${NOTARIZE:-1}"   # set NOTARIZE=0 to smoke-test: sign + DMG, skip notarization
WORK="$(mktemp -d)"
ARCHIVE="$WORK/$APP_NAME.xcarchive"
EXPORT_DIR="$WORK/export"
OUT_DIR="$PWD/build"
DMG="$OUT_DIR/$APP_NAME-$VERSION.dmg"
mkdir -p "$OUT_DIR"
trap 'rm -rf "$WORK"' EXIT

# Resolve the Developer ID Application identity (and team) from the keychain.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/' || true)
[ -n "$IDENTITY" ] || { echo "❌ No 'Developer ID Application' identity in your keychain."; echo "   Create one: Xcode → Settings → Accounts → Manage Certificates → + Developer ID Application."; exit 1; }
TEAM_ID=$(echo "$IDENTITY" | sed -E 's/.*\(([A-Z0-9]+)\)\s*$/\1/')
echo "▸ Signing as: $IDENTITY  (team $TEAM_ID)  ·  version $VERSION"

# AIWorkstation needs the macOS 26 SDK (FoundationModels). Surface the toolchain so a
# stale `xcode-select` is obvious. Override with: DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer ./scripts/release.sh
echo "▸ Toolchain: $(xcodebuild -version | tr '\n' ' ')  (DEVELOPER_DIR=${DEVELOPER_DIR:-$(xcode-select -p)})"

# Pre-flight the notary credentials before the (slow) archive, so a missing/invalid profile
# fails in seconds, not minutes. `notarytool history` round-trips to App Store Connect and
# proves the stored key actually authenticates.
if [ "$NOTARIZE" != "0" ]; then
  echo "▸ Checking notary profile '$PROFILE'…"
  if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    echo "❌ Notary profile '$PROFILE' isn't set up (or App Store Connect is unreachable)."
    echo "   Set it up once with your App Store Connect API key:"
    echo "     xcrun notarytool store-credentials $PROFILE --key AuthKey_XXXX.p8 --key-id <KEY_ID> --issuer <ISSUER_ID>"
    echo "   …or smoke-test the build now without notarizing:"
    echo "     NOTARIZE=0 ./scripts/release.sh $VERSION"
    exit 1
  fi
fi

echo "▸ Archiving (Release, hardened runtime, timestamped)…"
xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration Release \
  -archivePath "$ARCHIVE" archive \
  ENABLE_HARDENED_RUNTIME=YES \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$IDENTITY" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  MARKETING_VERSION="$VERSION" \
  OTHER_CODE_SIGN_FLAGS="--timestamp --options runtime" \
  | grep -E "error:|warning: .*deprecat|ARCHIVE SUCCEEDED" || true

echo "▸ Exporting (Developer ID)…"
cat > "$WORK/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>manual</string>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT_DIR" -exportOptionsPlist "$WORK/ExportOptions.plist" >/dev/null
APP="$EXPORT_DIR/$APP_NAME.app"
[ -d "$APP" ] || { echo "❌ Export produced no .app at $APP"; exit 1; }

echo "▸ Building DMG…"
rm -f "$DMG"
# Stage the app next to an /Applications symlink so the mounted DMG offers drag-to-install
# even on the plain hdiutil path (when create-dmg isn't installed). create-dmg adds its own
# drop-link via --app-drop-link, so it takes the app directly.
DMG_STAGE="$WORK/dmgroot"; rm -rf "$DMG_STAGE"; mkdir -p "$DMG_STAGE"
cp -R "$APP" "$DMG_STAGE/"
ln -s /Applications "$DMG_STAGE/Applications"
if command -v create-dmg >/dev/null 2>&1; then
  create-dmg --volname "$APP_NAME" --window-size 660 380 \
    --icon "$APP_NAME.app" 165 185 --app-drop-link 495 185 \
    "$DMG" "$APP" \
  || hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_STAGE" -ov -format UDZO "$DMG"
else
  hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_STAGE" -ov -format UDZO "$DMG"
fi

# Sign the DMG container too (not just the app), so Gatekeeper has a usable signature on
# the dmg itself — otherwise `spctl -a -t open` reports "no usable signature" even though
# the app inside is notarized. Apple's recommended belt-and-suspenders for distribution.
echo "▸ Signing the DMG…"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

if [ "$NOTARIZE" = "0" ]; then
  echo
  echo "⚠️  Skipped notarization (NOTARIZE=0). This DMG is SIGNED but NOT notarized —"
  echo "    Gatekeeper will warn on other Macs (right-click → Open bypasses it). Smoke-test"
  echo "    only; do a full run before publishing."
  echo "✅ Signed DMG: $DMG"
  echo "   sha256:  $(shasum -a 256 "$DMG" | awk '{print $1}')"
  exit 0
fi

echo "▸ Notarizing (keychain profile: $PROFILE) — this can take a few minutes…"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo
echo "✅ Notarized DMG ready:  $DMG"
echo "   sha256:  $(shasum -a 256 "$DMG" | awk '{print $1}')"
echo
echo "   Publish it:"
echo "     gh release create v$VERSION \"$DMG\" --generate-notes"
echo "   Then bump Casks/aiworkstation.rb (version + sha256) in your homebrew tap."
