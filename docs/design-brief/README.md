# Claude Design brief: The Bound Three

A package for setting up a design space in Claude Design (claude.ai/design) for interface and screen mockups that match the game. The look and the process behind it are described in `docs/art-pipeline.md`.

## What to upload

The four reference boards in `images/`, made by `make_boards.py` from the game's own renders and colour constants:

| File | Shows |
| --- | --- |
| `images/01_look.png` | The game at its default camera, plus occlusion, spell light and firelight |
| `images/02_palette.png` | 48 named colours with hex values: world, characters, interface, gameplay signals |
| `images/03_characters.png` | The dark mage from five angles and at actual in-game size |
| `images/04_interface.png` | Interface materials (black leather, dark iron, scorched parchment), type, a sample leaf, gameplay colour chips |

Also upload `assets/3d/previews/styles/prerender_crypt_game_zoom.png`. It is a clean 1600 x 900 in-game frame with no interface, a good background for HUD mockups.

Regenerate the boards after the look changes:

```bash
uv run --no-project --with pillow python docs/design-brief/make_boards.py
```

## Steps in Claude Design

1. Open your existing *The Bound Three Art Bible* project, or create a new project called *The Bound Three - interface*.
2. Attach the five images above.
3. Paste the brief below as the first message (or as the project's instructions, if the project offers them).
4. Ask for the first mockups from the list further down, one at a time, and correct the design language on the first one before moving on.

## The brief to paste

```text
You are designing interface mockups for The Bound Three, a dark fantasy CRPG in the tradition of Baldur's Gate 2. The attached boards are the source of truth: 01 the look, 02 the palette, 03 the characters, 04 the interface materials and type. The clean in-game frame is the background for HUD mockups.

The game
- One hero body shared by three souls: the knight, the rogue and the mage. The player switches soul (keys 1, 2, 3); each soul has its own abilities and colour.
- Fixed isometric camera over painted, pre-rendered scenes at night. Characters are small on screen (about 125 px tall at 1600 x 900), so the interface must never cover the middle of the screen.
- Exploration is real time; combat is turn based (6 m of movement per turn, actions, then end turn). Enemies telegraph attacks and the player can counter at the right moment (key F).

Visual language
- Materials: black leather, dark iron with rivets, scorched parchment. The in-game story book already uses them: a black leather book with iron corners, and parchment where words burn in ember red and cool to ink.
- Colour: use the palette board. Frames and panels stay muted and dark (leather #0E0A0A, iron #3D3B38, parchment #B59E78, ink #1A0F0D). Ember #C7290F and heat #FFCC6B are the accents. Gameplay colours stay saturated and are used only for gameplay meaning: knight #94BDFF, rogue #8CED99, mage #CC9EFF, damage taken #FF5C5C, heal #8CF299.
- Type: Palatino Linotype (fallbacks Palatino, Constantia, Book Antiqua, Georgia) for titles, names and story text; a clean sans only for small numbers.
- Mood: worn, heavy and quiet. No glossy gradients, no neon, no sci-fi glass, no bright white panels. Ornament comes from iron corners, rivets, stitched leather and scorched edges, used sparingly.
- Readability first: every control readable over a dark painted background, hit targets at least 44 px at 1920 x 1080, and colour never the only signal.

Deliverables
- Design at 1920 x 1080 and check at 1600 x 900.
- Keep a small design system as you go: colour tokens (use the hex values given), type scale, panel and button styles, icon style.
- Mark anything you invent that is not in the boards, so we can decide on it.
```

## First mockups to ask for

Built on what the game already has (`docs/3d-arena.md`, `docs/gameplay-expansion.md`):

1. **Combat HUD** over the clean frame. It holds:
   - the action row: Melee, Throw, Block, Arcane Burst, Frost Snare, Wait, End Turn (it changes with the soul in control);
   - the soul switcher (knight, rogue, mage, keys 1 to 3);
   - the turn order strip with portraits;
   - the movement budget ("6 m");
   - a mute toggle.
2. **The counter prompt**: an enemy wind-up with a timing ring and the F key, shown as a wind-up, a perfect result and a miss.
3. **Loot panel**: a pile of dropped items with take and take all.
4. **Inventory and character sheet**: equipment slots, bag, level and experience, and the three souls with their abilities.
5. **Story book spread**: the prologue pages, for comparison with the in-game book.
6. **Main menu and pause menu.**

## Bringing designs back into the game

- Share the project link with Claude Code. It can read Claude Design projects once `/design-login` has been run once in an interactive `claude` session on this PC. Without that, export the files into the repository.
- Agreed tokens go into `docs/art-pipeline.md` (section 3) and then into the game's interface theme.
- Mockups are drafts. The game's own code decides what is final.
