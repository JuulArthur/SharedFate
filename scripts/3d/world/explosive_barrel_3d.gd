class_name ExplosiveBarrel3D
extends StaticBody3D

## Track A: an explosive barrel (docs/gameplay-expansion.md section 3,
## "Hittables" and "Explosive barrel").
##
## A StaticBody3D on the prop layer (8), so it blocks movement and line of
## sight like a crate, in group `hittable` so melee, throws, spells and
## abilities can target it like an enemy. When its health runs out it
## explodes: `blast_damage` to every living actor within `blast_radius`
## (enemies through `receive_damage`, so survivors join a fight; the player
## through `take_damage`), `apply_status(&"burn", 2, 4)` and a knockback on the
## enemies that have those methods, a fireball, a burst and a shake, then other
## barrels in range go off `chain_delay` seconds later. The barrel frees itself
## once the flash is over. Its hole in the navmesh stays (not required).

const HITTABLE_GROUP := &"hittable"
const BARREL_GROUP := &"explosive_barrels"
const PROP_LAYER := 8
const RADIUS_M := 0.38
const HEIGHT_M := 1.0
const COLOR_BODY := Color(0.72, 0.13, 0.1)
const COLOR_BAND := Color(0.16, 0.12, 0.1)
const COLOR_MARK := Color(1.0, 0.78, 0.2)
const COLOR_FIRE := Color(1.0, 0.55, 0.15, 1.0)
const COLOR_FIRE_CORE := Color(1.8, 1.3, 0.6, 1.0)
const COLOR_HIT := Color(2.6, 1.6, 1.0, 1.0)
const FIREBALL_SECONDS := 0.45
const FREE_AFTER_SECONDS := 0.6
const POPUP_OFFSET := Vector3(0.0, 1.6, 0.0)

## Emitted once, at the moment of the blast.
signal exploded(center: Vector3)

@export var max_health := 10
@export var blast_radius := 3.0
@export var blast_damage := 22
@export var burn_turns := 2
@export var burn_power := 4
@export var knockback_m := 1.5
@export var chain_delay := 0.15

var health := 0
var _exploded := false
var _hover_highlighted := false
var _model: Node3D = null


func _ready() -> void:
	health = max_health
	collision_layer = PROP_LAYER
	collision_mask = 0
	add_to_group(HITTABLE_GROUP)
	add_to_group(BARREL_GROUP)
	var shape := CylinderShape3D.new()
	shape.radius = RADIUS_M
	shape.height = HEIGHT_M
	WorldFx3D.add_shape(self, shape, Vector3(0.0, HEIGHT_M * 0.5, 0.0))
	_build_model()


func is_alive() -> bool:
	return not _exploded and health > 0


func receive_damage(amount: int) -> void:
	_take_hit(amount)


func take_damage(amount: int) -> void:
	_take_hit(amount)


func set_hover_highlighted(enabled: bool) -> void:
	if _hover_highlighted == enabled:
		return
	_hover_highlighted = enabled
	WorldFx3D.set_highlight(_model, enabled, Color(1.0, 0.4, 0.2, 0.25))


func is_hover_highlighted() -> bool:
	return _hover_highlighted


## Blows up now, whatever the health (chain reactions, scripted events).
func detonate() -> void:
	if _exploded or not is_inside_tree():
		return
	health = 0
	_explode()


func _take_hit(amount: int) -> void:
	if _exploded or amount <= 0:
		return
	health = maxi(0, health - amount)
	if _model != null:
		HitFlash3D.flash_node(_model, COLOR_HIT, 0.14)
	if health == 0:
		_explode()


func _explode() -> void:
	_exploded = true
	var center := GroundMath.flatten(global_position)
	# Out of the way at once: no longer blocks, hides, and cannot be hit again.
	set_deferred("collision_layer", 0)
	remove_from_group(HITTABLE_GROUP)
	if _model != null:
		_model.visible = false

	_damage_actors(center)
	_play_blast_fx(center)
	_chain(center)
	exploded.emit(center)

	var timer := get_tree().create_timer(FREE_AFTER_SECONDS)
	timer.timeout.connect(queue_free)


func _damage_actors(center: Vector3) -> void:
	var tree := get_tree()
	var enemies: Array[Node] = tree.get_nodes_in_group(&"enemies")
	for node in enemies:
		var enemy := node as Node3D
		if not _is_live_actor_in_blast(enemy, center):
			continue
		if enemy.has_method("receive_damage"):
			enemy.call("receive_damage", blast_damage)
		if enemy.has_method("is_alive") and not bool(enemy.call("is_alive")):
			continue
		if enemy.has_method("apply_status"):
			enemy.call("apply_status", &"burn", burn_turns, burn_power)
		if enemy.has_method("knockback"):
			enemy.call("knockback", center, knockback_m)
	var players: Array[Node] = tree.get_nodes_in_group(&"player")
	for node in players:
		var player := node as Node3D
		if not _is_live_actor_in_blast(player, center):
			continue
		if player.has_method("take_damage"):
			player.call("take_damage", blast_damage)


func _is_live_actor_in_blast(actor: Node3D, center: Vector3) -> bool:
	if actor == null or not is_instance_valid(actor) or not actor.is_inside_tree():
		return false
	if actor.has_method("is_alive") and not bool(actor.call("is_alive")):
		return false
	return GroundMath.ground_distance(actor.global_position, center) <= blast_radius


func _chain(center: Vector3) -> void:
	for node in get_tree().get_nodes_in_group(BARREL_GROUP):
		if node == self or not (node is ExplosiveBarrel3D):
			continue
		var other := node as ExplosiveBarrel3D
		if not other.is_alive():
			continue
		if GroundMath.ground_distance(other.global_position, center) > blast_radius:
			continue
		var timer := get_tree().create_timer(chain_delay)
		timer.timeout.connect(other.detonate)


func _play_blast_fx(center: Vector3) -> void:
	var fx_parent := get_parent() as Node3D
	if fx_parent != null:
		_spawn_fireball(fx_parent, center)
	var start_px := 8.0 * WorldFx3D.FX_SCREEN_SCALE
	var end_px := WorldFx3D.screen_radius_px(self, center, blast_radius)
	CombatFx.ring_burst(self, center + Vector3(0.0, 0.05, 0.0), COLOR_FIRE, start_px, end_px, 0.4)
	CombatFx.ring_burst(self, center + Vector3(0.0, 0.8, 0.0), COLOR_FIRE_CORE, start_px,
		end_px * 0.6, 0.3, 1.0)
	CombatFx.popup_text(center + POPUP_OFFSET, "BOOM!", COLOR_FIRE, 26)
	CombatFx.shake(9.0, 0.3)


## A glowing ball that swells and fades, plus a short light flash, parented
## to the level so it outlives the barrel.
func _spawn_fireball(parent: Node3D, center: Vector3) -> void:
	var fireball := Node3D.new()
	fireball.name = "BarrelBlast"
	parent.add_child(fireball, true)
	fireball.global_position = center + Vector3(0.0, 0.6, 0.0)

	var sphere := SphereMesh.new()
	sphere.radius = 0.5
	sphere.height = 1.0
	sphere.radial_segments = 10
	sphere.rings = 5
	var outer_material := WorldFx3D.glow_material(COLOR_FIRE, true)
	var outer := WorldFx3D.add_mesh(fireball, "Outer", sphere, outer_material)
	outer.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	outer.scale = Vector3.ONE * 0.4
	var core_material := WorldFx3D.glow_material(COLOR_FIRE_CORE, true)
	var core := WorldFx3D.add_mesh(fireball, "Core", sphere, core_material)
	core.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	core.scale = Vector3.ONE * 0.3

	var light := OmniLight3D.new()
	light.name = "Flash"
	light.light_color = COLOR_FIRE
	light.light_energy = 6.0
	light.omni_range = blast_radius * 2.5
	fireball.add_child(light)

	var diameter := blast_radius * 2.0
	var tween := fireball.create_tween()
	tween.set_parallel(true)
	tween.tween_property(outer, "scale", Vector3.ONE * diameter, FIREBALL_SECONDS) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(core, "scale", Vector3.ONE * diameter * 0.55, FIREBALL_SECONDS * 0.7) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(outer_material, "albedo_color:a", 0.0, FIREBALL_SECONDS)
	tween.tween_property(core_material, "albedo_color:a", 0.0, FIREBALL_SECONDS * 0.7)
	tween.tween_property(light, "light_energy", 0.0, FIREBALL_SECONDS)
	tween.chain().tween_callback(fireball.queue_free)


func _build_model() -> void:
	_model = Node3D.new()
	_model.name = "Model"
	add_child(_model)
	var body_mesh := CylinderMesh.new()
	body_mesh.top_radius = RADIUS_M * 0.94
	body_mesh.bottom_radius = RADIUS_M * 0.94
	body_mesh.height = HEIGHT_M
	body_mesh.radial_segments = 10
	body_mesh.rings = 2
	WorldFx3D.add_mesh(_model, "Body", body_mesh, WorldFx3D.flat_material(COLOR_BODY, 0.6),
		Vector3(0.0, HEIGHT_M * 0.5, 0.0))
	var band_mesh := CylinderMesh.new()
	band_mesh.top_radius = RADIUS_M
	band_mesh.bottom_radius = RADIUS_M
	band_mesh.height = 0.08
	band_mesh.radial_segments = 10
	band_mesh.rings = 1
	var band_material := WorldFx3D.flat_material(COLOR_BAND, 0.5, 0.6)
	for band_y: float in [0.14, 0.5, 0.86]:
		WorldFx3D.add_mesh(_model, "Band", band_mesh, band_material, Vector3(0.0, band_y, 0.0))
	var lid_mesh := CylinderMesh.new()
	lid_mesh.top_radius = RADIUS_M * 0.8
	lid_mesh.bottom_radius = RADIUS_M * 0.9
	lid_mesh.height = 0.04
	lid_mesh.radial_segments = 10
	lid_mesh.rings = 1
	WorldFx3D.add_mesh(_model, "Lid", lid_mesh, band_material, Vector3(0.0, HEIGHT_M + 0.02, 0.0))
	# A yellow hazard mark on two sides so it reads as "explosive" from above.
	var mark_mesh := BoxMesh.new()
	mark_mesh.size = Vector3(0.18, 0.18, 0.02)
	var mark_material := WorldFx3D.flat_material(COLOR_MARK, 0.5)
	mark_material.emission_enabled = true
	mark_material.emission = COLOR_MARK * 0.35
	for side: float in [-1.0, 1.0]:
		WorldFx3D.add_mesh(_model, "Mark", mark_mesh, mark_material,
			Vector3(0.0, 0.68, side * (RADIUS_M - 0.005)), Vector3(0.0, 0.0, 45.0))
