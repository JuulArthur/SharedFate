# Level flow: moving between levels

Status: written 2026-09-29 on branch `feat/level-flow`. How a 3D level hands the Bound Three over to the next one. The first real use is planned in `docs/level-1-design.md`; today a placeholder proves it.

## What happens

1. The player walks into a **level exit** (`LevelExit3D`) outside a fight.
2. The exit calls `travel_to(target_scene, target_entry)` on the coordinator (`main_3d.gd`, group `level_coordinator`).
3. The coordinator stores the body's state in **`RunState3D`**, fades the screen to black (0.45 s) and changes the scene.
4. The next level's coordinator takes the state and the entry id in `_ready`. It places the player at the node **`Entry_<target_entry>`**, puts the state back, fades in and announces `level_display_name`.

In a fight `travel_to` refuses ("Not during a fight"). A missing scene refuses too ("The way is shut", with an error in the log).

## What is carried

`Player3D.get_run_state()` / `apply_run_state()`:

| Carried | Where it lives |
| --- | --- |
| level and XP, health (not above the maximum) | the player |
| the soul in control | the player (a shift on arrival) |
| every item and what is worn | the player's `Inventory` (items are Resources, so the same objects travel) |
| buffs | the player |
| attribute points and attributes, mana and stamina, skill cards, forged skills | `Progression3D.to_state()` / `from_state()` |

Not carried: cooldowns (they melt in exploration anyway), trap fields and spirits, the respawn point (each level starts at its entry), anything in the old level's world.

On a fresh start (no entry) a level behaves as before: `Spawn_default`, the story chapter, the debug loot and the starter cards. On arrival from another level the intro book, the debug loot and the starter cards are skipped.

## Building a level for the flow

On top of the level node contract (`docs/3d-port-contracts.md`, section 9):

| Node | Purpose |
| --- | --- |
| `Entry_<id>` (Node3D, anywhere) | where a body arriving with entry `<id>` stands. Keep it 3 m or more from any exit so an arrival never stands in one |
| `LevelExit3D` (`scripts/3d/world/level_exit_3d.gd`) | exports `target_scene` (a .tscn path), `target_entry`, `label` (the sign over the arch) and `radius_m` (1.2 m) |
| root export `level_display_name` | announced on arrival, for example "The Hollow Road" |

An exit has no colliders, so it does not change the navmesh bake. It ignores the player for 1 s after the level starts.

## Levels today

| Level | Scene | Entries | Exits |
| --- | --- | --- | --- |
| The Wilds (main scene) | `scenes/3d/wilds.tscn`, built by `tools/build_wilds_3d.gd` | `Entry_from_road` (-33.5, 38.5) | "To the Hollow Road" at (-31, 41.5), south side of the start glade |
| The Hollow Road (placeholder) | `scenes/3d/levels/hollow_road.tscn`, built by `tools/build_hollow_road_placeholder.gd` from the test arena | `Entry_from_wilds` (-9, 0) | "To the Wilds" at (-10.5, 2.6) |

Rebuild the placeholder after changing the arena:

```powershell
& $godot --headless --path . --script res://tools/build_hollow_road_placeholder.gd   # prints BUILD OK
```

## Test

`scenes/3d/tests/level_flow_test.tscn` (prints `LEVEL FLOW OK`):

1. It starts in the Hollow Road.
2. It changes the body: a level up, a mage Power point, a forged Fireball, spent mana, a wound, the rogue in control, worn gear.
3. It walks into the exit and checks that all of it arrived in the Wilds at `Entry_from_road`.
4. It walks back through the Wilds' exit to `Entry_from_wilds`.
5. It checks that travel is refused in a fight.

```powershell
& $godot --headless --path . res://scenes/3d/tests/level_flow_test.tscn --quit-after 3000
```

## Later

`RunState3D` lasts one session. A save game writes and reads the same dictionary (`get_run_state`), plus the current level path and entry.
