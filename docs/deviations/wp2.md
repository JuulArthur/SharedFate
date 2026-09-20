# WP2 deviations: camera and picking

Branch `feat/3d-wp2`, written 2026-09-20. Contract: `docs/3d-port-contracts.md`,
sections 2 (camera row), 3, 6, 11 and 12. Everything below is a deviation from,
or an addition to, that text; the lead should fold the relevant rows back in.

## 1. `focus_between` takes a default blend

Section 6 lists `focus_between(a: Node3D, b: Node3D, blend: float)`. The rig
declares `blend: float = CAMERA_ENEMY_FOCUS_BLEND` (0.6, the 2D value). Callers
that pass three arguments are unaffected; the default only spares WP4 from
repeating the constant.

## 2. Two methods beyond the contract table

- `set_shake_offset(offset: Vector2)` - the method form of the `shake_offset`
  property, so the WP5 adapter can do
  `CombatFx.set_shake_target(Callable(rig, "set_shake_offset"))` instead of
  wrapping the property in a lambda. The property stays and is the contract.
- `snap_to_target()` - drops the camera on its target this frame instead of
  lerping. It is the 3D counterpart of `main.gd`'s `_center_camera()` on level
  load and after a teleport; without it the camera sails across the map.

## 3. The rig builds a Camera3D if the scene has none

`scenes/3d/camera_rig_3d.tscn` carries the `Camera3D` child the contract
requires. If the script is put on a bare `Node3D`, `_ready` creates the child
rather than failing, so a hand-built level cannot half-work.

## 4. The look-at point rides 1.0 m above the ground

`LOOK_AT_HEIGHT` = 1.0 m, the same value the WP0 arena skeleton used. Looking at
the feet would push the actor into the upper half of the frame; 1 m reproduces
the 2D framing, which centred on the sprite. Not in the contract text.

## 5. The self-check cannot assert the literal ground tolerance

The brief asks the test to unproject the enemy's `OverheadAnchor`, feed that one
screen point to both `pick_enemy` and `pick_ground`, and require the ground hit
within 1.0 m of the enemy's ground position. That is geometrically impossible:
at pitch -35 degrees a ray through a point `h` metres up meets the ground
`h / tan(35 deg)` = 1.43 `h` metres behind the feet. With the 1.3 m anchor of the
stub enemy that is 1.86 m, and the test measures exactly 1.86 m. Shrinking the
anchor to fit would be a lie about where an overhead anchor sits.

`scripts/3d/tests/camera_picking_test.gd` therefore splits the assertion and
gates `CAMERA_PICKING OK` on six checks:

1. `pick_enemy` at the anchor screen point returns the enemy (as briefed; the
   ray still enters the body box, so this is a direct hit).
2. `pick_ground` at the same screen point is non-null and within 1.0 m of where
   that camera ray crosses the ground plane (the tolerance applied to the point
   the ray can actually reach).
3. `pick_ground` at the screen point of the enemy's feet is within 1.0 m of the
   enemy's ground position (the briefed 1.0 m assertion, at the point where it
   holds).
4. `pick_enemy` 0.5 m beside the body, where the ray misses the collider,
   returns the enemy through the 0.6 m forgiveness fallback.
5. `pick_enemy` 1.6 m beside the body returns null.
6. `pick_pickup` returns the layer 3 area of the test pickup.

The measured parallax is printed on the info line so the coordinator can see it.

## 6. The headless viewport is 1600x1600, not 1600x900

The brief says headless keeps the project's 1600x900 viewport. Measured with
`get_viewport().get_visible_rect().size` in this scene on Godot 4.7.2 headless it
is 1600x1600: the headless display server reports a square window. Projection and
unprojection stay consistent with each other, so picking round-trips and the test
passes, but a headless test that asserts absolute pixel coordinates (WP5 overlay
placement) must read the viewport size instead of assuming 900 px of height.

## 7. The test scene adds a pickup area

`scenes/3d/tests/camera_picking_test.tscn` copies the WP0 arena layout and adds a
`TestPickup` node with a `PickupArea` (`Area3D`, layer 3, mask 0, monitoring off)
so `pick_pickup` is exercised before WP6 exists. Nothing in that subtree has an
`is_available` method, so the picker returns the area itself - the documented
fallback. Once `ItemPickup3D` lands, the same call returns the pickup root.

## 8. `pick_enemy` reaches the scene tree through the camera

`WorldPicker` is static and holds no state, so the forgiveness fallback
enumerates group `enemies` with `camera.get_tree()`. The camera is the only node
the function is handed. It is reached only after `pick_ground` succeeded, which
already proves the camera is inside a tree.

## 9. Near and far planes

`CAMERA_NEAR` = 0.05, `CAMERA_FAR` = 200.0 on a 30 m boom, so a 6 m prop standing
on the focus point lies between roughly 25 m and 35 m of view depth and is never
clipped. The contract fixes the boom and the angles but not the planes.
