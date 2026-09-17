extends Node

# Autoload `CombatFx`: the shared "game feel" layer for combat. Floating damage
# numbers, turn banners, camera shake, hit-stop and hit flashes all live here
# so player.gd, enemy.gd and main.gd call one-liners instead of each growing
# its own tween soup. Everything is code-built and sits on its own CanvasLayer,
# so it works in every level scene without any per-level wiring.
#
# Tuning knobs are the constants at the top. Set SHAKE_SCALE or HIT_STOP_SCALE
# to 0.0 to switch that effect off entirely.

# Below the turn HUD (5) and the two inventory screens (6, 7) so popups never
# sit on top of a menu, above the world.
const LAYER := 4

# Global multipliers for the two "physical" effects.
const SHAKE_SCALE := 1.0
const HIT_STOP_SCALE := 1.0

# Floating text.
const POPUP_RISE_PX := 46.0
const POPUP_DURATION := 0.95
const POPUP_FONT_SIZE := 24
const POPUP_JITTER_PX := 10.0

# Banner (YOUR TURN / ENEMY TURN / ...).
const BANNER_FONT_SIZE := 46
const BANNER_IN_SECONDS := 0.18
const BANNER_OUT_SECONDS := 0.28
const BANNER_Y_FRACTION := 0.30

# Colours used by callers so the palette stays in one place.
const COLOR_DAMAGE_DEALT := Color(1.0, 0.93, 0.62, 1.0)
const COLOR_DAMAGE_TAKEN := Color(1.0, 0.36, 0.36, 1.0)
const COLOR_BLOCK := Color(0.62, 0.82, 1.0, 1.0)
const COLOR_COUNTER := Color(1.0, 0.84, 0.25, 1.0)
const COLOR_WARNING := Color(1.0, 0.62, 0.42, 1.0)
const COLOR_XP := Color(0.72, 0.62, 1.0, 1.0)
const COLOR_HEAL := Color(0.55, 0.95, 0.6, 1.0)
const COLOR_PLAYER_TURN := Color(0.66, 0.9, 0.7, 1.0)
const COLOR_ENEMY_TURN := Color(0.95, 0.52, 0.5, 1.0)
const COLOR_COMBAT := Color(1.0, 0.8, 0.45, 1.0)

var _layer: CanvasLayer
var _popups: Array[Dictionary] = []
var _banner: Label
var _banner_tween: Tween

var _shake_strength := 0.0
var _shake_time_left := 0.0
var _shake_duration := 0.0
var _shaken_camera: Camera2D

var _hit_stop_until_msec := 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_layer = CanvasLayer.new()
	_layer.name = "CombatFxLayer"
	_layer.layer = LAYER
	add_child(_layer)


func _process(delta: float) -> void:
	_update_popups(delta)
	_update_shake(delta)
	_update_hit_stop()


# --- Floating text ------------------------------------------------------------

# Spawns a short-lived label anchored to `world_position` that drifts up and
# fades. It is projected through the current camera every frame, so it stays
# crisp at any zoom and follows camera shake like everything else on screen.
func popup_text(world_position: Vector2, text: String, color: Color = Color.WHITE,
		font_size: int = POPUP_FONT_SIZE) -> void:
	if _layer == null:
		return
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_outline_color", Color(0.05, 0.03, 0.02, 0.95))
	label.add_theme_constant_override("outline_size", 6)
	label.pivot_offset = Vector2.ZERO
	_layer.add_child(label)

	_popups.append({
		"label": label,
		"world": world_position,
		"jitter": Vector2(randf_range(-POPUP_JITTER_PX, POPUP_JITTER_PX), 0.0),
		"t": 0.0,
	})
	_place_popup(_popups[_popups.size() - 1])


func popup_damage(world_position: Vector2, amount: int, color: Color = COLOR_DAMAGE_DEALT) -> void:
	popup_text(world_position, str(amount), color)


func _update_popups(delta: float) -> void:
	var finished: Array[int] = []
	for i in range(_popups.size()):
		var entry := _popups[i]
		var label := entry["label"] as Label
		if label == null or not is_instance_valid(label):
			finished.append(i)
			continue
		var t := float(entry["t"]) + delta
		entry["t"] = t
		if t >= POPUP_DURATION:
			label.queue_free()
			finished.append(i)
			continue
		_place_popup(entry)
		var progress := t / POPUP_DURATION
		var alpha := 1.0 if progress < 0.55 else 1.0 - (progress - 0.55) / 0.45
		label.modulate.a = clampf(alpha, 0.0, 1.0)
		# Quick punch in, then settle to 1.0.
		var punch := 1.0 + 0.45 * maxf(0.0, 1.0 - progress * 6.0)
		label.scale = Vector2(punch, punch)

	for i in range(finished.size() - 1, -1, -1):
		_popups.remove_at(finished[i])


func _place_popup(entry: Dictionary) -> void:
	var label := entry["label"] as Label
	var t := float(entry["t"])
	var progress := clampf(t / POPUP_DURATION, 0.0, 1.0)
	var rise := POPUP_RISE_PX * (1.0 - pow(1.0 - progress, 2.0))
	var screen := _world_to_screen(entry["world"] as Vector2)
	var size := label.get_combined_minimum_size()
	label.pivot_offset = size * 0.5
	label.position = screen + (entry["jitter"] as Vector2) - size * 0.5 - Vector2(0.0, rise)


func _world_to_screen(world_position: Vector2) -> Vector2:
	var viewport := get_viewport()
	if viewport == null:
		return world_position
	return viewport.get_canvas_transform() * world_position


# --- Banner -------------------------------------------------------------------

# Big centred text for phase changes. A new banner replaces the one already on
# screen so rapid transitions (combat start immediately followed by "your
# turn") never stack.
func announce(text: String, color: Color = Color.WHITE, hold_seconds: float = 0.8) -> void:
	if _layer == null:
		return
	if _banner_tween != null and _banner_tween.is_valid():
		_banner_tween.kill()
	if _banner != null and is_instance_valid(_banner):
		_banner.queue_free()

	_banner = Label.new()
	_banner.text = text
	_banner.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_banner.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_banner.add_theme_font_size_override("font_size", BANNER_FONT_SIZE)
	_banner.add_theme_color_override("font_color", color)
	_banner.add_theme_color_override("font_outline_color", Color(0.05, 0.03, 0.02, 0.95))
	_banner.add_theme_constant_override("outline_size", 10)
	_banner.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_banner.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_layer.add_child(_banner)

	var viewport_size := get_viewport().get_visible_rect().size
	var size := _banner.get_combined_minimum_size()
	_banner.pivot_offset = size * 0.5
	_banner.position = Vector2(viewport_size.x * 0.5, viewport_size.y * BANNER_Y_FRACTION) - size * 0.5
	_banner.scale = Vector2(1.35, 1.35)
	_banner.modulate.a = 0.0

	var banner := _banner
	_banner_tween = create_tween()
	_banner_tween.set_parallel(true)
	_banner_tween.tween_property(banner, "scale", Vector2.ONE, BANNER_IN_SECONDS) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_banner_tween.tween_property(banner, "modulate:a", 1.0, BANNER_IN_SECONDS * 0.6)
	_banner_tween.chain().tween_interval(hold_seconds)
	_banner_tween.chain().tween_property(banner, "modulate:a", 0.0, BANNER_OUT_SECONDS)
	_banner_tween.parallel().tween_property(banner, "position:y", banner.position.y - 24.0, BANNER_OUT_SECONDS) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	_banner_tween.chain().tween_callback(banner.queue_free)


# --- Camera shake -------------------------------------------------------------

# Nudges the current Camera2D's `offset` with a decaying random jitter. Only
# `offset` is touched, so a camera that lerps `global_position` (main.gd) is
# unaffected and the two compose.
func shake(strength: float = 5.0, duration: float = 0.16) -> void:
	strength *= SHAKE_SCALE
	if strength <= 0.0 or duration <= 0.0:
		return
	var camera := get_viewport().get_camera_2d()
	if camera == null:
		return
	if _shaken_camera != null and _shaken_camera != camera and is_instance_valid(_shaken_camera):
		_shaken_camera.offset = Vector2.ZERO
	_shaken_camera = camera
	_shake_strength = maxf(_shake_strength, strength)
	_shake_time_left = maxf(_shake_time_left, duration)
	_shake_duration = maxf(_shake_duration, duration)


func _update_shake(delta: float) -> void:
	if _shake_time_left <= 0.0:
		return
	if _shaken_camera == null or not is_instance_valid(_shaken_camera):
		_shake_time_left = 0.0
		_shake_strength = 0.0
		return
	_shake_time_left -= delta
	if _shake_time_left <= 0.0:
		_shaken_camera.offset = Vector2.ZERO
		_shake_strength = 0.0
		_shake_duration = 0.0
		return
	var falloff := _shake_time_left / maxf(_shake_duration, 0.001)
	var amount := _shake_strength * falloff * falloff
	_shaken_camera.offset = Vector2(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0)) * amount


# --- Hit-stop -----------------------------------------------------------------

# A very short global slow-down on impact. Measured on the wall clock so it
# always releases, and stacking hits only extend it rather than deepen it.
func hit_stop(duration: float = 0.06, time_scale: float = 0.2) -> void:
	if HIT_STOP_SCALE <= 0.0 or duration <= 0.0:
		return
	var until := Time.get_ticks_msec() + int(duration * HIT_STOP_SCALE * 1000.0)
	_hit_stop_until_msec = maxi(_hit_stop_until_msec, until)
	Engine.time_scale = minf(Engine.time_scale, time_scale)


func _update_hit_stop() -> void:
	if _hit_stop_until_msec == 0:
		return
	if Time.get_ticks_msec() >= _hit_stop_until_msec:
		_hit_stop_until_msec = 0
		Engine.time_scale = 1.0


# --- Sprite helpers -----------------------------------------------------------

# Flashes a sprite via `self_modulate` and eases it back. Using self_modulate
# (not modulate) means it never fights the attack tweens and archetype
# animations that key `modulate` on the same node.
func flash(item: CanvasItem, color: Color = Color(2.6, 2.6, 2.6, 1.0), duration: float = 0.16) -> void:
	if item == null or not is_instance_valid(item):
		return
	item.self_modulate = color
	var tween := item.create_tween()
	tween.tween_property(item, "self_modulate", Color.WHITE, duration) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)


# Animates a two-part health bar: `fill` snaps quickly to the new ratio while
# `ghost` (a pale bar drawn underneath) trails behind so the chunk that was
# just lost stays readable for a moment. Heals move both at once.
func animate_bar(fill: Sprite2D, ghost: Sprite2D, ratio: float) -> void:
	ratio = clampf(ratio, 0.0, 1.0)
	if fill == null or not is_instance_valid(fill):
		return
	var fill_tween := fill.create_tween()
	fill_tween.tween_property(fill, "scale:x", ratio, 0.12).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	if ghost == null or not is_instance_valid(ghost):
		return
	if ratio >= ghost.scale.x:
		ghost.scale.x = ratio
		return
	var ghost_tween := ghost.create_tween()
	ghost_tween.tween_interval(0.28)
	ghost_tween.tween_property(ghost, "scale:x", ratio, 0.32).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN_OUT)


# Ring texture for auras and range markers. Soft-edged so it reads at the
# game's zoom without looking like a hard vector circle.
static func create_ring_texture(size: int, inner_radius: float, outer_radius: float, color: Color) -> Texture2D:
	var image := Image.create(size, size, false, Image.FORMAT_RGBA8)
	image.fill(Color(0, 0, 0, 0))
	var center := Vector2(float(size) * 0.5, float(size) * 0.5)
	var feather := 1.2
	for y in range(size):
		for x in range(size):
			var r := Vector2(float(x) + 0.5, float(y) + 0.5).distance_to(center)
			var a := 0.0
			if r >= inner_radius - feather and r <= outer_radius + feather:
				var inner_t := clampf((r - (inner_radius - feather)) / feather, 0.0, 1.0)
				var outer_t := clampf(((outer_radius + feather) - r) / feather, 0.0, 1.0)
				a = minf(inner_t, outer_t)
			if a > 0.0:
				image.set_pixel(x, y, Color(color.r, color.g, color.b, color.a * a))
	return ImageTexture.create_from_image(image)


# --- World-space bursts -------------------------------------------------------

# One shared white ring; bursts tint it through `modulate`, so a new burst
# colour costs nothing.
const BURST_RING_SIZE := 64
const BURST_RING_INNER := 25.0
const BURST_RING_OUTER := 30.0
var _burst_ring_texture: Texture2D


# A ring that expands and fades at a world position: soul shifts, spell
# impacts, a root landing. It lives under `parent` (the actor or the level),
# not on the FX CanvasLayer, so it sits in the world and flattens like the
# other floor rings. `flatten` is the y scale relative to x; 1.0 is a true
# circle for effects drawn on the body rather than the floor.
func ring_burst(parent: Node, world_position: Vector2, color: Color,
		start_radius: float = 8.0, end_radius: float = 30.0,
		duration: float = 0.35, flatten: float = 0.6) -> void:
	if parent == null or not is_instance_valid(parent):
		return
	if _burst_ring_texture == null:
		_burst_ring_texture = create_ring_texture(BURST_RING_SIZE, BURST_RING_INNER, BURST_RING_OUTER, Color.WHITE)

	var ring := Sprite2D.new()
	ring.texture = _burst_ring_texture
	ring.modulate = color
	ring.z_index = 20
	parent.add_child(ring)
	ring.global_position = world_position

	var texture_radius := (BURST_RING_INNER + BURST_RING_OUTER) * 0.5
	var start_scale := start_radius / texture_radius
	var end_scale := end_radius / texture_radius
	ring.scale = Vector2(start_scale, start_scale * flatten)

	var tween := ring.create_tween()
	tween.set_parallel(true)
	tween.tween_property(ring, "scale", Vector2(end_scale, end_scale * flatten), duration) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(ring, "modulate:a", 0.0, duration) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.chain().tween_callback(ring.queue_free)
