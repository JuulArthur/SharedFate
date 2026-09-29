class_name SkillField3D
extends Node3D

## A trap field from a rogue's card skill with an Area card
## (docs/cards-and-attributes.md): a glowing disc on the ground that strikes
## every enemy inside once a turn, for `turns_left` of the player's turns.
##
## The field only finds its victims; AbilityRunner3D strikes them (through
## `strike_requested`), so every card effect lives in one place. An enemy is
## struck when it walks in and again when a new turn begins (`tick`) while it
## stands inside, never twice in one turn.

signal strike_requested(field: SkillField3D, enemy: Node3D)

const ACTOR_LAYER := 2
const DISC_HEIGHT_M := 0.03
const DISC_ALPHA := 0.28
const PULSE_SPEED := 3.0

var ability: Ability3D = null
var radius_m := 2.0
var turns_left := 3
var _struck: Dictionary = {}   # instance id -> true, this turn
var _area: Area3D = null
var _disc_material: StandardMaterial3D = null
var _ring: RangeRing3D = null
var _time := 0.0
var _ending := false


func setup(the_ability: Ability3D) -> void:
	ability = the_ability
	radius_m = maxf(0.5, ability.radius_m)
	turns_left = maxi(1, ability.lasting_turns)


func _ready() -> void:
	var color := ability.color if ability != null else Color.WHITE
	var disc := CylinderMesh.new()
	disc.top_radius = radius_m
	disc.bottom_radius = radius_m
	disc.height = DISC_HEIGHT_M
	disc.radial_segments = 40
	disc.rings = 1
	_disc_material = WorldFx3D.glow_material(Color(color, DISC_ALPHA), true)
	var disc_instance := WorldFx3D.add_mesh(self, "Disc", disc, _disc_material, Vector3(0.0, DISC_HEIGHT_M * 0.5 + 0.01, 0.0))
	disc_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	_ring = RangeRing3D.new()
	_ring.name = "Edge"
	add_child(_ring)
	_ring.show_ring(radius_m, Color(color, 0.8), true)

	_area = Area3D.new()
	_area.name = "Trigger"
	_area.collision_layer = 0
	_area.collision_mask = ACTOR_LAYER
	_area.monitorable = false
	var shape := CylinderShape3D.new()
	shape.radius = radius_m
	shape.height = 2.0
	WorldFx3D.add_shape(_area, shape, Vector3(0.0, 1.0, 0.0))
	add_child(_area)
	_area.body_entered.connect(_on_body_entered)


func _process(delta: float) -> void:
	if _disc_material == null or _ending:
		return
	_time += delta
	var pulse := 0.75 + 0.25 * sin(_time * PULSE_SPEED)
	_disc_material.albedo_color.a = DISC_ALPHA * pulse


## A new player turn: strike everyone inside, then count the turn down.
## Returns false once the field has run out (it then fades and frees itself).
func tick() -> bool:
	_struck.clear()
	strike_everyone_inside()
	turns_left -= 1
	if turns_left <= 0:
		end_field()
		return false
	return true


func strike_everyone_inside() -> void:
	for enemy in get_enemies_inside():
		_strike(enemy)


func get_enemies_inside() -> Array[Node3D]:
	var result: Array[Node3D] = []
	for node in get_tree().get_nodes_in_group("enemies"):
		var enemy := node as Node3D
		if enemy == null or not is_instance_valid(enemy):
			continue
		if enemy.has_method("is_alive") and not bool(enemy.call("is_alive")):
			continue
		if GroundMath.ground_distance(enemy.global_position, global_position) <= radius_m:
			result.append(enemy)
	return result


func end_field() -> void:
	if _ending:
		return
	_ending = true
	if _area != null:
		_area.set_deferred("monitoring", false)
	if _ring != null:
		_ring.hide_ring()
	var tween := create_tween()
	tween.tween_property(_disc_material, "albedo_color:a", 0.0, 0.4)
	tween.tween_callback(queue_free)


func _on_body_entered(body: Node) -> void:
	if _ending or not (body is Node3D) or not body.is_in_group("enemies"):
		return
	_strike(body as Node3D)


func _strike(enemy: Node3D) -> void:
	var key := enemy.get_instance_id()
	if _struck.has(key):
		return
	_struck[key] = true
	strike_requested.emit(self, enemy)
