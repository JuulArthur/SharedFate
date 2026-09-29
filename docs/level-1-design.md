# Level 1: The Hollow Road (design draft)

Status: draft for review, 2026-09-29. Nothing here is built yet except the level flow it plugs into (`docs/level-flow.md`) and a placeholder scene with the same name (`scenes/3d/levels/hollow_road.tscn`, a copy of the test arena). Numbers are proposals; change anything.

## Purpose

The first playable level, and the showcase: a new player who has read nothing walks from one end to the other in 12 to 18 minutes and has used every core system once, in an order where each one is needed before the next is shown. It ends at an exit to the next level, the Wilds, so moving between levels is part of the showcase.

**Success looks like this:** a tester who has never seen the game finishes it without asking a question, fights three times with rising difficulty, forges one skill and uses it, and walks into the Wilds with everything they earned.

## The shape

A narrow valley road, about 70 m long and 12 to 25 m wide, walked south to north. Much smaller than the Wilds (104 x 104 m), so it can later be one pre-rendered painting or a few tiles (`docs/art-pipeline.md`, section 6). Six areas along one path, with one optional side pocket.

```
  N   [F] The Gate ........ brute guards the arch; EXIT "To the Wilds"
       |
      [E] The Bridge ...... bandit ambush, barrels, a way around through reeds
       |
      [D] The Shrine ...... waystone + campfire: first forge, respawn point
       |        \
       |        [D'] Side pocket: hidden trap, a chest with a Summon card (optional)
      [C] The Broken Cart . chest with the first cards, a line of spike traps
       |
      [B] The Watchers .... one lone wolf, then a pair; bushes to sneak through
       |
  S   [A] The Waking ...... spawn, the prologue book, the road north
```

## Area by area

| Area | Size | What is there | What it teaches | First-time hint (proposal) |
| --- | --- | --- | --- | --- |
| A. The Waking | 14 m clearing | spawn, the prologue story book, a lit road leading north, nothing hostile | click to move; the three souls and shifting (1 / 2 / 3, Q) | "Click to walk. 1, 2, 3: let another soul take the body." |
| B. The Watchers | 20 m | a lone wolf beside the road (ring visible), then two wolves 12 m further, bushes on the west edge | detection rings, sneaking (C) and cover, the ambush from range, the first turn fight: movement budget, the action, End Turn (Space), the F reaction on a bite | ring: "Its ring is how far it sees. C to sneak." First fight: "Your turn: move, then one action. Space ends it." First bite: "F now: Block, Parry or Ward." |
| C. The Broken Cart | 12 m | an overturned cart, a chest (a potion plus the first two cards), a visible line of spike traps across the direct path | loot and the inventory (I); skill cards exist; traps (the rogue sees hidden ones farther) | chest: "Cards. Forge them into skills at a fire." |
| D. The Shrine | 16 m | a waystone (the respawn point) and a campfire; most players reach level 2 here (lone wolf + pair = 105 XP) | attribute points (K); forging the first skill from the chest's cards plus what the wolves dropped | "K: spend your points. By the fire you can forge." |
| D'. Side pocket (optional) | 8 m | a hidden trap in the mouth, a chest with a Summon card and a heal potion | exploring pays; the rogue's trap sense | none |
| E. The Bridge | 22 m | two bandits and a cultist on the far side of a stone bridge, two explosive barrels near them, tall reeds on a longer path round the east side | the full fight: shifting mid-turn, the bonus action, the forged skill and its mana or stamina, hazards, or slipping away; enough XP for level 3 (260 total) | barrels: "Strike a barrel to set it off." |
| F. The Gate | 14 m | a brute (slow, heavy hits) in front of a ruined arch, the exit behind it; a chest by the arch | a hard single enemy: the knight's Block stance, a Control skill, keeping distance with the mage | exit: the arch's sign, "To the Wilds" |

Wolves, bandits, cultists and the brute exist today (`docs/enemy-roster.md`). XP along the road: 35 + 70 (B) = 105, level 2 at the shrine; + 155 (E) = 260, level 3 after the bridge; + 90 (F) = 350.

## Cards in this level

The starter deck (`starter_card_copies`) is off here: the level hands out cards on purpose.

| Where | Cards | So that |
| --- | --- | --- |
| C, the cart chest | Damage, Fire | the first skill can be forged at the shrine: a flame bolt for the mage, a flaming strike for the knight or rogue (an Area card from the wolves makes it a Fireball) |
| B, the wolves | random drops (the first is always a type card) | the collection grows by play |
| D', the side chest | Summon, Area | a reward for exploring |
| F, the gate chest | Control, Frost, Ranged | a head start in the Wilds |

This needs chests with fixed cards (see "What has to be built").

## The level flow

- Start: a fresh game starts here (the main scene moves from the Wilds to this level). The prologue book opens here instead of in the Wilds.
- Exit: the arch in F, a `LevelExit3D` to `res://scenes/3d/wilds.tscn`, entry `from_road`. That entry already exists in the start glade of the Wilds, 3.9 m from the Wilds' way back to this level.
- Death: back at the shrine's waystone once it is reached, before that at the spawn. Today the respawn point only moves when a waystone teleports you, so reaching one must count too (see "What has to be built").
- Coming back from the Wilds lands at `Entry_from_wilds`, beside the arch in F.

## What has to be built

In rough order:

1. **The level itself**: a builder like `tools/build_wilds_3d.gd` (layout as data, baked navmesh), replacing the placeholder at the same path so the level flow keeps working.
2. **Contextual hints**: a small system that shows a line once, the first time something happens (first ring in view, first player turn, first bite, first card, first rest point). Remembered in the run state.
3. **An objective line**: one short line on screen ("Follow the road north", "Cross the bridge", "Pass the gate").
4. **Chests with fixed cards**: an export on the chest, read by the coordinator instead of the random roll.
5. **Rest points as checkpoints**: resting by a waystone or campfire (standing within forge range) makes it the respawn point.
6. **The main scene switch**: `run/main_scene` to this level, the prologue moved here, the starter deck off.
7. **Later, art**: once the level plays well, the pre-rendered pipeline on this map only.

## Open questions for you

1. Name and mood: "The Hollow Road", a valley road at night, fits the dark-fantasy brief. Keep it?
2. Should the player pick a starting soul, or always wake as the knight?
3. Is 12 to 18 minutes the right length, or should level 1 be shorter (cut B's second wolf pair and D')?
4. Should the brute at the gate be optional (a way round it), or the gatekeeper you must beat?
5. Hints: plain text lines (cheap), or the story book's painted pages for the big moments?
