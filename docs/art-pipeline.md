# Art pipeline: the look, maps and characters

How The Bound Three should look, and the process for making maps and characters that look that way. It is built on two tests that worked:

- the pre-rendered crypt: `docs/style-study/prerender_crypt.md`, scene `scenes/3d/tests/styles/prerender_crypt_view.tscn`;
- the realistic dark mage: `docs/style-study/mage_dark.md`.

Reference boards for people and for Claude Design are in `docs/design-brief/`.

Status, 2026-09-26: the method is proven in a test scene. The playable levels (`scenes/3d/wilds.tscn`, `scenes/3d/arena.tscn`) are still real-time geometry. Section 6 lists what is missing before a pre-rendered map can be a game level.

## 1. The look in one paragraph

Baldur's Gate 2 at night, in a darker key. Each map is one painted scene, rendered offline in Blender from the game camera, detailed and softly lit, with fog, and it never moves. Characters are real-time 3D models walking inside that painting: walls and pillars hide them, the moon casts their shadows on it, and their magic lights it up. The mood is dark fantasy, meaning ruins, graves, ritual and decay, and three kinds of light tell the story:

| Light | Colour | Meaning |
| --- | --- | --- |
| Moon | cool blue | the world outside, cold |
| Fire | warm orange | shelter, the living |
| Magic | crimson | danger, ritual, the souls |

Everything else stays muted, worn and dark. Saturated colour is kept for light, magic and the gameplay signals.

## 2. Fixed numbers

These are not style choices. The pipeline depends on them.

| Item | Value | Why |
| --- | --- | --- |
| Units | 1 unit = 1 m, +Y up (Godot), +Z up (Blender), ground at 0 | `docs/3d-port-contracts.md`, section 2 |
| Camera | orthographic, yaw 45°, pitch -35°, never rotates | a painting is only valid from one direction |
| Default view | 14 m of view height, zoom 5 to 17.4 m | `CameraRig3D`; the painting limits the zoom |
| Render density | 96 px per metre of screen today, 128 recommended | sharp at 14 m on 1080p; 128 for close zoom and 4K |
| Character height | about 1.9 m (1.95 m with a hood) | about 125 px at 14 m on a 900 px screen |
| Screen-plane axes | u = screen right, v = away from the viewer | author layouts in (u, v); see section 4.2 |
| Floor | walkable tops at y = 0 (the dais steps are 0.12 and 0.25 m) | characters stand on y = 0 |
| Character budget | up to about 15,000 triangles for heroes (dark mage: 13,970) | recommendation, not yet measured with a full party |
| Colour management | Blender "Standard" view transform, Godot linear tonemapper | the painting comes through unchanged |

## 3. Palette

The values come from the generators and the UI code. The board is `docs/design-brief/images/02_palette.png`.

- **World:** flagstone `#34362F` to `#5A5A51`, wall stone `#5E5B52`, mortar `#1D1C19`, moss `#1F2A18`, soil `#2C271F`, night void `#030304`. Light: moon `#99B2FF`, fire `#FF8033` with core `#FFF1B0`, sigil `#FF1A0A`.
- **Characters:** robe charcoal `#2B272C`, oxblood `#4A151A`, tarnished embroidery `#6B5836`, ashen skin `#8C8078`, bone `#B9AD90`, leather `#3D2C20`, crimson glow `#FF2A14`.
- **Interface** (the story book, `scripts/3d/story_book_3d.gd`): leather `#0E0A0A`, iron `#3D3B38`, parchment `#B59E78`, ink `#1A0F0D`, ember ink `#C7290F`, heat `#FFCC6B`, blood `#660D0A`.
- **Gameplay signals** (keep saturated): knight `#94BDFF`, rogue `#8CED99`, mage `#CC9EFF`, damage taken `#FF5C5C`, heal `#8CF299`, and the element colours in `scripts/3d/abilities/ability_catalog_3d.gd`.

Rules:

- One strong accent per map: crimson for the crypt, for example. Everything else is desaturated stone, earth and cloth.
- Keep deep darks, but never let a walkable area go fully black. A character must stay readable on it; the mage's rim light helps.
- Fire and magic may clip to white in the render. Stone and cloth may not.

## 4. Making a map

### 4.1 Plan the gameplay first, on paper

Before any Blender work, mark:

- the walkable area;
- blockers (walls, rubble, trees);
- occluders: tall things in front of walkable ground. These are what make the painted look work, and they also hide the player, so use them on purpose;
- entrances;
- fight spaces: at least 6 m across, for the 6 m turn move;
- points of interest and light sources.

Draw it in screen-aligned coordinates (u right, v away). A rectangle in (u, v) is a rectangle on screen, as in Baldur's Gate's maps.

Size on screen: a map W m wide in u and D m deep in v covers about W x (0.57 D + 5) m of screen. That is W x 96 px wide at today's density. One image should stay under about 8,000 px wide (about 80 m of u); larger maps need tiles (section 6).

### 4.2 Build the scene generator

Start from `tools/blender/prerender/crypt_courtyard.py`. Copy it to `tools/blender/prerender/<map>.py` and replace its `build_*` functions. Keep:

- the helpers (`P(u, v, z)`, `frame_uv`, `wall`, `prism`, `tube`, `lathe`, `rock`), the material builder `NT` and the camera, export, compositor and render sections;
- the collections and names, which Godot relies on:

| Collection | Contents | Exported to the proxy glb? |
| --- | --- | --- |
| `Proxy` | everything a character can stand on, walk behind or bump into | yes |
| `RenderOnly` | flames, fog, grass, candles, pebbles, far background, emissive details | no |
| `Cutters` | boolean cutters for doors and windows (`hide_render`) | no |
| `Lights` | sun (moon), point lights | no, but written to the json |

- the name prefixes: `Walk_` for floors (the navmesh and click picking use them), `Occ_` for other proxies and `Fx_` for render-only.
- the light groups: `moon` for the key light (the characters' shadows subtract it), `fire` for flickering sources, and one more group per animated effect (the crypt uses `sigil`). Put every emitter and light that should animate in a group, and set `obj.lightgroup`.
- the json fields, which Godot reads: camera, `moon`, `fire_lights`, `flames`, `candles`, `spots`, `walk_rect_uv`. Add a named spot for every test you want to repeat.

Rules for the geometry:

- The proxies *are* the render meshes. Never simplify them separately, or silhouettes drift off the painting.
- Walkable tops at y = 0; steps no higher than 0.25 m (the navmesh climbs 0.3 m).
- Keep thin, small or transparent things render-only: they show in the painting but cannot occlude or block.
- Occluders need real thickness. Anything a character should vanish behind must be taller than about 1 m and in front of walkable ground.
- Paint detail with materials (noise, brick, Voronoi cracks) rather than geometry, and keep the geometry for silhouettes.

### 4.3 Look at it, cheaply, many times

```powershell
blender --background --factory-startup --python tools/blender/prerender/<map>.py -- --root . --preview
```

This is 40 px/m and 64 samples, about 70 seconds on this PC's RTX 3080. It writes `*_preview.jpg` beside the real files. Judge composition, light and readability here, and change the generator, not the render.

Review questions:

- Does every walkable area read against its surroundings?
- Is there one clear focal point, and does the light lead to it?
- Do the three kinds of light stay separate?
- Is anything important hidden behind an occluder with no way to see it?

### 4.4 Export and check the proxies in Godot

```powershell
blender --background --factory-startup --python tools/blender/prerender/<map>.py -- --root . --ppm 96 --no-render
```

This writes the proxy glb and the json in two seconds. Point a copy of the crypt view scene at the new data, then run it headless. It must print its OK line after checking:

- that the texture sizes match the json;
- that the camera axes match `CameraRig3D`;
- the paths to every spot;
- the view rays: spots behind occluders are hidden, the others visible.

### 4.5 Final render

```powershell
blender --background --factory-startup --python tools/blender/prerender/<map>.py -- --root . --ppm 96 --samples 192
```

This took 9 minutes 38 seconds for the crypt. Then fix the Godot import once for each new texture in its `.import` file: `mipmaps/generate=true` and `detect_3d/compress_to=0`. Without mipmaps the painting shimmers when the camera moves; with compression it goes blocky.

### 4.6 Review in Godot, windowed

```powershell
godot --path . --resolution 1600x900 --script res://scripts/3d/tests/styles/prerender_crypt_capture.gd -- <out_dir> [shot,shot]
```

Check, with a character at every spot:

- occlusion edges (no fringes wider than a pixel or two);
- the character's shadow on moonlit and on shadowed ground;
- flicker, and spell light on the painting;
- the camera clamp at the map edges;
- readability at 14 m zoom.

## 5. Making a character

### 5.1 Design rules

- **Silhouette first.** At the game camera a character is about 125 px tall. The shapes that carry it are the head or hood, the shoulders, the hem and the weapon. Test with a flat black fill.
- **Three values:** a dark body, one mid tone, one light accent (the dark mage: charcoal, oxblood, the pale beard).
- **One saturated accent**, and it should glow or catch light (the mage's crimson crystal and eyes). It also ties the character to a soul colour or a faction.
- **Adult proportions,** head about 1/7.5 of the height. The toy proportions of the early studies do not sit in a painted world.
- **Wear and damage:** torn hems, tarnish, stains. Nothing looks new.
- **Clearance:** parts that move apart need at least 3 cm of gap in the rest pose (a sleeve and the robe, a hand and a pouch). The voxel fusion joins anything closer, and it tears when the limb moves.

### 5.2 The generator

Start from `tools/blender/mage_styles/mage_dark.py`: parts, fuse, paint, weights, rig, clips, export. Keep:

- **Conventions** as in `docs/3d-port-contracts.md`, section 10: facing Blender +Y, origin at the feet, the right hand at +X.
- **Names** that `SoulBodies3D` and the scenes rely on: `<Name>_Body`, `HandPoint`, `OverheadAnchor` and the weapon object (`Staff`, `Sword` or the daggers).
- **The 13-bone rig and the clip names** `idle`, `walk`, `cast` (or the attack clip the actor needs).
- **Separate emissive materials** for anything that should pulse or flare (`Mage_Glow`, `Mage_Gem`).

Watch the numbers it prints on every run:

| Line | Target |
| --- | --- |
| `SF_DARK_GAP` | every gap at least 0.03 m |
| `SF_DARK_DEFORM` | walk p99 at most 2, action clips p99 at most 4 |
| `SF_DARK_WALK` | ground per cycle; the game sets `speed_scale` = move speed / that distance |
| `SF_DARK_MODEL` | triangle counts and height |

### 5.3 Import into Godot

- Write `<name>_cloth.tres` (and one for each other vertex-coloured material) with `vertex_color_use_as_albedo = true`, and map it in the glb's `.import` file under `_subresources/materials`. Godot 4.7.2 ignores the vertex colours of the first vertex-coloured surface otherwise.
- The style-study glbs carry no loop flags. Loop `idle` and `walk` at run time, as the crypt view does, or set the loop mode in the import.
- Review the character in the crypt scene (swap `MAGE_GLB`): idle by the braziers, walking behind the low wall, casting in front of a pillar.

## 6. Before a pre-rendered map can be a game level

What the crypt test does not do yet, roughly in order:

1. **A shared library.** Move the reusable half of `crypt_courtyard.py` into `tools/blender/prerender/prerender_common.py` and the Godot side into a `PrerenderBackground3D` node (proxy loading, projection material, light rig, flame overlays, camera clamp) that any level can instance.
2. **Level contract.** A pre-rendered level still needs the nodes of `docs/3d-port-contracts.md`, section 9. The proxies go under `NavigationRegion3D` with `Walk_` meshes on layer 1 and `Occ_` meshes on layer 8. The painting's moon becomes `Sun`, the navmesh is baked offline, and `main_3d.gd` runs it unchanged.
3. **Tiles for large maps.** The Wilds (104 x 104 m) would be about 14,000 px wide at 96 px/m. Render it as tiles (one camera offset per tile, same axes), and give each proxy mesh its tile's texture, or split the projection by screen position.
4. **Enemies, props that move, doors and loot** are real-time, like the characters. Anything that changes during play (a door that opens, a bridge that falls) must be a real-time model or a second painted state.
5. **Hand painting.** Optional: paint over `crypt_color.jpg` in an image editor. Only surfaces that exist in the proxy can take it, and every re-render overwrites it.

## 7. Working with Claude Design

Claude Design is for mockups: HUD, menus, inventory, dialogue and the story book, plus layout and colour exploration for maps. It is not for final game art. The brief, the instructions and the reference boards are in `docs/design-brief/README.md`.

When a mockup is agreed, share its link. Claude Code can read Claude Design projects once `/design-login` has been run in an interactive `claude` session on this PC. Otherwise, export the files into the repository. Agreed tokens (colours, fonts, spacing) then go into this document and into the game's theme.

## 8. Sources

- Obsidian Entertainment, *Pillars of Eternity* Update #79, "Graphics and Rendering": pre-rendered backgrounds with depth, normal and albedo passes behind 3D characters. https://eternity.obsidian.net/eternity/news/update--79-graphics-and-rendering-
- Game Developer, "To build a new Baldur's Gate, Beamdog had to reverse-engineer the original": the original assets were lost, and the Enhanced Edition re-rendered and hand-painted its new areas. https://www.gamedeveloper.com/production/to-build-a-new-i-baldur-s-gate-i-beamdog-had-to-reverse-engineer-the-original
