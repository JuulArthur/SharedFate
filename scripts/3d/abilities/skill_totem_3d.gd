class_name SkillTotem3D
extends Node3D

## A spirit raised by a Summon card skill (docs/cards-and-attributes.md): a
## small stone with a floating light in the skill's colour. At the start of
## each player turn it strikes (AbilityRunner3D picks the target and deals the
## damage, through `strike_requested`), for `turns_left` turns. It does not
## move and enemies ignore it.

signal strike_requested(totem: SkillTotem3D)

const STONE_COLOR := Color(0.30, 0.29, 0.30)
const ORB_HEIGHT_M := 1.15
const BOB_M := 0.08

var ability: Ability3D = null
var reach_m := 4.0
var turns_left := 3
var _orb: MeshInstance3D = null
var _light: OmniLight3D = null
var _time := 0.0
var _ending := false


func setup(the_ability: Ability3D) -> void:
	ability = the_ability
	reach_m = maxf(1.0, ability.totem_reach_m)
	turns_left = maxi(1, ability.lasting_turns)


func _ready() -> void:
	var color := ability.color if ability != null else Color.WHITE
	var stone := CylinderMesh.new()
	stone.top_radius = 0.12
	stone.bottom_radius = 0.2
	stone.height = 0.7
	stone.radial_segments = 6
	stone.rings = 1
	WorldFx3D.add_mesh(self, "Stone", stone, WorldFx3D.flat_material(STONE_COLOR), Vector3(0.0, 0.35, 0.0))

	var orb_mesh := SphereMesh.new()
	orb_mesh.radius = 0.16
	orb_mesh.height = 0.32
	_orb = WorldFx3D.add_mesh(self, "Orb", orb_mesh, WorldFx3D.glow_material(Color(color, 0.9), true),
		Vector3(0.0, ORB_HEIGHT_M, 0.0))
	_orb.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	_light = OmniLight3D.new()
	_light.name = "Glow"
	_light.light_color = color
	_light.light_energy = 1.4
	_light.omni_range = 3.5
	_light.position = Vector3(0.0, ORB_HEIGHT_M, 0.0)
	add_child(_light)

	var ring := RangeRing3D.new()
	ring.name = "Reach"
	add_child(ring)
	ring.show_ring(reach_m, Color(color, 0.35), true)


func _process(delta: float) -> void:
	if _orb == null:
		return
	_time += delta
	_orb.position.y = ORB_HEIGHT_M + BOB_M * sin(_time * 2.4)


## Where a strike leaves from.
func get_strike_origin() -> Vector3:
	return _orb.global_position if _orb != null else global_position + Vector3.UP * ORB_HEIGHT_M


## A new player turn: strike, then count down. Returns false once spent.
func tick() -> bool:
	if _ending:
		return false
	strike_requested.emit(self)
	turns_left -= 1
	if turns_left <= 0:
		end_totem()
		return false
	return true


func end_totem() -> void:
	if _ending:
		return
	_ending = true
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(self, "scale", Vector3(0.01, 0.01, 0.01), 0.35)
	if _light != null:
		tween.tween_property(_light, "light_energy", 0.0, 0.35)
	tween.chain().tween_callback(queue_free)
