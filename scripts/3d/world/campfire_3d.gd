class_name Campfire3D
extends StaticBody3D

## Track A: a campfire prop for the bandit camp. A ring of stones, crossed
## logs and an unshaded flame, lit by a flickering OmniLight3D. The body sits
## on the prop layer (8) so nobody walks through the fire and the navmesh bake
## carves around it; it is short, so it does not block line of sight much
## (the collider is only 0.4 m high, under the 0.6 m eye height enemies use).

const PROP_LAYER := 8
const STONE_RING_RADIUS_M := 0.62
const STONE_COUNT := 9
const COLOR_STONE := Color(0.36, 0.35, 0.34)
const COLOR_LOG := Color(0.33, 0.22, 0.13)
const COLOR_FLAME := Color(1.0, 0.55, 0.15, 0.9)
const COLOR_FLAME_CORE := Color(1.6, 1.2, 0.5, 0.95)
const COLOR_LIGHT := Color(1.0, 0.62, 0.32)

@export var light_energy := 2.6
@export var light_range := 10.0

var _light: OmniLight3D = null
var _flames: Array[MeshInstance3D] = []
var _flame_scales: Array[Vector3] = []
var _time := 0.0


func _ready() -> void:
	collision_layer = PROP_LAYER
	collision_mask = 0
	var shape := CylinderShape3D.new()
	shape.radius = STONE_RING_RADIUS_M + 0.12
	shape.height = 0.4
	WorldFx3D.add_shape(self, shape, Vector3(0.0, 0.2, 0.0))
	_build_model()


func _process(delta: float) -> void:
	_time += delta
	var flicker := 0.82 + 0.1 * sin(_time * 11.0) + 0.08 * sin(_time * 23.0 + 1.3)
	if _light != null:
		_light.light_energy = light_energy * flicker
	for i in range(_flames.size()):
		var flame := _flames[i]
		var phase := float(i) * 1.7
		flame.scale = _flame_scales[i] * Vector3(1.0, 0.85 + 0.2 * sin(_time * 9.0 + phase), 1.0)


func _build_model() -> void:
	var stone_mesh := SphereMesh.new()
	stone_mesh.radius = 0.14
	stone_mesh.height = 0.2
	stone_mesh.radial_segments = 6
	stone_mesh.rings = 3
	var stone_material := WorldFx3D.flat_material(COLOR_STONE)
	for i in range(STONE_COUNT):
		var angle := TAU * float(i) / float(STONE_COUNT)
		WorldFx3D.add_mesh(self, "Stone%d" % i, stone_mesh, stone_material,
			Vector3(cos(angle), 0.0, sin(angle)) * STONE_RING_RADIUS_M + Vector3(0.0, 0.08, 0.0),
			Vector3(0.0, rad_to_deg(angle), 0.0))

	var log_mesh := CylinderMesh.new()
	log_mesh.top_radius = 0.07
	log_mesh.bottom_radius = 0.08
	log_mesh.height = 0.95
	log_mesh.radial_segments = 6
	log_mesh.rings = 1
	var log_material := WorldFx3D.flat_material(COLOR_LOG)
	for i in range(3):
		WorldFx3D.add_mesh(self, "Log%d" % i, log_mesh, log_material, Vector3(0.0, 0.1, 0.0),
			Vector3(90.0, 60.0 * float(i), 12.0))

	var flame_mesh := CylinderMesh.new()
	flame_mesh.top_radius = 0.0
	flame_mesh.bottom_radius = 0.22
	flame_mesh.height = 0.7
	flame_mesh.radial_segments = 6
	flame_mesh.rings = 1
	var outer := WorldFx3D.add_mesh(self, "Flame", flame_mesh, WorldFx3D.glow_material(COLOR_FLAME, true),
		Vector3(0.0, 0.45, 0.0))
	outer.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_flames.append(outer)
	_flame_scales.append(Vector3.ONE)
	var core := WorldFx3D.add_mesh(self, "FlameCore", flame_mesh, WorldFx3D.glow_material(COLOR_FLAME_CORE, true),
		Vector3(0.0, 0.38, 0.0))
	core.scale = Vector3(0.55, 0.7, 0.55)
	core.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_flames.append(core)
	_flame_scales.append(core.scale)

	_light = OmniLight3D.new()
	_light.name = "FireLight"
	_light.light_color = COLOR_LIGHT
	_light.light_energy = light_energy
	_light.omni_range = light_range
	_light.shadow_enabled = true
	_light.position = Vector3(0.0, 1.2, 0.0)
	add_child(_light)
