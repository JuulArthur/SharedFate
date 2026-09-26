class_name Trap3D
extends Area3D

## Track A: a spike trap (docs/gameplay-expansion.md section 3, "Traps").
##
## An Area3D on no layer that watches the actor layer (2, contracts section 3).
## Rules:
## - Hidden until the player notices it: the player within `reveal_radius`
##   (`rogue_reveal_radius` while the rogue is in control) for
##   `notice_seconds` reveals it and the spikes show. Until then only a faint
##   glint blinks now and then.
## - The player triggers only a trap it has not revealed.
## - Enemies trigger it only while in turn mode, unless the player placed it
##   (`placed_by_player`), which catches them any time.
## - Enemy: `take_environment_damage(damage)` (fallback `receive_damage`) and
##   `apply_status(&"root", 1)` (fallback `apply_root(1)`). Player:
##   `take_damage(damage)`.
## - Spent after one trigger: the spikes snap up, a popup and a shake, and the
##   trap stays as a dull, harmless plate.
##
## `notice_seconds` is a track A addition (docs/wilds-map.md): with an instant
## reveal at 3 m a walking player always sees a trap long before stepping on
## it. A knight walking at 3.5 m/s crosses 3 m in under a second, so the
## default 1 s notice time lets a careless walk spring it, while the rogue's
## 6 m sees it in time. Set it to 0 for the contract's instant reveal.

const PLAYER_GROUP := &"player"
const ENEMY_GROUP := &"enemies"
const ACTOR_LAYER := 2
const TRIGGER_RADIUS_M := 0.5
const TRIGGER_HEIGHT_M := 1.0
const PLATE_RADIUS_M := 0.45
const SPIKE_COUNT := 7
const SPIKE_HEIGHT_M := 0.32
const SPIKE_RETRACTED_Y := -0.26
const SPIKE_SNAPPED_Y := 0.06
const SNAP_SECONDS := 0.07
const GLINT_PERIOD_SECONDS := 3.2
const GLINT_ON_SECONDS := 0.18
const RING_RADIUS_M := 0.62
const COLOR_STEEL := Color(0.42, 0.42, 0.46)
const COLOR_PLAYER_STEEL := Color(0.3, 0.5, 0.56)
const COLOR_PLATE := Color(0.2, 0.18, 0.16)
const COLOR_SPENT := Color(0.26, 0.24, 0.22)
const COLOR_RING := Color(1.0, 0.35, 0.25, 0.55)
const COLOR_PLAYER_RING := Color(0.35, 0.95, 0.85, 0.6)
const COLOR_GLINT := Color(1.6, 1.6, 1.3, 1.0)
const COLOR_SNAP := Color(1.0, 0.55, 0.35, 1.0)
const POPUP_OFFSET := Vector3(0.0, 1.2, 0.0)

## Emitted once, when the trap fires on `victim`.
signal triggered(victim: Node3D)
## Emitted once, when the player notices the trap.
signal revealed_to_player

## Damage dealt by the spikes.
@export var damage := 12
## Turns of root put on an enemy it catches.
@export var root_turns := 1
## True for a trap the rogue set (Set Snare): visible, tinted, catches enemies
## outside turn mode too.
@export var placed_by_player := false
## Starts revealed (a visible trap line that teaches the rule).
@export var start_revealed := false
## Metres; the player notices the trap within this radius...
@export var reveal_radius := 3.0
## ...or this one while the rogue is in control.
@export var rogue_reveal_radius := 6.0
## Seconds the player must stay inside the radius to notice it (0 = at once).
@export var notice_seconds := 1.0

var _revealed := false
var _spent := false
var _notice_time := 0.0
var _glint_time := 0.0
var _visual: Node3D = null
var _spikes: Node3D = null
var _plate: MeshInstance3D = null
var _glint: MeshInstance3D = null
var _ring: RangeRing3D = null
var _steel_material: StandardMaterial3D = null


## Creates a player-placed trap under `parent` at `world_point` (flattened to
## the ground) and returns it. What the rogue's Set Snare ability calls.
static func place_player_trap(parent: Node, world_point: Vector3) -> Trap3D:
	var trap := Trap3D.new()
	trap.name = "PlayerTrap"
	trap.placed_by_player = true
	trap.start_revealed = true
	trap.notice_seconds = 0.0
	if parent == null:
		return trap
	parent.add_child(trap, true)
	trap.global_position = GroundMath.flatten(world_point)
	return trap


func _ready() -> void:
	collision_layer = 0
	collision_mask = ACTOR_LAYER
	monitoring = true
	monitorable = false
	_build_collision()
	_build_visual()
	body_entered.connect(_on_body_entered)
	if start_revealed or placed_by_player:
		_set_revealed(true, false)
	else:
		_apply_visibility()


func _physics_process(delta: float) -> void:
	if _spent:
		return
	if not _revealed:
		_update_notice(delta)
		_update_glint(delta)


## True once the player has noticed the trap (or it started visible).
func is_revealed() -> bool:
	return _revealed


## True once the trap has fired.
func is_spent() -> bool:
	return _spent


## Shows the trap to the player at once (a detection ability, a test).
func reveal() -> void:
	if _revealed or _spent:
		return
	_set_revealed(true, true)


## The radius, in metres, at which `player` notices this trap right now.
func get_reveal_radius_for(player: Node) -> float:
	if player != null and player.has_method("get_active_soul"):
		var soul := player.call("get_active_soul") as Soul
		if soul != null and soul.kind == Soul.Kind.ROGUE:
			return rogue_reveal_radius
	return reveal_radius


func _update_notice(delta: float) -> void:
	var player := WorldFx3D.find_player(get_tree())
	if player == null:
		_notice_time = 0.0
		return
	if player.has_method("is_alive") and not bool(player.call("is_alive")):
		return
	var distance := GroundMath.ground_distance(player.global_position, global_position)
	if distance > get_reveal_radius_for(player):
		_notice_time = 0.0
		return
	_notice_time += delta
	if _notice_time >= notice_seconds:
		_set_revealed(true, true)


func _on_body_entered(body: Node3D) -> void:
	if _spent or body == null:
		return
	if body.has_method("is_alive") and not bool(body.call("is_alive")):
		return
	if body.is_in_group(PLAYER_GROUP):
		if _revealed:
			return
		_trigger_on_player(body)
		return
	if body.is_in_group(ENEMY_GROUP):
		var in_turn_mode := body.has_method("is_in_turn_based_combat") \
			and bool(body.call("is_in_turn_based_combat"))
		if not placed_by_player and not in_turn_mode:
			return
		_trigger_on_enemy(body)


func _trigger_on_player(player: Node3D) -> void:
	_spend(player)
	if player.has_method("take_damage"):
		player.call("take_damage", damage)


func _trigger_on_enemy(enemy: Node3D) -> void:
	_spend(enemy)
	# Environment damage keeps an unaware enemy unaware (no provoked_by_hit),
	# so a player-set trap in exploration does not start an ambush.
	if enemy.has_method("take_environment_damage"):
		enemy.call("take_environment_damage", damage)
	elif enemy.has_method("receive_damage"):
		enemy.call("receive_damage", damage)
	if enemy.has_method("is_alive") and not bool(enemy.call("is_alive")):
		return
	if enemy.has_method("apply_status"):
		enemy.call("apply_status", &"root", root_turns)
	elif enemy.has_method("apply_root"):
		enemy.call("apply_root", root_turns)


## Marks the trap spent and plays the snap: spikes shoot up, the plate dulls,
## popup, burst and shake.
func _spend(victim: Node3D) -> void:
	_spent = true
	set_deferred("monitoring", false)
	if not _revealed:
		_revealed = true
	_apply_visibility()
	if _ring != null:
		_ring.hide_ring()
	if _spikes != null:
		_spikes.position.y = SPIKE_RETRACTED_Y
		var tween := create_tween()
		tween.tween_property(_spikes, "position:y", SPIKE_SNAPPED_Y, SNAP_SECONDS) \
			.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		tween.tween_interval(0.35)
		tween.tween_callback(_dull)
	CombatFx.popup_text(global_position + POPUP_OFFSET, "SNAP!", COLOR_SNAP, 20)
	CombatFx.ring_burst(self, global_position + Vector3(0.0, 0.05, 0.0), COLOR_SNAP,
		6.0 * WorldFx3D.FX_SCREEN_SCALE, 20.0 * WorldFx3D.FX_SCREEN_SCALE, 0.28)
	CombatFx.shake(4.0, 0.15)
	triggered.emit(victim)


func _dull() -> void:
	if _steel_material != null:
		_steel_material.albedo_color = COLOR_SPENT
		_steel_material.metallic = 0.1


func _set_revealed(value: bool, announce: bool) -> void:
	_revealed = value
	_apply_visibility()
	if not _revealed or _spent:
		return
	if _ring != null:
		_ring.show_ring(RING_RADIUS_M, COLOR_PLAYER_RING if placed_by_player else COLOR_RING)
	if _spikes != null and announce:
		# A little pop so the reveal reads: spikes peek up, then settle.
		_spikes.position.y = SPIKE_RETRACTED_Y
		var tween := create_tween()
		tween.tween_property(_spikes, "position:y", SPIKE_RETRACTED_Y + 0.14, 0.12)
		tween.tween_property(_spikes, "position:y", SPIKE_RETRACTED_Y + 0.08, 0.1)
	elif _spikes != null:
		_spikes.position.y = SPIKE_RETRACTED_Y + 0.08
	if announce:
		CombatFx.popup_text(global_position + POPUP_OFFSET, "Trap!", CombatFx.COLOR_WARNING, 16)
		revealed_to_player.emit()


func _apply_visibility() -> void:
	if _visual != null:
		_visual.visible = _revealed
	if _glint != null:
		_glint.visible = false


func _update_glint(delta: float) -> void:
	if _glint == null:
		return
	_glint_time = fmod(_glint_time + delta, GLINT_PERIOD_SECONDS)
	_glint.visible = _glint_time < GLINT_ON_SECONDS


func _build_collision() -> void:
	var shape := CylinderShape3D.new()
	shape.radius = TRIGGER_RADIUS_M
	shape.height = TRIGGER_HEIGHT_M
	WorldFx3D.add_shape(self, shape, Vector3(0.0, TRIGGER_HEIGHT_M * 0.5, 0.0))


func _build_visual() -> void:
	_visual = Node3D.new()
	_visual.name = "Visual"
	add_child(_visual)

	var plate_mesh := CylinderMesh.new()
	plate_mesh.top_radius = PLATE_RADIUS_M
	plate_mesh.bottom_radius = PLATE_RADIUS_M + 0.03
	plate_mesh.height = 0.05
	plate_mesh.radial_segments = 10
	plate_mesh.rings = 1
	_plate = WorldFx3D.add_mesh(_visual, "Plate", plate_mesh,
		WorldFx3D.flat_material(COLOR_PLATE, 0.8, 0.3), Vector3(0.0, 0.025, 0.0))

	_steel_material = WorldFx3D.flat_material(
		COLOR_PLAYER_STEEL if placed_by_player else COLOR_STEEL, 0.4, 0.8)
	var jaw_mesh := TorusMesh.new()
	jaw_mesh.inner_radius = PLATE_RADIUS_M - 0.08
	jaw_mesh.outer_radius = PLATE_RADIUS_M
	jaw_mesh.rings = 12
	jaw_mesh.ring_segments = 4
	WorldFx3D.add_mesh(_visual, "Jaw", jaw_mesh, _steel_material, Vector3(0.0, 0.06, 0.0))

	# The spikes ride in a node that sits below the plate; the plate hides them
	# until the snap pushes them up through it.
	_spikes = Node3D.new()
	_spikes.name = "Spikes"
	_spikes.position = Vector3(0.0, SPIKE_RETRACTED_Y, 0.0)
	_visual.add_child(_spikes)
	var spike_mesh := CylinderMesh.new()
	spike_mesh.top_radius = 0.0
	spike_mesh.bottom_radius = 0.045
	spike_mesh.height = SPIKE_HEIGHT_M
	spike_mesh.radial_segments = 4
	spike_mesh.rings = 1
	for i in range(SPIKE_COUNT):
		var offset := Vector3.ZERO
		if i > 0:
			var angle := TAU * float(i - 1) / float(SPIKE_COUNT - 1)
			offset = Vector3(cos(angle), 0.0, sin(angle)) * (PLATE_RADIUS_M * 0.55)
		WorldFx3D.add_mesh(_spikes, "Spike%d" % i, spike_mesh, _steel_material,
			offset + Vector3(0.0, SPIKE_HEIGHT_M * 0.5, 0.0))

	var glint_mesh := QuadMesh.new()
	glint_mesh.size = Vector2(0.16, 0.16)
	_glint = WorldFx3D.add_mesh(self, "Glint", glint_mesh,
		WorldFx3D.glow_material(COLOR_GLINT, true), Vector3(0.12, 0.06, -0.05), Vector3(-90.0, 45.0, 0.0))
	_glint.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_glint.visible = false

	_ring = RangeRing3D.new()
	_ring.name = "RevealRing"
	add_child(_ring)
	_ring.hide_ring()
