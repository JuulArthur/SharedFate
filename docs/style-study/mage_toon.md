# Style study: cel-shaded toon mage

Branch `feat/3d-style-toon`, 2026-09-26, Blender 4.3.0 and Godot 4.7.2. All geometry, rig, clips and shading are code; nothing is sculpted, painted or downloaded.

## What the style is
Mid-poly smooth-shaded shapes (lathes and lofts: a flared robe with six big folds and an open front over a grey under-robe, a tall hood with a gold-rimmed oval opening and a drooping tip, a scalloped capelet, oversized bell sleeves, a gold sash with hanging tails, a staff with gold claws around a pale emissive crystal), flat saturated colour regions, three hard light bands (shadow, mid, lit) with a cool purple shadow tint, a narrow rim band on the lit side, and a dark ink outline from an inverted hull. The look lives in the shaders: Blender uses Diffuse, Shader to RGB, a constant Color Ramp and an Emission output, with a Solidify outline (flipped normals, black backface-culled material); Godot uses `shaders/3d/toon.gdshader` and `shaders/3d/toon_outline.gdshader` with the same thresholds and colours. The glb carries plain Principled materials; `ToonMaterials3D.apply(model)` swaps in the toon materials by material name.

## Files and numbers
- Renders in `assets/3d/previews/styles/`: `mage_toon_front.png`, `_side.png`, `_back.png`, `_walk.png` (phase 0.25), `_cast.png` (0.62 s, just after the thrust), `mage_toon_iso_godot.png` (windowed Godot, game camera at 8 m zoom instead of the arena's 14 m, arena sun and environment).
- Model `assets/3d/models/styles/mage_toon.glb`: 5,936 triangles (body 5,368, staff 568; the current mage is 648), 14 bones (the 8 of the current mage plus `Hood`, `Sleeve_L/R`, `RobeFront_L/R`, `RobeBack`), height 1.98 m (the crystal reaches 2.12 m), `HandPoint` and `Staff` under the `LowerArm_R` bone attachment, `OverheadAnchor` at 2.23 m. The node names and tree match `mage.glb`, so `SoulBodies3D` finds everything; the staff stands tilted 8 degrees as modelled.
- Skinning is smooth: up to four procedural weights per vertex (skirt blended from `Hips` into the robe bones by height and azimuth, sleeves over upper arm, forearm and bell, hood tip into `Hood`). Rigid skinning would tear the lathe surfaces.
- Clips: `idle` 2.0 s loop, `walk` 1.0 s loop, `cast` 1.0 s one-shot (anticipation to 0.30 s, gather to 0.44 s, thrust to 0.56 s, overshoot to 0.68 s, settle).
- Walk distance: the legs under the robe (`RobeFront_L/R`) swing 18 degrees forward and 8 back, the boots sweep 0.416 m per step, so a cycle covers 0.83 m of ground; matched playback would be 0.83 m/s. At the player's 3.5 m/s with `WALK_REFERENCE_SPEED` 3.5 the feet slide about 76 %, hidden by the hem except the boot tips. A 1.75 m/s reference (2x cadence at 3.5 m/s) is the compromise if it shows.
- Code size (lines): generator 1,352 (1,193 non-blank; about 450 of them are reusable plumbing: toon materials, loft, outline, renders, clip authoring), `toon.gdshader` 57, `toon_outline.gdshader` 39, `toon_materials_3d.gd` 153, view scene script 177, capture script 43.
- Run time: generator about 4 s on a warm Blender (EEVEE shader cache), about 20 s cold; five renders 2 to 17 s of that.
- Checks: `godot --headless --path . res://scenes/3d/tests/styles/mage_toon_view.tscn --quit-after 120` prints `MAGE_TOON OK` (15 surfaces, 15 toon, 15 outlined, 12 distinct materials), no errors; capture with `godot --path . --script res://scripts/3d/tests/styles/mage_toon_capture.gd -- <out.png>`.

## What changed after looking at the renders
Scene shadows were off (a scene made by `scenes.new()` has `eevee.use_shadows` False), so the bands never showed cast shadows; the hood tip was 7 cm too tall; the boots detached from the hem in the walk and cast (bones made vertical, feet moved back, hem weights raised, swing reduced); the cast was first framed from the wrong side and the thrust was timid (deeper lean, staff further forward, bigger flare, near-profile view); the light threshold moved from 0.55 to 0.62 so the vertical robe shows the mid band; the hood opening went from a lat/long cut (square, then stair-stepped oval) to rings built around the opening axis, which gives one clean oval edge; the face moved forward so it reads inside the cavity. In Godot the arena fog greyed the flat colours (toon surfaces now `fog_disabled`), the shadow and rim colours were wrongly sRGB-decoded (now linear, matching Blender), 2 px lines swamped the eyes and hair (materials ending in `_Eye`, `_Hair`, `_Skin` get 1 px), and a preloaded glb plus a material swap made the headless dummy renderer print errors (the view loads at run time).

## Easy and hard
Easy: the toon shaders (under 100 lines, written once), the material swap by name, silhouette-first shapes from lathes, and the outline, which hides the low segment counts. Hard: smooth weights by formula (every part needs a weight rule), keeping the staff upright while the arm moves (it is rigid on the forearm, so its tilt is the sum of three pitches), faceted cuts in smooth meshes, and the triangle count, four times the contract's 1,500 budget.

## Extending it to the cast
Shaders and `ToonMaterials3D` are reused as they are; factor the reusable half of the generator into a `tools/blender/toon_common.py` first (0.5 session).

| Asset | New generator lines | Assistant sessions |
| --- | --- | --- |
| Knight (plate lathes, helm, cape loft, sword, real legs in the walk) | 700 | 1.5 |
| Rogue (hood reused, cloak, leather, daggers) | 600 | 1 to 1.5 |
| Wolf (loft along a spine curve, organic head, four legs, tail) | 650 | 1.5 to 2 |
| Tree (lathe trunk, ellipsoid canopy clusters) | 150 | 0.5 |
| Crate, chest | 100 each | 0.25 each |
| Ground (toon shader on the tiles, no outline) | 30 | 0.25 |

Total about 2,300 new lines and 6 to 7 sessions after the refactor, plus a contract update for the triangle budget and `ToonMaterials3D.apply` calls in `SoulBodies3D` and `Enemy3D` (shared files, not touched here).

## Outline, HitFlash3D and hover
The outline is the `next_pass` of each surface override material, so `material_overlay` stays free: HitFlash3D and the enemy hover rim draw over the body and restore the previous overlay, and the ink line stays dark during a flash, which keeps the silhouette readable. `transfer_weapon` copies the surface overrides, so the player's held staff keeps its toon material and outline. A toon-native hover would recolour or widen the outline instead (`ToonMaterials3D.set_outline_width`); the outline material is shared per `apply` call, so give each actor its own call.

## Cost of the outline pass
Twelve walking mages, windowed, vsync off, this PC: draw calls 540 to 1,080, primitives 89 k to 179 k (the hull also renders into the depth and shadow passes), CPU frame time 0.93 to 1.0 ms without and 1.2 ms with. The mesh is drawn twice; moving the hull to a second `MeshInstance3D` with `cast_shadow` off would cut the shadow share.

## Risks
The inverted hull draws no lines at intersections or creases, gaps at hard edges, and blobs on parts thinner than the line. The arena sun sits 15 degrees from the camera, so the bands show mostly on undersides; the style wants a side key light per level. Ambient and fog are ignored by design, so level mood must come from the light colour or palette. The triangle budget and the smooth-weight rules grow with every asset. Glb triangle order changes between runs (WP12 row 11).

## Verdict
The toon style suits this game best of what a solo developer can produce with code alone: it reads clearly at the isometric size, keeps the 2D game's palette and silhouettes, and puts most of the look in two small shaders that every asset reuses, so the per-asset cost is geometry and poses, not texturing. It costs roughly ten times the lines of the blocky mage's share of `generate_characters.py` and four times the triangles, and the outline doubles draw calls, which a dozen characters absorb easily. I would pick it, with a side key light and a raised triangle budget written into the contract.
