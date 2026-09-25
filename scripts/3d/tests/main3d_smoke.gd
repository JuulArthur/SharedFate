extends Node

## Headless smoke test for main_3d.gd (WP4). Child of the test scene root
## (scenes/3d/tests/main3d_stub_arena.tscn), which runs main_3d.gd against the
## WP0 stub actors.
##
## Headless has no clicks, so once the navmesh is baked this drives the
## coordinator's request methods directly through one scripted sequence:
## exploration move, wait for combat to start when the stub enemy spots the
## player, one turn move within budget, one melee attack, End Turn, one enemy
## turn. Prints `SMOKE OK` or `SMOKE FAIL: <step>: <reason>` for the first
## failing step. Run with
##
##   godot --headless --path . res://scenes/3d/tests/main3d_stub_arena.tscn --quit-after 240
##
## Placement: the stub enemy is 5 m from the spawn (4 cells in x, 3 in z), one
## metre outside its 4 m `aggro_range`, which the coordinator reads as the
## stub's detection distance (WP13; the 2D Manhattan-cell trigger is gone), so
## exploration lasts until the first move closes the gap.

const Main3D := preload("res://scripts/3d/main_3d.gd")

# Headless Godot paces at about 145 fps (the low-processor sleep), so 240
# frames would be under two seconds of game time. Pinning 60 fps makes the
# frame budget four seconds, as in the editor. Only applied when headless.
const HEADLESS_FPS := 60
const STEP_TIMEOUT_SECONDS := 3.0
const NAVMESH_TIMEOUT_SECONDS := 6.0
const EXPLORATION_STEP_M := 2.0
const RANGE_TOLERANCE_M := 0.05

var _step := "boot"
var _done := false


func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		Engine.max_fps = HEADLESS_FPS
	# The parent's _ready runs after this one; start once the tree has settled.
	call_deferred("_run")


func _exit_tree() -> void:
	if not _done:
		print("SMOKE FAIL: quit during step '%s'" % _step)


func _run() -> void:
	await get_tree().process_frame

	var main := get_parent() as Main3D
	if main == null:
		_fail("main_3d.gd is not on the parent node")
		return
	var player := main.player
	var enemy := get_tree().get_first_node_in_group("enemies") as CharacterBody3D
	if player == null or enemy == null:
		_fail("player or enemy missing from the scene")
		return

	# 1. Navmesh.
	_step = "navmesh"
	if not await _wait_until(func() -> bool: return main.is_navmesh_ready(), NAVMESH_TIMEOUT_SECONDS):
		_fail("navmesh did not bake in %.1f s" % NAVMESH_TIMEOUT_SECONDS)
		return

	# 2. Exploration move toward the enemy.
	_step = "exploration_move"
	if main.combat_state != Main3D.CombatState.EXPLORATION:
		_fail("expected EXPLORATION before the first move, got %d" % main.combat_state)
		return
	var toward_enemy := GroundMath.ground_direction(player.global_position, enemy.global_position)
	main._request_player_move(player.global_position + toward_enemy * EXPLORATION_STEP_M)
	if not bool(player.call("is_moving")):
		_fail("player did not start moving after _request_player_move")
		return

	# 3. Combat starts once the player is inside the stub's 4 m aggro_range
	# (WP13: the coordinator's detection fallback for an enemy without can_spot).
	_step = "combat_start"
	if not await _wait_until(func() -> bool: return main.combat_state == Main3D.CombatState.PLAYER_TURN, STEP_TIMEOUT_SECONDS):
		_fail("combat did not start within %.1f s (state %d)" % [STEP_TIMEOUT_SECONDS, main.combat_state])
		return
	var budget := float(player.call("get_turn_remaining_move_meters"))
	if absf(budget - Main3D.TURN_MOVE_METERS) > 0.001:
		_fail("turn budget is %.2f m, expected %.2f m" % [budget, Main3D.TURN_MOVE_METERS])
		return

	# 4. One turn move within budget: walk to the melee approach point.
	_step = "turn_move"
	var approach_distance := float(player.call("get_preferred_attack_approach_distance"))
	var approach_point := main._compute_approach_world_point(player.global_position, enemy.global_position, approach_distance)
	main._request_player_turn_move(approach_point)
	var remaining := float(player.call("get_turn_remaining_move_meters"))
	if remaining >= budget:
		_fail("turn move consumed no movement (remaining %.2f m)" % remaining)
		return
	if remaining < 0.0:
		_fail("turn move overspent the budget (remaining %.2f m)" % remaining)
		return
	if not await _wait_until(func() -> bool: return not bool(player.call("is_moving")), STEP_TIMEOUT_SECONDS):
		_fail("player still moving after %.1f s" % STEP_TIMEOUT_SECONDS)
		return
	var melee_range := float(player.call("get_melee_range"))
	var gap := GroundMath.ground_distance(player.global_position, enemy.global_position)
	if gap > melee_range + RANGE_TOLERANCE_M:
		_fail("player stopped %.2f m from the enemy, melee range is %.2f m" % [gap, melee_range])
		return
	print("[smoke] turn move used %.2f m, %.2f m left, %.2f m to the enemy" % [budget - remaining, remaining, gap])

	# 5. One melee attack.
	_step = "melee_attack"
	var enemy_health_before := int(enemy.get("health"))
	await main._request_player_turn_attack(enemy)
	var enemy_health_after := int(enemy.get("health"))
	if enemy_health_after >= enemy_health_before:
		_fail("melee attack did not damage the enemy (%d -> %d)" % [enemy_health_before, enemy_health_after])
		return
	if bool(player.call("can_turn_attack")):
		_fail("attack still available after the swing")
		return
	print("[smoke] melee hit: enemy %d -> %d" % [enemy_health_before, enemy_health_after])

	# 6. End Turn.
	_step = "end_turn"
	main._request_end_player_turn()
	if main.combat_state != Main3D.CombatState.ENEMY_TURN:
		_fail("End Turn did not hand over to the enemy (state %d)" % main.combat_state)
		return

	# 7. One enemy turn: the enemy acts and control comes back.
	_step = "enemy_turn"
	var player_health_before := int(player.get("health"))
	var enemy_turn_budget := STEP_TIMEOUT_SECONDS + Main3D.ENEMY_TURN_DELAY_SECONDS + Main3D.ENEMY_TURN_HANDBACK_SECONDS
	if not await _wait_until(func() -> bool: return main.combat_state == Main3D.CombatState.PLAYER_TURN, enemy_turn_budget):
		_fail("enemy turn did not hand back within %.1f s (state %d)" % [enemy_turn_budget, main.combat_state])
		return
	var player_health_after := int(player.get("health"))
	if player_health_after >= player_health_before:
		_fail("enemy turn dealt no damage to the player (%d -> %d)" % [player_health_before, player_health_after])
		return
	print("[smoke] enemy turn: player %d -> %d, back to PLAYER_TURN" % [player_health_before, player_health_after])

	_done = true
	print("SMOKE OK")


func _fail(reason: String) -> void:
	_done = true
	print("SMOKE FAIL: %s: %s" % [_step, reason])
	get_tree().quit(1)


func _wait_until(condition: Callable, timeout_seconds: float) -> bool:
	var waited := 0.0
	while waited < timeout_seconds:
		if bool(condition.call()):
			return true
		await get_tree().process_frame
		waited += get_process_delta_time()
	return bool(condition.call())
