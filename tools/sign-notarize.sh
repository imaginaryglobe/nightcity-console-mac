#!/bin/bash
# Sign (Developer ID + hardened runtime), notarize, and package CyberConsole.app into a distributable .dmg.
# YOU run this with YOUR Apple Developer ID - it never asks the assistant for credentials.
#
# One-time setup (stores your notary credentials in the keychain):
#   xcrun notarytool store-credentials cyberconsole-notary \
#     --apple-id "you@example.com" --team-id "TEAMID" --password "app-specific-password"
#
# Then run:
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#   NOTARY_PROFILE="cyberconsole-notary" \
#   ./tools/sign-notarize.sh
set -e
cd "$(dirname "$0")/.."
APP="build/CyberConsole.app"
DMG="dist/CyberConsole.dmg"
ZIP="dist/CyberConsole.zip"

: "${SIGN_IDENTITY:?set SIGN_IDENTITY to 'Developer ID Application: NAME (TEAMID)'}"
: "${NOTARY_PROFILE:?set NOTARY_PROFILE to your notarytool keychain profile name}"

echo "==> building app (ad-hoc), then re-signing with Developer ID"
./launcher/build-app.sh

# Sign every Mach-O inside-out with hardened runtime + secure timestamp (required for notarization).
find "$APP/Contents/Resources" -name "*.dylib" -print0 | while IFS= read -r -d '' f; do
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$f"
done
codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> notarizing the app"
mkdir -p dist
rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"          # staple the ticket onto the app
rm -f "$ZIP"

echo "==> packaging stapled app into $DMG"
rm -f "$DMG"
hdiutil create -volname "CyberConsole" -srcfolder "$APP" -ov -format UDZO "$DMG"
# notarize + staple the dmg too (so the downloaded .dmg itself passes Gatekeeper offline)
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"

echo "done: $DMG  (signed, notarized, stapled - ships with no Gatekeeper warnings)"
