# WP5 deviations - overlays and feel

Package: WP5, branch `feat/3d-wp5`, base commit `afeee19`. Contract:
`docs/3d-port-contracts.md`, sections 1, 2, 5.1, 7, 11 and 12. Everything below is
a decision taken while implementing; the lead folds what it wants into the
contracts document.

## Verification

| Command | Exit | Note |
| --- | --- | --- |
| `--import` | 0 | |
| `--check-only --script res://scripts/combat_fx.gd` | 0 | |
| `--check-only` on the five overlay scripts | 0 | |
| `--check-only --script res://scripts/3d/tests/overlays_test.gd` | **1** | see D1 |
| `res://scenes/3d/tests/overlays_test.tscn --quit-after 120` | 0 | prints `OVERLAYS OK` |
| `res://scenes/main.tscn --quit-after 120` | 0 | no `SCRIPT ERROR` lines, see D8 |

## Deviations

**D1. `--check-only --script` cannot see autoloads.** The test script calls
`CombatFx.set_world_projector(...)` as section 7 prescribes, and the check exits 1
with `Compile Error: Identifier not found: CombatFx`. This is the check command,
not the script: the pre-existing 2D `scripts/enemy.gd` fails in exactly the same
way, because autoload singletons are only registered once a SceneTree starts. The
five overlay scripts deliberately reference no autoload, so they check clean; the
test is verified by running the scene instead. Do not "fix" this by reaching for
`get_node("/root/CombatFx")` - the 2D game calls the singleton directly and WP4
should too.

**D2. One cast inside `CombatFx.flash`.** Widening `item` to `Node` makes
`item.self_modulate = color` a compile error, so that one line became
`(item as CanvasItem).self_modulate = color` behind an `if not (item is
CanvasItem)` branch. Every other line of the function is untouched, and the
`Node`-typed `item` still works for `create_tween` and `tween_property`.

**D3. `ring_burst` in 3D draws on the FX CanvasLayer, not under `parent`.** A
`Node3D` cannot parent a `Sprite2D`, so the projected branch ignores `parent` and
adds the ring to `CombatFxLayer` at the projected screen point, with the same
texture, radii, flatten and tween. The screen point is taken once at spawn: the
burst lasts 0.35 s, and following the camera for that long costs a per-frame
update for no visible gain. If a burst ever needs to stick to a moving world
point, give it the popup treatment (an entry in `_popups`-style per-frame list).

**D4. Screen-space overlays are scaled by 3.35.** `CounterPrompt3D`,
`OverheadBars3D` and the `PathPreview3D` label draw in screen pixels, while their
2D originals are `Node2D`s seen through a camera at `main.gd CAMERA_ZOOM = 3.35`.
Each file has a `SCREEN_SCALE := 3.35` constant that multiplies the 2D pixel
sizes, so the overlays read at their 2D size. Colours, phase durations and the
label wording are unchanged. If WP2 settles on a different perceived scale, that
one constant is the knob.

**D5. `OverheadBars3D` colours are exports, not a second method.** `CombatFx` has
no bar constants to reuse - the 2D geometry (28x4 px), colours and the dark
background live in `player.gd` and `enemy.gd` - so they are copied into the script
with a comment, and the two animation timings come from `CombatFx.animate_bar`
(0.12 s fill; 0.28 s delay then 0.32 s ghost). Fill and ghost colours are
`@export`s (player green by default, enemy red set in the scene) so the public API
stays exactly `set_ratio` and `set_visible_bars`.

**D6. `PathPreview3D` has no glow strip.** The 2D preview draws a wide faint
`Line2D` under the thin one; section 7 asks for a two-colour polyline, so only the
line is ported. The split between the in-budget and the beyond part is
`GroundMath.trim_path(points, remaining_m)`, and the two strips share the split
point so they meet without a gap. `used_m` only feeds the label, as in 2D.

**D7. CanvasLayer per overlay node, layers 5 and 3.** `CounterPrompt3D` uses layer
5 as section 7 says. `OverheadBars3D` and the `PathPreview3D` label use layer 3, so
`CombatFx` popups (layer 4) are never hidden behind a health bar. Each node owns
its own `CanvasLayer`; with a handful of actors on screen that is cheap, but if a
level ever fields dozens of enemies WP4 should pool one layer and hand it to the
overlays.

**D8. Two pre-existing errors in the 2D run.** `scenes/main.tscn` prints
`Node not found: "../MyCustomObjects"` and a `NavigationServer` map query warning
from `enemy.gd:478` during `_ready`. Both come from 2D-only code paths, neither is
a `SCRIPT ERROR`, and WP5 touches neither.

**D9. `HitFlash3D` is not in the section 7 table.** It is in the WP5 brief and in
section 5.1 as the `flash_hit()` effect. Suggest adding a row:
`HitFlash3D` (`scripts/3d/hit_flash_3d.gd`) - `flash(color, duration)` as a child
of the body, or `HitFlash3D.flash_node(body, color, duration)` statically. It
restores whatever `material_overlay` a mesh already had when the flash ends, so it
composes with an outline or highlight overlay.

**D10. Clearing the adapters.** `set_world_projector(Callable())` and
`set_shake_target(null)` put `CombatFx` back into its 2D behaviour;
`set_shake_target(null)` also sends one final `Vector2.ZERO` to the old callable so
a camera rig does not keep the last offset. A 3D level must clear both in
`_exit_tree`, because the autoload outlives the scene - the test scene does this
and WP4 must copy it, otherwise returning to the 2D game leaves popups projected
through a freed camera.

## How WP4 and WP8 parent the overlays

| Node | Parent | Notes |
| --- | --- | --- |
| `RangeRing3D` | the `Player` body (melee, throw, spell rings), the hovered enemy for a blast radius | local origin, follows the body; `show_ring(range_m, colour, dashed)` mirrors the 2D calls in `main.gd` |
| `CounterPrompt3D` | the enemy's `OverheadAnchor`, one per enemy | `enemy_3d.gd` creates it in `_ready` like `enemy.gd` does, and drives the same four phases |
| `PathPreview3D` | the level root, one per level, owned by the coordinator | `show_path` takes global points |
| `OverheadBars3D` | each actor's `OverheadAnchor` | set `fill_color` / `ghost_color` on enemies; wire `set_visible_bars` to `set_overhead_ui_visible` |
| `HitFlash3D` | each actor body, as a child called from the body's `flash_hit()` | or no child at all and `HitFlash3D.flash_node(self)` from `flash_hit()` |

`main_3d.gd` (WP4) installs the adapters once the camera exists:
`CombatFx.set_world_projector(func(p: Variant) -> Vector2: return camera.unproject_position(p as Vector3))`
and `CombatFx.set_shake_target(<camera rig>.set_shake_offset)`, and clears both in
`_exit_tree`. `scripts/3d/tests/overlays_test.gd` is the worked example.
