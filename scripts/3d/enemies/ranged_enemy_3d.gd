class_name RangedEnemy3D
extends Enemy3D

## A caster that fights from range (the cultist, `scenes/3d/enemies/cultist_3d.tscn`).
## Its swing is the normal Enemy3D sequence with the normal counter handshake,
## only dressed differently: the wind-up charges the staff, and the strike (the
## counter window) is a visible bolt that flies from the staff to the target in
## exactly the strike time, so the prompt's beat is the bolt's arrival. The
## player reacts exactly as to a bite.
##
## Keeping distance: when the target stands within `retreat_trigger_m` at the
## start of its turn, it first backs off up to `retreat_distance_m` (never
## more than the turn's movement budget) and then fires. The coordinator's
## approach point for a 7 m reach is about 6.8 m out, so it normally stays at
## range on its own; the retreat covers a player who walked up to it.
##
## docs/enemy-roster.md.

## Target this close at the start of the turn: step back before firing.
@export var retreat_trigger_m := 2.5
## How far the step back goes (capped by the remaining turn movement).
@export var retreat_distance_m := 3.0
## Seconds the step back may take before the bolt fires anyway.
@export var retreat_timeout := 2.5
## The bolt's colour (the player's `_launch_bolt` look, in violet).
@export var bolt_color := Color(0.78, 0.45, 1.0, 0.95)

const BOLT_THICKNESS_M := 0.07
const BOLT_MAX_TAIL_M := 0.9
const BOLT_TARGET_HEIGHT_M := 1.0
## Where the bolt leaves from: above the staff hand.
const BOLT_HAND_LIFT_M := 0.45
const BOLT_FALLBACK_HEIGHT_M := 1.45
const CHARGE_TINT := Color(0.45, 0.12, 0.7, 1.0)
const CHARGE_SCALE := Vector3(1.04, 1.06, 0.96)
const RECOIL_M := 0.08

var _retreat_wanted := false
var _bolts_fired := 0
var _hand: Node3D = null


func _ready() -> void:
	super()
	var model := get_node_or_null("Model")
	if model != null:
		_hand = model.find_child("HandPoint", true, false) as Node3D


## Bolts launched so far (for tests and the lead's HUD).
func get_bolts_fired() -> int:
	return _bolts_fired


## True from the start of a turn whose target stood within `retreat_trigger_m`
## until the step back has been made.
func wants_retreat() -> bool:
	return _retreat_wanted


func start_turn(max_move_meters: float = 6.0) -> void:
	super(max_move_meters)
	_retreat_wanted = false
	var target := _live_target()
	if target == null or not is_alive() or get_turn_remaining_move_meters() <= 0.0:
		return
	_retreat_wanted = GroundMath.ground_distance(global_position, target.global_position) <= retreat_trigger_m


func end_turn() -> void:
	super()
	_retreat_wanted = false


func try_attack(target: Node3D = null) -> bool:
	if target != null:
		_target = target
	if _retreat_wanted and is_in_turn_based_combat() and is_turn_active():
		_retreat_wanted = false
		await _retreat_from(_live_target())
		if not is_instance_valid(self) or not is_alive():
			return false
	return await super(target)


## Backs away from `threat` along the line between them, up to
## `retreat_distance_m` and the remaining budget, then waits for the walk.
func _retreat_from(threat: Node3D) -> void:
	if threat == null or not is_instance_valid(threat):
		return
	var budget := minf(retreat_distance_m, get_turn_remaining_move_meters())
	if budget <= 0.05:
		return
	var away := GroundMath.ground_direction(threat.global_position, global_position)
	if away == Vector3.ZERO:
		away = GroundMath.ground_direction(Vector3.ZERO, global_transform.basis.z)
	if away == Vector3.ZERO:
		return
	var start := GroundMath.flatten(global_position)
	var destination := _clamp_to_navmesh(start + away * budget, budget + 1.0)
	var planned := GroundMath.ground_distance(start, destination)
	if planned <= 0.05:
		return
	set_navigation_target(destination)
	var deadline := Time.get_ticks_msec() + int(retreat_timeout * 1000.0)
	while is_instance_valid(self) and is_alive() and is_moving() and Time.get_ticks_msec() < deadline:
		await get_tree().physics_frame
	if not is_instance_valid(self):
		return
	if is_moving():
		hold_position()
	consume_turn_movement_meters(GroundMath.ground_distance(start, global_position))


## The wind-up charges the staff: a violet glow and a slight rise.
func _play_wind_up(_target_node: Node3D, seconds: float) -> void:
	_flash_model(CHARGE_TINT, seconds)
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(_model, "scale", _model_idle_scale * CHARGE_SCALE, seconds) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(_model, "position", _model_idle_position + Vector3(0.0, 0.0, WIND_UP_PULL_M * 0.5), seconds)
	await tween.finished


## The strike is the bolt's flight, exactly `seconds` long.
func _play_strike(target_node: Node3D, seconds: float) -> void:
	_flash_model(STRIKE_TINT, maxf(seconds * 0.3, 0.01))
	var recoil := create_tween()
	recoil.set_parallel(true)
	recoil.tween_property(_model, "position", _model_idle_position + Vector3(0.0, 0.0, RECOIL_M), seconds * 0.5)
	recoil.tween_property(_model, "scale", _model_idle_scale, seconds * 0.5)
	if target_node != null and is_instance_valid(target_node):
		_launch_bolt(target_node, maxf(seconds, 0.05))
	await get_tree().create_timer(maxf(seconds, 0.01)).timeout


## A glowing streak from the staff to the target's chest, parented to the level
## so it keeps its own path. Same construction as Player3D._launch_bolt.
func _launch_bolt(target_node: Node3D, flight_time: float) -> void:
	var start := _bolt_start_position()
	var destination := target_node.global_position + Vector3(0.0, BOLT_TARGET_HEIGHT_M, 0.0)
	var distance := start.distance_to(destination)

	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = bolt_color.lightened(0.2)

	var tail_length := maxf(minf(BOLT_MAX_TAIL_M, distance * 0.5), BOLT_THICKNESS_M)
	var box := BoxMesh.new()
	box.size = Vector3(BOLT_THICKNESS_M, BOLT_THICKNESS_M, tail_length)
	var arrays := box.get_mesh_arrays()
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	for i in range(vertices.size()):
		vertices[i] += Vector3(0.0, 0.0, tail_length * 0.5)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, material)

	var bolt := MeshInstance3D.new()
	bolt.name = "EnemyBolt"
	bolt.mesh = mesh
	bolt.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var holder := get_parent()
	if holder == null:
		holder = self
	holder.add_child(bolt)
	bolt.global_position = start
	var direction := destination - start
	if direction.length() > 0.01 and absf(direction.normalized().dot(Vector3.UP)) < 0.999:
		bolt.look_at(destination, Vector3.UP)
	_bolts_fired += 1

	var tween := bolt.create_tween()
	tween.tween_property(bolt, "global_position", destination, flight_time) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.tween_property(material, "albedo_color:a", 0.0, 0.1)
	tween.tween_callback(bolt.queue_free)


func _bolt_start_position() -> Vector3:
	if _hand != null and is_instance_valid(_hand):
		return _hand.global_position + Vector3(0.0, BOLT_HAND_LIFT_M, 0.0)
	return global_position + Vector3(0.0, BOLT_FALLBACK_HEIGHT_M, 0.0)
