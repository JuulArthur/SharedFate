class_name WildsGround3D
extends MeshInstance3D

## Track A: the Wilds floor. One vertex-coloured grid mesh built at load from
## WildsLayout: mossy grass in the clearings, a trodden dirt line along the
## corridors, dark forest floor under the trees, all broken up by value
## noise. Visual only: the walkable collider is the level's flat
## `NavigationRegion3D/Ground` box (contracts section 9), and this node sits
## outside the navigation region so the navmesh bake never reads it.
##
## arena_ground_tiles.gd lays 2 m glb tiles over a 28 m arena; at 104 m that
## would be 2,700 instances, so the big map uses a single mesh instead.

const COLOR_GRASS := Color(0.3, 0.42, 0.22)
const COLOR_GRASS_LIGHT := Color(0.38, 0.5, 0.26)
const COLOR_DIRT := Color(0.42, 0.35, 0.24)
const COLOR_FOREST := Color(0.13, 0.17, 0.11)
const COLOR_FOREST_DEEP := Color(0.08, 0.1, 0.07)
const PATH_HALF_WIDTH_M := 1.1
const FOREST_FADE_M := 5.0

## Grid spacing in metres; the mesh covers the whole map.
@export var cell_m := 1.0
@export var noise_seed := 91


func _ready() -> void:
	mesh = _build_mesh()
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _build_mesh() -> ArrayMesh:
	var noise := FastNoiseLite.new()
	noise.seed = noise_seed
	noise.frequency = 0.08
	var detail := FastNoiseLite.new()
	detail.seed = noise_seed + 1
	detail.frequency = 0.35

	var half := WildsLayout.MAP_HALF_M
	var steps := int(ceil(half * 2.0 / cell_m))
	var tool := SurfaceTool.new()
	tool.begin(Mesh.PRIMITIVE_TRIANGLES)
	var colors: Array[Color] = []
	var positions: Array[Vector3] = []
	for row in range(steps + 1):
		for col in range(steps + 1):
			var ground := Vector2(-half + float(col) * cell_m, -half + float(row) * cell_m)
			positions.append(GroundMath.from_ground(ground))
			colors.append(_color_at(ground, noise, detail))

	var stride := steps + 1
	for row in range(steps):
		for col in range(steps):
			var i00 := row * stride + col
			var i10 := i00 + 1
			var i01 := i00 + stride
			var i11 := i01 + 1
			for index: int in [i00, i10, i11, i00, i11, i01]:
				tool.set_color(colors[index])
				tool.set_normal(Vector3.UP)
				tool.add_vertex(positions[index])

	var material := StandardMaterial3D.new()
	material.vertex_color_use_as_albedo = true
	material.roughness = 1.0
	tool.set_material(material)
	return tool.commit()


func _color_at(ground: Vector2, noise: FastNoiseLite, detail: FastNoiseLite) -> Color:
	var d := WildsLayout.distance_to_open(ground)
	var n := noise.get_noise_2d(ground.x, ground.y)
	var fine := detail.get_noise_2d(ground.x, ground.y)
	var color: Color
	if d < 0.0:
		color = COLOR_GRASS.lerp(COLOR_GRASS_LIGHT, clampf(n * 0.5 + 0.5, 0.0, 1.0))
		var path_d := WildsLayout.distance_to_path_line(ground)
		if path_d < PATH_HALF_WIDTH_M + fine * 0.4:
			color = color.lerp(COLOR_DIRT, 0.75)
		# The edge darkens into the forest over the last metre.
		color = color.lerp(COLOR_FOREST, clampf(1.0 + d, 0.0, 1.0) * 0.5)
	else:
		color = COLOR_FOREST.lerp(COLOR_FOREST_DEEP, clampf(d / FOREST_FADE_M, 0.0, 1.0))
	return color.lightened(fine * 0.05) if fine > 0.0 else color.darkened(-fine * 0.05)
