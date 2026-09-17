extends Node2D

const TILE_SIZE := Vector2i(128, 64)
const MAP_WIDTH := 14
const MAP_HEIGHT := 14
const CAMERA_FOLLOW_SPEED := 6.0
const CAMERA_ZOOM := Vector2(3.35, 3.35)
const ASSET_DIR := "res://assets/kenney_isometric-miniature-dungeon 2/Isometric/"
const TURN_MOVE_METERS := 6.0
const RANGED_ATTACK_RANGE_METERS := 12.0
const COMBAT_TRIGGER_DISTANCE_CELLS := 6
const PLAYER_SPAWN_OFFSET := Vector2i(-6, 0)
# Enemy turn pacing: a short beat before the first enemy acts, a gap between
# enemies so the camera can settle on each one, and a beat before control
# comes back so the last hit is readable.
const ENEMY_TURN_DELAY_SECONDS := 0.6
const ENEMY_ACTION_GAP_SECONDS := 0.45
const ENEMY_TURN_HANDBACK_SECONDS := 0.3
# During the enemy turn the camera sits between the player and the acting
# enemy, biased toward the enemy, so both stay on screen.
const CAMERA_ENEMY_FOCUS_BLEND := 0.6
const TURN_MODE_ENEMY_BLOCKER_EXTRA_RADIUS := 20.0
const TEST_LOOT_SPREAD := 26.0

enum CombatState {
	EXPLORATION,
	PLAYER_TURN,
	ENEMY_TURN
}

enum PlayerTurnAction {
	MOVE,
	ATTACK,
	RANGED
}

@onready var custom_layout: TileMapLayer = get_node_or_null("MyCustomLayout")
@onready var custom_background: TileMapLayer = get_node_or_null("MyCustomBackground")
@onready var custom_objects: TileMapLayer = get_node_or_null("MyCustomObjects")
@onready var canvas_modulate: CanvasModulate = $CanvasModulate
@onready var camera_2d: Camera2D = $Camera2D
@onready var player: CharacterBody2D = $Player
@onready var nav_region: NavigationRegion2D = $NavigationRegion2D

@export var prefer_hand_painted_layout: bool = true
# Debug convenience: drop a few items beside the player on startup so the loot
# menu can be tested without hunting down a crate. Untick in the inspector once
# the level has its own loot worth testing against.
@export var spawn_test_loot: bool = true
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
var turn_ui_level_xp_label: Label
var turn_ui_order_panel: PanelContainer
var turn_ui_player_icon: TextureRect
var turn_ui_player_label: Label
var turn_ui_enemy_icons_container: HBoxContainer
var turn_ui_enemy_icon_entries: Array[Dictionary] = []
var turn_ui_actions_panel: PanelContainer
var turn_ui_attack_button: Button
var turn_ui_ranged_button: Button
var turn_ui_block_button: Button
var turn_ui_wait_button: Button
var turn_ui_end_turn_button: Button
var selected_player_turn_action: PlayerTurnAction = PlayerTurnAction.MOVE
var path_preview_glow: Line2D
var path_preview_line: Line2D
var path_preview_label: Label
var melee_range_ring: RangeRing
var ranged_range_ring: RangeRing
var _turn_meter_world_units_cache: float = -1.0
var music_exploration: AudioStreamPlayer
var music_combat: AudioStreamPlayer
var music_muted := true
var mute_button: Button
const MUSIC_CROSSFADE_SECONDS := 1.2
const MUSIC_VOLUME_DB := -6.0


func _ready() -> void:
	canvas_modulate.color = runtime_canvas_modulate_color
	_setup_turn_ui()
	_setup_music()

	active_nav_layer = custom_background
	_refresh_turn_meter_world_units()
	_setup_tile_set()
	_rebuild_navigation_for_layer(active_nav_layer)
	_place_player()
	_spawn_test_loot()
	_register_placed_enemies()
	_wire_enemy_ai_targets()
	_center_camera()

	if nav_region and nav_region.navigation_polygon:
		_original_nav_poly = nav_region.navigation_polygon.duplicate()

	_setup_path_preview()
	_setup_range_rings()


func _process(delta: float) -> void:
	var weight := clampf(delta * CAMERA_FOLLOW_SPEED, 0.0, 1.0)
	camera_2d.global_position = camera_2d.global_position.lerp(_get_camera_focus_position(), weight)
	_update_combat_state()
	_update_enemy_hover_state()
	_update_turn_ui()
	_update_path_preview()
	_update_range_rings()


func _get_camera_focus_position() -> Vector2:
	if combat_state == CombatState.ENEMY_TURN \
			and active_enemy_turn_actor != null and is_instance_valid(active_enemy_turn_actor):
		return player.global_position.lerp(active_enemy_turn_actor.global_position, CAMERA_ENEMY_FOCUS_BLEND)
	return player.global_position


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


func _register_placed_enemies() -> void:
	var found: Array[CharacterBody2D] = []
	for node in get_tree().get_nodes_in_group("enemies"):
		if not (node is CharacterBody2D):
			continue
		if not is_ancestor_of(node):
			continue
		found.append(node as CharacterBody2D)

	if found.is_empty():
		push_warning("No enemies found: add instances of res://scenes/enemy.tscn under Main (group \"enemies\").")
		return

	found.sort_custom(func(a: CharacterBody2D, b: CharacterBody2D) -> bool:
		return str(a.get_path()) < str(b.get_path())
	)

	enemy = found[0]
	extra_enemies.clear()
	for i in range(1, found.size()):
		extra_enemies.append(found[i])


func _wire_enemy_ai_targets() -> void:
	for enemy_actor in _get_all_alive_enemies():
		if enemy_actor.has_method("set_target"):
			enemy_actor.call("set_target", player)


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


func _spawn_test_loot() -> void:
	if not spawn_test_loot:
		return

	# Goes out through LootDropper like every other drop, so what you test is
	# exactly what a crate or a dead enemy produces. One of everything, so the
	# inventory screen has a full set of gear to try on.
	var items: Array[Item] = [
		ItemFactory.create_sword(),
		ItemFactory.create_dagger(),
		ItemFactory.create_health_potion(),
	]
	for builder in ItemFactory.gear_builders():
		items.append(builder.call())
	LootDropper.drop_items(player, items, TEST_LOOT_SPREAD)


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
			if selected_player_turn_action == PlayerTurnAction.RANGED:
				_request_player_turn_ranged_attack(clicked_enemy as CharacterBody2D)
			else:
				_request_player_turn_engage_enemy(clicked_enemy as CharacterBody2D)
		else:
			_request_player_turn_move(click_position)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_accept"):
		_request_end_player_turn()
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
	_set_player_turn_action(PlayerTurnAction.MOVE)
	combat_state = CombatState.PLAYER_TURN
	enemy_turn_running = false
	active_enemy_turn_actor = null

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

	_crossfade_music(music_combat, music_exploration)
	CombatFx.announce("COMBAT!", CombatFx.COLOR_COMBAT, 0.7)
	CombatFx.shake(4.0, 0.2)
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
	var player_alive := true
	if player.has_method("is_alive"):
		player_alive = bool(player.call("is_alive"))
	if not player_alive:
		CombatFx.announce("DEFEATED", CombatFx.COLOR_ENEMY_TURN, 1.4)
	elif _get_all_alive_enemies().is_empty():
		CombatFx.announce("VICTORY", CombatFx.COLOR_COMBAT, 1.2)

	combat_state = CombatState.EXPLORATION
	_set_player_turn_action(PlayerTurnAction.MOVE)
	enemy_turn_running = false
	active_enemy_turn_actor = null
	_set_hovered_enemy(null)
	active_enemy_turn_actor = null

	if player.has_method("set_turn_based_combat"):
		player.call("set_turn_based_combat", false)
	for enemy_actor in _get_all_alive_enemies():
		if enemy_actor.has_method("set_turn_based_combat"):
			enemy_actor.call("set_turn_based_combat", false)

	_crossfade_music(music_exploration, music_combat)
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



# Coroutine: resolves when the swing has landed. Callers hold
# `player_turn_action_running` across the await so End Turn can't fire
# mid-swing.
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
	if player.global_position.distance_to(target_enemy.global_position) > _get_player_melee_range():
		return

	await player.try_attack(target_enemy)
	_update_turn_ui()


# The melee reach the rules actually use: the equipped weapon's range, falling
# back to the bare `attack_range`. main.gd used to test `attack_range` while
# player.gd tested the weapon, so a short dagger could pass here and be refused
# there with no feedback.
func _get_player_melee_range() -> float:
	if player.has_method("get_melee_range"):
		return float(player.call("get_melee_range"))
	return float(player.get("attack_range"))


func _get_ranged_attack_range_world() -> float:
	return RANGED_ATTACK_RANGE_METERS * _get_turn_meter_world_units()


func _request_player_turn_ranged_attack(target_enemy: CharacterBody2D = null) -> void:
	if combat_state != CombatState.PLAYER_TURN:
		return
	if player_turn_action_running:
		return
	if not player.has_method("try_ranged_attack"):
		return
	if not player.call("can_turn_attack"):
		CombatFx.popup_text(player.global_position + Vector2(0, -50), "No attack left", CombatFx.COLOR_WARNING, 16)
		return
	if target_enemy == null:
		target_enemy = _get_closest_enemy_to_player()
	if target_enemy == null:
		return
	var max_dist := _get_ranged_attack_range_world()
	if player.global_position.distance_to(target_enemy.global_position) > max_dist:
		CombatFx.popup_text(target_enemy.global_position + Vector2(0, -50), "Out of range", CombatFx.COLOR_WARNING, 16)
		return

	player_turn_action_running = true
	await player.try_ranged_attack(target_enemy)
	player_turn_action_running = false
	_set_player_turn_action(PlayerTurnAction.MOVE)
	_update_turn_ui()


func _request_player_turn_engage_enemy(target_enemy: CharacterBody2D = null) -> void:
	if combat_state != CombatState.PLAYER_TURN:
		return
	if player_turn_action_running:
		return
	if target_enemy == null:
		target_enemy = _get_closest_enemy_to_player()
	if target_enemy == null:
		return

	var can_attack := player.has_method("can_turn_attack") and bool(player.call("can_turn_attack"))
	if not can_attack:
		# Still walk up to them - the click is a clear "go there" - but say why
		# nothing else is going to happen.
		CombatFx.popup_text(player.global_position + Vector2(0, -50), "No attack left", CombatFx.COLOR_WARNING, 16)

	player_turn_action_running = true

	# If already in range, attack immediately.
	if _player_can_attack_enemy_now(target_enemy):
		await _request_player_turn_attack(target_enemy)
		player_turn_action_running = false
		return

	if not player.has_method("get_turn_remaining_move_meters"):
		player_turn_action_running = false
		return

	var remaining_meters := float(player.call("get_turn_remaining_move_meters"))
	if remaining_meters <= 0.0 and can_attack:
		CombatFx.popup_text(target_enemy.global_position + Vector2(0, -50), "Out of reach", CombatFx.COLOR_WARNING, 16)
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

	if _player_can_attack_enemy_now(target_enemy):
		await _request_player_turn_attack(target_enemy)
	elif can_attack and is_instance_valid(target_enemy):
		CombatFx.popup_text(target_enemy.global_position + Vector2(0, -50), "Out of reach", CombatFx.COLOR_WARNING, 16)

	player_turn_action_running = false


func _request_end_player_turn() -> void:
	if combat_state != CombatState.PLAYER_TURN:
		return
	if player_turn_action_running:
		return
	if player != null and player.has_method("is_moving") and player.call("is_moving"):
		return
	_begin_enemy_turn()


func _begin_enemy_turn() -> void:
	if combat_state != CombatState.PLAYER_TURN:
		return
	_set_player_turn_action(PlayerTurnAction.MOVE)
	if player.has_method("end_turn"):
		player.call("end_turn")
	combat_state = CombatState.ENEMY_TURN
	enemy_turn_running = false
	CombatFx.announce("ENEMY TURN", CombatFx.COLOR_ENEMY_TURN, 0.6)
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

	var first_actor := true
	for enemy_actor in _get_all_alive_enemies():
		active_enemy_turn_actor = enemy_actor
		if enemy_actor.has_method("start_turn"):
			enemy_actor.call("start_turn", TURN_MOVE_METERS)

		# Let the camera arrive on this enemy before it does anything.
		if not first_actor:
			await get_tree().create_timer(ENEMY_ACTION_GAP_SECONDS).timeout
			if combat_state != CombatState.ENEMY_TURN:
				enemy_turn_running = false
				return
			if not is_instance_valid(enemy_actor) or (enemy_actor.has_method("is_alive") and not bool(enemy_actor.call("is_alive"))):
				continue
		first_actor = false

		var used_meters := _request_enemy_turn_move_by_distance(enemy_actor, TURN_MOVE_METERS)
		if used_meters > 0.0 and enemy_actor.has_method("consume_turn_movement_meters"):
			enemy_actor.call("consume_turn_movement_meters", used_meters)

		if enemy_actor.has_method("is_moving"):
			while enemy_actor.call("is_moving"):
				await get_tree().physics_frame
				if combat_state != CombatState.ENEMY_TURN:
					enemy_turn_running = false
					return
				if not is_instance_valid(enemy_actor):
					break

		if is_instance_valid(enemy_actor) and enemy_actor.has_method("try_attack"):
			await enemy_actor.try_attack(player)
		if is_instance_valid(enemy_actor) and enemy_actor.has_method("end_turn"):
			enemy_actor.call("end_turn")

	# A beat so the last hit lands visually before the HUD flips back.
	await get_tree().create_timer(ENEMY_TURN_HANDBACK_SECONDS).timeout
	if combat_state != CombatState.ENEMY_TURN:
		enemy_turn_running = false
		return

	if player.has_method("start_turn"):
		player.call("start_turn", TURN_MOVE_METERS)
	_set_player_turn_action(PlayerTurnAction.MOVE)
	active_enemy_turn_actor = null
	combat_state = CombatState.PLAYER_TURN
	enemy_turn_running = false
	CombatFx.announce("YOUR TURN", CombatFx.COLOR_PLAYER_TURN, 0.6)
	_update_turn_ui()


func _player_can_attack_enemy_now(target_enemy: CharacterBody2D = null) -> bool:
	if not player.has_method("can_turn_attack"):
		return false
	if not player.call("can_turn_attack"):
		return false
	if target_enemy == null or not is_instance_valid(target_enemy):
		target_enemy = _get_closest_enemy_to_player()
	if target_enemy == null:
		return false
	return player.global_position.distance_to(target_enemy.global_position) <= _get_player_melee_range()


const ENEMY_CLICK_RADIUS := 24.0

func _get_enemy_at_position(world_position: Vector2) -> Node2D:
	var closest_enemy: Node2D = null
	var closest_dist := ENEMY_CLICK_RADIUS

	for enemy_actor in _get_all_alive_enemies():
		var dist := world_position.distance_to(enemy_actor.global_position)
		if dist < closest_dist:
			closest_dist = dist
			closest_enemy = enemy_actor

	return closest_enemy


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


func _request_enemy_turn_move_by_distance(enemy_actor: CharacterBody2D, max_meters: float) -> float:
	if active_nav_layer == null:
		return 0.0
	if enemy_actor == null or not is_instance_valid(enemy_actor):
		return 0.0
	if max_meters <= 0.0:
		return 0.0

	_refresh_enemy_blocked_cells(enemy_actor)
	_rebuild_navigation_for_layer(active_nav_layer)

	var enemy_attack_range := float(enemy_actor.get("attack_range"))
	var approach_point := _compute_approach_world_point(enemy_actor.global_position, player.global_position, maxf(4.0, enemy_attack_range - 20.0))
	var world_path := _build_world_path_from_navigation(enemy_actor.global_position, approach_point, enemy_actor)
	if world_path.size() <= 1:
		return 0.0

	var meter_units := _get_turn_meter_world_units()
	var max_world_distance := max_meters * meter_units
	var path_length := _path_length(world_path)
	if path_length <= 0.001:
		return 0.0

	var used_world_distance := minf(max_world_distance, path_length)
	var destination_world := _point_on_path_at_distance(world_path, used_world_distance)
	if enemy_actor.has_method("set_navigation_target"):
		enemy_actor.call("set_navigation_target", destination_world)

	return used_world_distance / meter_units


func _get_all_alive_enemies() -> Array[CharacterBody2D]:
	var seen: Dictionary = {}
	var result: Array[CharacterBody2D] = []

	for node in get_tree().get_nodes_in_group("enemies"):
		_collect_alive_enemy_under_main(node, seen, result)

	if enemy != null and is_instance_valid(enemy):
		_collect_alive_enemy_under_main(enemy, seen, result)
	for enemy_actor in extra_enemies:
		if enemy_actor != null and is_instance_valid(enemy_actor):
			_collect_alive_enemy_under_main(enemy_actor, seen, result)

	result.sort_custom(func(a: CharacterBody2D, b: CharacterBody2D) -> bool:
		return str(a.get_path()) < str(b.get_path())
	)
	return result


func _collect_alive_enemy_under_main(node: Node, seen: Dictionary, out: Array[CharacterBody2D]) -> void:
	if not (node is CharacterBody2D):
		return
	var actor := node as CharacterBody2D
	if not is_ancestor_of(actor):
		return
	if seen.has(actor):
		return
	if actor.has_method("is_alive") and not bool(actor.call("is_alive")):
		return
	seen[actor] = true
	out.append(actor)


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

	var world_path := _build_world_path_from_navigation(player.global_position, target_world_position, player)
	if world_path.size() <= 1:
		return 0.0

	var meter_units := _get_turn_meter_world_units()
	var max_world_distance := max_meters * meter_units
	var path_length := _path_length(world_path)
	if path_length <= 0.001:
		return 0.0

	var used_world_distance := minf(max_world_distance, path_length)
	var destination_world := _point_on_path_at_distance(world_path, used_world_distance)
	if player.has_method("set_navigation_target"):
		player.call("set_navigation_target", destination_world)

	return used_world_distance / meter_units


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


func _build_world_path_from_navigation(from_world: Vector2, to_world: Vector2, path_actor: CharacterBody2D = null) -> Array[Vector2]:
	var actor := path_actor if path_actor != null else player
	var nav_agent := actor.get_node_or_null("NavigationAgent2D") as NavigationAgent2D
	if nav_agent == null:
		return []

	var nav_map_rid := nav_agent.get_navigation_map()
	if not nav_map_rid.is_valid():
		return []

	var from_point := NavigationServer2D.map_get_closest_point(nav_map_rid, from_world)
	var to_point := NavigationServer2D.map_get_closest_point(nav_map_rid, to_world)
	var nav_path := NavigationServer2D.map_get_path(nav_map_rid, from_point, to_point, true)
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


func _refresh_turn_meter_world_units() -> void:
	_turn_meter_world_units_cache = -1.0
	_get_turn_meter_world_units()


func _get_turn_meter_world_units() -> float:
	if _turn_meter_world_units_cache > 0.0:
		return _turn_meter_world_units_cache
	if active_nav_layer == null:
		_turn_meter_world_units_cache = 64.0
		return _turn_meter_world_units_cache
	var used_rect := active_nav_layer.get_used_rect()
	if used_rect.size == Vector2i.ZERO:
		_turn_meter_world_units_cache = 64.0
		return _turn_meter_world_units_cache
	var c0: Vector2i = used_rect.position
	var c1: Vector2i = c0
	for delta in [Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0), Vector2i(0, -1)]:
		var cand: Vector2i = c0 + delta
		if used_rect.has_point(cand):
			c1 = cand
			break
	if c1 == c0:
		_turn_meter_world_units_cache = 64.0
		return _turn_meter_world_units_cache
	var d := active_nav_layer.map_to_local(c0).distance_to(active_nav_layer.map_to_local(c1))
	if d <= 0.001:
		d = 64.0
	_turn_meter_world_units_cache = d
	return _turn_meter_world_units_cache


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


func _setup_path_preview() -> void:
	path_preview_glow = Line2D.new()
	path_preview_glow.name = "PathPreviewGlow"
	path_preview_glow.width = 6.0
	path_preview_glow.default_color = Color(0.6, 0.75, 1.0, 0.25)
	path_preview_glow.z_index = 9
	path_preview_glow.visible = false
	add_child(path_preview_glow)

	path_preview_line = Line2D.new()
	path_preview_line.name = "PathPreviewLine"
	path_preview_line.width = 2.0
	path_preview_line.default_color = Color(1.0, 1.0, 1.0, 0.9)
	path_preview_line.z_index = 10
	path_preview_line.visible = false
	add_child(path_preview_line)

	path_preview_label = Label.new()
	path_preview_label.name = "PathPreviewLabel"
	path_preview_label.z_index = 11
	path_preview_label.visible = false
	path_preview_label.add_theme_font_size_override("font_size", 11)
	path_preview_label.add_theme_color_override("font_color", Color(1.0, 0.95, 0.7, 0.95))
	path_preview_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	path_preview_label.add_theme_constant_override("shadow_offset_x", 1)
	path_preview_label.add_theme_constant_override("shadow_offset_y", 1)
	add_child(path_preview_label)


func _setup_range_rings() -> void:
	# Two rings under the player in turn mode: the melee reach (always, faint)
	# and the ranged reach (dashed, only while aiming a ranged shot). They are
	# the same circles the attack checks use, so "inside the ring" means "will
	# hit".
	melee_range_ring = RangeRing.new()
	melee_range_ring.name = "MeleeRangeRing"
	melee_range_ring.z_index = 8
	melee_range_ring.visible = false
	add_child(melee_range_ring)

	ranged_range_ring = RangeRing.new()
	ranged_range_ring.name = "RangedRangeRing"
	ranged_range_ring.z_index = 8
	ranged_range_ring.visible = false
	add_child(ranged_range_ring)


func _update_range_rings() -> void:
	if melee_range_ring == null or ranged_range_ring == null:
		return
	var show := combat_state == CombatState.PLAYER_TURN and not InventoryScreen.is_open()
	if show and player.has_method("can_turn_attack"):
		show = bool(player.call("can_turn_attack"))
	if not show:
		melee_range_ring.hide_ring()
		ranged_range_ring.hide_ring()
		return

	melee_range_ring.global_position = player.global_position
	ranged_range_ring.global_position = player.global_position
	if selected_player_turn_action == PlayerTurnAction.RANGED:
		melee_range_ring.hide_ring()
		ranged_range_ring.show_ring(_get_ranged_attack_range_world(), Color(0.55, 0.85, 1.0, 0.55), true)
	else:
		ranged_range_ring.hide_ring()
		var melee_color := Color(1.0, 0.9, 0.7, 0.28)
		if selected_player_turn_action == PlayerTurnAction.ATTACK:
			melee_color = Color(1.0, 0.85, 0.5, 0.6)
		melee_range_ring.show_ring(_get_player_melee_range(), melee_color)


func _setup_music() -> void:
	music_exploration = AudioStreamPlayer.new()
	music_exploration.name = "MusicExploration"
	music_exploration.bus = "Master"
	music_exploration.volume_db = MUSIC_VOLUME_DB
	var exploration_stream := load("res://assets/music/forest1.mp3") as AudioStream
	if exploration_stream is AudioStreamMP3:
		exploration_stream.loop = true
	music_exploration.stream = exploration_stream
	add_child(music_exploration)

	music_combat = AudioStreamPlayer.new()
	music_combat.name = "MusicCombat"
	music_combat.bus = "Master"
	music_combat.volume_db = -80.0
	var combat_stream := load("res://assets/music/combat1.mp3") as AudioStream
	if combat_stream is AudioStreamMP3:
		combat_stream.loop = true
	music_combat.stream = combat_stream
	add_child(music_combat)

	if not music_muted:
		music_exploration.play()
		music_combat.play()

	_setup_mute_button()


func _setup_mute_button() -> void:
	mute_button = Button.new()
	mute_button.name = "MuteButton"
	mute_button.toggle_mode = true
	mute_button.button_pressed = music_muted
	mute_button.text = "Sound: OFF" if music_muted else "Sound: ON"
	mute_button.custom_minimum_size = Vector2(100, 32)
	mute_button.anchor_left = 1.0
	mute_button.anchor_top = 0.0
	mute_button.anchor_right = 1.0
	mute_button.anchor_bottom = 0.0
	mute_button.offset_left = -118.0
	mute_button.offset_top = 18.0
	mute_button.offset_right = -18.0
	mute_button.offset_bottom = 50.0

	var style_normal := StyleBoxFlat.new()
	style_normal.bg_color = Color(0.08, 0.07, 0.05, 0.92)
	style_normal.border_color = Color(0.66, 0.56, 0.33, 0.95)
	style_normal.border_width_left = 2
	style_normal.border_width_top = 2
	style_normal.border_width_right = 2
	style_normal.border_width_bottom = 2
	style_normal.corner_radius_top_left = 4
	style_normal.corner_radius_top_right = 4
	style_normal.corner_radius_bottom_left = 4
	style_normal.corner_radius_bottom_right = 4
	style_normal.content_margin_left = 8
	style_normal.content_margin_right = 8

	var style_hover := style_normal.duplicate() as StyleBoxFlat
	style_hover.bg_color = Color(0.12, 0.11, 0.08, 0.95)

	var style_pressed := style_normal.duplicate() as StyleBoxFlat
	style_pressed.bg_color = Color(0.05, 0.04, 0.03, 0.95)

	mute_button.add_theme_stylebox_override("normal", style_normal)
	mute_button.add_theme_stylebox_override("hover", style_hover)
	mute_button.add_theme_stylebox_override("pressed", style_pressed)
	mute_button.add_theme_stylebox_override("focus", style_normal)
	mute_button.add_theme_color_override("font_color", Color(0.88, 0.78, 0.53, 1.0))
	mute_button.add_theme_color_override("font_hover_color", Color(0.95, 0.88, 0.65, 1.0))
	mute_button.add_theme_font_size_override("font_size", 13)
	mute_button.focus_mode = Control.FOCUS_NONE

	mute_button.pressed.connect(_on_mute_button_pressed)
	turn_ui_layer.add_child(mute_button)


func _on_mute_button_pressed() -> void:
	music_muted = mute_button.button_pressed
	if music_muted:
		music_exploration.stop()
		music_combat.stop()
	else:
		music_exploration.play()
		music_combat.play()
	mute_button.text = "Sound: OFF" if music_muted else "Sound: ON"


func _crossfade_music(fade_in_player: AudioStreamPlayer, fade_out_player: AudioStreamPlayer) -> void:
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(fade_in_player, "volume_db", MUSIC_VOLUME_DB, MUSIC_CROSSFADE_SECONDS)
	tween.tween_property(fade_out_player, "volume_db", -80.0, MUSIC_CROSSFADE_SECONDS)


func _hide_path_preview() -> void:
	path_preview_line.visible = false
	path_preview_glow.visible = false
	path_preview_label.visible = false


func _update_path_preview() -> void:
	if InventoryScreen.is_open():
		_hide_path_preview()
		return
	if combat_state != CombatState.PLAYER_TURN or player_turn_action_running:
		_hide_path_preview()
		return
	if selected_player_turn_action != PlayerTurnAction.MOVE:
		_hide_path_preview()
		return

	if player.has_method("is_moving") and player.call("is_moving"):
		_hide_path_preview()
		return

	var remaining_meters := 0.0
	if player.has_method("get_turn_remaining_move_meters"):
		remaining_meters = float(player.call("get_turn_remaining_move_meters"))
	if remaining_meters <= 0.01:
		_hide_path_preview()
		return

	var mouse_world := get_global_mouse_position()
	var world_path := _build_world_path_from_navigation(player.global_position, mouse_world, player)
	if world_path.size() <= 1:
		_hide_path_preview()
		return

	var meter_units := _get_turn_meter_world_units()
	var max_world_distance := remaining_meters * meter_units
	var total_length := _path_length(world_path)
	var used_distance := minf(max_world_distance, total_length)
	var used_meters := used_distance / meter_units

	var trimmed: Array[Vector2] = []
	trimmed.append(world_path[0])
	var remaining_dist := used_distance
	for i in range(1, world_path.size()):
		var seg_len := world_path[i - 1].distance_to(world_path[i])
		if remaining_dist <= seg_len:
			trimmed.append(world_path[i - 1].lerp(world_path[i], remaining_dist / maxf(seg_len, 0.001)))
			break
		trimmed.append(world_path[i])
		remaining_dist -= seg_len

	path_preview_line.clear_points()
	path_preview_glow.clear_points()
	for p in trimmed:
		path_preview_line.add_point(p)
		path_preview_glow.add_point(p)

	var over_budget := total_length > max_world_distance
	if over_budget:
		path_preview_line.default_color = Color(1.0, 0.75, 0.75, 0.9)
		path_preview_glow.default_color = Color(1.0, 0.5, 0.5, 0.2)
	else:
		path_preview_line.default_color = Color(1.0, 1.0, 1.0, 0.9)
		path_preview_glow.default_color = Color(0.6, 0.75, 1.0, 0.25)
	path_preview_line.visible = true
	path_preview_glow.visible = true

	var end_point := trimmed[trimmed.size() - 1]
	path_preview_label.text = "%.1fm / %.1fm" % [used_meters, remaining_meters]
	path_preview_label.position = end_point + Vector2(6, -14)
	path_preview_label.visible = true


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

	turn_ui_level_xp_label = Label.new()
	turn_ui_level_xp_label.text = "Level 1 | XP: 0 / 100"
	turn_ui_level_xp_label.add_theme_color_override("font_color", Color(0.82, 0.78, 0.95, 1.0))
	vbox.add_child(turn_ui_level_xp_label)

	turn_ui_actions_panel = PanelContainer.new()
	turn_ui_actions_panel.name = "TurnActionsUI"
	turn_ui_actions_panel.visible = false
	turn_ui_actions_panel.anchor_left = 0.5
	turn_ui_actions_panel.anchor_top = 1.0
	turn_ui_actions_panel.anchor_right = 0.5
	turn_ui_actions_panel.anchor_bottom = 1.0
	turn_ui_actions_panel.offset_left = -410.0
	turn_ui_actions_panel.offset_top = -82.0
	turn_ui_actions_panel.offset_right = 410.0
	turn_ui_actions_panel.offset_bottom = -18.0
	turn_ui_actions_panel.add_theme_stylebox_override("panel", panel_style.duplicate())
	turn_ui_layer.add_child(turn_ui_actions_panel)

	var actions_margin := MarginContainer.new()
	actions_margin.add_theme_constant_override("margin_left", 12)
	actions_margin.add_theme_constant_override("margin_top", 8)
	actions_margin.add_theme_constant_override("margin_right", 12)
	actions_margin.add_theme_constant_override("margin_bottom", 8)
	turn_ui_actions_panel.add_child(actions_margin)

	var actions_hbox := HBoxContainer.new()
	actions_hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	actions_hbox.add_theme_constant_override("separation", 10)
	actions_margin.add_child(actions_hbox)

	turn_ui_attack_button = Button.new()
	turn_ui_attack_button.text = "Attack"
	turn_ui_attack_button.toggle_mode = true
	turn_ui_attack_button.custom_minimum_size = Vector2(128, 36)
	turn_ui_attack_button.pressed.connect(_on_turn_attack_button_pressed)
	actions_hbox.add_child(turn_ui_attack_button)

	turn_ui_ranged_button = Button.new()
	turn_ui_ranged_button.text = "Ranged 12m"
	turn_ui_ranged_button.toggle_mode = true
	turn_ui_ranged_button.custom_minimum_size = Vector2(128, 36)
	turn_ui_ranged_button.pressed.connect(_on_turn_ranged_button_pressed)
	actions_hbox.add_child(turn_ui_ranged_button)

	turn_ui_block_button = Button.new()
	turn_ui_block_button.text = "Block"
	turn_ui_block_button.custom_minimum_size = Vector2(128, 36)
	turn_ui_block_button.pressed.connect(_on_turn_block_button_pressed)
	actions_hbox.add_child(turn_ui_block_button)

	turn_ui_wait_button = Button.new()
	turn_ui_wait_button.text = "Wait"
	turn_ui_wait_button.custom_minimum_size = Vector2(128, 36)
	turn_ui_wait_button.pressed.connect(_on_turn_wait_button_pressed)
	actions_hbox.add_child(turn_ui_wait_button)

	turn_ui_end_turn_button = Button.new()
	turn_ui_end_turn_button.text = "End Turn"
	turn_ui_end_turn_button.custom_minimum_size = Vector2(128, 36)
	turn_ui_end_turn_button.pressed.connect(_on_turn_end_turn_button_pressed)
	actions_hbox.add_child(turn_ui_end_turn_button)

	_rebuild_turn_enemy_icons()


func _update_turn_ui() -> void:
	# The inventory screen is a full-screen modal; the combat HUD behind it is
	# just noise, and none of its buttons are reachable anyway.
	var hud_visible := not InventoryScreen.is_open()
	if turn_ui_layer != null:
		turn_ui_layer.visible = hud_visible
	if player != null and player.has_method("set_overhead_ui_visible"):
		player.call("set_overhead_ui_visible", hud_visible)

	if turn_ui_panel == null:
		return

	var in_turn_mode := combat_state != CombatState.EXPLORATION
	turn_ui_panel.visible = in_turn_mode
	if turn_ui_order_panel != null:
		turn_ui_order_panel.visible = in_turn_mode
	if turn_ui_actions_panel != null:
		turn_ui_actions_panel.visible = in_turn_mode
	if not in_turn_mode:
		return

	var alive_enemies := _get_all_alive_enemies()
	if turn_ui_enemy_icon_entries.size() != alive_enemies.size():
		_rebuild_turn_enemy_icons()

	var can_attack := false
	var is_blocking := false
	if player != null and player.has_method("can_turn_attack"):
		can_attack = bool(player.call("can_turn_attack"))
	if player != null and player.has_method("is_blocking"):
		is_blocking = bool(player.call("is_blocking"))

	var can_player_use_actions := combat_state == CombatState.PLAYER_TURN and not player_turn_action_running
	if can_player_use_actions and player != null and player.has_method("is_moving"):
		can_player_use_actions = not bool(player.call("is_moving"))
	if not can_attack and (selected_player_turn_action == PlayerTurnAction.ATTACK or selected_player_turn_action == PlayerTurnAction.RANGED):
		_set_player_turn_action(PlayerTurnAction.MOVE)

	if turn_ui_attack_button != null:
		turn_ui_attack_button.disabled = not can_player_use_actions or not can_attack
		turn_ui_attack_button.button_pressed = selected_player_turn_action == PlayerTurnAction.ATTACK
		turn_ui_attack_button.text = "Melee (Select Target)" if selected_player_turn_action == PlayerTurnAction.ATTACK else "Melee"
	if turn_ui_ranged_button != null:
		turn_ui_ranged_button.disabled = not can_player_use_actions or not can_attack
		turn_ui_ranged_button.button_pressed = selected_player_turn_action == PlayerTurnAction.RANGED
		turn_ui_ranged_button.text = "Ranged 12m (Select)" if selected_player_turn_action == PlayerTurnAction.RANGED else "Ranged 12m"
	if turn_ui_block_button != null:
		turn_ui_block_button.disabled = not can_player_use_actions
		turn_ui_block_button.text = "Block (Active)" if is_blocking else "Block"
	if turn_ui_wait_button != null:
		turn_ui_wait_button.disabled = not can_player_use_actions
	if turn_ui_end_turn_button != null:
		turn_ui_end_turn_button.disabled = not can_player_use_actions
		# Pulse End Turn once there is nothing left to spend, so the eye goes to
		# the one button that matters.
		var remaining_move := 0.0
		if player != null and player.has_method("get_turn_remaining_move_meters"):
			remaining_move = float(player.call("get_turn_remaining_move_meters"))
		var nothing_left := can_player_use_actions and not can_attack and remaining_move <= 0.05
		if nothing_left:
			var pulse := 0.5 + 0.5 * sin(Time.get_ticks_msec() * 0.008)
			turn_ui_end_turn_button.modulate = Color.WHITE.lerp(Color(1.45, 1.3, 0.75, 1.0), pulse)
		else:
			turn_ui_end_turn_button.modulate = Color.WHITE

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
		var can_attack_now := false

		if player != null and player.has_method("get_turn_remaining_move_meters"):
			remaining_meters = float(player.call("get_turn_remaining_move_meters"))
		if player != null and player.has_method("can_turn_attack"):
			can_attack_now = bool(player.call("can_turn_attack"))

		phase_text = "Phase: Your turn (Space = end turn)"
		if not can_attack_now and remaining_meters <= 0.05:
			phase_text = "Phase: Nothing left - end turn (Space)"
		move_text = "Movement: %.1f m left" % remaining_meters
		var attack_mode_text := "Move"
		match selected_player_turn_action:
			PlayerTurnAction.ATTACK:
				attack_mode_text = "Melee aim"
			PlayerTurnAction.RANGED:
				attack_mode_text = "Ranged 12m aim"
			_:
				attack_mode_text = "Move"
		attack_text = "Actions: %s | Mode: %s" % [("Ready" if can_attack_now else "Used"), attack_mode_text]
		turn_ui_phase_label.add_theme_color_override("font_color", Color(0.62, 0.84, 0.66, 1.0))
		turn_ui_move_label.add_theme_color_override("font_color", Color(0.86, 0.86, 0.84, 1.0))
		turn_ui_attack_label.add_theme_color_override("font_color", Color(0.65, 0.88, 0.67, 1.0) if can_attack_now else Color(0.88, 0.57, 0.57, 1.0))
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

	if turn_ui_level_xp_label != null and player != null:
		if player.has_method("get_player_level"):
			var plv := int(player.call("get_player_level"))
			var cur_xp := 0.0
			var need_xp := 100.0
			if player.has_method("get_experience_toward_next"):
				cur_xp = float(player.call("get_experience_toward_next"))
			if player.has_method("get_xp_required_for_next_level"):
				need_xp = float(player.call("get_xp_required_for_next_level"))
			turn_ui_level_xp_label.text = "Level %d | XP: %.0f / %.0f" % [plv, cur_xp, need_xp]


func _set_player_turn_action(action: PlayerTurnAction) -> void:
	selected_player_turn_action = action


func _on_turn_attack_button_pressed() -> void:
	if combat_state != CombatState.PLAYER_TURN:
		return
	if player_turn_action_running:
		return
	if selected_player_turn_action == PlayerTurnAction.ATTACK:
		_set_player_turn_action(PlayerTurnAction.MOVE)
		_update_turn_ui()
		return
	if player != null and player.has_method("can_turn_attack"):
		if not bool(player.call("can_turn_attack")):
			return
	_set_player_turn_action(PlayerTurnAction.ATTACK)
	_update_turn_ui()


func _on_turn_ranged_button_pressed() -> void:
	if combat_state != CombatState.PLAYER_TURN:
		return
	if player_turn_action_running:
		return
	if selected_player_turn_action == PlayerTurnAction.RANGED:
		_set_player_turn_action(PlayerTurnAction.MOVE)
		_update_turn_ui()
		return
	if player != null and player.has_method("can_turn_attack"):
		if not bool(player.call("can_turn_attack")):
			return
	_set_player_turn_action(PlayerTurnAction.RANGED)
	_update_turn_ui()


func _on_turn_block_button_pressed() -> void:
	if combat_state != CombatState.PLAYER_TURN:
		return
	if player_turn_action_running:
		return
	if player != null and player.has_method("set_blocking"):
		player.call("set_blocking", true)
	_begin_enemy_turn()


func _on_turn_wait_button_pressed() -> void:
	if combat_state != CombatState.PLAYER_TURN:
		return
	if player_turn_action_running:
		return
	_begin_enemy_turn()


func _on_turn_end_turn_button_pressed() -> void:
	_request_end_player_turn()


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
	# Outside combat the outline tells you the enemy is a click-to-attack
	# target; inside it marks what a click will engage.
	if InventoryScreen.is_open() or LootMenu.is_open():
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
