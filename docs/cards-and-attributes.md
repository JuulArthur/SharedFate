# Cards and attributes: how the Bound Three grow

Status: written 2026-09-26 on branch `feat/card-skills`. It replaces the skill tree of the gameplay expansion (`docs/gameplay-expansion.md`): the skill points, the 13 hand-made soul abilities and the four body passives (Vitality, Might, Fleet Foot, Soul Bond) are gone. Inspired by Two Worlds II: attribute points to spread, and spells built from cards.

Growth has two parts:

1. **Attributes, per soul.** Each level gives attribute points that go to one soul at a time, so the three souls compete for them.
2. **Skill cards.** Cards drop from enemies and chests. At a campfire or waystone, cards are forged into skills. The same cards make a different skill for each soul, and extra copies of a card make it stronger.

Code: `scripts/3d/progression_3d.gd` (attributes, pools, collection, forged skills), `scripts/3d/cards/skill_cards_3d.gd` (the cards), `scripts/3d/cards/card_skill_compiler_3d.gd` (cards to skill, every skill number), `scripts/3d/abilities/ability_runner_3d.gd` (runs the skills), `scripts/3d/ui/character_screen_3d.gd` (the K screen). Test: `scenes/3d/tests/gameplay_test.tscn` (prints `GAMEPLAY OK`).

## 1. Attributes

The body starts with 3 attribute points and gets 3 more at every level up (plus 8 maximum health, as before). A point raises one soul's attribute by one, up to 10. Points cannot be taken back. Attributes can be raised anywhere, any time, on the character screen (K).

Each soul reads the same three attributes its own way:

| Attribute | Knight | Rogue | Mage |
| --- | --- | --- | --- |
| Power | +10 % damage (weapon and skills) | +10 % damage (blades, throws, skills) | +10 % damage (spells and skills) |
| Energy | +8 stamina, +1 refill a turn per 2 points | +8 stamina, +1 refill a turn per 2 points | +8 mana, +1 refill a turn per 2 points |
| Finesse | 5 % less damage taken while in control (at most 50 %) | +0.5 m movement a turn while in control | +0.5 m range and +0.25 m area on its skills |

Power applies to everything the soul in control deals through `Player3D.scale_damage`: melee, throws, the mage's two spells and the card skills. A raise in Energy arrives filled.

## 2. Mana and stamina

Each soul has its own pool: the knight and the rogue stamina, the mage mana. Card skills cost from the pool of the soul they belong to, on top of the turn's action or bonus action. Basic attacks (melee, throw, the mage's Arcane Burst and Frost Snare, Block) stay free.

| Soul | Pool | Refill a turn |
| --- | --- | --- |
| Knight | 30 stamina | 6 |
| Rogue | 30 stamina | 8 |
| Mage | 40 mana | 8 |

All three pools refill at the start of every player turn (the three souls share one body and all rest). Outside a fight they refill by one turn's worth every 3 s, the same clock as exploration cooldowns. A fight does not reset them. The bars under the soul portraits (top left) show them.

## 3. The cards

| Category | Cards | Cost each | What a copy does |
| --- | --- | --- | --- |
| Type | Damage, Affliction, Control, Buff, Heal, Summon | 6 | what the skill does; extra copies make it stronger and rank it II, III |
| Element | Fire, Frost, Lightning, Poison | 4 | adds damage and a status; extra copies add more |
| Modifier | Ranged, Close, Area | 3 | shapes the delivery; extra copies reach further, hit harder or wider |

A skill holds 1 to 5 cards: exactly one kind of type card (in one to three copies), any elements, any modifiers, but not Ranged and Close together. Its cost is the sum of its cards' costs. A skill with 4 cards recharges 1 turn after use, one with 5 cards 2 turns. Buffs and heals cost the bonus action, everything else the action. Each soul holds 3 skills, on keys 4, 5 and 6 while that soul is in control. Toss Pebble stays on key 7 for every soul.

### Drops

- A chest gives 2 cards (3 for a chest with 3 or more items) on top of its items.
- A fallen enemy gives a card with a chance of 35 % plus 0.5 % per XP it was worth, at most 85 %. The boss gives 3.
- While the body owns no type card at all, the next card is always a type card, so the first card found can become a skill.
- Otherwise a card is rolled by weight: Damage is the most common type and Summon the rarest; elements and modifiers are about equally common.

### Forging

Forging and taking skills apart happen on the character screen, and only within 4 m of a campfire or waystone, outside a fight (`Main3D.forge_block_reason`). Anything in group `rest_point` counts as a rest point too. Pick a slot, click cards in the collection to put them on the workbench, read the preview, and press Forge. Forging over a skill returns its old cards first; taking a skill apart returns all its cards.

## 4. How a skill is built

The type decides the effect, elements add power and statuses, modifiers shape it, and **the soul decides the delivery**:

| Soul | No modifier | Ranged | Close | Area |
| --- | --- | --- | --- | --- |
| Knight | weapon strike | leap to the enemy and strike (4 m) | weapon strike | sweep around the body (with Ranged: a slam at the landing) |
| Rogue | weapon strike (x1.5 on an exposed enemy) | thrown blade (6 m) | weapon strike | trap field on the ground (6 m away, or around the rogue with Close) |
| Mage | bolt (8 m) | bolt (8 m) | nova around the mage | bursting bolt (with Close: a bigger nova) |

A mage bolt with Lightning and no Area chains to one more enemy per Lightning card (4 m jumps, 20 % less per jump). Buffs and heals land on the body. Summons raise a spirit on the ground within 5 m.

The same four cards, Damage + Fire + Ranged + Area, make three different skills:

- **Mage:** *Fireball*, a bolt that bursts over 2 m: 11 damage and burn to everyone in the burst.
- **Rogue:** *Fire Trap*, a burning field 8 m away that lasts 3 turns and strikes every enemy inside once a turn.
- **Knight:** *Flame Slam*, a leap onto an enemy that strikes everyone around the landing.

### Numbers (before Power)

| Effect | Base | Per extra copy of the type | Other cards |
| --- | --- | --- | --- |
| Damage | 8 damage | +6 | +3 per element card; a weapon delivery adds 50 % of the weapon's damage, +25 % per Close card |
| Affliction | 3 damage, then burn (poison with a Poison card) 3 a turn for 2 turns | +2 a turn, +1 turn | +1 a turn and +1 damage per element card; a weapon delivery adds half the Damage row's weapon share |
| Control | 4 damage and a hold for 1 turn | +1 turn (a stun at most 2) | +2 damage per element; the hold is root (Frost), stun (Lightning), weaken (Poison), expose (Fire), otherwise stun for the knight and root for the others; the knight also knocks back 1.5 m; a weapon delivery adds half the Damage row's weapon share |
| Buff | 2 turns | +1 turn | Fire: +25 % damage per card. Frost: 25 % less damage taken, +10 % per extra card (at most 60 %). Lightning: +3 m movement, +1 per extra card. Poison: hits poison for 3, +2 per extra card. No element: the knight wards 30 %, the rogue vanishes in smoke (Smoke Bomb), the mage gets +25 % damage |
| Heal | 15 % of maximum health | +10 % | each element adds its buff for 1 turn |
| Summon | a spirit for 3 turns, 5 damage a strike | +1 turn, +3 damage | +2 damage per element and the element's status; Area: it strikes everyone in reach instead of the nearest. Reach: knight 2.5 m, rogue 4 m, mage 7 m |

On a Damage skill or a spirit, elements add: Fire burn (2 turns, 2 a turn per Fire card), Frost root 1 turn, Lightning expose 1 turn, Poison poison (2 turns, 2 a turn per Poison card). A trap field strikes for 60 % of the damage, but every turn. Area radius is 2 m, +1 m per extra Area card. Ranged adds 2 m of range per copy the delivery does not need (the mage's bolt and the rogue's field need none; the throw and the leap need one).

Cards that do nothing in a combination (Area on a buff, Ranged on a nova) are named in the forge preview.

### Names

Well-known combinations get classic names: Fireball, Chain Lightning, Frost Nova, Fire Trap, Poison Blade, Shield Bash, Cleave, Charge, Second Wind, Smoke Bomb. Everything else is named from its element and delivery (for example *Storm Spirit*, *Frost Ward*, *Venom Knife*), with II or III for two or three copies of the type card.

## 5. Buffs on the body

`Player3D.apply_buff(id, turns, power)`: `ward` (less damage taken), `empower` (more damage), `haste` (more movement, at once when cast mid-turn), `envenom` (melee hits, throws and skill hits poison), `vanish` (the Smoke Bomb cover). Buffs count the player's own turns and melt at the start of each; outside a fight, one melts every 3 s. They show in the soul strip under the portraits.

## 6. Trap fields and spirits

A trap field (`SkillField3D`) strikes an enemy when it walks in and again at the start of every player turn while it stands inside, never twice a turn. Its strikes are environment damage (`take_environment_damage`), so a field laid in exploration catches an unaware enemy without starting an ambush. A spirit (`SkillTotem3D`) strikes at the start of every player turn during a fight; outside a fight it waits and counts down. Both last their turns, then fade.

## 7. Tuning

Every skill number is a constant at the top of `card_skill_compiler_3d.gd`; attribute, pool and drop numbers are at the top of `progression_3d.gd` and `main_3d.gd` (`CHEST_CARDS`, `BOSS_CARDS`, `ENEMY_CARD_CHANCE_*`). Card costs, weights and texts are in `skill_cards_3d.gd`. The first pass of balance is untested in play: expect to tune costs, the 60 % field share and the drop rates.

## 8. Not done yet

- No save game exists, so attributes and cards last one session, like everything else.
- Points cannot be respent.
- Spirits do not move, and enemies ignore them.
- The mage's Finesse range bonus reaches its card skills, not Arcane Burst and Frost Snare.
