# The 3D arena: how to run it

The playable 3D slice is `scenes/3d/arena.tscn`: one clearing ringed by trees, the knight with the three souls, three wolves, a crate and a chest, on the coordinator `scripts/3d/main_3d.gd`. The 2D game is untouched and stays the main scene.

## Open and run

1. Install Godot 4.7.2 (the version `project.godot` declares; an older editor rewrites scene files). On this PC it is the winget build under `%LOCALAPPDATA%\Microsoft\WinGet\Packages\GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe\`.
2. Open the repository's `project.godot` in the editor and let the first import finish.
3. Open `scenes/3d/arena.tscn` and press F6 (Run Current Scene). F5 still runs the 2D hub, `scenes/main.tscn`.

Headless check of the whole slice (prints `INTEGRATION OK`):

```powershell
$godot = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe\Godot_v4.7.2-stable_win64_console.exe"
& $godot --headless --path . res://scenes/3d/arena.tscn --quit-after 1200
```

The `IntegrationSmoke` node in the arena drives that check. It only runs headless, or with the user argument `-- --integration-smoke`, so F6 plays normally.

## Controls

| Input | Exploration | Turn combat |
| --- | --- | --- |
| Left click on the ground | walk there | spend movement (path preview shows the 6 m budget) |
| Left click on a wolf | walk up and attack | melee, or the aimed throw / spell |
| Left click on a dropped item | open the loot panel (walks over if far) | same |
| Space | sword sweep | end the turn |
| 1 / 2 / 3, Q | shift to knight / rogue / mage, cycle | one shift per turn (two after a perfect reaction) |
| F | - | counter during the wolf's strike: block, parry or ward, by soul |
| I | inventory screen | same |
| Esc | close a panel, skip the story book | same |

Combat starts by proximity (6 cells). The HUD buttons Melee, Throw, Block, Arcane Burst, Frost Snare, Wait and End Turn do what they say; Block and Wait hand the turn over. Hovering a wolf or an item highlights it. The Sound button (top right) unmutes the music.

## What is placeholder

- The generic enemy (`scenes/3d/enemy_3d.tscn`) is still a red box; only the wolf has a model. The knight is the body for all three souls (the light changes colour on a shift; the rogue and mage models exist under `assets/3d/models/` but are not wired).
- No skeletal animation: attacks are the procedural lunge, squash and tint of the 2D game on `Model`, plus the weapon-holder animation.
- No link from the 2D hub. The arena runs standalone; `LevelLoader.change_level("res://scenes/3d/arena.tscn")` works but nothing calls it, and `story_chapter_id` on the arena root is empty so no chapter opens at start.
- Test loot drops beside the player at start (`spawn_test_loot` on the arena root); untick it in the inspector for a clean run.
- Turn-order portraits are coloured squares; dropped items are the 2D icons as billboards.

## Regenerating

Models (Blender 4.3, no add-on needed; writes `assets/3d/models/*.glb`, Godot re-imports on the next open):

```powershell
blender --background --factory-startup --python tools/blender/generate_characters.py -- --root .
blender --background --factory-startup --python tools/blender/generate_wolf.py -- --root .
blender --background --factory-startup --python tools/blender/generate_props.py -- --root .
```

Keep the node names the scenes rely on: the knight's `Sword`, `HandPoint` and `OverheadAnchor` (`scripts/3d/knight_visual_3d.gd` hands the sword to the weapon holder) and the wolf's `Wolf_Body`. `scenes/3d/tests/asset_gallery.tscn` prints every model's tree and size.

Navmesh, after moving or adding props in `arena.tscn` (writes `scenes/3d/arena_navmesh.tres`, which is committed):

```powershell
& $godot --headless --path . --script res://tools/bake_arena_navmesh.gd
```
