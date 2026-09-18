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
# How close the player must come before this enemy gives chase. 0 keeps the
# old behaviour (chase from anywhere); wolves in the big woods use a short
# range so each pack is its own fight. Taking a hit always provokes.
@export var aggro_range := 0.0
# Optional sprite sheets for a drawn body (see `scenes/wolf.tscn`). Both are
# grids of equal frames: `body_sheet_rows` facing rows (0 = away-right,
# 1 = away-left, 2 = toward-left, 3 = toward-right) and one column per frame.
# Leave `body_sheet_idle` empty to keep the procedural placeholder body.
@export var body_sheet_idle: Texture2D
@export var body_sheet_run: Texture2D
@export var body_sheet_columns_idle := 4
@export var body_sheet_columns_run := 8
@export var body_sheet_rows := 4
@export var body_animation_fps := 8.0
@export var attack_wind_up_duration := 0.2
@export var attack_strike_duration := 0.12
@export var attack_recovery_duration := 0.2
# Turn mode uses a slower, clearly telegraphed swing: the wind-up is long
# enough to read and the strike (= the counter window) is wide enough to hit
# on purpose. Realtime keeps the snappier values above.
@export var turn_attack_wind_up_duration := 0.55
@export var turn_attack_strike_duration := 0.18

const HIT_NUDGE_PX := 7.0
const DEATH_SECONDS := 0.42
# Frost Snare: the ring at the feet while rooted, and the popups.
const ROOT_COLOR := Color(0.62, 0.88, 1.0, 0.9)

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
var health_bar_ghost: Sprite2D
var hover_outline: Sprite2D
var counter_prompt: CounterPrompt
var _dying := false
# Turns of our own this enemy still spends unable to move (the mage's Frost
# Snare). It keeps its attack; it just goes nowhere.
var rooted_turns := 0
var root_ring: Sprite2D
var _aggroed := false
# Sheet animation state; only used when `body_sheet_idle` is set.
var _body_frame := 0
var _body_frame_time := 0.0
var _body_row := 2  # toward-left: facing the camera at rest
var _body_running := false


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
	_setup_body_sprite()
	_sprite_idle_local = sprite.position
	_setup_hover_outline()
	_setup_counter_prompt()
	_setup_root_ring()


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

	# Ambushers hold still until the player wanders close enough.
	if aggro_range > 0.0 and not _aggroed:
		if global_position.distance_to(_target.global_position) > aggro_range:
			velocity = Vector2.ZERO
			move_and_slide()
			return
		_aggroed = true

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
	if not is_alive():
		return
	_aggroed = true
	current_health = maxi(0, current_health - amount)
	_update_health_bar()
	_play_hit_feedback(amount)
	if current_health == 0:
		_die()


# Alias so the player's radial (spacebar) attack, which calls `take_damage`
# like crates do, lands on enemies too.
func take_damage(amount: int) -> void:
	receive_damage(amount)


func _play_hit_feedback(amount: int) -> void:
	CombatFx.flash(sprite)
	CombatFx.popup_damage(global_position + Vector2(0, -40), amount, CombatFx.COLOR_DAMAGE_DEALT)
	CombatFx.shake(3.0, 0.12)

	# Recoil away from whoever we're fighting. Skipped mid-swing so it never
	# fights the attack tween that owns sprite.position at that moment.
	if _attack_sequence_active:
		return
	var away := Vector2.RIGHT
	if _target != null and is_instance_valid(_target):
		away = (global_position - _target.global_position).normalized()
		if away.length() < 0.01:
			away = Vector2.RIGHT
	var nudge := Vector2(away.x * HIT_NUDGE_PX, away.y * HIT_NUDGE_PX * 0.6)
	var tween := create_tween()
	tween.tween_property(sprite, "position", _sprite_idle_local + nudge, 0.05) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(sprite, "position", _sprite_idle_local, 0.16) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


# Death is a short beat, not a pop: flash, topple, fade, then loot spills out
# of the corpse. `is_alive()` is already false from the first frame, so combat
# logic stops counting us while the animation plays.
func _die() -> void:
	if _dying:
		return
	_dying = true
	set_hover_highlighted(false)
	if counter_prompt != null:
		counter_prompt.hide_prompt()
	if root_ring != null:
		root_ring.visible = false
	collision_layer = 0
	collision_mask = 0
	navigation_agent.target_position = global_position
	velocity = Vector2.ZERO

	get_tree().call_group("player", "add_experience", experience_reward)
	CombatFx.popup_text(global_position + Vector2(0, -58), "+%d XP" % experience_reward, CombatFx.COLOR_XP, 18)
	CombatFx.shake(5.0, 0.18)

	var bar_root := get_node_or_null("HealthBarRoot") as Node2D
	if bar_root != null:
		bar_root.visible = false

	var topple_dir := 1.0
	if _target != null and is_instance_valid(_target) and _target.global_position.x > global_position.x:
		topple_dir = -1.0

	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(sprite, "self_modulate", Color(2.6, 2.6, 2.6, 1.0), 0.05)
	tween.tween_property(sprite, "rotation", topple_dir * 1.25, DEATH_SECONDS) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.tween_property(sprite, "position", _sprite_idle_local + Vector2(topple_dir * 6.0, 10.0), DEATH_SECONDS) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.tween_property(sprite, "scale", Vector2(1.05, 0.8), DEATH_SECONDS)
	tween.chain().tween_property(sprite, "modulate:a", 0.0, 0.16)
	await tween.finished

	if not is_instance_valid(self):
		return
	# Drop before freeing: LootDropper reads our position and parent, and
	# spawns the pickups as siblings so they outlive us.
	_drop_loot()
	queue_free()


func is_alive() -> bool:
	return current_health > 0


# --- Root (Frost Snare) --------------------------------------------------------

# Pins the enemy for `turns` of its own turns: it keeps its attack but loses
# its movement. Rooting an already rooted enemy keeps the longer of the two.
func apply_root(turns: int) -> void:
	if turns <= 0 or not is_alive():
		return
	rooted_turns = maxi(rooted_turns, turns)
	_update_root_visual()
	CombatFx.popup_text(global_position + Vector2(0, -56), "ROOTED", ROOT_COLOR, 16)
	CombatFx.flash(sprite, Color(0.9, 1.5, 2.2, 1.0), 0.25)
	CombatFx.ring_burst(self, global_position + Vector2(0, 2), ROOT_COLOR, 6.0, 22.0, 0.3)


func is_rooted() -> bool:
	return rooted_turns > 0


func _setup_root_ring() -> void:
	root_ring = Sprite2D.new()
	root_ring.name = "RootRing"
	root_ring.texture = CombatFx.create_ring_texture(40, 11.0, 15.0, ROOT_COLOR)
	root_ring.position = Vector2(0, 2)
	root_ring.scale = Vector2(1.0, 0.55)
	root_ring.z_index = sprite.z_index - 1
	root_ring.visible = false
	add_child(root_ring)


func _update_root_visual() -> void:
	if root_ring == null:
		return
	var show := rooted_turns > 0
	if show and not root_ring.visible:
		root_ring.visible = true
		root_ring.modulate.a = 0.0
		var tween := create_tween()
		tween.tween_property(root_ring, "modulate:a", 1.0, 0.18)
	elif not show and root_ring.visible:
		var tween := create_tween()
		tween.tween_property(root_ring, "modulate:a", 0.0, 0.2)
		tween.tween_callback(func() -> void:
			if root_ring != null and rooted_turns <= 0:
				root_ring.visible = false
		)


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
	var wind_up := turn_attack_wind_up_duration if in_turn_based_combat else attack_wind_up_duration
	var strike := turn_attack_strike_duration if in_turn_based_combat else attack_strike_duration
	var can_be_countered := target.has_method("begin_enemy_counter_windup")
	if can_be_countered:
		target.call("begin_enemy_counter_windup", self, attack_damage)
		if counter_prompt != null:
			# Tell the player what the press will do as whoever is in control.
			if target.has_method("get_reaction_hint"):
				var hint: Dictionary = target.call("get_reaction_hint")
				counter_prompt.set_hint(String(hint.get("text", "")), hint.get("color", CounterPrompt.COLOR_TARGET))
			counter_prompt.start_windup(wind_up)

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
	tween.tween_property(sprite, "position", idle_pos + Vector2(-to_target.x * 6.0, -to_target.y * 4.0 + 2.0), wind_up).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(sprite, "scale", Vector2(0.86, 1.12), wind_up)
	tween.tween_property(sprite, "modulate", Color(0.52, 0.22, 0.22, 1.0), wind_up)
	await tween.finished

	if not is_instance_valid(self) or not is_alive():
		_cancel_counter_on_target(target)
		_hide_counter_prompt()
		_attack_sequence_active = false
		return
	if not is_instance_valid(target) or global_position.distance_to(target.global_position) > attack_range * 1.2:
		_cancel_counter_on_target(target)
		_hide_counter_prompt()
		_reset_attack_sprite_pose(idle_pos, idle_scale)
		_attack_sequence_active = false
		if not in_turn_based_combat:
			_attack_cooldown_left = attack_cooldown * 0.35
		return

	# 2) Strike — counter window; damage resolves after the lunge
	if target.has_method("begin_enemy_counter_strike"):
		target.call("begin_enemy_counter_strike")
	if can_be_countered and counter_prompt != null:
		counter_prompt.start_strike(strike)

	tween = create_tween()
	tween.set_parallel(true)
	tween.tween_property(sprite, "position", idle_pos + lunge, strike).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.tween_property(sprite, "scale", Vector2(1.14, 0.9), strike)
	tween.tween_property(sprite, "modulate", Color(1.0, 0.48, 0.48, 1.0), strike * 0.45)
	await tween.finished

	if not is_instance_valid(self):
		_cancel_counter_on_target(target)
		_attack_sequence_active = false
		return

	if is_instance_valid(target):
		if target.has_method("resolve_enemy_attack"):
			var countered: bool = bool(target.call("resolve_enemy_attack", self, attack_damage))
			if counter_prompt != null:
				counter_prompt.show_result(countered)
		elif target.has_method("receive_damage"):
			target.call("receive_damage", attack_damage)
			_hide_counter_prompt()
	else:
		_hide_counter_prompt()

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


func _hide_counter_prompt() -> void:
	if counter_prompt != null:
		counter_prompt.hide_prompt()


func _setup_counter_prompt() -> void:
	counter_prompt = CounterPrompt.new()
	counter_prompt.name = "CounterPrompt"
	counter_prompt.position = _sprite_idle_local
	counter_prompt.z_index = sprite.z_index + 3
	add_child(counter_prompt)


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

	# Pale bar under the fill that trails on damage so the lost chunk reads.
	health_bar_ghost = root.get_node_or_null("Ghost") as Sprite2D
	if health_bar_ghost == null:
		health_bar_ghost = Sprite2D.new()
		health_bar_ghost.name = "Ghost"
		health_bar_ghost.centered = false
		root.add_child(health_bar_ghost)
	health_bar_ghost.texture = _create_solid_texture(Vector2i(28, 4), Color(1.0, 0.78, 0.6, 0.9))

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
	if not is_inside_tree():
		health_bar_fill.scale = Vector2(ratio, 1.0)
		if health_bar_ghost != null:
			health_bar_ghost.scale = Vector2(ratio, 1.0)
		return
	CombatFx.animate_bar(health_bar_fill, health_bar_ghost, ratio)


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


# --- Body sprite -----------------------------------------------------------

func _setup_body_sprite() -> void:
	if body_sheet_idle == null:
		sprite.texture = _create_enemy_texture()
		return
	_apply_body_sheet(body_sheet_idle, body_sheet_columns_idle)


func _process(delta: float) -> void:
	if body_sheet_idle == null or _dying:
		return
	_update_body_animation(delta)


func _update_body_animation(delta: float) -> void:
	var moving := velocity.length_squared() > 25.0
	if moving:
		_body_row = _body_row_for_direction(velocity)
	elif _target != null and is_instance_valid(_target) and (_aggroed or in_turn_based_combat):
		# Standing still mid-fight: keep eyes on the player.
		_body_row = _body_row_for_direction(_target.global_position - global_position)

	var wants_run := moving and body_sheet_run != null
	if wants_run != _body_running:
		_body_running = wants_run
		_body_frame = 0
		_body_frame_time = 0.0

	_body_frame_time += delta
	var frame_seconds := 1.0 / maxf(body_animation_fps, 0.1)
	while _body_frame_time >= frame_seconds:
		_body_frame_time -= frame_seconds
		_body_frame += 1

	if _body_running:
		_apply_body_sheet(body_sheet_run, body_sheet_columns_run)
	else:
		_apply_body_sheet(body_sheet_idle, body_sheet_columns_idle)


func _apply_body_sheet(sheet: Texture2D, columns: int) -> void:
	sprite.texture = sheet
	sprite.hframes = maxi(1, columns)
	sprite.vframes = maxi(1, body_sheet_rows)
	var row := clampi(_body_row, 0, sprite.vframes - 1)
	sprite.frame = row * sprite.hframes + (_body_frame % sprite.hframes)


func _body_row_for_direction(direction: Vector2) -> int:
	# Screen-up is away from the camera. Rows: 0 away-right, 1 away-left,
	# 2 toward-left, 3 toward-right — the order the critter sheets use.
	if direction.y < 0.0:
		return 0 if direction.x >= 0.0 else 1
	return 3 if direction.x >= 0.0 else 2


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
		rooted_turns = 0
		_update_root_visual()


func start_turn(max_move_meters: float = 6.0) -> void:
	turn_active = true
	# A rooted enemy keeps its attack but goes nowhere this turn.
	turn_remaining_move_meters = 0.0 if rooted_turns > 0 else maxf(0.0, max_move_meters)
	turn_attack_available = true
	if rooted_turns > 0:
		CombatFx.popup_text(global_position + Vector2(0, -48), "Rooted", ROOT_COLOR, 14)


func end_turn() -> void:
	turn_active = false
	turn_remaining_move_meters = 0.0
	turn_attack_available = false
	# The root is spent by the turn it cost; the ice melts once that turn ends.
	if rooted_turns > 0:
		rooted_turns -= 1
		_update_root_visual()


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
