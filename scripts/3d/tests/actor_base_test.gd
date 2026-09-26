extends Node3D

## WP3a test: two ActorBase3D bodies on a baked navmesh.
##
## Actor A is sent to a point on the far side of a wall and must walk around it,
## so the distance it covers is clearly longer than the straight line. Actor B is
## sent into a blocker that the navmesh does not know about (the pocket sits
## outside the NavigationRegion3D, so the bake never carves it out), so its path
## runs straight into a wall and the ported stuck detection has to stop it.
##
## Prints `ACTOR_BASE OK`, or the first failing check, within 200 physics frames.
##
##   godot --headless --path . res://scenes/3d/tests/actor_base_test.tscn --quit-after 240

const MAX_FRAMES := 200
## A counts as arrived inside this radius, and B as blocked outside it.
const ARRIVE_TOLERANCE := 0.5
## A has gone around the wall when it covered at least this much more than the
## straight line.
const DETOUR_FACTOR := 1.1

const TARGET_A := Vector3(0.0, 0.0, 2.5)
const TARGET_B := Vector3(-5.0, 0.0, 0.0)

const CAMERA_SIZE_M := 24.0
const CAMERA_YAW_DEG := 45.0
const CAMERA_PITCH_DEG := -35.0
const CAMERA_DISTANCE := 30.0

@onready var camera: Camera3D = $Camera3D
@onready var sun: DirectionalLight3D = $Sun
@onready var nav_region: NavigationRegion3D = $NavigationRegion3D
@onready var actor_a: ActorBase3D = $ActorA
@onready var actor_b: ActorBase3D = $ActorB

var _frames := 0
var _running := false
var _finished := false
var _travelled := 0.0
var _straight_line := 0.0
var _last_a := Vector3.ZERO


func _ready() -> void:
	# Headless runs the main loop as fast as it can, which starves the physics
	# steps this test counts. Capping the frame rate keeps roughly one physics
	# tick per iteration, so 200 frames fit inside --quit-after 240.
	Engine.max_fps = 60
	_setup_camera()
	sun.rotation_degrees = Vector3(-55.0, 30.0, 0.0)
	nav_region.bake_finished.connect(_on_bake_finished)
	nav_region.bake_navigation_mesh()


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
	_last_a = actor_a.global_position
	_straight_line = GroundMath.ground_distance(actor_a.global_position, TARGET_A)
	actor_a.set_navigation_target(TARGET_A)
	actor_b.set_navigation_target(TARGET_B)
	_running = true


## The baked mesh only reaches the navigation map on a later server sync; until
## it does, map queries answer with the origin. Waits for the map to report a
## point near a spot that is known to be walkable.
func _wait_for_navigation_map() -> void:
	var map := get_world_3d().navigation_map
	for _i in range(60):
		await get_tree().physics_frame
		var closest := NavigationServer3D.map_get_closest_point(map, TARGET_A)
		if GroundMath.ground_distance(closest, TARGET_A) < 0.5:
			return
	push_error("[actor_base_test] the navigation map never picked up the baked mesh")


func _physics_process(_delta: float) -> void:
	if _finished or not _running:
		return
	_frames += 1
	_travelled += GroundMath.ground_distance(actor_a.global_position, _last_a)
	_last_a = actor_a.global_position
	if _is_verdict_ready() or _frames >= MAX_FRAMES:
		_report()


## Both actors have settled: A stopped inside the arrival radius, B gave up.
func _is_verdict_ready() -> bool:
	if actor_a.is_moving() or actor_b.is_moving():
		return false
	return GroundMath.ground_distance(actor_a.global_position, TARGET_A) <= ARRIVE_TOLERANCE


func _report() -> void:
	_finished = true
	print("[actor_base_test] A travelled %.2f m, straight line %.2f m, final position %s, %d frames"
		% [_travelled, _straight_line, str(actor_a.global_position), _frames])
	print("[actor_base_test] B is_moving %s, position %s"
		% [str(actor_b.is_moving()), str(actor_b.global_position)])
	var failure := _first_failure()
	if failure.is_empty():
		print("ACTOR_BASE OK")
	else:
		print(failure)
	get_tree().quit()


## The first check that did not hold, or "" when everything did.
func _first_failure() -> String:
	var distance_left := GroundMath.ground_distance(actor_a.global_position, TARGET_A)
	if distance_left > ARRIVE_TOLERANCE:
		return "ACTOR_BASE FAIL: A is %.2f m from its target after %d frames" % [distance_left, _frames]
	if _travelled < _straight_line * DETOUR_FACTOR:
		return "ACTOR_BASE FAIL: A travelled %.2f m, not more than the straight line %.2f m, so it did not go around" \
			% [_travelled, _straight_line]
	if GroundMath.ground_distance(actor_b.global_position, TARGET_B) <= ARRIVE_TOLERANCE:
		return "ACTOR_BASE FAIL: B reached its target, so the blocker never stopped it"
	if actor_b.is_moving():
		return "ACTOR_BASE FAIL: B still reports moving after %d frames" % _frames
	return ""
