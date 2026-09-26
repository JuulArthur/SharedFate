# Enemy roster, statuses and the boss (track B)

Status: written 2026-09-26 on branch `feat/enemy-roster` (worktree `.claude/worktrees/roster`). Implements section 2 of `docs/gameplay-expansion.md` on `Enemy3D` and delivers the enemy scenes listed in its section 6. Units, layers and the actor contract are those of `docs/3d-port-contracts.md`.

## The roster

All scenes are standalone `CharacterBody3D`s on layer 2 / mask 9 with `CollisionShape3D`, `NavigationAgent3D` (tuned like the wolf: path 0.3 m, target 0.1 m, avoidance, `time_horizon_agents` 0.25, `max_speed` = walk speed), `OverheadAnchor` and `Model`. Balance knobs are the scene exports; behaviour constants sit at the top of each script.

| Scene | Script | Body | HP | Damage | Reach | Speed | Turn move | Detection | XP |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `scenes/3d/wolf_3d.tscn` | `enemy_3d.gd` | wolf | 36 | 10 | 1.3 m | 3.6 m/s | 6 m | 5 m | 35 |
| `scenes/3d/enemies/dire_wolf_3d.tscn` | `enemies/dire_wolf_3d.gd` | wolf x1.35, dark | 70 | 14 (21 heavy) | 1.6 m | 3.4 m/s | 6 m | 5.5 m | 70 |
| `scenes/3d/enemies/bandit_3d.tscn` | `enemy_3d.gd` | rogue, tinted | 45 | 9 | 1.2 m | 4.0 m/s | 7 m | 6 m | 50 |
| `scenes/3d/enemies/cultist_3d.tscn` | `enemies/ranged_enemy_3d.gd` | mage, violet | 32 | 11 | 7 m | 3.0 m/s | 6 m | 6.5 m | 55 |
| `scenes/3d/enemies/brute_3d.tscn` | `enemy_3d.gd` | knight x1.2, rusty | 95 | 18 | 1.5 m | 2.6 m/s | 5 m | 4.5 m | 90 |
| `scenes/3d/enemies/grave_warden_3d.tscn` | `enemies/boss_enemy_3d.gd` | knight x1.7, dark, glowing visor and steel | 320 | 20 | 1.8 m | 2.8 m/s | 6 m | 7 m | 400 |

- **Wolf**: unchanged numbers; gained `display_name` and `portrait_color`.
- **Dire Wolf** (`DireWolf3D`): every third bite (3rd, 6th, ...) is heavy: x1.5 damage behind a 1.6x longer wind-up with a deeper crouch, a `HEAVY` popup and `HEAVY` in front of the counter hint. A fixed count, never a roll, so fights are repeatable. Aborted swings do not count.
- **Bandit**: plain `Enemy3D`; fast (4 m/s) and `turn_move_override_m = 7`, quicker wind-up (0.5 s in turns).
- **Cultist** (`RangedEnemy3D`): the normal swing with the normal counter handshake, dressed as a spell: the wind-up charges the staff (violet glow), the strike is a violet bolt flying from the staff hand to the target in exactly the strike time (0.32 s in turns), so the prompt's beat is the bolt's arrival and every soul reacts as to a bite. If the target stands within 2.5 m at the start of its turn it first backs off up to 3 m (capped by its remaining movement, spent from the budget) and then fires. The coordinator's approach point for a 7 m reach is about 6.8 m out, so it otherwise stays at range.
- **Brute**: plain `Enemy3D`; long telegraphed wind-up (0.95 s) and a wide counter window (0.26 s), `damage_taken_multiplier = 0.8`, 5 m turns. No knockback on the player (the player has no knockback API).
- **Grave Warden** (`BossEnemy3D`, `boss = true`), turn chosen from state:
  - **Grave Slam**: marks a pulsing red 2.5 m ring (a `RangeRing3D` plus a faint disc) at the player's feet and shouts `GRAVE SLAM`. At the start of its next turn everyone still inside takes 26: the player through `take_damage`, other enemies (its own summons too) through `take_environment_damage`. A stun on the warden breaks the pending slam.
  - **Phase 1**: on its even turns (the first included) it marks a slam when none is pending, on odd turns it bites through the counter window; a player out of reach always gets a slam.
  - **Phase 2** at <= 50 % health, once: `THE DEAD RISE`, two wolves (`wolf_3d.tscn`) rise beside it as siblings (`snap_to` on the navmesh, group `enemies`, `set_target(player)`, turn mode when a fight runs, `alert()`, then `call_group("level_coordinator", "register_spawned_enemy", wolf)`). From then on it marks a slam and bites in the same turn when in reach.
  - **Boss bar**: a screen-top CanvasLayer (name, bar, `Phase n`) shown while in turn mode and within 16 m of the player, hidden on death. `show_boss_bar = false` hands it to a HUD.
  - **Death**: 1.1 s topple, `THE WARDEN FALLS` banner, heavy shake and rings, 400 XP, and guaranteed loot (amulet, ring, two health potions from `ItemFactory` when the scene authors none).

Every enemy defaults to `wander_radius = 0` (stands watch); the map builder sets wandering per instance.

## Statuses

`apply_status(status, turns, power = 0)` adds or refreshes (keeps the longer duration and the higher power). Ids are constants on `Enemy3D`: `STATUS_STUN`, `STATUS_ROOT`, `STATUS_POISON`, `STATUS_BURN`, `STATUS_WEAKEN`, `STATUS_EXPOSE`. Queries: `has_status`, `get_status_turns`, `get_status_power`, `get_statuses()` (a copy: id -> {turns, power}), `get_status_text()`, `is_skipping_turn()`.

| Status | Effect |
| --- | --- |
| stun | `start_turn` gives 0 m and no attack (`try_attack` refuses); popup `STUNNED`. A stun landing mid-turn stops the walk and takes the attack. |
| root | 0 m at `start_turn`, attack kept, the Frost Snare ring; `apply_root(turns)` maps onto it. Landing mid-turn (a trap) stops the walk. |
| poison / burn | `power` damage at `start_turn` (green / orange popups), before the stun and root checks; can kill (the turn then has 0 m and no attack). The tick ignores `expose` and armour. |
| weaken | the swing's damage halves (rounded, at least 1), including the value handed to `begin_enemy_counter_windup` and `resolve_enemy_attack`. |
| expose | incoming hits x1.5 in `_apply_damage`, after `damage_taken_multiplier`. |

Durations count the enemy's own turns and drop at its own `end_turn` (the coordinator's `end_turn` sweep when a fight starts no longer eats a status). A status applied during the enemy's own turn gets one extra turn, because the current turn must not count. All statuses clear in `set_turn_based_combat(false)`. Out of turn mode (a player-placed trap rooting an unaware enemy) one status turn melts every 3 s, like ability cooldowns in exploration; poison and burn do not tick then. The status line (`STUN 1  POISON 2`) is `EnemyStatusLine3D`, a projected label under the health bar.

## Other additions on Enemy3D

- `knockback(from_point, distance_m)`: a shape cast of the body's own collision shape against layer 8 stops it 3 cm short of a prop, the end point is clamped to the navmesh, the slide is a 0.15 s tween; turn budget and aggro are unchanged.
- `is_unaware()`, `is_back_turned_to(point)` (more than 110 degrees off local -Z), `investigate(point)` (calm walk, about 2 s of looking left and right, calm walk home; ignored when alerted or in turn mode).
- `take_environment_damage(amount)`: no `provoked_by_hit`, no aggro; `expose` and armour still apply.
- `get_display_name()`, `get_portrait_color()`, `is_boss()`, `get_effective_detection_range()`, `get_target()`, `alert()`, `get_home_position()`, `get_calm_state()`.
- Detection: `can_spot` and the ring use `detection_range * target.get_detection_multiplier()` (1.0 when the target lacks it). The ring shows the effective radius but never less than 0.6 m, and only rebuilds when the radius moves by more than 2 cm.
- Wandering: `wander_radius`, `wander_pause`; home is the position on the first physics frame. Wandering, investigating and walking home run only while unaware and out of turn mode, at 45 % of `move_speed`. When turn combat ends, a survivor more than 0.5 m from home walks back.
- Humanoid bodies: `idle_clip`, `move_clip` (`trot` default, `walk` for the soul glbs) and `move_clip_reference_speed` (1.878 m/s for the wolf, 1.92 m/s x model scale for a humanoid). `model_tint` duplicates each surface material into an override and multiplies its albedo; white (the default) leaves the model untouched, so the wolf keeps its imported materials.
- `turn_move_override_m` (0 = the coordinator's 6 m) and `damage_taken_multiplier` (1.0 = exact).
- Subclass hooks: `_begin_attack_variant`, `_end_attack_variant`, `_attack_wind_up_seconds`, `_attack_strike_seconds`, `_attack_base_damage`, `_attack_hint_prefix`, `_play_wind_up`, `_play_strike`, `_death_topple_seconds`. The handshake order itself lives only in `_run_attack_sequence_full`.

## Decisions and deviations

- `snap_to` outside turn mode also moves the home point, so a level, a loader or a test that places an enemy does not see it walk back. A knockback does not re-home.
- `set_target` in turn mode only changes the target and no longer routes the agent: the coordinator owns every turn-mode step, and a summon registered mid-fight must not walk freely.
- The status popups and the cultist bolt reuse `CombatFx` and the player's bolt construction; nothing in `player_3d.gd` or `main_3d.gd` changed.
- The warden's slam also hurts enemies in the ring (a way to turn its summons against it). Its bar lives on the boss node; the lead may switch it off for a HUD version.
- XP: wolf 35, dire wolf 70, bandit 50, cultist 55, brute 90, warden 400.

## Test

```powershell
$godot = "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\GodotEngine.GodotEngine_Microsoft.Winget.Source_8wekyb3d8bbwe\Godot_v4.7.2-stable_win64_console.exe"
& $godot --headless --path . res://scenes/3d/tests/enemy_roster_test.tscn --quit-after 3000
```

Prints `ROSTER OK` or `ROSTER FAIL: <step>: <reason>`. It builds a stub player (the WP0 stub plus `get_detection_multiplier`) and a stub `level_coordinator` in code on a flat floor with one prop wall and a runtime navmesh bake, then checks: every roster scene's exports, mesh, clips, turn budget and tint; stun, weaken, refresh, poison, expose, root, the status line and the clear on combat end; poison killing; the dire wolf's 14 / 14 / 21 bites and the brute's 8 (12 exposed) from a 10 hit; knockback away and against the wall; `is_back_turned_to`; the detection multiplier on `can_spot` and the ring (including the 0.6 m minimum and the 2 cm rule); environment damage not provoking and an exploration root melting; wandering inside the radius at the calm pace, investigate and walk home; the cultist's bolt from 6 m and its step back from 1.5 m; the warden's slam hitting a player who stayed and missing one who left, phase 2 raising and registering two wolves, the phase 2 slam-and-bite turn, the bar, and the death with four drops.

The existing checks keep passing: `arena.tscn` (`INTEGRATION OK`), `tests/detection_test.tscn` (`DETECTION OK`), `tests/enemy_test.tscn` (`ENEMY OK`).
