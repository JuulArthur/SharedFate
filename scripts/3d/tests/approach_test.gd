extends Node3D

## WP10 "Approach spacing": diagnosis and acceptance test for how the player and
## a wolf close in on each other to attack. The real `player_3d.tscn` and one
## `wolf_3d.tscn` on an arena-style floor with a runtime navmesh bake.
##
## Three phases, each logged per physics frame (ground distance between the two
## bodies, the surface gap, both velocity magnitudes, and any displacement a body
## did not command itself, which is the "bump"):
##
##   A  realtime: the wolf aggroes and closes on a standing player;
##   B  realtime: the player is sent to attack a wolf that is also approaching;
##   C  turn mode: the coordinator-style engage (path to the enemy, trim to the
##      budget, attack), then the enemy's turn (path, trim, bite).
##
## Prints the per-phase numbers and `APPROACH OK` when no frame shows a bump
## above BUMP_EPS_M and both bodies come to rest with at least MIN_SURFACE_GAP_M
## between their surfaces, else `APPROACH FAIL: ...` with the values.
##
##   godot --headless --path . res://scenes/3d/tests/approach_test.tscn --quit-after 900

const Main3D := preload("res://scripts/3d/main_3d.gd")

const CAMERA_SIZE_M := 24.0
const CAMERA_YAW_DEG := 45.0
const CAMERA_PITCH_DEG := -35.0
const CAMERA_DISTANCE := 30.0

const NAV_MAP_FRAMES := 60
const NAV_MAP_TOLERANCE_M := 0.5
const MAP_PROBE := Vector3(0.0, 0.0, 2.5)

## Phase A: the wolf starts inside its 5 m detection range of a standing player
## (WP13; with no coordinator in the scene the realtime chase and bite run).
const A_PLAYER := Vector3(0.0, 0.0, 0.0)
const A_WOLF := Vector3(3.5, 0.0, 0.0)
const A_MAX_SECONDS := 3.5
## Phase B: 5 m apart, both approaching; the wolf is already provoked from A.
const B_PLAYER := Vector3(-2.5, 0.0, 0.0)
const B_WOLF := Vector3(2.5, 0.0, 0.0)
const B_MAX_SECONDS := 4.5
## Phase C: 4 m apart, inside one 6 m turn move.
const C_PLAYER := Vector3(-2.0, 0.0, 0.0)
const C_WOLF := Vector3(2.0, 0.0, 0.0)
const C_MOVE_TIMEOUT := 3.0
## Once the first hit has landed, keep logging this long to catch pushing
## between two bodies that both believe they are standing still.
const SETTLE_SECONDS := 1.2

## A body that commands no movement may not be displaced by more than this in
## one frame; a walking body may not be displaced by more than its own step.
const BUMP_EPS_M := 0.02
const MIN_SURFACE_GAP_M := 0.1
const LOG_EVERY_FRAMES := 12

@onready var camera: Camera3D = $Camera3D
@onready var sun: DirectionalLight3D = $Sun
@onready var nav_region: NavigationRegion3D = $NavigationRegion3D
@onready var player: Player3D = $Player
@onready var wolf: Enemy3D = $Wolf

var _finished := false
var _phase := ""
var _frame := 0
var _phase_frame := 0
var _phase_time := 0.0

# Per-frame watcher state (the root's _physics_process runs before the actors',
# so it sees the world after the previous frame completed).
var _watching := false
var _prev_player := Vector3.ZERO
var _prev_wolf := Vector3.ZERO
var _prev_player_walks := false
var _prev_wolf_walks := false
var _have_prev := false
var _player_computed_calls := 0
var _wolf_computed_calls := 0
var _player_phantom_calls := 0
var _wolf_phantom_calls := 0

# Per-phase statistics.
var _stats: Dictionary = {}
var _phase_reports: Array[String] = []
var _failures: Array[String] = []


func _ready() -> void:
	Engine.max_fps = 60
	_setup_camera()
	sun.rotation_degrees = Vector3(-55.0, 30.0, 0.0)
	CombatFx.set_world_projector(func(p: Variant) -> Vector2: return camera.unproject_position(p as Vector3))

	nav_region.bake_finished.connect(_on_bake_finished)
	nav_region.bake_navigation_mesh()


func _exit_tree() -> void:
	CombatFx.set_world_projector(Callable())
	CombatFx.set_shake_target(null)
	if not _finished:
		print("APPROACH FAIL: quit during phase '%s'" % _phase)


func _setup_camera() -> void:
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = CAMERA_SIZE_M
	camera.near = 0.1
	camera.far = 200.0
	camera.current = true
	var back := Vector3(0.0, 0.0, CAMERA_DISTANCE)
	back = back.rotated(Vector3.RIGHT, deg_to_rad(CAMERA_PITCH_DEG))
	back = back.rotated(Vector3.UP, deg_to_rad(CAMERA_YAW_DEG))
	camera.global_position = back
	camera.look_at(Vector3.ZERO, Vector3.UP)


func _on_bake_finished() -> void:
	await _wait_for_navigation_map()
	_run()


func _wait_for_navigation_map() -> void:
	var map := get_world_3d().navigation_map
	for _i in range(NAV_MAP_FRAMES):
		await get_tree().physics_frame
		var closest := NavigationServer3D.map_get_closest_point(map, MAP_PROBE)
		if GroundMath.ground_distance(closest, MAP_PROBE) < NAV_MAP_TOLERANCE_M:
			return
	push_error("[approach_test] the navigation map never picked up the baked mesh")


# --- Driver -------------------------------------------------------------------------

func _run() -> void:
	# Neither body may die during the test; health is the base class's plain var.
	player.health = 100000
	wolf.health = 100000
	player.navigation_agent.velocity_computed.connect(_on_player_velocity_computed)
	wolf.navigation_agent.velocity_computed.connect(_on_wolf_velocity_computed)
	_print_geometry()

	await _phase_a()
	await _phase_b()
	await _phase_c()

	for report in _phase_reports:
		print(report)
	if _failures.is_empty():
		print("APPROACH OK")
	else:
		print("APPROACH FAIL: %s" % "; ".join(_failures))
	_finished = true
	get_tree().quit()


func _print_geometry() -> void:
	var player_shape := player.collision_shape.shape
	var wolf_shape := wolf.collision_shape.shape
	var player_desc := "?"
	if player_shape is CapsuleShape3D:
		player_desc = "capsule r=%.2f" % (player_shape as CapsuleShape3D).radius
	var wolf_desc := "?"
	if wolf_shape is BoxShape3D:
		wolf_desc = "box %s" % str((wolf_shape as BoxShape3D).size)
	var wolf_bounds := _model_bounds(wolf.get_node_or_null("Model"))
	print("[approach] player %s mask %d, reach %.2f m; wolf %s mask %d, reach %.2f m, model AABB %s..%s" % [
		player_desc, player.collision_mask, player.get_melee_range(),
		wolf_desc, wolf.collision_mask, wolf.attack_range,
		str(wolf_bounds.position), str(wolf_bounds.end)])
	print("[approach] agents: player target_desired %.2f avoid r=%.2f, wolf target_desired %.2f avoid r=%.2f" % [
		player.navigation_agent.target_desired_distance, player.navigation_agent.radius,
		wolf.navigation_agent.target_desired_distance, wolf.navigation_agent.radius])


func _model_bounds(model: Node3D) -> AABB:
	var bounds := AABB()
	var first := true
	if model == null:
		return bounds
	var stack: Array[Node] = [model]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children():
			stack.append(child)
		var mesh := node as MeshInstance3D
		if mesh == null or mesh.mesh == null:
			continue
		var box: AABB = (model.global_transform.affine_inverse() * mesh.global_transform) * mesh.get_aabb()
		if first:
			bounds = box
			first = false
		else:
			bounds = bounds.merge(box)
	return bounds


# --- Phase A: the wolf closes on a standing player ------------------------------------

func _phase_a() -> void:
	_begin_phase("A realtime wolf -> standing player")
	_reset_actors(A_PLAYER, A_WOLF)
	wolf.set_target(player)
	var health_before := player.health
	var bitten := await _wait_until(func() -> bool: return player.health < health_before, A_MAX_SECONDS)
	if bitten:
		await _wait(SETTLE_SECONDS)
	_end_phase(bitten, "the wolf never bit within %.1f s" % A_MAX_SECONDS)


# --- Phase B: both approach -------------------------------------------------------------

func _phase_b() -> void:
	_begin_phase("B realtime both approach")
	_reset_actors(B_PLAYER, B_WOLF)
	wolf.set_target(player)
	player.set_attack_target(wolf)
	var wolf_before := wolf.health
	var player_before := player.health
	var traded := await _wait_until(func() -> bool:
		return wolf.health < wolf_before and player.health < player_before,
		B_MAX_SECONDS)
	if traded:
		await _wait(SETTLE_SECONDS)
	_end_phase(traded, "no exchange of hits within %.1f s (player hit %s, wolf bit %s)"
		% [B_MAX_SECONDS, str(wolf.health < wolf_before), str(player.health < player_before)])
	player.clear_attack_target()


# --- Phase C: turn mode, coordinator style -------------------------------------------------

func _phase_c() -> void:
	_begin_phase("C turn-mode engage and enemy turn")
	_reset_actors(C_PLAYER, C_WOLF)
	# As the coordinator does it: targets are wired at load, and switching to
	# turn mode stops every combatant where it stands.
	wolf.set_target(player)
	player.set_turn_based_combat(true)
	wolf.set_turn_based_combat(true)

	# The player's engage: approach point, navmesh path, trim to the budget.
	player.start_turn(Main3D.TURN_MOVE_METERS)
	var player_stop := _coordinator_player_approach_distance()
	var player_goal := _approach_point(player.global_position, wolf.global_position, player_stop)
	var player_dest := _trimmed_destination(player.global_position, player_goal, Main3D.TURN_MOVE_METERS)
	player.set_navigation_target(player_dest)
	var player_arrived := await _wait_until(func() -> bool: return not player.is_moving(), C_MOVE_TIMEOUT)
	var reach_after_move := GroundMath.ground_distance(player.global_position, wolf.global_position)
	var wolf_before := wolf.health
	var player_swung: bool = await player.try_attack(wolf)
	player.end_turn()
	print("[approach] C player: stop %.2f m, walked to %.2f m from the wolf (arrived %s), try_attack %s, damage %d"
		% [player_stop, reach_after_move, str(player_arrived), str(player_swung), wolf_before - wolf.health])
	if not player_arrived:
		_failures.append("C: the player's turn move did not finish in %.1f s" % C_MOVE_TIMEOUT)
	if not player_swung:
		_failures.append("C: try_attack refused after the engage move at %.2f m (reach %.2f m)"
			% [reach_after_move, player.get_melee_range()])

	# The enemy's turn: the coordinator's stop distance, path, trim, bite.
	wolf.start_turn(Main3D.TURN_MOVE_METERS)
	var wolf_stop := _coordinator_enemy_approach_distance()
	var wolf_goal := _approach_point(wolf.global_position, player.global_position, wolf_stop)
	var wolf_dest := _trimmed_destination(wolf.global_position, wolf_goal, Main3D.TURN_MOVE_METERS)
	wolf.set_navigation_target(wolf_dest)
	var wolf_arrived := await _wait_until(func() -> bool: return not wolf.is_moving(), C_MOVE_TIMEOUT)
	var bite_distance := GroundMath.ground_distance(player.global_position, wolf.global_position)
	var player_before := player.health
	var wolf_swung: bool = await wolf.try_attack(player)
	wolf.end_turn()
	print("[approach] C wolf: stop %.2f m, walked to %.2f m from the player (arrived %s), try_attack %s, damage %d"
		% [wolf_stop, bite_distance, str(wolf_arrived), str(wolf_swung), player_before - player.health])
	if not wolf_arrived:
		_failures.append("C: the wolf's turn move did not finish in %.1f s" % C_MOVE_TIMEOUT)
	if not wolf_swung:
		_failures.append("C: the wolf's try_attack refused at %.2f m (reach %.2f m)" % [bite_distance, wolf.attack_range])
	await _wait(SETTLE_SECONDS * 0.5)
	_end_phase(player_swung and wolf_swung, "turn-mode attacks did not both land")
	player.set_turn_based_combat(false)
	wolf.set_turn_based_combat(false)


## What `_request_player_turn_engage_enemy` in main_3d.gd aims for.
func _coordinator_player_approach_distance() -> float:
	return Main3D.approach_distance_for(player, wolf, player.get_melee_range())


## What `_request_enemy_turn_move_by_distance` in main_3d.gd aims for.
func _coordinator_enemy_approach_distance() -> float:
	return Main3D.approach_distance_for(wolf, player, wolf.attack_range)


## `_compute_approach_world_point` in main_3d.gd.
func _approach_point(mover: Vector3, target: Vector3, stop_distance: float) -> Vector3:
	var distance := GroundMath.ground_distance(mover, target)
	if distance <= stop_distance:
		return mover
	if distance <= 0.001:
		return target
	return GroundMath.flatten(target) + GroundMath.ground_direction(target, mover) * stop_distance


## `_build_world_path_from_navigation` plus `_point_on_path_at_distance`.
func _trimmed_destination(from_world: Vector3, to_world: Vector3, budget_m: float) -> Vector3:
	var map := get_world_3d().navigation_map
	var from_point := NavigationServer3D.map_get_closest_point(map, from_world)
	var to_point := NavigationServer3D.map_get_closest_point(map, to_world)
	var nav_path := NavigationServer3D.map_get_path(map, from_point, to_point, true)
	var world_path: Array[Vector3] = [from_point]
	for p in nav_path:
		if GroundMath.ground_distance(world_path[world_path.size() - 1], p) > 0.01:
			world_path.append(p)
	var trimmed := GroundMath.trim_path(world_path, budget_m)
	return trimmed[trimmed.size() - 1]


# --- Phase bookkeeping ----------------------------------------------------------------------

func _reset_actors(player_at: Vector3, wolf_at: Vector3) -> void:
	player.stop_movement_immediately()
	wolf.stop_movement_immediately()
	player.snap_to(player_at)
	wolf.snap_to(wolf_at)
	player.face_toward(wolf_at)
	wolf.face_toward(player_at)


func _begin_phase(label: String) -> void:
	_phase = label
	_phase_frame = 0
	_phase_time = 0.0
	_have_prev = false
	_player_computed_calls = 0
	_wolf_computed_calls = 0
	_player_phantom_calls = 0
	_wolf_phantom_calls = 0
	_stats = {
		"min_dist": INF, "min_gap": INF,
		"player_bump_frames": 0, "wolf_bump_frames": 0,
		"player_bump_max": 0.0, "wolf_bump_max": 0.0,
		"player_bump_total": 0.0, "wolf_bump_total": 0.0,
		"player_max_speed": 0.0, "wolf_max_speed": 0.0,
	}
	print("[approach] --- phase %s ---" % label)
	_watching = true


func _end_phase(succeeded: bool, failure_text: String) -> void:
	_watching = false
	var dist := GroundMath.ground_distance(player.global_position, wolf.global_position)
	var gap := _surface_gap()
	var report := "[approach] %s: closest %.2f m (surface gap %.2f m), rest at %.2f m (gap %.2f m); bumps player %d frames max %.3f total %.2f m, wolf %d frames max %.3f total %.2f m; phantom avoidance moves player %d/%d wolf %d/%d" % [
		_phase, _stats["min_dist"], _stats["min_gap"], dist, gap,
		_stats["player_bump_frames"], _stats["player_bump_max"], _stats["player_bump_total"],
		_stats["wolf_bump_frames"], _stats["wolf_bump_max"], _stats["wolf_bump_total"],
		_player_phantom_calls, _player_computed_calls, _wolf_phantom_calls, _wolf_computed_calls]
	_phase_reports.append(report)
	print(report)
	if not succeeded:
		_failures.append("%s: %s" % [_phase, failure_text])
	if float(_stats["player_bump_max"]) > BUMP_EPS_M or float(_stats["wolf_bump_max"]) > BUMP_EPS_M:
		_failures.append("%s: a body was displaced without commanding it (player max %.3f m, wolf max %.3f m per frame)"
			% [_phase, _stats["player_bump_max"], _stats["wolf_bump_max"]])
	if gap < MIN_SURFACE_GAP_M:
		_failures.append("%s: the bodies came to rest %.2f m apart, surface gap %.2f m (need %.2f m)"
			% [_phase, dist, gap, MIN_SURFACE_GAP_M])


# --- Per-frame watcher -----------------------------------------------------------------------

func _physics_process(delta: float) -> void:
	_frame += 1
	if not _watching:
		return
	_phase_frame += 1
	_phase_time += delta

	var player_pos := player.global_position
	var wolf_pos := wolf.global_position
	var dist := GroundMath.ground_distance(player_pos, wolf_pos)
	var gap := _surface_gap()
	var player_speed := player.velocity.length()
	var wolf_speed := wolf.velocity.length()
	_stats["min_dist"] = minf(_stats["min_dist"], dist)
	_stats["min_gap"] = minf(_stats["min_gap"], gap)
	_stats["player_max_speed"] = maxf(_stats["player_max_speed"], player_speed)
	_stats["wolf_max_speed"] = maxf(_stats["wolf_max_speed"], wolf_speed)

	var player_bump := 0.0
	var wolf_bump := 0.0
	if _have_prev:
		player_bump = _bump(player_pos.distance_to(_prev_player), _prev_player_walks, player.move_speed, delta)
		wolf_bump = _bump(wolf_pos.distance_to(_prev_wolf), _prev_wolf_walks, wolf.move_speed, delta)
		_record_bump("player", player_bump)
		_record_bump("wolf", wolf_bump)

	var logged := _phase_frame % LOG_EVERY_FRAMES == 1 or player_bump > BUMP_EPS_M or wolf_bump > BUMP_EPS_M
	if logged:
		print("[approach] %s f=%d t=%.2f dist=%.2f gap=%.2f v_player=%.2f v_wolf=%.2f%s%s" % [
			_phase.substr(0, 1), _phase_frame, _phase_time, dist, gap, player_speed, wolf_speed,
			(" BUMP player %.3f" % player_bump) if player_bump > BUMP_EPS_M else "",
			(" BUMP wolf %.3f" % wolf_bump) if wolf_bump > BUMP_EPS_M else ""])

	# The intent each body will act on this frame, judged from what it sees now.
	_prev_player = player_pos
	_prev_wolf = wolf_pos
	_prev_player_walks = _player_wants_to_walk(dist)
	_prev_wolf_walks = _wolf_wants_to_walk(dist)
	_have_prev = true


func _bump(displacement: float, walks: bool, speed: float, delta: float) -> float:
	if walks:
		return maxf(0.0, displacement - speed * delta * 1.02)
	return displacement


func _record_bump(who: String, amount: float) -> void:
	if amount <= BUMP_EPS_M:
		return
	_stats[who + "_bump_frames"] = int(_stats[who + "_bump_frames"]) + 1
	_stats[who + "_bump_max"] = maxf(_stats[who + "_bump_max"], amount)
	_stats[who + "_bump_total"] = float(_stats[who + "_bump_total"]) + amount


## Exploration: the pursuit halts inside melee range; otherwise the body walks
## while its navigation is unfinished. Turn mode: walks while unfinished.
func _player_wants_to_walk(dist: float) -> bool:
	if not player.is_moving():
		return false
	if not player.is_in_turn_based_combat() and player.attack_target != null and dist <= player.get_melee_range():
		return false
	return true


func _wolf_wants_to_walk(dist: float) -> bool:
	if not wolf.is_moving():
		return false
	if not wolf.is_in_turn_based_combat() and dist <= wolf.attack_range:
		return false
	return true


## `velocity_computed` arriving for a body that did not ask to move this frame
## is a phantom move: the NavigationServer keeps the last submitted velocity.
func _on_player_velocity_computed(safe_velocity: Vector3) -> void:
	if not _watching:
		return
	_player_computed_calls += 1
	if not _prev_player_walks and safe_velocity.length() > 0.01:
		_player_phantom_calls += 1


func _on_wolf_velocity_computed(safe_velocity: Vector3) -> void:
	if not _watching:
		return
	_wolf_computed_calls += 1
	if not _prev_wolf_walks and safe_velocity.length() > 0.01:
		_wolf_phantom_calls += 1


# --- Geometry -----------------------------------------------------------------------------------

## Distance between the two collision surfaces along the line of centres.
func _surface_gap() -> float:
	var dist := GroundMath.ground_distance(player.global_position, wolf.global_position)
	var toward_player := GroundMath.ground_direction(wolf.global_position, player.global_position)
	if toward_player == Vector3.ZERO:
		return -INF
	return dist - _radius_along(player, -toward_player) - _radius_along(wolf, toward_player)


## The body's collision extent from its origin along `world_dir` on the ground.
func _radius_along(body: CharacterBody3D, world_dir: Vector3) -> float:
	var shape_node := body.get_node_or_null("CollisionShape3D") as CollisionShape3D
	if shape_node == null or shape_node.shape == null:
		return 0.0
	var shape := shape_node.shape
	if shape is CapsuleShape3D:
		return (shape as CapsuleShape3D).radius
	if shape is SphereShape3D:
		return (shape as SphereShape3D).radius
	if shape is CylinderShape3D:
		return (shape as CylinderShape3D).radius
	if shape is BoxShape3D:
		var half := (shape as BoxShape3D).size * 0.5
		var local := shape_node.global_transform.basis.inverse() * world_dir
		return half.x * absf(local.x) + half.z * absf(local.z)
	return 0.0


# --- Waiting -------------------------------------------------------------------------------------

func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _wait_until(predicate: Callable, timeout: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if bool(predicate.call()):
			return true
		await get_tree().physics_frame
	return bool(predicate.call())
