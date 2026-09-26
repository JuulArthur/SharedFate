extends Node3D

## WP0 arena skeleton: a runnable 3D level with box placeholders and stub actors
## that satisfy the actor contract, so the coordinator (WP4) and the overlays (WP5)
## have something to run against before the real actors, camera rig and models land.
##
## Click the ground to move the stub player. Run headless with
##   godot --headless --path . res://scenes/3d/arena_skeleton.tscn --quit-after 120
## to check for script errors. See docs/3d-port-contracts.md.

const CAMERA_SIZE_M := 14.0
const CAMERA_YAW_DEG := 45.0
const CAMERA_PITCH_DEG := -35.0
const CAMERA_DISTANCE := 30.0

const SHARED_CONTRACT: Array[String] = [
	"snap_to", "set_navigation_target", "stop_movement_immediately", "is_moving", "is_alive",
	"receive_damage", "take_damage", "set_turn_based_combat", "start_turn", "end_turn",
	"consume_turn_movement_meters", "get_turn_remaining_move_meters",
	"get_turn_remaining_move_cells", "can_turn_attack", "try_attack",
]
const PLAYER_CONTRACT: Array[String] = [
	"set_attack_target", "clear_attack_target", "set_turn_meter_world_units", "get_melee_range",
	"get_melee_damage", "get_ranged_range_meters", "try_ranged_attack", "try_cast_spell",
	"get_spell_cooldown", "get_preferred_attack_approach_distance", "set_blocking", "is_blocking",
	"get_active_soul", "get_souls", "get_shifts_left", "can_shift", "shift_to",
	"shift_kind_from_event", "get_reaction_hint", "begin_enemy_counter_windup",
	"begin_enemy_counter_strike", "cancel_enemy_counter", "resolve_enemy_attack", "heal",
	"add_experience", "get_player_level", "get_experience_toward_next",
	"get_xp_required_for_next_level", "set_overhead_ui_visible", "get_equipped_weapon",
	"get_inventory_items",
]
const ENEMY_CONTRACT: Array[String] = [
	"set_target", "set_hover_highlighted", "apply_root", "is_rooted",
]

@onready var camera: Camera3D = $Camera3D
@onready var sun: DirectionalLight3D = $Sun
@onready var nav_region: NavigationRegion3D = $NavigationRegion3D
@onready var player: CharacterBody3D = $Player

var _navmesh_ready := false


func _ready() -> void:
	_setup_camera()
	sun.rotation_degrees = Vector3(-55.0, 30.0, 0.0)
	nav_region.bake_finished.connect(_on_bake_finished)
	nav_region.bake_navigation_mesh()
	if player.has_method("set_turn_meter_world_units"):
		player.call("set_turn_meter_world_units", GroundMath.METER_WORLD_UNITS)
	_report_contract()


func _process(_delta: float) -> void:
	# Fixed-angle follow until the WP2 camera rig replaces this placeholder.
	var look_at_point := GroundMath.flatten(player.global_position, 1.0)
	var back := Vector3(0.0, 0.0, CAMERA_DISTANCE)
	back = back.rotated(Vector3.RIGHT, deg_to_rad(CAMERA_PITCH_DEG))
	back = back.rotated(Vector3.UP, deg_to_rad(CAMERA_YAW_DEG))
	camera.global_position = look_at_point + back
	camera.look_at(look_at_point, Vector3.UP)


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton):
		return
	var mouse := event as InputEventMouseButton
	if not mouse.pressed or mouse.button_index != MOUSE_BUTTON_LEFT:
		return
	var hit: Variant = _pick_ground(mouse.position)
	if hit == null:
		return
	if player.has_method("set_navigation_target"):
		player.call("set_navigation_target", hit)
	get_viewport().set_input_as_handled()


func _setup_camera() -> void:
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = CAMERA_SIZE_M
	camera.near = 0.1
	camera.far = 200.0
	camera.current = true


## Ray from the camera through the screen point onto collision layer 1 (ground).
## Returns a Vector3 or null. WorldPicker (WP2) replaces this.
func _pick_ground(screen_pos: Vector2) -> Variant:
	var from := camera.project_ray_origin(screen_pos)
	var to := from + camera.project_ray_normal(screen_pos) * 500.0
	var params := PhysicsRayQueryParameters3D.create(from, to, 1)
	var result := get_world_3d().direct_space_state.intersect_ray(params)
	if result.is_empty():
		return null
	return result["position"]


func _on_bake_finished() -> void:
	_navmesh_ready = true
	print("[arena_skeleton] navmesh baked")


func _report_contract() -> void:
	var missing: Array[String] = []
	for method_name in SHARED_CONTRACT + PLAYER_CONTRACT:
		if not player.has_method(method_name):
			missing.append("player." + method_name)
	for enemy in get_tree().get_nodes_in_group("enemies"):
		for method_name in SHARED_CONTRACT + ENEMY_CONTRACT:
			if not enemy.has_method(method_name):
				missing.append("%s.%s" % [enemy.name, method_name])
	if missing.is_empty():
		print("[arena_skeleton] actor contract satisfied by the stubs")
	else:
		push_warning("[arena_skeleton] contract methods missing: %s" % ", ".join(missing))
