extends Node

## Headless test of the gameplay expansion's lead track (docs/gameplay-expansion.md):
## progression and the skill tree, the ability runner with the action and bonus
## action, per-soul movement, sneaking and the detection multiplier, slipping
## away from a fight (by distance and by smoke), respawn after a defeat and the
## coordinator interface. Instances the arena without its IntegrationSmoke node.
##
##   godot --headless --path . res://scenes/3d/tests/gameplay_test.tscn --quit-after 3000
##
## Prints GAMEPLAY OK or GAMEPLAY FAIL: <step>: <reason>. Checks that need track
## B's enemy interface (statuses, is_unaware) are skipped with a note when the
## enemy does not have it yet.

const Main3D := preload("res://scripts/3d/main_3d.gd")
const ARENA := preload("res://scenes/3d/arena.tscn")
const HEADLESS_FPS := 60
const COMBAT_TIMEOUT_SECONDS := 6.0
const ENEMY_TURN_TIMEOUT_SECONDS := 10.0
const PARK_B := Vector3(10.0, 0.0, -10.0)
const PARK_C := Vector3(10.0, 0.0, 10.0)

var _main: Main3D
var _player: Player3D
var _wolves: Array[Enemy3D] = []
var _step := "boot"
var _done := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	Engine.max_fps = HEADLESS_FPS
	var arena := ARENA.instantiate()
	var smoke := arena.get_node_or_null("IntegrationSmoke")
	if smoke != null:
		arena.remove_child(smoke)
		smoke.free()
	add_child(arena)
	_main = arena as Main3D
	call_deferred("_run")


func _exit_tree() -> void:
	if not _done:
		print("GAMEPLAY FAIL: quit during step '%s'" % _step)


func _run() -> void:
	await get_tree().process_frame
	var steps: Array = [
		["boot", _step_boot],
		["progression", _step_progression],
		["skill_tree", _step_skill_tree],
		["sneak", _step_sneak],
		["soul_movement", _step_soul_movement],
		["abilities_in_turn", _step_abilities_in_turn],
		["bonus_then_action", _step_bonus_then_action],
		["spawned_enemy", _step_spawned_enemy],
		["escape_by_distance", _step_escape_by_distance],
		["escape_by_smoke", _step_escape_by_smoke],
		["respawn", _step_respawn],
	]
	for entry in steps:
		_step = String(entry[0])
		var step: Callable = entry[1]
		var result: Variant = await step.call()
		var failure := str(result)
		if not failure.is_empty():
			_done = true
			print("GAMEPLAY FAIL: %s: %s" % [_step, failure])
			get_tree().quit(1)
			return
		print("[gameplay] %s ok" % _step)
	_done = true
	print("GAMEPLAY OK")
	get_tree().quit(0)


# --- Steps ---------------------------------------------------------------------------

func _step_boot() -> String:
	_player = _main.player as Player3D
	if _player == null:
		return "no Player3D"
	for node in get_tree().get_nodes_in_group("enemies"):
		var wolf := node as Enemy3D
		if wolf != null and _main.is_ancestor_of(wolf):
			_wolves.append(wolf)
	_wolves.sort_custom(func(a: Enemy3D, b: Enemy3D) -> bool: return String(a.name) < String(b.name))
	if _wolves.size() < 3:
		return "expected 3 wolves, found %d" % _wolves.size()
	if not await _wait_until(func() -> bool: return _main.is_navmesh_ready(), 5.0):
		return "navmesh not ready"
	if _main.ability_runner == null or _main.ability_runner.player != _player:
		return "the coordinator has no AbilityRunner wired to the player"
	if not _main.is_in_group("level_coordinator"):
		return "the coordinator is not in group level_coordinator"
	# Keep the wolves out of the way until a step wants one.
	_wolves[0].snap_to(Vector3(8.0, 0.0, 0.0))
	_wolves[1].snap_to(PARK_B)
	_wolves[2].snap_to(PARK_C)
	return ""


func _step_progression() -> String:
	var progression := _player.get_progression()
	if progression == null:
		return "the player has no Progression3D"
	if progression.skill_points != Progression3D.STARTING_SKILL_POINTS:
		return "%d skill points at start, expected %d" % [progression.skill_points, Progression3D.STARTING_SKILL_POINTS]
	for starter in [AbilityCatalog3D.SHIELD_BASH, AbilityCatalog3D.BACKSTAB, AbilityCatalog3D.SHADOWSTEP, AbilityCatalog3D.BLINK]:
		if not progression.is_learned(starter):
			return "%s is not learned at start" % starter
	if progression.is_learned(AbilityCatalog3D.CLEAVE):
		return "Cleave is learned at start"
	if progression.learn(AbilityCatalog3D.CLEAVE):
		return "Cleave (level 2) was learned at level 1"
	var health_before := _player.max_health
	_player.add_experience(int(_player.get_xp_required_for_next_level()))
	if _player.get_player_level() != 2:
		return "level %d after a level's worth of XP" % _player.get_player_level()
	if progression.skill_points != Progression3D.STARTING_SKILL_POINTS + 1:
		return "%d skill points after the level up" % progression.skill_points
	if _player.max_health != health_before + Progression3D.HEALTH_PER_LEVEL:
		return "max health %d -> %d, expected +%d per level" % [health_before, _player.max_health, Progression3D.HEALTH_PER_LEVEL]
	if not progression.learn(AbilityCatalog3D.CLEAVE):
		return "Cleave refused at level 2: %s" % progression.learn_block_reason(AbilityCatalog3D.CLEAVE)
	if progression.learn(AbilityCatalog3D.CHARGE):
		return "Charge (level 4) was learned at level 2"
	var health_now := _player.max_health
	if not progression.raise_passive(Progression3D.PASSIVE_VITALITY):
		return "Vitality refused: %s" % progression.passive_block_reason(Progression3D.PASSIVE_VITALITY)
	if _player.max_health != health_now + Progression3D.VITALITY_HEALTH_PER_RANK:
		return "Vitality raised max health %d -> %d" % [health_now, _player.max_health]
	if progression.skill_points != 0:
		return "%d points left after spending two" % progression.skill_points
	# The ability bar follows the learned list of the soul in control.
	var bar_ids: Array[StringName] = []
	for ability in _main._bar_abilities():
		bar_ids.append(ability.id)
	if not bar_ids.has(AbilityCatalog3D.CLEAVE) or not bar_ids.has(AbilityCatalog3D.SHIELD_BASH):
		return "the knight's bar is %s" % str(bar_ids)
	return ""


func _step_skill_tree() -> String:
	var screen := _main.skill_tree_screen
	if screen == null:
		return "no skill tree screen"
	_main._toggle_skill_tree()
	if not screen.is_open() or not get_tree().paused:
		return "K did not open the tree and pause the world"
	await get_tree().process_frame
	_main._toggle_skill_tree()
	if screen.is_open() or get_tree().paused:
		return "the tree did not close and unpause"
	return ""


func _step_sneak() -> String:
	if not is_equal_approx(_player.get_detection_multiplier(), 1.0):
		return "multiplier %.2f while walking upright" % _player.get_detection_multiplier()
	var speed := _player.move_speed
	_main._toggle_sneak()
	if not _player.is_sneaking():
		return "C did not start sneaking"
	if not is_equal_approx(_player.get_detection_multiplier(), Player3D.DETECTION_MULT_SNEAK):
		return "knight sneak multiplier %.2f" % _player.get_detection_multiplier()
	if _player.move_speed >= speed:
		return "sneaking did not slow the walk"
	_main._request_shift(int(Soul.Kind.ROGUE))
	if not is_equal_approx(_player.get_detection_multiplier(), Player3D.DETECTION_MULT_SNEAK_ROGUE):
		return "rogue sneak multiplier %.2f" % _player.get_detection_multiplier()
	var zone := Node.new()
	add_child(zone)
	_player.set_in_cover(zone, true)
	if not _player.is_hidden() or _player.get_detection_multiplier() != 0.0:
		return "sneaking in cover is not hidden"
	_player.set_in_cover(zone, false)
	zone.queue_free()
	var wolf := _wolves[0]
	if wolf.has_method("get_effective_detection_range"):
		var effective := float(wolf.call("get_effective_detection_range"))
		if effective >= wolf.detection_range:
			return "the wolf's effective detection %.2f m did not shrink while sneaking" % effective
	else:
		print("[gameplay] note: Enemy3D has no get_effective_detection_range yet (track B); ring shrink not checked")
	# Sneak attack multiplier needs the enemy's is_unaware (track B).
	if wolf.has_method("is_unaware"):
		if _player.stealth_multiplier_against(wolf) != Player3D.SNEAK_ATTACK_MULT_ROGUE:
			return "sneak attack multiplier %.1f against an unaware wolf" % _player.stealth_multiplier_against(wolf)
	else:
		print("[gameplay] note: Enemy3D has no is_unaware yet (track B); sneak attack not checked")
	_main._toggle_sneak()
	if _player.is_sneaking() or not is_equal_approx(_player.move_speed, speed):
		return "C did not stop sneaking and restore the walk"
	_main._request_shift(int(Soul.Kind.KNIGHT))
	return ""


func _step_soul_movement() -> String:
	await _start_fight_with(_wolves[0], 2.5)
	if _main.combat_state != Main3D.CombatState.PLAYER_TURN:
		return "no player turn (state %d)" % _main.combat_state
	var knight_budget := _player.get_turn_remaining_move_meters()
	if absf(knight_budget - Main3D.TURN_MOVE_METERS) > 0.01:
		return "knight budget %.2f m" % knight_budget
	_main._request_shift(int(Soul.Kind.ROGUE))
	var rogue_budget := _player.get_turn_remaining_move_meters()
	if absf(rogue_budget - (knight_budget + 2.0)) > 0.01:
		return "rogue budget %.2f m after the shift, expected %.2f" % [rogue_budget, knight_budget + 2.0]
	return ""


func _step_abilities_in_turn() -> String:
	var wolf := _wolves[0]
	# Rogue in control from the last step; Backstab is an action ability.
	var backstab := AbilityCatalog3D.get_ability(AbilityCatalog3D.BACKSTAB)
	_player.snap_to(wolf.global_position + Vector3(1.0, 0.0, 0.0))
	await get_tree().physics_frame
	var before := wolf.health
	await _main._execute_ability(backstab, wolf, null)
	if wolf.health >= before:
		return "Backstab did no damage (%d -> %d)" % [before, wolf.health]
	if wolf.is_alive() and _player.has_action():
		return "Backstab did not spend the action"
	if _main.ability_runner.block_reason(backstab).is_empty() and wolf.is_alive():
		return "a second action ability is allowed in the same turn"
	# Shield Bash is the knight's; the rogue's bar does not carry it.
	for ability in _main._bar_abilities():
		if ability.id == AbilityCatalog3D.SHIELD_BASH:
			return "the rogue's bar shows Shield Bash"
	print("[gameplay] backstab %d -> %d" % [before, wolf.health])
	return ""


func _step_bonus_then_action() -> String:
	# Next player turn: Shadowstep (bonus) behind the wolf, then Blink is
	# refused (the bonus is spent) even after a shift to the mage.
	if not await _end_turn_and_wait():
		return "the enemy turn did not hand back"
	var wolf := _alive_wolf_near()
	if wolf == null:
		return "no wolf left to test against"
	var step := AbilityCatalog3D.get_ability(AbilityCatalog3D.SHADOWSTEP)
	if _player.get_active_soul().kind != Soul.Kind.ROGUE:
		_main._request_shift(int(Soul.Kind.ROGUE))
	_player.snap_to(wolf.global_position + Vector3(4.0, 0.0, 0.0))
	await get_tree().physics_frame
	await _main._execute_ability(step, wolf, null)
	var gap := GroundMath.ground_distance(_player.global_position, wolf.global_position)
	if gap > 1.6:
		return "Shadowstep left the rogue %.2f m from the wolf" % gap
	if _player.has_bonus_action():
		return "Shadowstep did not spend the bonus action"
	if not _player.has_action():
		return "Shadowstep spent the action"
	_main._request_shift(int(Soul.Kind.MAGE))
	var blink := AbilityCatalog3D.get_ability(AbilityCatalog3D.BLINK)
	var reason := _main.ability_runner.block_reason(blink)
	if reason.is_empty():
		return "Blink allowed with the bonus action spent"
	return ""


func _step_spawned_enemy() -> String:
	var extra := _main.enemy_scene.instantiate() as Enemy3D
	_main.add_child(extra)
	extra.snap_to(_player.global_position + Vector3(0.0, 0.0, 3.0))
	get_tree().call_group("level_coordinator", "register_spawned_enemy", extra)
	if not _main.engaged_enemies.has(extra.get_instance_id()):
		return "register_spawned_enemy did not engage the newcomer"
	if not extra.is_in_turn_based_combat():
		return "the newcomer is not in turn mode"
	extra.receive_damage(1000)
	await get_tree().process_frame
	return ""


func _step_escape_by_distance() -> String:
	if _main.combat_state == Main3D.CombatState.EXPLORATION:
		await _start_fight_with(_alive_wolf_near(), 2.5)
	if _main.combat_state != Main3D.CombatState.PLAYER_TURN:
		if not await _wait_until(func() -> bool: return _main.combat_state == Main3D.CombatState.PLAYER_TURN, ENEMY_TURN_TIMEOUT_SECONDS):
			return "no player turn to escape from (state %d)" % _main.combat_state
	# Out of reach and out of sight: across the clearing.
	var far := Vector3(-9.0, 0.0, 0.0)
	for wolf in _main._get_all_alive_enemies():
		if GroundMath.ground_distance(wolf.global_position, far) <= Main3D.ESCAPE_ANY_SIGHT_M:
			wolf.snap_to(Vector3(9.0, 0.0, 9.0))
	_player.snap_to(far)
	await get_tree().physics_frame
	if not _main._player_escaped():
		return "not escaped at %.1f m from the nearest engaged wolf" % _nearest_engaged_distance()
	_main._request_end_player_turn()
	if _main.combat_state != Main3D.CombatState.EXPLORATION:
		return "ending the turn out of reach did not end the fight (state %d)" % _main.combat_state
	return ""


func _step_escape_by_smoke() -> String:
	var wolf := _alive_wolf_near()
	if wolf == null:
		return "no wolf left"
	await _start_fight_with(wolf, 2.5)
	if _main.combat_state != Main3D.CombatState.PLAYER_TURN:
		return "no player turn (state %d)" % _main.combat_state
	_player.apply_smoke_cover()
	if not _player.is_hidden_by_smoke():
		return "smoke does not hide the body"
	_player.snap_to(wolf.global_position + Vector3(4.0, 0.0, 0.0))
	await get_tree().physics_frame
	_main._request_end_player_turn()
	if _main.combat_state != Main3D.CombatState.EXPLORATION:
		return "ending the turn in smoke 4 m away did not end the fight (state %d)" % _main.combat_state
	return ""


func _step_respawn() -> String:
	var spawn := _main._respawn_point
	_player.snap_to(Vector3(4.0, 0.0, -6.0))
	_player.take_damage(10000)
	if _player.is_alive():
		return "the player survived 10000 damage"
	if not await _wait_until(func() -> bool: return _player.is_alive(), Main3D.RESPAWN_DELAY_SECONDS + 2.0):
		return "the player was not revived within %.1f s" % (Main3D.RESPAWN_DELAY_SECONDS + 2.0)
	if GroundMath.ground_distance(_player.global_position, spawn) > 0.6:
		return "revived %.2f m from the respawn point" % GroundMath.ground_distance(_player.global_position, spawn)
	if _player.health != _player.max_health:
		return "revived with %d / %d health" % [_player.health, _player.max_health]
	if _player.collision_layer != 2:
		return "revived body is on collision layer %d" % _player.collision_layer
	return ""


# --- Helpers ---------------------------------------------------------------------------

## Places `wolf` `distance` m from the player and starts the fight (player first).
func _start_fight_with(wolf: Enemy3D, distance: float) -> void:
	if wolf == null:
		return
	wolf.snap_to(_player.global_position + Vector3(distance, 0.0, 0.0))
	if _main.combat_state == Main3D.CombatState.EXPLORATION:
		_main._start_turn_based_combat()
	await get_tree().physics_frame


func _end_turn_and_wait() -> bool:
	_main._request_end_player_turn()
	return await _wait_until(func() -> bool:
		return _main.combat_state == Main3D.CombatState.PLAYER_TURN or _main.combat_state == Main3D.CombatState.EXPLORATION,
		ENEMY_TURN_TIMEOUT_SECONDS)


func _alive_wolf_near() -> Enemy3D:
	var best: Enemy3D = null
	var best_distance := INF
	for wolf in _wolves:
		if not is_instance_valid(wolf) or not wolf.is_alive():
			continue
		var d := GroundMath.ground_distance(wolf.global_position, _player.global_position)
		if d < best_distance:
			best = wolf
			best_distance = d
	return best


func _nearest_engaged_distance() -> float:
	var best := INF
	for wolf in _main._get_all_alive_enemies():
		best = minf(best, GroundMath.ground_distance(wolf.global_position, _player.global_position))
	return best


func _wait_until(condition: Callable, timeout_seconds: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if bool(condition.call()):
			return true
		await get_tree().process_frame
	return bool(condition.call())
