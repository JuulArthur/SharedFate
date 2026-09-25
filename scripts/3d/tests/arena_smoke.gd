extends Node

## Headless smoke test for the real arena (WP7, scenes/3d/arena.tscn). Child of
## the arena root named "Smoke" (the coordinator ignores unknown children,
## docs/3d-port-contracts.md section 9).
##
## Headless has no clicks, so this drives the coordinator directly: waits for
## the navmesh, checks the player spawned at Spawn_default, checks a navmesh
## path across the clearing, checks every tree/crate/chest carries a layer-8
## collider, checks the camera rig owns the active camera, then requests an
## exploration move toward the nearest enemy (main._request_player_move, the
## same method a ground click resolves to) and waits for combat to start.
## Prints ARENA OK or the first failing check with values.
##
## Run: godot --headless --path . res://scenes/3d/arena.tscn --quit-after 600

const Main3D := preload("res://scripts/3d/main_3d.gd")

const HEADLESS_FPS := 60
const NAVMESH_TIMEOUT_SECONDS := 5.0
const COMBAT_TIMEOUT_SECONDS := 6.0
const SPAWN_TOLERANCE_M := 0.5
const PATH_TARGET_DISTANCE_M := 10.0
const PATH_MAX_LENGTH_M := 20.0
const PROP_LAYER := 8

var _step := "boot"
var _done := false


func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		Engine.max_fps = HEADLESS_FPS
	call_deferred("_run")


func _exit_tree() -> void:
	if not _done:
		print("ARENA FAIL: quit during step '%s'" % _step)


func _run() -> void:
	await get_tree().process_frame

	var main := get_parent() as Main3D
	if main == null:
		_fail("main_3d.gd is not on the parent node")
		return
	var player := main.player
	var spawn := main.find_child("Spawn_default", true, false) as Node3D
	if player == null or spawn == null:
		_fail("player or Spawn_default missing from the scene")
		return

	# 1. Navmesh.
	_step = "navmesh"
	if not await _wait_until(func() -> bool: return main.is_navmesh_ready(), NAVMESH_TIMEOUT_SECONDS):
		_fail("navmesh did not become ready within %.1f s" % NAVMESH_TIMEOUT_SECONDS)
		return

	# 2. The player spawns at Spawn_default.
	_step = "spawn_position"
	var spawn_gap := GroundMath.ground_distance(player.global_position, spawn.global_position)
	if spawn_gap > SPAWN_TOLERANCE_M:
		_fail("player is %.2f m from Spawn_default, expected within %.2f m" % [spawn_gap, SPAWN_TOLERANCE_M])
		return

	# 3. A navmesh path across the clearing.
	_step = "clearing_path"
	var nav_map: RID = main.get_world_3d().navigation_map
	var target := spawn.global_position + Vector3(PATH_TARGET_DISTANCE_M, 0.0, 0.0)
	var from_point := NavigationServer3D.map_get_closest_point(nav_map, spawn.global_position)
	var to_point := NavigationServer3D.map_get_closest_point(nav_map, target)
	var path := NavigationServer3D.map_get_path(nav_map, from_point, to_point, true)
	if path.size() < 2:
		_fail("navmesh path from spawn has %d point(s), expected at least 2" % path.size())
		return
	var path_length := 0.0
	for i in range(1, path.size()):
		path_length += GroundMath.ground_distance(path[i - 1], path[i])
	if path_length >= PATH_MAX_LENGTH_M:
		_fail("navmesh path across the clearing is %.2f m, expected under %.2f m" % [path_length, PATH_MAX_LENGTH_M])
		return
	print("[arena_smoke] clearing path: %d points, %.2f m" % [path.size(), path_length])

	# 4. Every tree, the crate and the chest carry a layer-8 collider.
	_step = "prop_colliders"
	var props := get_tree().get_nodes_in_group("navmesh_source")
	if props.is_empty():
		_fail("no props found in group 'navmesh_source'")
		return
	for prop: Node in props:
		if not (prop is Node3D) or not main.is_ancestor_of(prop):
			continue
		if not _has_layer_collider(prop, PROP_LAYER):
			_fail("%s has no StaticBody3D on layer %d" % [prop.name, PROP_LAYER])
			return
	print("[arena_smoke] %d props on layer %d" % [props.size(), PROP_LAYER])

	# 5. The camera rig owns the active camera.
	_step = "camera_rig"
	var rig := main.get_node_or_null("CameraRig")
	if rig == null or not rig.has_method("get_camera"):
		_fail("no CameraRig with get_camera() under the arena root")
		return
	var camera: Camera3D = rig.call("get_camera")
	if camera == null or not camera.current:
		_fail("CameraRig's camera is not current")
		return
	print("[arena_smoke] camera rig owns the active camera")

	# 6. An exploration move toward the nearest enemy starts combat.
	_step = "combat_start"
	if main.combat_state != Main3D.CombatState.EXPLORATION:
		_fail("expected EXPLORATION before the first move, got %d" % main.combat_state)
		return
	var enemy := _closest_enemy(player)
	if enemy == null:
		_fail("no enemy found in group 'enemies'")
		return
	# Aim the whole way at the enemy; the coordinator halts the player as soon
	# as combat starts (well before arrival), so overshooting the target is
	# harmless and keeps this robust to exactly which enemy is closest.
	main._request_player_move(enemy.global_position)
	if not await _wait_until(func() -> bool: return main.combat_state != Main3D.CombatState.EXPLORATION, COMBAT_TIMEOUT_SECONDS):
		_fail("combat did not start within %.1f s (state %d)" % [COMBAT_TIMEOUT_SECONDS, main.combat_state])
		return
	print("[arena_smoke] combat state left EXPLORATION (now %d)" % main.combat_state)

	_done = true
	print("ARENA OK")


func _has_layer_collider(node: Node, layer_bit: int) -> bool:
	if node is StaticBody3D and ((node as StaticBody3D).collision_layer & layer_bit) != 0:
		return true
	for child in node.get_children():
		if _has_layer_collider(child, layer_bit):
			return true
	return false


func _closest_enemy(player: CharacterBody3D) -> CharacterBody3D:
	var closest: CharacterBody3D = null
	var closest_dist := INF
	for node in get_tree().get_nodes_in_group("enemies"):
		if not (node is CharacterBody3D):
			continue
		var actor := node as CharacterBody3D
		var d := GroundMath.ground_distance(player.global_position, actor.global_position)
		if d < closest_dist:
			closest_dist = d
			closest = actor
	return closest


func _fail(reason: String) -> void:
	_done = true
	print("ARENA FAIL: %s: %s" % [_step, reason])
	get_tree().quit(1)


func _wait_until(condition: Callable, timeout_seconds: float) -> bool:
	var waited := 0.0
	while waited < timeout_seconds:
		if bool(condition.call()):
			return true
		await get_tree().process_frame
		waited += get_process_delta_time()
	return bool(condition.call())
