# Style study: pixel-textured low poly (mage)

Low-poly geometry wrapped in one small pixel-art atlas: 128 x 64 texels, 25 colours (the `SoulArt.MAGE_*` palette, `Soul.COLOR_MAGE` for the crystal, `SoulArt.OUTLINE` for the outline), nearest filtering, 32 texels per metre on every surface. Robe folds, the grey under-robe, trims, the gold hem diamonds, the face, the hair and the staff runes are drawn into the texture. Geometry only carries the silhouette. A 1 cm inverted hull gives the dark outline of the 2D sprites. Everything comes from `tools/blender/mage_styles/mage_pixel.py`, which draws every texel with code. No texel is painted by hand.

## Output

| Item | Value |
| --- | --- |
| Model | `assets/3d/models/styles/mage_pixel.glb` (311 KB, mostly animation keys; atlas embedded), atlas `mage_pixel_atlas.png` (975 bytes) |
| Renders (`assets/3d/previews/styles/`) | `mage_pixel_front.png`, `_side`, `_back`, `_walk` (mid-stride), `_cast` (thrust), `_iso` (game camera, game pixel density), `_iso_pixelated` (half-resolution render, 2x nearest upscale) |
| Triangles | 2,154: body 1,818 + staff 336, of which 1,077 are the outline hull (909 + 168). 1,077 without the outline. |
| Rig | 14 bones: the WP11 mage bones (`Hips`, `Spine`, `Head`, `UpperArm_L/R`, `LowerArm_L/R`, `Robe`), hidden `Leg_L` / `Leg_R` that plant the boots, and `RobeFront_L/R` / `RobeBack_L/R`. The front bones follow a leg only when it swings forward, the back bones only when it swings back, so the knee and heel push the cloth instead of pulling it. Skinning is smooth on the skirt (`Robe` plus the push bones, at most 5 influences), rigid everywhere else. `HandPoint` and `Staff` are on `LowerArm_R`, and `OverheadAnchor` is on the armature at 2.235 m. Height 1.985 m, feet at 0. The staff forearm is bent forward, so the hand sits 0.26 m ahead of the body. |
| Clips | `idle` 2.0 s loop, `walk` 1.0 s loop, `cast` 1.0 s one-shot (raise over the shoulder, gather with a tremble, thrust, hold, recover to rest) |
| Walk distance | 1.40 m per cycle: the planted sole sweeps 0.84 m back over the 0.6 s stance (measured on the posed rig; planted sole height and speed error 0.0 mm). Reference speed 1.40 m/s, so at the player's 3.5 m/s the clip must play at 2.5x, or the peeking feet slide. |
| Generator | 1,543 lines, about 190 of them blank. About 950 are reusable (atlas packer, mesh builder with UVs and weights, PNG writer, clip authoring, walk and stretch measurements, renders) and about 590 are mage-specific (painters 250, geometry and weights 150, poses 130, assembly). A full run takes 2.8 s including seven renders and the `.blend`. The atlas, glb and renders are byte-identical between runs. |
| Texel stretch | The worst length change of a textured skirt edge is 1.2 % in idle, 21.7 % in walk and 7.7 % in cast (`SF_PIXEL_STRETCH`). Everything else is rigid, so its texels never stretch. |
| Godot | `scenes/3d/tests/styles/mage_pixel_view.tscn` prints `MAGE_PIXEL OK`. The same file also drops into `SoulBodies3D` unchanged: body, hand, `Staff`, anchor and clips are all found. |

Texture filter: the Blender image node uses `Closest`, so the exporter writes a glTF sampler with mag `NEAREST` and min `NEAREST_MIPMAP_NEAREST`. Godot's importer turns that into `TEXTURE_FILTER_NEAREST_WITH_MIPMAPS` without any override. `mage_pixel.glb.import` sets `gltf/embedded_image_handling=3` (embed uncompressed), so the atlas stays lossless RGB8 and VRAM compression cannot smear the palette. The same file also sets `loop_mode` 1 on `idle` and `walk`.

Lighting: lightly lit (Lambert, roughness 1, flat shading). The texture holds only shading that does not depend on the light direction: occlusion under the sash, the mantle and the hood, fold lines, and the hem shadow. The engine's sun adds the directional light, so the shading stays right as the mage turns through 360 degrees. Flat faces quantise that light into bands, much as pixel shading does. An unlit material would freeze one light direction into the texture that is wrong half the time, and it would not match the lit props.

## What I changed after looking at the renders

The eyes merged into the hood-shadow band, so I added a fringe and forehead row between them. The staff read as black (dark wood plus outline), so the wood is now a lighter grey. The 50 % checker dithers on the hood, the torso and the lower skirt looked like noise once they were on a curved surface, so each is now a single transition row, and the broken fold dashes became continuous folds. I also made these fixes:
- The upper sleeve poked through the mantle: the sleeve now starts lower and the mantle is wider.
- The boot looked like a loose brick and dipped under the floor: it is now darker, smaller and flat.
- The diagonal fold pattern on the back of the hood read as a stray staircase, so I removed it.
- The sash's bright stripe became glints.
- The front preview moved to the free-hand side (-35 degrees), because from the staff side the shaft covers the face.
- A walk contact sheet showed the hem swallowing the ferrule at heel strike. The pull now fades toward the sides, the skirt twists less, and the staff leans 6 degrees forward and 6 degrees out (about 7 cm of clearance at rest).
- A stretch measurement then showed 52 % shear at the front of the hem, where both legs pulled the cloth in opposite directions. The push-only robe bones and a smaller pull brought it down to 21.7 %.
- The iso mage turns to -140 degrees, so the crystal is clear of the face.
- The pixelated iso was rendered at twice the intended scale. Fixed.

## Easy and hard

Easy: UVs come for free because the generator makes them. Lathe columns follow the angle, rows follow the profile, and each part gets its own atlas rectangle sized from its surface. Painting in palette keys, with the face as eight rows of text like `SoulArt`, makes a feature a one-line edit. At 3 s per run, looking and fixing is quick. Godot needed no material work.

Hard: texel design on curved, tapered surfaces. Texels are 2 cm wide at the sash and 3.1 cm at the hem, and the face spans three facets that flat shading gives three tones. Dithering reads as noise in 3D. Robe and staff clearance, and the shear of the skirt texels, only showed up in contact sheets and a measurement, not in the single previews. The outline has a world-space width: 3-4 px in the close previews but about 0.6 px in game. The renders are the only quality check, and faces need zoomed crops to judge.

## Extending to the cast

Plan one session to move the reusable 950 lines into `tools/blender/sf_pixel_common.py`, with a box unwrap that gives each face its own rectangle. Then, per asset:

| Asset | New generator lines | Sessions | Notes |
| --- | --- | --- | --- |
| Knight | 450-550 | 1 | plates, rivets, visor slit and a cape in the texture; visible legs reuse the WP11 walk; a sword swing for the attack |
| Rogue | 400-500 | 1 | leather, belts, hood shadow, two daggers |
| Wolf | 350-450 | 1 | fur bands and a muzzle on box parts; the WP12 trot rig carries over |
| Tree | 150-200 | 0.5 | trunk lathe and bark; canopy blobs with a leaf-cluster pattern |
| Crate and chest | 80-120 each | 0.5 for both | plank, nail and iron-band textures on boxes |
| Ground tiles | 100-150 | 0.5 | a tileable 64 x 64 grass texture per 2 m tile (the same 32 texels per metre), plus 2-3 variants against visible repeats |

Total: about 2,500-3,000 new lines and 6-7 sessions, plus about one session of look-and-fix across the set.

## Next to the 2D sprites

The palette is the same and the outline colour is `SoulArt.OUTLINE`, so the mage is clearly the 2D mage. The pixel scale is not the same. At the game camera (14 m tall on 900 px) one texel is about 2 screen pixels, while a 2D sprite pixel is 3.35. Mixed on one screen (for example the pickup billboards, which are 2D icons), the 3D pixels look about 40 % finer. Matching exactly would need about 20 texels per metre, which leaves the face 5 texels wide, or a camera zoomed in to about 8.4 m. The pickup billboards themselves fit this style better than any smooth-shaded look would.

## Risks

- Texture swimming: with nearest sampling at about 2 px per texel, texel edges jump by a pixel as the mage moves and turns. The mipmapped nearest filter only helps when zoomed out. `_iso_pixelated` shows the worst case, one texel per pixel: the staff breaks up and the outline turns to dots. A low-resolution render pipeline would need texels of at least 2 low-resolution pixels.
- Readability at distance: at the default zoom the mage is about 125 px tall. The hem diamonds, trims, sash and crystal read, but the eyes are 2 px. Zooming the camera out quickly turns the face into mush.
- Animation pixel crawl: rigid parts carry their texels cleanly. The smoothly skinned hem stretches texels by up to 21.7 % at the knee push in the walk, and the diamond band shears slightly there. The world-space outline shimmers below 1 px. A Godot screen-space outline shader (a `next_pass` with constant pixel width) would fix that and save the 1,077 hull triangles.

## Verdict

This style fits Shared Fate well. In the game camera it reads as the 2D mage made solid, costs about 2,000 triangles and one 1 KB texture, and it is fully code-generated, deterministic and quick to iterate. Hidden legs and push bones make a robed walk readable, and the cast costs only about 60 lines of key poses. The cost per asset is mostly art direction in code (a painter per part), not tooling, and most of the tooling carries over. Adopt it if the 3D game should keep the 2D identity, on three conditions. First, fix one texel density for the whole world (32 per metre). Second, keep the camera close enough that a texel is at least 2 px. Third, move the outline into a Godot shader before building the full cast.
