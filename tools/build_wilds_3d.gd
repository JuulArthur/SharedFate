extends SceneTree

## Track A: builds `scenes/3d/wilds.tscn`, the Wilds (a ~100 x 100 m forest
## map), and bakes its navmesh into `scenes/3d/wilds_navmesh.tres`.
## docs/gameplay-expansion.md section 6, docs/wilds-map.md.
##
## Run from the repository root (writes both files; re-run after any change):
##   godot --headless --path . --script res://tools/build_wilds_3d.gd
##
## The level follows the node contract of docs/3d-port-contracts.md section 9:
## root `Wilds` on main_3d.gd, WorldEnvironment, Sun, NavigationRegion3D with
## the flat Ground box (layer 1, the map bounds main_3d measures) and every
## prop under it (layer 8), CameraRig, Player, Spawn_default. The shape of the
## map lives in scripts/3d/world/wilds_layout.gd; everything outside its
## clearings and corridors becomes invisible prop-layer walls (`ForestWalls`)
## lined with real trees, while WildsForest3D draws the deep forest at load.
##
## Work happens in MainLoop._initialize(), not _init(): the level scripts use
## autoload identifiers, which only resolve once the SceneTree has registered
## the autoloads (contracts section 9, WP7 note).
##
## Bake: the NavigationRegion3D's children are parsed as static colliders on
## layers 1 and 8 with the arena's settings (cell 0.25 m, agent radius 0.5 m,
## height 2 m). Recast also finds the flat tops of the forest walls; the bake
## is then pruned to the one connected piece of floor that holds the spawn, so
## no click can snap to a wall top or a sealed pocket.

const OUTPUT_PATH := "res://scenes/3d/wilds.tscn"
const NAVMESH_PATH := "res://scenes/3d/wilds_navmesh.tres"
const MAIN_SCRIPT_PATH := "res://scripts/3d/main_3d.gd"
const PROP_SCRIPT_PATH := "res://scripts/3d/prop_3d.gd"
const PLAYER_SCENE_PATH := "res://scenes/3d/player_3d.tscn"
const CAMERA_RIG_SCENE_PATH := "res://scenes/3d/camera_rig_3d.tscn"
const TREE_SCENE_PATH := "res://assets/3d/models/tree.glb"
const CRATE_SCENE_PATH := "res://assets/3d/models/crate.glb"

const TRAP_SCRIPT_PATH := "res://scripts/3d/world/trap_3d.gd"
const BARREL_SCRIPT_PATH := "res://scripts/3d/world/explosive_barrel_3d.gd"
const HIDE_ZONE_SCRIPT_PATH := "res://scripts/3d/world/hide_zone_3d.gd"
const WAYSTONE_SCRIPT_PATH := "res://scripts/3d/world/waystone_3d.gd"
const CHEST_SCRIPT_PATH := "res://scripts/3d/world/loot_chest_3d.gd"
const CAMPFIRE_SCRIPT_PATH := "res://scripts/3d/world/campfire_3d.gd"
const GROUND_SCRIPT_PATH := "res://scripts/3d/world/wilds_ground_3d.gd"
const FOREST_SCRIPT_PATH := "res://scripts/3d/world/wilds_forest_3d.gd"

const Layout := preload("res://scripts/3d/world/wilds_layout.gd")

## Enemy scenes (gameplay expansion section 6). Track B writes all but the
## wolf; a missing scene falls back to the wolf with a warning.
const ENEMY_SCENES := {
	&"wolf": "res://scenes/3d/wolf_3d.tscn",
	&"dire_wolf": "res://scenes/3d/enemies/dire_wolf_3d.tscn",
	&"bandit": "res://scenes/3d/enemies/bandit_3d.tscn",
	&"cultist": "res://scenes/3d/enemies/cultist_3d.tscn",
	&"brute": "res://scenes/3d/enemies/brute_3d.tscn",
	&"grave_warden": "res://scenes/3d/enemies/grave_warden_3d.tscn",
}
const FALLBACK_ENEMY := &"wolf"

const LAYER_GROUND := 1
const LAYER_PROPS := 8
const NAVMESH_GROUP := &"navmesh_source"
const WALL_CELL_M := 1.0
const WALL_HEIGHT_M := 2.0
## Real trees stand in this band of forest along the open ground.
const EDGE_TREE_MIN_M := 0.35
const EDGE_TREE_MAX_M := 2.8
const EDGE_TREE_SPACING_M := 1.9
const EDGE_TREE_CANDIDATE_STEP_M := 0.7
## Navmesh polygons above this height are wall tops, not floor.
const NAVMESH_FLOOR_MAX_Y := 1.0
const SETTLE_PROCESS_FRAMES := 6
const SETTLE_PHYSICS_FRAMES := 3
const SEED := 20260926

const SPAWN := Vector2(-36.0, 38.0)

## Enemies per camp: kind, (x, z), facing point (x, z), wander radius (m).
const CAMPS := {
	&"start": [
		{"kind": &"wolf", "at": Vector2(-30.0, 27.0), "face": Vector2(-34.0, 34.0), "wander": 3.0},
		{"kind": &"wolf", "at": Vector2(-39.5, 26.0), "face": Vector2(-36.0, 34.0), "wander": 0.0},
	],
	&"den": [
		{"kind": &"dire_wolf", "at": Vector2(-32.0, -12.0), "face": Vector2(-33.0, 0.0), "wander": 0.0},
		{"kind": &"wolf", "at": Vector2(-35.0, -10.5), "face": Vector2(-40.0, -4.0), "wander": 0.0},
		{"kind": &"wolf", "at": Vector2(-29.0, -10.0), "face": Vector2(-24.0, -4.0), "wander": 2.0},
		{"kind": &"wolf", "at": Vector2(-33.0, -15.0), "face": Vector2(-18.0, -26.0), "wander": 0.0},
	],
	&"camp": [
		{"kind": &"bandit", "at": Vector2(4.5, 9.5), "face": Vector2(6.0, 12.0), "wander": 1.5},
		{"kind": &"bandit", "at": Vector2(9.0, 11.5), "face": Vector2(6.0, 12.0), "wander": 0.0},
		{"kind": &"bandit", "at": Vector2(6.0, 15.0), "face": Vector2(-14.0, 30.0), "wander": 0.0},
		{"kind": &"cultist", "at": Vector2(2.5, 12.5), "face": Vector2(6.0, 12.0), "wander": 0.0},
	],
	&"ruins": [
		{"kind": &"brute", "at": Vector2(-2.0, -30.0), "face": Vector2(0.0, -18.0), "wander": 0.0},
		{"kind": &"brute", "at": Vector2(1.5, -28.5), "face": Vector2(3.0, -18.0), "wander": 0.0},
		{"kind": &"cultist", "at": Vector2(-3.5, -33.0), "face": Vector2(-14.0, -26.0), "wander": 0.0},
		{"kind": &"cultist", "at": Vector2(1.0, -33.0), "face": Vector2(16.0, -31.0), "wander": 0.0},
	],
	&"boss": [
		{"kind": &"grave_warden", "at": Vector2(37.0, -32.0), "face": Vector2(16.0, -31.0), "wander": 0.0},
	],
}

var _rng := RandomNumberGenerator.new()
var _root: Node3D
var _region: NavigationRegion3D
var _materials: Dictionary = {}
## Points (x, z) with a clearance radius that edge trees keep away from.
var _keep_out: Array[Dictionary] = []
var _warnings: Array[String] = []
var _enemy_count := 0
var _tree_count := 0
var _wall_box_count := 0


func _initialize() -> void:
	var ok: bool = await _build()
	quit(0 if ok else 1)


func _build() -> bool:
	_rng.seed = SEED
	_root = Node3D.new()
	_root.name = "Wilds"

	_add_environment()
	_add_navigation_region()
	_add_forest_walls()
	_add_structures()
	_add_interactables()
	_add_edge_trees()

	# Bake while the carving geometry is live: prop_3d.gd relabels the glb
	# colliders and the world objects build their colliders in _ready.
	root.add_child(_root)
	for _i in range(SETTLE_PROCESS_FRAMES):
		await process_frame
	for _i in range(SETTLE_PHYSICS_FRAMES):
		await physics_frame
	var baked := _bake_navmesh()
	root.remove_child(_root)
	if not baked:
		_root.free()
		return false

	_add_visuals()
	_add_lights()
	_add_cover()
	_add_traps()
	_add_enemies()
	_add_player_and_camera()

	_root.set_script(load(MAIN_SCRIPT_PATH))
	_root.set("spawn_test_loot", false)
	_root.set("story_chapter_id", &"")
	_root.set("enemy_scene", load(ENEMY_SCENES[FALLBACK_ENEMY]))

	var packed := PackedScene.new()
	var pack_error := packed.pack(_root)
	if pack_error != OK:
		push_error("build_wilds_3d: pack failed (%d)" % pack_error)
		_root.free()
		return false
	var save_error := ResourceSaver.save(packed, OUTPUT_PATH)
	if save_error != OK:
		push_error("build_wilds_3d: save failed (%d)" % save_error)
		_root.free()
		return false

	for warning in _warnings:
		print("[build_wilds_3d] WARNING: %s" % warning)
	print("[build_wilds_3d] wall boxes %d, edge trees %d, enemies %d, navmesh polygons %d" % [
		_wall_box_count, _tree_count, _enemy_count, _region.navigation_mesh.get_polygon_count()])
	print("BUILD OK: %s + %s" % [OUTPUT_PATH, NAVMESH_PATH])
	_root.free()
	return true


# --- Environment ------------------------------------------------------------------

func _add_environment() -> void:
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.04, 0.06, 0.06)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.36, 0.46, 0.42)
	environment.ambient_light_energy = 0.65
	environment.fog_enabled = true
	environment.fog_light_color = Color(0.2, 0.28, 0.26)
	environment.fog_density = 0.012
	environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var world_environment := WorldEnvironment.new()
	world_environment.name = "WorldEnvironment"
	world_environment.environment = environment
	_attach(_root, world_environment)

	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.position = Vector3(0.0, 20.0, 0.0)
	sun.rotation_degrees = Vector3(-50.0, 35.0, 0.0)
	sun.light_color = Color(0.85, 0.92, 0.8)
	sun.light_energy = 0.8
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 60.0
	_attach(_root, sun)


func _add_navigation_region() -> void:
	_region = NavigationRegion3D.new()
	_region.name = "NavigationRegion3D"
	var mesh := NavigationMesh.new()
	mesh.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	mesh.geometry_collision_mask = LAYER_GROUND | LAYER_PROPS
	mesh.agent_height = 2.0
	_region.navigation_mesh = mesh
	_attach(_root, _region)

	var ground := StaticBody3D.new()
	ground.name = "Ground"
	ground.collision_layer = LAYER_GROUND
	ground.collision_mask = 0
	ground.position = Vector3(0.0, -0.2, 0.0)
	_attach(_region, ground)
	var box := BoxShape3D.new()
	var side := Layout.MAP_HALF_M * 2.0
	box.size = Vector3(side, 0.4, side)
	var shape := CollisionShape3D.new()
	shape.name = "CollisionShape3D"
	shape.shape = box
	_attach(ground, shape)


## Every 1 m cell whose centre lies in the forest becomes solid; runs of
## cells merge greedily into as few boxes as possible, all on one body.
func _add_forest_walls() -> void:
	var walls := StaticBody3D.new()
	walls.name = "ForestWalls"
	walls.collision_layer = LAYER_PROPS
	walls.collision_mask = 0
	_attach(_region, walls)
	walls.add_to_group(NAVMESH_GROUP, true)

	var half := Layout.MAP_HALF_M
	var cells := int(round(half * 2.0 / WALL_CELL_M))
	var solid: Array[PackedByteArray] = []
	for row in range(cells):
		var line := PackedByteArray()
		line.resize(cells)
		for col in range(cells):
			var centre := Vector2(-half + (float(col) + 0.5) * WALL_CELL_M, -half + (float(row) + 0.5) * WALL_CELL_M)
			line[col] = 1 if Layout.distance_to_open(centre) > 0.0 else 0
		solid.append(line)

	for row in range(cells):
		var col := 0
		while col < cells:
			if solid[row][col] == 0:
				col += 1
				continue
			var width := 1
			while col + width < cells and solid[row][col + width] == 1:
				width += 1
			var height := 1
			while row + height < cells and _row_span_solid(solid[row + height], col, width):
				height += 1
			for r in range(row, row + height):
				for c in range(col, col + width):
					solid[r][c] = 0
			var box := BoxShape3D.new()
			box.size = Vector3(float(width) * WALL_CELL_M, WALL_HEIGHT_M, float(height) * WALL_CELL_M)
			var shape := CollisionShape3D.new()
			shape.name = "Wall%03d" % _wall_box_count
			shape.shape = box
			shape.position = Vector3(-half + (float(col) + float(width) * 0.5) * WALL_CELL_M, WALL_HEIGHT_M * 0.5,
				-half + (float(row) + float(height) * 0.5) * WALL_CELL_M)
			_attach(walls, shape)
			_wall_box_count += 1
			col += width


func _row_span_solid(line: PackedByteArray, col: int, width: int) -> bool:
	for c in range(col, col + width):
		if line[c] == 0:
			return false
	return true


# --- Structures: rocks, ruins, standing stones, crates, tents, campfire -------------

func _add_structures() -> void:
	var props := Node3D.new()
	props.name = "Props"
	_attach(_region, props)

	# Start glade: a few boulders at the edges.
	for rock: Array in [[Vector2(-26.0, 30.0), 0.9], [Vector2(-43.5, 32.0), 1.1], [Vector2(-27.0, 42.5), 0.7],
			[Vector2(-40.0, -13.0), 1.0], [Vector2(-24.5, -12.5), 0.8], [Vector2(-29.0, -20.0), 1.2],
			[Vector2(-8.0, -38.5), 0.9], [Vector2(9.0, -29.5), 0.7], [Vector2(20.5, 18.0), 0.9]]:
		_add_rock(props, rock[0], rock[1])

	# Bandit camp.
	var campfire: Node3D = _new_scripted(StaticBody3D.new(), CAMPFIRE_SCRIPT_PATH)
	campfire.name = "Campfire"
	campfire.position = _at(Vector2(6.0, 12.0))
	_attach(props, campfire)
	_keep(Vector2(6.0, 12.0), 1.5)
	_add_tent(props, "TentA", Vector2(0.5, 4.5), 35.0)
	_add_tent(props, "TentB", Vector2(13.0, 6.0), -30.0)
	for crate: Array in [[Vector2(10.5, 3.6), 10.0], [Vector2(11.4, 3.2), -8.0], [Vector2(15.8, 10.2), 25.0],
			[Vector2(-2.0, 7.5), 0.0]]:
		_add_crate(props, crate[0], crate[1])

	# Old ruins: broken walls and pillars, the stealth blockers.
	_add_ruin_wall(props, "RuinWallA", Vector2(-9.0, -36.0), Vector2(-3.0, -36.0), 2.4)
	_add_ruin_wall(props, "RuinWallB", Vector2(4.0, -35.0), Vector2(4.0, -27.0), 1.8)
	_add_ruin_wall(props, "RuinWallC", Vector2(-10.0, -26.0), Vector2(-10.0, -31.0), 2.1)
	_add_ruin_wall(props, "RuinWallD", Vector2(-6.5, -22.5), Vector2(-3.5, -22.5), 1.4)
	for pillar: Array in [[Vector2(-6.5, -27.0), 3.0], [Vector2(-0.5, -24.5), 2.6], [Vector2(-7.0, -33.5), 3.2],
			[Vector2(6.5, -24.0), 1.2], [Vector2(-4.0, -38.5), 2.2], [Vector2(7.0, -31.0), 0.9]]:
		_add_pillar(props, pillar[0], pillar[1])

	# Warden's ring: standing stones every 30 degrees, open to the west.
	var boss_center := Vector2(36.0, -32.0)
	for i in range(12):
		var angle := deg_to_rad(30.0 * float(i))
		if absf(angle - PI) < 0.1:
			continue
		var at := boss_center + Vector2(cos(angle), sin(angle)) * 8.5
		_add_standing_stone(props, "StandingStone%02d" % i, at, boss_center)


func _add_rock(parent: Node3D, at: Vector2, radius: float) -> void:
	var body := _new_prop_body("Rock", at)
	_attach(parent, body)
	var mesh := SphereMesh.new()
	mesh.radius = 0.5
	mesh.height = 1.0
	mesh.radial_segments = 6
	mesh.rings = 3
	var visual := MeshInstance3D.new()
	visual.name = "Mesh"
	visual.mesh = mesh
	visual.material_override = _material(&"rock", Color(0.4, 0.4, 0.38))
	visual.scale = Vector3(radius * 2.2, radius * 1.3, radius * 1.8)
	visual.position = Vector3(0.0, radius * 0.45, 0.0)
	visual.rotation_degrees = Vector3(_rng.randf_range(-8.0, 8.0), _rng.randf_range(0.0, 360.0), 0.0)
	_attach(body, visual)
	var shape := CylinderShape3D.new()
	shape.radius = radius * 0.95
	shape.height = radius * 1.2
	_attach_shape(body, shape, Vector3(0.0, radius * 0.6, 0.0))
	_keep(at, radius + 1.0)


func _add_tent(parent: Node3D, tent_name: String, at: Vector2, yaw_degrees: float) -> void:
	var body := _new_prop_body(tent_name, at)
	body.rotation_degrees = Vector3(0.0, yaw_degrees, 0.0)
	_attach(parent, body)
	var mesh := PrismMesh.new()
	mesh.size = Vector3(2.4, 1.7, 2.8)
	var visual := MeshInstance3D.new()
	visual.name = "Mesh"
	visual.mesh = mesh
	visual.material_override = _material(&"cloth", Color(0.55, 0.46, 0.32))
	visual.position = Vector3(0.0, 0.85, 0.0)
	_attach(body, visual)
	var box := BoxShape3D.new()
	box.size = Vector3(2.2, 1.6, 2.7)
	_attach_shape(body, box, Vector3(0.0, 0.8, 0.0))
	_keep(at, 2.4)


func _add_crate(parent: Node3D, at: Vector2, yaw_degrees: float) -> void:
	var crate := _instance(load(CRATE_SCENE_PATH) as PackedScene)
	crate.name = "Crate"
	crate.set_script(load(PROP_SCRIPT_PATH))
	crate.position = _at(at)
	crate.rotation_degrees = Vector3(0.0, yaw_degrees, 0.0)
	_attach(parent, crate)
	_keep(at, 1.2)


func _add_ruin_wall(parent: Node3D, wall_name: String, from: Vector2, to: Vector2, height: float) -> void:
	var length := from.distance_to(to)
	var mid := (from + to) * 0.5
	var direction := GroundMath.from_ground(to - from).normalized()
	var body := _new_prop_body(wall_name, mid)
	body.rotation.y = GroundMath.yaw_facing(direction.cross(Vector3.UP))
	_attach(parent, body)
	# Local X runs along the wall. The top is broken into three uneven blocks.
	var thickness := 0.7
	var box := BoxShape3D.new()
	box.size = Vector3(length, height, thickness)
	_attach_shape(body, box, Vector3(0.0, height * 0.5, 0.0))
	var segments := 3
	for i in range(segments):
		var segment_height := height * _rng.randf_range(0.72, 1.0)
		var mesh := BoxMesh.new()
		mesh.size = Vector3(length / float(segments) + 0.02, segment_height, thickness)
		var visual := MeshInstance3D.new()
		visual.name = "Block%d" % i
		visual.mesh = mesh
		visual.material_override = _material(&"ruin", Color(0.5, 0.5, 0.46))
		visual.position = Vector3(-length * 0.5 + (float(i) + 0.5) * length / float(segments), segment_height * 0.5, 0.0)
		_attach(body, visual)
	var moss := BoxMesh.new()
	moss.size = Vector3(length * 0.6, 0.12, thickness + 0.06)
	var moss_visual := MeshInstance3D.new()
	moss_visual.name = "Moss"
	moss_visual.mesh = moss
	moss_visual.material_override = _material(&"moss", Color(0.26, 0.38, 0.2))
	moss_visual.position = Vector3(-length * 0.1, 0.06, 0.0)
	_attach(body, moss_visual)
	for i in range(int(ceil(length)) + 1):
		var t := float(i) / maxf(1.0, ceil(length))
		_keep(from.lerp(to, t), 1.2)


func _add_pillar(parent: Node3D, at: Vector2, height: float) -> void:
	var body := _new_prop_body("Pillar", at)
	_attach(parent, body)
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.4
	mesh.bottom_radius = 0.46
	mesh.height = height
	mesh.radial_segments = 8
	mesh.rings = 1
	var visual := MeshInstance3D.new()
	visual.name = "Mesh"
	visual.mesh = mesh
	visual.material_override = _material(&"ruin", Color(0.5, 0.5, 0.46))
	visual.position = Vector3(0.0, height * 0.5, 0.0)
	visual.rotation_degrees = Vector3(_rng.randf_range(-3.0, 3.0), 0.0, _rng.randf_range(-3.0, 3.0))
	_attach(body, visual)
	var plinth := BoxMesh.new()
	plinth.size = Vector3(1.1, 0.3, 1.1)
	var plinth_visual := MeshInstance3D.new()
	plinth_visual.name = "Plinth"
	plinth_visual.mesh = plinth
	plinth_visual.material_override = _material(&"ruin_dark", Color(0.38, 0.38, 0.36))
	plinth_visual.position = Vector3(0.0, 0.15, 0.0)
	_attach(body, plinth_visual)
	var shape := CylinderShape3D.new()
	shape.radius = 0.55
	shape.height = height
	_attach_shape(body, shape, Vector3(0.0, height * 0.5, 0.0))
	_keep(at, 1.4)


func _add_standing_stone(parent: Node3D, stone_name: String, at: Vector2, center: Vector2) -> void:
	var body := _new_prop_body(stone_name, at)
	body.rotation.y = GroundMath.yaw_facing(GroundMath.from_ground(center - at).normalized())
	_attach(parent, body)
	var height := _rng.randf_range(2.4, 3.2)
	var mesh := BoxMesh.new()
	mesh.size = Vector3(1.0, height, 0.7)
	var visual := MeshInstance3D.new()
	visual.name = "Mesh"
	visual.mesh = mesh
	visual.material_override = _material(&"standing_stone", Color(0.34, 0.36, 0.38))
	visual.position = Vector3(0.0, height * 0.5, 0.0)
	visual.rotation_degrees = Vector3(_rng.randf_range(-4.0, 4.0), 0.0, _rng.randf_range(-4.0, 4.0))
	_attach(body, visual)
	var glyph := BoxMesh.new()
	glyph.size = Vector3(0.14, 0.6, 0.02)
	var glyph_visual := MeshInstance3D.new()
	glyph_visual.name = "Glyph"
	glyph_visual.mesh = glyph
	glyph_visual.material_override = _glow(&"warden_glyph", Color(0.55, 1.0, 0.45, 1.0))
	glyph_visual.position = Vector3(0.0, height * 0.6, -0.37)
	_attach(body, glyph_visual)
	var box := BoxShape3D.new()
	box.size = Vector3(1.0, height, 0.7)
	_attach_shape(body, box, Vector3(0.0, height * 0.5, 0.0))
	_keep(at, 1.6)


# --- Interactables: waystones, chests, barrels ----------------------------------------

func _add_interactables() -> void:
	var waystones := Node3D.new()
	waystones.name = "Waystones"
	_attach(_region, waystones)
	# A ring: start -> camp -> gate -> start (see docs/wilds-map.md).
	_add_waystone(waystones, "WaystoneStart", &"start", &"camp", "Start Glade",
		Vector2(-42.0, 38.0), Vector2(-34.0, 34.0), true)
	_add_waystone(waystones, "WaystoneCamp", &"camp", &"gate", "Bandit Camp",
		Vector2(-1.5, 17.5), Vector2(-14.0, 30.0), false)
	_add_waystone(waystones, "WaystoneGate", &"gate", &"start", "Warden's Gate",
		Vector2(16.0, -34.0), Vector2(16.0, -31.0), false)

	var chests := Node3D.new()
	chests.name = "Chests"
	_attach(_region, chests)
	_add_chest(chests, "ChestStart", Vector2(-28.0, 40.0), Vector2(-34.0, 34.0), 2, false, true)
	_add_chest(chests, "ChestCamp", Vector2(13.0, 17.5), Vector2(6.0, 12.0), 3, true, false)
	_add_chest(chests, "ChestRuins", Vector2(6.0, -36.5), Vector2(-2.0, -30.0), 2, true, true)
	_add_chest(chests, "ChestWarden", Vector2(42.5, -32.0), Vector2(36.0, -32.0), 4, true, true)

	var barrels := Node3D.new()
	barrels.name = "Barrels"
	_attach(_region, barrels)
	for at: Vector2 in [Vector2(3.2, 8.2), Vector2(2.3, 9.0), Vector2(10.4, 12.8), Vector2(7.4, 16.2),
			Vector2(31.0, -28.5), Vector2(31.5, -35.5)]:
		var barrel: Node3D = _new_scripted(StaticBody3D.new(), BARREL_SCRIPT_PATH)
		barrel.name = "ExplosiveBarrel"
		barrel.position = _at(at)
		_attach(barrels, barrel)
		_keep(at, 1.0)


func _add_waystone(parent: Node3D, node_name: String, id: StringName, destination: StringName,
		display_name: String, at: Vector2, face: Vector2, attuned: bool) -> void:
	var stone: Node3D = _new_scripted(StaticBody3D.new(), WAYSTONE_SCRIPT_PATH)
	stone.name = node_name
	stone.position = _at(at)
	stone.rotation.y = GroundMath.yaw_facing(GroundMath.from_ground(face - at).normalized())
	stone.set("waystone_id", id)
	stone.set("destination_id", destination)
	stone.set("display_name", display_name)
	stone.set("start_attuned", attuned)
	_attach(parent, stone)
	_keep(at, 2.0)
	var arrival := at + (face - at).normalized() * 1.5
	_keep(arrival, 1.2)


func _add_chest(parent: Node3D, node_name: String, at: Vector2, face: Vector2, count: int,
		gear: bool, potion: bool) -> void:
	var chest: Node3D = _new_scripted(StaticBody3D.new(), CHEST_SCRIPT_PATH)
	chest.name = node_name
	chest.position = _at(at)
	chest.rotation.y = GroundMath.yaw_facing(GroundMath.from_ground(face - at).normalized())
	chest.set("item_count", count)
	chest.set("guaranteed_gear", gear)
	chest.set("include_potion", potion)
	_attach(parent, chest)
	_keep(at, 1.8)


# --- Trees ----------------------------------------------------------------------------------

## Real trees along the forest edge: jittered candidates in the edge band,
## visited in random order, kept when far enough from every other tree and
## from the hand-placed props.
func _add_edge_trees() -> void:
	var trees := Node3D.new()
	trees.name = "Trees"
	_attach(_region, trees)
	var tree_scene := load(TREE_SCENE_PATH) as PackedScene
	var prop_script := load(PROP_SCRIPT_PATH)

	var half := Layout.MAP_HALF_M
	var candidates: Array[Vector2] = []
	var steps := int(half * 2.0 / EDGE_TREE_CANDIDATE_STEP_M)
	for row in range(steps):
		for col in range(steps):
			var at := Vector2(-half + (float(col) + _rng.randf()) * EDGE_TREE_CANDIDATE_STEP_M,
				-half + (float(row) + _rng.randf()) * EDGE_TREE_CANDIDATE_STEP_M)
			var d := Layout.distance_to_open(at)
			if d >= EDGE_TREE_MIN_M and d <= EDGE_TREE_MAX_M:
				candidates.append(at)
	for i in range(candidates.size() - 1, 0, -1):
		var j := _rng.randi_range(0, i)
		var swap := candidates[i]
		candidates[i] = candidates[j]
		candidates[j] = swap

	# Spatial hash so the spacing test stays cheap.
	var buckets: Dictionary = {}
	for at in candidates:
		if _blocked_by_keep_out(at):
			continue
		var cell := Vector2i(floori(at.x / EDGE_TREE_SPACING_M), floori(at.y / EDGE_TREE_SPACING_M))
		var crowded := false
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				var neighbours: Array = buckets.get(cell + Vector2i(dx, dy), [])
				for other: Vector2 in neighbours:
					if other.distance_to(at) < EDGE_TREE_SPACING_M:
						crowded = true
						break
				if crowded:
					break
			if crowded:
				break
		if crowded:
			continue
		var bucket: Array = buckets.get(cell, [])
		bucket.append(at)
		buckets[cell] = bucket

		var tree := _instance(tree_scene)
		tree.name = "Tree%04d" % _tree_count
		tree.set_script(prop_script)
		tree.position = _at(at)
		tree.rotation.y = _rng.randf_range(0.0, TAU)
		var tree_scale := _rng.randf_range(0.9, 1.25)
		tree.scale = Vector3(tree_scale, tree_scale * _rng.randf_range(0.95, 1.1), tree_scale)
		_attach(trees, tree)
		_tree_count += 1


func _blocked_by_keep_out(at: Vector2) -> bool:
	for entry in _keep_out:
		var point: Vector2 = entry["at"]
		var radius: float = entry["radius"]
		if point.distance_to(at) < radius:
			return true
	return false


# --- Navmesh ----------------------------------------------------------------------------------

func _bake_navmesh() -> bool:
	var mesh := _region.navigation_mesh
	_region.bake_navigation_mesh(false)
	var raw_count := mesh.get_polygon_count()
	if raw_count <= 0:
		push_error("build_wilds_3d: the navmesh bake produced no polygons")
		return false
	var kept := _prune_navmesh(mesh, GroundMath.from_ground(SPAWN))
	print("[build_wilds_3d] navmesh baked %d polygons, kept %d connected to the spawn" % [raw_count, kept])
	if kept <= 0:
		push_error("build_wilds_3d: no navmesh polygon connected to the spawn")
		return false
	var err := ResourceSaver.save(mesh, NAVMESH_PATH)
	if err != OK:
		push_error("build_wilds_3d: saving %s failed (%d)" % [NAVMESH_PATH, err])
		return false
	# Reference the saved file from the scene instead of embedding a copy.
	mesh.take_over_path(NAVMESH_PATH)
	return true


## Drops the polygons above the floor (wall tops) and every polygon not
## connected, edge to edge, to the one under `seed_point`. Returns the number
## of polygons kept.
func _prune_navmesh(mesh: NavigationMesh, seed_point: Vector3) -> int:
	var vertices := mesh.get_vertices()
	var polygons: Array[PackedInt32Array] = []
	for i in range(mesh.get_polygon_count()):
		polygons.append(mesh.get_polygon(i))

	var floor_polygon := PackedByteArray()
	floor_polygon.resize(polygons.size())
	var edge_owners: Dictionary = {}
	var seed_index := -1
	var seed_distance := INF
	for i in range(polygons.size()):
		var polygon := polygons[i]
		var on_floor := true
		var centroid := Vector3.ZERO
		for index in polygon:
			if vertices[index].y > NAVMESH_FLOOR_MAX_Y:
				on_floor = false
			centroid += vertices[index]
		floor_polygon[i] = 1 if on_floor else 0
		if not on_floor:
			continue
		centroid /= float(polygon.size())
		var d := GroundMath.ground_distance(centroid, seed_point)
		if d < seed_distance:
			seed_distance = d
			seed_index = i
		for k in range(polygon.size()):
			var key := _edge_key(vertices[polygon[k]], vertices[polygon[(k + 1) % polygon.size()]])
			var owners: Array = edge_owners.get(key, [])
			owners.append(i)
			edge_owners[key] = owners
	if seed_index < 0:
		return 0

	var reached := PackedByteArray()
	reached.resize(polygons.size())
	var queue: Array[int] = [seed_index]
	reached[seed_index] = 1
	while not queue.is_empty():
		var current: int = queue.pop_back()
		var polygon := polygons[current]
		for k in range(polygon.size()):
			var key := _edge_key(vertices[polygon[k]], vertices[polygon[(k + 1) % polygon.size()]])
			for other: int in edge_owners.get(key, []):
				if reached[other] == 0 and floor_polygon[other] == 1:
					reached[other] = 1
					queue.append(other)

	var remap: Dictionary = {}
	var new_vertices := PackedVector3Array()
	var new_polygons: Array[PackedInt32Array] = []
	for i in range(polygons.size()):
		if reached[i] == 0:
			continue
		var mapped := PackedInt32Array()
		for index in polygons[i]:
			if not remap.has(index):
				remap[index] = new_vertices.size()
				new_vertices.append(vertices[index])
			mapped.append(int(remap[index]))
		new_polygons.append(mapped)
	mesh.clear_polygons()
	mesh.vertices = new_vertices
	for polygon in new_polygons:
		mesh.add_polygon(polygon)
	return new_polygons.size()


func _edge_key(a: Vector3, b: Vector3) -> String:
	var ka := "%d,%d,%d" % [roundi(a.x * 100.0), roundi(a.y * 100.0), roundi(a.z * 100.0)]
	var kb := "%d,%d,%d" % [roundi(b.x * 100.0), roundi(b.y * 100.0), roundi(b.z * 100.0)]
	return ka + "|" + kb if ka < kb else kb + "|" + ka


# --- After the bake: visuals, lights, cover, traps, actors --------------------------------

func _add_visuals() -> void:
	var ground_visual: Node3D = _new_scripted(MeshInstance3D.new(), GROUND_SCRIPT_PATH)
	ground_visual.name = "GroundVisual"
	_attach(_root, ground_visual)
	var forest: Node3D = _new_scripted(MultiMeshInstance3D.new(), FOREST_SCRIPT_PATH)
	forest.name = "DeepForest"
	_attach(_root, forest)


func _add_lights() -> void:
	var lights := Node3D.new()
	lights.name = "Lights"
	_attach(_root, lights)
	_add_light(lights, "StartLight", Vector3(-34.0, 4.0, 34.0), Color(1.0, 0.86, 0.62), 1.2, 16.0)
	_add_light(lights, "DenLight", Vector3(-32.0, 4.0, -10.0), Color(0.55, 0.62, 0.95), 1.0, 15.0)
	_add_light(lights, "CampLantern", Vector3(12.5, 2.2, 16.8), Color(1.0, 0.7, 0.4), 1.0, 6.0)
	_add_light(lights, "RuinsTorchA", Vector3(-6.5, 3.4, -27.0), Color(0.4, 0.95, 0.85), 1.4, 9.0)
	_add_light(lights, "RuinsTorchB", Vector3(-7.0, 3.6, -33.5), Color(0.4, 0.95, 0.85), 1.4, 9.0)
	_add_light(lights, "RuinsTorchC", Vector3(4.0, 2.4, -30.0), Color(0.4, 0.95, 0.85), 1.0, 7.0)
	_add_light(lights, "WardenLight", Vector3(36.0, 4.5, -32.0), Color(0.55, 1.0, 0.5), 2.2, 15.0)
	_add_light(lights, "GateLight", Vector3(16.0, 3.0, -31.0), Color(0.55, 0.8, 1.0), 1.0, 8.0)


func _add_light(parent: Node3D, light_name: String, at: Vector3, color: Color, energy: float, light_range: float) -> void:
	var light := OmniLight3D.new()
	light.name = light_name
	light.position = at
	light.light_color = color
	light.light_energy = energy
	light.omni_range = light_range
	_attach(parent, light)


func _add_cover() -> void:
	var cover := Node3D.new()
	cover.name = "Cover"
	_attach(_root, cover)
	var zones := [
		# Wolf den: bushes all around the edge and tall grass in the south mouth.
		["DenBushW", Vector2(-40.5, -5.0), Vector3(3.5, 1.4, 4.0), 0],
		["DenBushE", Vector2(-23.5, -5.0), Vector3(3.5, 1.4, 4.0), 0],
		["DenBushSW", Vector2(-40.5, -16.0), Vector3(3.0, 1.4, 3.5), 0],
		["DenBushNE", Vector2(-24.0, -17.5), Vector3(3.5, 1.4, 3.0), 0],
		["DenBushN", Vector2(-32.5, -20.0), Vector3(4.0, 1.4, 2.5), 0],
		["DenGrassMouth", Vector2(-34.5, 1.5), Vector3(4.0, 1.4, 3.0), 1],
		# Bandit camp: tall grass to creep up on the barrels.
		["CampGrassW", Vector2(-2.0, 11.0), Vector3(3.0, 1.4, 4.0), 1],
		["CampGrassS", Vector2(8.5, 21.0), Vector3(4.0, 1.4, 2.5), 1],
		# Ruins: grass by the west and south entrances.
		["RuinsGrassW", Vector2(-12.0, -23.0), Vector3(3.0, 1.4, 3.0), 1],
		["RuinsGrassS", Vector2(3.5, -19.5), Vector3(3.0, 1.4, 2.5), 1],
	]
	var index := 0
	for zone: Array in zones:
		var node: Node3D = _new_scripted(Area3D.new(), HIDE_ZONE_SCRIPT_PATH)
		node.name = zone[0]
		node.position = _at(zone[1])
		node.set("size", zone[2])
		node.set("style", zone[3])
		node.set("visual_seed", 100 + index)
		_attach(cover, node)
		index += 1


func _add_traps() -> void:
	var traps := Node3D.new()
	traps.name = "Traps"
	_attach(_root, traps)
	# Start glade: a visible line between the spawn and the wolves, to teach
	# that turn-mode enemies walking over a trap get caught.
	for x: float in [-36.5, -35.0, -33.5, -32.0]:
		_add_trap(traps, "TeachTrap", Vector2(x, 31.0), true)
	# Ruins: hidden at the entrances and in front of the chest.
	for at: Vector2 in [Vector2(1.0, -19.0), Vector2(-1.5, -20.5), Vector2(-12.5, -27.2), Vector2(5.2, -35.2)]:
		_add_trap(traps, "RuinsTrap", at, false)
	# Warden's ring: hidden in the gap between the stones.
	for at: Vector2 in [Vector2(27.5, -30.8), Vector2(28.0, -33.2)]:
		_add_trap(traps, "RingTrap", at, false)


func _add_trap(parent: Node3D, trap_name: String, at: Vector2, revealed: bool) -> void:
	var trap: Node3D = _new_scripted(Area3D.new(), TRAP_SCRIPT_PATH)
	trap.name = trap_name
	trap.position = _at(at)
	trap.set("start_revealed", revealed)
	_attach(parent, trap)


func _add_enemies() -> void:
	var loaded: Dictionary = {}
	for kind: StringName in ENEMY_SCENES:
		var path: String = ENEMY_SCENES[kind]
		if ResourceLoader.exists(path):
			loaded[kind] = load(path)
		else:
			loaded[kind] = load(ENEMY_SCENES[FALLBACK_ENEMY])
			if kind != FALLBACK_ENEMY:
				_warnings.append("%s missing (%s): the wolf stands in; re-run after track B merges" % [kind, path])

	for camp: StringName in CAMPS:
		var container := Node3D.new()
		container.name = "Enemies_%s" % String(camp).capitalize()
		container.set_meta(&"camp_id", camp)
		container.set_meta(&"camp_center", Layout.clearing_center(camp))
		_attach(_root, container)
		var index := 0
		for entry: Dictionary in CAMPS[camp]:
			index += 1
			var kind: StringName = entry["kind"]
			var scene := loaded[kind] as PackedScene
			var enemy := _instance(scene)
			enemy.name = "%s_%d" % [String(kind).to_pascal_case(), index]
			var at: Vector2 = entry["at"]
			var face: Vector2 = entry["face"]
			enemy.position = _at(at)
			enemy.rotation.y = GroundMath.yaw_facing(GroundMath.from_ground(face - at).normalized())
			enemy.set_meta(&"enemy_kind", kind)
			var wander: float = entry["wander"]
			if wander > 0.0 and "wander_radius" in enemy:
				enemy.set("wander_radius", wander)
			_attach(container, enemy)
			_enemy_count += 1


func _add_player_and_camera() -> void:
	var rig := _instance(load(CAMERA_RIG_SCENE_PATH) as PackedScene)
	rig.name = "CameraRig"
	_attach(_root, rig)

	var player := _instance(load(PLAYER_SCENE_PATH) as PackedScene)
	player.name = "Player"
	player.position = _at(SPAWN)
	_attach(_root, player)

	var spawn := Node3D.new()
	spawn.name = "Spawn_default"
	spawn.position = _at(SPAWN)
	_attach(_root, spawn)


# --- Helpers ----------------------------------------------------------------------------------

func _at(ground: Vector2) -> Vector3:
	return GroundMath.from_ground(ground)


## Instances scene with its edit state, so PackedScene.pack stores only
## what this builder changes on the instance (position, script, exports) and
## later edits to the source scene (track B tuning an enemy) still come through.
func _instance(scene: PackedScene) -> Node3D:
	return scene.instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE) as Node3D


func _keep(at: Vector2, radius: float) -> void:
	_keep_out.append({"at": at, "radius": radius})


func _new_scripted(node: Node, script_path: String) -> Node:
	node.set_script(load(script_path))
	return node


func _new_prop_body(body_name: String, at: Vector2) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = body_name
	body.collision_layer = LAYER_PROPS
	body.collision_mask = 0
	body.position = _at(at)
	body.add_to_group(NAVMESH_GROUP, true)
	return body


func _attach_shape(body: Node3D, shape: Shape3D, offset: Vector3) -> void:
	var node := CollisionShape3D.new()
	node.name = "CollisionShape3D"
	node.shape = shape
	node.position = offset
	_attach(body, node)


func _material(key: StringName, color: Color) -> StandardMaterial3D:
	if not _materials.has(key):
		var material := StandardMaterial3D.new()
		material.albedo_color = color
		material.roughness = 0.92
		_materials[key] = material
	return _materials[key]


func _glow(key: StringName, color: Color) -> StandardMaterial3D:
	if not _materials.has(key):
		var material := StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.albedo_color = color
		_materials[key] = material
	return _materials[key]


## Adds `node` under `parent` and marks it as part of the level so
## PackedScene.pack writes it. An instanced sub-scene keeps its link: only its
## root gets the owner.
func _attach(parent: Node, node: Node) -> void:
	parent.add_child(node, true)
	node.owner = _root
