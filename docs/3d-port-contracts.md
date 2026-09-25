# 3D port: conventions and contracts

Status: WP0 deliverable, written 2026-09-20 on branch `feat/3d-test`. Every 3D work package quotes the parts of this file it needs. Deviations found while implementing go in the "Deviations log" at the end, and the lead folds them back into the text before the next package reads it.

Plan and package table: `docs/3d-test-plan.md`. 2D architecture: `CODEBASE_GUIDE.md`.

## 1. Ground rules for the branch

- The 2D game must not change. `scripts/*.gd` (except the files listed as additive below), `scenes/*.tscn`, `assets/**` and `tools/build_black_woods.gd` are read-only on this branch.
- All new code lives under `scripts/3d/`, `scenes/3d/`, `assets/3d/`, `tools/blender/` and `docs/`.
- Shared files that may receive **additive** edits, and by whom: `scripts/combat_fx.gd` (WP5), `scripts/inventory/loot_dropper.gd` and `scripts/inventory/loot_menu.gd` (WP6), `scripts/level_loader.gd` (WP8 if needed), `project.godot` autoload list (WP8 if needed). Additive means: new optional parameters with defaults, widened parameter types (`Node2D` to `Node`, `Vector2` to `Variant`), new methods, new branches guarded by a 3D check. Never a changed default, a renamed method or a removed branch.
- Port by copying: `scripts/3d/main_3d.gd`, `player_3d.gd`, `enemy_3d.gd` start as copies of the 2D scripts. Duplication is accepted for the test.
- Verify with `git diff --stat 2d-baseline -- scenes scripts`: only `3d` paths plus the additive files above may appear.

## 2. Coordinate and unit conventions

| Item | Convention |
| --- | --- |
| Unit | 1 Godot unit = 1 metre. `GroundMath.METER_WORLD_UNITS` = 1.0. The player receives `set_turn_meter_world_units(1.0)`. |
| Up axis | +Y. The ground plane is y = 0 (`GroundMath.GROUND_Y`). |
| Forward | A character faces its local -Z. Use `GroundMath.yaw_facing(direction)` for `rotation.y`. |
| 2D to 3D mapping | 2D `Vector2(x, y)` ground coordinates become `Vector3(x, 0, y)`: 2D y is 3D z. Use `GroundMath.to_ground` / `from_ground`; never write the conversion inline. |
| Turn grid | 1 m cells, `GroundMath.to_cell` and `cell_center`. `AStarGrid2D` stays as the grid data structure; it is dimension-neutral. |
| Turn constants | `TURN_MOVE_METERS` = 6.0, `ENGAGE_RADIUS_METERS` = 9.0, `COMBAT_TRIGGER_DISTANCE_CELLS` = 6 keep their 2D values. Pixel constants converted in WP4: enemy blocker extra radius 0.6 m, enemy personal-space padding 0.2 m, test loot spread 0.8 m, enemy approach stop `max(0.2, attack_range - 0.4)` m. `ENEMY_CLICK_RADIUS` is replaced by the body ray hit plus `WorldPicker`'s 0.6 m forgiveness. |
| Character scale | Humanoids about 1.9 m tall, origin at the feet (the knight model is 1.93 m). |
| Camera | Orthographic, fixed angle, no player rotation. Default size 14 m vertical, yaw 45 degrees, pitch -35 degrees, looking at the player. Decided 2026-09-19. |

## 3. Collision layers and groups

| Layer | Bit value | Used for | Who collides / rays here |
| --- | --- | --- | --- |
| 1 Ground | 1 | Walkable static geometry; receives click rays | Actors stand on it; `WorldPicker.pick_ground` |
| 2 Actors | 2 | Player and enemy `CharacterBody3D` | Click-to-attack rays; actor-actor blocking |
| 3 Pickups | 4 | `Area3D` on dropped items | `WorldPicker.pick_pickup` |
| 4 Props | 8 | Obstacles, trees, crates; navmesh sources | Actors collide; blocks movement |

Actor bodies: `collision_layer` = 2, `collision_mask` = 1 + 8 = 9. Ground: layer 1, mask 0. Props: layer 8, mask 0. Pickup areas: layer 4, mask 0, `monitoring` off.

Groups keep their 2D names: `player`, `enemies`, `navmesh_source`.

## 4. GroundMath (`scripts/3d/ground_math.gd`, `class_name GroundMath`)

All static. Owned by WP0; extend only by appending functions.

| Function | Meaning |
| --- | --- |
| `to_ground(p: Vector3) -> Vector2` | (x, z) |
| `from_ground(g: Vector2, y := 0.0) -> Vector3` | (g.x, y, g.y) |
| `flatten(p: Vector3, y := 0.0) -> Vector3` | same x and z, given y |
| `ground_distance(a, b: Vector3) -> float` | distance ignoring y |
| `ground_direction(from, to: Vector3) -> Vector3` | unit vector on the plane, `Vector3.ZERO` when coincident |
| `path_length(points: Array[Vector3]) -> float` | sum of ground distances |
| `trim_path(points: Array[Vector3], max_length: float) -> Array[Vector3]` | prefix of the path up to the budget, last point interpolated |
| `to_cell(p: Vector3) -> Vector2i` | floor of x and z over `CELL_SIZE` |
| `cell_center(c: Vector2i, y := 0.0) -> Vector3` | centre of the cell |
| `manhattan(a, b: Vector2i) -> int` | cell distance used for combat start |
| `yaw_facing(direction: Vector3) -> float` | `rotation.y` that points local -Z along `direction` |
| `meters_to_units(m) / units_to_meters(u)` | identity today, kept so ranges stay authored in metres |

## 5. Actor contract

The coordinator calls actors through `has_method` / `call`, so the contract is the method list below. Every `world_position` and `target` is 3D: `Vector3` and `Node3D`. Methods marked (await) are coroutines that return `bool` and the coordinator awaits them.

### 5.1 Shared by player and enemy (WP3a base, `scripts/3d/actor_3d_base.gd`)

| Method | Notes |
| --- | --- |
| `snap_to(world_position: Vector3) -> void` | teleport, also used by `LevelLoader` |
| `set_navigation_target(world_position: Vector3) -> void` | snaps to the closest navmesh point via `NavigationServer3D.map_get_closest_point` |
| `stop_movement_immediately() -> void` | |
| `is_moving() -> bool` | |
| `is_alive() -> bool` | false from the first frame of death |
| `receive_damage(amount: int) -> void` and `take_damage(amount: int) -> void` | both must land (see guide) |
| `set_turn_based_combat(enabled: bool) -> void` | |
| `start_turn(max_move_meters: float = 6.0) -> void` | |
| `end_turn() -> void` | |
| `consume_turn_movement_meters(used: float) -> void` | |
| `get_turn_remaining_move_meters() -> float` | |
| `get_turn_remaining_move_cells() -> int` | |
| `can_turn_attack() -> bool` | |
| `try_attack(target: Node3D) -> bool` (await on the player) | |

Base class also owns: `NavigationAgent3D` child named `NavigationAgent3D`, `CollisionShape3D` child named `CollisionShape3D`, facing via `yaw_facing`, the hit flash hook `flash_hit()` (material tint, WP5 provides the effect), and an overhead anchor `Node3D` named `OverheadAnchor` at head height for bars and prompts.

Implemented in WP3a as `class_name ActorBase3D` (`scripts/3d/actor_3d_base.gd`). Facts subclasses and levels must know:

- Recast bakes the navmesh about one `cell_height` above the floor (y = 0.3 with the arena settings) and `NavigationAgent3D` measures `path_desired_distance` / `target_desired_distance` in 3D, so an agent aimed at raw navmesh points never reaches its first waypoint. `set_navigation_target` sets `path_height_offset` from the measured navmesh height and aims `target_position` at y = 0. Do not undo this in subclasses.
- `NavigationServer3D.map_get_closest_point` returns (0, 0, 0) until the first map sync after a runtime bake; two physics frames after `bake_finished` were not enough. Levels that bake at runtime (WP4, WP7) must wait for the map before routing anyone (`scripts/3d/tests/actor_base_test.gd` shows `_wait_for_navigation_map`).
- Damage: subclasses scale incoming hits in the virtual `_apply_damage(amount: int) -> int` (return what lands), never by overriding `take_damage`. Outgoing melee damage comes from the virtual `_outgoing_damage() -> int`.
- Death: `_die()` makes `is_alive()` false at once, clears the collision layer deferred and calls the virtual `_on_died()`, whose default hides the body. A death animation overrides `_on_died()` without `super` and hides or frees the body when done.
- `try_attack(target: Node3D = null) -> bool`: overrides must repeat the default and the return type. `is_turn_active()` is true only during this actor's own turn; `is_in_turn_based_combat()` answers whether the fight is in turn mode. `end_turn()` and `set_turn_based_combat(false)` do not stop movement, as in `player.gd`.
- Subclasses that define `_ready`, `_physics_process` or `_on_died` call `super` unless they replace the behaviour. `flash_hit()` emits `hit_flashed`. Stuck detection: 1.0 s without 0.03 m of progress stops the actor.

### 5.2 Player only (WP3b, `scripts/3d/player_3d.gd`)

Signal: `soul_changed(soul: Soul)`. Exports keep their 2D names (`move_speed`, `max_health`, `attack_damage`, `attack_range`, `melee_hit_delay`, `character_name`, `gold`); speeds and ranges are now in metres, so `move_speed` about 3.5 m/s, `attack_range` 1.2 m, `attack_approach_buffer` 0.4 m.

| Method | Notes |
| --- | --- |
| `set_attack_target(target: Node3D)`, `clear_attack_target()` | exploration click-to-attack |
| `set_turn_meter_world_units(units: float)` | receives 1.0 |
| `get_melee_range() -> float`, `get_melee_damage() -> int` | weapon-aware, in metres |
| `get_ranged_range_meters() -> float`, `try_ranged_attack(target: Node3D) -> bool` (await) | |
| `try_cast_spell(spell_id: StringName, target: Node3D) -> bool` (await), `get_spell_cooldown(spell_id) -> int` | |
| `get_preferred_attack_approach_distance() -> float` | |
| `set_blocking(enabled: bool)`, `is_blocking() -> bool` | knight stance |
| `get_active_soul() -> Soul`, `get_souls() -> Array[Soul]`, `get_shifts_left() -> int`, `can_shift() -> bool`, `shift_to(kind: int) -> bool`, `shift_kind_from_event(event: InputEvent) -> int` | |
| `get_reaction_hint() -> Dictionary`, `begin_enemy_counter_windup(attacker: Node3D, base_damage: int)`, `begin_enemy_counter_strike()`, `cancel_enemy_counter()`, `resolve_enemy_attack(attacker: Node3D, base_damage: int) -> bool` | counter window, driven by the enemy |
| `heal(amount: int)`, `add_experience(amount: int)`, `get_player_level() -> int`, `get_experience_toward_next() -> float`, `get_xp_required_for_next_level() -> float` | |
| `set_overhead_ui_visible(is_visible: bool)` | |
| `get_equipped_weapon() -> Item`, `get_inventory_items() -> Array[Item]` | `Inventory` child named `Inventory`, unchanged class |

Weapon holder: a `Node3D` named `EquippedWeaponHolder` under a `Node3D` named `HandPoint` (right hand, from the model's `HandPoint` empty). Archetype animations key `EquippedWeaponHolder:rotation` and `:position`; the per-item fit goes on the child `EquippedWeaponMesh`. No flip root: facing is `rotation.y`.

Implemented in WP3b (`scripts/3d/player_3d.gd`, `scenes/3d/player_3d.tscn`, `class_name Player3D`). Item pixels convert through one constant, `WEAPON_RANGE_METERS_PER_PIXEL` = 1.2 / 40 (iron sword 1.2 m, dagger 0.96 m), applied to `weapon_range`, `grip_offset`, the animated hand offsets and the body lunges; `ranged_bolt_speed` is 14 m/s. `try_attack`, `try_ranged_attack` and `try_cast_spell` are `bool` coroutines that now refuse out-of-range targets themselves (2D left that to the coordinator), with the base's 0.05 m tolerance. Animations key `HandPoint/EquippedWeaponHolder:rotation` / `:position` as `Vector3` (the 2D swing angle goes on local X; 2D pixel offsets `(x, y)` become `Vector3(0, -y, -x)` metres) and `Model:scale`; the `modulate` tracks, the slash sprite and the knight attack strip are gone, tints are `HitFlash3D` overlays. The held weapon and the bolt are `ArrayMesh`es with their origin at the grip or head; `EquippedWeaponMesh` hangs point-down (180 degrees about X) plus `grip_rotation_deg`; a scene-authored mesh on that node is kept. `_physics_process` overrides the base step to keep the 2D order (stuck check, manual path, click-to-attack pursuit, then `_step_navigation()`). Death is the base behaviour: `is_alive()` is final and `heal` cannot revive. Overhead UI under `OverheadAnchor`: `HealthBars`, `XpAnchor/XpBars` and a `LevelLabel`, all hidden by `set_overhead_ui_visible`. `BlockRing` is a `RangeRing3D` at 0.55 m. Popup anchors sit 2.1 to 2.7 m above the feet; burst radii scale by 3.35 and the Arcane Burst ring is the projected blast radius. `get_shifts_left()` returns 1 outside combat. WP8 model swap: replace `Model` contents (optional `Model/Body` mesh gets the placeholder soul tint), keep `HandPoint` at (0.34, 0.85, -0.08) or reparent it to the model's `HandPoint`, and author the imported `Sword` as `EquippedWeaponMesh`.

### 5.3 Enemy only (WP3c, `scripts/3d/enemy_3d.gd`)

| Method | Notes |
| --- | --- |
| `set_target(target: Node3D)` | |
| `set_hover_highlighted(enabled: bool)` | outline or tint |
| `apply_root(turns: int)`, `is_rooted() -> bool` | |
| `try_attack(target: Node3D) -> bool` | drives the `CounterPrompt3D` and calls the player's counter methods, same timing as 2D. Returns bool (the 2D enemy returned void): GDScript requires an override to match the base class signature, and the base declares bool |

Exports keep their names; `aggro_range` and `loot_drop_spread` are in metres (wolves: 4.0 m aggro, 0.3 m spread).

Implemented in WP3c (`scripts/3d/enemy_3d.gd`, `scenes/3d/enemy_3d.tscn`, `scenes/3d/wolf_3d.tscn`). Ranges are authored in metres rather than converted from pixels: base enemy 3.0 m/s and 1.2 m reach, wolf 3.6 m/s, 1.1 m reach, 4.0 m aggro; health, damage, cooldowns, XP and the swing durations keep their 2D numbers. The chase aims `0.5 m` short of `attack_range` because the agent stops 0.4 m from its goal. The sprite-sheet exports and procedural textures are gone; the visible body is the `Node3D` child `Model`, and the script only poses, tints and topples nodes under it from the pose captured in `_ready`, so WP8 replaces the contents of `Model` only (origin at the feet, facing -Z, at least one `MeshInstance3D`). Damage goes through `_apply_damage` (a hit always provokes) and the bar, popup, shake and recoil live in `flash_hit()`; `current_health` is a read-only alias of `health`. The additive overlay cannot dim, so the wind-up dim is a red glow and the death fade is a scale collapse after the 0.42 s topple. Hover is an additive overlay on the `Model` meshes; the root ring is a `RangeRing3D` at 0.7 m. Additions: `is_attacking()`, `get_counter_prompt()`, `has_shown_counter_prompt()`, `is_hover_highlighted()`. Actors are on layer 2 with mask 9 and therefore block each other, unlike 2D where the player walked through enemies; avoidance is on to compensate.

What the coordinator must do differently: `await` `try_attack(target)` (it returns after the recovery), install `CombatFx.set_world_projector` before the first fight (damage, XP and ROOTED popups use `Vector3` positions), push hover with `set_hover_highlighted` from the `WorldPicker.pick_enemy` result, parent enemies under a node that outlives them (loot spawns on the enemy's parent), and wait for the navigation map after a runtime bake before `set_target`.

## 6. Camera and picking (WP2)

`scripts/3d/camera_rig_3d.gd` on a `Node3D` named `CameraRig` with a `Camera3D` child named `Camera3D`.

| Member | Meaning |
| --- | --- |
| `set_follow_target(node: Node3D)` | smooth follow, `CAMERA_FOLLOW_SPEED` 6.0 |
| `focus_between(a: Node3D, b: Node3D, blend: float)` and `clear_focus()` | enemy-turn framing, blend 0.6 |
| `shake_offset: Vector2` | screen-space offset in metres, written by the CombatFx shake adapter |
| `set_zoom_size(size_m: float)` | orthographic size |
| `get_camera() -> Camera3D` | |
| `set_shake_offset(offset: Vector2)` | method form of `shake_offset`, for `CombatFx.set_shake_target(Callable(rig, "set_shake_offset"))` |
| `snap_to_target()` | drop the camera on its target this frame (level load, teleport); the 3D twin of `_center_camera` |

Implemented in WP2 (`scenes/3d/camera_rig_3d.tscn`, `class_name CameraRig3D`): `focus_between` defaults `blend` to 0.6; the look-at point rides 1.0 m above the ground so framing matches the 2D sprite centre; boom 30 m, near 0.05, far 200; the rig yields if another `Camera3D` is already current. Wiring for the coordinator: instance the rig as `CameraRig` under the level root with no other `Camera3D`, `set_follow_target(player)` then `snap_to_target()` after load or teleport, `focus_between(player, enemy)` during the enemy turn and `clear_focus()` after, pass `get_camera()` to every `WorldPicker` call, and pick in the 2D order: enemy, then pickup, then ground. Hover highlight is a `pick_enemy` call from the coordinator's `_process`. `WorldPicker.pick_enemy` falls back to the nearest alive enemy within 0.6 m of the ground hit, the metric twin of `ENEMY_CLICK_RADIUS`.

`scripts/3d/world_picker.gd`, `class_name WorldPicker`, all static, takes the camera:

| Function | Meaning |
| --- | --- |
| `pick_ground(camera: Camera3D, screen_pos: Vector2) -> Variant` | `Vector3` on layer 1 or `null` |
| `pick_enemy(camera, screen_pos) -> Node3D` | nearest body on layer 2 in group `enemies`, else `null` |
| `pick_pickup(camera, screen_pos) -> Node3D` | area on layer 3, else `null` |
| `world_to_screen(camera, world: Vector3) -> Vector2` | `unproject_position` |

## 7. Combat feel and overlays (WP5)

Additive contract on the `CombatFx` autoload: `set_world_projector(projector: Callable)`; when set, `_world_to_screen` calls it with the world position (`Variant`, `Vector3` in 3D) and expects a `Vector2` screen point. `popup_text` / `popup_damage` / `ring_burst` accept `Variant` world positions. `shake` gets an optional adapter: `set_shake_target(callable_or_null)` that receives the offset per frame; when unset it keeps writing `Camera2D.offset`. `flash(item)` accepts a `Node` and, for a `Node3D`, calls `item.flash_hit()` if present.

3D overlay nodes mirror the 2D APIs one to one:

| Node | API |
| --- | --- |
| `RangeRing3D` (`scripts/3d/range_ring_3d.gd`) | `show_ring(radius_m: float, color: Color, use_dashes := false)`, `hide_ring()`; a flat ring mesh at y = 0.02 |
| `CounterPrompt3D` (`scripts/3d/counter_prompt_3d.gd`) | `set_hint(text, color)`, `start_windup(duration)`, `start_strike(duration)`, `show_result(perfect)`, `hide_prompt()`; drawn as a Control projected from the enemy's `OverheadAnchor` |
| `PathPreview3D` (`scripts/3d/path_preview_3d.gd`) | `show_path(points: Array[Vector3], used_m: float, remaining_m: float)`, `hide_path()` |
| `OverheadBars3D` (`scripts/3d/overhead_bars_3d.gd`) | `set_ratio(health_ratio: float)`, `set_visible_bars(v: bool)`; projected Control anchored to `OverheadAnchor`; `fill_color` / `ghost_color` exports (player green by default, enemies set red) |
| `HitFlash3D` (`scripts/3d/hit_flash_3d.gd`) | `flash(color := Color(2.6, 2.6, 2.6, 1.0), duration := 0.16)` as a child of the body, or static `HitFlash3D.flash_node(body, color, duration)`; tints every `MeshInstance3D` through `material_overlay` and restores the previous overlay |

Implemented in WP5. Screen-space overlays multiply their 2D pixel sizes by `SCREEN_SCALE` = 3.35 (the 2D `CAMERA_ZOOM`) so they read at their 2D size; the prompt uses CanvasLayer 5, bars and the path label CanvasLayer 3, popups stay on 4. `ring_burst` with a `Vector3` draws on the FX CanvasLayer at the projected point taken once at spawn. `PathPreview3D` has no glow strip; `used_m` only feeds the label. Parenting: `RangeRing3D` under the body it measures from; `CounterPrompt3D` and `OverheadBars3D` under each actor's `OverheadAnchor`; `PathPreview3D` under the level root with global points; `HitFlash3D` as a child of each body, called from `flash_hit()`. The coordinator installs `CombatFx.set_world_projector(...)` and `CombatFx.set_shake_target(rig.set_shake_offset)` once the camera exists and clears both in `_exit_tree` (`set_world_projector(Callable())`, `set_shake_target(null)`), because the autoload outlives the scene. `scripts/3d/tests/overlays_test.gd` is the worked example.

## 8. World items (WP6)

`ItemPickup3D` (`scripts/3d/item_pickup_3d.gd`, scene `scenes/3d/item_pickup_3d.tscn`): `Node3D` with a `Sprite3D` billboard of `item.icon` and an `Area3D` on layer 3. API as 2D: `setup(item: Item)`, `is_available() -> bool`, `take(inventory: Inventory) -> bool`, `gather_pile() -> Array` of nearby pickups within 1.0 m. Clicking goes through `WorldPicker.pick_pickup` in the coordinator, which calls `LootMenu.request_loot(pickup, player)`.

Additive edits: `LootDropper.drop_items(source: Node, items, spread)` branches on `source is Node3D` and instances the 3D pickup scene in a ring on the ground plane; `LootMenu.request_loot(pickup: Node, looter: Node)` widens the type and measures distance with `GroundMath.ground_distance` when both are `Node3D`. `LOOT_RANGE` gains a metre-based twin `LOOT_RANGE_M` = 1.5.

Implemented in WP6. The widening in `loot_menu.gd` had to cascade into the internal pile storage and helpers (`_pile`, `_shown`, `_selected`, `_pending_pickup`, `_take`, `_neighbour_of`, `_filtered_pile`, `_prune_pile`, `_build_slot`, slot callbacks), all `Node2D` to `Node`, because `open_for`'s `as Node2D` cast silently dropped 3D pickups; only `_in_loot_range` gained a real branch. `ItemPickup3D` (`scenes/3d/item_pickup_3d.tscn`) also has `get_item()`, `set_hover_highlighted(enabled)` and the 2D collect animation (0.18 s) before freeing. Coordinator on click: `WorldPicker.pick_pickup(camera, screen_pos)` then `LootMenu.request_loot(pickup, player)`; call `pickup.set_hover_highlighted(bool)` on hover changes, since 3D pickups never hit-test themselves.

## 9. Level node contract (WP7, consumed by WP4)

A 3D level that runs `main_3d.gd` is a `Node3D` root with:

| Node | Type | Purpose |
| --- | --- | --- |
| `WorldEnvironment` | WorldEnvironment | ambient light and background |
| `Sun` | DirectionalLight3D | key light with shadows |
| `NavigationRegion3D` | NavigationRegion3D | baked `NavigationMesh` from its children on layers 1 and 4 (`geometry_parsed_geometry_type` = static colliders); `Ground` and props are its children |
| `NavigationRegion3D/Ground` | StaticBody3D | layer 1, the walkable floor |
| `CameraRig` | Node3D (camera_rig_3d.gd) | with `Camera3D` child |
| `Player` | CharacterBody3D (player_3d.gd) | group `player` |
| enemies | CharacterBody3D (enemy_3d.gd) | group `enemies`, anywhere in the tree |
| `Spawn_<name>` | Node3D | spawn points for `LevelLoader` |

The 2D tilemap nodes (`MyCustomBackground` and friends) have no 3D equivalent; `main_3d.gd` takes its grid from `GroundMath` and the map bounds from the `Ground` collision box.

Implemented in WP7 (`scenes/3d/arena.tscn` with the offline-baked `scenes/3d/arena_navmesh.tres`, 181 polygons; `tools/bake_arena_navmesh.gd` re-bakes it with `godot --headless --path . --script res://tools/bake_arena_navmesh.gd` whenever the layout changes; `scripts/3d/prop_3d.gd` moves every `StaticBody3D` under a prop to layer 8 and adds the prop to `navmesh_source`; `scripts/3d/arena_ground_tiles.gd` lays the checkerboard from `ground_tile.glb` and frees the tiles' imported colliders). Layout: 24 x 24 m clearing, 20 trees on a 13 m ring with about 3.5 m gates, crate and chest near the centre, `Spawn_default` at (-9, 0, 0), enemies `Enemy_01..03` 8.6 to 9 m from the spawn, `story_chapter_id` empty. Known gap for WP8: `_cache_blocked_cells_from_props` in `main_3d.gd` expects a direct `CollisionObject3D` child with a `BoxShape3D`, while the imported props nest a `StaticBody3D` with a `ConcavePolygonShape3D` two levels down (`Tree/Tree_Body/Tree_Col`); movement is unaffected because paths come from the navmesh and blocking from live physics queries, but `_spawn_additional_enemy`'s cell search does not see props until the helper walks descendants. A `--script` tool must do its work in `MainLoop._initialize()`, not `_init()`, or autoload identifiers are unresolved.

Implemented in WP4 (`scripts/3d/main_3d.gd`, smoke scene `scenes/3d/tests/main3d_stub_arena.tscn`). Level authors should know: `_place_player` prefers a `Spawn_default` node and falls back to the 2D centre-plus-offset rule; blocked cells come from layer 4 boxes under the navigation region; when the region's mesh has no polygons and `bake_navmesh_if_empty` is on, `_ready` bakes it and `is_navmesh_ready()` turns true two physics frames after `bake_finished` (arenas that ship an editor-baked mesh skip this); `@export var enemy_scene` sets the spawn scene (WP8 points it at `scenes/3d/enemy_3d.tscn`); `acquire_counter_prompt(owner: Node3D) -> Node3D` parents a prompt under the owner's `OverheadAnchor` through the overlay factory. Since WP8 every seam is closed: the coordinator picks through `WorldPicker` with the `CameraRig`'s camera (a level without a `CameraRig` gets a `push_error` and no picking), installs `CombatFx.set_world_projector` and `set_shake_target` unconditionally (converting the pixel shake offset to metres from `camera.size` over the viewport height) and clears both in `_exit_tree`, creates the WP5 overlay nodes, calls `LootDropper` and `LootMenu` directly, pushes hover to enemies and pickups, waits for the navigation map's first sync (`map_get_iteration_id`) before wiring enemy targets, and marks blocked cells from every descendant collider of a prop (48 cells in the arena). `main_3d_placeholders.gd` is gone. `enemy_scene` defaults to `scenes/3d/wolf_3d.tscn`. An exploration click on an enemy marks the input handled; a click that hits nothing is left unhandled. The playable slice is `scenes/3d/arena.tscn` with `scripts/3d/tests/arena_integration_smoke.gd` as its headless acceptance test (`INTEGRATION OK`); `docs/3d-arena.md` says how to run it.

## 10. Models and assets (WP1)

- Format `.glb`, exported from Blender with +Y up; verify after import that the character faces -Z and stands on y = 0. Files under `assets/3d/models/<name>.glb`, generator scripts under `tools/blender/`.
- Knight, rogue and mage: about 1.9 m tall, origin at the feet, materials named `<Character>_<Part>`, low-poly flat shading, under 1,500 triangles each without the cape.
- The sword is a separate object `Sword` with its origin at the grip; the character carries an empty named `HandPoint` at the right hand, and one named `OverheadAnchor` 0.25 m above the helm.
- Wolf about 1.1 m long, tree 4 to 6 m, crate 0.8 m, chest 0.9 m wide; each prop with a simple collision box authored as a child named `<Name>_Col-colonly`, which Godot imports as a `StaticBody3D` named `<Name>_Col` with a concave shape and no extra mesh (`-col` would keep the box as a second visible mesh).
- A preview sheet `assets/3d/previews/<name>.png` per model, rendered from the front three-quarter view.

Implemented in WP1 (`tools/blender/sf_assets_common.py`, `generate_characters.py`, `generate_wolf.py`, `generate_props.py`; models in `assets/3d/models/`, gallery test `scenes/3d/tests/asset_gallery.tscn`). Facts for WP3b, WP7 and WP8:

- Regenerate from the command line, no add-on needed: `blender --background --factory-startup --python tools/blender/<generator>.py -- --root <repo>`. The scripts also run through the MCP add-on's `execute_code` with `SF_DIR` / `SF_ROOT` pre-set (file headers say how). No `.blend` file is committed.
- Imported tree of a character: root `<Name>` (Node3D) with `<Name>_Body`; the cape, the weapon mesh (`Sword`, `Dagger_L` / `Dagger_R`, `Staff`), `HandPoint` and `OverheadAnchor` sit **under `<Name>_Body`**, because Godot's glTF importer keeps empties under the mesh node they were parented to in Blender (corrected in WP8; look them up recursively). The main mesh is `<Name>_Body` because Godot renames a child that shares its parent's name.
- Weapons: origin at the grip, blade or shaft along local +Y in Godot; the exported `Sword` and daggers carry a 180 degree rotation about X so they hang point-down at rest, the `Staff` stands upright. A weapon dropped into `EquippedWeaponHolder` with an identity transform points straight up.
- Sizes: knight 1.995 m (988 triangles with the solidified cape, 832 without), rogue 1.890 m (720), mage 1.925 m (612), wolf 1.154 m long and 0.725 m at the ears (312) with `OverheadAnchor` at y = 0.925, tree 4.65 m, crate 0.80 m, chest 0.94 x 0.62 x 0.75 m.
- `ground_tile.glb` holds two root objects, `GroundTile_A` and `GroundTile_B` (two greens), top face at y = 0 and 0.10 m thick.
- Blender 4.3 prints a harmless `Draco mesh compression is not available` line on every export; `bpy.context.temp_override(scene=...)` crashes the glTF exporter, so the scripts switch `window.scene` instead.

## 11. Verification on this machine

Godot 4.7.2 is installed via winget at
`%LOCALAPPDATA%\Microsoft\WinGet\Packages\GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe\Godot_v4.7.2-stable_win64_console.exe`
(the console build prints to the terminal). From the repository root:

```powershell
$godot = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe\Godot_v4.7.2-stable_win64_console.exe"
& $godot --headless --path . --import          # import assets once; writes .godot/ (ignored)
& $godot --headless --path . --check-only --script res://scripts/3d/ground_math.gd
& $godot --headless --path . res://scenes/3d/arena_skeleton.tscn --quit-after 120
```

The last line runs a scene for 120 frames and exits; a script error prints to the terminal. Open the project in the editor for anything visual.

Headless Godot runs the main loop as fast as it can, so a `--quit-after N` frame budget can pass before N physics frames; a test that waits on physics or navigation should set `Engine.max_fps = 60` in `_ready`.

`--check-only --script` does not register autoloads, so a script that names `CombatFx`, `LootMenu`, `StoryBook` or another autoload directly fails the check with "Identifier not found" (the 2D `enemy.gd` fails the same way). Verify such scripts by running their scene instead; do not replace the direct autoload access with `get_node("/root/...")`.

Headless Godot 4.7.2 reports a square 1600x1600 viewport, not the project's 1600x900. Projection and unprojection stay consistent, but a headless test must read `get_viewport().get_visible_rect().size` instead of assuming 900 px of height.

Two GDScript rules this project enforces as errors, seen on the first WP0 check: a variable inferred from a `Variant` value must be typed explicitly (`var hit: Variant = ...`), and an overriding method must match the base signature exactly, including the return type.

## 12. Definition of done (every package)

- No script errors on `--import` and on `--check-only` for every new script.
- The package's test scene runs headless for 120 frames without errors.
- Every method in its contract table exists, or is stubbed with a `# TODO(3d):` comment.
- `git diff --stat 2d-baseline -- scenes scripts` shows only allowed paths.
- `scenes/main.tscn` still opens and plays.
- Deviations from this document are listed in the pull request and appended below.

## Deviations log

Each package writes its own `docs/deviations/wp<N>.md` (date, deviation, reason) so parallel branches never conflict on this file. The lead folds accepted deviations into the sections above at merge time and records them here.

| Date | Package | Deviation | Folded into text? |
| --- | --- | --- | --- |
| 2026-09-20 | WP0 | Enemy `try_attack` returns `bool` instead of the 2D `void`, because GDScript overrides must match the base signature | yes (5.3) |
| 2026-09-20 | WP0 | Branch is `feat/3d-test`, not `3d-test`, to follow the `type/description` branch convention; package branches are `feat/3d-wp<N>` in worktrees under `.claude/worktrees/` | yes (1) |
| 2026-09-20 | WP2 | Rig adds `set_shake_offset`, `snap_to_target`, default blend 0.6, look-at height 1.0 m; headless viewport is 1600x1600; picking test asserts ground tolerance at the ray/plane point (full text in `docs/deviations/wp2.md`) | yes (6, 11) |
| 2026-09-25 | WP8 | Knight empties sit under `Knight_Body` (section 10 corrected); `wolf_3d.tscn` is standalone, not inherited, so the box can be removed; `knight_visual_3d.gd` hands the glb sword to the weapon holder; all coordinator seams closed and the placeholders file deleted; shake adapter converts px to m; pickup hover pushed by the coordinator; `LevelLoader` handles `Node3D` spawns; three bugs fixed (enemy targets before map sync, prop blocked cells, WP7 smoke hijacking F6) (full text in `docs/deviations/wp8.md`) | yes (5.3, 7, 8, 9, 10) |
| 2026-09-25 | WP7 | Extra `arena_ground_tiles.gd`; navmesh baked offline and shipped; bake tool logic in `MainLoop._initialize()`; prop collider nesting not seen by `_cache_blocked_cells_from_props` (for WP8); 28 x 28 m tiled floor over a 24 m clearing (full text in `docs/deviations/wp7.md`) | yes (9) |
| 2026-09-25 | WP3b | One pixel-to-metre constant for weapons; attack methods check range themselves; `modulate`, slash sprite and attack strip dropped; `ArrayMesh` weapon and bolt; `_physics_process` override keeps the 2D order; death final; XP bar and level tag as overhead nodes (full text in `docs/deviations/wp3b.md`) | yes (5.2) |
| 2026-09-25 | WP3c | Ranges in metres not converted; approach buffer 0.5 m; sprite-sheet exports dropped; `Model` node contract; damage through `_apply_damage` with `current_health` alias; glow and scale collapse instead of dim and fade; actors block each other (full text in `docs/deviations/wp3c.md`) | yes (5.3) |
| 2026-09-20 | WP1 | Models built with `blender --background` because the add-on server was not started; `-colonly` instead of `-col`; `<Name>_Body` mesh naming; weapon axis +Y with a 180 degree X rotation on blades; wolf anchor above the ears; two ground tile variants in one file (full text in `docs/deviations/wp1.md`) | yes (10) |
| 2026-09-20 | WP4 | Pixel constants to metres (section 2); `Spawn_default` preferred; runtime bake when the mesh is empty; `enemy_scene` export and a new `_spawn_additional_enemy` (the 2D helper the guide describes no longer exists); placeholder overlay classes suffixed `Stub`; `acquire_counter_prompt`; enemy click marks input handled; `LevelLoader.apply_spawn` needs widening to `Node3D` in WP8 (full text in `docs/deviations/wp4.md`) | yes (2, 9) |
| 2026-09-20 | WP3a | `path_height_offset` from the measured navmesh height and ground-plane `target_position`; wait for the navigation map after a runtime bake; `is_in_turn_based_combat()` added; `_apply_damage` / `_on_died` virtuals; `end_turn` does not stop movement; headless tests cap `Engine.max_fps` (full text in `docs/deviations/wp3a.md`) | yes (5.1, 11) |
| 2026-09-20 | WP5 | `HitFlash3D` added; overlays scale 2D pixel sizes by 3.35; bars colours are exports; `ring_burst` in 3D draws on the FX layer at a fixed screen point; `PathPreview3D` drops the glow strip; `--check-only` cannot see autoloads (full text in `docs/deviations/wp5.md`) | yes (7, 11) |
| 2026-09-20 | WP6 | One inline `as Node2D` cast in the 2D `drop_items` branch (GDScript's `Node` has no `global_position`); `LootMenu` widening cascaded into internal storage; `gather_pile()` returns untyped `Array`; the lead replaced the load-time `preload` of the 3D pickup scene with a lazy `load` so the 2D game does not depend on 3D files (full text in `docs/deviations/wp6.md`) | yes (8) |
