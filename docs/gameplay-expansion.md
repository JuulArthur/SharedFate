# Gameplay expansion: shared interfaces

Status: written 2026-09-26 on branch `feat/gameplay-expansion` (off `main`). Three tracks run in parallel and merge back into that branch. This file is the contract between them; everything in `docs/3d-port-contracts.md` still holds (units, layers, GroundMath, duck-typed actors, `_apply_damage`, headless rules in section 11).

| Track | Branch / checkout | Owns |
| --- | --- | --- |
| Lead: abilities, stealth, progression | `feat/gameplay-expansion`, main checkout | `scripts/3d/main_3d.gd`, `scripts/3d/player_3d.gd`, `scripts/3d/abilities/`, `scripts/3d/progression_3d.gd`, `scripts/3d/ui/`, `scripts/3d/tests/arena_integration_smoke.gd`, `scripts/3d/tests/gameplay_test.gd` |
| A: world, hazards, map | `feat/wilds-map`, `.claude/worktrees/wilds` | `scripts/3d/world/`, `tools/build_wilds_3d.gd`, `scenes/3d/wilds.tscn`, `scenes/3d/wilds_navmesh.tres`, `scenes/3d/world/`, `scenes/3d/tests/wilds_test.tscn` + script |
| B: enemies, statuses, boss | `feat/enemy-roster`, `.claude/worktrees/roster` | `scripts/3d/enemy_3d.gd`, `scripts/3d/enemies/`, `scenes/3d/enemies/`, `scenes/3d/wolf_3d.tscn`, `scenes/3d/tests/enemy_roster_test.tscn` + script |

A track never edits another track's files. If it needs something from another track, it codes against the interface below with `has_method` guards and writes the need in its section of "Open requests" at the end of this file.

## 1. Turn economy (lead)

A player turn is: movement (per soul, see 4), one **action** (melee, throw, spell, or an action ability), one **bonus action** (bonus abilities), one soul shift (two after a perfect reaction). Enemies keep move + one attack. Abilities have cooldowns in the player's own turns; in exploration one turn of cooldown melts every 3 s (as the spells do today).

## 2. Enemy interface (track B implements on `Enemy3D`, everyone calls it duck-typed)

| Method | Meaning |
| --- | --- |
| `apply_status(status: StringName, turns: int, power: int = 0) -> void` | adds or refreshes a status (keeps the longer duration and the higher power) |
| `has_status(status: StringName) -> bool`, `get_status_turns(status: StringName) -> int`, `get_statuses() -> Dictionary` | status id -> {turns, power} |
| `knockback(from_point: Vector3, distance_m: float) -> void` | slides the body away from `from_point` on the ground plane over about 0.15 s, stopping at props (layer 8) and staying on the navmesh |
| `is_unaware() -> bool` | alive, not in turn mode, not alerted: a sneak-attack target |
| `is_back_turned_to(world_point: Vector3) -> bool` | the point lies more than 110 degrees off the enemy's facing (local -Z) |
| `investigate(world_point: Vector3) -> void` | an unaware enemy walks to the point at reduced speed, looks around about 2 s, then walks home. Ignored when alerted or in turn mode |
| `take_environment_damage(amount: int) -> void` | damage that does **not** emit `provoked_by_hit` (traps), so a trap in exploration never starts an ambush; the enemy stays unaware |
| `get_display_name() -> String`, `get_portrait_color() -> Color`, `is_boss() -> bool` | for the turn-order strip and the boss bar |
| `get_effective_detection_range() -> float` | `detection_range` times the target's multiplier (below) |

Status ids (constants on `Enemy3D`: `STATUS_STUN` etc.):

| Id | Effect |
| --- | --- |
| `&"stun"` | its next turn is skipped: no movement, no attack; popup `STUNNED` |
| `&"root"` | as Frost Snare today (`apply_root` stays and maps to it) |
| `&"poison"` | `power` damage at the start of each of its turns (green popup) |
| `&"burn"` | `power` damage at the start of each of its turns (orange popup) |
| `&"weaken"` | its hits deal half damage |
| `&"expose"` | it takes 50 % more damage |

Durations count the enemy's own turns and drop at its `end_turn`. All statuses clear when turn combat ends. Statuses show as a short text line under the health bar (for example `STUN 1  POISON 2`).

Detection: `can_spot(target)` and the visible ring use `detection_range * target.get_detection_multiplier()` when the target has that method (0 means it cannot be seen at all; the ring then shows at a small minimum radius). Line of sight rules stay.

Wandering: exports `wander_radius := 0.0` (metres around the home point; 0 stands still) and `wander_pause := Vector2(2.0, 5.0)` seconds. Home is the position on the first physics frame. Wandering and investigating happen only while unaware and out of turn mode, at 45 % of `move_speed`. When turn combat ends, an unaware survivor walks home.

Spawned enemies (the boss's summons): add as a sibling of the spawner, `snap_to`, add to group `enemies`, then `get_tree().call_group("level_coordinator", "register_spawned_enemy", enemy)`. The coordinator engages it at once when a fight is running, connects its signals and gives it the player as target.

## 3. World interface (track A implements, lead picks and calls)

- **Interactables**: a `Node3D` in group `interactable`, with colliders on layer 8 somewhere under it. Methods: `interact(player: Node3D) -> void`, `get_interact_range() -> float` (metres, default 1.8), `get_interact_label() -> String`, optional `set_hover_highlighted(enabled: bool)`, optional `can_interact() -> bool`. The coordinator ray-casts layer 8 on a click, walks up the parents to the first node in the group, and either calls `interact` (in range) or walks the player over and calls it on arrival. Waystones, chests and levers are interactables.
- **Hittables**: a `Node3D` in group `hittable` (the explosive barrel), colliders on layer 8. Methods: `receive_damage(amount: int)`, `take_damage(amount: int)`, `is_alive() -> bool`, optional `set_hover_highlighted(enabled: bool)`. Melee, throws, spells and abilities can target it like an enemy.
- **Traps** (`Trap3D`, an `Area3D` watching layer 2): trigger on an actor body entering. Players always trigger a trap they have not revealed; a trap is revealed when the player comes within 3 m (6 m while the rogue is in control) and then shows its mesh. Enemies trigger it only while in turn mode, unless the trap was placed by the player (`placed_by_player = true`), which triggers on enemies any time. Effect on an enemy: `take_environment_damage(damage)` (fallback `receive_damage`) and `apply_status(&"root", 1)` (fallback `apply_root(1)`). Effect on the player: `take_damage(damage)`. Spent after one trigger. Static `Trap3D.place_player_trap(parent: Node, world_point: Vector3) -> Trap3D` is what the rogue's Set Snare ability calls.
- **Explosive barrel**: on death, 22 damage in 3 m to every actor (enemies through `receive_damage`, so survivors join a fight; the player through `take_damage`) plus `apply_status(&"burn", 2, 4)` on enemies and `knockback`; chains to other barrels in range after 0.15 s.
- **Cover** (`HideZone3D`, an `Area3D` with procedural bushes or tall grass, no collision for movement or line of sight): calls `player.set_in_cover(self, true)` on enter and `(self, false)` on exit, guarded by `has_method`.
- **Waystones**: pairs or networks by `waystone_id` / `destination_id`; `interact` teleports the player with `player.teleport_to(world_point)` and then `get_tree().call_group("level_coordinator", "on_player_teleported")`. Only usable in exploration: check `get_tree().get_first_node_in_group("level_coordinator").call("is_in_combat")` when available.

## 4. Player interface (lead implements, track A calls)

| Method | Meaning |
| --- | --- |
| `set_in_cover(zone: Node, inside: bool) -> void`, `is_in_cover() -> bool` | cover zones the body stands in |
| `is_sneaking() -> bool`, `set_sneaking(enabled: bool) -> void` | exploration only; C toggles |
| `get_detection_multiplier() -> float` | 1.0 normal, 0.55 sneaking, 0.3 sneaking as the rogue, 0.0 sneaking in cover or while Smoke Bomb hides the body, 0.6 in cover but upright |
| `teleport_to(world_point: Vector3) -> void` | snaps to the nearest navmesh point with a burst |
| `take_damage(amount: int)`, `get_active_soul() -> Soul` | unchanged |

Per-soul movement per turn: knight 6 m, rogue 8 m, mage 5 m (plus progression bonuses). A shift mid-turn moves the remaining budget by the difference.

## 5. Coordinator interface (lead implements on `main_3d.gd`, group `level_coordinator`)

`register_spawned_enemy(enemy: CharacterBody3D) -> void`, `on_player_teleported() -> void`, `is_in_combat() -> bool`.

## 6. Map (track A)

`scenes/3d/wilds.tscn` is generated by `tools/build_wilds_3d.gd` (run headless with `--script`) together with its baked `scenes/3d/wilds_navmesh.tres`. It follows the level node contract (contracts section 9), roughly 100 x 100 m, with a start glade, several camps each with a different enemy group, cover, traps, barrels, chests, waystones and a boss arena. Enemy scene paths (track B delivers them; the builder falls back to the wolf and prints a warning for a missing scene):

| Scene | Enemy |
| --- | --- |
| `res://scenes/3d/wolf_3d.tscn` | Wolf (exists) |
| `res://scenes/3d/enemies/dire_wolf_3d.tscn` | Dire Wolf: bigger, tougher wolf |
| `res://scenes/3d/enemies/bandit_3d.tscn` | Bandit: rogue body, fast melee |
| `res://scenes/3d/enemies/cultist_3d.tscn` | Cultist: mage body, ranged bolt, keeps distance |
| `res://scenes/3d/enemies/brute_3d.tscn` | Brute: knight body, slow, heavy hits |
| `res://scenes/3d/enemies/grave_warden_3d.tscn` | Grave Warden: the boss |

`scenes/3d/arena.tscn` stays as the small test arena behind the `INTEGRATION OK` test. When the tracks are merged, `run/main_scene` becomes `wilds.tscn`.

## Open requests

(each track appends here: date, track, request)

- 2026-09-26, track B (details in `docs/enemy-roster.md`):
  1. Turn-order strip: read `get_display_name()`, `get_portrait_color()` and `is_boss()` from each enemy (all roster scenes set them; the wolf is "Wolf").
  2. Enemy turn in `main_3d.gd`: skip the camera beat and `ENEMY_ACTION_GAP_SECONDS` for an enemy whose `is_skipping_turn()` is true after `start_turn` (stunned: it has 0 m and `try_attack` refuses), and for one that `start_turn` killed (poison or burn tick). Both are already harmless today; this is pacing only. The `is_alive` check after the gap is skipped for the first actor, so a first actor killed by poison still gets its (empty) move, attack and `end_turn` calls.
  3. `register_spawned_enemy(enemy)`: `Enemy3D.set_target` no longer routes the agent while the enemy is in turn mode, so the coordinator must not rely on it to move a summon; engage it, connect `provoked_by_hit`, and let the normal enemy turn move it. The warden already puts its summons in turn mode, gives them the player as target and calls `alert()` on them.
  4. `Player3D.get_detection_multiplier()` (section 4) is what `can_spot` and the ring read; without it the multiplier is 1.0.
  5. Optional: if the HUD draws its own boss bar, set `show_boss_bar = false` on `BossEnemy3D` and read `get_display_name()`, `health` / `max_health` and `get_phase()`.
  6. Optional: a player knockback API (for example `knockback(from_point, distance_m)` like the enemy's) would let the brute and the warden's slam shove the player; skipped for now.
### 2026-09-26, track A (world, hazards, map)

Delivered on `feat/wilds-map`: `scripts/3d/world/` (Trap3D, ExplosiveBarrel3D, HideZone3D, Waystone3D, LootChest3D, Campfire3D, plus the map helpers), `tools/build_wilds_3d.gd`, `scenes/3d/wilds.tscn`, `scenes/3d/wilds_navmesh.tres` and `scenes/3d/tests/wilds_test.tscn` (prints `WILDS OK`). Details and choices: `docs/wilds-map.md`.

For the lead:

1. Put the `main_3d.gd` root in group `level_coordinator` and add `is_in_combat()` and `on_player_teleported()` (section 5). Until then waystones fall back to the player's `is_in_turn_based_combat()` for the fight check. The `on_player_teleported` call is skipped when no coordinator has the method.
2. Player `set_in_cover` / `is_in_cover` and `teleport_to` (section 4). Until then the waystone snaps the player to the nearest navmesh point and calls `CameraRig.snap_to_target()`. The test notes both and checks the fallback.
3. Click handling for group `interactable` (the waystones and chests are StaticBody3D roots on layer 8) and targeting for group `hittable` (the barrels: `receive_damage`, `take_damage`, `is_alive`, `set_hover_highlighted`). Everything else in the world needs no coordinator code.
4. Set Snare: `Trap3D.place_player_trap(level_root, point)` returns the trap. It is visible, tinted teal and catches enemies outside turn mode too.
5. Decide on trap `notice_seconds` (default 1 s): the player must stay within the reveal radius that long to notice a trap. It is a track A addition to the section 3 rule. With an instant reveal a walking player always spots a trap before stepping on it. Set it to 0 on `Trap3D` if you want the literal contract.
6. `is_navmesh_ready()` can turn true one or more physics frames before `map_get_closest_point` answers for a shipped mesh (async map iterations). `wilds_test` waits until the map answers near the spawn; the coordinator may want the same wait before wiring enemy targets.
7. After merging: re-run `tools/build_wilds_3d.gd` once track B's enemy scenes exist (today every non-wolf enemy is a wolf stand-in with a builder warning), then set `run/main_scene` to `res://scenes/3d/wilds.tscn` (section 6).

For track B:

1. The hazards call `take_environment_damage(amount)` and `apply_status(&"root", 1)` (traps), and `receive_damage`, `apply_status(&"burn", 2, 4)` and `knockback(center, 1.5)` (barrels), all guarded by `has_method`. The builder sets `wander_radius` on four enemies when the property exists.
2. Detection ranges: the camp waystone's arrival point is 7.9 m from the camp cultist and 9.3 m from the nearest bandit. The gate waystone's arrival point is 15 m from the ruins cultists and 21 m from the Grave Warden. Please keep bandit and cultist `detection_range` under about 6 m and the Warden's under about 18 m, or a teleport lands inside a ring. If that does not suit the roster, tell track A and the stones move.
