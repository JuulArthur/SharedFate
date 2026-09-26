extends CharacterBody3D

## WP0 stub actor: the shared half of the actor contract with the simplest possible
## behaviour (straight-line movement, no navmesh, no animation), so the arena
## skeleton runs before WP3a delivers actor_3d_base.gd.
##
## Contract: docs/3d-port-contracts.md, section 5.1. Positions are Vector3 on the
## ground plane; distances are metres.

@export var move_speed := 3.5
@export var max_health := 100
@export var attack_damage := 10
@export var attack_range := 1.2

const ARRIVE_DISTANCE := 0.1

var health: int = 0
var _target_position := Vector3.ZERO
var _has_target := false
var _turn_mode := false
var _turn_move_left := 0.0
var _turn_attack_available := false
var _alive := true


func _ready() -> void:
	health = max_health
	if not is_in_group("player") and not is_in_group("enemies"):
		push_warning("%s: stub actor is in neither the 'player' nor the 'enemies' group" % name)


func _physics_process(_delta: float) -> void:
	if not _alive or not _has_target:
		velocity = Vector3.ZERO
		return
	var distance := GroundMath.ground_distance(global_position, _target_position)
	if distance <= ARRIVE_DISTANCE:
		_has_target = false
		velocity = Vector3.ZERO
		return
	var direction := GroundMath.ground_direction(global_position, _target_position)
	velocity = direction * move_speed
	rotation.y = GroundMath.yaw_facing(direction)
	move_and_slide()
	global_position = GroundMath.flatten(global_position, GroundMath.GROUND_Y)


# --- Movement ------------------------------------------------------------------

func snap_to(world_position: Vector3) -> void:
	_has_target = false
	velocity = Vector3.ZERO
	global_position = GroundMath.flatten(world_position, GroundMath.GROUND_Y)


## Stub: walks in a straight line. The real actor snaps the target to the navmesh
## with NavigationServer3D.map_get_closest_point and follows a NavigationAgent3D.
func set_navigation_target(world_position: Vector3) -> void:
	_target_position = GroundMath.flatten(world_position, GroundMath.GROUND_Y)
	_has_target = true


func stop_movement_immediately() -> void:
	_has_target = false
	velocity = Vector3.ZERO


func is_moving() -> bool:
	return _has_target


# --- Health --------------------------------------------------------------------

func is_alive() -> bool:
	return _alive


func receive_damage(amount: int) -> void:
	take_damage(amount)


func take_damage(amount: int) -> void:
	if not _alive:
		return
	health = maxi(0, health - amount)
	flash_hit()
	if health == 0:
		_die()


## Hook for the hit tint. WP5 provides the real effect; the stub only prints.
func flash_hit() -> void:
	pass


func _die() -> void:
	_alive = false
	_has_target = false
	velocity = Vector3.ZERO
	set_deferred("collision_layer", 0)
	visible = false


# --- Turn resources ------------------------------------------------------------

func set_turn_based_combat(enabled: bool) -> void:
	_turn_mode = enabled
	stop_movement_immediately()
	if not enabled:
		_turn_move_left = 0.0
		_turn_attack_available = false


func start_turn(max_move_meters: float = 6.0) -> void:
	_turn_move_left = max_move_meters
	_turn_attack_available = true


func end_turn() -> void:
	_turn_move_left = 0.0
	_turn_attack_available = false
	stop_movement_immediately()


func consume_turn_movement_meters(used: float) -> void:
	_turn_move_left = maxf(0.0, _turn_move_left - used)


func get_turn_remaining_move_meters() -> float:
	return _turn_move_left


func get_turn_remaining_move_cells() -> int:
	return int(floor(_turn_move_left / GroundMath.CELL_SIZE))


func can_turn_attack() -> bool:
	if not _turn_mode:
		return true
	return _turn_attack_available


func is_turn_active() -> bool:
	return _turn_mode


# --- Attacks -------------------------------------------------------------------

## Instant hit when the target is within attack_range. Returns whether it landed.
## The real player version is a coroutine with the contact delay; awaiting a plain
## bool works the same for the coordinator.
func try_attack(target: Node3D = null) -> bool:
	if not _alive or target == null or not is_instance_valid(target):
		return false
	if not can_turn_attack():
		return false
	if GroundMath.ground_distance(global_position, target.global_position) > attack_range + 0.05:
		return false
	var direction := GroundMath.ground_direction(global_position, target.global_position)
	if direction != Vector3.ZERO:
		rotation.y = GroundMath.yaw_facing(direction)
	if target.has_method("receive_damage"):
		target.call("receive_damage", _outgoing_damage())
	_turn_attack_available = false
	return true


func _outgoing_damage() -> int:
	return attack_damage
