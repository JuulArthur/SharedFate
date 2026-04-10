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
const PLAYER_SPAWN_OFFSET := Vector2i(-6, 0)
const ENEMY_SPAWN_OFFSET := Vector2i(6, -6)
const ENEMY_SPAWN_SEARCH_RADIUS := 14
const ENEMY_TURN_DELAY_SECONDS := 1.0
const TURN_MODE_ENEMY_BLOCKER_EXTRA_RADIUS := 20.0

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
@onready var nav_region: NavigationRegion2D = $NavigationRegion2D

@export var prefer_hand_painted_layout: bool = true
@export var runtime_canvas_modulate_color: Color = Color(0.06, 0.06, 0.08, 1.0)

var grass_source_id: int = -1
var grass_alt_source_id: int = -1
var dirt_source_id: int = -1
var border_source_id: int = -1
var obstacle_a_source_id: int = -1
var obstacle_b_source_id: int = -1
var blocked_cells: Dictionary = {}
var _original_nav_poly: NavigationPolygon
var enemy_blocked_cells: Dictionary = {}
var astar_grid: AStarGrid2D = AStarGrid2D.new()
var active_nav_layer: TileMapLayer
var enemy: CharacterBody2D
var extra_enemies: Array[CharacterBody2D] = []
var combat_state: CombatState = CombatState.EXPLORATION
var enemy_turn_running := false
var active_enemy_turn_actor: CharacterBody2D
var hovered_enemy: CharacterBody2D
var player_turn_action_running := false
var turn_ui_layer: CanvasLayer
var turn_ui_panel: PanelContainer
var turn_ui_title_label: Label
var turn_ui_phase_label: Label
var turn_ui_move_label: Label
var turn_ui_attack_label: Label
var turn_ui_order_panel: PanelContainer
var turn_ui_player_icon: TextureRect
var turn_ui_player_label: Label
var turn_ui_enemy_icons_container: HBoxContainer
var turn_ui_enemy_icon_entries: Array[Dictionary] = []


func _ready() -> void:
	canvas_modulate.color = runtime_canvas_modulate_color
	_setup_turn_ui()

	active_nav_layer = custom_background
	_setup_tile_set()
	_rebuild_navigation_for_layer(active_nav_layer)
	_place_player()
	_spawn_enemy()
	var second_enemy := _spawn_additional_enemy(Vector2i(-ENEMY_SPAWN_OFFSET.x, ENEMY_SPAWN_OFFSET.y), "Enemy2")
	if second_enemy != null:
		extra_enemies.append(second_enemy)
	_center_camera()

	if nav_region and nav_region.navigation_polygon:
		_original_nav_poly = nav_region.navigation_polygon.duplicate()


func _process(delta: float) -> void:
	var weight := clampf(delta * CAMERA_FOLLOW_SPEED, 0.0, 1.0)
	camera_2d.global_position = camera_2d.global_position.lerp(player.global_position, weight)
	_update_combat_state()
	_update_enemy_hover_state()
	_update_turn_ui()


func _unhandled_input(event: InputEvent) -> void:
	if combat_state != CombatState.EXPLORATION:
		_handle_turn_input(event)
		return

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		var click_position := get_global_mouse_position()
		var clicked_enemy := _get_enemy_at_position(click_position)
		if clicked_enemy != null and player.has_method("set_attack_target"):
			# attack_target system handles navigation internally via _refresh_attack_target_position
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
	enemy = _spawn_additional_enemy(ENEMY_SPAWN_OFFSET, "Enemy")


func _spawn_additional_enemy(offset_from_player: Vector2i, enemy_name: String) -> CharacterBody2D:
	var enemy_actor := CharacterBody2D.new()
	enemy_actor.name = enemy_name
	enemy_actor.z_index = 4
	enemy_actor.script = load("res://scripts/enemy.gd")

	var collision_shape := CollisionShape2D.new()
	collision_shape.name = "CollisionShape2D"
	enemy_actor.add_child(collision_shape)

	var navigation_agent := NavigationAgent2D.new()
	navigation_agent.name = "NavigationAgent2D"
	navigation_agent.path_desired_distance = 4.0
	navigation_agent.target_desired_distance = 8.0
	enemy_actor.add_child(navigation_agent)

	var sprite := Sprite2D.new()
	sprite.name = "Sprite2D"
	sprite.position = Vector2(0, -16)
	enemy_actor.add_child(sprite)

	add_child(enemy_actor)
	_place_enemy_on_layer(enemy_actor, custom_background, offset_from_player)
	if enemy_actor.has_method("set_target"):
		enemy_actor.call("set_target", player)
	return enemy_actor


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
	var spawn_cell := _clamp_cell_to_region(center_cell + PLAYER_SPAWN_OFFSET, used_rect)
	var spawn_position := layer.map_to_local(spawn_cell)
	if player.has_method("snap_to"):
		player.call("snap_to", spawn_position)
	else:
		player.global_position = spawn_position


func _place_enemy_on_layer(enemy_actor: CharacterBody2D, layer: TileMapLayer, offset_from_player: Vector2i) -> void:
	if enemy_actor == null or not is_instance_valid(enemy_actor):
		return
	if layer == null:
		return

	var used_rect := layer.get_used_rect()
	if used_rect.size == Vector2i.ZERO:
		return

	var player_cell := layer.local_to_map(layer.to_local(player.global_position))
	var preferred_cell := player_cell + offset_from_player
	var spawn_cell := _find_nearest_walkable_spawn_cell(layer, preferred_cell, ENEMY_SPAWN_SEARCH_RADIUS)
	var spawn_position := layer.map_to_local(spawn_cell)

	if enemy_actor.has_method("snap_to"):
		enemy_actor.call("snap_to", spawn_position)
	else:
		enemy_actor.global_position = spawn_position


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
	if not player.has_method("try_attack"):
		return
	var target_enemy := _get_closest_enemy_to_player()
	if target_enemy == null:
		return
	player.call("try_attack", target_enemy)


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
		if clicked_enemy != null:
			_request_player_turn_engage_enemy(clicked_enemy as CharacterBody2D)
		else:
			_request_player_turn_move(click_position)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_accept"):
		_request_player_turn_attack()
		get_viewport().set_input_as_handled()


func _update_combat_state() -> void:
	var enemy_alive := not _get_all_alive_enemies().is_empty()
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

	var player_cell: Vector2i = _world_to_cell(active_nav_layer, player.global_position)
	for enemy_actor in _get_all_alive_enemies():
		var enemy_cell: Vector2i = _world_to_cell(active_nav_layer, enemy_actor.global_position)
		var manhattan_distance: int = abs(player_cell.x - enemy_cell.x) + abs(player_cell.y - enemy_cell.y)
		if manhattan_distance <= COMBAT_TRIGGER_DISTANCE_CELLS:
			return true
	return false


func _start_turn_based_combat() -> void:
	_stop_all_combatants_immediately()
	combat_state = CombatState.PLAYER_TURN
	enemy_turn_running = false
	active_enemy_turn_actor = null

	_carve_enemy_holes_in_navmesh()

	if player.has_method("set_turn_based_combat"):
		player.call("set_turn_based_combat", true)
	for enemy_actor in _get_all_alive_enemies():
		if enemy_actor.has_method("set_turn_based_combat"):
			enemy_actor.call("set_turn_based_combat", true)

	if player.has_method("start_turn"):
		player.call("start_turn", TURN_MOVE_METERS)
	for enemy_actor in _get_all_alive_enemies():
		if enemy_actor.has_method("end_turn"):
			enemy_actor.call("end_turn")

	print("Turn-based combat started")
	_update_turn_ui()


func _stop_all_combatants_immediately() -> void:
	if player != null and player.has_method("stop_movement_immediately"):
		player.call("stop_movement_immediately")
	elif player != null and player.has_method("set_navigation_target"):
		player.call("set_navigation_target", player.global_position)

	for enemy_actor in _get_all_alive_enemies():
		if enemy_actor.has_method("stop_movement_immediately"):
			enemy_actor.call("stop_movement_immediately")
		elif enemy_actor.has_method("set_navigation_target"):
			enemy_actor.call("set_navigation_target", enemy_actor.global_position)


func _end_turn_based_combat() -> void:
	combat_state = CombatState.EXPLORATION
	enemy_turn_running = false
	active_enemy_turn_actor = null
	_set_hovered_enemy(null)
	active_enemy_turn_actor = null

	_restore_navmesh()

	if player.has_method("set_turn_based_combat"):
		player.call("set_turn_based_combat", false)
	for enemy_actor in _get_all_alive_enemies():
		if enemy_actor.has_method("set_turn_based_combat"):
			enemy_actor.call("set_turn_based_combat", false)

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


func _request_player_turn_attack(target_enemy: CharacterBody2D = null) -> void:
	if combat_state != CombatState.PLAYER_TURN:
		return
	if not player.has_method("can_turn_attack"):
		return
	if not player.call("can_turn_attack"):
		return
	if target_enemy == null:
		target_enemy = _get_closest_enemy_to_player()
	if target_enemy == null:
		return
	if player.global_position.distance_to(target_enemy.global_position) > float(player.get("attack_range")):
		return

	player.call("try_attack", target_enemy)
	_begin_enemy_turn()


func _request_player_turn_engage_enemy(target_enemy: CharacterBody2D = null) -> void:
	if combat_state != CombatState.PLAYER_TURN:
		return
	if player_turn_action_running:
		return
	if target_enemy == null:
		target_enemy = _get_closest_enemy_to_player()
	if target_enemy == null:
		return

	player_turn_action_running = true

	# If already in range, attack immediately.
	if _player_can_attack_enemy_now():
		_request_player_turn_attack(target_enemy)
		player_turn_action_running = false
		return

	if not player.has_method("get_turn_remaining_move_meters"):
		player_turn_action_running = false
		return

	var remaining_meters := float(player.call("get_turn_remaining_move_meters"))
	if remaining_meters > 0.0:
		var player_approach_distance := float(player.get("attack_range"))
		if player.has_method("get_preferred_attack_approach_distance"):
			player_approach_distance = float(player.call("get_preferred_attack_approach_distance"))
		var approach_point := _compute_approach_world_point(player.global_position, target_enemy.global_position, player_approach_distance)
		var used_meters := _request_player_turn_move_by_distance(approach_point, remaining_meters)
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
		_request_player_turn_attack(target_enemy)
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
	var alive_enemies := _get_all_alive_enemies()
	if alive_enemies.is_empty():
		_end_turn_based_combat()
		return

	enemy_turn_running = true
	await get_tree().create_timer(ENEMY_TURN_DELAY_SECONDS).timeout
	if combat_state != CombatState.ENEMY_TURN:
		enemy_turn_running = false
		return

	for enemy_actor in _get_all_alive_enemies():
		active_enemy_turn_actor = enemy_actor
		if enemy_actor.has_method("start_turn"):
			enemy_actor.call("start_turn", ENEMY_TURN_MOVE_CELLS)

		var used_cells := _request_enemy_move_towards_player(enemy_actor, ENEMY_TURN_MOVE_CELLS)
		if used_cells > 0 and enemy_actor.has_method("consume_turn_movement"):
			enemy_actor.call("consume_turn_movement", used_cells)

		if enemy_actor.has_method("is_moving"):
			while enemy_actor.call("is_moving"):
				await get_tree().physics_frame
				if combat_state != CombatState.ENEMY_TURN:
					enemy_turn_running = false
					return
				if not is_instance_valid(enemy_actor):
					break

		if is_instance_valid(enemy_actor) and enemy_actor.has_method("try_attack"):
			enemy_actor.call("try_attack", player)
		if is_instance_valid(enemy_actor) and enemy_actor.has_method("end_turn"):
			enemy_actor.call("end_turn")

	_carve_enemy_holes_in_navmesh()

	if player.has_method("start_turn"):
		player.call("start_turn", TURN_MOVE_METERS)
	active_enemy_turn_actor = null
	combat_state = CombatState.PLAYER_TURN
	enemy_turn_running = false
	_update_turn_ui()


func _player_can_attack_enemy_now() -> bool:
	if not player.has_method("can_turn_attack"):
		return false
	if not player.call("can_turn_attack"):
		return false
	var target_enemy := _get_closest_enemy_to_player()
	if target_enemy == null:
		return false
	return player.global_position.distance_to(target_enemy.global_position) <= float(player.get("attack_range"))


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
		if not (collider is Node2D):
			continue
		var candidate := collider as Node2D
		for enemy_actor in _get_all_alive_enemies():
			if candidate == enemy_actor:
				return enemy_actor

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


func _carve_enemy_holes_in_navmesh() -> void:
	if _original_nav_poly == null or nav_region == null:
		return

	var modified := _original_nav_poly.duplicate() as NavigationPolygon
	var alive_enemies := _get_all_alive_enemies()
	var hole_radius := 24.0

	for enemy_actor in alive_enemies:
		var enemy_local_pos := nav_region.to_local(enemy_actor.global_position)
		var hole := PackedVector2Array()
		var segments := 12
		for i in range(segments - 1, -1, -1):
			var angle := TAU * float(i) / float(segments)
			hole.append(enemy_local_pos + Vector2(cos(angle), sin(angle)) * hole_radius)
		modified.add_outline(hole)

	modified.make_polygons_from_outlines()
	nav_region.navigation_polygon = modified


func _restore_navmesh() -> void:
	if _original_nav_poly == null or nav_region == null:
		return
	nav_region.navigation_polygon = _original_nav_poly.duplicate()


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
			astar_grid.set_point_solid(cell, blocked_cells.has(cell) or enemy_blocked_cells.has(cell))


func _request_player_move(target_world_position: Vector2) -> void:
	# Use navmesh routing directly; NavigationObstacle2D on enemies carves them out
	# of the navmesh so the path routes around them automatically.
	if player == null or not is_instance_valid(player):
		return
	if player.has_method("set_navigation_target"):
		player.call("set_navigation_target", target_world_position)


func _collect_enemy_personal_space_cells() -> Array[Vector2i]:
	var blocked: Array[Vector2i] = []
	if active_nav_layer == null:
		return blocked

	var used_rect := astar_grid.region
	if used_rect.size == Vector2i.ZERO:
		return blocked

	var player_radius := _get_character_collision_radius(player)
	for enemy_actor in _get_all_alive_enemies():
		var enemy_cell := _world_to_cell(active_nav_layer, enemy_actor.global_position)
		var enemy_radius := _get_character_collision_radius(enemy_actor)
		var clearance_world := player_radius + enemy_radius + 6.0
		if combat_state != CombatState.EXPLORATION:
			clearance_world += TURN_MODE_ENEMY_BLOCKER_EXTRA_RADIUS

		var sample_cell_radius := int(ceili(clearance_world / maxf(1.0, float(TILE_SIZE.y)))) + 2
		for dx in range(-sample_cell_radius, sample_cell_radius + 1):
			for dy in range(-sample_cell_radius, sample_cell_radius + 1):
				var cell := enemy_cell + Vector2i(dx, dy)
				if not used_rect.has_point(cell):
					continue

				var cell_world := active_nav_layer.map_to_local(cell)
				if cell_world.distance_to(enemy_actor.global_position) <= clearance_world and blocked.find(cell) == -1:
					blocked.append(cell)

		# Ensure the enemy's own cell is always blocked.
		if blocked.find(enemy_cell) == -1:
			blocked.append(enemy_cell)

	return blocked


func _refresh_enemy_blocked_cells(excluded_enemy: CharacterBody2D = null) -> void:
	enemy_blocked_cells.clear()
	if active_nav_layer == null:
		return
	if astar_grid.region.size == Vector2i.ZERO:
		return

	var used_rect := astar_grid.region
	var player_radius := _get_character_collision_radius(player)

	for enemy_actor in _get_all_alive_enemies():
		if excluded_enemy != null and enemy_actor == excluded_enemy:
			continue

		var enemy_cell := _world_to_cell(active_nav_layer, enemy_actor.global_position)
		var enemy_radius := _get_character_collision_radius(enemy_actor)
		var clearance_world := player_radius + enemy_radius + 6.0
		if combat_state != CombatState.EXPLORATION:
			clearance_world += TURN_MODE_ENEMY_BLOCKER_EXTRA_RADIUS

		var sample_cell_radius := int(ceili(clearance_world / maxf(1.0, float(TILE_SIZE.y)))) + 2
		for dx in range(-sample_cell_radius, sample_cell_radius + 1):
			for dy in range(-sample_cell_radius, sample_cell_radius + 1):
				var cell := enemy_cell + Vector2i(dx, dy)
				if not used_rect.has_point(cell):
					continue
				var cell_world := active_nav_layer.map_to_local(cell)
				if cell_world.distance_to(enemy_actor.global_position) <= clearance_world:
					enemy_blocked_cells[cell] = true

		enemy_blocked_cells[enemy_cell] = true


func _get_character_collision_radius(character: Node) -> float:
	if character == null:
		return 10.0
	var shape_node := character.get_node_or_null("CollisionShape2D") as CollisionShape2D
	if shape_node == null:
		return 10.0
	var circle := shape_node.shape as CircleShape2D
	if circle == null:
		return 10.0
	return circle.radius


func _find_farthest_valid_player_path_index(cell_path: Array[Vector2i]) -> int:
	if cell_path.size() <= 1:
		return 0
	for i in range(cell_path.size() - 1, 0, -1):
		var world_pos := active_nav_layer.map_to_local(cell_path[i])
		if not _is_player_position_blocked(world_pos):
			return i
	return 0


func _is_player_position_blocked(world_position: Vector2) -> bool:
	if player == null or not is_instance_valid(player):
		return true

	var shape_node := player.get_node_or_null("CollisionShape2D") as CollisionShape2D
	if shape_node == null or shape_node.shape == null:
		return false

	var params := PhysicsShapeQueryParameters2D.new()
	params.shape = shape_node.shape
	params.transform = Transform2D(0.0, world_position + shape_node.position)
	params.collide_with_areas = false
	params.collide_with_bodies = true
	params.exclude = [player]
	params.collision_mask = 1 | 4

	var hits := get_world_2d().direct_space_state.intersect_shape(params, 1)
	if not hits.is_empty():
		return true

	# In turn mode, treat enemy personal space as hard collision too.
	if combat_state != CombatState.EXPLORATION:
		var player_radius := _get_character_collision_radius(player)
		for enemy_actor in _get_all_alive_enemies():
			var enemy_radius := _get_character_collision_radius(enemy_actor)
			var min_distance := player_radius + enemy_radius + TURN_MODE_ENEMY_BLOCKER_EXTRA_RADIUS
			if world_position.distance_to(enemy_actor.global_position) < min_distance:
				return true

	return false


func _request_enemy_move_towards_player(enemy_actor: CharacterBody2D, max_cells: int) -> int:
	if active_nav_layer == null:
		return 0
	if enemy_actor == null or not is_instance_valid(enemy_actor):
		return 0

	# Rebuild grid while excluding this mover from dynamic enemy blockers.
	_refresh_enemy_blocked_cells(enemy_actor)
	_rebuild_navigation_for_layer(active_nav_layer)

	var enemy_attack_range := float(enemy_actor.get("attack_range"))
	var approach_point := _compute_approach_world_point(enemy_actor.global_position, player.global_position, enemy_attack_range)
	var cell_path := _build_cell_path_from_navigation(enemy_actor.global_position, approach_point)
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
	if enemy_actor.has_method("set_navigation_target"):
		enemy_actor.call("set_navigation_target", destination_world)
	return used_steps


func _get_all_alive_enemies() -> Array[CharacterBody2D]:
	var result: Array[CharacterBody2D] = []
	if enemy != null and is_instance_valid(enemy):
		if not enemy.has_method("is_alive") or bool(enemy.call("is_alive")):
			result.append(enemy)
	for enemy_actor in extra_enemies:
		if enemy_actor != null and is_instance_valid(enemy_actor):
			if not enemy_actor.has_method("is_alive") or bool(enemy_actor.call("is_alive")):
				result.append(enemy_actor)
	return result


func _get_closest_enemy_to_player() -> CharacterBody2D:
	var alive_enemies := _get_all_alive_enemies()
	if alive_enemies.is_empty():
		return null

	var closest := alive_enemies[0]
	var closest_dist := player.global_position.distance_to(closest.global_position)
	for i in range(1, alive_enemies.size()):
		var candidate := alive_enemies[i]
		var d := player.global_position.distance_to(candidate.global_position)
		if d < closest_dist:
			closest_dist = d
			closest = candidate
	return closest


func _compute_approach_world_point(mover_world: Vector2, target_world: Vector2, stop_distance: float) -> Vector2:
	var to_mover := mover_world - target_world
	var distance := to_mover.length()
	if distance <= stop_distance:
		return mover_world
	if distance <= 0.001:
		return target_world
	return target_world + (to_mover / distance) * stop_distance


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


func _build_astar_id_path(from_cell: Vector2i, to_cell: Vector2i, dynamic_blocked_cells: Array[Vector2i]) -> Array[Vector2i]:
	var modified_cells: Array[Vector2i] = []
	for blocked_cell in dynamic_blocked_cells:
		if blocked_cell == from_cell:
			continue
		if not astar_grid.is_in_boundsv(blocked_cell):
			continue
		if astar_grid.is_point_solid(blocked_cell):
			continue
		astar_grid.set_point_solid(blocked_cell, true)
		modified_cells.append(blocked_cell)

	var resolved_to_cell := to_cell
	if astar_grid.is_point_solid(resolved_to_cell):
		resolved_to_cell = _find_nearest_walkable_cell(resolved_to_cell, 12)

	var path: Array[Vector2i] = []
	if resolved_to_cell != Vector2i(-1, -1):
		path = astar_grid.get_id_path(from_cell, resolved_to_cell)

	for modified_cell in modified_cells:
		astar_grid.set_point_solid(modified_cell, false)

	return path


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

	turn_ui_order_panel = PanelContainer.new()
	turn_ui_order_panel.name = "TurnOrderUI"
	turn_ui_order_panel.visible = false
	turn_ui_order_panel.anchor_left = 0.5
	turn_ui_order_panel.anchor_top = 0.0
	turn_ui_order_panel.anchor_right = 0.5
	turn_ui_order_panel.anchor_bottom = 0.0
	turn_ui_order_panel.offset_left = -130.0
	turn_ui_order_panel.offset_top = 18.0
	turn_ui_order_panel.offset_right = 130.0
	turn_ui_order_panel.offset_bottom = 112.0

	var top_style := StyleBoxFlat.new()
	top_style.bg_color = Color(0.08, 0.07, 0.05, 0.92)
	top_style.border_color = Color(0.66, 0.56, 0.33, 0.95)
	top_style.border_width_left = 2
	top_style.border_width_top = 2
	top_style.border_width_right = 2
	top_style.border_width_bottom = 2
	top_style.corner_radius_top_left = 4
	top_style.corner_radius_top_right = 4
	top_style.corner_radius_bottom_left = 4
	top_style.corner_radius_bottom_right = 4
	turn_ui_order_panel.add_theme_stylebox_override("panel", top_style)
	turn_ui_layer.add_child(turn_ui_order_panel)

	var top_margin := MarginContainer.new()
	top_margin.add_theme_constant_override("margin_left", 10)
	top_margin.add_theme_constant_override("margin_top", 8)
	top_margin.add_theme_constant_override("margin_right", 10)
	top_margin.add_theme_constant_override("margin_bottom", 8)
	turn_ui_order_panel.add_child(top_margin)

	var order_hbox := HBoxContainer.new()
	order_hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	order_hbox.add_theme_constant_override("separation", 22)
	top_margin.add_child(order_hbox)

	var player_box := VBoxContainer.new()
	player_box.add_theme_constant_override("separation", 4)
	order_hbox.add_child(player_box)

	turn_ui_player_icon = TextureRect.new()
	turn_ui_player_icon.custom_minimum_size = Vector2(48, 48)
	turn_ui_player_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	turn_ui_player_icon.texture = _create_placeholder_icon(Color(0.26, 0.50, 0.84, 1.0))
	player_box.add_child(turn_ui_player_icon)

	turn_ui_player_label = Label.new()
	turn_ui_player_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	turn_ui_player_label.text = "Player"
	player_box.add_child(turn_ui_player_label)

	turn_ui_enemy_icons_container = HBoxContainer.new()
	turn_ui_enemy_icons_container.add_theme_constant_override("separation", 12)
	order_hbox.add_child(turn_ui_enemy_icons_container)

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

	_rebuild_turn_enemy_icons()


func _update_turn_ui() -> void:
	if turn_ui_panel == null:
		return

	var in_turn_mode := combat_state != CombatState.EXPLORATION
	turn_ui_panel.visible = in_turn_mode
	if turn_ui_order_panel != null:
		turn_ui_order_panel.visible = in_turn_mode
	if not in_turn_mode:
		return

	var alive_enemies := _get_all_alive_enemies()
	if turn_ui_enemy_icon_entries.size() != alive_enemies.size():
		_rebuild_turn_enemy_icons()

	var player_turn_active := combat_state == CombatState.PLAYER_TURN
	var player_icon_dim := Color(1.0, 1.0, 1.0, 1.0) if player_turn_active else Color(0.45, 0.45, 0.45, 0.95)
	if turn_ui_player_icon != null:
		turn_ui_player_icon.modulate = player_icon_dim
	if turn_ui_player_label != null:
		turn_ui_player_label.add_theme_color_override("font_color", Color(0.72, 0.90, 1.0, 1.0) if player_turn_active else Color(0.68, 0.68, 0.68, 1.0))

	for i in range(turn_ui_enemy_icon_entries.size()):
		var entry := turn_ui_enemy_icon_entries[i]
		var enemy_actor := entry.get("enemy") as CharacterBody2D
		var panel := entry.get("panel") as PanelContainer
		var icon := entry.get("icon") as TextureRect
		var label := entry.get("label") as Label

		var is_enemy_active := false
		if combat_state == CombatState.ENEMY_TURN:
			if active_enemy_turn_actor != null and is_instance_valid(active_enemy_turn_actor):
				is_enemy_active = enemy_actor == active_enemy_turn_actor
			elif i == 0:
				is_enemy_active = true
		var is_enemy_hovered := hovered_enemy != null and is_instance_valid(hovered_enemy) and enemy_actor == hovered_enemy

		if icon != null:
			if is_enemy_hovered:
				icon.modulate = Color(1.0, 0.86, 0.86, 1.0)
			elif is_enemy_active:
				icon.modulate = Color(1.0, 1.0, 1.0, 1.0)
			else:
				icon.modulate = Color(0.45, 0.45, 0.45, 0.95)
		if label != null:
			if is_enemy_hovered:
				label.add_theme_color_override("font_color", Color(1.0, 0.35, 0.35, 1.0))
			elif is_enemy_active:
				label.add_theme_color_override("font_color", Color(1.0, 0.73, 0.73, 1.0))
			else:
				label.add_theme_color_override("font_color", Color(0.68, 0.68, 0.68, 1.0))
		if panel != null:
			panel.add_theme_stylebox_override("panel", _create_turn_enemy_icon_panel_style(is_enemy_active, is_enemy_hovered))

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


func _create_placeholder_icon(base_color: Color) -> Texture2D:
	var size := 64
	var image := Image.create(size, size, false, Image.FORMAT_RGBA8)
	image.fill(base_color)

	var border_color := base_color.darkened(0.42)
	for x in range(size):
		image.set_pixel(x, 0, border_color)
		image.set_pixel(x, size - 1, border_color)
	for y in range(size):
		image.set_pixel(0, y, border_color)
		image.set_pixel(size - 1, y, border_color)

	return ImageTexture.create_from_image(image)


func _rebuild_turn_enemy_icons() -> void:
	if turn_ui_enemy_icons_container == null:
		return

	for child in turn_ui_enemy_icons_container.get_children():
		child.queue_free()
	turn_ui_enemy_icon_entries.clear()

	var alive_enemies := _get_all_alive_enemies()
	for i in range(alive_enemies.size()):
		var enemy_actor := alive_enemies[i]
		var enemy_panel := PanelContainer.new()
		enemy_panel.add_theme_stylebox_override("panel", _create_turn_enemy_icon_panel_style(false, false))
		turn_ui_enemy_icons_container.add_child(enemy_panel)

		var enemy_box := VBoxContainer.new()
		enemy_box.add_theme_constant_override("separation", 4)
		enemy_panel.add_child(enemy_box)

		var enemy_icon := TextureRect.new()
		enemy_icon.custom_minimum_size = Vector2(48, 48)
		enemy_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		enemy_icon.texture = _create_placeholder_icon(Color(0.82, 0.26, 0.26, 1.0))
		enemy_box.add_child(enemy_icon)

		var enemy_label := Label.new()
		enemy_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		enemy_label.text = "Enemy %d" % (i + 1)
		enemy_box.add_child(enemy_label)

		turn_ui_enemy_icon_entries.append({
			"enemy": enemy_actor,
			"panel": enemy_panel,
			"icon": enemy_icon,
			"label": enemy_label
		})


func _update_enemy_hover_state() -> void:
	if combat_state == CombatState.EXPLORATION:
		_set_hovered_enemy(null)
		return

	var hovered := _get_enemy_at_position(get_global_mouse_position()) as CharacterBody2D
	_set_hovered_enemy(hovered)


func _set_hovered_enemy(new_enemy: CharacterBody2D) -> void:
	if hovered_enemy != null and not is_instance_valid(hovered_enemy):
		hovered_enemy = null
	if new_enemy != null and not is_instance_valid(new_enemy):
		new_enemy = null
	if hovered_enemy == new_enemy:
		return

	if hovered_enemy != null and hovered_enemy.has_method("set_hover_highlighted"):
		hovered_enemy.call("set_hover_highlighted", false)

	hovered_enemy = new_enemy

	if hovered_enemy != null and hovered_enemy.has_method("set_hover_highlighted"):
		hovered_enemy.call("set_hover_highlighted", true)


func _create_turn_enemy_icon_panel_style(is_active: bool, is_hovered: bool) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.14, 0.12, 0.09, 0.85)
	style.corner_radius_top_left = 4
	style.corner_radius_top_right = 4
	style.corner_radius_bottom_left = 4
	style.corner_radius_bottom_right = 4
	style.content_margin_left = 6
	style.content_margin_top = 4
	style.content_margin_right = 6
	style.content_margin_bottom = 4

	if is_hovered:
		style.border_color = Color(0.92, 0.18, 0.18, 1.0)
		style.border_width_left = 2
		style.border_width_top = 2
		style.border_width_right = 2
		style.border_width_bottom = 2
	elif is_active:
		style.border_color = Color(0.82, 0.52, 0.52, 1.0)
		style.border_width_left = 2
		style.border_width_top = 2
		style.border_width_right = 2
		style.border_width_bottom = 2
	else:
		style.border_color = Color(0.35, 0.30, 0.24, 0.9)
		style.border_width_left = 1
		style.border_width_top = 1
		style.border_width_right = 1
		style.border_width_bottom = 1

	return style
