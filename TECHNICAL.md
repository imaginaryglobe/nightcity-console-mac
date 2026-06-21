# NightCity Console: how it works and how it was built

This document explains the internals: how NightCity Console injects into Cyberpunk 2077 on macOS, how it
calls into the game's engine, how the in-game overlay is drawn, and how the whole thing was reverse
engineered. It is meant for contributors and for anyone curious about REDengine on Apple Silicon.

Everything here targets the macOS (Apple Silicon) Steam build of Cyberpunk 2077 v2.3.1. Offsets and
hashes are specific to that build.

## 1. The problem

Cyber Engine Tweaks (CET) is the standard cheat/scripting console for Cyberpunk 2077, but it is
Windows-only (it relies on D3D12 and Windows-specific hooking). The macOS build has no equivalent.
NightCity Console rebuilds the core of that capability from scratch on macOS: inject code into the running
game, resolve the engine's runtime type system (RTTI), call game functions with real arguments, and
draw a console on the live frame.

## 2. Injection

The shipped game binary has hardened runtime enabled but ships the entitlements
`com.apple.security.cs.allow-dyld-environment-variables` and `disable-library-validation`. That means
`DYLD_INSERT_LIBRARIES` works with System Integrity Protection left on, and any validly-signed dylib
(ad-hoc is fine) can be loaded into the process. No SIP changes, no patching the binary.

We inject three dylibs:

- `RED4ext.dylib` (macOS port): a REDengine hooking framework. It also loads the Frida gadget.
- `FridaGadget.dylib`: an in-process Frida runtime. Its config (`FridaGadget.config`) auto-loads our
  script `red4ext_hooks.js` on startup.
- `libcyberconsole_overlay.dylib`: our native Metal/ImGui overlay (see section 7).

Plus `DYLD_FORCE_FLAT_NAMESPACE=1` and `SteamAppId=1091500` so the Steam API initializes.

The command engine lives entirely in `red4ext_hooks.js` (a Frida script). The overlay is a separate
native dylib. They are decoupled and talk through two files in `/tmp` (section 6).

## 3. Finding offsets (the reverse engineering)

The macOS build ships a rich symbol table: `nm` yields about 68,000 symbols with addresses. Runtime
address = `symbol_vaddr - 0x100000000 + module_base`, where the module base comes from the loaded image
of `Cyberpunk2077`. The shipped `cyberpunk2077_addresses.json` is stale/wrong for 2.3.1, so every offset
was re-derived from the binary's own symbols plus disassembly in Ghidra and radare2.

Key results (file vaddrs; runtime = base + (vaddr - 0x100000000)):

- Universal script executor `FUN_102173120`, signature `(func, context, frame, result, resultType)`.
  Every scripted call goes through it.
- RTTI registry getter `CRTTISystem::Get` at `0x102188e8c`; the registry vtable exposes `GetClass` at
  vtbl+0x10, `GetFunction` at vtbl+0x30, `GetEnum` at vtbl+0x18.
- The opcode handler table (used by the script VM) is populated at runtime at `module_base + 0x908b798`.
- `Main` is at `module_base + 0x31e18` (used for the clean-shutdown hook, section 8).

CNames are FNV1a64 of the type/function name. TweakDBIDs are `CRC32(name) | (len << 32)`.

## 4. Calling a game function

REDengine's native script handlers take their arguments from bytecode in a `CScriptStackFrame`. To call
a function we build that frame by hand:

1. Resolve the function. `clsByName(name)` calls the registry's `GetClass`. We then scan the class's
   instance-function array (CClass+0x48) and static-function array (CClass+0x58), walking up parent
   classes, matching the short-name CName at function+0x10. This gives a `CClassFunction*`, its return
   type, and whether it is static.
2. Marshal each argument by the function's declared parameter type. For each arg we allocate a synthetic
   `CProperty` (type at +0x00, valueOffset at +0x20), write the encoded value into a locals buffer at
   that offset, and emit a `LocalVar` opcode (0x18) referencing the property, ending with `ParamEnd`
   (0x26). Supported types include Int32/Uint32/Int64/Float/Bool, CName (FNV1a64), TweakDBID, gameItemID,
   enums (resolved by member name against the enum's value list, or by a literal integer), object handles
   (`@player`/`@self`/`@<ptr>` written as `{instance, refCount}`), and raw struct passthrough.
3. Invoke `FUN_102173120(func, context, frame, &result, returnType)` and read the result.

Important detail: you must supply exactly the number of parameters the function declares (or stop at a
genuinely optional trailing param). Under-supplying makes the handler read `ParamEnd` as a value opcode
and crash. NightCity Console logs each function's live signature so commands are built against the real shape.

Items use `ItemID.FromTDBID(TweakDBID)` to build a proper `gameItemID` (correct rngSeed and structure);
hand-built IDs validate but never commit, so `FromTDBID` is mandatory.

## 5. Getting live engine systems

Two different mechanisms, both reached from the live `GameInstance` (obtained via
`PlayerPuppet.GetGame()`):

- Scriptable systems (e.g. `PlayerDevelopmentSystem`): `GameInstance.GetScriptableSystemsContainer(gi)`
  (a static method on `ScriptGameInstance`) returns a container, then `container.Get(CName)` returns the
  system instance.
- Other engine systems and facilities (godmode, teleportation, player system) are not in that container.
  They come from static getters on `GameInstance`, e.g. `GetGodModeSystem(gi)`,
  `GetTeleportationFacility(gi)`, `GetPlayerSystem(gi)`. The helper `getViaGetter(gi, "GetXxx")` resolves
  the static getter and calls it with the 8-byte GameInstance pointer.

The player handle matters. The Frida hook captures any object whose vtable matches `PlayerPuppet`, but
some of those are transient/preview puppets. Resolving the player deterministically via
`PlayerSystem.GetLocalPlayerControlledGameObject()` (class `cpPlayerSystem`) fixed intermittent failures
in commands that depend on the correct owner (item give, heal, and so on).

## 6. The command engine and channel

`red4ext_hooks.js` polls `/tmp/cp2077_cmd.txt` about twice a second. A command is queued and then executed
on the game thread at a clean point (when the script executor's call depth returns to zero, so we are not
nested inside another scripted call). Output is appended to `/tmp/cp2077_out.txt`. This file channel is
the only coupling between the command engine and the overlay, which keeps the two completely independent.

Commands are simple verbs (`give`, `money`, `perks`, `level`, `heal`, `teleport`, `setfact`, `call`,
etc.). A small translator also recognizes the most common CET copy-paste line, `Game.AddToInventory(
"Items.X", n)`, and routes it through the same path, so internet item codes work unchanged.

## 7. The in-game overlay (Metal + ImGui)

The Frida gadget here has no ObjC bridge and no `Module.findExportByName`, so the overlay is a separate
native dylib that uses the Objective-C runtime directly via method swizzling.

Render path:

- At load (deferred a few seconds so Metal is ready) we find the concrete command-buffer class at runtime
  (`object_getClass` on a command buffer from a throwaway queue; on Apple GPUs this is an
  `AGXG<n>FamilyCommandBuffer`) and swizzle `presentDrawable:`.
- In the hook, before calling the original, we build a render pass on the drawable's texture with
  `loadAction = Load` (preserving the game's frame) and draw Dear ImGui into the same command buffer, so
  it composites on top, then let the present proceed. The layer reports `framebufferOnly = 0`, so the
  drawable texture is freely usable and no layer recreation is needed. Pixel format is RGBA8Unorm.

Input path (the tricky part):

- Events arrive on the main thread; ImGui runs on the render thread; ImGui is not thread safe. So we
  swizzle `-[NSApplication sendEvent:]`, extract the keyboard/mouse data into a mutex-guarded queue, and
  drain that queue on the render thread just before `ImGui::NewFrame`. All ImGui calls stay on one thread.
- The backtick/tilde key (and F1) toggles the console. While open, input is swallowed so the game does
  not also react. Clipboard is wired to `NSPasteboard` with `ConfigMacOSXBehaviors`, so Cmd+V/C/X/A work.

## 8. The launcher app, Steam Cloud, and clean shutdown

The launcher (`launcher/`) is a small SwiftUI app. Install copies the payload into `<game>/red4ext/` and
strips the `com.apple.quarantine` attribute from the files it writes. This is the key trick for macOS:
files written by a locally-running app are not quarantined, so dyld will load them. Play sets the
injection environment and launches the game binary directly.

Two macOS-specific findings shaped this:

- Steam launch options do not work for injection on macOS. Steam launches Mac games through
  LaunchServices (`open`), not by exec, so the Linux-style `"wrapper.sh" %command%` trick fails. Direct
  launch is the working path.
- The game crashes on exit when hooks are attached: a SIGSEGV in the engine's own teardown calling a stale
  hook/trampoline, which happens after the save is flushed but before libc `exit()`. Replacing `exit()`
  with `_exit()` is too late. The fix is to hook `Main`'s return (the game is quitting, the save is done)
  and call `_exit(0)` immediately, so the crashing teardown never runs. This also fixed Steam Cloud:
  launching directly still registers the session with the Steam client, but the crash-on-exit was
  aborting Steam's post-session cloud upload; a clean exit lets it complete.

## 9. Build and packaging

- `overlay/build.sh` clones Dear ImGui (pinned) and compiles `libcyberconsole_overlay.dylib`.
- `tools/fetch-deps.sh` puts `RED4ext.dylib` and `FridaGadget.dylib` into `deps/` (copied from a local
  game install if present). These large binaries are never committed.
- `launcher/build-app.sh` compiles the SwiftUI app with `swiftc`, assembles the `.app` bundle, copies the
  payload into `Contents/Resources`, and ad-hoc signs it for local testing.
- `tools/sign-notarize.sh` re-signs everything inside-out with a Developer ID and hardened runtime,
  notarizes the app and the dmg with `notarytool`, staples the tickets, and produces `dist/NightCity-Console-for-Mac.dmg`
  that passes Gatekeeper with no warnings. You run this with your own Apple Developer ID.

## 10. Known limits and where to contribute

- godmode registers with the engine's godmode system (HasGodMode returns true), but on 2.3.1 the damage
  pipeline still applies hit damage. It prevents death, not damage. A true zero-damage mode would need a
  per-tick health stat-pool refill.
- Teleport is blocked by the game during active combat. Bookmarks are session-only.
- Not yet implemented: real vehicle summon (needs the garage vehicle id, not just `ToggleSummonMode`),
  equip-to-slot (needs `EquipmentSystemPlayerData`), and NPC/vehicle spawning.
- Offsets are tied to game v2.3.1. A game update will likely require re-deriving them.

The signatures needed for the unfinished features were already captured by the `convdump` diagnostic and
are documented in the command engine, so they are a reasonable starting point for contributions.
