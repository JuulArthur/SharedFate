extends CharacterBody2D

@export var move_speed := 220.0
@export var max_health := 100
@export var attack_damage := 20
@export var attack_range := 28.0
@export var attack_cooldown := 0.35
@export var target_refresh_interval := 0.2
@export var attack_action_name := "attack"

@onready var collision_shape: CollisionShape2D = $CollisionShape2D
@onready var navigation_agent: NavigationAgent2D = $NavigationAgent2D
@onready var sprite: Sprite2D = $Sprite2D
@onready var vision_light: PointLight2D = $VisionLight

var current_health := 100
var attack_cooldown_left := 0.0
var health_bar_fill: Sprite2D
var attack_target: Node2D
var target_refresh_left := 0.0


func _ready() -> void:
	_ensure_collision_shape()
	collision_layer = 2
	collision_mask = 1

	navigation_agent.navigation_layers = 1
	navigation_agent.path_desired_distance = 4.0
	navigation_agent.target_desired_distance = 8.0

	_ensure_attack_input()
	_setup_health_bar()
	current_health = max_health
	_update_health_bar()

	sprite.texture = _create_placeholder_texture()
	vision_light.texture = _create_vision_light_texture()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(attack_action_name):
		_try_attack()


func _physics_process(delta: float) -> void:
	attack_cooldown_left = maxf(attack_cooldown_left - delta, 0.0)
	target_refresh_left -= delta

	if attack_target != null and is_instance_valid(attack_target):
		if attack_target.has_method("is_alive") and not attack_target.call("is_alive"):
			clear_attack_target()
		else:
			if target_refresh_left <= 0.0:
				_refresh_attack_target_position()
				target_refresh_left = target_refresh_interval

			if global_position.distance_to(attack_target.global_position) <= attack_range:
				velocity = Vector2.ZERO
				move_and_slide()
				_try_attack_target(attack_target)
			elif not navigation_agent.is_navigation_finished():
				var target_next_position := navigation_agent.get_next_path_position()
				velocity = global_position.direction_to(target_next_position) * move_speed
				move_and_slide()
			else:
				velocity = Vector2.ZERO
				move_and_slide()
			return

	if navigation_agent.is_navigation_finished():
		velocity = Vector2.ZERO
		move_and_slide()
		return

	var next_position := navigation_agent.get_next_path_position()
	velocity = global_position.direction_to(next_position) * move_speed
	move_and_slide()


func snap_to(world_position: Vector2) -> void:
	global_position = world_position
	navigation_agent.target_position = world_position


func set_navigation_target(world_position: Vector2) -> void:
	clear_attack_target()
	var nav_map_rid := navigation_agent.get_navigation_map()
	var closest_nav_point := NavigationServer2D.map_get_closest_point(nav_map_rid, world_position)
	navigation_agent.target_position = closest_nav_point


func set_attack_target(target: Node2D) -> void:
	if target == null:
		clear_attack_target()
		return
	attack_target = target
	_refresh_attack_target_position()
	target_refresh_left = target_refresh_interval


func clear_attack_target() -> void:
	attack_target = null


func take_damage(amount: int) -> void:
	current_health = maxi(0, current_health - maxi(amount, 0))
	_update_health_bar()


func receive_damage(amount: int) -> void:
	take_damage(amount)


func heal(amount: int) -> void:
	current_health = mini(max_health, current_health + maxi(amount, 0))
	_update_health_bar()


func _try_attack() -> void:
	if attack_cooldown_left > 0.0:
		return

	attack_cooldown_left = attack_cooldown
	_flash_attack_feedback()
	_apply_attack_damage()


func try_attack(_target: Node2D = null) -> void:
	_try_attack()


func _try_attack_target(target: Node2D) -> void:
	if attack_cooldown_left > 0.0:
		return
	if target == null or not is_instance_valid(target):
		return
	if global_position.distance_to(target.global_position) > attack_range:
		return
	if not target.has_method("receive_damage"):
		return

	attack_cooldown_left = attack_cooldown
	_flash_attack_feedback()
	target.call("receive_damage", attack_damage)


func _refresh_attack_target_position() -> void:
	if attack_target == null or not is_instance_valid(attack_target):
		return

	var nav_map_rid := navigation_agent.get_navigation_map()
	var closest_nav_point := NavigationServer2D.map_get_closest_point(nav_map_rid, attack_target.global_position)
	navigation_agent.target_position = closest_nav_point


func _apply_attack_damage() -> void:
	var shape := CircleShape2D.new()
	shape.radius = attack_range

	var params := PhysicsShapeQueryParameters2D.new()
	params.shape = shape
	params.transform = Transform2D(0.0, global_position)
	params.collision_mask = collision_mask
	params.exclude = [self]

	var hits := get_world_2d().direct_space_state.intersect_shape(params, 16)
	for hit in hits:
		var collider := hit.get("collider") as Object
		if collider != null and collider.has_method("take_damage"):
			collider.call("take_damage", attack_damage)


func _flash_attack_feedback() -> void:
	sprite.modulate = Color(1.0, 0.72, 0.72, 1.0)
	var tween := create_tween()
	tween.tween_property(sprite, "modulate", Color(1, 1, 1, 1), 0.12)


func _setup_health_bar() -> void:
	var root := get_node_or_null("HealthBarRoot") as Node2D
	if root == null:
		root = Node2D.new()
		root.name = "HealthBarRoot"
		root.position = Vector2(-14, -34)
		add_child(root)

	var bg := root.get_node_or_null("Background") as Sprite2D
	if bg == null:
		bg = Sprite2D.new()
		bg.name = "Background"
		bg.centered = false
		root.add_child(bg)
	bg.texture = _create_solid_texture(Vector2i(28, 4), Color(0.16, 0.16, 0.16, 0.95))

	health_bar_fill = root.get_node_or_null("Fill") as Sprite2D
	if health_bar_fill == null:
		health_bar_fill = Sprite2D.new()
		health_bar_fill.name = "Fill"
		health_bar_fill.centered = false
		root.add_child(health_bar_fill)
	health_bar_fill.texture = _create_solid_texture(Vector2i(28, 4), Color(0.15, 0.82, 0.22, 1.0))


func _update_health_bar() -> void:
	if health_bar_fill == null:
		return

	var ratio := 0.0
	if max_health > 0:
		ratio = clampf(float(current_health) / float(max_health), 0.0, 1.0)
	health_bar_fill.scale = Vector2(ratio, 1.0)


func _ensure_attack_input() -> void:
	if not InputMap.has_action(attack_action_name):
		InputMap.add_action(attack_action_name)

	var has_space_key := false
	var events := InputMap.action_get_events(attack_action_name)
	for e in events:
		if e is InputEventKey and e.physical_keycode == KEY_SPACE:
			has_space_key = true
			break

	if not has_space_key:
		var key_event := InputEventKey.new()
		key_event.physical_keycode = KEY_SPACE
		InputMap.action_add_event(attack_action_name, key_event)


func _ensure_collision_shape() -> void:
	var circle := collision_shape.shape as CircleShape2D
	if circle == null:
		circle = CircleShape2D.new()
		collision_shape.shape = circle
	circle.radius = 10.0
	collision_shape.position = Vector2(0, -2)


func _create_solid_texture(size: Vector2i, color: Color) -> Texture2D:
	var image := Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)
	image.fill(color)
	return ImageTexture.create_from_image(image)


func _create_placeholder_texture() -> Texture2D:
	var image := Image.create(24, 32, false, Image.FORMAT_RGBA8)
	image.fill(Color(0, 0, 0, 0))

	for y in range(10, 30):
		for x in range(8, 16):
			image.set_pixel(x, y, Color(0.24, 0.52, 0.82))

	for y in range(3, 11):
		for x in range(7, 17):
			image.set_pixel(x, y, Color(0.92, 0.80, 0.67))

	for y in range(29, 32):
		for x in range(7, 10):
			image.set_pixel(x, y, Color(0.13, 0.12, 0.12))
		for x in range(14, 17):
			image.set_pixel(x, y, Color(0.13, 0.12, 0.12))

	return ImageTexture.create_from_image(image)


func _create_vision_light_texture() -> Texture2D:
	var size := 256
	var image := Image.create(size, size, false, Image.FORMAT_RGBA8)
	image.fill(Color(1, 1, 1, 0))

	var center := Vector2(float(size) * 0.5, float(size) * 0.5)
	var radius := float(size) * 0.5

	for y in range(size):
		for x in range(size):
			var d: float = Vector2(float(x), float(y)).distance_to(center) / radius
			var alpha: float = clampf(1.0 - d, 0.0, 1.0)
			alpha = float(smoothstep(0.0, 1.0, alpha))
			image.set_pixel(x, y, Color(1, 1, 1, alpha))

	return ImageTexture.create_from_image(image)


func _on_navigation_agent_2d_velocity_computed(safe_velocity: Vector2) -> void:
	velocity = safe_velocity
