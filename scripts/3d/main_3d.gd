extends Node3D

## 3D coordinator: the port of scripts/main.gd for a 3D level (WP4).
##
## The game rules, the CombatState machine, the turn flow, the engagement radius,
## the soul UI, the turn UI and the input routing are those of main.gd. What
## changed is only what was 2D: positions and paths are Vector3 (converted only
## through GroundMath), world paths come from NavigationServer3D, clicks are
## camera rays, and the overlays go through the section 7 APIs of
## docs/3d-port-contracts.md. Actors are duck-typed (section 5).
##
## Level node contract: docs/3d-port-contracts.md, section 9. Picking goes
## through WorldPicker and the level's CameraRig (section 6), popups and shake
## through the CombatFx adapters (section 7), loot through LootDropper and
## LootMenu (section 8). Integrated in WP8.

# Orthographic size handed to the CameraRig (contract, section 2).
const CAMERA_SIZE_M := 14.0
const TURN_MOVE_METERS := 6.0
# WP13: combat no longer starts by the 2D Manhattan-cell proximity
# (COMBAT_TRIGGER_DISTANCE_CELLS, 6). It starts when an enemy spots the player
# (`Enemy3D.can_spot`: inside its `detection_range` ring with a clear line of
# sight) or when the player lands a hit on an enemy in exploration (an ambush,
# `provoked_by_hit`). An enemy without `can_spot` (the WP0 stub) is read
# through its `detection_range` / `aggro_range` property as a plain distance.
const DETECTION_RANGE_PROPERTIES: Array[StringName] = [&"detection_range", &"aggro_range"]
# How far (in turn meters) from the player an enemy can be and still be part of
# a fight. On a big map this is what keeps one pack's fight from also taking
# turns for every other pack; newcomers join as they close in. WP13 raised it
# from the 2D 9.0 so a pack spread around a clearing joins its spotter.
const ENGAGE_RADIUS_METERS := 12.0
# Banners for the two ways a fight starts (WP13): spotted, or the first strike.
const ANNOUNCE_COMBAT := "COMBAT!"
const ANNOUNCE_AMBUSH := "AMBUSH!"
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
# Metres. The 2D values were pixels: 20 px extra blocker radius, 6 px personal
# space padding, 26 px test-loot ring (about 32 px to the metre there).
const TURN_MODE_ENEMY_BLOCKER_EXTRA_RADIUS := 0.6
const ENEMY_PERSONAL_SPACE_PADDING_M := 0.2
const TEST_LOOT_SPREAD_M := 0.8
# Fallback approach stop for an actor without the WP10 spacing rule (the WP0
# stubs): this far inside its reach (2D: max(4 px, range - 20 px)). Real actors
# answer `get_attack_approach_distance`, see `approach_distance_for`.
const ENEMY_APPROACH_BUFFER_M := 0.4
const ENEMY_APPROACH_MIN_M := 0.2
const DEFAULT_CHARACTER_RADIUS_M := 0.4
# The actors' own slack on a range check (ActorBase3D.ATTACK_RANGE_TOLERANCE):
# a turn-mode approach may stop exactly on the reach (WP10).
const ATTACK_RANGE_TOLERANCE_M := 0.05
# Popups anchor to the actor's OverheadAnchor; this is the fallback height.
const POPUP_HEIGHT_M := 1.8
# Collision layers, docs/3d-port-contracts.md section 3.
const LAYER_GROUND := 1
const LAYER_ACTORS := 2
const LAYER_PICKUPS := 4
const LAYER_PROPS := 8
# Grid used when the level has no NavigationRegion3D/Ground box to measure.
const FALLBACK_MAP_REGION := Rect2i(-20, -20, 40, 40)
# Physics frames to wait for the navigation map to sync a (baked) mesh.
const NAV_MAP_SYNC_MAX_FRAMES := 120
const MUSIC_CROSSFADE_SECONDS := 1.2
const MUSIC_VOLUME_DB := -6.0
# User arguments (after `--`) that skip the intro book or silence its narrator.
const NO_INTRO_ARGUMENT := "--no-intro"
const SILENT_INTRO_ARGUMENT := "--silent-intro"

enum CombatState {
	EXPLORATION,
	PLAYER_TURN,
	ENEMY_TURN
}

enum PlayerTurnAction {
	MOVE,
	ATTACK,
	RANGED,
	SPELL,
	ABILITY
}

# --- Gameplay expansion (docs/gameplay-expansion.md) --------------------------
# Ability bar hotkeys: 4 to 9 pick the bar's abilities in order (1-3 shift).
const ABILITY_HOTKEYS: Array[Key] = [KEY_4, KEY_5, KEY_6, KEY_7, KEY_8, KEY_9]
const SNEAK_KEY := KEY_C
const SKILL_TREE_KEY := KEY_K
# A hit from stealth only wakes the struck enemy's close neighbours and anyone
# who can actually see the body, not the whole 12 m around it.
const STEALTH_ALERT_RADIUS_M := 4.0
# Slipping away: at the end of the player's turn every engaged enemy is this far
# away and cannot see the body (or farther than ESCAPE_ANY_SIGHT_M), or the body
# is in smoke with nobody within ESCAPE_SMOKE_MIN_M. The fight then ends.
const ESCAPE_DISTANCE_M := 11.0
const ESCAPE_ANY_SIGHT_M := 15.0
const ESCAPE_SMOKE_MIN_M := 3.0
const ANNOUNCE_ESCAPED := "SLIPPED AWAY"
const RESPAWN_DELAY_SECONDS := 3.0
const INTERACT_RANGE_SLACK_M := 0.3
const INTERACT_WALK_TIMEOUT_SECONDS := 8.0
const MELEE_APPROACH_TIMEOUT_SECONDS := 5.0

@onready var player: CharacterBody3D = $Player
@onready var nav_region: NavigationRegion3D = get_node_or_null("NavigationRegion3D")
# The level's WP2 rig (section 6): the only camera a 3D level runs through.
@onready var camera_rig: CameraRig3D = get_node_or_null("CameraRig") as CameraRig3D

# Debug convenience: drop a few items beside the player on startup so the loot
# menu can be tested without hunting down a crate. Untick in the inspector once
# the level has its own loot worth testing against.
@export var spawn_test_loot: bool = true
# Scene instanced by `_spawn_additional_enemy`: the WP3c wolf by default.
@export var enemy_scene: PackedScene = preload("res://scenes/3d/wolf_3d.tscn")
# A level authored in the editor ships a baked NavigationMesh; a test scene may
# not, in which case the coordinator bakes one at start.
@export var bake_navmesh_if_empty: bool = true

@export_group("Intro")
# Chapter read in the 3D story book (StoryBook3D) when this level opens, once
# per session. Authored in StoryLibrary; leave empty for no narration.
@export var story_chapter_id: StringName = StoryLibrary.PROLOGUE
# Untick to test the level without the intro. The user argument `--no-intro`
# does the same without touching the scene; headless runs always skip it.
@export var intro_enabled: bool = true
# Untick for a silent book (still written on screen). `--silent-intro` does the
# same from the command line.
@export var intro_voice_enabled: bool = true
@export_group("")

var blocked_cells: Dictionary = {}
var enemy_blocked_cells: Dictionary = {}
var astar_grid: AStarGrid2D = AStarGrid2D.new()
# Cells covered by the walkable ground, from the Ground collision box (section 9).
var _map_region: Rect2i = FALLBACK_MAP_REGION
var _navmesh_ready := false
var enemy: CharacterBody3D
var extra_enemies: Array[CharacterBody3D] = []
# Instance ids of the enemies taking part in the current fight.
var engaged_enemies: Dictionary = {}
var combat_state: CombatState = CombatState.EXPLORATION
var enemy_turn_running := false
var active_enemy_turn_actor: CharacterBody3D
var hovered_enemy: CharacterBody3D
# The 3D pickup under the cursor; it never hit-tests itself (section 8).
var hovered_pickup: Node3D
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
# Mage spell buttons keyed by spell id. Built once; only shown for the mage.
var turn_ui_spell_buttons: Dictionary = {}
var turn_ui_soul_label: Label
var selected_player_turn_action: PlayerTurnAction = PlayerTurnAction.MOVE
var selected_spell_id: StringName = &""
# The Bound Three: the always-visible soul portraits and the shift status line.
var soul_ui_panel: PanelContainer
var soul_ui_buttons: Array[Button] = []
var soul_ui_status_label: Label
var _soul_ui_styled_kind := -1
# Overlays (section 7, WP5). The path preview lives under the level root and
# takes global points; the melee and ranged rings ride under the player body;
# the blast ring is moved onto the hovered enemy each frame.
var path_preview: PathPreview3D
var melee_range_ring: RangeRing3D
var ranged_range_ring: RangeRing3D
var spell_area_ring: RangeRing3D
var _camera_rig_focused := false
var music_exploration: AudioStreamPlayer
var music_combat: AudioStreamPlayer
var music_muted := true
var mute_button: Button
# The dark-fantasy story book; replaces the 2D StoryBook autoload in 3D levels.
var story_book: StoryBook3D
# Gameplay expansion: abilities, the skill tree, stealth, the world objects.
var ability_runner: AbilityRunner3D
var selected_ability_id: StringName = &""
var skill_tree_screen: SkillTreeScreen3D
var ability_bar_panel: PanelContainer
var ability_bar_row: HBoxContainer
var ability_bar_buttons: Dictionary = {}
var ability_bar_order: Array[Ability3D] = []
var _ability_bar_signature := ""
var sneak_button: Button
var skills_button: Button
var stealth_label: Label
var hover_hint_label: Label
var hovered_prop_target: Node3D
var _pending_interactable: Node3D
var _pending_interact_deadline_msec := 0
var _respawn_scheduled := false
var _respawn_point := Vector3.ZERO
var _has_respawn_point := false


func _ready() -> void:
	add_to_group("level_coordinator")
	_setup_turn_ui()
	_setup_soul_ui()
	_setup_music()
	_setup_gameplay_expansion()

	_map_region = _compute_map_region()
	_cache_blocked_cells_from_props()
	_rebuild_navigation_grid()
	_place_player()
	_respawn_point = GroundMath.flatten(player.global_position)
	_has_respawn_point = true
	# Spell radii are authored in meters; with 1 unit = 1 m this is 1.0.
	if player.has_method("set_turn_meter_world_units"):
		player.call("set_turn_meter_world_units", _get_turn_meter_world_units())
	_spawn_test_loot()
	_register_placed_enemies()
	# Enemy targets are wired once the navigation map has synced (`_setup_navmesh`):
	# Enemy3D.set_target routes at once, and a map query before the first sync
	# is a NavigationServer error (docs/deviations/wp3c.md, section 11).
	_setup_navmesh()
	_setup_camera()

	_setup_path_preview()
	_setup_range_rings()
	_setup_combat_fx_adapters()

	# Last, so the world is fully placed under the book before it opens.
	_setup_story_book()
	if should_play_intro():
		story_book.show_chapter_once(StoryLibrary.chapter(story_chapter_id))


func _setup_story_book() -> void:
	story_book = StoryBook3D.new()
	story_book.name = "StoryBook3D"
	story_book.voice_enabled = intro_voice_enabled \
			and not OS.get_cmdline_user_args().has(SILENT_INTRO_ARGUMENT)
	add_child(story_book)


## Whether the intro chapter opens at start: on unless the inspector switch,
## an empty chapter id or `--no-intro` turns it off. Headless runs skip it so
## the acceptance tests stay deterministic; they open the book themselves.
func should_play_intro() -> bool:
	if not intro_enabled or story_chapter_id == &"":
		return false
	if DisplayServer.get_name() == "headless":
		return false
	return not OS.get_cmdline_user_args().has(NO_INTRO_ARGUMENT)


func _exit_tree() -> void:
	# The CombatFx autoload outlives this level; put it back into its 2D state
	# so the hub does not project popups through a freed camera (section 7).
	CombatFx.set_world_projector(Callable())
	CombatFx.set_shake_target(null)


func _process(_delta: float) -> void:
	_update_camera_rig()
	_update_combat_state()
	_update_hover_state()
	_update_turn_ui()
	_update_path_preview()
	_update_range_rings()
	_update_pending_interaction()
	_update_ability_bar()
	_update_stealth_label()


func _unhandled_input(event: InputEvent) -> void:
	if _handle_expansion_keys(event):
		get_viewport().set_input_as_handled()
		return
	if combat_state != CombatState.EXPLORATION:
		_handle_turn_input(event)
		return

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		var screen_pos: Vector2 = event.position
		# Loot first. In 2D the pickup swallowed the click itself; in 3D the
		# coordinator picks (section 8).
		if _try_click_pickup(screen_pos):
			get_viewport().set_input_as_handled()
			return
		if selected_player_turn_action == PlayerTurnAction.ABILITY:
			_handle_ability_click(screen_pos)
			get_viewport().set_input_as_handled()
			return
		_pending_interactable = null
		var clicked_enemy := _pick_enemy(screen_pos)
		if clicked_enemy != null:
			# WP13: the HUD's Throw and spell aims work in exploration too; a
			# plain click (or the Melee aim) is the click-to-attack pursuit.
			if selected_player_turn_action == PlayerTurnAction.RANGED:
				_request_exploration_ranged_attack(clicked_enemy as CharacterBody3D)
			elif selected_player_turn_action == PlayerTurnAction.SPELL:
				_request_exploration_spell(clicked_enemy as CharacterBody3D)
			elif player.has_method("set_attack_target"):
				# attack_target system handles navigation internally via _refresh_attack_target_position
				player.call("set_attack_target", clicked_enemy)
				_set_player_turn_action(PlayerTurnAction.MOVE)
			get_viewport().set_input_as_handled()
			return
		var hittable := _pick_prop_in_group(screen_pos, &"hittable")
		if hittable != null:
			if selected_player_turn_action == PlayerTurnAction.RANGED:
				_request_exploration_ranged_attack(hittable)
			elif selected_player_turn_action == PlayerTurnAction.SPELL:
				_request_exploration_spell(hittable)
			elif player.has_method("set_attack_target"):
				player.call("set_attack_target", hittable)
				_set_player_turn_action(PlayerTurnAction.MOVE)
			get_viewport().set_input_as_handled()
			return
		var interactable := _pick_prop_in_group(screen_pos, &"interactable")
		if interactable != null:
			_request_interaction(interactable)
			get_viewport().set_input_as_handled()
			return
		var ground: Variant = _pick_ground(screen_pos)
		if ground == null:
			return
		if player.has_method("clear_attack_target"):
			player.call("clear_attack_target")
		_request_player_move(ground)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_accept"):
		_request_player_attack()
		get_viewport().set_input_as_handled()


func _register_placed_enemies() -> void:
	var found: Array[CharacterBody3D] = []
	for node in get_tree().get_nodes_in_group("enemies"):
		if not (node is CharacterBody3D):
			continue
		if not is_ancestor_of(node):
			continue
		found.append(node as CharacterBody3D)

	if found.is_empty():
		push_warning("No enemies found: add instances of res://scenes/3d/enemy_3d.tscn under the level root (group \"enemies\").")
		return

	found.sort_custom(func(a: CharacterBody3D, b: CharacterBody3D) -> bool:
		return str(a.get_path()) < str(b.get_path())
	)

	enemy = found[0]
	extra_enemies.clear()
	for i in range(1, found.size()):
		extra_enemies.append(found[i])
	for enemy_actor in found:
		_connect_enemy_signals(enemy_actor)


# WP13: an enemy that takes a hit outside turn mode reports it; the fight then
# starts as an ambush. Duck-typed like the rest of the actor contract.
func _connect_enemy_signals(enemy_actor: CharacterBody3D) -> void:
	if enemy_actor == null or not enemy_actor.has_signal("provoked_by_hit"):
		return
	var handler := Callable(self, "_on_enemy_provoked_by_hit").bind(enemy_actor)
	if not enemy_actor.is_connected("provoked_by_hit", handler):
		enemy_actor.connect("provoked_by_hit", handler)


func _wire_enemy_ai_targets() -> void:
	for enemy_actor in _get_all_alive_enemies():
		if enemy_actor.has_method("set_target"):
			enemy_actor.call("set_target", player)


# --- Level geometry (section 9) ----------------------------------------------
# The 2D tilemaps gave the coordinator its grid and bounds. In 3D the grid is
# GroundMath's 1 m cells and the bounds come from the Ground collision box.

func _compute_map_region() -> Rect2i:
	var ground := get_node_or_null("NavigationRegion3D/Ground") as Node3D
	if ground == null:
		push_warning("main_3d: no NavigationRegion3D/Ground node; using the fallback grid %s" % FALLBACK_MAP_REGION)
		return FALLBACK_MAP_REGION
	var shape_node: CollisionShape3D = null
	for child in ground.get_children():
		var candidate := child as CollisionShape3D
		if candidate != null and candidate.shape is BoxShape3D:
			shape_node = candidate
			break
	if shape_node == null:
		push_warning("main_3d: NavigationRegion3D/Ground has no BoxShape3D collider; using the fallback grid %s" % FALLBACK_MAP_REGION)
		return FALLBACK_MAP_REGION
	var box := shape_node.shape as BoxShape3D
	var half := box.size * 0.5
	var min_x := INF
	var max_x := -INF
	var min_z := INF
	var max_z := -INF
	for sx: float in [-1.0, 1.0]:
		for sz: float in [-1.0, 1.0]:
			var corner := shape_node.global_transform * Vector3(half.x * sx, 0.0, half.z * sz)
			min_x = minf(min_x, corner.x)
			max_x = maxf(max_x, corner.x)
			min_z = minf(min_z, corner.z)
			max_z = maxf(max_z, corner.z)
	var min_cell := GroundMath.to_cell(Vector3(min_x, 0.0, min_z))
	var max_cell := GroundMath.to_cell(Vector3(max_x - 0.001, 0.0, max_z - 0.001))
	return Rect2i(min_cell, max_cell - min_cell + Vector2i.ONE)


# Static blockers for the A* grid: every prop collider (layer 4) anywhere under
# the navigation region marks the cells its shape covers, as the object tilemap
# did in 2D. The imported props nest their StaticBody3D two levels down and
# carry a concave trimesh (docs/deviations/wp7.md, deviation 2), so this walks
# descendants and measures each shape's global AABB rather than expecting a
# direct child with a BoxShape3D.
func _cache_blocked_cells_from_props() -> void:
	blocked_cells.clear()
	if nav_region == null:
		return
	var bodies: Array[CollisionObject3D] = []
	_collect_collision_objects(nav_region, bodies)
	for body in bodies:
		if (body.collision_layer & LAYER_PROPS) == 0:
			continue
		for shape_child in body.get_children():
			var shape_node := shape_child as CollisionShape3D
			if shape_node == null or shape_node.shape == null or shape_node.disabled:
				continue
			var bounds := _shape_global_aabb(shape_node)
			if bounds.size == Vector3.ZERO:
				continue
			var min_cell := GroundMath.to_cell(Vector3(bounds.position.x, 0.0, bounds.position.z))
			var max_cell := GroundMath.to_cell(Vector3(bounds.end.x - 0.001, 0.0, bounds.end.z - 0.001))
			for x in range(min_cell.x, max_cell.x + 1):
				for y in range(min_cell.y, max_cell.y + 1):
					blocked_cells[Vector2i(x, y)] = true


func _collect_collision_objects(node: Node, out: Array[CollisionObject3D]) -> void:
	for child in node.get_children():
		if child is CollisionObject3D:
			out.append(child as CollisionObject3D)
		_collect_collision_objects(child, out)


# World-space bounds of a collision shape: the shape's local bounds (box size,
# trimesh faces, or the debug mesh for anything else) through the node's global
# transform.
func _shape_global_aabb(shape_node: CollisionShape3D) -> AABB:
	var shape := shape_node.shape
	var local := AABB()
	if shape is BoxShape3D:
		var size := (shape as BoxShape3D).size
		local = AABB(-size * 0.5, size)
	elif shape is ConcavePolygonShape3D:
		var faces := (shape as ConcavePolygonShape3D).get_faces()
		if faces.is_empty():
			return AABB()
		local = AABB(faces[0], Vector3.ZERO)
		for vertex in faces:
			local = local.expand(vertex)
	else:
		var debug_mesh := shape.get_debug_mesh()
		if debug_mesh == null:
			return AABB()
		local = debug_mesh.get_aabb()
	return shape_node.global_transform * local


func _setup_navmesh() -> void:
	if nav_region == null:
		push_warning("main_3d: no NavigationRegion3D; turn moves will find no paths")
		_wire_enemy_ai_targets()
		return
	var mesh := nav_region.navigation_mesh
	if mesh != null and mesh.get_polygon_count() > 0:
		# An editor-baked mesh (WP7) still reaches the server only on the first
		# map sync, one physics frame away.
		_finish_navmesh_setup(0)
		return
	if not bake_navmesh_if_empty:
		_wire_enemy_ai_targets()
		return
	if mesh == null:
		mesh = NavigationMesh.new()
		mesh.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
		mesh.geometry_collision_mask = LAYER_GROUND | LAYER_PROPS
		nav_region.navigation_mesh = mesh
	nav_region.bake_finished.connect(_on_navmesh_bake_finished, CONNECT_ONE_SHOT)
	nav_region.bake_navigation_mesh()


func _on_navmesh_bake_finished() -> void:
	# The region hands its mesh to the server on the next map sync; wait for
	# that iteration before anyone routes.
	_finish_navmesh_setup(NavigationServer3D.map_get_iteration_id(_level_navigation_map()))
	print("[main_3d] navmesh baked")


# Coroutine: waits until the navigation map has synced past `after_iteration`
# (the mesh is then queryable), marks the level ready and wires the enemies.
func _finish_navmesh_setup(after_iteration: int) -> void:
	await _wait_for_navigation_map(after_iteration)
	_navmesh_ready = true
	_wire_enemy_ai_targets()


# A map query made before the server's first sync is a NavigationServer error,
# and a freshly baked mesh is only visible from the next sync on. The map's
# iteration id counts those syncs.
func _wait_for_navigation_map(after_iteration: int) -> void:
	var map := _level_navigation_map()
	if not map.is_valid():
		return
	for _i in range(NAV_MAP_SYNC_MAX_FRAMES):
		if NavigationServer3D.map_get_iteration_id(map) > after_iteration:
			return
		await get_tree().physics_frame
	push_warning("main_3d: the navigation map did not sync within %d physics frames" % NAV_MAP_SYNC_MAX_FRAMES)


func _level_navigation_map() -> RID:
	var world := get_world_3d()
	if world == null:
		return RID()
	return world.navigation_map


## True once NavigationServer3D can answer path queries for this level.
func is_navmesh_ready() -> bool:
	return _navmesh_ready


func _spawn_test_loot() -> void:
	if not spawn_test_loot:
		return

	# Goes out through LootDropper like every other drop, so what you test is
	# exactly what a crate or a dead enemy produces. One of everything, so the
	# inventory screen has a full set of gear to try on. The 3D branch of
	# `drop_items` (WP6) spreads the ring on the ground plane in metres.
	var items: Array[Item] = [
		ItemFactory.create_sword(),
		ItemFactory.create_dagger(),
		ItemFactory.create_health_potion(),
	]
	for builder in ItemFactory.gear_builders():
		items.append(builder.call())
	LootDropper.drop_items(player, items, TEST_LOOT_SPREAD_M)


func _place_player() -> void:
	# A `Spawn_default` node (the LevelLoader convention) wins; otherwise the 2D
	# rule: the map centre cell plus PLAYER_SPAWN_OFFSET, clamped to the grid.
	var spawn_position: Vector3
	var spawn := find_child("Spawn_default", true, false) as Node3D
	if spawn != null:
		spawn_position = GroundMath.flatten(spawn.global_position)
	else:
		if _map_region.size == Vector2i.ZERO:
			return
		var center_cell := _map_region.position + (_map_region.size / 2)
		var spawn_cell := _clamp_cell_to_region(center_cell + PLAYER_SPAWN_OFFSET, _map_region)
		spawn_position = GroundMath.cell_center(spawn_cell)
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
		var screen_pos: Vector2 = event.position
		if _try_click_pickup(screen_pos):
			get_viewport().set_input_as_handled()
			return
		if selected_player_turn_action == PlayerTurnAction.ABILITY:
			_handle_ability_click(screen_pos)
			get_viewport().set_input_as_handled()
			return
		var clicked_enemy: Node3D = _pick_enemy(screen_pos)
		if clicked_enemy == null:
			clicked_enemy = _pick_prop_in_group(screen_pos, &"hittable")
		if clicked_enemy != null:
			if selected_player_turn_action == PlayerTurnAction.RANGED:
				_request_player_turn_ranged_attack(clicked_enemy)
			elif selected_player_turn_action == PlayerTurnAction.SPELL:
				_request_player_turn_spell(clicked_enemy)
			else:
				_request_player_turn_engage_enemy(clicked_enemy)
			get_viewport().set_input_as_handled()
			return
		if _pick_prop_in_group(screen_pos, &"interactable") != null:
			_fx_popup(_popup_anchor(player), "Not during a fight", CombatFx.COLOR_WARNING, 16)
			get_viewport().set_input_as_handled()
			return
		var ground: Variant = _pick_ground(screen_pos)
		if ground == null:
			return
		_request_player_turn_move(ground)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_accept"):
		_request_end_player_turn()
		get_viewport().set_input_as_handled()
	elif player.has_method("shift_kind_from_event"):
		# 1 / 2 / 3 / Q: hand the body to another soul. Same bindings as the
		# free shifting in exploration, gated by the turn rules above.
		var wanted_kind := int(player.call("shift_kind_from_event", event))
		if wanted_kind >= 0:
			_request_shift(wanted_kind)
			get_viewport().set_input_as_handled()


# --- Picking (section 6) -----------------------------------------------------
# WorldPicker rays through the rig's camera against the ground, actor and
# pickup layers, in the 2D order: pickup, enemy, ground.

func _pick_ground(screen_pos: Vector2) -> Variant:
	return WorldPicker.pick_ground(_get_active_camera(), screen_pos)


func _pick_enemy(screen_pos: Vector2) -> Node3D:
	return WorldPicker.pick_enemy(_get_active_camera(), screen_pos)


# Only an available pickup counts as clickable; WorldPicker returns the owning
# ItemPickup3D (or a bare area when nothing above it answers `is_available`).
func _pick_pickup(screen_pos: Vector2) -> Node3D:
	var pickup := WorldPicker.pick_pickup(_get_active_camera(), screen_pos)
	if pickup == null or not pickup.has_method("is_available"):
		return null
	if not bool(pickup.call("is_available")):
		return null
	return pickup


# A click on a pickup. Returns true when the click was spent on loot (menu
# opened, or an approach started), false when no pickup was under the cursor.
func _try_click_pickup(screen_pos: Vector2) -> bool:
	var pickup := _pick_pickup(screen_pos)
	if pickup == null:
		return false
	if LootMenu.request_loot(pickup, player):
		return true
	# Too far to loot. The 2D pickup left the click unhandled so click-to-move
	# walked the player over; here the coordinator does that walk itself, and
	# the loot menu keeps watching the distance and opens the pile on arrival.
	var approach := GroundMath.flatten(pickup.global_position)
	if combat_state == CombatState.EXPLORATION:
		if player.has_method("clear_attack_target"):
			player.call("clear_attack_target")
		_request_player_move(approach)
	else:
		_request_player_turn_move(approach)
	return true


# --- Combat state --------------------------------------------------------------

func _update_combat_state() -> void:
	var enemy_alive := not _get_all_alive_enemies().is_empty()
	var player_alive: bool = true
	if player.has_method("is_alive"):
		player_alive = bool(player.call("is_alive"))
	if not player_alive and not _respawn_scheduled and player.has_method("revive"):
		_schedule_respawn()
	if not enemy_alive or not player_alive:
		if combat_state != CombatState.EXPLORATION:
			_end_turn_based_combat()
		return

	if combat_state == CombatState.EXPLORATION:
		if _find_spotting_enemy() != null:
			_start_turn_based_combat()
		return

	if combat_state == CombatState.ENEMY_TURN and not enemy_turn_running:
		_run_enemy_turn()


# The enemy that has just spotted the player, or null. The rule is the enemy's
# own `can_spot` (its ring and its line of sight); a stub without it is read as
# a plain distance against its detection property. WP13 replaced the 2D
# Manhattan-cell trigger with this so the visible ring is the real rule.
func _find_spotting_enemy() -> CharacterBody3D:
	for enemy_actor in _get_all_alive_enemies():
		if _enemy_can_spot_player(enemy_actor):
			return enemy_actor
	return null


func _enemy_can_spot_player(enemy_actor: CharacterBody3D) -> bool:
	if enemy_actor == null or not is_instance_valid(enemy_actor):
		return false
	if enemy_actor.has_method("can_spot"):
		return bool(enemy_actor.call("can_spot", player))
	for property_name in DETECTION_RANGE_PROPERTIES:
		var value: Variant = enemy_actor.get(property_name)
		if value == null:
			continue
		var detection := float(value)
		if detection <= 0.0:
			return false
		return GroundMath.ground_distance(player.global_position, enemy_actor.global_position) <= detection
	return false


# WP13: a hit landed on `enemy_actor` while exploring. The hit has resolved
# already; the fight itself starts at the end of the frame, once a lethal hit
# has finished dying, so a struck enemy that died is not counted.
func _on_enemy_provoked_by_hit(enemy_actor: CharacterBody3D) -> void:
	if combat_state != CombatState.EXPLORATION:
		return
	call_deferred("_start_ambush_combat", enemy_actor)


# The first strike is the reward: the struck enemy and everyone within the
# joining radius engage, and the enemies take the first turn. When the only
# witness died of the hit and nobody else is near, nothing starts.
func _start_ambush_combat(struck_enemy: CharacterBody3D) -> void:
	if combat_state != CombatState.EXPLORATION:
		return
	if player == null or not is_instance_valid(player):
		return
	if player.has_method("is_alive") and not bool(player.call("is_alive")):
		return
	engaged_enemies.clear()
	if struck_enemy != null and is_instance_valid(struck_enemy):
		var struck_alive := not struck_enemy.has_method("is_alive") or bool(struck_enemy.call("is_alive"))
		if struck_alive:
			engaged_enemies[struck_enemy.get_instance_id()] = true
	if _player_is_stealthy():
		# Gameplay expansion: a strike from stealth only wakes the struck
		# enemy's close neighbours and whoever can see the body. A silent kill
		# with nobody watching starts nothing.
		_refresh_engaged_enemies_stealthy(struck_enemy)
	else:
		_refresh_engaged_enemies()
	var anyone_engaged := false
	for enemy_actor in _get_all_alive_enemies_unfiltered():
		if engaged_enemies.has(enemy_actor.get_instance_id()):
			anyone_engaged = true
			break
	if not anyone_engaged:
		engaged_enemies.clear()
		if _player_is_stealthy():
			CombatFx.announce("UNSEEN", Color(0.8, 0.55, 1.0, 1.0), 0.6)
		return
	_start_turn_based_combat(true)


# Starts turn combat. Spotted (`ambush` false): the fight is scoped here and
# the player acts first, as in 2D. Ambush (WP13): the caller has already scoped
# the fight and the enemies act first; the player's turn follows as usual.
func _start_turn_based_combat(ambush: bool = false) -> void:
	if not ambush:
		# Decide who is in this fight while we can still see every enemy.
		engaged_enemies.clear()
		_refresh_engaged_enemies()
	_stop_all_combatants_immediately()
	_set_player_turn_action(PlayerTurnAction.MOVE)
	_pending_interactable = null
	if ability_runner != null:
		ability_runner.on_combat_started()
	combat_state = CombatState.ENEMY_TURN if ambush else CombatState.PLAYER_TURN
	enemy_turn_running = false
	active_enemy_turn_actor = null

	if player.has_method("set_turn_based_combat"):
		player.call("set_turn_based_combat", true)
	# Spell radii are authored in meters; the player needs this map's scale.
	if player.has_method("set_turn_meter_world_units"):
		player.call("set_turn_meter_world_units", _get_turn_meter_world_units())
	# Every enemy on the map freezes into turn mode, engaged or not, so a pack
	# that hasn't noticed yet can't keep running at us in realtime. Only the
	# engaged ones are given turns.
	for enemy_actor in _get_all_alive_enemies_unfiltered():
		if enemy_actor.has_method("set_turn_based_combat"):
			enemy_actor.call("set_turn_based_combat", true)

	if not ambush and player.has_method("start_turn"):
		player.call("start_turn", TURN_MOVE_METERS)
	for enemy_actor in _get_all_alive_enemies():
		if enemy_actor.has_method("end_turn"):
			enemy_actor.call("end_turn")

	_crossfade_music(music_combat, music_exploration)
	if ambush:
		CombatFx.announce(ANNOUNCE_AMBUSH, CombatFx.COLOR_COMBAT, 0.7)
		print("Turn-based combat started (ambush, enemies act first)")
	else:
		CombatFx.announce(ANNOUNCE_COMBAT, CombatFx.COLOR_COMBAT, 0.7)
		print("Turn-based combat started")
	CombatFx.shake(4.0, 0.2)
	_update_turn_ui()


func _stop_all_combatants_immediately() -> void:
	if player != null and player.has_method("stop_movement_immediately"):
		player.call("stop_movement_immediately")
	elif player != null and player.has_method("set_navigation_target"):
		player.call("set_navigation_target", player.global_position)

	for enemy_actor in _get_all_alive_enemies_unfiltered():
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

	if player.has_method("set_turn_based_combat"):
		player.call("set_turn_based_combat", false)
	for enemy_actor in _get_all_alive_enemies_unfiltered():
		if enemy_actor.has_method("set_turn_based_combat"):
			enemy_actor.call("set_turn_based_combat", false)
	engaged_enemies.clear()

	_crossfade_music(music_exploration, music_combat)
	print("Turn-based combat ended")
	_update_turn_ui()


# --- Player turn actions -------------------------------------------------------

func _request_player_turn_move(target_world_position: Vector3) -> void:
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
func _request_player_turn_attack(target_enemy: Node3D = null) -> void:
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
	if GroundMath.ground_distance(player.global_position, target_enemy.global_position) > _get_player_melee_range() + ATTACK_RANGE_TOLERANCE_M:
		return

	await player.try_attack(target_enemy)
	_after_player_strike(target_enemy)
	_update_turn_ui()


# The melee reach the rules actually use: the equipped weapon's range, falling
# back to the bare `attack_range`. Both are metres in 3D.
func _get_player_melee_range() -> float:
	if player.has_method("get_melee_range"):
		return float(player.call("get_melee_range"))
	return float(player.get("attack_range"))


# Ranged reach is the active soul's (the rogue's throw). A soul without a
# ranged attack has zero reach; its button is hidden anyway.
func _get_ranged_attack_range_world() -> float:
	if player.has_method("get_ranged_range_meters"):
		return float(player.call("get_ranged_range_meters")) * _get_turn_meter_world_units()
	return 0.0


func _get_active_soul() -> Soul:
	if player != null and player.has_method("get_active_soul"):
		return player.call("get_active_soul") as Soul
	return null


func _get_selected_spell() -> Soul.Spell:
	var soul := _get_active_soul()
	if soul == null or selected_spell_id == &"":
		return null
	return soul.get_spell(selected_spell_id)


func _get_spell_range_world(spell: Soul.Spell) -> float:
	if spell == null:
		return 0.0
	return spell.range_meters * _get_turn_meter_world_units()


func _request_player_turn_ranged_attack(target_enemy: Node3D = null) -> void:
	if combat_state != CombatState.PLAYER_TURN:
		return
	if player_turn_action_running:
		return
	if not player.has_method("try_ranged_attack"):
		return
	if not player.call("can_turn_attack"):
		_fx_popup(_popup_anchor(player), "No attack left", CombatFx.COLOR_WARNING, 16)
		return
	if target_enemy == null:
		target_enemy = _get_closest_enemy_to_player()
	if target_enemy == null:
		return
	var max_dist := _get_ranged_attack_range_world()
	if GroundMath.ground_distance(player.global_position, target_enemy.global_position) > max_dist:
		_fx_popup(_popup_anchor(target_enemy), "Out of range", CombatFx.COLOR_WARNING, 16)
		return

	player_turn_action_running = true
	await player.try_ranged_attack(target_enemy)
	player_turn_action_running = false
	_after_player_strike(target_enemy)
	_set_player_turn_action(PlayerTurnAction.MOVE)
	_update_turn_ui()


# The mage's spells. Same shape as the ranged attack: refuse with a popup when
# the spell is recharging or the target is out of range, otherwise hold the
# turn while the bolt flies and the spell resolves.
func _request_player_turn_spell(target_enemy: Node3D = null) -> void:
	if combat_state != CombatState.PLAYER_TURN:
		return
	if player_turn_action_running:
		return
	if not player.has_method("try_cast_spell"):
		return
	var spell := _get_selected_spell()
	if spell == null:
		return
	if not player.call("can_turn_attack"):
		_fx_popup(_popup_anchor(player), "No attack left", CombatFx.COLOR_WARNING, 16)
		return
	var cooldown := 0
	if player.has_method("get_spell_cooldown"):
		cooldown = int(player.call("get_spell_cooldown", spell.id))
	if cooldown > 0:
		_fx_popup(_popup_anchor(player), "Recharging (%d)" % cooldown, CombatFx.COLOR_WARNING, 16)
		return
	if target_enemy == null:
		target_enemy = _get_closest_enemy_to_player()
	if target_enemy == null:
		return
	if GroundMath.ground_distance(player.global_position, target_enemy.global_position) > _get_spell_range_world(spell):
		_fx_popup(_popup_anchor(target_enemy), "Out of range", CombatFx.COLOR_WARNING, 16)
		return

	player_turn_action_running = true
	await player.try_cast_spell(spell.id, target_enemy)
	player_turn_action_running = false
	_after_player_strike(target_enemy)
	_set_player_turn_action(PlayerTurnAction.MOVE)
	_update_turn_ui()


# --- Exploration attacks (WP13) --------------------------------------------------
# The throw and the spells outside combat, with the turn mode's rings, targeting
# and refusals. The player stands still to throw or cast. A hit that lands
# starts the fight as an ambush through `provoked_by_hit`; a refused or missed
# attack starts nothing. Melee in exploration is the click-to-attack pursuit and
# the Space sweep, which the player already owns.

func _request_exploration_ranged_attack(target_enemy: Node3D = null) -> void:
	if combat_state != CombatState.EXPLORATION:
		return
	if player_turn_action_running:
		return
	if not player.has_method("try_ranged_attack"):
		return
	if target_enemy == null:
		target_enemy = _get_closest_enemy_to_player()
	if target_enemy == null:
		return
	var max_dist := _get_ranged_attack_range_world()
	if GroundMath.ground_distance(player.global_position, target_enemy.global_position) > max_dist:
		_fx_popup(_popup_anchor(target_enemy), "Out of range", CombatFx.COLOR_WARNING, 16)
		return

	_stop_player_for_exploration_attack()
	player_turn_action_running = true
	await player.try_ranged_attack(target_enemy)
	player_turn_action_running = false
	if combat_state == CombatState.EXPLORATION:
		_set_player_turn_action(PlayerTurnAction.MOVE)
	_update_turn_ui()


func _request_exploration_spell(target_enemy: Node3D = null) -> void:
	if combat_state != CombatState.EXPLORATION:
		return
	if player_turn_action_running:
		return
	if not player.has_method("try_cast_spell"):
		return
	var spell := _get_selected_spell()
	if spell == null:
		return
	var cooldown := 0
	if player.has_method("get_spell_cooldown"):
		cooldown = int(player.call("get_spell_cooldown", spell.id))
	if cooldown > 0:
		_fx_popup(_popup_anchor(player), "Recharging (%d)" % cooldown, CombatFx.COLOR_WARNING, 16)
		return
	if target_enemy == null:
		target_enemy = _get_closest_enemy_to_player()
	if target_enemy == null:
		return
	if GroundMath.ground_distance(player.global_position, target_enemy.global_position) > _get_spell_range_world(spell):
		_fx_popup(_popup_anchor(target_enemy), "Out of range", CombatFx.COLOR_WARNING, 16)
		return

	_stop_player_for_exploration_attack()
	player_turn_action_running = true
	await player.try_cast_spell(spell.id, target_enemy)
	player_turn_action_running = false
	if combat_state == CombatState.EXPLORATION:
		_set_player_turn_action(PlayerTurnAction.MOVE)
	_update_turn_ui()


# A throw or a cast is made standing: drop the walk and any melee pursuit.
func _stop_player_for_exploration_attack() -> void:
	if player.has_method("clear_attack_target"):
		player.call("clear_attack_target")
	if player.has_method("stop_movement_immediately"):
		player.call("stop_movement_immediately")


# Whether the HUD's attack aims (Melee, Throw, spells) may be picked right now:
# on the player's turn, or in exploration (WP13).
func _player_can_pick_attack_aim() -> bool:
	if player_turn_action_running:
		return false
	return combat_state == CombatState.PLAYER_TURN or combat_state == CombatState.EXPLORATION


func _request_player_turn_engage_enemy(target_enemy: Node3D = null) -> void:
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
		_fx_popup(_popup_anchor(player), "No attack left", CombatFx.COLOR_WARNING, 16)

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
		_fx_popup(_popup_anchor(target_enemy), "Out of reach", CombatFx.COLOR_WARNING, 16)
	if remaining_meters > 0.0:
		var player_approach_distance := approach_distance_for(player, target_enemy, _get_player_melee_range())
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
		_fx_popup(_popup_anchor(target_enemy), "Out of reach", CombatFx.COLOR_WARNING, 16)

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
	if _player_escaped():
		_escape_combat()
		return
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
	# Anyone who has closed in since last turn joins the fight now.
	_refresh_engaged_enemies()
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

		# Smoke Bomb: the body is lost in the smoke; the enemy looks around and
		# spends its turn doing nothing useful.
		if player.has_method("is_hidden_by_smoke") and bool(player.call("is_hidden_by_smoke")):
			_fx_popup(_popup_anchor(enemy_actor), "?", CombatFx.COLOR_WARNING, 22)
			if enemy_actor.has_method("end_turn"):
				enemy_actor.call("end_turn")
			continue

		# The budget comes from the enemy itself, so one rooted by Frost Snare
		# (zero movement this turn) stays where it is and just swings if it can.
		var move_budget := TURN_MOVE_METERS
		if enemy_actor.has_method("get_turn_remaining_move_meters"):
			move_budget = float(enemy_actor.call("get_turn_remaining_move_meters"))
		var used_meters := _request_enemy_turn_move_by_distance(enemy_actor, move_budget)
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
	if ability_runner != null:
		ability_runner.on_player_turn_started()
	_set_player_turn_action(PlayerTurnAction.MOVE)
	active_enemy_turn_actor = null
	combat_state = CombatState.PLAYER_TURN
	enemy_turn_running = false
	CombatFx.announce("YOUR TURN", CombatFx.COLOR_PLAYER_TURN, 0.6)
	_update_turn_ui()


func _player_can_attack_enemy_now(target_enemy: Node3D = null) -> bool:
	if not player.has_method("can_turn_attack"):
		return false
	if not player.call("can_turn_attack"):
		return false
	if target_enemy == null or not is_instance_valid(target_enemy):
		target_enemy = _get_closest_enemy_to_player()
	if target_enemy == null:
		return false
	return GroundMath.ground_distance(player.global_position, target_enemy.global_position) <= _get_player_melee_range() + ATTACK_RANGE_TOLERANCE_M


# --- Navigation grid (AStarGrid2D on GroundMath cells) -----------------------
# Dimension-neutral data structure, kept from 2D: cells are GroundMath.to_cell
# values and cell centres come from GroundMath.cell_center.

func _rebuild_navigation_grid() -> void:
	if _map_region.size == Vector2i.ZERO:
		return

	astar_grid = AStarGrid2D.new()
	astar_grid.region = _map_region
	astar_grid.cell_size = Vector2(GroundMath.CELL_SIZE, GroundMath.CELL_SIZE)
	astar_grid.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_NEVER
	astar_grid.default_compute_heuristic = AStarGrid2D.HEURISTIC_MANHATTAN
	astar_grid.default_estimate_heuristic = AStarGrid2D.HEURISTIC_MANHATTAN
	astar_grid.update()

	for x in range(_map_region.position.x, _map_region.position.x + _map_region.size.x):
		for y in range(_map_region.position.y, _map_region.position.y + _map_region.size.y):
			var cell := Vector2i(x, y)
			astar_grid.set_point_solid(cell, blocked_cells.has(cell) or enemy_blocked_cells.has(cell))


func _request_player_move(target_world_position: Vector3) -> void:
	# Use navmesh routing directly; the actor snaps the target to the navmesh
	# and its NavigationAgent3D routes around what is in the way.
	if player == null or not is_instance_valid(player):
		return
	if player.has_method("set_navigation_target"):
		player.call("set_navigation_target", target_world_position)


func _collect_enemy_personal_space_cells() -> Array[Vector2i]:
	var blocked: Array[Vector2i] = []
	var used_rect := astar_grid.region
	if used_rect.size == Vector2i.ZERO:
		return blocked

	var player_radius := _get_character_collision_radius(player)
	for enemy_actor in _get_all_alive_enemies():
		var enemy_cell := GroundMath.to_cell(enemy_actor.global_position)
		var enemy_radius := _get_character_collision_radius(enemy_actor)
		var clearance_world := player_radius + enemy_radius + ENEMY_PERSONAL_SPACE_PADDING_M
		if combat_state != CombatState.EXPLORATION:
			clearance_world += TURN_MODE_ENEMY_BLOCKER_EXTRA_RADIUS

		var sample_cell_radius := int(ceili(clearance_world / GroundMath.CELL_SIZE)) + 2
		for dx in range(-sample_cell_radius, sample_cell_radius + 1):
			for dy in range(-sample_cell_radius, sample_cell_radius + 1):
				var cell := enemy_cell + Vector2i(dx, dy)
				if not used_rect.has_point(cell):
					continue

				var cell_world := GroundMath.cell_center(cell)
				if GroundMath.ground_distance(cell_world, enemy_actor.global_position) <= clearance_world and blocked.find(cell) == -1:
					blocked.append(cell)

		# Ensure the enemy's own cell is always blocked.
		if blocked.find(enemy_cell) == -1:
			blocked.append(enemy_cell)

	return blocked


func _refresh_enemy_blocked_cells(excluded_enemy: CharacterBody3D = null) -> void:
	enemy_blocked_cells.clear()
	if astar_grid.region.size == Vector2i.ZERO:
		return

	var used_rect := astar_grid.region
	var player_radius := _get_character_collision_radius(player)

	for enemy_actor in _get_all_alive_enemies():
		if excluded_enemy != null and enemy_actor == excluded_enemy:
			continue

		var enemy_cell := GroundMath.to_cell(enemy_actor.global_position)
		var enemy_radius := _get_character_collision_radius(enemy_actor)
		var clearance_world := player_radius + enemy_radius + ENEMY_PERSONAL_SPACE_PADDING_M
		if combat_state != CombatState.EXPLORATION:
			clearance_world += TURN_MODE_ENEMY_BLOCKER_EXTRA_RADIUS

		var sample_cell_radius := int(ceili(clearance_world / GroundMath.CELL_SIZE)) + 2
		for dx in range(-sample_cell_radius, sample_cell_radius + 1):
			for dy in range(-sample_cell_radius, sample_cell_radius + 1):
				var cell := enemy_cell + Vector2i(dx, dy)
				if not used_rect.has_point(cell):
					continue
				var cell_world := GroundMath.cell_center(cell)
				if GroundMath.ground_distance(cell_world, enemy_actor.global_position) <= clearance_world:
					enemy_blocked_cells[cell] = true

		enemy_blocked_cells[enemy_cell] = true


# Footprint radius in metres from the actor's CollisionShape3D (contract 5.1).
func _get_character_collision_radius(character: Node) -> float:
	if character == null:
		return DEFAULT_CHARACTER_RADIUS_M
	var shape_node := character.get_node_or_null("CollisionShape3D") as CollisionShape3D
	if shape_node == null or shape_node.shape == null:
		return DEFAULT_CHARACTER_RADIUS_M
	var shape := shape_node.shape
	if shape is CapsuleShape3D:
		return (shape as CapsuleShape3D).radius
	if shape is SphereShape3D:
		return (shape as SphereShape3D).radius
	if shape is CylinderShape3D:
		return (shape as CylinderShape3D).radius
	if shape is BoxShape3D:
		var size := (shape as BoxShape3D).size
		return maxf(size.x, size.z) * 0.5
	return DEFAULT_CHARACTER_RADIUS_M


func _find_farthest_valid_player_path_index(cell_path: Array[Vector2i]) -> int:
	if cell_path.size() <= 1:
		return 0
	for i in range(cell_path.size() - 1, 0, -1):
		var world_pos := GroundMath.cell_center(cell_path[i])
		if not _is_player_position_blocked(world_pos):
			return i
	return 0


func _is_player_position_blocked(world_position: Vector3) -> bool:
	if player == null or not is_instance_valid(player):
		return true

	var shape_node := player.get_node_or_null("CollisionShape3D") as CollisionShape3D
	if shape_node == null or shape_node.shape == null:
		return false

	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = shape_node.shape
	params.transform = Transform3D(Basis.IDENTITY, world_position + shape_node.position)
	params.collide_with_areas = false
	params.collide_with_bodies = true
	var excluded: Array[RID] = [player.get_rid()]
	params.exclude = excluded
	# Props block, other actors block; the ground is what we stand on.
	params.collision_mask = LAYER_PROPS | LAYER_ACTORS

	var space := get_world_3d().direct_space_state
	if space == null:
		return false
	var hits := space.intersect_shape(params, 1)
	if not hits.is_empty():
		return true

	# In turn mode, treat enemy personal space as hard collision too.
	if combat_state != CombatState.EXPLORATION:
		var player_radius := _get_character_collision_radius(player)
		for enemy_actor in _get_all_alive_enemies():
			var enemy_radius := _get_character_collision_radius(enemy_actor)
			var min_distance := player_radius + enemy_radius + TURN_MODE_ENEMY_BLOCKER_EXTRA_RADIUS
			if GroundMath.ground_distance(world_position, enemy_actor.global_position) < min_distance:
				return true

	return false


func _request_enemy_turn_move_by_distance(enemy_actor: CharacterBody3D, max_meters: float) -> float:
	if enemy_actor == null or not is_instance_valid(enemy_actor):
		return 0.0
	if max_meters <= 0.0:
		return 0.0

	_refresh_enemy_blocked_cells(enemy_actor)
	_rebuild_navigation_grid()

	var enemy_attack_range := float(enemy_actor.get("attack_range"))
	var stop_distance := approach_distance_for(enemy_actor, player, enemy_attack_range)
	var approach_point := _compute_approach_world_point(enemy_actor.global_position, player.global_position, stop_distance)
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


# The enemies that matter right now. Out of combat that is every living enemy
# on the map; in a fight it is only the ones engaged in it (see
# ENGAGE_RADIUS_METERS), so far-off packs neither take turns nor count toward
# victory. Code that must reach everyone regardless (freezing and releasing
# turn mode) uses the unfiltered version.
func _get_all_alive_enemies() -> Array[CharacterBody3D]:
	var alive := _get_all_alive_enemies_unfiltered()
	if combat_state == CombatState.EXPLORATION:
		return alive

	var engaged: Array[CharacterBody3D] = []
	for enemy_actor in alive:
		if engaged_enemies.has(enemy_actor.get_instance_id()):
			engaged.append(enemy_actor)
	return engaged


func _refresh_engaged_enemies() -> void:
	var radius := ENGAGE_RADIUS_METERS * _get_turn_meter_world_units()
	for enemy_actor in _get_all_alive_enemies_unfiltered():
		if engaged_enemies.has(enemy_actor.get_instance_id()):
			continue
		if GroundMath.ground_distance(player.global_position, enemy_actor.global_position) <= radius:
			engaged_enemies[enemy_actor.get_instance_id()] = true


func _get_all_alive_enemies_unfiltered() -> Array[CharacterBody3D]:
	var seen: Dictionary = {}
	var result: Array[CharacterBody3D] = []

	for node in get_tree().get_nodes_in_group("enemies"):
		_collect_alive_enemy_under_main(node, seen, result)

	if enemy != null and is_instance_valid(enemy):
		_collect_alive_enemy_under_main(enemy, seen, result)
	for enemy_actor in extra_enemies:
		if enemy_actor != null and is_instance_valid(enemy_actor):
			_collect_alive_enemy_under_main(enemy_actor, seen, result)

	result.sort_custom(func(a: CharacterBody3D, b: CharacterBody3D) -> bool:
		return str(a.get_path()) < str(b.get_path())
	)
	return result


func _collect_alive_enemy_under_main(node: Node, seen: Dictionary, out: Array[CharacterBody3D]) -> void:
	if not (node is CharacterBody3D):
		return
	var actor := node as CharacterBody3D
	if not is_ancestor_of(actor):
		return
	if seen.has(actor):
		return
	if actor.has_method("is_alive") and not bool(actor.call("is_alive")):
		return
	seen[actor] = true
	out.append(actor)


func _get_closest_enemy_to_player() -> CharacterBody3D:
	var alive_enemies := _get_all_alive_enemies()
	if alive_enemies.is_empty():
		return null

	var closest := alive_enemies[0]
	var closest_dist := GroundMath.ground_distance(player.global_position, closest.global_position)
	for i in range(1, alive_enemies.size()):
		var candidate := alive_enemies[i]
		var d := GroundMath.ground_distance(player.global_position, candidate.global_position)
		if d < closest_dist:
			closest_dist = d
			closest = candidate
	return closest


# How far from `target`'s origin `mover` stops before attacking with `reach`
# (WP10). Real actors own the rule (ActorBase3D.get_attack_approach_distance:
# inside the reach, never closer than the two collision surfaces plus a gap), so
# turn combat stops at the same spacing as the realtime chase. A stub without
# it gets its own preference, else the 2D-style buffer.
static func approach_distance_for(mover: Node, target: Node, reach: float) -> float:
	if mover != null and mover.has_method("get_attack_approach_distance"):
		return float(mover.call("get_attack_approach_distance", target, reach))
	if mover != null and mover.has_method("get_preferred_attack_approach_distance"):
		return float(mover.call("get_preferred_attack_approach_distance"))
	return maxf(ENEMY_APPROACH_MIN_M, reach - ENEMY_APPROACH_BUFFER_M)


# Point on the ground plane `stop_distance` short of `target_world`, on the
# line from the target toward the mover. The mover's own position when it is
# already that close.
func _compute_approach_world_point(mover_world: Vector3, target_world: Vector3, stop_distance: float) -> Vector3:
	var distance := GroundMath.ground_distance(mover_world, target_world)
	if distance <= stop_distance:
		return mover_world
	if distance <= 0.001:
		return target_world
	var away := GroundMath.ground_direction(target_world, mover_world)
	return GroundMath.flatten(target_world) + away * stop_distance


func _request_player_turn_move_by_distance(target_world_position: Vector3, max_meters: float) -> float:
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


# The navigation map an actor walks on: its NavigationAgent3D's map when it has
# one, else the level's world map.
func _get_navigation_map_for(actor: Node) -> RID:
	if actor != null and is_instance_valid(actor):
		var nav_agent := actor.get_node_or_null("NavigationAgent3D") as NavigationAgent3D
		if nav_agent != null:
			var agent_map := nav_agent.get_navigation_map()
			if agent_map.is_valid():
				return agent_map
	return get_world_3d().navigation_map


func _build_cell_path_from_navigation(from_world: Vector3, to_world: Vector3) -> Array[Vector2i]:
	var nav_map_rid := _get_navigation_map_for(player)
	if not nav_map_rid.is_valid():
		return []

	var from_point := NavigationServer3D.map_get_closest_point(nav_map_rid, from_world)
	var to_point := NavigationServer3D.map_get_closest_point(nav_map_rid, to_world)
	var nav_path := NavigationServer3D.map_get_path(nav_map_rid, from_point, to_point, false)
	if nav_path.is_empty():
		return []

	var cell_path: Array[Vector2i] = []
	var from_cell := GroundMath.to_cell(from_world)
	cell_path.append(from_cell)
	for nav_point in nav_path:
		var path_cell := GroundMath.to_cell(nav_point)
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


func _build_world_path_from_navigation(from_world: Vector3, to_world: Vector3, path_actor: CharacterBody3D = null) -> Array[Vector3]:
	var actor: Node = path_actor if path_actor != null else player
	var nav_map_rid := _get_navigation_map_for(actor)
	if not nav_map_rid.is_valid():
		return []

	var from_point := NavigationServer3D.map_get_closest_point(nav_map_rid, from_world)
	var to_point := NavigationServer3D.map_get_closest_point(nav_map_rid, to_world)
	var nav_path := NavigationServer3D.map_get_path(nav_map_rid, from_point, to_point, true)
	if nav_path.is_empty():
		return []

	var world_path: Array[Vector3] = []
	world_path.append(from_point)
	for p in nav_path:
		if GroundMath.ground_distance(world_path[world_path.size() - 1], p) > 0.01:
			world_path.append(p)
	return world_path


func _path_length(path: Array[Vector3]) -> float:
	return GroundMath.path_length(path)


func _point_on_path_at_distance(path: Array[Vector3], distance_on_path: float) -> Vector3:
	if path.is_empty():
		return Vector3.ZERO
	var trimmed := GroundMath.trim_path(path, maxf(0.0, distance_on_path))
	return trimmed[trimmed.size() - 1]


# One turn meter in world units. The 2D game measured a tile step; here 1 unit
# is 1 m by convention (contract, section 2).
func _get_turn_meter_world_units() -> float:
	return GroundMath.METER_WORLD_UNITS


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


# Instances `enemy_scene` on the nearest walkable cell to `target_cell`, wires
# it like a placed enemy and returns it (null when nothing could be placed).
func _spawn_additional_enemy(target_cell: Vector2i, search_radius: int = 6) -> CharacterBody3D:
	if enemy_scene == null:
		push_warning("main_3d: enemy_scene is not set; cannot spawn an enemy")
		return null
	_refresh_enemy_blocked_cells()
	_rebuild_navigation_grid()
	var spawn_cell := _find_nearest_walkable_cell(target_cell, search_radius)
	if spawn_cell == Vector2i(-1, -1):
		return null

	var instance := enemy_scene.instantiate()
	var actor := instance as CharacterBody3D
	if actor == null:
		push_warning("main_3d: enemy_scene root is not a CharacterBody3D")
		instance.free()
		return null
	add_child(actor)
	if not actor.is_in_group("enemies"):
		actor.add_to_group("enemies")
	var spawn_position := GroundMath.cell_center(spawn_cell)
	if actor.has_method("snap_to"):
		actor.call("snap_to", spawn_position)
	else:
		actor.global_position = spawn_position

	if enemy == null or not is_instance_valid(enemy):
		enemy = actor
	else:
		extra_enemies.append(actor)
	_connect_enemy_signals(actor)
	if actor.has_method("set_target"):
		actor.call("set_target", player)
	if combat_state != CombatState.EXPLORATION and actor.has_method("set_turn_based_combat"):
		actor.call("set_turn_based_combat", true)
	return actor


# --- Camera (section 6) --------------------------------------------------------
# A 3D level runs through its CameraRig and nothing else: `_ready` reports a
# missing rig, and every pick and projection then answers null / zero.

func _get_active_camera() -> Camera3D:
	if camera_rig == null:
		return null
	return camera_rig.get_camera()


func _setup_camera() -> void:
	if camera_rig == null:
		push_error("main_3d: %s has no CameraRig (scenes/3d/camera_rig_3d.tscn, contract section 9); clicks, popups and the follow camera are disabled" % name)
		return
	camera_rig.set_follow_target(player)
	camera_rig.set_zoom_size(CAMERA_SIZE_M)
	# Drop onto the player this frame instead of lerping in from the origin,
	# the 3D twin of the 2D `_center_camera`.
	camera_rig.snap_to_target()


# Enemy-turn framing: the rig looks between the player and the acting enemy,
# biased toward the enemy, and returns to the follow target afterwards.
func _update_camera_rig() -> void:
	if camera_rig == null:
		return
	var focus_enemy: CharacterBody3D = null
	if combat_state == CombatState.ENEMY_TURN \
			and active_enemy_turn_actor != null and is_instance_valid(active_enemy_turn_actor):
		focus_enemy = active_enemy_turn_actor
	if focus_enemy != null:
		camera_rig.focus_between(player, focus_enemy, CAMERA_ENEMY_FOCUS_BLEND)
		_camera_rig_focused = true
	elif _camera_rig_focused:
		camera_rig.clear_focus()
		_camera_rig_focused = false


# --- CombatFx adapters (section 7) --------------------------------------------
# Installed once the camera exists and cleared in `_exit_tree`, because the
# autoload outlives the level.

func _setup_combat_fx_adapters() -> void:
	CombatFx.set_world_projector(_project_world_to_screen)
	CombatFx.set_shake_target(_apply_camera_shake_offset)


# Every CombatFx world position (damage numbers, XP, ROOTED, bursts) is a
# Vector3 in 3D and lands on screen through the rig's camera.
func _project_world_to_screen(world: Variant) -> Vector2:
	if world is Vector2:
		return world
	if not (world is Vector3):
		return Vector2.ZERO
	return WorldPicker.world_to_screen(_get_active_camera(), world)


# CombatFx shakes in 2D pixels (it wrote Camera2D.offset); the rig's
# `shake_offset` is a screen-plane offset in metres, so the pixel jitter is
# scaled by the orthographic size over the viewport height. Screen y points
# down while the camera's v_offset points up.
func _apply_camera_shake_offset(offset: Vector2) -> void:
	if camera_rig == null:
		return
	var camera := _get_active_camera()
	if camera == null:
		return
	var viewport_height := maxf(1.0, get_viewport().get_visible_rect().size.y)
	var offset_m := offset * (camera.size / viewport_height)
	camera_rig.set_shake_offset(Vector2(offset_m.x, -offset_m.y))


# Popup at a world position; CombatFx projects it through the adapter above
# every frame, so it follows the camera like a 2D popup.
func _fx_popup(world: Vector3, text: String, color: Color, font_size: int = 16) -> void:
	CombatFx.popup_text(world, text, color, font_size)


# Where an actor's popups appear: its OverheadAnchor, else above its feet.
func _popup_anchor(actor: Node3D) -> Vector3:
	if actor == null or not is_instance_valid(actor):
		return Vector3.ZERO
	var anchor := actor.get_node_or_null("OverheadAnchor") as Node3D
	if anchor != null:
		return anchor.global_position
	return actor.global_position + Vector3.UP * POPUP_HEIGHT_M


# --- Overlays (section 7, WP5) ---------------------------------------------------

## Counter-prompt hookup for an enemy that does not build its own: a
## CounterPrompt3D parented under the enemy's OverheadAnchor (or the enemy
## itself), which the enemy then drives through the four phases. Enemy3D makes
## its own prompt in `_ready`; this stays for other enemy scripts.
func acquire_counter_prompt(prompt_owner: Node3D) -> Node3D:
	if prompt_owner == null or not is_instance_valid(prompt_owner):
		return null
	var prompt := CounterPrompt3D.new()
	prompt.name = "CounterPrompt3D"
	var anchor := prompt_owner.get_node_or_null("OverheadAnchor") as Node3D
	if anchor != null:
		anchor.add_child(prompt)
	else:
		prompt_owner.add_child(prompt)
	return prompt


func _setup_path_preview() -> void:
	# One per level, under the root: `show_path` takes global points.
	path_preview = PathPreview3D.new()
	path_preview.name = "PathPreview"
	add_child(path_preview)


func _setup_range_rings() -> void:
	# Two rings under the player in turn mode: the melee reach (always, faint)
	# and the ranged reach (dashed, only while aiming a ranged shot). They are
	# the same circles the attack checks use, so "inside the ring" means "will
	# hit". Parented to the body, they follow it at the local origin.
	melee_range_ring = RangeRing3D.new()
	melee_range_ring.name = "MeleeRangeRing"
	player.add_child(melee_range_ring)

	ranged_range_ring = RangeRing3D.new()
	ranged_range_ring.name = "RangedRangeRing"
	player.add_child(ranged_range_ring)

	# Blast preview for area spells, moved onto the enemy under the cursor.
	spell_area_ring = RangeRing3D.new()
	spell_area_ring.name = "SpellAreaRing"
	add_child(spell_area_ring)


func _update_range_rings() -> void:
	if melee_range_ring == null or ranged_range_ring == null or spell_area_ring == null:
		return
	var show := combat_state == CombatState.PLAYER_TURN and not InventoryScreen.is_open()
	if show and player.has_method("can_turn_attack") and selected_player_turn_action != PlayerTurnAction.ABILITY:
		show = bool(player.call("can_turn_attack"))
	# WP13: in exploration the rings show only while an aim is picked, so the
	# enemies' detection rings stay readable the rest of the time.
	if combat_state == CombatState.EXPLORATION and not InventoryScreen.is_open():
		show = selected_player_turn_action != PlayerTurnAction.MOVE
	if not show:
		melee_range_ring.hide_ring()
		ranged_range_ring.hide_ring()
		spell_area_ring.hide_ring()
		return

	spell_area_ring.hide_ring()
	if selected_player_turn_action == PlayerTurnAction.ABILITY:
		melee_range_ring.hide_ring()
		var ability := _get_selected_ability()
		if ability == null or ability_runner == null:
			ranged_range_ring.hide_ring()
			return
		var ring_color := Color(ability.color.r, ability.color.g, ability.color.b, 0.6)
		ranged_range_ring.show_ring(ability_runner.get_range(ability), ring_color, not ability.is_melee())
		if ability.is_area():
			var area_center: Variant = null
			if ability.target == Ability3D.Target.ENEMY and hovered_enemy != null and is_instance_valid(hovered_enemy):
				area_center = hovered_enemy.global_position
			elif ability.target == Ability3D.Target.GROUND:
				area_center = _pick_ground(get_viewport().get_mouse_position())
			if area_center is Vector3:
				spell_area_ring.global_position = GroundMath.flatten(area_center)
				spell_area_ring.show_ring(ability.radius_m, Color(ability.color.r, ability.color.g, ability.color.b, 0.45))
	elif selected_player_turn_action == PlayerTurnAction.RANGED:
		melee_range_ring.hide_ring()
		ranged_range_ring.show_ring(_get_ranged_attack_range_world(), Color(0.55, 0.85, 1.0, 0.55), true)
	elif selected_player_turn_action == PlayerTurnAction.SPELL:
		melee_range_ring.hide_ring()
		var spell := _get_selected_spell()
		if spell == null:
			ranged_range_ring.hide_ring()
		else:
			ranged_range_ring.show_ring(_get_spell_range_world(spell), Color(spell.color.r, spell.color.g, spell.color.b, 0.6), true)
			if spell.is_area() and hovered_enemy != null and is_instance_valid(hovered_enemy):
				spell_area_ring.global_position = GroundMath.flatten(hovered_enemy.global_position)
				spell_area_ring.show_ring(spell.radius_meters * _get_turn_meter_world_units(),
					Color(spell.color.r, spell.color.g, spell.color.b, 0.45))
	else:
		ranged_range_ring.hide_ring()
		var melee_color := Color(1.0, 0.9, 0.7, 0.28)
		if selected_player_turn_action == PlayerTurnAction.ATTACK:
			melee_color = Color(1.0, 0.85, 0.5, 0.6)
		melee_range_ring.show_ring(_get_player_melee_range(), melee_color)


# --- Music ---------------------------------------------------------------------

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


# --- Path preview --------------------------------------------------------------

func _hide_path_preview() -> void:
	if path_preview != null:
		path_preview.hide_path()


func _update_path_preview() -> void:
	if path_preview == null:
		return
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

	var mouse_world: Variant = _pick_ground(get_viewport().get_mouse_position())
	if mouse_world == null:
		_hide_path_preview()
		return
	var world_path := _build_world_path_from_navigation(player.global_position, mouse_world, player)
	if world_path.size() <= 1:
		_hide_path_preview()
		return

	var meter_units := _get_turn_meter_world_units()
	var max_world_distance := remaining_meters * meter_units
	var total_length := _path_length(world_path)
	var used_distance := minf(max_world_distance, total_length)
	var used_meters := used_distance / meter_units

	var trimmed := GroundMath.trim_path(world_path, used_distance)
	path_preview.show_path(trimmed, used_meters, remaining_meters)


# --- Turn UI -------------------------------------------------------------------

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
	turn_ui_order_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH

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
	# Seven rows of text plus the rule; the PanelContainer grows downward from
	# this edge, so it has to start high enough to keep the last row on screen.
	turn_ui_panel.offset_top = -216.0
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

	turn_ui_soul_label = Label.new()
	turn_ui_soul_label.text = "Soul: -"
	turn_ui_soul_label.add_theme_color_override("font_color", Color(0.86, 0.86, 0.84, 1.0))
	vbox.add_child(turn_ui_soul_label)

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

	# Soul-specific actions share the row: the rogue's throw, the knight's
	# Block stance, the mage's spells. `_update_turn_ui` shows the ones the
	# active soul can use and hides the rest.
	turn_ui_ranged_button = Button.new()
	turn_ui_ranged_button.text = "Throw"
	turn_ui_ranged_button.toggle_mode = true
	turn_ui_ranged_button.custom_minimum_size = Vector2(128, 36)
	turn_ui_ranged_button.pressed.connect(_on_turn_ranged_button_pressed)
	actions_hbox.add_child(turn_ui_ranged_button)

	turn_ui_block_button = Button.new()
	turn_ui_block_button.text = "Block"
	turn_ui_block_button.custom_minimum_size = Vector2(128, 36)
	turn_ui_block_button.pressed.connect(_on_turn_block_button_pressed)
	actions_hbox.add_child(turn_ui_block_button)

	turn_ui_spell_buttons.clear()
	for spell in Soul.mage().spells:
		var spell_button := Button.new()
		spell_button.text = spell.display_name
		spell_button.toggle_mode = true
		spell_button.custom_minimum_size = Vector2(150, 36)
		spell_button.tooltip_text = spell.description
		spell_button.pressed.connect(_on_turn_spell_button_pressed.bind(spell.id))
		actions_hbox.add_child(spell_button)
		turn_ui_spell_buttons[spell.id] = spell_button

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

	# The soul strip is part of the character, so it shows in exploration too.
	_update_soul_ui()

	if turn_ui_panel == null:
		return

	var in_turn_mode := combat_state != CombatState.EXPLORATION
	turn_ui_panel.visible = in_turn_mode
	if turn_ui_order_panel != null:
		turn_ui_order_panel.visible = in_turn_mode
	# WP13: the action row stays up in exploration with the attacks the soul
	# can open a fight with (Melee, Throw, the spells); Block, Wait and End
	# Turn belong to a turn and are hidden there.
	if turn_ui_actions_panel != null:
		turn_ui_actions_panel.visible = true

	if in_turn_mode:
		var alive_enemies := _get_all_alive_enemies()
		if turn_ui_enemy_icon_entries.size() != alive_enemies.size():
			_rebuild_turn_enemy_icons()

	var can_attack := false
	var is_blocking := false
	if player != null and player.has_method("can_turn_attack"):
		can_attack = bool(player.call("can_turn_attack"))
	if player != null and player.has_method("is_blocking"):
		is_blocking = bool(player.call("is_blocking"))

	var can_player_use_actions := _player_can_pick_attack_aim()
	if can_player_use_actions and combat_state == CombatState.PLAYER_TURN and player != null and player.has_method("is_moving"):
		can_player_use_actions = not bool(player.call("is_moving"))
	var can_player_use_turn_actions := can_player_use_actions and combat_state == CombatState.PLAYER_TURN
	# An aim that can no longer be carried out - attack spent, or a shift to a
	# soul without that action - falls back to plain movement.
	var soul := _get_active_soul()
	if not can_attack and selected_player_turn_action != PlayerTurnAction.MOVE \
			and selected_player_turn_action != PlayerTurnAction.ABILITY:
		_set_player_turn_action(PlayerTurnAction.MOVE)
	if selected_player_turn_action == PlayerTurnAction.ABILITY and not player_turn_action_running:
		var aimed := _get_selected_ability()
		if aimed == null or ability_runner == null or not ability_runner.block_reason(aimed).is_empty():
			_set_player_turn_action(PlayerTurnAction.MOVE)
	if soul != null:
		if selected_player_turn_action == PlayerTurnAction.RANGED and not soul.has_ranged():
			_set_player_turn_action(PlayerTurnAction.MOVE)
		if selected_player_turn_action == PlayerTurnAction.SPELL and not soul.has_spells():
			_set_player_turn_action(PlayerTurnAction.MOVE)

	if turn_ui_attack_button != null:
		turn_ui_attack_button.disabled = not can_player_use_actions or not can_attack
		turn_ui_attack_button.button_pressed = selected_player_turn_action == PlayerTurnAction.ATTACK
		turn_ui_attack_button.text = "Melee (Select Target)" if selected_player_turn_action == PlayerTurnAction.ATTACK else "Melee"
	if turn_ui_ranged_button != null:
		var has_ranged := soul != null and soul.has_ranged()
		turn_ui_ranged_button.visible = has_ranged
		turn_ui_ranged_button.disabled = not can_player_use_actions or not can_attack
		turn_ui_ranged_button.button_pressed = selected_player_turn_action == PlayerTurnAction.RANGED
		if has_ranged:
			var ranged_label := "%s %dm" % [soul.ranged_name, int(round(soul.ranged_range_meters))]
			if selected_player_turn_action == PlayerTurnAction.RANGED:
				ranged_label += " (Select)"
			turn_ui_ranged_button.text = ranged_label
	if turn_ui_block_button != null:
		turn_ui_block_button.visible = in_turn_mode and (soul == null or soul.can_block_stance)
		turn_ui_block_button.disabled = not can_player_use_turn_actions
		turn_ui_block_button.text = "Block (Active)" if is_blocking else "Block"
	for spell_id in turn_ui_spell_buttons:
		var spell_button := turn_ui_spell_buttons[spell_id] as Button
		var spell: Soul.Spell = soul.get_spell(spell_id) if soul != null else null
		spell_button.visible = spell != null
		if spell == null:
			continue
		var cooldown := 0
		if player != null and player.has_method("get_spell_cooldown"):
			cooldown = int(player.call("get_spell_cooldown", spell_id))
		spell_button.disabled = not can_player_use_actions or not can_attack or cooldown > 0
		var aiming: bool = selected_player_turn_action == PlayerTurnAction.SPELL and selected_spell_id == spell_id
		spell_button.button_pressed = aiming
		var spell_label := "%s %dm" % [spell.display_name, int(round(spell.range_meters))]
		if cooldown > 0:
			spell_label = "%s (%d)" % [spell.display_name, cooldown]
		elif aiming:
			spell_label += " (Select)"
		spell_button.text = spell_label
	if turn_ui_wait_button != null:
		turn_ui_wait_button.visible = in_turn_mode
		turn_ui_wait_button.disabled = not can_player_use_turn_actions
	if turn_ui_end_turn_button != null:
		turn_ui_end_turn_button.visible = in_turn_mode
		turn_ui_end_turn_button.disabled = not can_player_use_turn_actions
		# Pulse End Turn once there is nothing left to spend, so the eye goes to
		# the one button that matters.
		var remaining_move := 0.0
		if player != null and player.has_method("get_turn_remaining_move_meters"):
			remaining_move = float(player.call("get_turn_remaining_move_meters"))
		var nothing_left := can_player_use_turn_actions and not can_attack and remaining_move <= 0.05
		if nothing_left:
			var pulse := 0.5 + 0.5 * sin(Time.get_ticks_msec() * 0.008)
			turn_ui_end_turn_button.modulate = Color.WHITE.lerp(Color(1.45, 1.3, 0.75, 1.0), pulse)
		else:
			turn_ui_end_turn_button.modulate = Color.WHITE

	if not in_turn_mode:
		return

	var player_turn_active := combat_state == CombatState.PLAYER_TURN
	var player_icon_dim := Color(1.0, 1.0, 1.0, 1.0) if player_turn_active else Color(0.45, 0.45, 0.45, 0.95)
	if turn_ui_player_icon != null:
		turn_ui_player_icon.modulate = player_icon_dim
	if turn_ui_player_label != null:
		turn_ui_player_label.add_theme_color_override("font_color", Color(0.72, 0.90, 1.0, 1.0) if player_turn_active else Color(0.68, 0.68, 0.68, 1.0))

	for i in range(turn_ui_enemy_icon_entries.size()):
		var entry := turn_ui_enemy_icon_entries[i]
		var enemy_actor := entry.get("enemy") as CharacterBody3D
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
				attack_mode_text = "%s aim" % (soul.ranged_name if soul != null else "Ranged")
			PlayerTurnAction.SPELL:
				var aimed_spell := _get_selected_spell()
				attack_mode_text = "%s aim" % (aimed_spell.display_name if aimed_spell != null else "Spell")
			PlayerTurnAction.ABILITY:
				var aimed_ability := _get_selected_ability()
				attack_mode_text = "%s aim" % (aimed_ability.display_name if aimed_ability != null else "Ability")
			_:
				attack_mode_text = "Move"
		var bonus_ready := player != null and player.has_method("has_bonus_action") and bool(player.call("has_bonus_action"))
		attack_text = "Action: %s | Bonus: %s | %s" % [("Ready" if can_attack_now else "Used"),
			("Ready" if bonus_ready else "Used"), attack_mode_text]
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

	if turn_ui_soul_label != null:
		if soul == null:
			turn_ui_soul_label.text = "Soul: -"
		else:
			var shifts_left := 0
			if player != null and player.has_method("get_shifts_left"):
				shifts_left = int(player.call("get_shifts_left"))
			if combat_state == CombatState.PLAYER_TURN:
				turn_ui_soul_label.text = "Soul: %s (F = %s) | Shifts left: %d" % [soul.title, soul.reaction_name(), shifts_left]
			else:
				turn_ui_soul_label.text = "Soul: %s (F = %s)" % [soul.title, soul.reaction_name()]
			turn_ui_soul_label.add_theme_color_override("font_color", soul.color)

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
	if action != PlayerTurnAction.SPELL:
		selected_spell_id = &""
	if action != PlayerTurnAction.ABILITY:
		selected_ability_id = &""


func _on_turn_attack_button_pressed() -> void:
	if not _player_can_pick_attack_aim():
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
	if not _player_can_pick_attack_aim():
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


func _on_turn_spell_button_pressed(spell_id: StringName) -> void:
	if not _player_can_pick_attack_aim():
		return
	if selected_player_turn_action == PlayerTurnAction.SPELL and selected_spell_id == spell_id:
		_set_player_turn_action(PlayerTurnAction.MOVE)
		_update_turn_ui()
		return
	if player != null and player.has_method("can_turn_attack"):
		if not bool(player.call("can_turn_attack")):
			return
	selected_spell_id = spell_id
	_set_player_turn_action(PlayerTurnAction.SPELL)
	_update_turn_ui()


func _on_turn_block_button_pressed() -> void:
	if combat_state != CombatState.PLAYER_TURN:
		return
	if player_turn_action_running:
		return
	var soul := _get_active_soul()
	if soul != null and not soul.can_block_stance:
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


# --- The Bound Three ---------------------------------------------------------
# The soul strip (top left) is always on screen: three portraits with their
# hotkeys and a status line. Shifting is free in exploration; in combat the
# player enforces the one-shift-per-turn rule and this side only gates on the
# turn state it owns (whose turn it is, whether an action is mid-flight).

func _request_shift(kind: int) -> void:
	if player == null or not player.has_method("shift_to"):
		return
	if combat_state == CombatState.ENEMY_TURN:
		_fx_popup(_popup_anchor(player), "Locked in", CombatFx.COLOR_WARNING, 16)
		return
	if combat_state == CombatState.PLAYER_TURN:
		if player_turn_action_running:
			return
		if player.has_method("is_moving") and bool(player.call("is_moving")):
			return
	var shifted := bool(player.call("shift_to", kind))
	if shifted:
		# An aim the new soul can't perform falls back to plain movement.
		var soul := _get_active_soul()
		if soul != null:
			if selected_player_turn_action == PlayerTurnAction.RANGED and not soul.has_ranged():
				_set_player_turn_action(PlayerTurnAction.MOVE)
			if selected_player_turn_action == PlayerTurnAction.SPELL and not soul.has_spells():
				_set_player_turn_action(PlayerTurnAction.MOVE)
	_update_turn_ui()


func _on_soul_button_pressed(kind: int) -> void:
	_request_shift(kind)


func _on_player_soul_changed(soul: Soul) -> void:
	# The turn-order card is the body's card; it wears whoever is in control.
	if turn_ui_player_icon != null:
		turn_ui_player_icon.texture = SoulArt.create_portrait(soul.kind)
		turn_ui_player_icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	if turn_ui_player_label != null:
		turn_ui_player_label.text = soul.title
	_update_soul_ui()


func _setup_soul_ui() -> void:
	soul_ui_panel = PanelContainer.new()
	soul_ui_panel.name = "SoulUI"
	soul_ui_panel.anchor_left = 0.0
	soul_ui_panel.anchor_top = 0.0
	soul_ui_panel.anchor_right = 0.0
	soul_ui_panel.anchor_bottom = 0.0
	soul_ui_panel.offset_left = 18.0
	soul_ui_panel.offset_top = 18.0
	soul_ui_panel.offset_right = 18.0 + 330.0
	soul_ui_panel.offset_bottom = 18.0 + 124.0
	soul_ui_panel.add_theme_stylebox_override("panel", UiTheme.box(UiTheme.PANEL_BG, UiTheme.PANEL_BORDER, 2, 10, 8))
	turn_ui_layer.add_child(soul_ui_panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	soul_ui_panel.add_child(vbox)

	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 8)
	vbox.add_child(row)

	soul_ui_buttons.clear()
	var souls: Array = []
	if player != null and player.has_method("get_souls"):
		souls = player.call("get_souls")
	for soul: Soul in souls:
		var button := Button.new()
		button.name = "Soul_%s" % soul.id
		button.icon = SoulArt.create_portrait(soul.kind)
		button.text = "%s  %s" % [soul.hotkey_label, soul.title]
		button.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		button.vertical_icon_alignment = VERTICAL_ALIGNMENT_TOP
		button.expand_icon = true
		button.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		button.custom_minimum_size = Vector2(96, 74)
		button.tooltip_text = "%s, the %s\n%s" % [soul.display_name, soul.title, soul.description]
		button.set_meta("soul_kind", int(soul.kind))
		UiTheme.style_button(button, 13)
		button.pressed.connect(_on_soul_button_pressed.bind(int(soul.kind)))
		row.add_child(button)
		soul_ui_buttons.append(button)

	soul_ui_status_label = UiTheme.label("", UiTheme.MUTED, 12)
	soul_ui_status_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(soul_ui_status_label)

	if player != null and player.has_signal("soul_changed"):
		player.connect("soul_changed", _on_player_soul_changed)
	var active := _get_active_soul()
	if active != null:
		_on_player_soul_changed(active)


func _update_soul_ui() -> void:
	if soul_ui_panel == null or soul_ui_status_label == null:
		return
	var soul := _get_active_soul()
	if soul == null:
		return

	# Restyle only when the soul changes: a fresh StyleBox per frame is waste.
	if _soul_ui_styled_kind != int(soul.kind):
		_soul_ui_styled_kind = int(soul.kind)
		for button in soul_ui_buttons:
			var is_active := int(button.get_meta("soul_kind", -1)) == int(soul.kind)
			if is_active:
				var lit := UiTheme.box(UiTheme.SLOT_SELECTED, soul.color, 2, 12, 6)
				button.add_theme_stylebox_override("normal", lit)
				button.add_theme_stylebox_override("hover", lit)
				button.add_theme_stylebox_override("pressed", lit)
				button.add_theme_color_override("font_color", soul.color)
				button.add_theme_color_override("font_hover_color", soul.color)
			else:
				UiTheme.style_button(button, 13)

	var can_press := combat_state != CombatState.ENEMY_TURN and not player_turn_action_running
	for button in soul_ui_buttons:
		button.disabled = not can_press

	var status := ""
	var status_color := UiTheme.MUTED
	match combat_state:
		CombatState.EXPLORATION:
			status = "%s in control  |  1 / 2 / 3 or Q to shift" % soul.display_name
		CombatState.PLAYER_TURN:
			var shifts_left := 0
			if player.has_method("get_shifts_left"):
				shifts_left = int(player.call("get_shifts_left"))
			if shifts_left > 0:
				status = "%s  |  Shift ready (%d)" % [soul.display_name, shifts_left]
				status_color = CombatFx.COLOR_PLAYER_TURN
			else:
				status = "%s  |  Shift used this turn" % soul.display_name
		CombatState.ENEMY_TURN:
			status = "%s holds the body  |  F to %s" % [soul.display_name, soul.reaction_name().to_lower()]
			status_color = CombatFx.COLOR_ENEMY_TURN
	soul_ui_status_label.text = status
	soul_ui_status_label.add_theme_color_override("font_color", status_color)


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

		if enemy_actor.has_method("get_portrait_color"):
			enemy_icon.texture = _create_placeholder_icon(enemy_actor.call("get_portrait_color") as Color)

		var enemy_label := Label.new()
		enemy_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		enemy_label.text = "Enemy %d" % (i + 1)
		if enemy_actor.has_method("get_display_name"):
			enemy_label.text = String(enemy_actor.call("get_display_name"))
		enemy_label.add_theme_font_size_override("font_size", 12)
		enemy_box.add_child(enemy_label)

		turn_ui_enemy_icon_entries.append({
			"enemy": enemy_actor,
			"panel": enemy_panel,
			"icon": enemy_icon,
			"label": enemy_label
		})


func _update_hover_state() -> void:
	# Outside combat the outline tells you the enemy is a click-to-attack
	# target; inside it marks what a click will engage. Pickups get the same
	# push, because a 3D pickup never hit-tests itself (section 8).
	if InventoryScreen.is_open() or LootMenu.is_open() or _skill_tree_open():
		_set_hovered_enemy(null)
		_set_hovered_pickup(null)
		_set_hovered_prop_target(null)
		return

	var mouse := get_viewport().get_mouse_position()
	var hovered := _pick_enemy(mouse) as CharacterBody3D
	_set_hovered_enemy(hovered)
	_set_hovered_pickup(_pick_pickup(mouse))
	var prop_target: Node3D = null
	if hovered == null:
		prop_target = _pick_prop_in_group(mouse, &"hittable")
		if prop_target == null:
			prop_target = _pick_prop_in_group(mouse, &"interactable")
	_set_hovered_prop_target(prop_target)
	if hover_hint_label != null:
		var hint := ""
		if prop_target != null:
			if prop_target.has_method("get_interact_label"):
				hint = String(prop_target.call("get_interact_label"))
			elif prop_target.is_in_group(&"hittable"):
				hint = "Explosive - strike it"
		elif hovered != null and hovered.has_method("get_display_name"):
			hint = String(hovered.call("get_display_name"))
			if hovered.has_method("get_statuses"):
				var statuses: Dictionary = hovered.call("get_statuses")
				for status_id in statuses:
					hint += "  %s" % String(status_id).to_upper()
		hover_hint_label.text = hint
		hover_hint_label.visible = not hint.is_empty()
		hover_hint_label.position = mouse + Vector2(18, 14)


func _set_hovered_pickup(new_pickup: Node3D) -> void:
	if hovered_pickup != null and not is_instance_valid(hovered_pickup):
		hovered_pickup = null
	if new_pickup != null and not is_instance_valid(new_pickup):
		new_pickup = null
	if hovered_pickup == new_pickup:
		return
	if hovered_pickup != null and hovered_pickup.has_method("set_hover_highlighted"):
		hovered_pickup.call("set_hover_highlighted", false)
	hovered_pickup = new_pickup
	if hovered_pickup != null and hovered_pickup.has_method("set_hover_highlighted"):
		hovered_pickup.call("set_hover_highlighted", true)


func _set_hovered_enemy(new_enemy: CharacterBody3D) -> void:
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


# --- Gameplay expansion --------------------------------------------------------
# Abilities (AbilityRunner3D, the ability bar), the skill tree (K), sneaking (C),
# the world's hittables and interactables, slipping away from a fight, respawn
# after a defeat, and the coordinator interface of docs/gameplay-expansion.md,
# section 5.

func _setup_gameplay_expansion() -> void:
	ability_runner = AbilityRunner3D.new()
	ability_runner.name = "AbilityRunner"
	add_child(ability_runner)
	var player_3d := player as Player3D
	if player_3d != null:
		ability_runner.setup(player_3d)
		skill_tree_screen = SkillTreeScreen3D.new()
		skill_tree_screen.name = "SkillTree"
		add_child(skill_tree_screen)
		skill_tree_screen.setup(player_3d.get_progression())
		skill_tree_screen.visibility_changed_to.connect(_on_skill_tree_visibility_changed)
	_setup_ability_bar()


func _skill_tree_open() -> bool:
	return skill_tree_screen != null and skill_tree_screen.is_open()


func _on_skill_tree_visibility_changed(open: bool) -> void:
	# The world waits while the tree is open, as it does under the story book.
	get_tree().paused = open
	_update_turn_ui()


## K, C and the ability hotkeys, in every combat state. True when handled.
func _handle_expansion_keys(event: InputEvent) -> bool:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return false
	if key.physical_keycode == SKILL_TREE_KEY:
		_toggle_skill_tree()
		return true
	if key.physical_keycode == SNEAK_KEY:
		_toggle_sneak()
		return true
	if key.physical_keycode == KEY_ESCAPE and selected_player_turn_action == PlayerTurnAction.ABILITY:
		_set_player_turn_action(PlayerTurnAction.MOVE)
		return true
	var index := ABILITY_HOTKEYS.find(key.physical_keycode)
	if index >= 0 and index < ability_bar_order.size():
		_on_ability_button_pressed(ability_bar_order[index].id)
		return true
	return false


func _toggle_skill_tree() -> void:
	if skill_tree_screen == null:
		return
	if InventoryScreen.is_open():
		return
	skill_tree_screen.toggle()


func _toggle_sneak() -> void:
	if not player.has_method("set_sneaking"):
		return
	if combat_state != CombatState.EXPLORATION:
		_fx_popup(_popup_anchor(player), "Too late to hide", CombatFx.COLOR_WARNING, 16)
		return
	player.call("set_sneaking", not bool(player.call("is_sneaking")))
	_update_turn_ui()


func _get_selected_ability() -> Ability3D:
	if selected_ability_id == &"":
		return null
	return AbilityCatalog3D.get_ability(selected_ability_id)


## The abilities on the bar: the active soul's learned ones, then any-soul ones.
func _bar_abilities() -> Array[Ability3D]:
	var result: Array[Ability3D] = []
	var soul := _get_active_soul()
	var player_3d := player as Player3D
	if soul == null or player_3d == null or player_3d.get_progression() == null:
		return result
	return player_3d.get_progression().learned_for_soul(int(soul.kind))


func _on_ability_button_pressed(ability_id: StringName) -> void:
	var ability := AbilityCatalog3D.get_ability(ability_id)
	if ability == null or ability_runner == null:
		return
	if not _player_can_pick_attack_aim():
		return
	if combat_state == CombatState.PLAYER_TURN and player.has_method("is_moving") and bool(player.call("is_moving")):
		return
	if selected_player_turn_action == PlayerTurnAction.ABILITY and selected_ability_id == ability_id:
		_set_player_turn_action(PlayerTurnAction.MOVE)
		_update_turn_ui()
		return
	var reason := ability_runner.block_reason(ability)
	if not reason.is_empty():
		_fx_popup(_popup_anchor(player), reason, CombatFx.COLOR_WARNING, 16)
		return
	if ability.target == Ability3D.Target.SELF:
		_set_player_turn_action(PlayerTurnAction.MOVE)
		_execute_ability(ability, null, null)
		return
	_set_player_turn_action(PlayerTurnAction.ABILITY)
	selected_ability_id = ability_id
	_update_turn_ui()


## A click while an ability is aimed: an enemy (or a hittable) for ENEMY
## abilities, a ground point for GROUND ones.
func _handle_ability_click(screen_pos: Vector2) -> void:
	var ability := _get_selected_ability()
	if ability == null:
		_set_player_turn_action(PlayerTurnAction.MOVE)
		return
	if player_turn_action_running:
		return
	if ability.target == Ability3D.Target.ENEMY:
		var target: Node3D = _pick_enemy(screen_pos)
		if target == null:
			target = _pick_prop_in_group(screen_pos, &"hittable")
		if target == null:
			_fx_popup(_popup_anchor(player), "Pick an enemy", CombatFx.COLOR_WARNING, 14)
			return
		_execute_ability(ability, target, null)
		return
	var ground: Variant = _pick_ground(screen_pos)
	if ground == null:
		return
	_execute_ability(ability, null, ground)


## Runs an ability with the turn held. A melee ability out of reach walks up
## first (spending movement in a fight), like a melee click does.
func _execute_ability(ability: Ability3D, target: Node3D, point: Variant) -> void:
	if ability_runner == null or player_turn_action_running:
		return
	var state_at_start := combat_state
	player_turn_action_running = true
	if combat_state == CombatState.EXPLORATION:
		_stop_player_for_exploration_attack()
	if ability.target == Ability3D.Target.ENEMY and ability.is_melee() and target != null:
		var reach := ability_runner.get_range(ability)
		if GroundMath.ground_distance(player.global_position, target.global_position) > reach + ATTACK_RANGE_TOLERANCE_M:
			await _approach_for_melee(target, reach)
			if combat_state != state_at_start or not is_instance_valid(target):
				player_turn_action_running = false
				return
	await ability_runner.execute(ability, target, point)
	player_turn_action_running = false
	if combat_state == state_at_start:
		_set_player_turn_action(PlayerTurnAction.MOVE)
	_update_turn_ui()


## Walks toward `target` until it is within `reach`: within the turn's movement
## in a fight, freely in exploration (where being spotted on the way starts the
## fight and cancels the ability).
func _approach_for_melee(target: Node3D, reach: float) -> void:
	var stop := approach_distance_for(player, target, reach)
	var approach_point := _compute_approach_world_point(player.global_position, target.global_position, stop)
	var state_at_start := combat_state
	if combat_state == CombatState.PLAYER_TURN:
		var remaining := float(player.call("get_turn_remaining_move_meters")) if player.has_method("get_turn_remaining_move_meters") else 0.0
		if remaining <= 0.0:
			return
		var used := _request_player_turn_move_by_distance(approach_point, remaining)
		if used > 0.0 and player.has_method("consume_turn_movement_meters"):
			player.call("consume_turn_movement_meters", used)
	else:
		_request_player_move(approach_point)
	var deadline := Time.get_ticks_msec() + int(MELEE_APPROACH_TIMEOUT_SECONDS * 1000.0)
	while player.has_method("is_moving") and bool(player.call("is_moving")):
		await get_tree().physics_frame
		if combat_state != state_at_start or not is_instance_valid(target) or Time.get_ticks_msec() > deadline:
			return
		if combat_state == CombatState.EXPLORATION \
				and GroundMath.ground_distance(player.global_position, target.global_position) <= reach:
			player.call("stop_movement_immediately")
			return


func _setup_ability_bar() -> void:
	ability_bar_panel = PanelContainer.new()
	ability_bar_panel.name = "AbilityBar"
	ability_bar_panel.anchor_left = 0.5
	ability_bar_panel.anchor_right = 0.5
	ability_bar_panel.anchor_top = 1.0
	ability_bar_panel.anchor_bottom = 1.0
	ability_bar_panel.offset_left = -300.0
	ability_bar_panel.offset_right = 300.0
	ability_bar_panel.offset_top = -142.0
	ability_bar_panel.offset_bottom = -90.0
	ability_bar_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	ability_bar_panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	ability_bar_panel.add_theme_stylebox_override("panel", UiTheme.box(UiTheme.PANEL_BG, UiTheme.PANEL_BORDER, 2, 10, 6))
	turn_ui_layer.add_child(ability_bar_panel)

	var outer := HBoxContainer.new()
	outer.alignment = BoxContainer.ALIGNMENT_CENTER
	outer.add_theme_constant_override("separation", 14)
	ability_bar_panel.add_child(outer)

	ability_bar_row = HBoxContainer.new()
	ability_bar_row.add_theme_constant_override("separation", 8)
	outer.add_child(ability_bar_row)

	var divider := ColorRect.new()
	divider.color = UiTheme.RULE
	divider.custom_minimum_size = Vector2(1, 30)
	outer.add_child(divider)

	sneak_button = Button.new()
	sneak_button.toggle_mode = true
	sneak_button.text = "Sneak (C)"
	sneak_button.tooltip_text = "Crouch and move quietly: slower, and enemies must come much closer to spot you. In a bush, or as the rogue, even closer. A hit on an unaware enemy while sneaking is a sneak attack (x2, the rogue x3)."
	sneak_button.custom_minimum_size = Vector2(104, 36)
	UiTheme.style_button(sneak_button, 13)
	sneak_button.pressed.connect(_toggle_sneak)
	outer.add_child(sneak_button)

	skills_button = Button.new()
	skills_button.text = "Skills (K)"
	skills_button.custom_minimum_size = Vector2(104, 36)
	UiTheme.style_button(skills_button, 13)
	skills_button.pressed.connect(_toggle_skill_tree)
	outer.add_child(skills_button)

	stealth_label = UiTheme.label("", Color(0.8, 0.7, 1.0, 1.0), 14)
	stealth_label.position = Vector2(22.0, 150.0)
	stealth_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	turn_ui_layer.add_child(stealth_label)

	hover_hint_label = UiTheme.label("", UiTheme.TITLE, 14)
	hover_hint_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	hover_hint_label.add_theme_constant_override("outline_size", 6)
	hover_hint_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hover_hint_label.visible = false
	turn_ui_layer.add_child(hover_hint_label)


func _rebuild_ability_bar(abilities: Array[Ability3D]) -> void:
	for child in ability_bar_row.get_children():
		child.queue_free()
	ability_bar_buttons.clear()
	ability_bar_order = abilities
	for i in range(abilities.size()):
		var ability := abilities[i]
		var button := Button.new()
		button.toggle_mode = true
		button.custom_minimum_size = Vector2(118, 36)
		button.tooltip_text = "%s\n%s\n%s" % [ability.display_name, ability.summary(), ability.description]
		UiTheme.style_button(button, 13)
		button.add_theme_color_override("font_color", ability.color)
		button.pressed.connect(_on_ability_button_pressed.bind(ability.id))
		ability_bar_row.add_child(button)
		ability_bar_buttons[ability.id] = button


func _update_ability_bar() -> void:
	if ability_bar_panel == null:
		return
	var abilities := _bar_abilities()
	var signature := ""
	for ability in abilities:
		signature += String(ability.id) + ","
	if signature != _ability_bar_signature:
		_ability_bar_signature = signature
		_rebuild_ability_bar(abilities)
	var can_pick := _player_can_pick_attack_aim()
	if can_pick and combat_state == CombatState.PLAYER_TURN and player.has_method("is_moving"):
		can_pick = not bool(player.call("is_moving"))
	for i in range(ability_bar_order.size()):
		var ability := ability_bar_order[i]
		var button := ability_bar_buttons.get(ability.id) as Button
		if button == null:
			continue
		var reason := ability_runner.block_reason(ability) if ability_runner != null else "No body"
		var cooldown := ability_runner.get_cooldown(ability.id) if ability_runner != null else 0
		var hotkey := str(i + 4)
		var label := "%s %s" % [hotkey, ability.display_name]
		if cooldown > 0:
			label = "%s %s (%d)" % [hotkey, ability.display_name, cooldown]
		elif ability.cost == Ability3D.Cost.BONUS:
			label += " +"
		button.text = label
		button.disabled = not can_pick or not reason.is_empty()
		button.button_pressed = selected_player_turn_action == PlayerTurnAction.ABILITY and selected_ability_id == ability.id
	if sneak_button != null:
		var sneaking := player.has_method("is_sneaking") and bool(player.call("is_sneaking"))
		sneak_button.visible = combat_state == CombatState.EXPLORATION
		sneak_button.button_pressed = sneaking
		sneak_button.text = "Sneaking (C)" if sneaking else "Sneak (C)"
	if skills_button != null:
		var points := 0
		var player_3d := player as Player3D
		if player_3d != null and player_3d.get_progression() != null:
			points = player_3d.get_progression().skill_points
		skills_button.text = "Skills (K)  %d pt" % points if points > 0 else "Skills (K)"
		skills_button.modulate = Color(1.25, 1.15, 0.8, 1.0) if points > 0 else Color.WHITE


func _update_stealth_label() -> void:
	if stealth_label == null:
		return
	var text := ""
	if player.has_method("is_hidden_by_smoke") and bool(player.call("is_hidden_by_smoke")):
		text = "In smoke - unseen"
	elif player.has_method("is_sneaking") and bool(player.call("is_sneaking")):
		if player.has_method("is_in_cover") and bool(player.call("is_in_cover")):
			text = "Sneaking in cover - unseen"
		else:
			text = "Sneaking - detection rings shrink"
	elif player.has_method("is_in_cover") and bool(player.call("is_in_cover")):
		text = "In cover - press C to hide"
	stealth_label.text = text
	stealth_label.visible = not text.is_empty()


## The world object in `group` under the cursor: a ray on the prop layer, then up
## the parents to the first node in the group (docs/gameplay-expansion.md 3).
func _pick_prop_in_group(screen_pos: Vector2, group: StringName) -> Node3D:
	var camera := _get_active_camera()
	if camera == null or not is_inside_tree():
		return null
	var world := get_world_3d()
	if world == null or world.direct_space_state == null:
		return null
	var from := camera.project_ray_origin(screen_pos)
	var to := from + camera.project_ray_normal(screen_pos) * 400.0
	var query := PhysicsRayQueryParameters3D.create(from, to, LAYER_PROPS)
	query.collide_with_areas = false
	query.collide_with_bodies = true
	var hit: Dictionary = world.direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return null
	var node := hit.get("collider") as Node
	while node != null and node != self:
		if node.is_in_group(group) and node is Node3D:
			if node.has_method("is_alive") and not bool(node.call("is_alive")):
				return null
			if node.has_method("can_interact") and not bool(node.call("can_interact")):
				return null
			return node as Node3D
		node = node.get_parent()
	return null


func _set_hovered_prop_target(target: Node3D) -> void:
	if hovered_prop_target != null and not is_instance_valid(hovered_prop_target):
		hovered_prop_target = null
	if hovered_prop_target == target:
		return
	if hovered_prop_target != null and hovered_prop_target.has_method("set_hover_highlighted"):
		hovered_prop_target.call("set_hover_highlighted", false)
	hovered_prop_target = target
	if hovered_prop_target != null and hovered_prop_target.has_method("set_hover_highlighted"):
		hovered_prop_target.call("set_hover_highlighted", true)


func _interact_range(target: Node3D) -> float:
	if target.has_method("get_interact_range"):
		return float(target.call("get_interact_range"))
	return 1.8


## A click on an interactable: use it when in range, else walk over and use it
## on arrival.
func _request_interaction(target: Node3D) -> void:
	if target == null or not is_instance_valid(target):
		return
	if player.has_method("clear_attack_target"):
		player.call("clear_attack_target")
	if GroundMath.ground_distance(player.global_position, target.global_position) <= _interact_range(target) + INTERACT_RANGE_SLACK_M:
		_pending_interactable = null
		player.call("stop_movement_immediately")
		target.call("interact", player)
		return
	_pending_interactable = target
	_pending_interact_deadline_msec = Time.get_ticks_msec() + int(INTERACT_WALK_TIMEOUT_SECONDS * 1000.0)
	var stop := maxf(0.5, _interact_range(target) - 0.4)
	_request_player_move(_compute_approach_world_point(player.global_position, target.global_position, stop))


func _update_pending_interaction() -> void:
	if _pending_interactable == null:
		return
	if not is_instance_valid(_pending_interactable) or combat_state != CombatState.EXPLORATION \
			or Time.get_ticks_msec() > _pending_interact_deadline_msec:
		_pending_interactable = null
		return
	var in_range := GroundMath.ground_distance(player.global_position, _pending_interactable.global_position) \
		<= _interact_range(_pending_interactable) + INTERACT_RANGE_SLACK_M
	if in_range:
		var target := _pending_interactable
		_pending_interactable = null
		player.call("stop_movement_immediately")
		target.call("interact", player)
	elif player.has_method("is_moving") and not bool(player.call("is_moving")):
		_pending_interactable = null


## After a melee swing, a throw or a spell: the rogue's Killing Spree.
func _after_player_strike(target: Node3D) -> void:
	var soul := _get_active_soul()
	if soul == null or soul.kind != Soul.Kind.ROGUE or combat_state != CombatState.PLAYER_TURN:
		return
	if target == null:
		return
	var dead := not is_instance_valid(target) \
		or (target.has_method("is_alive") and not bool(target.call("is_alive")))
	if dead and player.has_method("refund_action_once") and bool(player.call("refund_action_once")):
		_fx_popup(_popup_anchor(player) + Vector3(0.0, 0.6, 0.0), "KILLING SPREE  +action", AbilityCatalog3D.COLOR_ROGUE, 18)


func _player_is_stealthy() -> bool:
	if player.has_method("is_hidden") and bool(player.call("is_hidden")):
		return true
	return player.has_method("is_sneaking") and bool(player.call("is_sneaking"))


## A stealth strike: the struck enemy's neighbours within STEALTH_ALERT_RADIUS_M
## and anyone who can see the body join; nobody else.
func _refresh_engaged_enemies_stealthy(struck_enemy: CharacterBody3D) -> void:
	var struck_position := player.global_position
	if struck_enemy != null and is_instance_valid(struck_enemy):
		struck_position = struck_enemy.global_position
	for enemy_actor in _get_all_alive_enemies_unfiltered():
		if engaged_enemies.has(enemy_actor.get_instance_id()):
			continue
		var near_struck := GroundMath.ground_distance(struck_position, enemy_actor.global_position) <= STEALTH_ALERT_RADIUS_M
		if near_struck or _enemy_can_spot_player(enemy_actor):
			engaged_enemies[enemy_actor.get_instance_id()] = true


## True when the player's turn ends out of every engaged enemy's reach and sight
## (see ESCAPE_DISTANCE_M), or in smoke with nobody close.
func _player_escaped() -> bool:
	var engaged := _get_all_alive_enemies()
	if engaged.is_empty():
		return false
	var in_smoke := player.has_method("is_hidden_by_smoke") and bool(player.call("is_hidden_by_smoke"))
	for enemy_actor in engaged:
		var distance := GroundMath.ground_distance(player.global_position, enemy_actor.global_position)
		if in_smoke:
			if distance <= ESCAPE_SMOKE_MIN_M:
				return false
			continue
		if distance <= ESCAPE_DISTANCE_M:
			return false
		if distance <= ESCAPE_ANY_SIGHT_M and enemy_actor.has_method("has_line_of_sight_to") \
				and bool(enemy_actor.call("has_line_of_sight_to", player)):
			return false
	return true


func _escape_combat() -> void:
	CombatFx.announce(ANNOUNCE_ESCAPED, Color(0.8, 0.55, 1.0, 1.0), 1.0)
	_end_turn_based_combat()


## Defeat: back on the feet at the last waystone (or the spawn) after a beat.
## The enemies of the lost fight go back to watching.
func _schedule_respawn() -> void:
	_respawn_scheduled = true
	await get_tree().create_timer(RESPAWN_DELAY_SECONDS).timeout
	if not is_instance_valid(player):
		return
	var point := _respawn_point if _has_respawn_point else player.global_position
	player.call("revive", point)
	if camera_rig != null:
		camera_rig.snap_to_target()
	CombatFx.announce("THE BOUND RISE AGAIN", CombatFx.COLOR_COMBAT, 1.2)
	_respawn_scheduled = false
	_update_turn_ui()


## Coordinator interface (docs/gameplay-expansion.md 5): an enemy spawned at
## runtime (the boss's summons). Engaged at once when a fight is running.
func register_spawned_enemy(enemy_actor: CharacterBody3D) -> void:
	if enemy_actor == null or not is_instance_valid(enemy_actor):
		return
	if not enemy_actor.is_in_group("enemies"):
		enemy_actor.add_to_group("enemies")
	if enemy == null or not is_instance_valid(enemy):
		enemy = enemy_actor
	elif not extra_enemies.has(enemy_actor):
		extra_enemies.append(enemy_actor)
	_connect_enemy_signals(enemy_actor)
	if enemy_actor.has_method("set_target"):
		enemy_actor.call("set_target", player)
	if combat_state != CombatState.EXPLORATION:
		if enemy_actor.has_method("set_turn_based_combat"):
			enemy_actor.call("set_turn_based_combat", true)
		engaged_enemies[enemy_actor.get_instance_id()] = true
		_rebuild_turn_enemy_icons()


## A waystone moved the player: the camera jumps along and the stone becomes
## the respawn point.
func on_player_teleported() -> void:
	if camera_rig != null:
		camera_rig.snap_to_target()
	_respawn_point = GroundMath.flatten(player.global_position)
	_has_respawn_point = true


func is_in_combat() -> bool:
	return combat_state != CombatState.EXPLORATION
