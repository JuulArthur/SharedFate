class_name ActorBase3D
extends CharacterBody3D

## The shared half of the 3D actor contract: navmesh movement, the turn-resource
## block, health and the facing / attack helpers that both the player (WP3b) and
## the enemy (WP3c) inherit. See docs/3d-port-contracts.md, section 5.1.
##
## Units are metres, the ground plane is y = 0 and there is no gravity, exactly
## as in the 2D game. Every conversion goes through GroundMath; never inline one.
##
## Required children, owned by the scene, looked up in `_ready`:
##   NavigationAgent3D named "NavigationAgent3D" (tuning belongs to the scene)
##   CollisionShape3D  named "CollisionShape3D"
##   Node3D            named "OverheadAnchor", at head height
##
## Collision layer 2 and mask 9 are authored in the scene; this script never
## touches them, except to clear the layer on death.
##
## Subclasses that define `_ready`, `_physics_process` or `_on_died` must call
## `super` unless they mean to replace the behaviour outright.

## Emitted by `flash_hit()`. WP5 hangs the material tint off this.
signal hit_flashed

@export var move_speed := 3.5
@export var max_health := 100
@export var attack_damage := 20
@export var attack_range := 1.2

## Ported from player.gd: an actor that is trying to move but cannot gives up
## after this many seconds and reports `is_moving() == false`.
const STUCK_THRESHOLD := 1.0
## player.gd uses 2.0 px, and the 2D game is 64 px to the metre.
const STUCK_MOVE_EPSILON := 0.03
## Slack on `attack_range` so a target standing exactly at range still gets hit.
const ATTACK_RANGE_TOLERANCE := 0.05

var health: int = 0

var navigation_agent: NavigationAgent3D = null
var collision_shape: CollisionShape3D = null
var overhead_anchor: Node3D = null

var _alive := true
# Turn-based combat is on for the fight; the turn is active only while it is
# this actor's own turn. Both mirror player.gd.
var _turn_mode := false
var _turn_active := false
var _turn_move_left := 0.0
var _turn_attack_available := false
var _stuck_timer := 0.0
var _last_position := Vector3.ZERO


func _ready() -> void:
	health = max_health
	_last_position = global_position
	navigation_agent = get_node_or_null("NavigationAgent3D") as NavigationAgent3D
	collision_shape = get_node_or_null("CollisionShape3D") as CollisionShape3D
	overhead_anchor = get_node_or_null("OverheadAnchor") as Node3D
	if navigation_agent == null:
		push_error("%s: ActorBase3D needs a NavigationAgent3D child named 'NavigationAgent3D'." % name)
	else:
		navigation_agent.velocity_computed.connect(_on_velocity_computed)
	if collision_shape == null:
		push_error("%s: ActorBase3D needs a CollisionShape3D child named 'CollisionShape3D'." % name)
	if overhead_anchor == null:
		push_error("%s: ActorBase3D needs a Node3D child named 'OverheadAnchor' at head height." % name)


func _physics_process(delta: float) -> void:
	if navigation_agent == null:
		return
	if not _alive:
		velocity = Vector3.ZERO
		return
	_check_stuck(delta)
	_step_navigation()


# --- Movement ------------------------------------------------------------------

## One navigation step: aim at the next path point, face it, move, stay on y = 0.
## With avoidance on, the NavigationServer answers on `velocity_computed` and the
## body is moved there instead.
func _step_navigation() -> void:
	if navigation_agent.is_navigation_finished():
		velocity = Vector3.ZERO
		move_and_slide()
		_settle_on_ground()
		return

	var next_position := navigation_agent.get_next_path_position()
	var direction := GroundMath.ground_direction(global_position, next_position)
	if direction != Vector3.ZERO:
		rotation.y = GroundMath.yaw_facing(direction)
	var desired_velocity := direction * move_speed
	if navigation_agent.avoidance_enabled:
		navigation_agent.set_velocity(desired_velocity)
		return
	velocity = desired_velocity
	move_and_slide()
	_settle_on_ground()


func _on_velocity_computed(safe_velocity: Vector3) -> void:
	if not _alive:
		return
	velocity = safe_velocity
	move_and_slide()
	_settle_on_ground()


## No gravity in this game: the body is pinned to the ground plane every step.
func _settle_on_ground() -> void:
	velocity.y = 0.0
	global_position = GroundMath.flatten(global_position, GroundMath.GROUND_Y)


## Ported from player.gd. An actor that wants to move but has not covered
## STUCK_MOVE_EPSILON within STUCK_THRESHOLD seconds gives up, so a blocked actor
## stops reporting `is_moving()` instead of grinding against a wall forever.
func _check_stuck(delta: float) -> void:
	if navigation_agent.is_navigation_finished():
		_stuck_timer = 0.0
		_last_position = global_position
		return

	if GroundMath.ground_distance(global_position, _last_position) > STUCK_MOVE_EPSILON:
		_stuck_timer = 0.0
		_last_position = global_position
		return

	_stuck_timer += delta
	if _stuck_timer >= STUCK_THRESHOLD:
		stop_movement_immediately()
		_stuck_timer = 0.0


func snap_to(world_position: Vector3) -> void:
	var grounded := GroundMath.flatten(world_position, GroundMath.GROUND_Y)
	global_position = grounded
	velocity = Vector3.ZERO
	_stuck_timer = 0.0
	_last_position = grounded
	if navigation_agent != null:
		navigation_agent.target_position = grounded


func set_navigation_target(world_position: Vector3) -> void:
	if navigation_agent == null:
		return
	_stuck_timer = 0.0
	_last_position = global_position
	var grounded := GroundMath.flatten(world_position, GroundMath.GROUND_Y)
	var destination := _closest_navigation_point(grounded)
	# Recast bakes the navigation mesh a cell height above the floor, so path
	# points hover over the feet. The agent measures path_desired_distance and
	# target_desired_distance in 3D, and that vertical gap alone can be enough to
	# stop it ever reaching a waypoint. Telling the agent how high the mesh sits,
	# and aiming at the ground plane, puts both checks back on the ground.
	navigation_agent.path_height_offset = maxf(0.0, destination.y - GroundMath.GROUND_Y)
	navigation_agent.target_position = GroundMath.flatten(destination, GroundMath.GROUND_Y)


## The navmesh point nearest `world_position`, so a click on a wall or off the
## map still produces a reachable destination. Falls back to the raw position
## while the actor is outside the tree or the map is not up yet.
func _closest_navigation_point(world_position: Vector3) -> Vector3:
	var world := get_world_3d()
	if world == null:
		return world_position
	var map := world.navigation_map
	if not map.is_valid():
		return world_position
	return NavigationServer3D.map_get_closest_point(map, world_position)


func stop_movement_immediately() -> void:
	velocity = Vector3.ZERO
	if navigation_agent != null:
		navigation_agent.target_position = global_position
	_stuck_timer = 0.0
	_last_position = global_position
	move_and_slide()
	_settle_on_ground()


func is_moving() -> bool:
	if not _alive or navigation_agent == null:
		return false
	return not navigation_agent.is_navigation_finished()


# --- Facing ---------------------------------------------------------------------

func face_toward(world_position: Vector3) -> void:
	var direction := GroundMath.ground_direction(global_position, world_position)
	if direction == Vector3.ZERO:
		return
	rotation.y = GroundMath.yaw_facing(direction)


# --- Health ---------------------------------------------------------------------

func is_alive() -> bool:
	return _alive


## Both entry points land: the 2D game hits enemies with `take_damage` from the
## radial attack and with `receive_damage` from melee, and the player only has
## `take_damage`. They share one path here.
func receive_damage(amount: int) -> void:
	_take_hit(amount)


func take_damage(amount: int) -> void:
	_take_hit(amount)


func _take_hit(amount: int) -> void:
	if not _alive or amount <= 0:
		return
	var applied := _apply_damage(amount)
	if applied <= 0:
		return
	health = maxi(0, health - applied)
	flash_hit()
	if health == 0:
		_die()


## Virtual: turn an incoming hit into the damage that actually lands, and own any
## feedback that depends on the mitigation. The player (WP3b) scales by the active
## soul's defence and halves it while blocking. Return value is subtracted from
## `health` by the caller.
func _apply_damage(amount: int) -> int:
	return maxi(0, amount)


## Virtual hit tint. The base only announces it; WP5 supplies the material flash.
func flash_hit() -> void:
	hit_flashed.emit()


func _die() -> void:
	if not _alive:
		return
	# False from this frame on, so combat logic stops counting the actor while a
	# subclass plays its death beat.
	_alive = false
	velocity = Vector3.ZERO
	if navigation_agent != null:
		navigation_agent.target_position = global_position
	set_deferred("collision_layer", 0)
	_on_died()


## Virtual death hook. The default hides the body; an override that plays a death
## animation simply does not call `super` and hides the body when it is done.
func _on_died() -> void:
	set_deferred("visible", false)


# --- Turn resources --------------------------------------------------------------

func set_turn_based_combat(enabled: bool) -> void:
	_turn_mode = enabled
	if enabled:
		stop_movement_immediately()
		return
	_turn_active = false
	_turn_move_left = 0.0
	_turn_attack_available = false


func start_turn(max_move_meters: float = 6.0) -> void:
	_turn_active = true
	_turn_move_left = maxf(0.0, max_move_meters)
	_turn_attack_available = true


func end_turn() -> void:
	_turn_active = false
	_turn_move_left = 0.0
	_turn_attack_available = false


func consume_turn_movement_meters(used: float) -> void:
	_turn_move_left = maxf(0.0, _turn_move_left - maxf(0.0, used))


func get_turn_remaining_move_meters() -> float:
	return _turn_move_left


func get_turn_remaining_move_cells() -> int:
	return int(floor(_turn_move_left / GroundMath.CELL_SIZE))


## Outside turn-based combat an attack is never gated by the turn budget.
func can_turn_attack() -> bool:
	if not _turn_mode:
		return true
	return _turn_attack_available


func is_turn_active() -> bool:
	return _turn_active


func is_in_turn_based_combat() -> bool:
	return _turn_mode


# --- Attacks ----------------------------------------------------------------------

## Instant melee hit inside `attack_range` metres. The player (WP3b) overrides this
## with the contact-delay coroutine and the enemy (WP3c) with the counter window;
## both keep the `-> bool` return, which the coordinator may await.
func try_attack(target: Node3D = null) -> bool:
	if not _alive or target == null or not is_instance_valid(target):
		return false
	if not can_turn_attack():
		return false
	if target.has_method("is_alive") and not bool(target.call("is_alive")):
		return false
	if GroundMath.ground_distance(global_position, target.global_position) > attack_range + ATTACK_RANGE_TOLERANCE:
		return false
	face_toward(target.global_position)
	if target.has_method("receive_damage"):
		target.call("receive_damage", _outgoing_damage())
	_turn_attack_available = false
	return true


## Virtual: the damage this actor deals with a melee hit. WP3b makes it weapon
## and soul aware.
func _outgoing_damage() -> int:
	return attack_damage


# --- Children ----------------------------------------------------------------------

## The anchor bars and prompts hang from. Null only when the scene is malformed,
## which `_ready` has already reported.
func get_overhead_anchor() -> Node3D:
	return overhead_anchor
