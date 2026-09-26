# WP9 "Bodies per soul": deviations log

Package: WP9, branch `feat/3d-wp9`, based on `780b239`. Written 2026-09-25.
Contract: `docs/3d-port-contracts.md`, sections 2, 5.2, 7, 10, 11, 12. The lead folds accepted rows into the contract's deviations table.

Files created: `scripts/3d/soul_bodies_3d.gd` (`class_name SoulBodies3D`, plus `.uid`), this file.
Files edited: `scenes/3d/player_3d.tscn` (`Model` subtree and `OverheadAnchor` only), `scripts/3d/player_3d.gd` (body visuals, weapon holder, shift effect only), `scripts/3d/tests/player_test.gd`, `scripts/3d/tests/arena_integration_smoke.gd` (assertions in `_step_models` only).
Files deleted: `scripts/3d/knight_visual_3d.gd` and its `.uid`.
No movement, pursuit, approach, navigation or turn code in `player_3d.gd` was touched.

## How the swap works

- `Player/Model` carries `soul_bodies_3d.gd` and the three glb instances `Knight`, `Rogue` and `Mage`, authored in the scene (rogue and mage saved hidden). `_ready` records each body's `HandPoint`, `OverheadAnchor` and held weapon (`Sword`, `Dagger_R`, `Staff`) through the local transform chain, hides the held weapon in every model and shows the initial soul. Inactive bodies are `visible = false` and `PROCESS_MODE_DISABLED`; nothing loads on a shift.
- `Player3D._apply_soul_visual` (at `_ready` and on every `shift_to`) calls `SoulBodies3D.show_soul(kind)`, sets `HandPoint.transform` to the body's hand at rest (`get_hand_transform()`), sets `OverheadAnchor.position.y` to `get_overhead_height()`, and refreshes `EquippedWeaponMesh`: the soul's weapon mesh and material overrides are copied onto it (`SoulBodies3D.transfer_weapon`, the WP8 hand-over generalised) and its transform is `get_weapon_fit()`. The vision light blend is unchanged.
- Public API on `SoulBodies3D`: `show_soul(kind) -> bool`, `get_hand_point() -> Node3D`, `get_hand_transform() -> Transform3D`, `get_overhead_height() -> float`, `get_weapon_meshes() -> Array[MeshInstance3D]` (held weapon first, then the rogue's `Dagger_L`), `get_held_weapon_mesh()`, `get_weapon_fit()`, `get_active_body()`, `get_active_kind()`, `get_body(kind)`, `punch_active_body()`, static `transfer_weapon(source, target)`. `Player3D.soul_bodies` is the typed reference (null when `Model` is a placeholder; the WP3b fallback path then runs unchanged).
- Shift effect: `_play_shift_fx` keeps the ring burst, the flash and the title popup, and replaces the `Model` squash (0.82 / 1.16 over 0.26 s) with `punch_active_body()`: the new body scales from 0.85 to its rest scale over 0.15 s (`TRANS_BACK`, ease out). The punch sits on the body node, so `Model:scale` stays owned by the archetype animations and attack tweens; a second shift inside 0.15 s kills the tween and resets the previous body.

Measured values (player space): hand knight (0.335, 0.86, -0.08), rogue (0.265, 0.83, -0.06), mage (0.245, 0.92, -0.06); `OverheadAnchor` 2.245 / 2.140 / 2.140 m (0.25 m over the `<Name>_Body` tops 1.995 / 1.890 / 1.890 m).

## Deviations and decisions

| # | Area | Deviation | Why | Action for the lead |
| --- | --- | --- | --- | --- |
| 1 | Held weapon (5.2) | The soul decides the mesh in the hand, the equipped `Item` only decides whether it is shown (unarmed hides it), plus damage, range and the attack archetype. An equipped dagger as the knight shows the knight's sword; the Iron Sword as the mage shows the staff. | Brief: simplification until items carry meshes. | See "Mapping items to meshes" below. |
| 2 | Grip fit (5.2) | With the soul bodies the item's `grip_offset` / `grip_rotation_deg` are no longer applied. The fit is per soul: the glb's own hang of the weapon under its `HandPoint` (180 degrees about X for `Sword` and `Dagger_R`, identity for the upright `Staff`), then a per-soul tilt and offset exported on `SoulBodies3D` (knight -25 degrees and 0.06 m up, rogue -20 degrees and 0.03 m up: the Iron Sword's and the Dagger's 2D grip values; mage none). The knight's sword therefore sits exactly as in WP8 (the smoke still measures y 0.14..1.04 m from a hand at 0.86 m). | The grip belongs to the mesh; applying the sword's -25 degree tilt to the staff would lean it forward. `WEAPON_HANG_ROTATION_DEG` plus the item grip stay as the fallback for a `Model` that is not a `SoulBodies3D`. | Fold into 5.2. |
| 3 | Attack animations | No change to `melee_slash`, `cast_staff` or `ranged_bow`. The holder turns about the hand's local X only, so every weapon stays in the forward/up plane; the new test samples all three animations per soul and asserts the weapon axis never goes sideways (local X component under 0.1), blades keep pointing down and the staff up (for the staff, `cast_staff` tilts the head forward and raises it 0.18 m; `melee_slash` swings its head from 40 degrees forward to 52 degrees back). A mutation run with the staff flipped failed as expected. | Brief item 3. | None. |
| 4 | Hand and anchor | `HandPoint` and `OverheadAnchor` stay children of the player and are moved, not re-parented, so the animation paths `HandPoint/EquippedWeaponHolder:*` and the bars under the anchor keep working. Consequence (unchanged from WP8): the hand does not follow the `Model` lunge, recoil or the shift punch. The hand transform is the body's rest pose, so a shift during a punch or an attack tween never measures a scaled hand. | Brief allows either; moving keeps every existing path. | None. |
| 5 | `OverheadAnchor` height | The scene value is now 2.245 m (the knight glb's anchor), not 2.25 m; the anchor follows the body (2.245 / 2.140 / 2.140 m). The integration smoke's `PLAYER_ANCHOR_HEIGHT_M` became 2.245 with a 0.01 m tolerance. | The anchor comes from the model, as WP1 authored it. | Update section 5.2 / wp8 row 1 (2.25 m). |
| 6 | Popups | Player3D's own popup anchors (`POPUP_HEIGHT_M` 2.1, `_HIGH_M` 2.4, `_TOP_M` 2.7 above the feet) stay fixed; they clear all three heads (1.89 to 1.995 m). The coordinator's popups already anchor to `OverheadAnchor` and follow the body. | Those constants live in the damage, reaction and XP functions that are outside this package's files. | Optional: derive them from `OverheadAnchor` in a later package. |
| 7 | Mage height | The brief lists the mage at 1.925 m; that is the gallery AABB including the staff. The body mesh is 1.890 m and the glb's `OverheadAnchor` sits at 2.140 m. The test measures the head from `<Name>_Body`. | The staff is in the hand, not on the head. | None. |
| 8 | Off-hand dagger | The rogue's `Dagger_L` stays visible in the model even when no weapon is equipped (only `EquippedWeaponMesh` hides). It is not animated. | Brief: left visible in the left hand. | Hide it with the weapon if unarmed should read empty-handed. |
| 9 | Placeholder tint | The `Model/Body` tint code, `PLACEHOLDER_BODY_COLOR`, `PLACEHOLDER_SOUL_TINT` and `_body_material` are removed from `player_3d.gd`. | `Model/Body` is gone since WP8; brief says not to reintroduce a tint. | Drop the `Model/Body` row from the WP3b node-path table. |
| 10 | Integration smoke | `_step_models` now also asserts the `Rogue_Body` and `Mage_Body` meshes exist, that the knight is active and its body the visible one, and takes the held weapon from `SoulBodies3D.get_held_weapon_mesh()` instead of `find_child("Sword")`. The sword-span assertion itself is unchanged (the knight is the active soul at that step). | Brief item 6. | None. |
| 11 | Docs outside this package | `docs/3d-arena.md` still says the knight is the body for all three souls and names `knight_visual_3d.gd` (sections "What is placeholder" and "Regenerating"); section 10 of the contracts should add `Dagger_R` / `Staff` to the node names the scenes rely on. | Not in this package's files. | Update both at merge: `scripts/3d/soul_bodies_3d.gd` needs `Sword`, `Dagger_R`, `Dagger_L`, `Staff`, `HandPoint`, `OverheadAnchor` and the `<Name>_Body` meshes. |

## Mapping items to meshes (for a later package)

- Give `Item` (or a 3D-side table keyed by `Item.id`) a mesh reference: a `PackedScene` or `Mesh` with the WP1 convention (origin at the grip, blade along local +Y), plus a 3D grip fit (`Transform3D`, or tilt and offset in metres) to replace the 2D `grip_offset` / `grip_rotation_deg`.
- In `Player3D._refresh_weapon_visual(weapon)`, prefer the item's mesh and fit when the item has one, and fall back to `soul_bodies.get_held_weapon_mesh()` / `get_weapon_fit()` otherwise. `SoulBodies3D.transfer_weapon` already copies a mesh and its material overrides onto `EquippedWeaponMesh`.
- Decide per soul what happens to the model's own weapons: an item mesh in the right hand should keep the glb weapon hidden (already the case) and probably hide off-hand weapons like `Dagger_L` for two-handed items. `get_weapon_meshes()` lists them.
- Archetypes need no change: they key the holder, so any mesh following the axis convention swings correctly. Extend the `_check_weapon_axis` test in `player_test.gd` to the item meshes.

## Verification record (2026-09-25, Godot 4.7.2, worktree `.claude/worktrees/wp9`)

| Command | Exit | Result |
| --- | --- | --- |
| `--import` | 0 | no errors; `soul_bodies_3d.gd.uid` generated |
| `--check-only --script res://scripts/3d/soul_bodies_3d.gd` | 0 | clean (`player_3d.gd` and the tests name `CombatFx` and are proven by their scene runs, section 11) |
| `res://scenes/3d/tests/player_test.tscn --quit-after 900` | 0 | `PLAYER OK`; per soul: hand 0.000 m off, anchor 2.245 / 2.140 / 2.140 m over a 1.995 / 1.890 / 1.890 m head |
| `res://scenes/3d/arena.tscn --quit-after 1200` | 0 | `INTEGRATION OK`; every step `ok`; sword spans y 0.14..1.04 m from a hand at 0.86 m (as WP8) |
| `main3d_stub_arena`, `actor_base_test`, `camera_picking_test`, `overlays_test`, `pickup_test`, `enemy_test`, `asset_gallery` | 0 | `SMOKE OK`, `ACTOR_BASE OK`, `CAMERA_PICKING OK`, `OVERLAYS OK`, `PICKUP OK`, `ENEMY OK`, `ASSET_GALLERY OK` |
| `res://scenes/3d/arena_skeleton.tscn --quit-after 120` | 0 | no output, no errors |
| `res://scenes/main.tscn --quit-after 60` | 0 | 2D game runs; only the two pre-existing 2D messages (`Node not found: "../MyCustomObjects"`, `NavigationServer` query before the first map sync) |
| `git diff --stat 780b239 -- scenes scripts` | - | only the WP9 files listed above |
| `git diff --stat 2d-baseline -- scenes scripts` | - | only `3d` paths plus `combat_fx.gd`, `loot_dropper.gd`, `loot_menu.gd`, `level_loader.gd` (unchanged since WP8) |
