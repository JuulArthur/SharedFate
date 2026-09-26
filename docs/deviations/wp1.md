# WP1 "Assets" - deviations log

Branch `feat/3d-wp1`, written 2026-09-20. Referenced sections are from
`docs/3d-port-contracts.md`. Everything here is a decision taken while
implementing; the lead folds what should stick into the contracts document.

## 1. Blender was driven from the command line, not through the MCP add-on

The work package says to build the models through `mcp__blender__*`. The MCP
add-on was not reachable at any point in the session: `get_addon_status`
returned "Could not connect to Blender" and TCP 127.0.0.1:9876 was closed, while
`blender.exe` 4.3.0 was running (the add-on's server had not been started in the
UI, which needs a click in Blender's sidebar).

The models were therefore generated with

    blender --background --factory-startup --python tools/blender/<generator>.py -- --root <repo>

The user's open `untitled.blend` was never opened, modified or saved, and
`bpy.ops.wm.save_mainfile` is not called anywhere in the new scripts.

The socket path is still supported and was verified: each generator was also run
by exec-ing its text in a fresh namespace with no `__file__` and with `SF_DIR` /
`SF_ROOT` pre-set, which is exactly what `execute_blender_code` does. The file
headers document that call.

## 2. `bpy.context.temp_override(scene=...)` crashes the glTF exporter

First implementation exported inside
`bpy.context.temp_override(scene=assets_scene(), view_layer=...)`. Blender 4.3.0
dies with `EXCEPTION_ACCESS_VIOLATION` in `BKE_base_eval_flags` reached from
`CTX_data_ensure_evaluated_depsgraph` as soon as the exporter asks for the
evaluated depsgraph (`export_apply=True`): the override changes the context
scene but leaves the view layer pointing into the old scene.

`sf_assets_common.enter_assets_scene()` assigns `bpy.context.window.scene`
instead, checks that `bpy.context.scene` really changed, and restores the
previous scene afterwards. This works in `--background` too - Blender still has
a window there - and it is what the MCP add-on path uses as well.

## 3. Prop collision children use `-colonly`, not `-col`

The package asks for a child mesh named `<Name>-col`. Measured in Godot 4.7.2:
`-col` keeps the box as a **second visible `MeshInstance3D`** and strips the
suffix, so the collision box takes the prop's own node name (the tree imported
as `Tree` plus a second mesh also called `Tree`, 108 triangles instead of 96).

The colliders are therefore named `<Name>_Col-colonly`, which imports as a
`StaticBody3D` named `<Name>_Col` with a `ConcavePolygonShape3D` and no extra
mesh. Section 10 of the contracts says `<Name>_col`; the actual Godot suffixes
are `-col` / `-colonly`, so that line needs fixing too.

## 4. Weapon axis convention

Every weapon is a separate object whose **origin is the grip** and whose blade or
shaft runs along **local +Z in Blender = local +Y in Godot** after the
`export_yup=True` conversion. A weapon dropped into
`EquippedWeaponHolder` with an identity transform therefore points straight up
out of the fist; WP3b rotates from there.

In the exported characters the `Sword`, `Dagger_L` and `Dagger_R` nodes carry a
180 degree rotation about X so the blades hang point-down at rest; the `Staff`
is upright with its ferrule 0.02 m above the ground.

## 5. Character body meshes are `<Name>_Body`, the glb root is `<Name>`

Godot names the instanced root after the glTF scene, which the Blender exporter
takes from the Blender scene name. Left alone, every model imported with the
root called `SharedFate_Assets`. `export_glb()` now renames the assets scene to
the model name for the duration of the export.

Because Godot renames a child that clashes with its parent (root `Knight` plus a
mesh `Knight` gave `Knight2`), the main mesh object of every model is
`<Name>_Body`. Imported tree, for example:

    Knight (Node3D)
      Knight_Body (MeshInstance3D)
      Knight_Cape (MeshInstance3D)
      Sword (MeshInstance3D)
      HandPoint (Node3D)
      OverheadAnchor (Node3D)

Material names are unchanged and follow `<Character>_<Part>`.

## 6. The three characters cannot hold an empty named `HandPoint` at once

Blender object names are unique per file. Each character is exported and
previewed immediately after it is assembled, and its two empties are then
renamed to `<Character>_HandPoint` / `<Character>_OverheadAnchor` so the next
character can use the plain names. The `.glb` files contain `HandPoint` and
`OverheadAnchor`; only the Blender session carries the prefixed names.

## 7. `OverheadAnchor` on the wolf sits above the ears, not above the back

Spec: 0.20 m above the back. The ear tips reach 0.725 m, higher than the back
line at 0.60 m, so an anchor at 0.80 m would sit 0.075 m above the ears and a
health bar would clip them. The anchor is 0.20 m above the highest point of the
mesh, at y = 0.925. The characters follow the spec exactly: 0.25 m above the top
of the head.

## 8. `ground_tile.glb` holds both variants as two root objects

"Two grass-green material variants" is exported as one file with
`GroundTile_A` (`GroundTile_GrassA`, `#4E7A3C`) at x = -1 and `GroundTile_B`
(`GroundTile_GrassB`, `#5F8A46`) at x = +1, edge to edge. WP7 instances the glb
and keeps the child it wants, or reuses the two meshes directly. The tile's top
face is at y = 0 and it is 0.10 m thick, so its AABB starts at y = -0.10; the
gallery's "stands on y = 0" check only applies to characters.

## 9. Triangle counts include the cape only after Solidify

`export_apply=True` bakes the cape's Solidify modifier, so the knight leaves
Blender at 888 triangles and arrives in Godot at 988. Without the cape the
knight is 832 (body 772 + sword 60), well under the 1,500 limit. Rogue 720,
mage 612, wolf 312 (limit 800).

## 10. Sizes that are "about" rather than exact

| Model | Asked | Built |
| --- | --- | --- |
| crate | 0.8 m | 0.80 m box, 0.855 m across the corner posts and rails |
| chest | 0.9 m wide | 0.94 x 0.62 x 0.752 m including the plinth and iron bands |
| tree | 4 to 6 m | 4.65 m, canopy 2.56 m across |
| wolf | 1.1 m long, 0.7 m tall | 1.154 m long, 0.725 m at the ears |
| knight / rogue / mage | about 1.9 m | 1.995 / 1.890 / 1.925 m |

## 11. `build_knight_v0.py` deleted

Its palette, bmesh helpers, collection handling and preview rig moved into
`tools/blender/sf_assets_common.py`; the knight itself moved into
`generate_characters.py` and now faces +Y instead of -Y. No `.blend` file is
committed - the generators are the source. The `blender/knight_lowpoly.blend`
that the old script wrote is untracked and was left alone.

## 12. Informational Blender message

Every glTF export prints `ERROR Draco mesh compression is not available ...`.
This is the io_scene_gltf2 add-on reporting a missing optional DLL in this
Blender install; Draco is not enabled, the export succeeds, and the `.glb` files
are uncompressed as intended.
