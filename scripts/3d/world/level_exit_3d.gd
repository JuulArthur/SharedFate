class_name LevelExit3D
extends Node3D

## The way out of a level (docs/level-flow.md): a worn stone arch over a
## glowing ring, with the destination's name floating above it. Walking into
## the ring outside a fight asks the coordinator to travel:
## `travel_to(target_scene, target_entry)` on the node in group
## `level_coordinator`, which carries the body's state over (RunState3D) and
## places it at the `Entry_<target_entry>` node of the next level.
##
## The arch has no colliders, so it neither blocks movement nor changes a
## navmesh bake. For a short while after the level starts the exit ignores the
## player, so arriving next to one never bounces you straight back.

const ACTOR_LAYER := 2
const ARM_DELAY_SECONDS := 1.0
const COLOR_STONE := Color(0.34, 0.33, 0.35)
const COLOR_GLOW := Color(1.0, 0.72, 0.36, 1.0)

## The level to load, a .tscn path.
@export_file("*.tscn") var target_scene := ""
## Where to arrive there: the `Entry_<target_entry>` node.
@export var target_entry: StringName = &"default"
## Shown above the arch, for example "To the Hollow Road".
@export var label := "Onward"
@export var radius_m := 1.2

var _area: Area3D = null
var _armed_at_msec := 0
var _ring: RangeRing3D = null


func _ready() -> void:
	_armed_at_msec = Time.get_ticks_msec() + int(ARM_DELAY_SECONDS * 1000.0)
	_build_arch()
	_ring = RangeRing3D.new()
	_ring.name = "Threshold"
	add_child(_ring)
	_ring.show_ring(radius_m, Color(COLOR_GLOW, 0.75), true)

	var sign_label := Label3D.new()
	sign_label.name = "Sign"
	sign_label.text = label
	sign_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	sign_label.no_depth_test = true
	sign_label.font_size = 64
	sign_label.outline_size = 14
	sign_label.modulate = UiTheme.TITLE
	sign_label.position = Vector3(0.0, 3.1, 0.0)
	add_child(sign_label)

	var light := OmniLight3D.new()
	light.name = "Glow"
	light.light_color = COLOR_GLOW
	light.light_energy = 1.2
	light.omni_range = 4.0
	light.position = Vector3(0.0, 1.6, 0.0)
	add_child(light)

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


## True when the exit would take the player now (armed, and the body inside).
func is_player_inside() -> bool:
	if _area == null:
		return false
	for body in _area.get_overlapping_bodies():
		if body.is_in_group("player"):
			return true
	return false


## Asks the coordinator to travel. Returns what `travel_to` answered.
func use_exit() -> bool:
	if target_scene.is_empty():
		push_warning("LevelExit3D %s: no target scene" % name)
		return false
	var coordinator := get_tree().get_first_node_in_group("level_coordinator")
	if coordinator == null or not coordinator.has_method("travel_to"):
		return false
	return bool(await coordinator.call("travel_to", target_scene, target_entry))


func _on_body_entered(body: Node) -> void:
	if not body.is_in_group("player") or Time.get_ticks_msec() < _armed_at_msec:
		return
	use_exit()


func _build_arch() -> void:
	var stone := WorldFx3D.flat_material(COLOR_STONE)
	var post := BoxMesh.new()
	post.size = Vector3(0.35, 2.4, 0.35)
	var lintel := BoxMesh.new()
	lintel.size = Vector3(2.0 * radius_m + 0.9, 0.35, 0.45)
	var half := radius_m + 0.25
	WorldFx3D.add_mesh(self, "PostLeft", post, stone, Vector3(-half, 1.2, 0.0))
	WorldFx3D.add_mesh(self, "PostRight", post, stone, Vector3(half, 1.2, 0.0))
	WorldFx3D.add_mesh(self, "Lintel", lintel, stone, Vector3(0.0, 2.55, 0.0), Vector3(0.0, 0.0, -2.0))
	var glow := CylinderMesh.new()
	glow.top_radius = radius_m
	glow.bottom_radius = radius_m
	glow.height = 0.02
	glow.radial_segments = 32
	glow.rings = 1
	var disc := WorldFx3D.add_mesh(self, "GlowDisc", glow, WorldFx3D.glow_material(Color(COLOR_GLOW, 0.18), true),
		Vector3(0.0, 0.02, 0.0))
	disc.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
