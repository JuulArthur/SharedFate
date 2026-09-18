extends SceneTree

# Builds `scenes/black_woods.tscn` — the Black Woods, a large forest map for the
# story's first shard hunt. The scene runs on `main.gd`, so turn combat, the
# three souls, reactions and loot all work exactly as on the hub map.
#
# Run from the project root (the editor may be open; re-import picks it up):
#   /Applications/Godot.app/Contents/MacOS/Godot --headless --path . --script tools/build_black_woods.gd
#
# The map is generated rather than hand-painted so it is reproducible and
# tweakable: change the constants below, re-run, and the ground, navmesh and
# every tree, wolf and chest are rebuilt. Hand-edit the result in the editor if
# you like — just know a re-run overwrites the file.
#
# Layout: an organic blob of forest floor walled in by trees, with five
# clearings — the entrance (south), a big central glade, the pool (north) and
# smaller east and west clearings — joined by dirt paths. Copses of trees break
# the interior into corridors. Wolf packs hold the pool, east and west
# clearings; the chest sits by the pool.

const OUTPUT_PATH := "res://scenes/black_woods.tscn"
const SPRITESHEET_PATH := "res://assets/isometric tileset/spritesheet.png"
const MAIN_SCRIPT_PATH := "res://scripts/main.gd"
const HUB_SCENE_PATH := "res://scenes/main.tscn"

const TREE_SCENE := "res://scenes/forest_tree.tscn"
const WOLF_SCENE := "res://scenes/wolf.tscn"
const CHEST_SCENE := "res://scenes/treasure_chest.tscn"
const PLAYER_SCENE := "res://scenes/player.tscn"
const TRANSITION_SCENE := "res://scenes/level_transition.tscn"

const SEED := 7
# The hub map is 35 x 53 of these cells; this is roughly four times the floor.
const MAP_COLUMNS := 64
const MAP_ROWS := 104
const TILE_SIZE := Vector2i(32, 16)
const SOURCE_ID := 0

# Atlas coordinates (column, row) in the spritesheet, chosen by sampling each
# tile's colour and opacity. Block tiles (~53% opaque) are ground; the rest are
# objects on a transparent background and go on the Decor layer.
const GRASS_PLAIN := [Vector2i(5, 2), Vector2i(6, 2)]
const GRASS_TUFTS := [Vector2i(7, 2), Vector2i(8, 2), Vector2i(9, 2), Vector2i(10, 2), Vector2i(0, 3), Vector2i(1, 3), Vector2i(2, 3)]
const GRASS_BUSHY := [Vector2i(3, 3), Vector2i(4, 3), Vector2i(5, 3), Vector2i(6, 3), Vector2i(7, 3)]
const DIRT_PLAIN := [Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0)]
const DIRT_WORN := [Vector2i(0, 1), Vector2i(1, 1), Vector2i(2, 1)]
const WATER := Vector2i(0, 8)
const DECOR_STUMPS := [Vector2i(3, 4), Vector2i(4, 4), Vector2i(5, 4), Vector2i(6, 4)]
const DECOR_ROCKS := [Vector2i(1, 5), Vector2i(2, 5), Vector2i(4, 5), Vector2i(7, 5), Vector2i(9, 5)]
const DECOR_PLANTS := [Vector2i(9, 3), Vector2i(10, 3), Vector2i(0, 4), Vector2i(1, 4)]

# Open ground, in cells, with a radius in world pixels kept clear of trees. The
# glade is oversized so `main.gd`'s default spawn (map centre, six cells west)
# lands in the open when the scene is run on its own.
const CLEARINGS := {
	"entrance": {"cell": Vector2i(32, 92), "radius": 130.0},
	"glade": {"cell": Vector2i(32, 52), "radius": 215.0},
	"pool": {"cell": Vector2i(32, 14), "radius": 170.0},
	"east": {"cell": Vector2i(52, 40), "radius": 120.0},
	"west": {"cell": Vector2i(12, 62), "radius": 120.0},
}
const PATHS := [["entrance", "glade"], ["glade", "pool"], ["glade", "east"], ["glade", "west"]]
const PATH_HALF_WIDTH := 22.0      # dirt underfoot
const CORRIDOR_HALF_WIDTH := 46.0  # kept free of trees (agent radius is 12)
const POOL_OFFSET := Vector2(90, 10)
const POOL_RADII := Vector2(72, 40)

const EDGE_BAND_PIXELS := 56.0
const EDGE_TREE_SPACING := 28.0
const INNER_TREE_SPACING := 31.0
const COPSE_COUNT := 14
const COPSE_RADIUS := 80.0
const COPSE_TREE_SPACING := 30.0
const DECOR_CHANCE := 0.05
const DECOR_TREE_CLEARANCE := 26.0

# Wolf positions as offsets from the clearing centre. The pool pack sits on the
# north side of its clearing so its aggro range (see wolf.tscn) doesn't reach
# the glade, which doubles as the default spawn.
const WOLF_PACKS := {
	"pool": [Vector2(-80, -20), Vector2(-30, 10), Vector2(20, -10)],
	"east": [Vector2(-30, -20), Vector2(30, 20)],
	"west": [Vector2(-40, 10), Vector2(10, -30), Vector2(35, 30)],
}
const CHEST_OFFSET := Vector2(-120, -30)  # from the pool clearing centre
const EXIT_OFFSET := Vector2(0, 90)       # from the entrance spawn
const EXIT_GAP_HALF_WIDTH := 60.0
const HUB_RETURN_SPAWN: StringName = &"from_woods"

const NAV_AGENT_RADIUS := 12.0
const NAVMESH_GROUP: StringName = &"navmesh_source"
const WOODS_LIGHT := Color(0.05, 0.06, 0.10, 1.0)

var _rng := RandomNumberGenerator.new()
var _shape_noise := FastNoiseLite.new()
var _detail_noise := FastNoiseLite.new()
var _scene_root: Node2D
var _ground: TileMapLayer
var _inside: Dictionary = {}       # Vector2i -> true for forest-floor cells
var _water_cells: Dictionary = {}  # Vector2i -> true
var _tree_positions: Array[Vector2] = []


func _initialize() -> void:
	_build()


func _build() -> void:
	_rng.seed = SEED
	_shape_noise.seed = SEED
	_shape_noise.frequency = 0.045
	_detail_noise.seed = SEED + 1
	_detail_noise.frequency = 0.18

	_scene_root = Node2D.new()
	_scene_root.name = "BlackWoods"
	_scene_root.y_sort_enabled = true

	var tile_set := _build_tile_set()

	var canvas_modulate := CanvasModulate.new()
	canvas_modulate.name = "CanvasModulate"
	canvas_modulate.color = WOODS_LIGHT
	_attach(_scene_root, canvas_modulate)

	var camera := Camera2D.new()
	camera.name = "Camera2D"
	_attach(_scene_root, camera)

	# `main.gd` reads the ground layer by this name for navigation, the turn
	# meter, camera framing and the default spawn.
	_ground = _make_layer("MyCustomBackground", tile_set, 0)
	_attach(_scene_root, _ground)

	var decor := _make_layer("Decor", tile_set, 1)
	_attach(_scene_root, decor)

	var nav_region := NavigationRegion2D.new()
	nav_region.name = "NavigationRegion2D"
	_attach(_scene_root, nav_region)

	var water := _make_layer("Water", tile_set, 0)
	_attach(nav_region, water)
	water.add_to_group(NAVMESH_GROUP, true)

	# Solid, invisible tiles over everything that isn't forest floor: they keep
	# the player and the navmesh inside the blob even where the tree wall has a gap.
	var void_layer := _make_layer("Void", tile_set, 0)
	void_layer.visible = false
	_attach(nav_region, void_layer)
	void_layer.add_to_group(NAVMESH_GROUP, true)

	var trees := Node2D.new()
	trees.name = "Trees"
	trees.y_sort_enabled = true
	_attach(nav_region, trees)
	trees.add_to_group(NAVMESH_GROUP, true)

	_carve_floor()
	_paint_ground(void_layer)
	_paint_water(water)
	_plant_edge_trees(trees)
	_plant_copses(trees)
	_paint_decor(decor)

	await _bake_navigation(nav_region)

	# Trees drew their own art while in the tree; drop it so the scene file
	# doesn't embed a copy (the tree script regenerates it on load).
	for tree in trees.get_children():
		var sprite := tree.get_node_or_null("Sprite2D") as Sprite2D
		if sprite != null:
			sprite.texture = null

	_place_actors()

	_scene_root.set_script(load(MAIN_SCRIPT_PATH))
	_scene_root.set("spawn_test_loot", false)
	_scene_root.set("runtime_canvas_modulate_color", WOODS_LIGHT)
	_scene_root.set("story_chapter_id", StoryLibrary.BLACK_WOODS)

	var packed := PackedScene.new()
	var pack_error := packed.pack(_scene_root)
	if pack_error != OK:
		push_error("build_black_woods: pack failed (%d)" % pack_error)
		quit(1)
		return
	var save_error := ResourceSaver.save(packed, OUTPUT_PATH)
	if save_error != OK:
		push_error("build_black_woods: save failed (%d)" % save_error)
		quit(1)
		return

	print("Black Woods written to %s" % OUTPUT_PATH)
	print("  floor cells: %d   water cells: %d   trees: %d   wolves: %d" % [
		_inside.size(), _water_cells.size(), _tree_positions.size(), _wolf_count()])
	print("  navmesh polygons: %d" % nav_region.navigation_polygon.get_polygon_count())
	_scene_root.free()
	quit()


# --- Tileset ---------------------------------------------------------------

func _build_tile_set() -> TileSet:
	# Same shape as the hub's tileset (isometric, stacked, 32x16 cells drawn
	# from 32x32 regions) so the two maps read alike. No navigation layer:
	# walkability comes solely from the baked NavigationRegion2D polygon.
	var tile_set := TileSet.new()
	tile_set.tile_shape = TileSet.TILE_SHAPE_ISOMETRIC
	tile_set.tile_layout = TileSet.TILE_LAYOUT_STACKED
	tile_set.tile_offset_axis = TileSet.TILE_OFFSET_AXIS_HORIZONTAL
	tile_set.tile_size = TILE_SIZE
	tile_set.add_physics_layer()
	tile_set.set_physics_layer_collision_layer(0, 1)
	tile_set.set_physics_layer_collision_mask(0, 0)

	var source := TileSetAtlasSource.new()
	source.texture = load(SPRITESHEET_PATH)
	source.texture_region_size = Vector2i(32, 32)
	tile_set.add_source(source, SOURCE_ID)

	var used: Array = []
	for group in [GRASS_PLAIN, GRASS_TUFTS, GRASS_BUSHY, DIRT_PLAIN, DIRT_WORN,
			DECOR_STUMPS, DECOR_ROCKS, DECOR_PLANTS]:
		used.append_array(group)
	used.append(WATER)
	for coords in used:
		if not source.has_tile(coords):
			source.create_tile(coords)

	# Water (and the invisible void, which reuses the tile) is solid: a diamond
	# the size of the cell so it blocks walking and is carved from the navmesh.
	var water_data := source.get_tile_data(WATER, 0)
	water_data.add_collision_polygon(0)
	water_data.set_collision_polygon_points(0, 0, PackedVector2Array([
		Vector2(0, -8), Vector2(16, 0), Vector2(0, 8), Vector2(-16, 0),
	]))
	return tile_set


func _make_layer(layer_name: String, tile_set: TileSet, z: int) -> TileMapLayer:
	var layer := TileMapLayer.new()
	layer.name = layer_name
	layer.tile_set = tile_set
	layer.y_sort_enabled = true
	layer.z_index = z
	return layer


# --- Ground ----------------------------------------------------------------

# Decide which cells are forest floor: an ellipse with a noisy edge, plus a
# forced corridor down to the exit so the way out is never pinched off.
func _carve_floor() -> void:
	var half := Vector2(MAP_COLUMNS, MAP_ROWS) * 0.5
	for row in MAP_ROWS:
		for col in MAP_COLUMNS:
			var normalized := (Vector2(col, row) - half) / half
			var wobble := _shape_noise.get_noise_2d(col * 1.0, row * 0.5)
			if normalized.length() < 0.88 + 0.14 * wobble:
				_inside[Vector2i(col, row)] = true

	var entrance_cell: Vector2i = CLEARINGS["entrance"]["cell"]
	for row in range(entrance_cell.y, MAP_ROWS):
		for col in range(entrance_cell.x - 3, entrance_cell.x + 4):
			_inside[Vector2i(col, row)] = true


func _paint_ground(void_layer: TileMapLayer) -> void:
	for row in MAP_ROWS:
		for col in MAP_COLUMNS:
			var cell := Vector2i(col, row)
			if not _inside.has(cell):
				void_layer.set_cell(cell, SOURCE_ID, WATER)
				continue

			var world := _ground.map_to_local(cell)
			var salt := col * 7 + row * 13
			var coords: Vector2i
			if _distance_to_paths(world) < PATH_HALF_WIDTH:
				var worn := _detail_noise.get_noise_2d(world.x, world.y) > 0.25
				coords = _pick(DIRT_WORN if worn else DIRT_PLAIN, salt)
			else:
				var n := _detail_noise.get_noise_2d(world.x, world.y)
				if n > 0.42:
					coords = _pick(GRASS_BUSHY, salt)
				elif n > 0.05:
					coords = _pick(GRASS_TUFTS, salt)
				else:
					coords = _pick(GRASS_PLAIN, salt)
			_ground.set_cell(cell, SOURCE_ID, coords)


func _paint_water(water: TileMapLayer) -> void:
	var centre := _clearing_world("pool") + POOL_OFFSET
	for cell: Vector2i in _inside.keys():
		var world := _ground.map_to_local(cell)
		if _ellipse_ratio(world, centre, POOL_RADII) <= 1.0:
			water.set_cell(cell, SOURCE_ID, WATER)
			_water_cells[cell] = true


# --- Trees -----------------------------------------------------------------

# A dense wall along the edge of the floor, thinning inward over a short band.
func _plant_edge_trees(trees: Node2D) -> void:
	for cell: Vector2i in _inside.keys():
		var edge_distance := _distance_to_outside(cell)
		if edge_distance > EDGE_BAND_PIXELS:
			continue
		var world := _ground.map_to_local(cell) + Vector2(_rng.randf_range(-6, 6), _rng.randf_range(-4, 4))
		var on_rim := edge_distance < 22.0
		if not on_rim and _rng.randf() > 0.6:
			continue
		var spacing := EDGE_TREE_SPACING if on_rim else INNER_TREE_SPACING
		# The rim ignores clearings and paths (nothing should open onto the void),
		# but always leaves the exit gap.
		if _tree_allowed(world, spacing, true):
			_plant_tree(trees, world)


# Clusters inside the floor that turn the open space into corridors.
func _plant_copses(trees: Node2D) -> void:
	var centres: Array[Vector2] = []
	var attempts := 0
	while centres.size() < COPSE_COUNT and attempts < 400:
		attempts += 1
		var cell := Vector2i(_rng.randi_range(4, MAP_COLUMNS - 5), _rng.randi_range(6, MAP_ROWS - 7))
		if not _inside.has(cell):
			continue
		var world := _ground.map_to_local(cell)
		if _distance_to_paths(world) < CORRIDOR_HALF_WIDTH + 50.0:
			continue
		if _nearest_clearing_gap(world) < 60.0:
			continue
		var crowded := false
		for other in centres:
			if other.distance_to(world) < 150.0:
				crowded = true
				break
		if crowded:
			continue
		centres.append(world)

	for centre in centres:
		var wanted := _rng.randi_range(7, 13)
		var planted := 0
		var tries := 0
		while planted < wanted and tries < 60:
			tries += 1
			var angle := _rng.randf_range(0.0, TAU)
			var distance := _rng.randf_range(0.0, COPSE_RADIUS)
			var world := centre + Vector2.RIGHT.rotated(angle) * distance
			if _tree_allowed(world, COPSE_TREE_SPACING, false):
				_plant_tree(trees, world)
				planted += 1


func _tree_allowed(world: Vector2, spacing: float, ignore_openings: bool) -> bool:
	var cell := _ground.local_to_map(world)
	if not _inside.has(cell) or _water_cells.has(cell):
		return false
	if _in_exit_gap(world):
		return false
	if not ignore_openings:
		if _distance_to_paths(world) < CORRIDOR_HALF_WIDTH:
			return false
		if _nearest_clearing_gap(world) < 0.0:
			return false
	for other in _tree_positions:
		if other.distance_to(world) < spacing:
			return false
	return true


func _plant_tree(trees: Node2D, world: Vector2) -> void:
	var tree := (load(TREE_SCENE) as PackedScene).instantiate() as Node2D
	tree.name = "Tree%03d" % _tree_positions.size()
	tree.position = world
	_attach(trees, tree)
	_tree_positions.append(world)


# --- Decor -----------------------------------------------------------------

func _paint_decor(decor: TileMapLayer) -> void:
	for cell: Vector2i in _inside.keys():
		if _water_cells.has(cell):
			continue
		if _rng.randf() > DECOR_CHANCE:
			continue
		var world := _ground.map_to_local(cell)
		if _distance_to_paths(world) < PATH_HALF_WIDTH + 6.0:
			continue
		# Keep the spots where things stand (spawn, wolves, chest) uncluttered.
		if _nearest_clearing_gap(world) < -60.0:
			continue
		var blocked := false
		for tree in _tree_positions:
			if tree.distance_to(world) < DECOR_TREE_CLEARANCE:
				blocked = true
				break
		if blocked:
			continue

		var roll := _rng.randf()
		var salt: int = cell.x * 3 + cell.y * 11
		if roll < 0.40:
			decor.set_cell(cell, SOURCE_ID, _pick(DECOR_STUMPS, salt))
		elif roll < 0.75:
			decor.set_cell(cell, SOURCE_ID, _pick(DECOR_ROCKS, salt))
		else:
			decor.set_cell(cell, SOURCE_ID, _pick(DECOR_PLANTS, salt))


# --- Navigation ------------------------------------------------------------

func _bake_navigation(nav_region: NavigationRegion2D) -> void:
	var nav_poly := NavigationPolygon.new()
	# The outline sits just inside the cell grid: everything beyond the last
	# ring of Void tiles must not exist as navmesh at all, or a click out there
	# would snap to a strip nobody can reach.
	var inset := 8.0
	var top_left := Vector2(inset, inset)
	var bottom_right := Vector2(MAP_COLUMNS * TILE_SIZE.x - inset, MAP_ROWS * (TILE_SIZE.y / 2) - inset)
	nav_poly.add_outline(PackedVector2Array([
		top_left, Vector2(bottom_right.x, top_left.y), bottom_right, Vector2(top_left.x, bottom_right.y),
	]))
	nav_poly.agent_radius = NAV_AGENT_RADIUS
	nav_poly.parsed_geometry_type = NavigationPolygon.PARSED_GEOMETRY_STATIC_COLLIDERS
	nav_poly.parsed_collision_mask = 1
	nav_poly.source_geometry_mode = NavigationPolygon.SOURCE_GEOMETRY_GROUPS_WITH_CHILDREN
	nav_poly.source_geometry_group_name = NAVMESH_GROUP
	nav_region.navigation_polygon = nav_poly

	# Baking parses live physics, so the scene has to sit in the tree for a
	# couple of physics frames first. `main.gd` isn't attached yet, so nothing
	# game-side runs.
	root.add_child(_scene_root)
	await physics_frame
	await physics_frame
	nav_region.bake_navigation_polygon(false)
	root.remove_child(_scene_root)


# --- Actors ----------------------------------------------------------------

func _place_actors() -> void:
	var wolves := Node2D.new()
	wolves.name = "Wolves"
	_attach(_scene_root, wolves)
	var index := 0
	for clearing in WOLF_PACKS:
		var centre := _clearing_world(clearing)
		for offset in WOLF_PACKS[clearing]:
			index += 1
			var wolf := (load(WOLF_SCENE) as PackedScene).instantiate() as Node2D
			wolf.name = "Wolf%d" % index
			wolf.position = centre + offset
			_attach(wolves, wolf)

	var chest := (load(CHEST_SCENE) as PackedScene).instantiate() as Node2D
	chest.name = "ShardChest"
	chest.position = _clearing_world("pool") + CHEST_OFFSET
	_attach(_scene_root, chest)

	# player.tscn has no light; the hub's player does, and `player.gd` expects
	# one. Same settings as the hub.
	var player := (load(PLAYER_SCENE) as PackedScene).instantiate() as Node2D
	player.name = "Player"
	var entrance := _clearing_world("entrance")
	player.position = entrance
	_attach(_scene_root, player)
	var light := PointLight2D.new()
	light.name = "VisionLight"
	light.position = Vector2(0, -10)
	light.energy = 1.35
	light.texture_scale = 2.8
	_attach(player, light)

	for spawn_name in ["Spawn_from_main", "Spawn_default"]:
		var spawn := Node2D.new()
		spawn.name = spawn_name
		spawn.position = entrance
		_attach(_scene_root, spawn)

	var exit := (load(TRANSITION_SCENE) as PackedScene).instantiate() as Node2D
	exit.name = "ExitToHub"
	exit.position = entrance + EXIT_OFFSET
	exit.set("target_scene_path", HUB_SCENE_PATH)
	exit.set("target_spawn_name", HUB_RETURN_SPAWN)
	_attach(_scene_root, exit)


# --- Geometry helpers ------------------------------------------------------

func _clearing_world(clearing: String) -> Vector2:
	return _ground.map_to_local(CLEARINGS[clearing]["cell"])


func _distance_to_paths(world: Vector2) -> float:
	var best := INF
	for path in PATHS:
		var a := _clearing_world(path[0])
		var b := _clearing_world(path[1])
		var closest := Geometry2D.get_closest_point_to_segment(world, a, b)
		best = minf(best, closest.distance_to(world))
	return best


# Negative inside a clearing, positive outside; magnitude is the distance to
# the nearest clearing's edge.
func _nearest_clearing_gap(world: Vector2) -> float:
	var best := INF
	for clearing in CLEARINGS:
		var gap := _clearing_world(clearing).distance_to(world) - float(CLEARINGS[clearing]["radius"])
		best = minf(best, gap)
	return best


func _distance_to_outside(cell: Vector2i) -> float:
	var world := _ground.map_to_local(cell)
	var best := INF
	for dy in range(-4, 5):
		for dx in range(-3, 4):
			var other := cell + Vector2i(dx, dy)
			if _inside.has(other):
				continue
			best = minf(best, _ground.map_to_local(other).distance_to(world))
	return best


func _in_exit_gap(world: Vector2) -> bool:
	var entrance := _clearing_world("entrance")
	return absf(world.x - entrance.x) < EXIT_GAP_HALF_WIDTH and world.y > entrance.y


func _ellipse_ratio(world: Vector2, centre: Vector2, radii: Vector2) -> float:
	var d := (world - centre) / radii
	return d.length()


func _pick(options: Array, salt: int) -> Vector2i:
	return options[absi(salt) % options.size()]


func _wolf_count() -> int:
	var count := 0
	for clearing in WOLF_PACKS:
		count += WOLF_PACKS[clearing].size()
	return count


# Adds `node` under `parent` and marks it as ours, so `PackedScene.pack` writes
# it out. Instanced sub-scenes keep their own internals; only their root is ours.
func _attach(parent: Node, node: Node) -> void:
	parent.add_child(node)
	node.owner = _scene_root
