extends Node

## Headless regression test for crowded enemy turns: an enemy whose natural
## attack spot next to the player is already taken by another enemy must pick a
## free spot (or give up on the walk) instead of pushing against its neighbour
## forever, and the enemy turn must hand control back.
##
##   godot --headless --path . res://scenes/3d/tests/crowd_test.tscn --quit-after 3000
##
## Prints CROWD OK or CROWD FAIL: <step>: <reason>.

const Main3D := preload("res://scripts/3d/main_3d.gd")
const ARENA := preload("res://scenes/3d/arena.tscn")
const HEADLESS_FPS := 60
# Two enemy turns with the pacing constants plus a swing each take about 4 s;
# a turn stuck on a blocked walk never hands back.
const ENEMY_TURN_TIMEOUT_SECONDS := 12.0
const PLAYER_POSITION := Vector3(-6.0, 0.0, 0.0)

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
		print("CROWD FAIL: quit during step '%s'" % _step)


func _run() -> void:
	await get_tree().process_frame
	var steps: Array = [
		["boot", _step_boot],
		["blocked_spot", _step_blocked_spot],
		["surrounded", _step_surrounded],
	]
	for entry in steps:
		_step = String(entry[0])
		var step: Callable = entry[1]
		var result: Variant = await step.call()
		var failure := str(result)
		if not failure.is_empty():
			_done = true
			print("CROWD FAIL: %s: %s" % [_step, failure])
			get_tree().quit(1)
			return
		print("[crowd] %s ok" % _step)
	_done = true
	print("CROWD OK")
	get_tree().quit(0)


func _step_boot() -> String:
	if _main == null:
		return "the arena root is not a main_3d.gd coordinator (script failed to load?)"
	_player = _main.player as Player3D
	for node in get_tree().get_nodes_in_group("enemies"):
		var wolf := node as Enemy3D
		if wolf != null and _main.is_ancestor_of(wolf):
			_wolves.append(wolf)
	_wolves.sort_custom(func(a: Enemy3D, b: Enemy3D) -> bool: return String(a.name) < String(b.name))
	if _player == null or _wolves.size() < 3:
		return "expected a Player3D and 3 wolves"
	if not await _wait_until(func() -> bool: return _main.is_navmesh_ready(), 5.0):
		return "navmesh not ready"
	# Nobody spots anyone while the scene is arranged; the fight is started by hand.
	for wolf in _wolves:
		wolf.detection_range = 0.0
	return ""


## Wolf A stands exactly on wolf B's natural attack spot (on the line from the
## player to B). B must still reach the player and bite, and the turn must end.
func _step_blocked_spot() -> String:
	_player.snap_to(PLAYER_POSITION)
	var wolf_a := _wolves[0]
	var wolf_b := _wolves[1]
	var natural_stop := wolf_b.get_attack_approach_distance(_player)
	wolf_a.snap_to(PLAYER_POSITION + Vector3(natural_stop, 0.0, 0.0))
	wolf_b.snap_to(PLAYER_POSITION + Vector3(5.0, 0.0, 0.0))
	_wolves[2].snap_to(Vector3(9.0, 0.0, 9.0))
	await get_tree().physics_frame
	_main._start_turn_based_combat()
	if not _main.engaged_enemies.has(wolf_b.get_instance_id()):
		return "wolf B is not engaged"
	var health_before := _player.health
	var started := Time.get_ticks_msec()
	_main._request_end_player_turn()
	if not await _wait_until(func() -> bool: return _main.combat_state == Main3D.CombatState.PLAYER_TURN, ENEMY_TURN_TIMEOUT_SECONDS):
		return "the enemy turn never handed back (wolf B at %s, %.2f m from the player, moving=%s)" % [
			str(wolf_b.global_position), GroundMath.ground_distance(wolf_b.global_position, _player.global_position), str(wolf_b.is_moving())]
	var reach := GroundMath.ground_distance(wolf_b.global_position, _player.global_position)
	if reach > wolf_b.attack_range + 0.05:
		return "wolf B stopped %.2f m from the player, outside its %.2f m reach" % [reach, wolf_b.attack_range]
	var gap := GroundMath.ground_distance(wolf_b.global_position, wolf_a.global_position)
	if gap < 0.8:
		return "wolf B stands %.2f m from wolf A, on top of it" % gap
	if _player.health >= health_before:
		return "no wolf bit the player (health %d -> %d)" % [health_before, _player.health]
	print("[crowd] turn %.2f s; wolf B %.2f m from the player, %.2f m from wolf A" % [
		float(Time.get_ticks_msec() - started) / 1000.0, reach, gap])
	return ""


## Every spot around the player taken: the extra wolf must give up its walk and
## the turn must still hand back.
func _step_surrounded() -> String:
	_main._end_turn_based_combat()
	await get_tree().physics_frame
	_player.snap_to(PLAYER_POSITION)
	_player.health = _player.max_health
	var extras: Array[Enemy3D] = []
	for i in range(6):
		var extra := _main.enemy_scene.instantiate() as Enemy3D
		_main.add_child(extra)
		extra.detection_range = 0.0
		extras.append(extra)
	await get_tree().physics_frame
	var ring: Array[Enemy3D] = [_wolves[0], _wolves[1], _wolves[2]]
	ring.append_array(extras.slice(0, 4))
	for i in range(ring.size()):
		var angle := TAU * float(i) / float(ring.size())
		ring[i].snap_to(PLAYER_POSITION + Vector3(cos(angle), 0.0, sin(angle)) * 1.15)
	var late_comers: Array[Enemy3D] = [extras[4], extras[5]]
	late_comers[0].snap_to(PLAYER_POSITION + Vector3(4.5, 0.0, 0.5))
	late_comers[1].snap_to(PLAYER_POSITION + Vector3(-4.5, 0.0, -0.5))
	await get_tree().physics_frame
	_main._start_turn_based_combat()
	_main._request_end_player_turn()
	if not await _wait_until(func() -> bool: return _main.combat_state == Main3D.CombatState.PLAYER_TURN or _main.combat_state == Main3D.CombatState.EXPLORATION, ENEMY_TURN_TIMEOUT_SECONDS * 2.0):
		var stuck := ""
		for wolf in late_comers:
			stuck += " %s moving=%s at %.2f m;" % [wolf.name, str(wolf.is_moving()), GroundMath.ground_distance(wolf.global_position, _player.global_position)]
		return "a surrounded player's enemy turn never handed back:%s" % stuck
	for wolf in late_comers:
		if wolf.is_moving():
			return "%s is still walking after its turn" % wolf.name
	return ""


func _wait_until(condition: Callable, timeout_seconds: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if bool(condition.call()):
			return true
		await get_tree().process_frame
	return bool(condition.call())
