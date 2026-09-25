# WP3b deviations: Player3D

Package: WP3b, the player (`scripts/3d/player_3d.gd`, `scenes/3d/player_3d.tscn`).
Branch `feat/3d-wp3b`, base commit `788f195`. Contract: `docs/3d-port-contracts.md`,
sections 2, 3, 5.1, 5.2, 6, 7, 8, 11, 12.

Everything below is a decision taken while porting `scripts/player.gd` method by
method, recorded for the lead to fold into the contracts document.

## Verification

| Command | Exit | Note |
| --- | --- | --- |
| `--import` | 0 | |
| `--check-only --script res://scripts/3d/player_3d.gd` | 1 | only `Identifier not found: CombatFx` (section 11: the check cannot see autoloads); the script compiles and runs in the scene |
| `--check-only --script res://scripts/3d/tests/player_test.gd` | 1 | same `CombatFx` line, nothing else |
| `res://scenes/3d/tests/player_test.tscn --quit-after 900` | 0 | prints `PLAYER OK`, no `SCRIPT ERROR`; melee contact measured at 133 ms (delay 100 ms), bolt at 366 ms (flight 357 ms over 5 m) |
| `res://scenes/main.tscn --quit-after 60` | 0 | only the two pre-existing 2D lines from WP5 D8 |
| `git diff --stat 788f195 -- scenes scripts` | | only the six WP3b files |

## Deviations

**D1. One constant for weapon pixels.** `Item.weapon_range` and `Item.grip_offset`
stay in 2D pixels (the `Item` class is read-only). `Player3D.WEAPON_RANGE_METERS_PER_PIXEL
= 1.2 / 40.0` converts them, so the iron sword (40 px) reaches the contract's 1.2 m
and the dagger (32 px) 0.96 m. The same constant converts the hand offsets keyed by
the archetype animations (a 8 px thrust is 0.24 m) and the small body lunges, so
the whole weapon-and-arm layer is one scale. It is deliberately not the 2D ground
scale (64 px to the metre): the 3D body is 1.9 m tall where the 2D sprite stood
for about 0.6 m.

**D2. `try_ranged_attack` and `try_cast_spell` check range themselves.** In 2D only
the coordinator refused an out-of-range throw or spell; `player.gd` trusted it. The
brief's test requires the 3D methods to return false for a 13 m throw, so both now
compare `GroundMath.ground_distance` against `get_ranged_range_meters()` /
`Spell.range_meters` plus the base class's `ATTACK_RANGE_TOLERANCE` (0.05 m). The
melee `try_attack` uses the same tolerance on `get_melee_range()`, where 2D compared
strictly. A refused attack spends nothing, as before. The coordinator's own checks
and popups stay.

**D3. Archetype animations in 3D.** `AttackAnimations` (built in code, as in 2D)
keys `HandPoint/EquippedWeaponHolder:rotation` and `:position` as `Vector3`, and
`Model:scale` instead of `Sprite2D:scale`. The 2D holder rotation (radians about
the screen normal) goes unchanged onto the hand's local X axis, which is the same
swing plane (forward and up) now that the body turns with `rotation.y`; 2D pixel
offsets `(x, y)` become `Vector3(0, -y, -x)` metres (forward is -Z). The two
`Sprite2D:modulate` tracks (the cast-staff glow) are dropped, because a 3D body
has no modulate; `_flash_ranged_feedback` fires a `HitFlash3D` tint for the cast
instead. Also dropped, with no 3D twin yet: the slash VFX sprite and the knight's
six-frame attack strip (`_play_body_attack_visual`); the body tint of the melee
tween (`modulate 1.0, 0.72, 0.72`) is an additive red `HitFlash3D` overlay. WP8's
model animations are the place for the body strip.

**D4. The held weapon is a mesh with its origin at the grip.** `BoxMesh` has no
centre offset, so `_make_offset_box` bakes the primitive into an `ArrayMesh` with
its vertices moved: the blade spans local y 0..0.8 from the grip (WP1 convention),
and the bolt's tail trails behind its head. `EquippedWeaponMesh` hangs point-down
(`WEAPON_HANG_ROTATION_DEG` = 180 about X) with `grip_rotation_deg` added on the
same axis and `grip_offset` applied through D1. The scene's `EquippedWeaponMesh`
node carries no mesh: the code fills in the placeholder blade only when the node
has none, so a scene (WP8) may author a real sword there and keep it.

**D5. `_physics_process` replaces the base step to keep the 2D order.** Stuck
check, then the manual path, then in exploration the click-to-attack pursuit
(stand still and swing when in reach, otherwise walk to the approach point), and
only then the base's `_step_navigation()`. It calls the base helpers rather than
copying them. `set_navigation_path` and `_process_manual_path_movement` are ported
although `main.gd` never calls them; the `_check_stuck` override counts a manual
path as "trying to move", as 2D did. `set_navigation_target` and
`stop_movement_immediately` clear the attack target before calling `super`.

**D6. Death is the base's.** At 0 HP `ActorBase3D` hides the body and
`is_alive()` stays false; `heal` raises `health` but cannot revive. The 2D player
had no death state and kept walking at 0 HP (a known 2D limitation in the guide).
The coordinator should treat `is_alive()` as final until a death flow exists.

**D7. Popup and burst geometry.** Popup anchors are 2.1 m (the 2D -44 px damage
anchor), 2.4 m (-62 to -70 px: reaction words, shift title, level up) and 2.7 m
(-84 px, Resonance) above the feet. `CombatFx.ring_burst` radii are multiplied by
`FX_SCREEN_SCALE` = 3.35 (the WP5 overlays' `SCREEN_SCALE`), because in 3D the burst
draws in screen pixels while the 2D radii were world pixels under a 3.35x camera.
The Arcane Burst ring's end radius is the blast radius projected through the
current camera (`_screen_radius_px`), so the burst is the circle the rules test.

**D8. Overhead UI.** The health bar is an `OverheadBars3D` created in code under
`OverheadAnchor` (`HealthBars`); the base class writes `health` directly, so the
bar follows it from `_process`. The 2D XP bar and level tag survive as a second
`OverheadBars3D` (`XpAnchor/XpBars`, purple fill, ghost alpha 0) 0.28 m higher and
a billboard `Label3D` (`LevelLabel`) 0.6 m higher. `set_overhead_ui_visible` hides
all three.

**D9. Block ring.** A `RangeRing3D` child (`BlockRing`, radius 0.55 m, the 2D aura
colour) shown while blocking. `RangeRing3D` has no alpha API, so the 2D fade is a
`tween_method` that rebuilds the ring at the interpolated alpha; the pop and the
"BLOCKED" punch are scale tweens. The camera pitch flattens the circle the way the
2D ellipse was flattened.

**D10. Hit flash colours.** `_apply_damage` flashes the body itself in the 2D
colour of the hit (red, or blue when blocked) and sets a flag so the base's
`flash_hit()` that follows does not flash twice. `flash_hit()` called from outside
(`CombatFx.flash(player, colour)`) cannot receive the colour and uses the
`HitFlash3D` default. Every flash goes through `HitFlash3D.flash_node(self, ...)`,
which also tints the weapon and the block ring; acceptable for a 0.2 s flash.

**D11. Placeholder body per soul.** The 2D player swapped `SpriteFrames` per soul.
The 3D placeholder is one grey capsule under `Model/Body`; `_apply_soul_visual`
tints a per-instance `material_override` toward the soul's colour and blends the
`OmniLight3D` (`VisionLight`, 6 m) to `soul.light_color` over
`SHIFT_LIGHT_BLEND_SECONDS`, as 2D did. With no `Body` mesh (WP8's knight) only the
light changes.

**D12. Turn helpers from the base.** `can_turn_attack()` is the WP3a version (true
outside turn mode); `get_shifts_left()` returns 1 outside combat as in 2D, not the
stub's 99; `get_turn_remaining_move_cells()` floors as in WP3a. `set_turn_meter_world_units`
keeps the 2D floor of 1.0 and defaults to `GroundMath.METER_WORLD_UNITS`.

**D13. Smaller numbers.** `ranged_bolt_speed` is 14 m/s (900 px/s at 64 px to the
metre); the flight clamp 0.08 to 0.4 s is kept. The approach-distance floor is
0.2 m (2D: 4 px). The exploration sweep is a `SphereShape3D` at 0.9 m on layers 2
and 8 (actors and props; 2D used 1 | 4). `_ensure_collision_shape` forces the
contract capsule (radius 0.35, height 1.8, at y 0.9) the way 2D forced its circle.
The base class exports `move_speed`, `max_health`, `attack_damage`, `attack_range`,
so `Player3D` cannot redeclare them; the defaults already match the contract.

**D14. Test scene notes.** The brief says stub targets with `aggro_range = 0.0`
never chase, but in `stub_enemy_3d.gd` 0 means "chase from anywhere" (the 2D
convention), so the test also puts each target in turn mode, where the stub never
acts on its own. Contact and flight timings are measured by a per-frame health
watcher and compared with a 25 ms tolerance (a `SceneTreeTimer` counts the frame it
was created in, and the watcher looks once per frame). The perfect press is
simulated by calling `_register_counter_press()` during the strike phase, as the
brief asks. The frost-snare recast is tested after a `start_turn` (cooldown 1) so
the refusal comes from the cooldown, not from the spent attack.

## Node paths for WP8 (model swap)

| Path | What the code expects |
| --- | --- |
| `Model` | `Node3D`, keyed by the archetype animations (`Model:scale`), lunged and squashed by tweens; its `position` at `_ready` is the idle position |
| `Model/Body` | optional `MeshInstance3D`; if present its `material_override` is tinted per soul (placeholder only) |
| `HandPoint` | `Node3D` at the right hand (0.34, 0.85, -0.08); created here if the scene has none; also the bolt's start point |
| `HandPoint/EquippedWeaponHolder` | `Node3D` at the hand origin, driven by the animations; created if missing |
| `HandPoint/EquippedWeaponHolder/EquippedWeaponMesh` | `MeshInstance3D`; the item's `grip_offset` / `grip_rotation_deg` go here; a scene-authored mesh is kept, the placeholder blade is added only when the node has no mesh |
| `OverheadAnchor` | bars and the level label are created under it in code (`HealthBars`, `XpAnchor/XpBars`, `LevelLabel`) |
| `VisionLight` | `OmniLight3D`, colour blended per soul |
| `BlockRing`, `AttackAnimations` | created in code; a scene may pre-author them under the same names |

## What the coordinator (WP4) calls differently from 2D

- `try_attack`, `try_ranged_attack` and `try_cast_spell` are coroutines returning
  `bool`, as in 2D, and now refuse out-of-range targets themselves (D2); the
  coordinator may keep its own range popups.
- `set_turn_meter_world_units(1.0)`; spell radii and ranges are metres.
- `set_overhead_ui_visible` hides the health bar, the XP bar and the level tag.
- `is_alive()` is false from the first frame of death and the body is hidden (D6).
- The shift actions (`shift_soul_1..3`, `shift_soul_cycle`), `attack` and `counter`
  are registered in `_ready` exactly as in 2D; `shift_kind_from_event` reads them.
- Popups need `CombatFx.set_world_projector(...)` installed by the level, as WP5
  describes; without it they draw at (0, 0).
