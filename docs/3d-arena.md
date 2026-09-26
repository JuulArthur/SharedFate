# The 3D arena: how to run it

The game's main scene is the Wilds, `scenes/3d/wilds.tscn` (since 2026-09-26, gameplay expansion): a 104 x 104 m forest with five camps and the Grave Warden, described in `docs/wilds-map.md`. The small test slice is `scenes/3d/arena.tscn`: one clearing ringed by trees, the knight with the three souls, three wolves, a crate and a chest, on the same coordinator `scripts/3d/main_3d.gd`; the acceptance test runs there. The original 2D game stays in the repository, untouched, as reference.

## Open and run

1. Install Godot 4.7.2 (the version `project.godot` declares; an older editor rewrites scene files). On this PC it is the winget build under `%LOCALAPPDATA%\Microsoft\WinGet\Packages\GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe\`.
2. Open the repository's `project.godot` in the editor and let the first import finish.
3. Press F5 (Run Project); it opens the arena. To look at the old 2D hub, open `scenes/main.tscn` and press F6 (Run Current Scene).

Headless check of the whole slice (prints `INTEGRATION OK`):

```powershell
$godot = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe\Godot_v4.7.2-stable_win64_console.exe"
& $godot --headless --path . res://scenes/3d/arena.tscn --quit-after 1200
```

The `IntegrationSmoke` node in the arena drives that check. It only runs headless, or with the user argument `-- --integration-smoke`, so F5 and F6 play normally.

### The intro book

The arena opens with the prologue from the 2D game (`StoryLibrary.PROLOGUE`, same text) in the 3D story book, `scripts/3d/story_book_3d.gd` (`StoryBook3D`, created by the coordinator; the 2D `StoryBook` autoload is not used by 3D levels). The paused arena shows blurred and darkened behind a black leather book with iron corners, embers rise from below, and the words burn in ember-red on scorched parchment and cool to ink (`scripts/3d/ember_ink_effect.gd`). Each page is read aloud: a recording when one exists, else the system voice (lower and slower than in 2D). Recordings go in `assets/3d/audio/narration/` as `<chapter id>_<page, two digits>.ogg`, for example `prologue_01.ogg` for the first page; `.wav` and `.mp3` work too, `.m4a` does not (Godot cannot import it). Click or Space hurries the ink and turns the page; Esc closes the book. It opens once per session.

To test without it:

| Want | How |
| --- | --- |
| No intro | untick **Intro > Intro Enabled** on the `Arena` root, or run with the user argument `-- --no-intro` (in the editor: Debug > Customize Run Instances, so the scene file stays unchanged) |
| Book, but silent | untick **Intro > Intro Voice Enabled**, or `-- --silent-intro` |
| No narration on a level | leave **Story Chapter Id** empty |

Headless runs always skip the intro; the acceptance test opens the book itself.

## Controls

| Input | Exploration | Turn combat |
| --- | --- | --- |
| Left click on the ground | walk there | spend movement (path preview shows the 6 m budget) |
| Left click on a wolf | walk up and attack, or the aimed throw / spell (see below) | melee, or the aimed throw / spell |
| Left click on a dropped item | open the loot panel (walks over if far) | same |
| Space | sword sweep | end the turn |
| 1 / 2 / 3, Q | shift to knight / rogue / mage, cycle | one shift per turn (two after a perfect reaction) |
| F | - | counter during the wolf's strike: block, parry or ward, by soul |
| I | inventory screen | same |
| 4 to 9 | aim or fire the ability bar's abilities (the soul in control's learned ones) | same; each costs the turn's action or its bonus action (marked `+`) |
| C | sneak on / off | - |
| K | skill tree (pauses the world) | same |
| Left click on a barrel, waystone or chest | strike the barrel; walk over and use the waystone or chest | strike the barrel |
| Esc | close a panel, close the story book, drop an ability aim | same |

### Abilities, stealth and levels (gameplay expansion)

Rules and balance: `docs/gameplay-expansion.md` (interfaces) and `scripts/3d/abilities/ability_catalog_3d.gd` (every number). In short:

- A turn is movement (knight 6 m, rogue 8 m, mage 5 m), one action (melee, throw, spell or an action ability), one bonus action and one shift. A perfect knight block ripostes for half a sword blow; a kill in the rogue's hands refunds the action once a turn.
- Sneaking (C) slows the walk and shrinks every enemy's detection ring (to 55 %, 30 % for the rogue, nothing inside a bush). A hit on an unaware enemy while sneaking is a sneak attack (x2, the rogue x3), and it only wakes enemies within 4 m of the victim or who can see you: a silent kill starts no fight.
- End your turn more than 11 m from every enemy in the fight and out of their sight (or in a Smoke Bomb with nobody within 3 m) and you slip away: the fight ends.
- Defeat is no longer the end: the body rises at the last waystone used (or the start) after 3 s.
- XP levels grant a skill point and 8 health each; the body starts with one point. Spend them in the skill tree on abilities (level 2 to 4) and passives (Vitality, Might, Fleet Foot, Soul Bond).

Headless check (prints `GAMEPLAY OK`):

```powershell
& $godot --headless --path . res://scenes/3d/tests/gameplay_test.tscn --quit-after 4000
```

### How a fight starts (WP13)

Every wolf shows a faint dashed ring on the ground while you explore: its detection range (5 m for a wolf, 4 m for the generic enemy). The ring turns red when you are within 1.5 m of its edge. Step inside the ring with nothing in the way and the wolf spots you: combat starts at once (`COMBAT!`), you act first, and every wolf within 12 m of you joins the fight. A tree or a crate between you and the wolf hides you even inside the ring (a line-of-sight ray against the prop layer). Rings disappear in combat and on death; a wolf with a detection range of 0 is unaware and never spots you on its own.

You can also strike first. In exploration the action row shows Melee and, for the soul in control, Throw or the two spells. Pick Throw or a spell and click a wolf: the same range ring, targeting and refusals as in a turn (`Out of range`, `Recharging (n)`), and the player stands still to throw or cast. A plain click on a wolf, or Space next to one, is the melee. Any hit that lands on a wolf outside combat starts it as an ambush (`AMBUSH!`): the hit resolves fully first, the struck wolf and everyone within 12 m of you engage, the wolves take the first turn, and your turn follows as usual. A refused or out-of-range attack starts nothing. Outside combat the attacks are spaced by the realtime 0.35 s cooldown, and a spell's cooldown melts one turn every 3 s of real time (spells still start every fight fresh).

The HUD buttons Melee, Throw, Block, Arcane Burst, Frost Snare, Wait and End Turn do what they say; Block and Wait hand the turn over and only show in combat. Hovering a wolf or an item highlights it. The Sound button (top right) unmutes the music.

Headless check of the detection and ambush rules (prints `DETECTION OK`):

```powershell
& $godot --headless --path . res://scenes/3d/tests/detection_test.tscn --quit-after 1200
```

## What is placeholder

- The generic enemy (`scenes/3d/enemy_3d.tscn`) is still a red box; only the wolf has a model. Each soul has its own body and weapon (knight and sword, rogue and daggers, mage and staff, swapped by `scripts/3d/soul_bodies_3d.gd` on a shift); the equipped item decides damage and range, not the mesh in the hand, so an equipped dagger as the knight still shows the sword.
- The three souls are rigged (hips, spine, head, arms, legs; a robe bone for the mage) with `idle` and `walk` clips authored in the generator and exported in the glb; the player plays `walk` while moving with the stride matched to its speed. Attacks are still the procedural lunge, squash and tint on `Model` plus the weapon-holder swing, layered over the walk. Wolves are rigged too (9 bones) with `idle` and a diagonal-gait `trot`, played by ground speed from `enemy_3d.gd` and frozen during the death topple.
- No link to or from the 2D hub. The arena is the start scene and has no level transitions (`LevelLoader.change_level` accepts 3D scenes, but nothing calls it yet).
- Test loot drops beside the player at start (`spawn_test_loot` on the arena root); untick it in the inspector for a clean run.
- Turn-order portraits are coloured squares; dropped items are the 2D icons as billboards.

## Regenerating

Models (Blender 4.3, no add-on needed; writes `assets/3d/models/*.glb`, Godot re-imports on the next open):

```powershell
blender --background --factory-startup --python tools/blender/generate_characters.py -- --root .
blender --background --factory-startup --python tools/blender/generate_wolf.py -- --root .
blender --background --factory-startup --python tools/blender/generate_props.py -- --root .
```

Keep the node names the scenes rely on: the knight's `Sword`, `HandPoint` and `OverheadAnchor` (`scripts/3d/knight_visual_3d.gd` hands the sword to the weapon holder) and the wolf's `Wolf_Body`. `scenes/3d/tests/asset_gallery.tscn` prints every model's tree and size.

Navmesh, after moving or adding props in `arena.tscn` (writes `scenes/3d/arena_navmesh.tres`, which is committed):

```powershell
& $godot --headless --path . --script res://tools/bake_arena_navmesh.gd
```
