# WP3c deviations: Enemy3D

Package: WP3c, the enemy (`scripts/3d/enemy_3d.gd`, `scenes/3d/enemy_3d.tscn`,
`scenes/3d/wolf_3d.tscn`). Branch `feat/3d-wp3c`.
Contract: `docs/3d-port-contracts.md`, sections 1, 2, 3, 5.1, 5.3, 7, 8, 11, 12.
2D original: `scripts/enemy.gd`, `scenes/enemy.tscn`, `scenes/wolf.tscn`.

No shared or 2D file needed a change: the package is eight new files under
`scripts/3d/`, `scenes/3d/` and `docs/`. Everything below is a deliberate decision
taken while implementing, recorded for the lead to fold back into the contracts
document.

## 1. Dropped: the sprite-sheet body

The 2D enemy draws itself. Six exports and four methods exist only for that and
have no 3D meaning, so they are gone:

| Dropped from `enemy.gd` | Why |
| --- | --- |
| `body_sheet_idle`, `body_sheet_run`, `body_sheet_columns_idle`, `body_sheet_columns_run`, `body_sheet_rows`, `body_animation_fps` | grids of facing rows and frames for a `Sprite2D`; a 3D body turns with `rotation.y` and animates from the `.glb` |
| `_setup_body_sprite`, `_process`, `_update_body_animation`, `_apply_body_sheet`, `_body_row_for_direction` | the sheet state machine, including the four-row facing table (away-right, away-left, toward-left, toward-right) |
| `_create_enemy_texture`, `_create_outline_texture`, `_create_solid_texture` | procedural placeholder pixels for the body, the hover outline and the bar |
| `_ensure_collision_shape` | the scene authors the collision box (section 3) |
| `health_bar_fill`, `health_bar_ghost`, `_setup_health_bar`, `HealthBarRoot` | replaced by `OverheadBars3D` (section 7) |

`scenes/wolf.tscn` sets `body_sheet_idle` / `body_sheet_run` to the wolf sheets and
`body_animation_fps = 9.0`; `scenes/3d/wolf_3d.tscn` has no equivalent lines.
Animation returns with WP1/WP8, driven by the imported model, not by this script.

## 2. The node WP8 swaps: `Model`

The visible body is a `Node3D` child named **`Model`**, holding one placeholder
`MeshInstance3D` (a red box, 0.9 x 1.0 x 1.3 m, lifted 0.5 m so it stands on
y = 0). WP8 replaces the contents of `Model`; it must not rename, move or remove
the node itself.

`Enemy3D` touches nothing outside `Model`. Everything the swing, the hit recoil, the
topple, the hit flash and the hover rim do is a local `position`, `scale`,
`rotation:x` or `material_overlay` change **under `Model`**, captured as
`_model_idle_position` / `_model_idle_scale` in `_ready`. So an imported wolf can
carry its own offset and scale in the scene and every animation still starts from
that pose. The mesh list is gathered recursively, so a multi-mesh `.glb` tints
whole.

Requirements a replacement model must keep: origin at the feet, facing local -Z
(the lunge is `-Z` on `Model`), and at least one `MeshInstance3D` somewhere under
`Model` (with none, the flash and the hover rim silently do nothing).

## 3. Ranges are authored in metres, not converted from pixels

Section 2 fixes the 2D-to-3D mapping for positions, but the 2D combat ranges were
tuned against 64 px bodies and read as cramped at 1 m scale. The 3D values follow
section 5.2's precedent (the player's `attack_range` 1.2 m against the 2D 44 px =
0.69 m) rather than a literal conversion:

| Export | 2D | Literal conversion | 3D value | Note |
| --- | --- | --- | --- | --- |
| `move_speed` (base / wolf) | 180 / 230 px/s | 2.81 / 3.59 m/s | 3.0 / 3.6 | rounded |
| `attack_range` (base / wolf) | 44 / 40 px | 0.69 / 0.63 m | 1.2 / 1.1 | matches the player's 1.2 m |
| `aggro_range` (wolf) | 200 px | 3.13 m | 4.0 | the value section 5.3 names |
| `loot_drop_spread` | 20 px | 0.31 m | 0.3 | the value section 5.3 names |

`max_health`, `attack_damage`, `attack_cooldown`, `experience_reward`,
`loot_drop_chance`, `target_refresh_interval` and the four swing durations keep
their 2D numbers exactly.

## 4. Approach buffer: 0.5 m, not the 2D 20 px

2D aims the chase at `attack_range - 20 px` (0.31 m short) against a
`target_desired_distance` of 8 px (0.13 m). The 3D agent stops 0.4 m from its goal
(`target_desired_distance` in `enemy_3d.tscn`), so the same 0.31 m buffer parks the
enemy just outside its own reach and it never swings. `APPROACH_BUFFER_M` is
therefore 0.5 m, clamped from below by `MIN_APPROACH_DISTANCE_M` = 0.06 m. In the
test the wolf settles at 0.60 - 0.72 m against an `attack_range` of 1.1 m.

## 5. Health and damage go through the base, not through `receive_damage`

`enemy.gd` owns `current_health` and overrides `receive_damage`. Section 5.1 forbids
that: subclasses scale a hit in `_apply_damage` and the base owns `health`. So:

- `_apply_damage(amount)` returns the full amount and sets `_aggroed` (a hit always
  provokes, as in 2D). It does not touch `health`.
- `flash_hit()` is where the bar update, the damage popup, the shake and the recoil
  nudge live, because the base calls it once per landed hit right after `health`
  changed. `CombatFx.flash(enemy)` routes to the same method through the actor
  contract, so a cosmetic flash also refreshes the bar; it pops no number, because
  `_last_applied_damage` is cleared after each real hit.
- `current_health` survives as a **read-only property** over the base's `health`,
  so 2D-shaped call sites keep reading.
- `is_alive()` is the base's `_alive` flag, not `current_health > 0`. Both go false
  on the same frame, but a future enemy with 0 health that is not dead would now
  behave differently.
- `_attack_precheck` compares against the bare `attack_range`, as in 2D, not the
  base's `attack_range + ATTACK_RANGE_TOLERANCE`.

## 6. What an additive overlay cannot do

`HitFlash3D` (section 7) tints through `material_overlay`, which can only **add**
light. Two 2D effects had to be re-expressed:

| 2D | 3D |
| --- | --- |
| wind-up `modulate` to (0.52, 0.22, 0.22): a dim | a sullen red glow, `WIND_UP_TINT` (0.35, 0.06, 0.06) added |
| death `modulate:a` to 0 over 0.16 s: a fade | a collapse of `Model.scale` to 0.001 over the same 0.16 s |

The death beat still takes `DEATH_SECONDS` 0.42 s for the topple plus
`DEATH_FADE_SECONDS` 0.16 s for the dissolve, the 2D timings.

The topple itself rotates `Model` about its local X by 90 degrees, dropping the
body backwards away from whoever it faces. The 2D script picked a topple direction
from the target's screen x; a body that already faces its target does not need to.

## 7. Hover highlight is an overlay, not an outline sprite

`set_hover_highlighted(enabled)` puts a faint additive `StandardMaterial3D` on every
mesh under `Model` instead of showing a `HoverOutline` sprite. `HitFlash3D` saves
and restores whatever overlay it finds, so the hover rim comes back after a flash
and the two compose, as section 7 promises. Consequence worth knowing: during a
0.16 s flash the rim is replaced rather than drawn on top, which is the same
trade-off `self_modulate` made in 2D.

## 8. The root ring is a `RangeRing3D`

2D builds a squashed `Sprite2D` ring texture and fades it in and out over 0.18 /
0.2 s. 3D reuses `RangeRing3D` (section 7) at `ROOT_RING_RADIUS_M` = 0.7 m: a true
circle on the ground, shown and hidden without the alpha tween, because
`RangeRing3D` exposes only `show_ring` / `hide_ring`. Root semantics are unchanged:
`apply_root` keeps the longer of the two durations, `start_turn` gives a rooted
enemy 0 m of movement but keeps its attack, and `end_turn` spends one turn of root.

`CombatFx.ring_burst` with a `Vector3` draws at a projected screen point (WP5), so
the 2D radii 6 and 22 are multiplied by `FX_SCREEN_SCALE` = 3.35 to read at their
2D size, the same reasoning as `CounterPrompt3D.SCREEN_SCALE`. The four popup
offsets are the 2D pixel offsets over 64 px per metre.

## 9. Collision: the scene authors layer 2 and mask 9

`enemy.gd` writes `collision_layer = 4` and `collision_mask = 1` in `_ready`, so the
2D player walks through enemies. Section 3 puts both actors on layer 2 with mask 9,
authored in `enemy_3d.tscn` and never written by the script, except that `_on_died`
clears `collision_mask` (the base already clears `collision_layer`). **Actors now
block each other.** That is the contract's choice, not this package's, but it is a
real gameplay difference from 2D and the reason `avoidance_enabled` is on in
`enemy_3d.tscn`.

## 10. Methods beyond the contract table

Section 5.3 lists four methods; all four exist with the stated signatures. These are
additions, none of which the coordinator is obliged to call:

| Method | Why |
| --- | --- |
| `is_attacking() -> bool` | true from the first frame of a swing until recovery ends, so the coordinator can hold the enemy turn open instead of guessing at the durations |
| `get_counter_prompt() -> CounterPrompt3D` | the prompt this enemy drives |
| `has_shown_counter_prompt() -> bool` | true once the prompt has been on screen; the test asserts on it |
| `is_hover_highlighted() -> bool` | reads back `set_hover_highlighted` |
| `current_health` | read-only alias over `health` (see 5) |

## 11. What the coordinator must call differently from 2D

- **`try_attack` must be awaited.** `Enemy3D.try_attack(target)` is a coroutine that
  returns only after the recovery, and returns `bool` (already folded into section
  5.3). `ActorBase3D.try_attack` returns immediately, so `await` on a variable typed
  as the base class still works but resolves on a different frame. Pass the target
  explicitly; the default `null` keeps the last `set_target`.
- **Install `CombatFx.set_world_projector` before the first fight.** The damage
  number, the `+XP` text and the `ROOTED` popups are `CombatFx` calls with `Vector3`
  positions. `CounterPrompt3D` and `OverheadBars3D` project themselves and are fine
  without it; the popups are not.
- **Hover is pushed, not polled.** As in 2D, call `set_hover_highlighted(bool)` from
  the coordinator's `WorldPicker.pick_enemy` result; the enemy never hit-tests
  itself.
- **Loot lands on the enemy's parent.** `LootDropper` spawns pickups as siblings
  (deferred) so they outlive the `queue_free`. An enemy parented directly to a node
  that is freed with it loses its loot.
- **Runtime navmesh bakes still need the map wait** (WP3a deviation 2). `set_target`
  routes immediately, so a level that bakes at load must wait before wiring targets.
  `scripts/3d/tests/enemy_test.gd` `_wait_for_navigation_map` is the worked example.
- The enemy does not stop itself when turn-based combat is switched off, matching
  the base (WP3a deviation 3).

## 12. Test scene

`scenes/3d/tests/enemy_test.tscn` / `scripts/3d/tests/enemy_test.gd`: a 40 x 40 m
ground on layer 1, one prop on layer 8, a runtime `bake_navigation_mesh()` plus the
map wait, the WP0 stub player (`max_health = 500`, group `player`) at (8, 0, 0) and
one `wolf_3d.tscn` at the origin. `Engine.max_fps = 60`, five checks, prints
`ENEMY OK` or the first failure with its values.

- The test puts the stub player in the **rogue** soul first. The stub scales
  incoming damage by the soul's `defence_mult`, and only the rogue's is 1.00, so
  what lands is exactly `attack_damage` and check 2 can compare on equality.
- Check 3 measures the turn-mode contact delay from a `_physics_process` watcher,
  not from the `await`, because `try_attack` only returns after the recovery.
  Tolerance 0.25 s against the expected 0.73 s (`0.55 + 0.18`); three runs measured
  0.75 s.
- Check 5 counts `ItemPickup3D` children of the test root within 1.0 m of the death
  position. The wolf is a direct child of the root, so the pickups are too.
