#!/bin/bash
# Build CyberConsole.app (ad-hoc signed, for dev/testing).
# Bundles the runtime payload into Contents/Resources so the app can install it into the game.
# Release signing + notarization + .dmg is a separate step: tools/sign-notarize.sh
set -e
cd "$(dirname "$0")/.."   # repo root
APP="build/CyberConsole.app"

echo "==> overlay + deps"
./overlay/build.sh
./tools/fetch-deps.sh

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp launcher/Info.plist "$APP/Contents/Info.plist"

echo "==> compiling launcher"
swiftc -O -parse-as-library -target arm64-apple-macos12 \
  -o "$APP/Contents/MacOS/CyberConsole" \
  launcher/Sources/*.swift

echo "==> bundling payload into Resources"
cp runtime/red4ext_hooks.js runtime/FridaGadget.config "$APP/Contents/Resources/"
cp deps/RED4ext.dylib deps/FridaGadget.dylib            "$APP/Contents/Resources/"
cp build/libcyberconsole_overlay.dylib                  "$APP/Contents/Resources/"

echo "==> ad-hoc signing"
codesign -s - --deep --force "$APP" >/dev/null
echo "built $APP"
echo "Run it:  open \"$APP\"   (first launch may need right-click -> Open until notarized)"
