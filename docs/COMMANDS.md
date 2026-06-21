# NightCity Console - command reference

Toggle the in-game console with **`` ` ``** (backtick/tilde) or **F1**. Type a command and press **Enter**.
Use **↑/↓** for history and **Cmd+V/C/X/A** for clipboard. Type `help` in-game for a quick list.

> Single-player only. Back up your saves before experimenting.

## Items & money
| Command | Effect |
|---|---|
| `give <Items.Name> <qty>` | Add an item. qty ≤ 20 -> distinct instances (weapons); > 20 -> one bulk stack. |
| `removeitem <Items.Name> <qty>` | Remove an item. |
| `money <amount>` | Add eddies. |
| `Game.AddToInventory("Items.Name", n)` | **CET copy-paste** - works verbatim from any CET guide. |

Item IDs are the same `Items.*` TweakDB names CET uses, so codes you find online work here.

## Character
| Command | Effect |
|---|---|
| `perks <N>` | Add N perk points. |
| `attrs <N>` | Add N attribute points. |
| `relic <N>` | Add N relic points. |
| `level <N>` | Set character level. |
| `heal` | Refill health to full. |
| `godmode [off]` | Not working yet (see note). |

## World
| Command | Effect |
|---|---|
| `teleport` | Print your current coords + saved bookmarks. |
| `teleport save <name>` | Bookmark your current position (resets each launch). |
| `teleport <name>` | Teleport to a saved bookmark. |
| `teleport <x> <y> <z>` | Teleport to absolute coords. |
| `setfact <name> <value>` | Set a quest fact flag. |

## Power tools
| Command | Effect |
|---|---|
| `call <Class> <method> [args]` | Invoke any **observed** RTTI method (args auto-marshalled). |
| `sig <Class> <method>` | Print a method's signature. |
| `convdump` / `devdump` | Diagnostics - dump method signatures. |
| `clear` / `help` | Clear scrollback / list commands. |

## Notes & known limits
- **godmode**: not working yet, disabled in the UI. It registers with the game's god-mode system, but on
  build 2.3.1 the entity id we can resolve isn't honored by the combat/damage pipeline (you still take
  damage and can die). Being worked on; tracked for a future update.
- **teleport** is blocked by the game during active combat; bookmarks are session-only.
- **Quest-gated items** (e.g. `Items.mq007_skippy`) won't commit without the relevant quest active.
- **Deferred / contributions welcome**: real vehicle summon, equip-to-slot, NPC/vehicle spawn.
