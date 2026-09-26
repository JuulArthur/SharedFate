# Style study: realistic dark fantasy mage

Branch `feat/3d-dark-mage`, 2026-09-26, Blender 4.3.0 and Godot 4.7.2. It follows the pre-rendered background test (`docs/style-study/prerender_crypt.md`), where the soft mage's toy proportions clashed with the painted crypt. Generator `tools/blender/mage_styles/mage_dark.py`, model `assets/3d/models/styles/mage_dark.glb`, shown in `scenes/3d/tests/styles/prerender_crypt_view.tscn`.

## The figure

A tall, stooped necromancer-like mage, 1.95 m to the tip of the hood (the body under it is about 1.86 m), with the head about 1/7.5 of the height and long arms. The soft mage's head is about a quarter of its height.

- **Head:** a deep pointed hood whose brim overhangs the face. The face is gaunt and ashen, with sunken eyes and cheeks painted darker, a brow ridge, a nose, a long grey beard to mid-chest, and two small crimson glowing eyes (their own emissive material `Mage_Glow`).
- **Clothing:** a charcoal robe with deep folds and a hem torn into tongues, dragging slightly at the back. Down the front opening it shows an oxblood under-robe edged with tarnished embroidery. A ragged mantle covers the shoulders and upper arms, and the sleeves are bell-shaped.
- **Belt:** leather, slung low, with a tarnished buckle, a pouch at the back, a small book chained at the right hip and a bone charm at the right front. Worn boots show under the hem when he walks.
- **Staff:** gnarled black wood, 2.12 m to the crystal tip. Four roots curl into a claw around a long crimson crystal (`Mage_Gem`, emissive), with a bone band under the claw and two bone charms on thongs.

Renders in `assets/3d/previews/styles/`: `mage_dark_front.png`, `_side`, `_back`, `_walk` (phase 0.25), `_cast` (0.70 s). In the crypt: `prerender_crypt_*.png`.

## Numbers

- Triangles: body 12,158 (three surfaces: `Mage_Cloth`, `Mage_Metal`, `Mage_Glow`), staff 1,812. Total 13,970, about 1.5 times the soft mage.
- glb 538 KB. `HandPoint` at (0.245, 0.268, 1.279) in Blender (Godot (0.245, 1.279, -0.268)) on `LowerArm_R`. `OverheadAnchor` at 2.20 m.
- Bones: the soft mage's 13 with the same names (`Hips`, `Spine`, `Head`, arms, `Robe`, `RobeFront_L/R`, `RobeBack`, `Foot_L/R`), so anything written for it plays here.
- Clips: `idle` 2.0 s (a slight stoop, a slow head turn), `walk` 1.0 s, `cast` 1.0 s (raise 0.30, gather 0.52, thrust 0.68 to 0.82). One walk cycle covers 1.002 m (stride 0.52 m per step), so the clip matches 1.0 m/s. The test scene walks at 1.5 m/s with `speed_scale` 1.5.
- Edge stretch against the rest mesh:

  | Clip and frame | p99 | max |
  | --- | --- | --- |
  | Walk | 1.7 to 1.8 | 4.2 to 4.9 |
  | Cast, arm raised (frames 18 and 31) | 3.6 to 3.8 | 15 to 16 |
  | Cast, recovery (frame 42) | 2.3 | 13.6 |

  The cast's worst edges are where the front of the mantle meets the raised right forearm. They are not visible in the renders, but they are twice the soft mage's p99.
- Generator: 17.6 s, of which the body takes 7.8 s. The rest is rig, clips, checks and five renders.

## What changed after looking at the renders

- **First run:** the left sleeve touched the robe at the hip (a 2 mm gap), so the voxel remesh fused them, and the robe tore (stretch up to 30) when the arm lifted in the cast. The left arm moved out 5 cm and the cuff narrowed (gap 33 mm).
- **The pouch:** next the pouch on the left hip touched the hanging hand. The pouch moved to the back and the book to the right hip.
- **The armpit:** the right upper arm sat inside the robe's chest. The chest was narrowed and the elbows widened, which halved the cast's worst stretch.
- **The face:** it came out pale and flat and stood clear of the hood. It moved back 18 mm, the brim was pushed half again as far forward, and the skin darkened. Its occlusion is kept strong (factor 0.7) so it reads as a face in shadow.

## Godot notes

- `mage_dark.glb.import` maps `Mage_Cloth` and `Mage_Metal` to `mage_dark_cloth.tres` and `mage_dark_metal.tres` (vertex colour as albedo, rim light on the cloth). This is the importer workaround from the soft mage study: Godot 4.7.2 ignores the vertex colours of the first vertex-coloured surface otherwise.
- The style-study glbs carry no loop flags, so the crypt view sets `idle` and `walk` to loop at run time. Without this, a walk longer than one clip would stop on its last frame.
- In the crypt view the dark mage keeps its own materials. Only the glowing eye and crystal materials are duplicated, so they can pulse with the sigil and flare during a cast. The retint shader is still used if `MAGE_GLB` is set back to the soft mage.

## Easy and hard

- **Easy:** most of the pipeline carried over from the soft mage unchanged: fusion, painting, the weight formulas, the rig and the cast keys. The dark palette and the torn edges are simple functions: the `tatter` tongues on the hem and mantle, and value-noise wear on the cloth.
- **Hard:** keeping clearance. Adult proportions put the arms close to the body, and every touching part fuses in the voxel remesh and then tears when the arm moves. The generator prints the gaps (`SF_DARK_GAP`) and the stretch (`SF_DARK_DEFORM`) on every run for that reason.
- **At game scale:** the small features (eyes, beard texture, the book, the charms) are only a few pixels at the game's 14 m zoom, so the figure has to read through its silhouette (pointed hood, mantle, torn hem, staff) and a few value accents (the pale beard, the oxblood strip, the crimson crystal).

## Risks

- Hard surfaces and tight clothing would suffer from fusion more than robes do.
- The mantle's weights are a compromise: it rides the spine with 55 % of the upper arm over each shoulder, and a raised arm still pushes through the front edge.
- A dark figure on a dark painting relies on the rim light and on the key lights of each level. Without the braziers he goes close to a silhouette, which suits the mood but not a busy fight.

## Verdict

At the crypt's scale this mage belongs in the painting: the silhouette, palette and proportions match the architecture, and the glowing crystal and eyes carry him in the dark. The cost is a 13,970-triangle character (fine for a party and a handful of enemies) and a generator that needs its clearance checks watched. The same approach should carry the rogue. The knight needs rigid plates rather than fused cloth, as the soft mage study already warned.
