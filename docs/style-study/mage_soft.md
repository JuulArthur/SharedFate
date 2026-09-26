# Style study: soft sculpted mage

Branch `feat/3d-style-soft`. Generator `tools/blender/mage_styles/mage_soft.py`, model `assets/3d/models/styles/mage_soft.glb`, test `scenes/3d/tests/styles/mage_soft_view.tscn` (`MAGE_SOFT OK`).

## The style

Rounded, continuous forms with a vinyl-toy feel: a big deep hood with a pointed tip, a large head and mitten hands, a flared robe with soft vertical folds and a wavy hem, a gold sash with a knot and ribbon tails, and bead eyes. Shading is smooth; colour is baked into vertex colours (palette, painted fold depth, a height gradient, ray-cast ambient occlusion). Materials are matte (roughness 0.74; gold 0.38, metallic 0.55) with Godot's soft rim on. Identity kept from the current mage: purple robe with a grey underrobe, lavender trims, hood, gold sash, grey staff with a pale lavender crystal (`Soul.COLOR_MAGE`).

Renders (`assets/3d/previews/styles/`): `mage_soft_front.png`, `_side`, `_back`, `_walk` (0.25 s), `_cast` (0.70 s, thrust), `_iso` (game camera, orthographic, yaw 45, pitch -35, 64 px/m as in game at 1600 x 900; the mage is about a quarter of the frame height).

## Numbers

- Triangles in Godot: body 7,996 (2 surfaces), staff 1,272 (3 surfaces), total 9,268. The baseline mage is 648.
- Height 1.95 m (staff tip 2.03 m), origin at the feet, facing -Z; `HandPoint` (0.313, 1.170, -0.248) on `LowerArm_R`; `OverheadAnchor` at 2.20 m.
- Bones: the WP11 eight plus `RobeFront_L/R`, `RobeBack` (hem swing) and root bones `Foot_L/R` (feet under the hem, not on `Hips`, so a planted foot ignores the hip bob). 13 in total.
- Clips: `idle` 2.0 s, `walk` 1.0 s, `cast` 1.0 s (raise 0.30, gather 0.52, thrust 0.68 to 0.82, back to rest at 1.0).
- Walk distance: the planted foot sweeps 0.443 m per step, **0.886 m per cycle**, so the clip matches 0.89 m/s. At the player's 3.5 m/s it would need `speed_scale` 3.95 (a scurry); at the current 3.5 m/s reference the hidden feet slide instead.
- Generator: 1,389 lines (about 1,110 excluding comments and blank lines). Run time 10.4 s on this PC (body 6.8 s, six EEVEE renders about 3.5 s). Deterministic: two runs print identical counts (the glTF exporter still orders triangles differently per process, WP12 row 11).

## How it is made

Parts: the robe, cowl and sash are lathe surfaces; folds are a sum of three cosines around the robe with depth rising toward the hem; the grey front opening is an inset region. The hood is a deformed sphere with its opening removed, given thickness by Solidify. Arms and hair are Skin modifier skeletons with Subdivision Surface. Face, hands, feet and knot are ellipsoids. Everything is joined, voxel remeshed at 8 mm (231,000 triangles), smoothed, decimated to 7,800 and smoothed again. Colour edges are painted on the fine mesh first and get weight 0 in the Decimate vertex group, so they keep their density. Every final vertex takes the colour of the nearest source part.

Skinning: computed weights, not heat weights: distance along each arm chain with smoothstep blends at the shoulder and elbow (the elbow on the bisector plane); height and angle on the robe (Spine, Hips, `Robe`, then three hem bones by angle); head parts on `Head` fading into `Spine` at the neck; feet rigid. Then three passes of graph smoothing and a limit of four influences. The gaps that keep sleeves, hands and feet free of the skirt are checked on every run (`SF_SOFT_GAP`: sleeve 27 mm, hand 116 mm, feet 50 mm, voxel 8 mm). The generator prints edge stretch per checked frame: walk p99 1.5, cast p99 1.5 to 1.8; the worst edges are the hidden robe underside (walk) and the right armpit under the cowl with the arm raised 125 degrees (cast, 6x). No twist is keyed on the arm bones, so there is no candy-wrapper collapse. In the renders the elbow extension of the thrust and the raised shoulder hold their shape.

## Easy and hard

- Easy: silhouettes and folds (a lathe plus a fold function); fusing parts (one voxel remesh); colour, AO and fold paint as vertex colours (no UVs, no textures); every operator applied as an evaluated mesh, so `--background` needs no context tricks except `mode_set` for the armature.
- Hard: small features. Eyes under about 2 cm do not survive remesh and decimation, so they are separate bead islands. Decimation raggedness at colour edges needed the vertex-group fix and still leaves slightly wavy trims and small gold drips under the sash. Weights: a continuous mesh needs a weight formula per region, and each new character needs its own. A long staff rigid in the fist limits the cast (no wrist bone, because the game's weapon follows `HandPoint` on the forearm).
- Godot 4.7.2 issue: the importer left `vertex_color_use_as_albedo` off on the first vertex-coloured surface of the mesh, whatever the material (tested by swapping the order), so the cloth would render white. Fix: `mage_soft.glb.import` maps `Mage_Cloth` and `Mage_Gold` to `mage_soft_cloth.tres` / `mage_soft_gold.tres` (vertex colour as albedo, roughness, rim). Every model in this style needs the same import settings; the view test fails if a vertex-coloured surface ignores its colours.

## Extending to the cast (estimates)

A shared library first (lathe, skin tubes, fuse and boundary decimate, paint and AO, weight smoothing, rig and clip authoring, renders): about 450 lines, 1 session. Then, per asset, generator lines on top of that library and assistant sessions:

| Asset | Lines | Sessions | Notes |
| --- | --- | --- | --- |
| Knight in armour | 900-1,300 | 2-3 | Hard surface is the weak spot: a voxel remesh rounds every plate into clay. Plates must stay separate rigid pieces (bevelled, not fused) over a soft body, which is closer to the blocky pipeline plus bevels; weights at hips and knees under armour are the hard part. |
| Rogue | 600-800 | 1-2 | Reuses hood, cloak and cloth. Visible legs need knee and hip formulas like the arms. |
| Wolf | 500-700 | 1-2 | Skin modifier along spine, neck, tail and four legs suits it; fur as soft clumps. |
| Tree | 200-350 | 0.5 | Skin trunk and branches, blobby canopy of fused ellipsoids, colour by height. |
| Crate, chest | 150-250 each | 0.25 each | Bevel modifier, rounded toy boxes; no remesh needed. |
| Ground | 100-200 | 0.25 | Rounded tiles or a soft noise sheet with vertex colours. |

## Performance in Godot

Estimated, not measured (headless Godot does not render): a dozen characters at about 9,300 triangles is about 110,000 triangles and 5 draw calls each (60, doubled for the shadow pass), with 4,000 skinned vertices each. That is light for any desktop GPU; Godot also generates LODs on import, which the distant iso camera will use. The runtime cost is ten times the blocky mage but still small; the real cost is authoring time.

## Risks

Per-character weight formulas; the vertex-colour import workaround must travel with every model; readability at 64 px/m relies on silhouette and big colour blocks (fine detail, AO and folds mostly vanish in the iso view); the walk speed mismatch; hard-surface characters do not fit the pipeline; Blender and Godot version changes to Skin, Remesh, Decimate or the glTF importer.

## Verdict

The soft sculpted style reads well at the isometric size: a clean purple hooded silhouette, a pale face, a gold sash and a glowing crystal, with far more charm than the stacked boxes, and a fully procedural generator runs in about ten seconds. It suits cloth-and-creature characters (mage, rogue, wolf) and organic props, and costs roughly two to three times the blocky pipeline in generator code and a session or two per character, mostly spent on weights and small features. Its weak spot is hard surface: the armoured knight would need a mixed approach (rigid bevelled plates over a soft body), and the whole cast then has to be judged for consistency. I would pick it if the owner accepts that the knight is a hybrid; if the cast is to be armour-heavy, a bevelled low-poly style is cheaper.
