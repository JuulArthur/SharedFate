# WP8 "Integration and QA": deviations log

Package: WP8, branch `feat/3d-wp8`, based on `87ce805` (WP0 to WP7 merged). Written 2026-09-25.
Contract: `docs/3d-port-contracts.md`, every section; acceptance test: the parity checklist at the end of "The work for a playable slice" in `docs/3d-test-plan.md`. The lead folds accepted rows into the contract's deviations table.

Files created: `scripts/3d/knight_visual_3d.gd`, `scripts/3d/tests/arena_integration_smoke.gd` (plus `.uid` sidecars), `docs/3d-arena.md`, this file.
Files edited: `scenes/3d/arena.tscn`, `scenes/3d/player_3d.tscn`, `scenes/3d/wolf_3d.tscn`, `scenes/3d/tests/main3d_stub_arena.tscn`, `scripts/3d/main_3d.gd`, `scripts/level_loader.gd` (additive).
Files deleted: `scripts/3d/main_3d_placeholders.gd`, `scripts/3d/tests/arena_smoke.gd` (and their `.uid`).
No model, 2D script or 2D scene was touched; `combat_fx.gd`, `loot_dropper.gd` and `loot_menu.gd` were only read.

## Bugs fixed while integrating

| # | File | Bug | Fix |
| --- | --- | --- | --- |
| B1 | `scripts/3d/main_3d.gd` | `_ready` wired enemy targets before the navigation map's first sync. The WP0 stub never pathed on `set_target`, but `Enemy3D.set_target` routes at once (WP3c deviation 11), so the arena with real wolves printed `NavigationServer navigation map query failed because it was made before first map synchronization` on every start. | `_setup_navmesh` now waits for the map to pass its current iteration (`NavigationServer3D.map_get_iteration_id`), both for a shipped baked mesh and after a runtime bake, then sets `is_navmesh_ready()` and calls `_wire_enemy_ai_targets`. Two physics frames after `bake_finished` are no longer assumed. |
| B2 | `scripts/3d/main_3d.gd` | `_cache_blocked_cells_from_props` expected a direct `CollisionObject3D` child with a `BoxShape3D`; the imported props nest a `StaticBody3D` two levels down with a concave trimesh (WP7 deviation 2), so no prop ever blocked a grid cell. | Walks every descendant collision object on layer 4 and marks the cells under each shape's global AABB (box size, trimesh faces, or the shape's debug mesh otherwise). The arena now blocks 48 cells for its 22 props; the smoke asserts the crate's and the chest's cells. |
| B3 | `scenes/3d/arena.tscn` | WP7's `Smoke` node drove the coordinator on every run of the scene, F6 included, so a play session started with a scripted move. | The `IntegrationSmoke` node only runs headless or with the user argument `--integration-smoke`. |

## Deviations and decisions

| # | Area | Deviation | Why | Action for the lead |
| --- | --- | --- | --- | --- |
| 1 | Player model (5.2, 10) | The knight glb nests `HandPoint`, `OverheadAnchor` and `Sword` under `Knight_Body`, not under the root as `docs/deviations/wp1.md` section 5 shows. `knight_visual_3d.gd` looks them up recursively, copies the `Sword` mesh (and surface overrides) onto `HandPoint/EquippedWeaponHolder/EquippedWeaponMesh` in `_ready` and hides the original; `Player3D` keeps the scene-authored mesh (WP3b D4). The scene's `HandPoint` is at the glb's hand (0.335, 0.86, -0.08) and `OverheadAnchor` at 2.25 m. | Godot's glTF importer parents empties under the mesh node they were parented to in Blender. | Fix the tree in wp1.md / section 10. |
| 2 | Wolf scene (5.3) | `scenes/3d/wolf_3d.tscn` is a standalone scene (same collider, agent and export values as `enemy_3d.tscn`, wolf.glb under `Model`, `OverheadAnchor` at 0.95 m) instead of an inherited one. | An inherited scene cannot remove the base scene's red box, only hide it, and a hidden box would still be tinted and flashed as part of `Model`. `enemy_3d.tscn` keeps the box for the generic enemy. | Note in 5.3 that the wolf no longer inherits. |
| 3 | Coordinator (6, 7, 8) | Every `TODO(3d-integration)` is closed: `WorldPicker` through `CameraRig3D.get_camera()`; the fallback camera is gone and a level without a `CameraRig` gets a `push_error` and no picking; `CombatFx.set_world_projector` / `set_shake_target` are installed unconditionally and cleared in `_exit_tree`; overlays are the WP5 nodes; `LootDropper.drop_items` and `LootMenu.request_loot` are called directly; `main_3d_placeholders.gd` is deleted. | Task. | Section 9 "Implemented in WP4" paragraph: drop the placeholder and fallback sentences. |
| 4 | Shake units (7) | The shake adapter keeps WP4's pixel-to-metre conversion (`camera.size / viewport height`, screen y negated) before `CameraRig3D.set_shake_offset`. | `CombatFx.shake` strengths are 2D pixels (4 to 6 px); the rig's offset is metres. Passing pixels straight through would shake the camera by metres. | Record in section 7 that the adapter converts. |
| 5 | Ring parenting (7) | The melee and ranged rings are children of the player body at its local origin, as `docs/deviations/wp5.md` asks; the blast ring stays under the level root and is moved onto the hovered enemy each frame rather than reparented. | Reparenting on every hover change is more churn than a position write. | None. |
| 6 | Pickup hover (8) | `_update_hover_state` also ray-picks pickups each frame and pushes `set_hover_highlighted` to the one under the cursor. | WP6 asked the coordinator to drive pickup hover since 3D pickups never hit-test themselves. | Add to section 8. |
| 7 | `enemy_scene` (9) | Default and arena value are `scenes/3d/wolf_3d.tscn`, not the `enemy_3d.tscn` WP4 deviation 14 anticipated. | The wolf is the one enemy of the slice; the generic box stays a scene for tests. | Update deviation 14's note. |
| 8 | `LevelLoader` (1, 9) | `apply_spawn` accepts a `Node3D` spawn and player through a guarded branch; `_find_player` returns `Node`. The 2D branch casts to `Node2D` exactly as before, so a non-`Node2D` player still returns early. The smoke calls `apply_spawn(arena)` with `pending_spawn_name = &"default"` and asserts the snap. | WP4 deviation 4. | None. |
| 9 | Stub arena test (11) | `scenes/3d/tests/main3d_stub_arena.tscn` instances `camera_rig_3d.tscn` instead of a bare `Camera3D`. | The fallback camera is gone (row 3). | None; `SMOKE OK` unchanged. |
| 10 | Integration smoke (12) | `arena_integration_smoke.gd` replaces WP7's `arena_smoke.gd` and folds its four level checks in. It parks wolves 2 and 3 at (10, 0, -10) and (10, 0, 10), outside the 9 m engagement radius, so the scripted fight has one opponent per beat and fits the 1200-frame budget (about 13 s at the 60 fps cap); wolf 1 dies to knight melee 20 plus rogue throw 16 (36 HP), with a `receive_damage(1000)` fallback if the numbers change; the perfect block is simulated by polling `Player3D._counter_phase` and calling `_register_counter_press()` in the strike window, as `player_test.gd` does; Arcane Burst's blast ring is asserted after `_set_hovered_enemy(wolf)` plus `_update_range_rings()` in the same frame, because the per-frame mouse pick clears the hover under a headless mouse at (0, 0); the story book is closed with `Input.parse_input_event` of `ui_cancel`, and the smoke node is `PROCESS_MODE_ALWAYS` so it keeps running under the paused book. | The checklist needs deterministic positions; snapping actors between steps is the only headless option. | None. |
| 11 | `acquire_counter_prompt` | Kept, now returning a `CounterPrompt3D`; nothing in the slice calls it since `Enemy3D` builds its own prompt. | WP4 deviation 10 left it optional. | Remove in a later cleanup if no enemy script needs it. |
| 12 | Story chapter | `story_chapter_id` stays empty on the arena root (WP7 deviation 6); the smoke opens the prologue explicitly and asserts `show_chapter_once` does not reopen it. | Deterministic headless runs. | A content package sets the chapter. |
| 13 | Soul bodies | The knight is the body for all three souls; only the vision light changes on a shift (WP3b D11, no `Model/Body` tint). `rogue.glb` and `mage.glb` are imported but unused. | Out of scope for the slice. | Decide whether to swap bodies per soul next. |
| 14 | Verification (11) | `--check-only` fails on `main_3d.gd`, `player_3d.gd`, `enemy_3d.gd` and the smoke with `Identifier not found: CombatFx` / `StoryBook` / `LevelLoader`, as WP4 deviation 1 records; the headless scene runs below are the compile proof. `knight_visual_3d.gd` checks clean. | Godot 4.7.2 behaviour. | None. |

## Verification record (2026-09-25, Godot 4.7.2)

| Command | Exit | Result |
| --- | --- | --- |
| `--import` | 0 | no errors |
| `--check-only --script res://scripts/3d/knight_visual_3d.gd` and every other 3D script that names no autoload | 0 | clean |
| `--check-only --script res://scripts/level_loader.gd` | 0 | clean |
| `res://scenes/3d/arena.tscn --quit-after 1200` | 0 | `INTEGRATION OK`; every step printed `ok`; no `SCRIPT ERROR`, `ERROR` or `WARNING` lines |
| `res://scenes/3d/tests/main3d_stub_arena.tscn --quit-after 240` | 0 | `SMOKE OK` |
| `res://scenes/3d/tests/actor_base_test.tscn --quit-after 240` | 0 | `ACTOR_BASE OK` |
| `res://scenes/3d/tests/camera_picking_test.tscn --quit-after 120` | 0 | `CAMERA_PICKING OK` |
| `res://scenes/3d/tests/overlays_test.tscn --quit-after 120` | 0 | `OVERLAYS OK` |
| `res://scenes/3d/tests/pickup_test.tscn --quit-after 240` | 0 | `PICKUP OK` |
| `res://scenes/3d/tests/player_test.tscn --quit-after 900` | 0 | `PLAYER OK` (knight model in the scene) |
| `res://scenes/3d/tests/enemy_test.tscn --quit-after 900` | 0 | `ENEMY OK` (wolf model in the scene) |
| `res://scenes/3d/tests/asset_gallery.tscn --quit-after 120` | 0 | `ASSET_GALLERY OK` |
| `res://scenes/3d/arena_skeleton.tscn --quit-after 120` | 0 | no output, no errors |
| `res://scenes/main.tscn --quit-after 120` | 0 | 2D game runs; only the two pre-existing 2D messages WP4, WP5 and WP7 recorded |
| `git diff --stat 2d-baseline -- scenes scripts` | - | only `3d` paths plus `combat_fx.gd`, `loot_dropper.gd`, `loot_menu.gd`, `level_loader.gd` |

Integration smoke output, for the record:

```
[integration] path 10.00 m, 22 props on layer 8, 48 blocked cells
[integration] sword spans y 0.14..1.04 m from a hand at 0.86 m
[integration] combat started at 6 cells from Enemy_01
[integration] 10 m request trimmed: walked 5.60 m
[integration] melee 20 damage, contact after 133 ms (delay 100 ms)
[integration] enemy turn 1.98 s (at least 1.83 s), block negated the bite, 2 shifts
[integration] throw: wolf 16 -> 0
[integration] second enemy turn 2.08 s; burst and snare landed, wolf rooted
INTEGRATION OK
```
