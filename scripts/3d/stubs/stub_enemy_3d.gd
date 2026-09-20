extends "res://scripts/3d/stubs/stub_actor_3d.gd"

## WP0 stub enemy: the enemy-only half of the actor contract
## (docs/3d-port-contracts.md, section 5.3) plus a crude realtime chase so the
## arena skeleton has something moving. No counter prompt, no loot, no telegraph.

@export var experience_reward := 50
@export var aggro_range := 4.0
@export var attack_cooldown := 1.0

var _target: Node3D = null
var _root_turns := 0
var _hover_highlighted := false
var _cooldown_left := 0.0


func _physics_process(delta: float) -> void:
	_cooldown_left = maxf(0.0, _cooldown_left - delta)
	if _alive and not _turn_mode:
		_chase_and_bite()
	super(delta)


func _chase_and_bite() -> void:
	var target := _current_target()
	if target == null:
		return
	var distance := GroundMath.ground_distance(global_position, target.global_position)
	if distance > aggro_range and aggro_range > 0.0:
		return
	if distance > attack_range:
		set_navigation_target(target.global_position)
		return
	stop_movement_immediately()
	if _cooldown_left <= 0.0:
		try_attack(target)
		_cooldown_left = attack_cooldown


func _current_target() -> Node3D:
	if _target != null and is_instance_valid(_target):
		if not _target.has_method("is_alive") or bool(_target.call("is_alive")):
			return _target
	var players := get_tree().get_nodes_in_group("player")
	if players.is_empty():
		return null
	var candidate := players[0] as Node3D
	if candidate != null and candidate.has_method("is_alive") and not bool(candidate.call("is_alive")):
		return null
	return candidate


# --- Enemy-only contract -------------------------------------------------------

func set_target(target: Node3D) -> void:
	_target = target


func set_hover_highlighted(enabled: bool) -> void:
	_hover_highlighted = enabled
	var mesh := get_node_or_null("MeshInstance3D") as MeshInstance3D
	if mesh != null:
		mesh.scale = Vector3.ONE * (1.08 if enabled else 1.0)


func apply_root(turns: int) -> void:
	_root_turns = maxi(_root_turns, turns)


func is_rooted() -> bool:
	return _root_turns > 0


func start_turn(max_move_meters: float = 6.0) -> void:
	super(0.0 if is_rooted() else max_move_meters)


func end_turn() -> void:
	super()
	if _root_turns > 0:
		_root_turns -= 1


## The 2D enemy's try_attack returned void; in 3D both actors return bool (GDScript
## requires overrides to match the base signature). The player resolves the hit
## through resolve_enemy_attack so the counter window can negate it.
func try_attack(target: Node3D = null) -> bool:
	if not _alive or target == null or not is_instance_valid(target) or not can_turn_attack():
		return false
	if GroundMath.ground_distance(global_position, target.global_position) > attack_range + 0.05:
		return false
	var direction := GroundMath.ground_direction(global_position, target.global_position)
	if direction != Vector3.ZERO:
		rotation.y = GroundMath.yaw_facing(direction)
	if target.has_method("resolve_enemy_attack"):
		target.call("resolve_enemy_attack", self, attack_damage)
	elif target.has_method("receive_damage"):
		target.call("receive_damage", attack_damage)
	_turn_attack_available = false
	return true


func _die() -> void:
	super()
	for player in get_tree().get_nodes_in_group("player"):
		if player.has_method("add_experience"):
			player.call("add_experience", experience_reward)
