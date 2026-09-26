class_name BossEnemy3D
extends Enemy3D

## The Grave Warden (`scenes/3d/enemies/grave_warden_3d.tscn`), the boss.
##
## Its turn is chosen from its state, never rolled:
##
## - Grave Slam. The warden marks a danger ring (SLAM_RADIUS_M, red, pulsing)
##   at the player's position and shouts `GRAVE SLAM`. At the START of its next
##   turn everyone still inside takes SLAM_DAMAGE (the player through
##   `take_damage`, other enemies through `take_environment_damage`), so the
##   player has one turn to step out. A stun on the warden breaks the slam.
## - Melee through the normal counter window when the player is within reach.
## - Phase 1 alternates: on its even turns (the first included) it marks a slam
##   when none is pending, on odd turns it bites when in reach; a player out of
##   reach always gets a slam. At <= PHASE_TWO_HEALTH_RATIO health, once, phase
##   2 begins: `THE DEAD RISE`, two wolves climb out beside it (registered with
##   the coordinator), and from then on it marks a slam and bites in the same
##   turn when it can.
## - A screen-top bar (name, health, phase) shows while it is in turn mode and
##   within BAR_SHOW_DISTANCE_M of the player; it hides on death.
## - Death is a longer beat, pays EXPERIENCE (the export) and always drops the
##   authored loot (filled from ItemFactory when the scene leaves it empty).
##
## docs/enemy-roster.md.

## The pulsing danger ring and its damage.
@export var slam_radius_m := 2.5
@export var slam_damage := 26
## Seconds the telegraph beat lasts in its own turn.
@export var slam_telegraph_seconds := 0.7
## Health share at or below which phase 2 starts.
@export_range(0.05, 0.95) var phase_two_health_ratio := 0.5
## Wolves raised at phase 2.
@export var summon_scene: PackedScene = preload("res://scenes/3d/wolf_3d.tscn")
@export var summon_count := 2
## How far to the side of the warden the summons stand.
@export var summon_offset_m := 1.9
## The boss bar shows while the player is at most this far away.
@export var bar_show_distance_m := 16.0
## Off when a HUD draws its own boss bar from `get_display_name()`,
## `health` / `max_health` and `get_phase()`.
@export var show_boss_bar := true

const SLAM_COLOR := Color(1.0, 0.18, 0.12, 0.95)
const SLAM_FILL_COLOR := Color(1.0, 0.12, 0.08, 0.2)
const SLAM_PULSE_SECONDS := 0.45
const SLAM_PULSE_SCALE := 1.08
const SLAM_TEXT := "GRAVE SLAM"
const SLAM_TEXT_COLOR := Color(1.0, 0.4, 0.3, 1.0)
const SLAM_WIND_UP_TINT := Color(0.5, 0.08, 0.05, 1.0)
const SLAM_POPUP_OFFSET := Vector3(0.0, 3.8, 0.0)
const PHASE_TWO_TEXT := "THE DEAD RISE"
const PHASE_TWO_COLOR := Color(0.55, 1.0, 0.7, 1.0)
## The emissive accent: the visor and the blade glow grave-green.
const ACCENT_EMISSION := Color(0.35, 1.0, 0.6, 1.0)
const ACCENT_EMISSION_ENERGY := 2.2
const ACCENT_MATERIAL_KEYS: Array[String] = ["Visor", "Steel"]
const DEATH_TOPPLE_SECONDS := 1.1
const DEATH_TEXT := "THE WARDEN FALLS"

## Screen-top bar layout (pixels; the bar is centred on the window's top edge).
## Same CanvasLayer as the overhead bars, under the popups (4) and the counter
## prompt (5).
const BAR_CANVAS_LAYER := 3
const BAR_WIDTH_PX := 620.0
const BAR_HEIGHT_PX := 18.0
const BAR_TOP_PX := 24.0
const BAR_BACK_COLOR := Color(0.08, 0.07, 0.07, 0.9)
const BAR_FILL_COLOR := Color(0.78, 0.16, 0.14, 1.0)
const BAR_NAME_COLOR := Color(1.0, 0.9, 0.75, 1.0)
const BAR_PHASE_COLOR := Color(0.7, 0.95, 0.75, 1.0)

var _phase := 1
var _turns_taken := 0
var _slam_pending := false
var _slam_center := Vector3.ZERO
var _slam_marker: Node3D = null
var _slam_ring: RangeRing3D = null
var _slam_pulse: Tween = null
var _summons: Array[Node3D] = []
var _slams_landed := 0

var _bar_layer: CanvasLayer = null
var _bar_root: Control = null
var _bar_fill: ColorRect = null
var _bar_name: Label = null
var _bar_phase: Label = null


func _ready() -> void:
	super()
	_apply_accent()
	_setup_slam_marker()
	_setup_boss_bar()
	if loot_items.is_empty():
		var items: Array[Item] = [ItemFactory.create_amulet(), ItemFactory.create_ring(),
			ItemFactory.create_health_potion(), ItemFactory.create_health_potion()]
		loot_items = items


func _process(delta: float) -> void:
	super(delta)
	_update_boss_bar()


# --- Queries --------------------------------------------------------------------

## 1 until the health threshold, then 2.
func get_phase() -> int:
	return _phase


func has_pending_slam() -> bool:
	return _slam_pending


## Centre of the pending slam ring (meaningless without one).
func get_slam_center() -> Vector3:
	return _slam_center


func get_slams_landed() -> int:
	return _slams_landed


## The wolves raised at phase 2 (freed ones drop out).
func get_summons() -> Array[Node3D]:
	var alive: Array[Node3D] = []
	for summon in _summons:
		if summon != null and is_instance_valid(summon):
			alive.append(summon)
	return alive


func is_boss_bar_visible() -> bool:
	return _bar_root != null and _bar_root.visible


# --- Turn ------------------------------------------------------------------------

## Statuses first (Enemy3D), then the pending slam lands on whoever is still in
## the ring. A stun breaks it instead.
func start_turn(max_move_meters: float = 6.0) -> void:
	super(max_move_meters)
	if not _slam_pending:
		return
	if not is_alive() or is_skipping_turn():
		_clear_slam()
		return
	_resolve_slam()


func end_turn() -> void:
	var was_own_turn := is_turn_active()
	super()
	if was_own_turn:
		_turns_taken += 1


## The warden's action, picked from its state (see the class comment). Returns
## true when it did something (a slam telegraph, a bite, or both).
func try_attack(target: Node3D = null) -> bool:
	if target != null:
		_target = target
	if not is_in_turn_based_combat():
		return await super(target)
	if _attack_sequence_active or not is_alive() or not is_turn_active() or not can_turn_attack():
		return false
	var victim := _live_target()
	if victim == null:
		return false
	var in_reach := GroundMath.ground_distance(global_position, victim.global_position) \
		<= attack_range + ATTACK_RANGE_TOLERANCE
	var slam_now := false
	var bite_now := false
	if _phase >= 2:
		slam_now = not _slam_pending
		bite_now = in_reach
	elif not in_reach:
		slam_now = not _slam_pending
	elif _turns_taken % 2 == 0 and not _slam_pending:
		slam_now = true
	else:
		bite_now = true

	var acted := false
	if slam_now:
		await _telegraph_slam(victim)
		if not is_instance_valid(self) or not is_alive():
			return true
		acted = true
	if bite_now:
		var bit: bool = await super(victim)
		acted = acted or bit
	_turn_attack_available = false
	return acted


# --- Grave Slam ------------------------------------------------------------------

func _setup_slam_marker() -> void:
	_slam_marker = Node3D.new()
	_slam_marker.name = "SlamMarker"
	_slam_marker.top_level = true
	add_child(_slam_marker)
	_slam_ring = RangeRing3D.new()
	_slam_ring.name = "SlamRing"
	_slam_marker.add_child(_slam_ring)
	var disc := MeshInstance3D.new()
	disc.name = "SlamDisc"
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = slam_radius_m
	cylinder.bottom_radius = slam_radius_m
	cylinder.height = 0.01
	cylinder.radial_segments = 48
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.no_depth_test = true
	material.albedo_color = SLAM_FILL_COLOR
	cylinder.material = material
	disc.mesh = cylinder
	disc.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	disc.position = Vector3(0.0, 0.015, 0.0)
	_slam_marker.add_child(disc)
	_slam_ring.hide_ring()
	_slam_marker.visible = false


## Marks the ring at the target's feet with a raised-weapon beat.
func _telegraph_slam(victim: Node3D) -> void:
	_slam_center = GroundMath.flatten(victim.global_position)
	_slam_pending = true
	face_toward(_slam_center)
	_slam_marker.global_position = _slam_center
	_slam_marker.visible = true
	_slam_ring.show_ring(slam_radius_m, SLAM_COLOR)
	_start_slam_pulse()
	CombatFx.popup_text(global_position + SLAM_POPUP_OFFSET, SLAM_TEXT, SLAM_TEXT_COLOR, 24)
	CombatFx.shake(3.0, 0.15)
	_flash_model(SLAM_WIND_UP_TINT, slam_telegraph_seconds)
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(_model, "scale", _model_idle_scale * Vector3(0.96, 1.1, 0.96), slam_telegraph_seconds * 0.5) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.chain().tween_property(_model, "scale", _model_idle_scale, slam_telegraph_seconds * 0.5)
	await tween.finished


func _start_slam_pulse() -> void:
	if _slam_pulse != null and _slam_pulse.is_valid():
		_slam_pulse.kill()
	_slam_marker.scale = Vector3.ONE
	_slam_pulse = _slam_marker.create_tween()
	_slam_pulse.set_loops()
	_slam_pulse.tween_property(_slam_marker, "scale", Vector3(SLAM_PULSE_SCALE, 1.0, SLAM_PULSE_SCALE), SLAM_PULSE_SECONDS) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_slam_pulse.tween_property(_slam_marker, "scale", Vector3.ONE, SLAM_PULSE_SECONDS) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)


## The slam lands: everyone inside the ring takes `slam_damage`.
func _resolve_slam() -> void:
	var center := _slam_center
	_clear_slam()
	_slams_landed += 1
	CombatFx.shake(9.0, 0.3)
	# The orthographic camera shows about 64 px per metre at its default size.
	CombatFx.ring_burst(self, center + Vector3(0.0, 0.05, 0.0), SLAM_COLOR,
		12.0 * FX_SCREEN_SCALE, slam_radius_m * 64.0, 0.35)
	CombatFx.popup_text(center + Vector3(0.0, 1.2, 0.0), SLAM_TEXT, SLAM_TEXT_COLOR, 22)
	for player_node in get_tree().get_nodes_in_group("player"):
		var body := player_node as Node3D
		if body == null or not _inside_slam(body, center):
			continue
		if body.has_method("is_alive") and not bool(body.call("is_alive")):
			continue
		if body.has_method("take_damage"):
			body.call("take_damage", slam_damage)
	for enemy_node in get_tree().get_nodes_in_group("enemies"):
		var other := enemy_node as Node3D
		if other == null or other == self or not _inside_slam(other, center):
			continue
		if other.has_method("is_alive") and not bool(other.call("is_alive")):
			continue
		if other.has_method("take_environment_damage"):
			other.call("take_environment_damage", slam_damage)
		elif other.has_method("receive_damage"):
			other.call("receive_damage", slam_damage)


func _inside_slam(body: Node3D, center: Vector3) -> bool:
	return GroundMath.ground_distance(body.global_position, center) <= slam_radius_m


func _clear_slam() -> void:
	_slam_pending = false
	if _slam_pulse != null and _slam_pulse.is_valid():
		_slam_pulse.kill()
	_slam_pulse = null
	if _slam_marker != null:
		_slam_marker.visible = false
		_slam_marker.scale = Vector3.ONE
	if _slam_ring != null:
		_slam_ring.hide_ring()


## A fight that ends takes the pending slam with it.
func set_turn_based_combat(enabled: bool) -> void:
	super(enabled)
	if not enabled:
		_clear_slam()


# --- Phase 2 ------------------------------------------------------------------------

func flash_hit() -> void:
	super()
	if _phase == 1 and is_alive() and health > 0 and max_health > 0 \
			and float(health) <= float(max_health) * phase_two_health_ratio:
		_enter_phase_two()


## Once: the popup, the summons, and the combined slam-and-bite turns.
func _enter_phase_two() -> void:
	if _phase >= 2:
		return
	_phase = 2
	CombatFx.popup_text(global_position + SLAM_POPUP_OFFSET, PHASE_TWO_TEXT, PHASE_TWO_COLOR, 26)
	CombatFx.shake(7.0, 0.3)
	_flash_model(Color(1.2, 2.2, 1.4, 1.0), 0.35)
	_summon_wolves()
	_update_boss_bar()


## Raises `summon_count` wolves beside the warden as its siblings, wired the
## way docs/gameplay-expansion.md section 2 asks: `snap_to`, group `enemies`,
## the player as target, turn mode when a fight runs, then
## `register_spawned_enemy` on the coordinator.
func _summon_wolves() -> void:
	var holder := get_parent()
	if holder == null or summon_scene == null:
		return
	var victim := _live_target()
	if victim == null:
		victim = get_tree().get_first_node_in_group("player") as Node3D
	var side := GroundMath.ground_direction(Vector3.ZERO, global_transform.basis.x)
	if side == Vector3.ZERO:
		side = Vector3.RIGHT
	for i in range(summon_count):
		var wolf := summon_scene.instantiate() as Node3D
		if wolf == null:
			continue
		wolf.name = "%s_Risen%d" % [name, i + 1]
		holder.add_child(wolf)
		var side_sign := 1.0 if i % 2 == 0 else -1.0
		var ring := 1.0 + floorf(float(i) * 0.5) * 0.8
		var spot := GroundMath.flatten(global_position) + side * side_sign * summon_offset_m * ring
		spot = _clamp_to_navmesh(spot, summon_offset_m * ring + 1.0)
		if wolf.has_method("snap_to"):
			wolf.call("snap_to", spot)
		else:
			wolf.global_position = spot
		if not wolf.is_in_group("enemies"):
			wolf.add_to_group("enemies")
		if victim != null and wolf.has_method("set_target"):
			wolf.call("set_target", victim)
		if is_in_turn_based_combat() and wolf.has_method("set_turn_based_combat"):
			wolf.call("set_turn_based_combat", true)
		if wolf.has_method("alert"):
			wolf.call("alert")
		CombatFx.ring_burst(self, spot + Vector3(0.0, 0.05, 0.0), PHASE_TWO_COLOR,
			6.0 * FX_SCREEN_SCALE, 30.0 * FX_SCREEN_SCALE, 0.4)
		_summons.append(wolf)
		get_tree().call_group("level_coordinator", "register_spawned_enemy", wolf)


# --- Look ----------------------------------------------------------------------------

## The emissive accent: every visor and steel surface glows grave-green on top
## of the dark tint (materials are the per-instance copies `model_tint` made,
## or fresh copies when there is no tint).
func _apply_accent() -> void:
	for mesh in get_model_meshes():
		if mesh == null or mesh.mesh == null:
			continue
		for surface in range(mesh.mesh.get_surface_count()):
			var material := mesh.get_active_material(surface) as BaseMaterial3D
			if material == null or not _is_accent_material(material):
				continue
			var glowing := material
			if mesh.get_surface_override_material(surface) != material:
				glowing = material.duplicate() as BaseMaterial3D
				mesh.set_surface_override_material(surface, glowing)
			glowing.emission_enabled = true
			glowing.emission = ACCENT_EMISSION
			glowing.emission_energy_multiplier = ACCENT_EMISSION_ENERGY


func _is_accent_material(material: Material) -> bool:
	for key in ACCENT_MATERIAL_KEYS:
		if material.resource_name.contains(key):
			return true
	return false


# --- Boss bar -----------------------------------------------------------------------

func _setup_boss_bar() -> void:
	_bar_layer = CanvasLayer.new()
	_bar_layer.name = "BossBarLayer"
	_bar_layer.layer = BAR_CANVAS_LAYER
	add_child(_bar_layer)

	_bar_root = Control.new()
	_bar_root.name = "BossBar"
	_bar_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bar_root.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_bar_root.custom_minimum_size = Vector2(BAR_WIDTH_PX, 64.0)
	_bar_root.size = Vector2(BAR_WIDTH_PX, 64.0)
	_bar_root.position = Vector2(-BAR_WIDTH_PX * 0.5, BAR_TOP_PX)
	_bar_layer.add_child(_bar_root)

	_bar_name = _make_bar_label("Name", display_name.to_upper(), BAR_NAME_COLOR, 20)
	_bar_name.position = Vector2(0.0, 0.0)

	var back := ColorRect.new()
	back.name = "Back"
	back.mouse_filter = Control.MOUSE_FILTER_IGNORE
	back.color = BAR_BACK_COLOR
	back.position = Vector2(0.0, 28.0)
	back.size = Vector2(BAR_WIDTH_PX, BAR_HEIGHT_PX)
	_bar_root.add_child(back)

	_bar_fill = ColorRect.new()
	_bar_fill.name = "Fill"
	_bar_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bar_fill.color = BAR_FILL_COLOR
	_bar_fill.position = Vector2(2.0, 30.0)
	_bar_fill.size = Vector2(BAR_WIDTH_PX - 4.0, BAR_HEIGHT_PX - 4.0)
	_bar_root.add_child(_bar_fill)

	_bar_phase = _make_bar_label("Phase", "", BAR_PHASE_COLOR, 14)
	_bar_phase.position = Vector2(0.0, 28.0 + BAR_HEIGHT_PX + 2.0)
	_bar_root.visible = false


func _make_bar_label(label_name: String, text: String, color: Color, font_size: int) -> Label:
	var label := Label.new()
	label.name = label_name
	label.text = text
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.size = Vector2(BAR_WIDTH_PX, font_size + 8.0)
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.add_theme_color_override("font_outline_color", Color(0.0, 0.0, 0.0, 0.9))
	label.add_theme_constant_override("outline_size", 5)
	_bar_root.add_child(label)
	return label


func _update_boss_bar() -> void:
	if _bar_root == null:
		return
	var shown := show_boss_bar and is_alive() and not _dying and is_in_turn_based_combat()
	if shown:
		var watcher := _live_target()
		if watcher == null:
			watcher = get_tree().get_first_node_in_group("player") as Node3D
		shown = watcher != null \
			and GroundMath.ground_distance(global_position, watcher.global_position) <= bar_show_distance_m
	_bar_root.visible = shown
	if not shown:
		return
	var ratio := clampf(float(health) / float(maxi(max_health, 1)), 0.0, 1.0)
	_bar_fill.size.x = (BAR_WIDTH_PX - 4.0) * ratio
	_bar_phase.text = "Phase %d%s" % [_phase, "  -  the dead rise" if _phase >= 2 else ""]


# --- Death ---------------------------------------------------------------------------

func _death_topple_seconds() -> float:
	return DEATH_TOPPLE_SECONDS


func _on_died() -> void:
	_clear_slam()
	if _bar_root != null:
		_bar_root.visible = false
	CombatFx.announce(DEATH_TEXT, PHASE_TWO_COLOR, 1.4)
	CombatFx.shake(12.0, 0.45)
	CombatFx.hit_stop(0.12, 0.2)
	for i in range(3):
		CombatFx.ring_burst(self, global_position + Vector3(0.0, 0.05 + 0.4 * float(i), 0.0), PHASE_TWO_COLOR,
			(10.0 + 8.0 * float(i)) * FX_SCREEN_SCALE, (48.0 + 16.0 * float(i)) * FX_SCREEN_SCALE, 0.5 + 0.15 * float(i))
	super()
