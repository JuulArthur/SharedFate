# Style study: pre-rendered background (approach 2)

Branch `feat/3d-prerender-test`, 2026-09-26, Blender 4.3.0 (Cycles, OptiX on an RTX 3080) and Godot 4.7.2. The aim is the Baldur's Gate 2 look: a detailed, painted scene seen from a fixed angle, with real-time characters walking in it. The method is the one Obsidian described for Pillars of Eternity (Update #79): render the level offline from the game camera with extra passes, then combine it with 3D characters in the engine.

## Files

| What | Where |
| --- | --- |
| Scene generator (Blender, all procedural) | `tools/blender/prerender/crypt_courtyard.py` |
| Painting and light passes | `assets/3d/prerender/crypt/crypt_{color,moon,fire,sigil,albedo}.jpg` |
| Proxy geometry | `assets/3d/prerender/crypt/crypt_proxy.glb` |
| Camera, lights, flames, test spots | `assets/3d/prerender/crypt/crypt_scene.json` |
| Projection shader | `shaders/3d/prerender_projection.gdshader` |
| Flame overlay, mage retint, screen grade | `shaders/3d/prerender_flame.gdshader`, `prerender_dark_mage.gdshader`, `prerender_grade.gdshader` |
| Test scene (playable) | `scenes/3d/tests/styles/prerender_crypt_view.tscn` on `scripts/3d/tests/styles/prerender_crypt_view.gd` |
| Screenshot script | `scripts/3d/tests/styles/prerender_crypt_capture.gd` |
| Screenshots | `assets/3d/previews/styles/prerender_crypt_*.png` |
| Viewable Blender file (not committed) | `blender/crypt_courtyard.blend` |

## The scene

A ruined crypt courtyard at night. At the back stands a chapel wall with a pointed-arch doorway, lancet windows, buttresses, two torn crimson banners and a collapsed stretch with rubble; through the doorway a candlelit sarcophagus shows. In the courtyard: diagonal flagstones with gaps and moss, six gothic pillars (three broken, one fallen), an octagonal dais with a crimson pentagram, runes and an altar with a skull, two iron braziers, candles, a graveyard with a dead tree on the right, low broken walls in the foreground and dead trees behind the wall. Pale blue moonlight comes from the front left, and ground fog lies over everything. The mage is the soft sculpted mage (`mage_soft.glb`), retinted in the shader to a charcoal and oxblood robe, tarnished bronze, ashen skin and a crimson crystal.

## How it works

1. **One render from the game camera.** The Blender camera is orthographic with exactly the axes of `CameraRig3D` (yaw 45, pitch -35); the headless check asserts they match to 1e-4. The render covers 32 x 17.4 m of screen plane at 96 px per metre (3072 x 1670). A Kuwahara filter (anisotropic, 3 px) gives the painted look and a soft glow blooms the fire.
2. **Light groups.** Cycles splits the light into `moon`, `fire` and `sigil` passes, saved at half resolution beside a diffuse colour pass. Lights and emitters carry their group; the world's faint ambient stays in the main image only.
3. **Proxy geometry with a projected texture.** The same meshes, minus flames, fog, grass and candles, are exported as a glb. In Godot every proxy surface computes its screen-plane position (`dot(world - centre, right)`, `dot(world - centre, up)`) and samples the painting there. The camera only translates, never rotates, and the projection is orthographic, so every world point always lands on the pixel that painted it. Occlusion is ordinary depth testing against real geometry: the mage disappears behind a pillar or wall pixel-exactly, stands inside the doorway, and has his legs hidden by the low wall. The camera can follow and zoom freely; it is clamped so it never shows past the edge of the painting.
4. **Light in Godot.** The proxies use a custom `light()`:
   - The moon (the one `DirectionalLight3D`) adds nothing where the proxy is lit. Where a character's shadow falls, it subtracts the moonlight pass (85 %), so the mage's shadow shows on moonlit stone but not in the painted shadows or the brazier glow.
   - Every other light (the spell) adds the diffuse colour pass × the light × the proxy normal, so a cast reddens the painted pillar and floor around the mage.
   - The brazier and sigil lights are on a cull mask that reaches only the mage, because the painting already holds their light on the stone.
5. **Animation on a still painting.** `fire_level` and `sigil_level` scale the fire and sigil passes each frame (noise flicker, slow pulse), in step with the omni lights on the mage. Camera-facing flame quads with a scrolling-noise shader sit on the braziers and candles, the same idea as the Infinity Engine's animated overlays.
6. **One grade for everything.** A screen shader (desaturate 14 %, slight contrast, cool lift, warm gain, vignette) runs over background and mage alike, so the real-time character and the painting share one look. Godot uses the linear tonemapper, matching Blender's Standard view transform, so the painted colours come through unchanged.

## Numbers

- Render: 9 min 38 s at 96 px/m and 192 samples with OptiX denoising (the fog volume is most of it); the preview mode (40 px/m, 64 samples) takes 73 s. Building and exporting without rendering takes 1.7 s.
- Assets: painting 489 KB, passes 515 KB (JPEG), proxy glb 3.8 MB with 26 meshes. The painting is imported lossless with mipmaps (`detect_3d/compress_to=0`), 20 to 27 MB of video memory with mipmaps (RGB8 or RGBA8).
- Navigation: baked at start from the proxies' colliders (cell 0.1 m, agent radius 0.4 m), 555 polygons; paths from the spawn to the doorway (15.0 m), behind the wall (19.9 m), behind the low wall (9.1 m) and onto the dais (6.3 m).
- Code: generator 1,408 lines, view script 606, projection shader 73, the other three shaders 127 together, capture script 78.
- Checks: `godot --headless --path . res://scenes/3d/tests/styles/prerender_crypt_view.tscn --quit-after 2000` prints `PRERENDER OK` (texture sizes against the json, camera axes, four navigation paths, six view rays: hidden behind the pillar, the low wall at hip height and the chapel wall; visible in the doorway, in front of the pillar and at the spawn). Screenshots: `godot --path . --resolution 1600x900 --script res://scripts/3d/tests/styles/prerender_crypt_capture.gd -- <out_dir>`. The arena acceptance test still prints `INTEGRATION OK`.

Regenerate:

```powershell
blender --background --factory-startup --python tools/blender/prerender/crypt_courtyard.py -- --root . --ppm 96 --samples 192
blender --background --factory-startup --python tools/blender/prerender/crypt_courtyard.py -- --root . --preview   # quick look, *_preview.jpg
```

## Controls in the test scene

Left click walks, C or right click casts, 1 to 8 jump to the test spots (spawn, in front of and behind a pillar, behind the low wall, on the dais, in the doorway, behind the wall, by a brazier), the wheel zooms between 5 and 17.4 m, V shows the proxy geometry.

## What looks good, what does not

- Good: the scene reads as one painted place, with light, shadow and fog no real-time scene of this cost would have. Occlusion is exact, and the mage's shadow, the flicker and the spell light make the mage look like he is in the painting, not pasted on top of it.
- The mage is the weak part: the chibi, vinyl-toy proportions of the soft mage clash with the painted realism. A dark fantasy cast needs taller, more realistic proportions and textured cloth to match.
- Softness when zoomed in: at 96 px/m the painting is sharp at the game's 14 m zoom on 1080p (64 px/m on screen) but soft at 5.5 m or on a 4K screen. 128 to 160 px/m would fix it: about 1.8 to 2.8 times the render time and a 4096 to 5120 px wide image.
- Seams: at silhouettes a pixel or two of the neighbouring surface can show, because the painting's antialiasing blends edges while the proxy edge is exact. It is barely visible here and only matters on thin objects in front of bright ones.
- The fog is subtle; it can be pushed further in the generator (`mat_fog` density).

## Costs and risks

- Every change to a level means a re-render (10 minutes here on this GPU; large levels are split into tiles). Layout iteration should happen at preview quality.
- Proxies must match the render exactly; the generator guarantees that by exporting the same meshes. Hand-painted additions (like the touch-ups Beamdog painted over its new renders) can only go on surfaces that exist in the proxy.
- Only one camera angle per level. Zooming is limited by texture resolution and the edge of the painting.
- Dynamic light on the painting is approximate: diffuse colour × proxy normal, with no fine normals or speculars. A normal pass would add detail for spells.
- Characters need a lighting rig that matches the painting per level (moon direction and colour, fire positions); the json carries it.
- Headless Godot cannot render, so the visual check is the windowed capture script.

## Verdict

The approach works in Godot with the game's existing camera: real 3D characters in a painted Cycles scene, with exact occlusion, matching shadows and living light, at almost no runtime cost (one texture lookup per background pixel). It gets closer to the Baldur's Gate 2 look than anything real-time we have tried. The price is in the pipeline: every level becomes a Blender scene plus a render step, and the characters must be brought up to the painting's level of detail. A next test would be a realistic dark fantasy mage model and a render at 128 px/m.
