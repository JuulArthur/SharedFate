extends CharacterBody2D

@export var move_speed := 220.0
@export var max_health := 100
@export var attack_damage := 20
@export var attack_range := 40.0
@export var attack_approach_buffer := 20.0
@export var attack_cooldown := 0.35
@export var attack_animation_speed_scale := 1.6
@export var target_refresh_interval := 0.2
@export var attack_action_name := "attack"
@export var ranged_attack_damage := 16

const XP_BASE_TO_LEVEL_2 := 100.0
const XP_PER_LEVEL_MULT := 1.5

@onready var collision_shape: CollisionShape2D = $CollisionShape2D
@onready var navigation_agent: NavigationAgent2D = $NavigationAgent2D
@onready var sprite: Sprite2D = $Sprite2D
@onready var vision_light: PointLight2D = $VisionLight

var current_health := 100
var player_level := 1
var experience_points := 0.0
var attack_cooldown_left := 0.0
var health_bar_fill: Sprite2D
var xp_bar_fill: Sprite2D
var level_label: Label
var attack_target: Node2D
var target_refresh_left := 0.0
var in_turn_based_combat := false
var turn_active := false
var turn_remaining_move_meters := 0.0
var turn_attack_available := false
var blocking_active := false
var facing_direction := Vector2.RIGHT
var attack_slash: Sprite2D
var sprite_idle_position := Vector2.ZERO
var manual_path_points: Array[Vector2] = []
var manual_path_index := 0
var _stuck_timer := 0.0
var _last_position := Vector2.ZERO
const STUCK_THRESHOLD := 1.0
const STUCK_MOVE_EPSILON := 2.0


func _ready() -> void:
	_ensure_collision_shape()
	collision_layer = 2
	# Collide with world only — walk through enemies.
	collision_mask = 1

	navigation_agent.navigation_layers = 1
	navigation_agent.path_desired_distance = 4.0
	navigation_agent.target_desired_distance = 8.0
	navigation_agent.avoidance_enabled = false

	add_to_group("player")

	_ensure_attack_input()
	_setup_health_bar()
	_setup_level_and_xp_ui()
	current_health = max_health
	_update_health_bar()
	_update_xp_bar()
	_update_level_label()

	sprite.texture = _create_placeholder_texture()
	sprite_idle_position = sprite.position
	vision_light.texture = _create_vision_light_texture()
	_setup_attack_vfx()


func _unhandled_input(event: InputEvent) -> void:
	if in_turn_based_combat:
		return
	if event.is_action_pressed(attack_action_name):
		_try_attack()


func _physics_process(delta: float) -> void:
	_check_stuck(delta)

	if _process_manual_path_movement():
		return

	if in_turn_based_combat:
		if navigation_agent.is_navigation_finished():
			velocity = Vector2.ZERO
			move_and_slide()
			return

		var turn_next_position := navigation_agent.get_next_path_position()
		velocity = global_position.direction_to(turn_next_position) * move_speed
		_update_facing_from_velocity(velocity)
		move_and_slide()
		return

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
				_update_facing_from_velocity(velocity)
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
	_update_facing_from_velocity(velocity)
	move_and_slide()


func snap_to(world_position: Vector2) -> void:
	global_position = world_position
	navigation_agent.target_position = world_position


func set_navigation_target(world_position: Vector2) -> void:
	clear_attack_target()
	manual_path_points.clear()
	manual_path_index = 0
	_stuck_timer = 0.0
	_last_position = global_position
	var nav_map_rid := navigation_agent.get_navigation_map()
	var closest_nav_point := NavigationServer2D.map_get_closest_point(nav_map_rid, world_position)
	navigation_agent.target_position = closest_nav_point


func set_navigation_path(points: Array[Vector2]) -> void:
	manual_path_points = points.duplicate()
	manual_path_index = 0
	navigation_agent.target_position = global_position


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
	var final_amount := maxi(amount, 0)
	if blocking_active and final_amount > 0:
		final_amount = maxi(1, int(ceil(float(final_amount) * 0.5)))
	current_health = maxi(0, current_health - final_amount)
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
	if in_turn_based_combat:
		if not turn_active:
			return
		if not turn_attack_available:
			return
		if _target == null or not is_instance_valid(_target):
			return
		if not _target.has_method("receive_damage"):
			return
		if global_position.distance_to(_target.global_position) > attack_range:
			return

		turn_attack_available = false
		_flash_attack_feedback()
		_target.call("receive_damage", attack_damage)
		return

	_try_attack()


func try_ranged_attack(_target: Node2D = null) -> void:
	if in_turn_based_combat:
		if not turn_active:
			return
		if not turn_attack_available:
			return
		if _target == null or not is_instance_valid(_target):
			return
		if not _target.has_method("receive_damage"):
			return

		turn_attack_available = false
		_face_toward_world(_target.global_position)
		_flash_ranged_feedback(_target)
		_target.call("receive_damage", ranged_attack_damage)
		return


func _face_toward_world(world_position: Vector2) -> void:
	var d := world_position - global_position
	if d.length() > 0.01:
		facing_direction = d.normalized()
		sprite.flip_h = facing_direction.x < 0.0


func _flash_ranged_feedback(_target: Node2D) -> void:
	var speed_scale := maxf(attack_animation_speed_scale, 0.1)
	var t_col := 0.1 * speed_scale
	var t_reset := 0.18 * speed_scale

	sprite.modulate = Color(0.75, 0.92, 1.0, 1.0)
	var tween := create_tween()
	tween.tween_property(sprite, "modulate", Color(1, 1, 1, 1), t_reset)

	var bolt := Line2D.new()
	bolt.width = 2.5
	bolt.default_color = Color(0.4, 0.85, 1.0, 0.95)
	bolt.z_index = sprite.z_index + 2
	add_child(bolt)
	bolt.add_point(Vector2.ZERO)
	bolt.add_point(to_local(_target.global_position))
	var bolt_tween := create_tween()
	bolt_tween.tween_property(bolt, "default_color:a", 0.0, 0.22 * speed_scale)
	bolt_tween.tween_callback(bolt.queue_free)


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
	var approach_point := _compute_approach_point(attack_target.global_position, get_preferred_attack_approach_distance())
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


func get_preferred_attack_approach_distance() -> float:
	return maxf(4.0, attack_range - attack_approach_buffer)


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
	var speed_scale := maxf(attack_animation_speed_scale, 0.1)
	var t_fast := 0.06 * speed_scale
	var t_med := 0.08 * speed_scale
	var t_reset := 0.12 * speed_scale
	var t_slash_in := 0.04 * speed_scale
	var t_slash_hold := 0.08 * speed_scale
	var t_slash_out := 0.10 * speed_scale

	var attack_dir := facing_direction.normalized()
	if attack_dir.length() <= 0.001:
		attack_dir = Vector2.RIGHT

	sprite.modulate = Color(1.0, 0.72, 0.72, 1.0)
	sprite.position = sprite_idle_position
	sprite.scale = Vector2.ONE

	if attack_slash != null:
		attack_slash.visible = true
		attack_slash.modulate = Color(1.0, 0.95, 0.85, 0.0)
		attack_slash.position = Vector2(sign(attack_dir.x) * 14.0, -16.0)
		attack_slash.rotation = attack_dir.angle()
		attack_slash.scale = Vector2(0.7, 0.7)

	var tween := create_tween()
	tween.tween_property(sprite, "modulate", Color(1, 1, 1, 1), t_reset)
	tween.parallel().tween_property(sprite, "position", sprite_idle_position + attack_dir * 3.5, t_fast)
	tween.parallel().tween_property(sprite, "scale", Vector2(1.08, 0.94), t_fast)

	var return_tween := create_tween()
	return_tween.tween_interval(t_fast)
	return_tween.tween_property(sprite, "position", sprite_idle_position, t_med)
	return_tween.parallel().tween_property(sprite, "scale", Vector2.ONE, t_med)

	if attack_slash != null:
		var slash_tween := create_tween()
		slash_tween.tween_property(attack_slash, "modulate", Color(1.0, 0.95, 0.85, 0.95), t_slash_in)
		slash_tween.parallel().tween_property(attack_slash, "scale", Vector2(1.2, 1.2), t_slash_hold)
		slash_tween.tween_property(attack_slash, "modulate", Color(1.0, 0.95, 0.85, 0.0), t_slash_out)
		slash_tween.tween_callback(func() -> void:
			if attack_slash != null:
				attack_slash.visible = false
		)


func _update_facing_from_velocity(v: Vector2) -> void:
	if v.length() < 0.001:
		return
	facing_direction = v.normalized()
	sprite.flip_h = facing_direction.x < 0.0


func _setup_attack_vfx() -> void:
	attack_slash = get_node_or_null("AttackSlash") as Sprite2D
	if attack_slash == null:
		attack_slash = Sprite2D.new()
		attack_slash.name = "AttackSlash"
		add_child(attack_slash)

	attack_slash.texture = _create_slash_texture()
	attack_slash.z_index = sprite.z_index + 1
	attack_slash.centered = true
	attack_slash.visible = false
	attack_slash.position = Vector2(14, -16)


func _create_slash_texture() -> Texture2D:
	var image := Image.create(28, 28, false, Image.FORMAT_RGBA8)
	image.fill(Color(0, 0, 0, 0))

	var center := Vector2(14.0, 14.0)
	for y in range(28):
		for x in range(28):
			var p := Vector2(float(x), float(y))
			var r := p.distance_to(center)
			var a := atan2(p.y - center.y, p.x - center.x)
			if r >= 7.0 and r <= 11.0 and a > -1.6 and a < -0.2:
				image.set_pixel(x, y, Color(1.0, 0.96, 0.84, 0.95))

	return ImageTexture.create_from_image(image)


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


func _setup_level_and_xp_ui() -> void:
	level_label = Label.new()
	level_label.name = "LevelLabel"
	level_label.text = "Lv 1"
	level_label.position = Vector2(-22, -52)
	level_label.add_theme_font_size_override("font_size", 10)
	level_label.add_theme_color_override("font_color", Color(0.95, 0.88, 0.65, 1.0))
	level_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.85))
	level_label.add_theme_constant_override("shadow_offset_x", 1)
	level_label.add_theme_constant_override("shadow_offset_y", 1)
	add_child(level_label)

	var xp_root := Node2D.new()
	xp_root.name = "XpBarRoot"
	xp_root.position = Vector2(-14, -44)
	add_child(xp_root)

	var xp_bg := Sprite2D.new()
	xp_bg.name = "Background"
	xp_bg.centered = false
	xp_bg.texture = _create_solid_texture(Vector2i(28, 3), Color(0.12, 0.12, 0.14, 0.95))
	xp_root.add_child(xp_bg)

	xp_bar_fill = Sprite2D.new()
	xp_bar_fill.name = "Fill"
	xp_bar_fill.centered = false
	xp_bar_fill.texture = _create_solid_texture(Vector2i(28, 3), Color(0.55, 0.45, 0.95, 1.0))
	xp_root.add_child(xp_bar_fill)


func xp_required_for_next_level() -> float:
	return XP_BASE_TO_LEVEL_2 * pow(XP_PER_LEVEL_MULT, float(player_level - 1))


func add_experience(amount: int) -> void:
	if amount <= 0:
		return
	experience_points += float(amount)
	while experience_points + 0.0001 >= xp_required_for_next_level():
		experience_points -= xp_required_for_next_level()
		player_level += 1
		_on_level_up()
	_update_xp_bar()
	_update_level_label()


func _on_level_up() -> void:
	pass


func get_player_level() -> int:
	return player_level


func get_experience_toward_next() -> float:
	return experience_points


func get_xp_required_for_next_level() -> float:
	return xp_required_for_next_level()


func _update_level_label() -> void:
	if level_label != null:
		level_label.text = "Lv %d" % player_level


func _update_xp_bar() -> void:
	if xp_bar_fill == null:
		return
	var need := xp_required_for_next_level()
	var ratio := 0.0
	if need > 0.0:
		ratio = clampf(experience_points / need, 0.0, 1.0)
	xp_bar_fill.scale = Vector2(ratio, 1.0)


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
	circle.radius = 7.0
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
	move_and_slide()


func _check_stuck(delta: float) -> void:
	var is_trying_to_move := not navigation_agent.is_navigation_finished() or manual_path_index < manual_path_points.size()
	if not is_trying_to_move:
		_stuck_timer = 0.0
		_last_position = global_position
		return

	if global_position.distance_to(_last_position) > STUCK_MOVE_EPSILON:
		_stuck_timer = 0.0
		_last_position = global_position
		return

	_stuck_timer += delta
	if _stuck_timer >= STUCK_THRESHOLD:
		stop_movement_immediately()
		_stuck_timer = 0.0


func stop_movement_immediately() -> void:
	velocity = Vector2.ZERO
	navigation_agent.target_position = global_position
	manual_path_points.clear()
	manual_path_index = 0
	clear_attack_target()
	move_and_slide()


func set_turn_based_combat(enabled: bool) -> void:
	in_turn_based_combat = enabled
	blocking_active = false
	if enabled:
		stop_movement_immediately()
		return

	if not enabled:
		turn_active = false
		turn_remaining_move_meters = 0.0
		turn_attack_available = false
		clear_attack_target()


func start_turn(max_move_meters: float = 6.0) -> void:
	turn_active = true
	turn_remaining_move_meters = maxf(0.0, max_move_meters)
	turn_attack_available = true
	blocking_active = false


func end_turn() -> void:
	turn_active = false
	turn_remaining_move_meters = 0.0
	turn_attack_available = false


func consume_turn_movement_meters(used_meters: float) -> void:
	turn_remaining_move_meters = maxf(0.0, turn_remaining_move_meters - maxf(0.0, used_meters))


func consume_turn_movement(used_cells: int) -> void:
	# Backward-compatible alias (1 cell == 1 meter in turn mode).
	consume_turn_movement_meters(float(maxi(0, used_cells)))


func is_turn_active() -> bool:
	return turn_active


func can_turn_attack() -> bool:
	return turn_attack_available


func get_turn_remaining_move_meters() -> float:
	return turn_remaining_move_meters


func get_turn_remaining_move_cells() -> int:
	# Backward-compatible alias.
	return int(round(turn_remaining_move_meters))


func is_moving() -> bool:
	return manual_path_index < manual_path_points.size() or not navigation_agent.is_navigation_finished()


func is_alive() -> bool:
	return current_health > 0


func set_blocking(enabled: bool) -> void:
	blocking_active = enabled


func is_blocking() -> bool:
	return blocking_active


func _process_manual_path_movement() -> bool:
	if manual_path_index >= manual_path_points.size():
		return false

	var next_point := manual_path_points[manual_path_index]
	var to_next := next_point - global_position
	if to_next.length() <= 4.0:
		manual_path_index += 1
		if manual_path_index >= manual_path_points.size():
			velocity = Vector2.ZERO
			move_and_slide()
			return true
		next_point = manual_path_points[manual_path_index]
		to_next = next_point - global_position

	velocity = to_next.normalized() * move_speed
	_update_facing_from_velocity(velocity)
	move_and_slide()
	return true
