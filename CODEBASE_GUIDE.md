# SharedFate Codebase Guide

This page explains how the current prototype is structured, where systems live, and how the main gameplay loop works.

## Quick file map

- `scenes/main.tscn`: Main scene graph (camera, player, navigation region, tilemap layers).
- `scripts/main.gd`: Core game orchestration (phase switching, turn flow, UI, spawning, movement requests).
- `scripts/player.gd`: Player actor logic (movement, attacks, HP/XP, turn resources, combat VFX).
- `scripts/enemy.gd`: Enemy actor logic (AI chase/attack, HP, turn resources, hover highlight, death reward).
- `scripts/inventory/item.gd`: `Item` Resource — flexible weapon/item definition (damage, type, range, icon, free-form `properties` dict).
- `scripts/inventory/item_factory.gd`: `ItemFactory` — static builders for items including procedural pixel-art textures (e.g. `create_sword()`).
- `scripts/inventory/inventory.gd`: `Inventory` Node — list of items + equipped weapon, emits signals on change.
- `scenes/backgroundMap.gd`: Tilemap helper script for obstacle/navigation updates (currently minimal/partial).
- `project.godot`: Project-level display/window config.

## High-level architecture

- `main.gd` is the coordinator. It does not own all low-level logic, but it decides *when* systems run.
- Actor scripts (`player.gd`, `enemy.gd`) own execution details like movement stepping, attack checks, damage handling, and state.
- Scene nodes in `main.tscn` provide composition: `Player` has `NavigationAgent2D`, `CollisionShape2D`, and visual nodes; map and nav data come from tilemap/navigation nodes.

## How turn-based combat is implemented

Main flow is in `scripts/main.gd`.

- Combat phases are tracked with `CombatState`:
  - `EXPLORATION`
  - `PLAYER_TURN`
  - `ENEMY_TURN`
- `_update_combat_state()` checks proximity and actor alive-state each frame.
- `_is_close_enough_for_combat_start()` triggers turn mode using Manhattan cell distance.
- `_start_turn_based_combat()`:
  - Stops movement for all actors.
  - Enables turn mode on player/enemies.
  - Starts player turn with movement budget (`TURN_MOVE_METERS`) and one attack.
- Player turn actions:
  - `_request_player_turn_move(...)`
  - `_request_player_turn_attack(...)`
  - `_request_player_turn_engage_enemy(...)` (approach + attack flow)
- Enemy turn flow:
  - `_begin_enemy_turn()` switches phase.
  - `_run_enemy_turn()` iterates alive enemies, gives move budget, moves, then attacks.
  - Returns control to player and starts new player turn.
- `_end_turn_based_combat()` exits back to exploration when one side is dead or missing.

Actor turn state is stored per actor:

- `player.gd` and `enemy.gd` each implement:
  - `set_turn_based_combat(enabled)`
  - `start_turn(max_move_meters)`
  - `end_turn()`
  - movement budget queries/consumption
  - attack availability tracking

## How the realtime phase is implemented

Realtime phase equals `CombatState.EXPLORATION` in `main.gd`.

- Input handling is in `_unhandled_input(event)`:
  - Left click enemy: sets player attack target.
  - Left click ground: clears attack target and requests move.
  - Accept key (`ui_accept`): requests attack.
- `_request_player_move(...)` forwards target position to player navigation.
- Player and enemy run continuous movement/attack in `_physics_process(...)` in their own scripts.
- Outside turn mode, enemies chase and attack based on cooldown/range checks in `enemy.gd`.

## How the combat system is implemented

Combat currently has two behavior modes sharing core stats:

- Shared core stats per actor:
  - `max_health`, `attack_damage`, `attack_range`, cooldowns, and turn resources.
- Realtime combat:
  - Player can hit with radial query (`_apply_attack_damage()` in `player.gd`) or target attack.
  - Enemies refresh target position and attack when in range (`enemy.gd`).
- Turn-based combat:
  - One attack availability per turn (`turn_attack_available`) plus movement budget.
  - Attack methods (`try_attack`) enforce turn-state checks and range checks.
- Damage model:
  - `receive_damage(...)` / `take_damage(...)`.
  - Player supports blocking (`set_blocking`) reducing incoming damage.
  - Enemy death grants XP via group call to player.

## How animations are implemented

Animations are layered across two cooperating systems — see "Weapon animations" below for the full design.

- **Weapon motion** is driven by an `AnimationPlayer` (`AttackAnimations`) under the player. It stores one short `Animation` per archetype (`melee_slash`, `melee_thrust`, `melee_chop`, `ranged_bow`, `cast_staff`, `unarmed`) and keys the weapon holder's rotation/position. Built in code by `Player._setup_attack_animations()`.
- **Body feedback** is still procedural tweens (`player.gd::_flash_attack_feedback()` for melee, `_flash_ranged_feedback()` for ranged). They produce the tint flash, lunge, scale squash, slash VFX, and projectile line. This lets us compose weapon swings on top of a body that isn't sprite-sheeted yet.
- **Enemy hit feedback** also uses a tween color flash in `enemy.gd::_flash_attack_feedback()`.
- **Textures** are generated at runtime by code (`_create_placeholder_texture`, `_create_enemy_texture`, `_create_slash_texture`, `ItemFactory._create_sword_texture`, etc.).

When you introduce a player sprite sheet, migrate the body tweens into the archetype `Animation`s and delete `_flash_attack_feedback` — the AnimationPlayer then becomes the single source of truth for attack motion.

## How movement and pathfinding are implemented

Movement and pathing are split between coordinator and actor scripts:

- Actors move via `NavigationAgent2D` (`player.gd` and `enemy.gd`).
- Target routing:
  - `set_navigation_target(world_position)` snaps destination to closest nav point via `NavigationServer2D.map_get_closest_point`.
- Step-by-step movement happens in actor `_physics_process(...)` using `get_next_path_position()` + `move_and_slide()`.
- Turn movement range:
  - `main.gd` builds world paths (`_build_world_path_from_navigation`),
  - computes path length,
  - trims destination to max allowed meters,
  - then sends that destination to actor navigation.
- Additional path systems:
  - `AStarGrid2D` is rebuilt in `_rebuild_navigation_for_layer(...)` to represent blocked cells.
  - Dynamic enemy personal-space blockers are tracked in `enemy_blocked_cells`.
  - Some A* helper methods exist for alternative routing logic and fallback behavior.

## Additional important concepts

### Camera and readability

- Camera follows player smoothly in `_process(...)` using lerp (`CAMERA_FOLLOW_SPEED`).
- Zoom is set in `_center_camera_on_layer(...)` via `CAMERA_ZOOM`.

### Turn UI and action UI

- Built fully in code inside `_setup_turn_ui()` in `main.gd`.
- Updated every frame by `_update_turn_ui()`.
- Includes:
  - phase/move/attack labels
  - level/XP display
  - turn order icons
  - action buttons (`Attack`, `Block`, `Wait`)

### Path preview UX

- `main.gd` creates `Line2D` overlays and a distance label:
  - `_setup_path_preview()`
  - `_update_path_preview()`
- Only visible during player turn and shows used vs remaining movement meters.

### Enemy spawning and lifecycle

- Enemies are created at runtime in `_spawn_additional_enemy(...)`.
- Spawn points are chosen near offset target cells with walkability search.
- Enemy death (`enemy.gd`) grants XP and removes node via `queue_free()`.

### Inventory and items

- `Item` is a `Resource`. Core properties: `id`, `display_name`, `description`, `icon`, `damage`, `weapon_type` (`MELEE`/`RANGED`/`MAGIC`), `weapon_range`. Use `properties: Dictionary` plus `get_property`/`set_property` for future stats (crit, status effects, etc.) without changing the class.
- Animation/fit properties: `animation_archetype`, `animation_override`, `grip_offset`, `grip_rotation_deg` (see "Weapon animations" below).
- `ItemFactory` owns item construction and procedural pixel-art (see `create_sword()`).
- `Inventory` is a `Node` added as a child of the player (`$Inventory`). API: `add_item`, `remove_item`, `equip_weapon`, `get_equipped_weapon`, `find_item_by_id`. Signals: `item_added`, `item_removed`, `equipped_weapon_changed`.
- The player auto-equips an Iron Sword (`ItemFactory.create_sword()`) in `_setup_inventory()`. Melee combat reads `get_melee_damage()` / `get_melee_range()` which prefer the equipped melee weapon's stats and fall back to `attack_damage` / `attack_range` when nothing is equipped. Ranged attacks still use `ranged_attack_damage` until a ranged weapon is introduced.
- The equipped weapon's `icon` is rendered beside the player via `EquippedWeaponSprite` (child of `EquippedWeaponHolder`), updated via the `equipped_weapon_changed` signal.

### Weapon animations

The goal: **share one animation across every weapon that moves the same way, swap skins freely, only author a new animation when the motion really changes.** You should not need a new animation per sword.

#### Pattern

1. Each weapon declares an **archetype** — the shared motion it uses. Archetype names live on `Item` as constants (`ARCHETYPE_MELEE_SLASH`, `ARCHETYPE_MELEE_THRUST`, `ARCHETYPE_MELEE_CHOP`, `ARCHETYPE_RANGED_BOW`, `ARCHETYPE_CAST_STAFF`, `ARCHETYPE_UNARMED`).
   - All one-handed swords/daggers → `melee_slash`
   - Spears/rapiers → `melee_thrust`
   - Two-handed axes/mauls → `melee_chop`
   - Bows/crossbows → `ranged_bow`
   - Staves/wands → `cast_staff`
2. The weapon is a separate sprite that the player holds. It lives inside a **weapon holder** (`EquippedWeaponHolder`) which sits at the player's hand point. The holder is what attack animations rotate and translate — this way one shared animation works for any weapon texture without per-item transform fights.
3. Per-item fit (`grip_offset`, `grip_rotation_deg`) is applied to the **sprite inside** the holder. So a dagger can sit lower, a staff can be rotated upright, and both reuse the same `melee_slash` or `cast_staff` animation.
4. For the rare signature weapon, set `animation_override` on the `Item` and author a unique animation — no archetype change needed.

#### Node layout on the player

```
Player
├── Sprite2D                        (body — today procedural, later a sprite sheet)
├── WeaponFlipRoot                  (Node2D, scale.x = ±1 based on facing)
│   └── EquippedWeaponHolder        (Node2D at WEAPON_HAND_POINT; driven by attack animations)
│       └── EquippedWeaponSprite    (Sprite2D, pos = grip_offset, rot = grip_rotation_deg)
├── AttackSlash                     (melee VFX sprite)
├── AttackAnimations                (AnimationPlayer holding the archetype stubs)
└── Inventory
```

Three separate nodes intentionally do three separate jobs:

- `WeaponFlipRoot` handles **facing** (`_update_weapon_facing()` flips `scale.x`). One assignment mirrors the hand point, the weapon texture, and any running swing — animations stay facing-agnostic.
- `EquippedWeaponHolder` is what **archetype animations** drive (rotation and position). Keyed in flipper-local space so the same keys read correctly both ways.
- `EquippedWeaponSprite` carries the **per-item skin** (texture + `grip_offset` / `grip_rotation_deg`). Swapping this sprite is how we reuse one motion for every weapon of the same archetype.

#### Where the animations live

`Player._setup_attack_animations()` creates an `AnimationPlayer` called `AttackAnimations` and installs an `AnimationLibrary` with one `Animation` per archetype:

- `melee_slash` — horizontal arm swing (holder rotation). Body lunge, tint and slash VFX are still produced by the tween in `_flash_attack_feedback` so the two layers compose cleanly.
- `melee_thrust` — straight forward stab (holder translate + small rotation).
- `melee_chop` — overhead two-handed chop, slower arc.
- `ranged_bow` — body scale accent + holder pull/release. Projectile line is added by `_flash_ranged_feedback`.
- `cast_staff` — body modulate glow + holder raised overhead.
- `unarmed` — forward jab when no weapon is equipped.

Each builder calls a shared `_add_value_track(anim, path, keys)` helper to keep the stubs short and uniform. The track paths use the constants `_HOLDER_ROT_PATH` / `_HOLDER_POS_PATH` / `_BODY_SCALE_PATH` / `_BODY_MOD_PATH`.

Dispatch goes through `_resolve_attack_archetype()` (reads `animation_override` first, then `animation_archetype`, defaulting to `melee_slash` unarmed) and `_play_attack_animation(archetype_override)`. Melee attack paths call `_flash_attack_feedback()` which dispatches and also runs the melee-only body tween + slash VFX. Ranged attacks call `_flash_ranged_feedback()` which dispatches to `ranged_bow` or `cast_staff` depending on the equipped weapon's archetype.

#### How to add a weapon

- New weapon that moves like an existing one → build the item in `ItemFactory`, set `animation_archetype` to the shared archetype, tune `grip_offset` / `grip_rotation_deg` for the skin. **No new animation.**
- New weapon with genuinely new motion → add a new `ARCHETYPE_*` constant on `Item`, implement `_build_<name>_animation()` in `player.gd`, register it in `_setup_attack_animations()`, and point the new item at it via `animation_archetype`.
- Signature/boss weapon with bespoke motion → leave `animation_archetype` as a sensible default and set `animation_override` to a unique animation name; register that animation the same way.

#### Roadmap (when to upgrade this system)

1. **Now (done):** tween-based body feedback + weapon holder driven by small keyed stubs.
2. **When the body becomes a sprite sheet:** move body tracks (`Sprite2D:frame`, `Sprite2D:position`, `:scale`, `:modulate`) into the archetype animations and delete the tween in `_flash_attack_feedback`. The AnimationPlayer becomes the single source of truth for attack motion.
3. **When you want richer poses (block, idle-sway with weapon, etc.):** introduce a `Skeleton2D` with a `hand` bone and re-parent `EquippedWeaponSprite` to the bone. Archetype animations move bones instead of the holder; any held weapon follows automatically.
4. **Only for bespoke hero/boss weapons:** per-weapon unique animation via `animation_override`. Avoid this for common loot.

Rule of thumb: **don't write a per-weapon animation to differentiate a skin — tune `grip_offset`, rotation, and maybe particle children instead. Write a new archetype only when the body posture / timing / contact arc is genuinely different.**

### Progression system (current)

- Player XP/level is in `player.gd`:
  - `add_experience(...)`
  - `xp_required_for_next_level()`
  - `_on_level_up()` (currently placeholder for future level-up effects/stats)

## Current limitations and TODO opportunities

- `backgroundMap.gd` obstacle/nav update logic is mostly placeholder comments.
- `AStarGrid2D` helpers exist but routing currently relies heavily on navmesh + `NavigationServer2D` path extraction.
- Animation system is procedural and code-driven; no content pipeline yet for authored clips.
- Combat is functional but still prototype-level (simple AI, no abilities/status effects, no initiative variety).

## Where to start when you jump back in

- If you want to change rules/flow: start in `scripts/main.gd`.
- If you want to change player feel: start in `scripts/player.gd`.
- If you want to tune enemy behavior: start in `scripts/enemy.gd`.
- If you want to adjust map/nav setup: inspect `scenes/main.tscn` and `scripts/main.gd` navigation helpers together.
