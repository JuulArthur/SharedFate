extends Node2D

const TILE_SIZE := Vector2i(128, 64)
const MAP_WIDTH := 14
const MAP_HEIGHT := 14
const CAMERA_FOLLOW_SPEED := 6.0
const CAMERA_ZOOM := Vector2(3.35, 3.35)
const ASSET_DIR := "res://assets/kenney_isometric-miniature-dungeon 2/Isometric/"

@onready var custom_layout: TileMapLayer = get_node_or_null("MyCustomLayout")
@onready var custom_background: TileMapLayer = get_node_or_null("MyCustomBackground")
@onready var custom_objects: TileMapLayer = get_node_or_null("MyCustomObjects")
@onready var canvas_modulate: CanvasModulate = $CanvasModulate
@onready var camera_2d: Camera2D = $Camera2D
@onready var player: CharacterBody2D = $Player
@onready var runtime_navigation_region: NavigationRegion2D = _get_or_create_runtime_navigation_region()

@export var prefer_hand_painted_layout: bool = true
@export var runtime_canvas_modulate_color: Color = Color(0.06, 0.06, 0.08, 1.0)

var grass_source_id: int = -1
var grass_alt_source_id: int = -1
var dirt_source_id: int = -1
var border_source_id: int = -1
var obstacle_a_source_id: int = -1
var obstacle_b_source_id: int = -1
var blocked_cells: Dictionary = {}
var astar_grid: AStarGrid2D = AStarGrid2D.new()
var active_nav_layer: TileMapLayer
var enemy: CharacterBody2D


func _ready() -> void:
	canvas_modulate.color = runtime_canvas_modulate_color

	_setup_tile_set()
	_rebuild_navigation_for_layer(active_nav_layer)
	_rebuild_runtime_navigation_region(active_nav_layer)
	_place_player()
	_spawn_enemy()
	_center_camera()


func _process(delta: float) -> void:
	var weight := clampf(delta * CAMERA_FOLLOW_SPEED, 0.0, 1.0)
	camera_2d.global_position = camera_2d.global_position.lerp(player.global_position, weight)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		var click_position := get_global_mouse_position()
		var clicked_enemy := _get_enemy_at_position(click_position)
		if clicked_enemy != null and player.has_method("set_attack_target"):
			player.call("set_attack_target", clicked_enemy)
		elif player.has_method("clear_attack_target"):
			player.call("clear_attack_target")
			if player.has_method("set_navigation_target"):
				player.call("set_navigation_target", click_position)
		elif player.has_method("set_navigation_target"):
			player.call("set_navigation_target", click_position)
	elif event.is_action_pressed("ui_accept"):
		_request_player_attack()
		get_viewport().set_input_as_handled()


func _spawn_enemy() -> void:
	enemy = CharacterBody2D.new()
	enemy.name = "Enemy"
	enemy.z_index = 4
	enemy.script = load("res://scripts/enemy.gd")

	var collision_shape := CollisionShape2D.new()
	collision_shape.name = "CollisionShape2D"
	enemy.add_child(collision_shape)

	var navigation_agent := NavigationAgent2D.new()
	navigation_agent.name = "NavigationAgent2D"
	navigation_agent.path_desired_distance = 4.0
	navigation_agent.target_desired_distance = 8.0
	enemy.add_child(navigation_agent)

	var sprite := Sprite2D.new()
	sprite.name = "Sprite2D"
	sprite.position = Vector2(0, -16)
	enemy.add_child(sprite)

	add_child(enemy)
	_place_enemy_on_layer(custom_background)
	if enemy.has_method("set_target"):
		enemy.call("set_target", player)


func _load_custom_layout_mode() -> void:
	if custom_layout != null:
		custom_layout.visible = true
	if custom_background != null:
		custom_background.visible = true
	if custom_objects != null:
		custom_objects.visible = true

	_cache_custom_blocked_cells()
	_rebuild_navigation_for_layer(active_nav_layer)
	_rebuild_runtime_navigation_region(active_nav_layer)


func _setup_tile_set() -> void:
	var tile_set := TileSet.new()
	tile_set.tile_shape = TileSet.TILE_SHAPE_ISOMETRIC
	tile_set.tile_layout = TileSet.TILE_LAYOUT_DIAMOND_RIGHT
	tile_set.tile_offset_axis = TileSet.TILE_OFFSET_AXIS_HORIZONTAL
	tile_set.tile_size = TILE_SIZE

	# Kenney pack does not include natural grass/trees in this folder, so we map:
	# - "grass" feel => dirtTiles + stoneUneven
	# - obstacles ("trees" equivalent) => columns + crates
	grass_source_id = _add_single_tile_source(tile_set, ASSET_DIR + "dirtTiles_S.png")
	grass_alt_source_id = _add_single_tile_source(tile_set, ASSET_DIR + "stoneUneven_S.png")
	dirt_source_id = _add_single_tile_source(tile_set, ASSET_DIR + "dirt_S.png")
	border_source_id = _add_single_tile_source(tile_set, ASSET_DIR + "stoneTile_S.png")
	obstacle_a_source_id = _add_single_tile_source(tile_set, ASSET_DIR + "stoneColumn_S.png")
	obstacle_b_source_id = _add_single_tile_source(tile_set, ASSET_DIR + "woodenCrate_S.png")


func _center_camera() -> void:
	_center_camera_on_layer(custom_background)


func _center_camera_on_layer(layer: TileMapLayer) -> void:
	var used_rect := layer.get_used_rect()
	if used_rect.size == Vector2i.ZERO:
		return

	var min_cell := used_rect.position
	var max_cell := used_rect.position + used_rect.size - Vector2i.ONE
	var min_pos := layer.map_to_local(min_cell)
	var max_pos := layer.map_to_local(max_cell)
	camera_2d.global_position = (min_pos + max_pos) * 0.5
	camera_2d.zoom = CAMERA_ZOOM
	camera_2d.enabled = true
	camera_2d.make_current()


func _place_player() -> void:
	_place_player_on_layer(custom_background)


func _place_player_on_layer(layer: TileMapLayer) -> void:
	var used_rect := layer.get_used_rect()
	if used_rect.size == Vector2i.ZERO:
		return

	var center_cell := used_rect.position + (used_rect.size / 2)
	var spawn_position := layer.map_to_local(center_cell)
	if player.has_method("snap_to"):
		player.call("snap_to", spawn_position)
	else:
		player.global_position = spawn_position


func _place_enemy_on_layer(layer: TileMapLayer) -> void:
	if enemy == null or not is_instance_valid(enemy):
		return
	if layer == null:
		return

	var used_rect := layer.get_used_rect()
	if used_rect.size == Vector2i.ZERO:
		return

	var player_cell := layer.local_to_map(layer.to_local(player.global_position))
	var preferred_cell := player_cell + Vector2i(2, -2)
	var spawn_cell := _find_nearest_walkable_spawn_cell(layer, preferred_cell, 8)
	var spawn_position := layer.map_to_local(spawn_cell)

	if enemy.has_method("snap_to"):
		enemy.call("snap_to", spawn_position)
	else:
		enemy.global_position = spawn_position


func _find_nearest_walkable_spawn_cell(layer: TileMapLayer, origin: Vector2i, max_radius: int) -> Vector2i:
	var used_rect := layer.get_used_rect()
	if used_rect.size == Vector2i.ZERO:
		return origin

	var clamped_origin := _clamp_cell_to_region(origin, used_rect)
	if not blocked_cells.has(clamped_origin):
		return clamped_origin

	for radius in range(1, max_radius + 1):
		for x in range(clamped_origin.x - radius, clamped_origin.x + radius + 1):
			for y in range(clamped_origin.y - radius, clamped_origin.y + radius + 1):
				var cell := Vector2i(x, y)
				var is_ring := x == clamped_origin.x - radius or x == clamped_origin.x + radius or y == clamped_origin.y - radius or y == clamped_origin.y + radius
				if not is_ring:
					continue
				if not used_rect.has_point(cell):
					continue
				if not blocked_cells.has(cell):
					return cell

	return clamped_origin


func _request_player_attack() -> void:
	if enemy == null or not is_instance_valid(enemy):
		return
	if not player.has_method("try_attack"):
		return
	player.call("try_attack", enemy)


func _get_enemy_at_position(world_position: Vector2) -> Node2D:
	var params := PhysicsPointQueryParameters2D.new()
	params.position = world_position
	params.collide_with_areas = true
	params.collide_with_bodies = true
	params.collision_mask = 0xFFFFFFFF

	var hits := get_world_2d().direct_space_state.intersect_point(params, 16)
	for hit in hits:
		var collider := hit.get("collider") as Object
		if collider == null:
			continue
		if collider == enemy:
			return enemy
		if collider.has_method("receive_damage") and collider is Node2D:
			return collider as Node2D

	return null


func _pick_ground_tile(x: int, y: int) -> int:
	if _is_path_cell(x, y):
		return dirt_source_id

	var center := Vector2(float(MAP_WIDTH) * 0.5, float(MAP_HEIGHT) * 0.5)
	var point := Vector2(float(x), float(y))
	var distance_to_center := point.distance_to(center)
	var radial_factor := distance_to_center / (min(MAP_WIDTH, MAP_HEIGHT) * 0.5)
	var noise := _cell_noise(x, y)

	if radial_factor > 0.78:
		return dirt_source_id
	if noise > 0.74:
		return dirt_source_id
	if noise > 0.46:
		return grass_alt_source_id
	return grass_source_id


func _should_place_tree(x: int, y: int) -> bool:
	if x <= 1 or y <= 1 or x >= MAP_WIDTH - 2 or y >= MAP_HEIGHT - 2:
		return false
	if _is_path_clearance_cell(x, y):
		return false

	var noise := _cell_noise(x * 5 + 3, y * 7 + 1)
	var clump_noise := _cell_noise(x * 11, y * 13)
	return noise > 0.60 and clump_noise > 0.42


func _is_path_cell(x: int, y: int) -> bool:
	var path_center_y := _path_center_row(x)
	return abs(float(y) - path_center_y) <= 1.0


func _is_path_clearance_cell(x: int, y: int) -> bool:
	var path_center_y := _path_center_row(x)
	return abs(float(y) - path_center_y) <= 2.0


func _path_center_row(x: int) -> float:
	var min_row: float = 3.0
	var max_row: float = float(MAP_HEIGHT - 4)
	var t: float = float(x) / float(maxi(1, MAP_WIDTH - 1))
	var base_row: float = lerpf(min_row, max_row, t)
	var bend: float = sin(float(x) * 0.55) * 1.5
	return clampf(base_row + bend, min_row, max_row)


func _cell_noise(x: int, y: int) -> float:
	var hashed := sin(float(x) * 12.9898 + float(y) * 78.233) * 43758.5453
	return abs(fmod(hashed, 1.0))


func _add_single_tile_source(tile_set: TileSet, texture_path: String) -> int:
	var texture := load(texture_path) as Texture2D
	if texture == null:
		push_error("Missing tile texture: " + texture_path)
		return -1

	var atlas_source := TileSetAtlasSource.new()
	atlas_source.texture = texture
	atlas_source.texture_region_size = texture.get_size()
	atlas_source.create_tile(Vector2i.ZERO)

	var tile_data := atlas_source.get_tile_data(Vector2i.ZERO, 0)
	var texture_size := texture.get_size()
	var origin_x := -int((texture_size.x - TILE_SIZE.x) * 0.5)
	var origin_y := -int(texture_size.y - TILE_SIZE.y)
	tile_data.texture_origin = Vector2i(origin_x, origin_y)

	return tile_set.add_source(atlas_source)

func _cache_custom_blocked_cells() -> void:
	blocked_cells.clear()
	if custom_objects == null:
		return

	var used_cells: Array[Vector2i] = custom_objects.get_used_cells()
	for cell in used_cells:
		blocked_cells[cell] = true


func _rebuild_navigation_for_layer(layer: TileMapLayer) -> void:
	if layer == null:
		return

	var used_rect := layer.get_used_rect()
	if used_rect.size == Vector2i.ZERO:
		return

	astar_grid = AStarGrid2D.new()
	astar_grid.region = used_rect
	astar_grid.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_NEVER
	astar_grid.default_compute_heuristic = AStarGrid2D.HEURISTIC_MANHATTAN
	astar_grid.default_estimate_heuristic = AStarGrid2D.HEURISTIC_MANHATTAN
	astar_grid.update()

	for x in range(used_rect.position.x, used_rect.position.x + used_rect.size.x):
		for y in range(used_rect.position.y, used_rect.position.y + used_rect.size.y):
			var cell := Vector2i(x, y)
			astar_grid.set_point_solid(cell, blocked_cells.has(cell))


func _request_player_move(target_world_position: Vector2) -> void:
	if active_nav_layer == null:
		return
	if astar_grid.region.size == Vector2i.ZERO:
		return

	var from_cell := _world_to_cell(active_nav_layer, player.global_position)
	var to_cell := _world_to_cell(active_nav_layer, target_world_position)
	if not astar_grid.is_in_boundsv(from_cell):
		return
	if not astar_grid.is_in_boundsv(to_cell):
		to_cell = _clamp_cell_to_region(to_cell, astar_grid.region)

	if astar_grid.is_point_solid(to_cell):
		to_cell = _find_nearest_walkable_cell(to_cell, 8)
		if to_cell == Vector2i(-1, -1):
			return

	var id_path: Array[Vector2i] = astar_grid.get_id_path(from_cell, to_cell)
	if id_path.is_empty():
		return

	var world_path: Array[Vector2] = []
	for path_cell in id_path:
		world_path.append(active_nav_layer.map_to_local(path_cell))

	# First point is the current cell, so skip it for smoother starts.
	if world_path.size() > 1:
		world_path.remove_at(0)

	if player.has_method("set_navigation_path"):
		player.call("set_navigation_path", world_path)


func _world_to_cell(layer: TileMapLayer, world_position: Vector2) -> Vector2i:
	var local_position := layer.to_local(world_position)
	return layer.local_to_map(local_position)


func _clamp_cell_to_region(cell: Vector2i, region: Rect2i) -> Vector2i:
	var min_x := region.position.x
	var min_y := region.position.y
	var max_x := region.position.x + region.size.x - 1
	var max_y := region.position.y + region.size.y - 1
	return Vector2i(clampi(cell.x, min_x, max_x), clampi(cell.y, min_y, max_y))


func _find_nearest_walkable_cell(origin: Vector2i, max_radius: int) -> Vector2i:
	if astar_grid.is_in_boundsv(origin) and not astar_grid.is_point_solid(origin):
		return origin

	for radius in range(1, max_radius + 1):
		for x in range(origin.x - radius, origin.x + radius + 1):
			for y in range(origin.y - radius, origin.y + radius + 1):
				var cell := Vector2i(x, y)
				var is_ring := x == origin.x - radius or x == origin.x + radius or y == origin.y - radius or y == origin.y + radius
				if not is_ring:
					continue
				if not astar_grid.is_in_boundsv(cell):
					continue
				if not astar_grid.is_point_solid(cell):
					return cell

	return Vector2i(-1, -1)


func _get_or_create_runtime_navigation_region() -> NavigationRegion2D:
	var existing := get_node_or_null("RuntimeNavigationRegion") as NavigationRegion2D
	if existing != null:
		existing.enabled = true
		existing.navigation_layers = 1
		return existing

	var region := NavigationRegion2D.new()
	region.name = "RuntimeNavigationRegion"
	region.enabled = true
	region.navigation_layers = 1
	add_child(region)
	return region


func _rebuild_runtime_navigation_region(layer: TileMapLayer) -> void:
	if layer == null:
		return

	var used_rect := layer.get_used_rect()
	if used_rect.size == Vector2i.ZERO:
		runtime_navigation_region.navigation_polygon = null
		return

	runtime_navigation_region.transform = layer.transform
	runtime_navigation_region.navigation_layers = 1

	var nav_polygon := NavigationPolygon.new()
	var vertices := PackedVector2Array()
	var half_w := float(TILE_SIZE.x) * 0.5
	var half_h := float(TILE_SIZE.y) * 0.5

	for x in range(used_rect.position.x, used_rect.position.x + used_rect.size.x):
		for y in range(used_rect.position.y, used_rect.position.y + used_rect.size.y):
			var cell := Vector2i(x, y)
			if blocked_cells.has(cell):
				continue

			var center := layer.map_to_local(cell)
			var i0 := vertices.size()
			vertices.append(center + Vector2(0.0, -half_h))
			vertices.append(center + Vector2(half_w, 0.0))
			vertices.append(center + Vector2(0.0, half_h))
			vertices.append(center + Vector2(-half_w, 0.0))
			nav_polygon.add_polygon(PackedInt32Array([i0, i0 + 1, i0 + 2, i0 + 3]))

	nav_polygon.vertices = vertices
	runtime_navigation_region.navigation_polygon = nav_polygon
