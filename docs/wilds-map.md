# The Wilds: map, hazards, rebuild and test

Status: track A of the gameplay expansion (`docs/gameplay-expansion.md`, sections 3 and 6), written 2026-09-26 on branch `feat/wilds-map`.

`scenes/3d/wilds.tscn` is a 104 x 104 m forest level on the coordinator `scripts/3d/main_3d.gd`, built by `tools/build_wilds_3d.gd` with its navmesh `scenes/3d/wilds_navmesh.tres`. Do not edit the scene by hand: a re-run overwrites it. The shape of the map lives in `scripts/3d/world/wilds_layout.gd`, the placements in the builder's constants.

## Layout

Ground coordinates are (x, z) in metres; north is -z, east is +x. The open ground is five clearings plus a small gate clearing, joined by 4 m corridors. The rest is forest: invisible prop-layer walls (`NavigationRegion3D/ForestWalls`, 162 boxes, 2 m high) lined with 289 `tree.glb` trees, plus about a thousand scenery trees drawn at load by `WildsForest3D`.

| Area | Centre | Radius | Contents |
| --- | --- | --- | --- |
| Start glade (SW) | (-34, 34) | 11 m | `Spawn_default` (-36, 38); waystone `start` (-42, 38), attuned from the start; chest (-28, 40): potion plus one random item; two lone wolves, (-30, 27) wandering 3 m and (-39.5, 26); a line of four visible spike traps at z = 31, x = -36.5 to -32 |
| Wolf den (W) | (-32, -10) | 11 m | dire wolf (-32, -12), wolves (-35, -10.5), (-29, -10) wandering 2 m, (-33, -15); five bush zones around the edge and tall grass in the south mouth; blue light |
| Bandit camp (centre) | (6, 12) | 12 m | campfire at the centre (flickering light); bandits (4.5, 9.5) wandering 1.5 m, (9, 11.5), (6, 15); cultist (2.5, 12.5); explosive barrels (3.2, 8.2) + (2.3, 9.0) (a chaining pair), (10.4, 12.8), (7.4, 16.2); two tents, four crates; chest (13, 17.5): gear plus two; waystone `camp` (-1.5, 17.5); two tall-grass zones |
| Old ruins (N) | (-2, -30) | 12 m | brutes (-2, -30), (1.5, -28.5); cultists (-3.5, -33), (1, -33); four broken walls and six pillars (line-of-sight blockers); hidden traps at the south entrance (1, -19), (-1.5, -20.5), the west entrance (-12.5, -27.2) and in front of the chest (5.2, -35.2); chest (6, -36.5): gear and a potion; teal lights |
| Warden's gate | (16, -31) | 4.5 m | waystone `gate` (16, -34) |
| Warden's ring (NE) | (36, -32) | 11 m | eleven standing stones on an 8.5 m ring, open to the west; Grave Warden (37, -32) facing the gate; barrels (31, -28.5), (31.5, -35.5); hidden traps in the gap (27.5, -30.8), (28, -33.2); chest behind the boss (42.5, -32): gear, potion, two more; green light |

Corridors (polylines): start - den via (-37, 12); start - camp via (-14, 30); camp - ruins via (3, -8); den - ruins via (-18, -26); ruins - gate - ring. Walking distances from the spawn along the navmesh: den 48 m, camp 50 m, ruins 85 m, gate 102 m, ring 122 m.

Camp spacing: the enemies of one camp stand within 7 m of each other (the ruins' farthest pair is 6.7 m), so the coordinator's 12 m engage radius pulls the whole pack into one fight. The closest enemies of two different camps are more than 33 m apart. The start glade's two wolves are about 10 m apart on purpose: lone warm-up wolves, not a pack.

Enemies sit under one container per camp (`Enemies_Start`, `Enemies_Den`, `Enemies_Camp`, `Enemies_Ruins`, `Enemies_Boss`), each with metadata `camp_id` and `camp_center`; every enemy carries metadata `enemy_kind`.

## Rebuild

```powershell
$godot = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe\Godot_v4.7.2-stable_win64_console.exe"
& $godot --headless --path . --import                                # once, or after adding scripts
& $godot --headless --path . --script res://tools/build_wilds_3d.gd  # writes wilds.tscn + wilds_navmesh.tres
```

It prints `BUILD OK` in about two seconds. Enemy scenes come from the table in gameplay expansion section 6. A missing scene falls back to the wolf with a warning (today every track B scene is missing), so **re-run the builder once track B is merged**. `wander_radius` is only set when the loaded scene has that property. Sub-scenes are instanced with their edit state, so the level stores only position, script and metadata on them, and later tuning in `wolf_3d.tscn` or the track B scenes still comes through. Each rebuild writes new `unique_id` values, so expect a noisy diff in `wilds.tscn`.

How the builder bakes: the navigation region parses static colliders on layers 1 and 8 with the arena settings (cell 0.25 m, agent radius 0.5 m, height 2 m). Recast also finds the flat tops of the forest walls, and it keeps sealed pockets of floor. The builder therefore keeps only the polygons below 1 m that connect, edge to edge, to the polygon under the spawn (1,781 baked, 691 kept), so no click can snap onto a wall top.

## Hazards and interactables (`scripts/3d/world/`)

| Class | What it does |
| --- | --- |
| `Trap3D` (Area3D, watches layer 2) | Spike trap, 12 damage. Hidden (a faint glint every 3.2 s) until the player notices it: within 3 m, or 6 m while the rogue is in control, for `notice_seconds` (1 s). The player sets off only a trap it has not noticed. Enemies set it off only in turn mode, unless the player placed the trap. On an enemy: `take_environment_damage` (fallback `receive_damage`), then `apply_status(&"root", 1)` (fallback `apply_root`). On the player: `take_damage`. The trap is spent after one trigger: the spikes snap, a `SNAP!` popup, a burst and a shake. `Trap3D.place_player_trap(parent, point)` makes a visible, teal-tinted trap that catches enemies at any time. Exports: `damage`, `root_turns`, `placed_by_player`, `start_revealed`, `reveal_radius`, `rogue_reveal_radius`, `notice_seconds` |
| `ExplosiveBarrel3D` (StaticBody3D, layer 8, group `hittable`) | 10 health. At 0 it explodes: 22 damage within 3 m (enemies through `receive_damage`, the player through `take_damage`), then `apply_status(&"burn", 2, 4)` and `knockback(center, 1.5)` on surviving enemies that have those methods. A fireball and a light flash, two bursts, `BOOM!`, a shake. Barrels in range go off 0.15 s later, and the barrel frees itself after 0.6 s. Blocks movement and line of sight until it explodes |
| `HideZone3D` (Area3D, watches layer 2) | Procedural bushes or tall grass from `size` / `style` / `visual_seed`, with no collider. Calls `player.set_in_cover(self, true/false)` on enter and exit, and on leaving the tree |
| `Waystone3D` (StaticBody3D, layer 8, group `interactable`) | `interact` sends the player to the stone whose `waystone_id` matches `destination_id`, landing 1.5 m in front of it (its local -Z), through `teleport_to`, then calls `on_player_teleported` on the `level_coordinator` group. Refused during a fight. Range 2 m, label `Waystone: to <name>` |
| `LootChest3D` (StaticBody3D, layer 8, group `interactable`) | `chest.glb` model. Opens once: a flash and a hop, then a spent tint. Drops `item_count` items through `LootDropper.drop_items(self, items, 0.8)`: random gear first when `guaranteed_gear` is set, a potion when `include_potion` is set, the rest from `ItemFactory.create_random_loot`. Range 1.8 m |
| `Campfire3D` | Stones, logs, a flame and a flickering, shadowed omni light. A low collider on layer 8 |
| `WildsGround3D`, `WildsForest3D`, `WildsLayout`, `WorldFx3D` | Floor mesh (vertex colours: grass, trodden paths, dark forest floor), deep-forest MultiMesh, map shape, and shared helpers (hover overlay, mesh builders, player and coordinator lookups) |

Hover highlights on the barrel, waystone and chest are a persistent additive overlay (`WorldFx3D.set_highlight`), which composes with `HitFlash3D`.

## Choices made without asking

- **Notice time on traps** (`notice_seconds`, default 1 s). The contract reveals a trap when the player comes within 3 m. With an instant reveal, a walking player always sees a trap long before stepping on it, so traps would never hurt anyone. With 1 s, a knight walking straight at a trap (3.5 m/s) springs it, and the rogue's 6 m radius sees it in time. Set it to 0 for the contract's literal rule.
- **Waystone attunement.** A destination works only once the player has stood within 4 m of it, or has used it. Otherwise the camp stone would send a fresh player straight to the boss gate. `start` starts attuned.
- **A ring, not a line.** One `destination_id` per stone, so the network is start -> camp -> gate -> start: every stone is reachable, and going back from the gate to the camp takes two hops.
- **Fallback teleport.** Until the player has `teleport_to`, the waystone snaps the player to the nearest navmesh point and calls `snap_to_target` on the level's `CameraRig`.
- **Walls, not tree trunks.** Trees stand 1.9 m apart, which leaves gaps an agent can pass. The forest itself is invisible prop-layer boxes (they also block line of sight, like the trees).
- No decorative chests. Every chest in the map is a lootable `LootChest3D`, so the player never clicks a chest that does nothing.
- The start glade's teaching trap line starts visible (`start_revealed`). It teaches that enemies in turn mode get caught; it cannot hurt the player.

## Test

```powershell
& $godot --headless --path . res://scenes/3d/tests/wilds_test.tscn --quit-after 4000
```

`scenes/3d/tests/wilds_test.tscn` instances the level under a test node, so the level itself carries no test node. The test waits for the navmesh and pauses the coordinator's `_process`, so no fight starts while it moves actors by hand. It then checks, in order:

- **camps:** counts, pack spread and camp spacing
- **paths:** a navmesh path from the spawn to every clearing, and no navmesh vertex above 1 m
- **trap_enemy:** an enemy in turn mode is hurt and rooted; an exploring enemy is ignored; a player-set trap catches it anyway
- **trap_player:** an unrevealed trap hurts the player, a revealed one does not, and standing near a trap reveals it
- **barrel:** 22 damage at 2 m, no damage at 5.5 m, the chain to the neighbour after the delay, and the barrel is freed
- **cover:** the zone sees the player enter and leave; `set_in_cover` is checked once the player has it
- **waystone:** an unattuned destination is refused, the player lands at the camp arrival point, and the stone is refused during a fight
- **chest:** it drops `item_count` items, once

The test prints `WILDS OK`, or `WILDS FAIL: <step>: <reason>`. Until the lead's player methods exist it prints a note for `set_in_cover` and `teleport_to`.
