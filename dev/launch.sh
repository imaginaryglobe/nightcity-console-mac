#!/bin/bash
# Developer launch path: install the runtime payload into the game and launch with injection.
# (Players use the CyberConsole.app launcher instead - this is the from-source dev workflow.)
#
# Steps: build overlay -> stage payload (runtime + deps + overlay) into <game>/red4ext/ -> launch.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GAME="${CP2077_DIR:-$HOME/Library/Application Support/Steam/steamapps/common/Cyberpunk 2077}"
BIN="$GAME/Cyberpunk2077.app/Contents/MacOS/Cyberpunk2077"
RED4="$GAME/red4ext"

[ -f "$BIN" ] || { echo "Game not found at: $GAME  (set CP2077_DIR to override)"; exit 1; }

echo "==> building overlay"
"$ROOT/overlay/build.sh"

echo "==> fetching deps"
"$ROOT/tools/fetch-deps.sh"

echo "==> staging payload into $RED4"
mkdir -p "$RED4"
cp "$ROOT/runtime/red4ext_hooks.js"   "$RED4/red4ext_hooks.js"
cp "$ROOT/runtime/FridaGadget.config" "$RED4/FridaGadget.config"
cp "$ROOT/deps/RED4ext.dylib"         "$RED4/RED4ext.dylib"
cp "$ROOT/deps/FridaGadget.dylib"     "$RED4/FridaGadget.dylib"
OVERLAY="$ROOT/build/libcyberconsole_overlay.dylib"
# strip quarantine from anything we just wrote so dyld will load it
xattr -dr com.apple.quarantine "$RED4" "$OVERLAY" 2>/dev/null || true

export DYLD_INSERT_LIBRARIES="$RED4/RED4ext.dylib:$RED4/FridaGadget.dylib:$OVERLAY"
export DYLD_FORCE_FLAT_NAMESPACE=1
export SteamAppId=1091500

cd "$GAME"
echo "==> launching (toggle the console in-game with \` or F1)"
exec "$BIN" "$@"
