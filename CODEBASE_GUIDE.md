# SharedFate Codebase Guide

This page explains how the current prototype is structured, where systems live, and how the main gameplay loop works.

## Quick file map

- `scenes/main.tscn`: Main scene graph (camera, player, navigation region, tilemap layers).
- `scripts/main.gd`: Core game orchestration (phase switching, turn flow, UI, spawning, movement requests).
- `scripts/player.gd`: Player actor logic (movement, attacks, HP/XP, turn resources, combat VFX).
- `scripts/enemy.gd`: Enemy actor logic (AI chase/attack, HP, turn resources, hover highlight, death reward).
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

There is currently no `AnimationPlayer`-driven animation pipeline. Most effects are procedural:

- Attack feedback uses tweens in `player.gd::_flash_attack_feedback()`:
  - sprite tint flash
  - short lunge and scale squash
  - temporary slash sprite fade/scale
- Enemy hit feedback also uses a tween color flash in `enemy.gd::_flash_attack_feedback()`.
- Visuals are generated from runtime textures in code (`_create_placeholder_texture`, `_create_enemy_texture`, `_create_slash_texture`, etc.).

If you later move to sprite sheet animations, this is the system to replace first.

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
