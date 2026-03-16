extends CharacterBody2D

@export var move_speed := 180.0
@export var max_health := 60
@export var attack_damage := 12
@export var attack_range := 36.0
@export var attack_cooldown := 0.8
@export var target_refresh_interval := 0.25

@onready var collision_shape: CollisionShape2D = $CollisionShape2D
@onready var navigation_agent: NavigationAgent2D = $NavigationAgent2D
@onready var sprite: Sprite2D = $Sprite2D

var current_health := 0
var _attack_cooldown_left := 0.0
var _target_refresh_left := 0.0
var _target: Node2D


func _ready() -> void:
	_ensure_collision_shape()
	collision_layer = 4
	collision_mask = 1
	current_health = max_health

	navigation_agent.navigation_layers = 1
	navigation_agent.path_desired_distance = 4.0
	navigation_agent.target_desired_distance = 8.0

	sprite.texture = _create_enemy_texture()


func _physics_process(delta: float) -> void:
	_attack_cooldown_left = maxf(0.0, _attack_cooldown_left - delta)
	_target_refresh_left -= delta

	if not is_alive():
		velocity = Vector2.ZERO
		move_and_slide()
		return

	if _target == null or not is_instance_valid(_target):
		velocity = Vector2.ZERO
		move_and_slide()
		return
	if _target.has_method("is_alive") and not _target.call("is_alive"):
		velocity = Vector2.ZERO
		move_and_slide()
		return

	if _target_refresh_left <= 0.0:
		_refresh_target_position()
		_target_refresh_left = target_refresh_interval

	var distance_to_target := global_position.distance_to(_target.global_position)
	if distance_to_target <= attack_range:
		velocity = Vector2.ZERO
		move_and_slide()
		_try_attack_target()
		return

	if navigation_agent.is_navigation_finished():
		velocity = Vector2.ZERO
		move_and_slide()
		return

	var next_position := navigation_agent.get_next_path_position()
	velocity = global_position.direction_to(next_position) * move_speed
	move_and_slide()


func set_target(target: Node2D) -> void:
	_target = target
	_refresh_target_position()


func snap_to(world_position: Vector2) -> void:
	global_position = world_position
	navigation_agent.target_position = world_position


func receive_damage(amount: int) -> void:
	if amount <= 0:
		return
	current_health = maxi(0, current_health - amount)
	print("Enemy HP: %d/%d" % [current_health, max_health])
	if current_health == 0:
		queue_free()


func is_alive() -> bool:
	return current_health > 0


func _try_attack_target() -> void:
	if _attack_cooldown_left > 0.0:
		return
	if _target == null or not is_instance_valid(_target):
		return
	if global_position.distance_to(_target.global_position) > attack_range:
		return
	if not _target.has_method("receive_damage"):
		return

	_target.call("receive_damage", attack_damage)
	_attack_cooldown_left = attack_cooldown


func _refresh_target_position() -> void:
	if _target == null or not is_instance_valid(_target):
		return

	var nav_map_rid := navigation_agent.get_navigation_map()
	var closest_nav_point := NavigationServer2D.map_get_closest_point(nav_map_rid, _target.global_position)
	navigation_agent.target_position = closest_nav_point


func _ensure_collision_shape() -> void:
	var circle := collision_shape.shape as CircleShape2D
	if circle == null:
		circle = CircleShape2D.new()
		collision_shape.shape = circle
	circle.radius = 10.0
	collision_shape.position = Vector2(0, -2)


func _create_enemy_texture() -> Texture2D:
	var image := Image.create(24, 32, false, Image.FORMAT_RGBA8)
	image.fill(Color(0, 0, 0, 0))

	for y in range(10, 30):
		for x in range(8, 16):
			image.set_pixel(x, y, Color(0.70, 0.18, 0.18))

	for y in range(3, 11):
		for x in range(7, 17):
			image.set_pixel(x, y, Color(0.78, 0.73, 0.62))

	for y in range(12, 16):
		for x in range(9, 11):
			image.set_pixel(x, y, Color(0.1, 0.05, 0.05))
		for x in range(13, 15):
			image.set_pixel(x, y, Color(0.1, 0.05, 0.05))

	for y in range(29, 32):
		for x in range(7, 10):
			image.set_pixel(x, y, Color(0.08, 0.08, 0.08))
		for x in range(14, 17):
			image.set_pixel(x, y, Color(0.08, 0.08, 0.08))

	return ImageTexture.create_from_image(image)
