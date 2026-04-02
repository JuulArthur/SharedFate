extends Node2D

const TILE_SIZE := Vector2i(128, 64)
const MAP_WIDTH := 14
const MAP_HEIGHT := 14
const CAMERA_FOLLOW_SPEED := 6.0
const CAMERA_ZOOM := Vector2(3.35, 3.35)
const ASSET_DIR := "res://assets/kenney_isometric-miniature-dungeon 2/Isometric/"
const TURN_MOVE_METERS := 6.0
const ENEMY_TURN_MOVE_CELLS := 6
const TURN_METER_WORLD_UNITS := float(TILE_SIZE.x)
const COMBAT_TRIGGER_DISTANCE_CELLS := 6
const ENEMY_SPAWN_OFFSET := Vector2i(6, -6)
const ENEMY_SPAWN_SEARCH_RADIUS := 14

enum CombatState {
	EXPLORATION,
	PLAYER_TURN,
	ENEMY_TURN
}

@onready var custom_layout: TileMapLayer = get_node_or_null("MyCustomLayout")
@onready var custom_background: TileMapLayer = get_node_or_null("MyCustomBackground")
@onready var custom_objects: TileMapLayer = get_node_or_null("MyCustomObjects")
@onready var canvas_modulate: CanvasModulate = $CanvasModulate
@onready var camera_2d: Camera2D = $Camera2D
@onready var player: CharacterBody2D = $Player

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
var combat_state: CombatState = CombatState.EXPLORATION
var enemy_turn_running := false
var player_turn_action_running := false
var turn_ui_layer: CanvasLayer
var turn_ui_panel: PanelContainer
var turn_ui_title_label: Label
var turn_ui_phase_label: Label
var turn_ui_move_label: Label
var turn_ui_attack_label: Label


func _ready() -> void:
	canvas_modulate.color = runtime_canvas_modulate_color
	_setup_turn_ui()

	active_nav_layer = custom_background
	_setup_tile_set()
	_rebuild_navigation_for_layer(active_nav_layer)
	_place_player()
	_spawn_enemy()
	_center_camera()


func _process(delta: float) -> void:
	var weight := clampf(delta * CAMERA_FOLLOW_SPEED, 0.0, 1.0)
	camera_2d.global_position = camera_2d.global_position.lerp(player.global_position, weight)
	_update_combat_state()
	_update_turn_ui()


func _unhandled_input(event: InputEvent) -> void:
	if combat_state != CombatState.EXPLORATION:
		_handle_turn_input(event)
		return

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		var click_position := get_global_mouse_position()
		var clicked_enemy := _get_enemy_at_position(click_position)
		if clicked_enemy != null and player.has_method("set_attack_target"):
			player.call("set_attack_target", clicked_enemy)
		elif player.has_method("clear_attack_target"):
			player.call("clear_attack_target")
			_request_player_move(click_position)
		else:
			_request_player_move(click_position)
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
	var preferred_cell := player_cell + ENEMY_SPAWN_OFFSET
	var spawn_cell := _find_nearest_walkable_spawn_cell(layer, preferred_cell, ENEMY_SPAWN_SEARCH_RADIUS)
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


func _handle_turn_input(event: InputEvent) -> void:
	if combat_state != CombatState.PLAYER_TURN:
		return
	if player_turn_action_running:
		return
	if player.has_method("is_moving") and player.call("is_moving"):
		return

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		var click_position := get_global_mouse_position()
		var clicked_enemy := _get_enemy_at_position(click_position)
		if clicked_enemy == enemy:
			_request_player_turn_engage_enemy()
		else:
			_request_player_turn_move(click_position)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_accept"):
		_request_player_turn_attack()
		get_viewport().set_input_as_handled()


func _update_combat_state() -> void:
	var enemy_alive := enemy != null and is_instance_valid(enemy)
	var player_alive: bool = true
	if player.has_method("is_alive"):
		player_alive = bool(player.call("is_alive"))
	if not enemy_alive or not player_alive:
		if combat_state != CombatState.EXPLORATION:
			_end_turn_based_combat()
		return

	if combat_state == CombatState.EXPLORATION:
		if _is_close_enough_for_combat_start():
			_start_turn_based_combat()
		return

	if combat_state == CombatState.ENEMY_TURN and not enemy_turn_running:
		_run_enemy_turn()


func _is_close_enough_for_combat_start() -> bool:
	if active_nav_layer == null:
		return false
	if enemy == null or not is_instance_valid(enemy):
		return false

	var player_cell: Vector2i = _world_to_cell(active_nav_layer, player.global_position)
	var enemy_cell: Vector2i = _world_to_cell(active_nav_layer, enemy.global_position)
	var manhattan_distance: int = abs(player_cell.x - enemy_cell.x) + abs(player_cell.y - enemy_cell.y)
	return manhattan_distance <= COMBAT_TRIGGER_DISTANCE_CELLS


func _start_turn_based_combat() -> void:
	combat_state = CombatState.PLAYER_TURN
	enemy_turn_running = false

	if player.has_method("set_turn_based_combat"):
		player.call("set_turn_based_combat", true)
	if enemy != null and enemy.has_method("set_turn_based_combat"):
		enemy.call("set_turn_based_combat", true)

	if player.has_method("start_turn"):
		player.call("start_turn", TURN_MOVE_METERS)
	if enemy != null and enemy.has_method("end_turn"):
		enemy.call("end_turn")

	print("Turn-based combat started")
	_update_turn_ui()


func _end_turn_based_combat() -> void:
	combat_state = CombatState.EXPLORATION
	enemy_turn_running = false

	if player.has_method("set_turn_based_combat"):
		player.call("set_turn_based_combat", false)
	if enemy != null and is_instance_valid(enemy) and enemy.has_method("set_turn_based_combat"):
		enemy.call("set_turn_based_combat", false)

	print("Turn-based combat ended")
	_update_turn_ui()


func _request_player_turn_move(target_world_position: Vector2) -> void:
	if combat_state != CombatState.PLAYER_TURN:
		return
	if not player.has_method("get_turn_remaining_move_meters"):
		return

	var remaining_meters := float(player.call("get_turn_remaining_move_meters"))
	if remaining_meters <= 0.0:
		return

	var used_meters := _request_player_turn_move_by_distance(target_world_position, remaining_meters)
	if used_meters <= 0.0:
		return
	if player.has_method("consume_turn_movement_meters"):
		player.call("consume_turn_movement_meters", used_meters)
	elif player.has_method("consume_turn_movement"):
		player.call("consume_turn_movement", int(round(used_meters)))

	var move_left := float(player.call("get_turn_remaining_move_meters"))
	if move_left <= 0.01 and not _player_can_attack_enemy_now():
		_begin_enemy_turn()


func _request_player_turn_attack() -> void:
	if combat_state != CombatState.PLAYER_TURN:
		return
	if enemy == null or not is_instance_valid(enemy):
		return
	if not player.has_method("can_turn_attack"):
		return
	if not player.call("can_turn_attack"):
		return
	if player.global_position.distance_to(enemy.global_position) > float(player.get("attack_range")):
		return

	player.call("try_attack", enemy)
	_begin_enemy_turn()


func _request_player_turn_engage_enemy() -> void:
	if combat_state != CombatState.PLAYER_TURN:
		return
	if enemy == null or not is_instance_valid(enemy):
		return
	if player_turn_action_running:
		return

	player_turn_action_running = true

	# If already in range, attack immediately.
	if _player_can_attack_enemy_now():
		_request_player_turn_attack()
		player_turn_action_running = false
		return

	if not player.has_method("get_turn_remaining_move_meters"):
		player_turn_action_running = false
		return

	var remaining_meters := float(player.call("get_turn_remaining_move_meters"))
	if remaining_meters > 0.0:
		var used_meters := _request_player_turn_move_by_distance(enemy.global_position, remaining_meters)
		if used_meters > 0.0:
			if player.has_method("consume_turn_movement_meters"):
				player.call("consume_turn_movement_meters", used_meters)
			elif player.has_method("consume_turn_movement"):
				player.call("consume_turn_movement", int(round(used_meters)))

		# Wait for movement to complete before checking attack range.
		if player.has_method("is_moving"):
			while player.call("is_moving"):
				await get_tree().physics_frame
				if combat_state != CombatState.PLAYER_TURN:
					player_turn_action_running = false
					return

	if _player_can_attack_enemy_now():
		_request_player_turn_attack()
	else:
		var move_left := 0.0
		if player.has_method("get_turn_remaining_move_meters"):
			move_left = float(player.call("get_turn_remaining_move_meters"))
		if move_left <= 0.01:
			_begin_enemy_turn()

	player_turn_action_running = false


func _begin_enemy_turn() -> void:
	if combat_state != CombatState.PLAYER_TURN:
		return
	if player.has_method("end_turn"):
		player.call("end_turn")
	combat_state = CombatState.ENEMY_TURN
	enemy_turn_running = false
	_update_turn_ui()


func _run_enemy_turn() -> void:
	if combat_state != CombatState.ENEMY_TURN:
		return
	if enemy_turn_running:
		return
	if enemy == null or not is_instance_valid(enemy):
		_end_turn_based_combat()
		return

	enemy_turn_running = true
	if enemy.has_method("start_turn"):
		enemy.call("start_turn", ENEMY_TURN_MOVE_CELLS)

	var used_cells := _request_enemy_move_towards_player(ENEMY_TURN_MOVE_CELLS)
	if used_cells > 0 and enemy.has_method("consume_turn_movement"):
		enemy.call("consume_turn_movement", used_cells)

	if enemy.has_method("is_moving"):
		while enemy.call("is_moving"):
			await get_tree().physics_frame
			if combat_state != CombatState.ENEMY_TURN or enemy == null or not is_instance_valid(enemy):
				enemy_turn_running = false
				return

	if enemy != null and is_instance_valid(enemy):
		if enemy.has_method("try_attack"):
			enemy.call("try_attack", player)

	if enemy != null and is_instance_valid(enemy) and enemy.has_method("end_turn"):
		enemy.call("end_turn")

	if player.has_method("start_turn"):
		player.call("start_turn", TURN_MOVE_METERS)
	combat_state = CombatState.PLAYER_TURN
	enemy_turn_running = false
	_update_turn_ui()


func _player_can_attack_enemy_now() -> bool:
	if enemy == null or not is_instance_valid(enemy):
		return false
	if not player.has_method("can_turn_attack"):
		return false
	if not player.call("can_turn_attack"):
		return false
	return player.global_position.distance_to(enemy.global_position) <= float(player.get("attack_range"))


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


func _request_player_move(target_world_position: Vector2, max_cells: int = -1, avoid_enemy_cell: bool = false) -> int:
	if active_nav_layer == null:
		return 0
	var cell_path := _build_cell_path_from_navigation(player.global_position, target_world_position)
	if cell_path.size() <= 1:
		return 0

	if avoid_enemy_cell and enemy != null and is_instance_valid(enemy):
		var enemy_cell := _world_to_cell(active_nav_layer, enemy.global_position)
		while cell_path.size() > 1 and cell_path[cell_path.size() - 1] == enemy_cell:
			cell_path.remove_at(cell_path.size() - 1)
		if cell_path.size() <= 1:
			return 0

	var total_steps := cell_path.size() - 1
	var used_steps := total_steps
	if max_cells >= 0:
		used_steps = mini(total_steps, max_cells)

	var destination_cell := cell_path[used_steps]
	var destination_world := active_nav_layer.map_to_local(destination_cell)
	if player.has_method("set_navigation_target"):
		player.call("set_navigation_target", destination_world)
	return used_steps


func _request_enemy_move_towards_player(max_cells: int) -> int:
	if active_nav_layer == null:
		return 0
	if enemy == null or not is_instance_valid(enemy):
		return 0

	var cell_path := _build_cell_path_from_navigation(enemy.global_position, player.global_position)
	if cell_path.size() <= 1:
		return 0

	var player_cell := _world_to_cell(active_nav_layer, player.global_position)
	while cell_path.size() > 1 and cell_path[cell_path.size() - 1] == player_cell:
		cell_path.remove_at(cell_path.size() - 1)
	if cell_path.size() <= 1:
		return 0

	var total_steps := cell_path.size() - 1
	var used_steps := mini(total_steps, maxi(0, max_cells))
	if used_steps <= 0:
		return 0

	var destination_cell := cell_path[used_steps]
	var destination_world := active_nav_layer.map_to_local(destination_cell)
	if enemy.has_method("set_navigation_target"):
		enemy.call("set_navigation_target", destination_world)
	return used_steps


func _request_player_turn_move_by_distance(target_world_position: Vector2, max_meters: float) -> float:
	if player == null or not is_instance_valid(player):
		return 0.0
	if max_meters <= 0.0:
		return 0.0

	var world_path := _build_world_path_from_navigation(player.global_position, target_world_position)
	if world_path.size() <= 1:
		return 0.0

	var max_world_distance := max_meters * TURN_METER_WORLD_UNITS
	var path_length := _path_length(world_path)
	if path_length <= 0.001:
		return 0.0

	var used_world_distance := minf(max_world_distance, path_length)
	var destination_world := _point_on_path_at_distance(world_path, used_world_distance)
	if player.has_method("set_navigation_target"):
		player.call("set_navigation_target", destination_world)

	return used_world_distance / TURN_METER_WORLD_UNITS


func _build_cell_path_from_navigation(from_world: Vector2, to_world: Vector2) -> Array[Vector2i]:
	if active_nav_layer == null:
		return []

	var nav_agent := player.get_node_or_null("NavigationAgent2D") as NavigationAgent2D
	if nav_agent == null:
		return []
	var nav_map_rid := nav_agent.get_navigation_map()
	if nav_map_rid.is_valid() == false:
		return []

	var from_point := NavigationServer2D.map_get_closest_point(nav_map_rid, from_world)
	var to_point := NavigationServer2D.map_get_closest_point(nav_map_rid, to_world)
	var nav_path := NavigationServer2D.map_get_path(nav_map_rid, from_point, to_point, false)
	if nav_path.is_empty():
		return []

	var cell_path: Array[Vector2i] = []
	var from_cell := _world_to_cell(active_nav_layer, from_world)
	cell_path.append(from_cell)
	for nav_point in nav_path:
		var path_cell := _world_to_cell(active_nav_layer, nav_point)
		if cell_path[cell_path.size() - 1] != path_cell:
			cell_path.append(path_cell)

	return cell_path


func _build_world_path_from_navigation(from_world: Vector2, to_world: Vector2) -> Array[Vector2]:
	var nav_agent := player.get_node_or_null("NavigationAgent2D") as NavigationAgent2D
	if nav_agent == null:
		return []

	var nav_map_rid := nav_agent.get_navigation_map()
	if not nav_map_rid.is_valid():
		return []

	var from_point := NavigationServer2D.map_get_closest_point(nav_map_rid, from_world)
	var to_point := NavigationServer2D.map_get_closest_point(nav_map_rid, to_world)
	var nav_path := NavigationServer2D.map_get_path(nav_map_rid, from_point, to_point, false)
	if nav_path.is_empty():
		return []

	var world_path: Array[Vector2] = []
	world_path.append(from_point)
	for p in nav_path:
		if world_path[world_path.size() - 1].distance_to(p) > 0.01:
			world_path.append(p)
	return world_path


func _path_length(path: Array[Vector2]) -> float:
	if path.size() <= 1:
		return 0.0

	var total := 0.0
	for i in range(path.size() - 1):
		total += path[i].distance_to(path[i + 1])
	return total


func _point_on_path_at_distance(path: Array[Vector2], distance_on_path: float) -> Vector2:
	if path.is_empty():
		return Vector2.ZERO
	if path.size() == 1:
		return path[0]

	var remaining := maxf(0.0, distance_on_path)
	for i in range(path.size() - 1):
		var a := path[i]
		var b := path[i + 1]
		var segment_len := a.distance_to(b)
		if segment_len <= 0.0001:
			continue
		if remaining <= segment_len:
			return a.lerp(b, remaining / segment_len)
		remaining -= segment_len

	return path[path.size() - 1]


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


func _setup_turn_ui() -> void:
	turn_ui_layer = CanvasLayer.new()
	turn_ui_layer.name = "TurnUILayer"
	turn_ui_layer.layer = 5
	add_child(turn_ui_layer)

	turn_ui_panel = PanelContainer.new()
	turn_ui_panel.name = "TurnUI"
	turn_ui_panel.visible = false
	turn_ui_panel.offset_left = 32.0
	turn_ui_panel.offset_top = -150.0
	turn_ui_panel.offset_right = 404.0
	turn_ui_panel.offset_bottom = -30.0
	turn_ui_panel.anchor_left = 0.0
	turn_ui_panel.anchor_top = 1.0
	turn_ui_panel.anchor_right = 0.0
	turn_ui_panel.anchor_bottom = 1.0

	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(0.08, 0.07, 0.05, 0.92)
	panel_style.border_color = Color(0.66, 0.56, 0.33, 0.95)
	panel_style.border_width_left = 2
	panel_style.border_width_top = 2
	panel_style.border_width_right = 2
	panel_style.border_width_bottom = 2
	panel_style.corner_radius_top_left = 4
	panel_style.corner_radius_top_right = 4
	panel_style.corner_radius_bottom_left = 4
	panel_style.corner_radius_bottom_right = 4
	turn_ui_panel.add_theme_stylebox_override("panel", panel_style)
	turn_ui_layer.add_child(turn_ui_panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_bottom", 10)
	turn_ui_panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	margin.add_child(vbox)

	turn_ui_title_label = Label.new()
	turn_ui_title_label.text = "TURN COMBAT"
	turn_ui_title_label.add_theme_color_override("font_color", Color(0.88, 0.78, 0.53, 1.0))
	vbox.add_child(turn_ui_title_label)

	turn_ui_phase_label = Label.new()
	turn_ui_phase_label.text = "Phase: -"
	turn_ui_phase_label.add_theme_color_override("font_color", Color(0.70, 0.70, 0.66, 1.0))
	vbox.add_child(turn_ui_phase_label)

	var separator := ColorRect.new()
	separator.color = Color(0.52, 0.44, 0.28, 0.85)
	separator.custom_minimum_size = Vector2(0, 1)
	vbox.add_child(separator)

	turn_ui_move_label = Label.new()
	turn_ui_move_label.text = "Move: -"
	turn_ui_move_label.add_theme_color_override("font_color", Color(0.86, 0.86, 0.84, 1.0))
	vbox.add_child(turn_ui_move_label)

	turn_ui_attack_label = Label.new()
	turn_ui_attack_label.text = "Attack: -"
	turn_ui_attack_label.add_theme_color_override("font_color", Color(0.86, 0.86, 0.84, 1.0))
	vbox.add_child(turn_ui_attack_label)


func _update_turn_ui() -> void:
	if turn_ui_panel == null:
		return

	var in_turn_mode := combat_state != CombatState.EXPLORATION
	turn_ui_panel.visible = in_turn_mode
	if not in_turn_mode:
		return

	var phase_text := "Phase: -"
	var move_text := "Move: -"
	var attack_text := "Attack: -"

	if combat_state == CombatState.PLAYER_TURN:
		var remaining_meters := 0.0
		var can_attack := false

		if player != null and player.has_method("get_turn_remaining_move_meters"):
			remaining_meters = float(player.call("get_turn_remaining_move_meters"))
		if player != null and player.has_method("can_turn_attack"):
			can_attack = bool(player.call("can_turn_attack"))

		phase_text = "Phase: Your turn"
		move_text = "Movement: %.1f m left" % remaining_meters
		attack_text = "Attack: %s" % ("Ready" if can_attack else "Used")
		turn_ui_phase_label.add_theme_color_override("font_color", Color(0.62, 0.84, 0.66, 1.0))
		turn_ui_move_label.add_theme_color_override("font_color", Color(0.86, 0.86, 0.84, 1.0))
		turn_ui_attack_label.add_theme_color_override("font_color", Color(0.65, 0.88, 0.67, 1.0) if can_attack else Color(0.88, 0.57, 0.57, 1.0))
	elif combat_state == CombatState.ENEMY_TURN:
		phase_text = "Phase: Enemy turn"
		move_text = "Movement: Enemy acting..."
		attack_text = "Attack: Enemy acting..."
		turn_ui_phase_label.add_theme_color_override("font_color", Color(0.88, 0.62, 0.62, 1.0))
		turn_ui_move_label.add_theme_color_override("font_color", Color(0.75, 0.69, 0.69, 1.0))
		turn_ui_attack_label.add_theme_color_override("font_color", Color(0.75, 0.69, 0.69, 1.0))

	turn_ui_phase_label.text = phase_text
	turn_ui_move_label.text = move_text
	turn_ui_attack_label.text = attack_text
