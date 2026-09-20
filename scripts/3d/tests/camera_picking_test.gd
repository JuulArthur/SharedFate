extends Node3D

## WP2 test scene: CameraRig3D following a stub player, WorldPicker resolving
## clicks. Same layout as the WP0 arena skeleton (ground on layer 1, a prop on
## layer 4, stub actors) but with no Camera3D on the root: the rig instance owns
## the camera.
##
## With a window: left-click the ground to walk the stub player there, and the
## console prints what pick_enemy and pick_pickup return for that click.
##
## Headless has no clicks, so the scene also checks itself two frames in and
## prints CAMERA_PICKING OK (or one CAMERA_PICKING FAIL line per failed check):
##   godot --headless --path . res://scenes/3d/tests/camera_picking_test.tscn --quit-after 120

## Tolerance for the ground picks, in metres.
const GROUND_TOLERANCE_M := 1.0
## Probe distances for the enemy-click forgiveness radius (0.6 m). Both are
## offsets along +X from the enemy's feet, where the camera ray leaves the body
## box (half extents 0.45 m by 0.65 m) untouched, so only the fallback can hit.
const NEAR_PROBE_M := 0.5
const FAR_PROBE_M := 1.6
const SELF_CHECK_FRAME := 2

@onready var rig: CameraRig3D = $CameraRig
@onready var sun: DirectionalLight3D = $Sun
@onready var nav_region: NavigationRegion3D = $NavigationRegion3D
@onready var player: CharacterBody3D = $Player
@onready var enemy: CharacterBody3D = $Enemy
@onready var pickup_area: Area3D = $TestPickup/PickupArea

var _frames := 0
var _self_check_done := false


func _ready() -> void:
	sun.rotation_degrees = Vector3(-55.0, 30.0, 0.0)
	nav_region.bake_navigation_mesh()
	rig.set_follow_target(player)
	if player.has_method("set_turn_meter_world_units"):
		player.call("set_turn_meter_world_units", GroundMath.METER_WORLD_UNITS)


func _process(_delta: float) -> void:
	if _self_check_done:
		return
	_frames += 1
	if _frames >= SELF_CHECK_FRAME:
		_self_check_done = true
		_run_self_check()


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton):
		return
	var mouse := event as InputEventMouseButton
	if not mouse.pressed or mouse.button_index != MOUSE_BUTTON_LEFT:
		return
	var camera := rig.get_camera()
	if camera == null:
		return

	var clicked_enemy := WorldPicker.pick_enemy(camera, mouse.position)
	var clicked_pickup := WorldPicker.pick_pickup(camera, mouse.position)
	var ground: Variant = WorldPicker.pick_ground(camera, mouse.position)
	print("[camera_picking_test] click %s: enemy=%s pickup=%s ground=%s" % [
		mouse.position, _node_name(clicked_enemy), _node_name(clicked_pickup), ground,
	])
	if ground != null and player.has_method("set_navigation_target"):
		player.call("set_navigation_target", ground)
	get_viewport().set_input_as_handled()


# --- Self-check ----------------------------------------------------------------

func _run_self_check() -> void:
	var camera := rig.get_camera()
	if camera == null:
		print("CAMERA_PICKING FAIL: the rig has no Camera3D child")
		return

	var failures: Array[String] = []
	var anchor := enemy.get_node_or_null("OverheadAnchor") as Node3D
	var anchor_position: Vector3 = enemy.global_position
	if anchor != null:
		anchor_position = anchor.global_position
	var enemy_ground := GroundMath.flatten(enemy.global_position)
	var anchor_screen := WorldPicker.world_to_screen(camera, anchor_position)
	var feet_screen := WorldPicker.world_to_screen(camera, enemy_ground)

	# 1. The enemy under its own overhead anchor.
	var picked := WorldPicker.pick_enemy(camera, anchor_screen)
	if picked != enemy:
		failures.append("pick_enemy at the OverheadAnchor screen point %s returned %s, expected %s" % [
			anchor_screen, _node_name(picked), enemy.name,
		])

	# 2. The ground under the same screen point. The hit cannot sit on the enemy's
	# feet: at pitch -35 degrees the ray through a 1.3 m anchor meets the ground
	# about 1.86 m behind the enemy, so it is checked against the ray-plane point.
	var parallax := -1.0
	var anchor_ground: Variant = WorldPicker.pick_ground(camera, anchor_screen)
	if anchor_ground == null:
		failures.append("pick_ground at the OverheadAnchor screen point %s returned null" % anchor_screen)
	else:
		var anchor_point: Vector3 = anchor_ground
		var expected := _ray_ground_point(camera, anchor_screen)
		parallax = GroundMath.ground_distance(anchor_point, enemy_ground)
		var error := GroundMath.ground_distance(anchor_point, expected)
		if error > GROUND_TOLERANCE_M:
			failures.append("pick_ground at the OverheadAnchor screen point hit %s, %.2f m from the expected %s" % [
				anchor_point, error, expected,
			])

	# 3. The ground under the enemy's feet, which must land on the enemy's cell.
	var feet_ground: Variant = WorldPicker.pick_ground(camera, feet_screen)
	if feet_ground == null:
		failures.append("pick_ground at the feet screen point %s returned null" % feet_screen)
	else:
		var feet_point: Vector3 = feet_ground
		var feet_error := GroundMath.ground_distance(feet_point, enemy_ground)
		if feet_error > GROUND_TOLERANCE_M:
			failures.append("pick_ground at the feet screen point hit %s, %.2f m from the enemy ground position %s" % [
				feet_point, feet_error, enemy_ground,
			])

	# 4 and 5. The click forgiveness radius: a miss just beside the body still
	# selects the enemy, a miss well clear of it selects nothing.
	var near_screen := WorldPicker.world_to_screen(camera, enemy_ground + Vector3(NEAR_PROBE_M, 0.0, 0.0))
	var near_pick := WorldPicker.pick_enemy(camera, near_screen)
	if near_pick != enemy:
		failures.append("pick_enemy %.1f m beside the enemy returned %s, expected %s (forgiveness radius %.1f m)" % [
			NEAR_PROBE_M, _node_name(near_pick), enemy.name, WorldPicker.ENEMY_CLICK_RADIUS_METERS,
		])
	var far_screen := WorldPicker.world_to_screen(camera, enemy_ground + Vector3(FAR_PROBE_M, 0.0, 0.0))
	var far_pick := WorldPicker.pick_enemy(camera, far_screen)
	if far_pick != null:
		failures.append("pick_enemy %.1f m beside the enemy returned %s, expected null" % [
			FAR_PROBE_M, _node_name(far_pick),
		])

	# 6. The pickup area on layer 3.
	var pickup_screen := WorldPicker.world_to_screen(camera, pickup_area.global_position)
	var picked_pickup := WorldPicker.pick_pickup(camera, pickup_screen)
	if picked_pickup != pickup_area:
		failures.append("pick_pickup at the test pickup %s returned %s, expected %s" % [
			pickup_screen, _node_name(picked_pickup), pickup_area.name,
		])

	print("[camera_picking_test] viewport %s, camera at %s, ortho size %.1f m, anchor screen %s, ground parallax %.2f m" % [
		get_viewport().get_visible_rect().size, camera.global_position, camera.size,
		anchor_screen, parallax,
	])
	if failures.is_empty():
		print("CAMERA_PICKING OK")
		return
	for failure in failures:
		print("CAMERA_PICKING FAIL: ", failure)


## Where the camera ray through `screen_pos` crosses the ground plane, which is
## what pick_ground must return on flat ground.
func _ray_ground_point(camera: Camera3D, screen_pos: Vector2) -> Vector3:
	var origin := camera.project_ray_origin(screen_pos)
	var direction := camera.project_ray_normal(screen_pos)
	if absf(direction.y) < 0.0001:
		return GroundMath.flatten(origin)
	return origin + direction * ((GroundMath.GROUND_Y - origin.y) / direction.y)


func _node_name(node: Node) -> String:
	if node == null or not is_instance_valid(node):
		return "null"
	return String(node.name)
