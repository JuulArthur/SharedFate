# WP3a deviations: ActorBase3D

Package: WP3a, actor base (`scripts/3d/actor_3d_base.gd`). Branch `feat/3d-wp3a`.
Contract: `docs/3d-port-contracts.md`, sections 2, 3, 4, 5.1, 11, 12.

Everything below is a deliberate decision taken while implementing, recorded here
for the lead to fold back into the contracts document.

## 1. The navigation mesh sits above the floor, and the agent measures in 3D

Recast bakes the navigation mesh roughly one `cell_height` above the collision
floor: with the contract's navmesh settings the path points come back at
y = 0.3 while the actor's origin is at its feet, y = 0.

`NavigationAgent3D` compares `path_desired_distance` and `target_desired_distance`
against the **3D** distance, so that 0.3 m of empty air alone is enough to stop the
agent ever reaching its first waypoint. With the arena skeleton's tuning
(`path_desired_distance = 0.3`) the actor stands still forever: the next path
position is its own position lifted by 0.3 m, the ground direction is zero, and the
stuck detector eventually gives up. This is not visible in the contract text and it
will hit every 3D level, not just the test scene.

`set_navigation_target` therefore does two things beyond the contract:

- it sets `navigation_agent.path_height_offset` to the measured height of the
  navmesh point above the ground plane, which puts the agent's own distance checks
  back on the ground plane, and
- it aims `target_position` at the flattened (y = 0) destination, so the arrival
  check is horizontal too.

The offset is measured from `map_get_closest_point`, never hardcoded, so it follows
whatever `cell_height` a level bakes with.

## 2. `map_get_closest_point` answers (0, 0, 0) before the first map sync

A freshly baked `NavigationRegion3D` only reaches the navigation map on a later
`NavigationServer3D` sync. Until then `map_get_closest_point` silently returns the
origin, so a destination snapped in that window sends the actor to (0, 0, 0). Two
physics frames after `bake_finished` were not enough in the headless test.

The base class falls back to the raw position when the map RID is invalid, but it
cannot detect "valid but empty". Callers that bake at runtime (WP4 and WP7) must
wait for the map before they route anyone; the test scene shows one way to do it
(`_wait_for_navigation_map`).

## 3. Turn-resource semantics, where the 2D player and the WP0 stub disagree

| Method | Choice | Why |
| --- | --- | --- |
| `is_turn_active()` | true only during this actor's own turn, as in `player.gd` | The stub returned "turn-based combat is on", which is a different question. Nothing in `main.gd` calls either, so this is free to fix. `is_in_turn_based_combat()` was added for the stub's meaning. |
| `can_turn_attack()` | true outside turn-based combat, as in the stub | `player.gd` returns the raw flag (false outside combat) and guards exploration attacks elsewhere; the coordinator's 3D copy will call this method directly. |
| `get_turn_remaining_move_cells()` | `floor(meters / GroundMath.CELL_SIZE)` | `player.gd` rounds, which can promise a step the budget cannot pay for. No caller today. |
| `end_turn()` | does not stop movement, as in `player.gd` | The stub stopped. The coordinator awaits the move before ending the turn. |
| `set_turn_based_combat(false)` | does not stop movement, as in `player.gd` | The stub stopped on both edges. |

## 4. Death: who hides the body

`_die()` sets `is_alive()` false immediately, parks the navigation target, clears
`collision_layer` deferred and then calls the virtual `_on_died()`. The **default**
`_on_died()` hides the body. Section 5.1 reads as if the base always hides it, but
an enemy that topples and fades (WP3c, `enemy.gd` `_die`) needs the mesh to stay
visible for the length of its death beat, so an override that does not call `super`
keeps the body and hides or frees it when the animation ends.

## 5. Smaller points

- `attack_damage` defaults to 20 as specified for WP3a; the WP0 stub used 10.
- `STUCK_MOVE_EPSILON` is 0.03 m, the metric twin of `player.gd`'s 2.0 px at the
  2D game's 64 px to the metre. `STUCK_THRESHOLD` keeps its 1.0 s.
- `flash_hit()` emits a new `hit_flashed` signal and does nothing else; WP5 owns
  the material tint.
- `try_attack(target: Node3D = null) -> bool` keeps the stub's optional parameter.
  GDScript requires overrides to match the base signature, so the player (WP3b) and
  the enemy (WP3c) must declare the default and the `-> bool` return as well.
- The base never writes `collision_layer` or `collision_mask` except to clear the
  layer on death, and it never overrides the scene's `NavigationAgent3D` tuning,
  apart from `path_height_offset` as described above.

## 6. Test scene

- `scenes/3d/tests/actor_base_test.tscn` has a `Pocket` blocker that is a sibling of
  the `NavigationRegion3D`, not a child, so the bake never carves it out. That is
  what makes actor B genuinely stuck: aiming B at the baked obstacle instead would
  only snap its destination to the navmesh edge, and B would simply arrive.
- The test sets `Engine.max_fps = 60`. Headless Godot runs the main loop as fast as
  it can, so without a cap the `--quit-after` iteration budget is spent long before
  200 physics frames have passed.
