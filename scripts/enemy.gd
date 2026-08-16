extends CharacterBody2D

@export var move_speed := 180.0
@export var max_health := 60
@export var attack_damage := 12
@export var attack_range := 44.0
@export var attack_cooldown := 0.8
@export var target_refresh_interval := 0.25
@export var experience_reward := 50
# Loot dropped on death. Authored items always drop; when the list is empty the
# enemy rolls `loot_drop_chance` against the shared random table instead, so
# runtime-spawned enemies still pay out without per-instance setup.
@export var loot_items: Array[Item] = []
@export var loot_drop_chance := 0.6
@export var loot_drop_spread := 20.0
@export var attack_wind_up_duration := 0.2
@export var attack_strike_duration := 0.12
@export var attack_recovery_duration := 0.2

@onready var collision_shape: CollisionShape2D = $CollisionShape2D
@onready var navigation_agent: NavigationAgent2D = $NavigationAgent2D
@onready var sprite: Sprite2D = $Sprite2D

var _sprite_idle_local := Vector2(0, -16)
var _attack_sequence_active := false
var current_health := 0
var _attack_cooldown_left := 0.0
var _target_refresh_left := 0.0
var _target: Node2D
var in_turn_based_combat := false
var turn_active := false
var turn_remaining_move_meters := 0.0
var turn_attack_available := false
var health_bar_fill: Sprite2D
var hover_outline: Sprite2D


func _ready() -> void:
	add_to_group("enemies")
	_ensure_collision_shape()
	collision_layer = 4
	# Collide with world only — player walks through enemies.
	collision_mask = 1
	current_health = max_health

	navigation_agent.navigation_layers = 1
	navigation_agent.path_desired_distance = 4.0
	navigation_agent.target_desired_distance = 8.0
	navigation_agent.avoidance_enabled = false
	_setup_health_bar()
	_update_health_bar()
	sprite.texture = _create_enemy_texture()
	_sprite_idle_local = sprite.position
	_setup_hover_outline()


func _physics_process(delta: float) -> void:
	if in_turn_based_combat:
		if navigation_agent.is_navigation_finished():
			velocity = Vector2.ZERO
			move_and_slide()
			return

		var turn_next_position := navigation_agent.get_next_path_position()
		velocity = global_position.direction_to(turn_next_position) * move_speed
		move_and_slide()
		return

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


func set_navigation_target(world_position: Vector2) -> void:
	var nav_map_rid := navigation_agent.get_navigation_map()
	var closest_nav_point := NavigationServer2D.map_get_closest_point(nav_map_rid, world_position)
	navigation_agent.target_position = closest_nav_point


func try_attack(target: Node2D) -> void:
	_target = target
	if _attack_sequence_active:
		return
	if not _attack_precheck():
		return
	if in_turn_based_combat:
		turn_attack_available = false
	await _run_attack_sequence_full()


func receive_damage(amount: int) -> void:
	if amount <= 0:
		return
	current_health = maxi(0, current_health - amount)
	_update_health_bar()
	print("Enemy HP: %d/%d" % [current_health, max_health])
	if current_health == 0:
		get_tree().call_group("player", "add_experience", experience_reward)
		# Drop before freeing: LootDropper reads our position and parent, and
		# spawns the pickups as siblings so they outlive us.
		_drop_loot()
		queue_free()


func is_alive() -> bool:
	return current_health > 0


func _drop_loot() -> void:
	var drops: Array[Item] = []
	for item in loot_items:
		if item != null:
			drops.append(item)

	if drops.is_empty() and randf() < loot_drop_chance:
		drops.append(ItemFactory.create_random_loot())

	LootDropper.drop_items(self, drops, loot_drop_spread)


func _try_attack_target() -> void:
	if _attack_sequence_active:
		return
	if not _attack_precheck():
		return
	_run_attack_sequence_full()


func _attack_precheck() -> bool:
	if in_turn_based_combat:
		if not turn_active or not turn_attack_available:
			return false
	else:
		if _attack_cooldown_left > 0.0:
			return false
	if _target == null or not is_instance_valid(_target):
		return false
	if _target.has_method("is_alive") and not _target.call("is_alive"):
		return false
	if global_position.distance_to(_target.global_position) > attack_range:
		return false
	return _target.has_method("receive_damage")


func _run_attack_sequence_full() -> void:
	var target := _target
	if target == null or not is_instance_valid(target):
		return

	_attack_sequence_active = true
	if target.has_method("begin_enemy_counter_windup"):
		target.call("begin_enemy_counter_windup", self, attack_damage)

	var idle_pos := _sprite_idle_local
	var idle_scale := Vector2.ONE
	var to_target := target.global_position - global_position
	if to_target.length() < 0.001:
		to_target = Vector2.RIGHT
	else:
		to_target = to_target.normalized()
	var lunge := Vector2(to_target.x * 11.0, to_target.y * 7.0)

	# 1) Wind-up — telegraph only, no damage
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(sprite, "position", idle_pos + Vector2(-6, 4), attack_wind_up_duration).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(sprite, "scale", Vector2(0.86, 1.12), attack_wind_up_duration)
	tween.tween_property(sprite, "modulate", Color(0.52, 0.22, 0.22, 1.0), attack_wind_up_duration)
	await tween.finished

	if not is_instance_valid(self) or not is_alive():
		_cancel_counter_on_target(target)
		_attack_sequence_active = false
		return
	if not is_instance_valid(target) or global_position.distance_to(target.global_position) > attack_range * 1.2:
		_cancel_counter_on_target(target)
		_reset_attack_sprite_pose(idle_pos, idle_scale)
		_attack_sequence_active = false
		if not in_turn_based_combat:
			_attack_cooldown_left = attack_cooldown * 0.35
		return

	# 2) Strike — counter window; damage resolves after the lunge
	if target.has_method("begin_enemy_counter_strike"):
		target.call("begin_enemy_counter_strike")

	tween = create_tween()
	tween.set_parallel(true)
	tween.tween_property(sprite, "position", idle_pos + lunge, attack_strike_duration).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.tween_property(sprite, "scale", Vector2(1.14, 0.9), attack_strike_duration)
	tween.tween_property(sprite, "modulate", Color(1.0, 0.48, 0.48, 1.0), attack_strike_duration * 0.45)
	await tween.finished

	if not is_instance_valid(self):
		_cancel_counter_on_target(target)
		_attack_sequence_active = false
		return

	if is_instance_valid(target):
		if target.has_method("resolve_enemy_attack"):
			target.call("resolve_enemy_attack", self, attack_damage)
		elif target.has_method("receive_damage"):
			target.call("receive_damage", attack_damage)

	# 3) Recovery — after damage, return to neutral
	tween = create_tween()
	tween.set_parallel(true)
	tween.tween_property(sprite, "position", idle_pos, attack_recovery_duration).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(sprite, "scale", idle_scale, attack_recovery_duration)
	tween.tween_property(sprite, "modulate", Color(1, 1, 1, 1), attack_recovery_duration)
	await tween.finished

	_attack_sequence_active = false
	if not in_turn_based_combat:
		_attack_cooldown_left = attack_cooldown


func _cancel_counter_on_target(counter_target: Node2D) -> void:
	if counter_target != null and is_instance_valid(counter_target) and counter_target.has_method("cancel_enemy_counter"):
		counter_target.call("cancel_enemy_counter")


func _reset_attack_sprite_pose(idle_pos: Vector2, idle_scale: Vector2) -> void:
	sprite.position = idle_pos
	sprite.scale = idle_scale
	sprite.modulate = Color(1, 1, 1, 1)


func _refresh_target_position() -> void:
	if _target == null or not is_instance_valid(_target):
		return

	var nav_map_rid := navigation_agent.get_navigation_map()
	var approach_point := _compute_approach_point(_target.global_position, maxf(4.0, attack_range - 20.0))
	var closest_nav_point := NavigationServer2D.map_get_closest_point(nav_map_rid, approach_point)
	navigation_agent.target_position = closest_nav_point


func _compute_approach_point(target_world_position: Vector2, stop_distance: float) -> Vector2:
	var to_mover := global_position - target_world_position
	var distance := to_mover.length()
	if distance <= stop_distance:
		return global_position
	if distance <= 0.001:
		return target_world_position
	return target_world_position + (to_mover / distance) * stop_distance


func _ensure_collision_shape() -> void:
	var circle := collision_shape.shape as CircleShape2D
	if circle == null:
		circle = CircleShape2D.new()
		collision_shape.shape = circle
	circle.radius = 7.0
	collision_shape.position = Vector2(0, -2)


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
	health_bar_fill.texture = _create_solid_texture(Vector2i(28, 4), Color(0.88, 0.2, 0.2, 1.0))


func _update_health_bar() -> void:
	if health_bar_fill == null:
		return

	var ratio := 0.0
	if max_health > 0:
		ratio = clampf(float(current_health) / float(max_health), 0.0, 1.0)
	health_bar_fill.scale = Vector2(ratio, 1.0)


func _create_solid_texture(size: Vector2i, color: Color) -> Texture2D:
	var image := Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)
	image.fill(color)
	return ImageTexture.create_from_image(image)


func _setup_hover_outline() -> void:
	hover_outline = get_node_or_null("HoverOutline") as Sprite2D
	if hover_outline == null:
		hover_outline = Sprite2D.new()
		hover_outline.name = "HoverOutline"
		add_child(hover_outline)

	hover_outline.texture = _create_outline_texture(Vector2i(28, 36), Color(0.95, 0.14, 0.14, 0.95), 2)
	hover_outline.position = Vector2(0, -16)
	hover_outline.z_index = sprite.z_index + 2
	hover_outline.visible = false


func set_hover_highlighted(enabled: bool) -> void:
	if hover_outline != null:
		hover_outline.visible = enabled


func _create_outline_texture(size: Vector2i, color: Color, border: int) -> Texture2D:
	var image := Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)
	image.fill(Color(0, 0, 0, 0))

	for y in range(size.y):
		for x in range(size.x):
			var on_border := x < border or x >= size.x - border or y < border or y >= size.y - border
			if on_border:
				image.set_pixel(x, y, color)

	return ImageTexture.create_from_image(image)


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


func stop_movement_immediately() -> void:
	velocity = Vector2.ZERO
	navigation_agent.target_position = global_position
	move_and_slide()


func set_turn_based_combat(enabled: bool) -> void:
	in_turn_based_combat = enabled
	if enabled:
		stop_movement_immediately()
		return

	if not enabled:
		turn_active = false
		turn_remaining_move_meters = 0.0
		turn_attack_available = false


func start_turn(max_move_meters: float = 6.0) -> void:
	turn_active = true
	turn_remaining_move_meters = maxf(0.0, max_move_meters)
	turn_attack_available = true


func end_turn() -> void:
	turn_active = false
	turn_remaining_move_meters = 0.0
	turn_attack_available = false


func consume_turn_movement_meters(used: float) -> void:
	turn_remaining_move_meters = maxf(0.0, turn_remaining_move_meters - maxf(0.0, used))


func get_turn_remaining_move_meters() -> float:
	return turn_remaining_move_meters


func can_turn_attack() -> bool:
	return turn_attack_available


func get_turn_remaining_move_cells() -> int:
	return int(round(turn_remaining_move_meters))


func is_moving() -> bool:
	return not navigation_agent.is_navigation_finished()
