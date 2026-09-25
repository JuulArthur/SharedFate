extends Node

## WP8 integration smoke for the playable 3D slice (scenes/3d/arena.tscn).
## Child of the arena root named "IntegrationSmoke"; the coordinator ignores it
## (docs/3d-port-contracts.md, section 9).
##
## Headless has no clicks, so this drives the parity checklist of
## docs/3d-test-plan.md through the coordinator's request methods and the
## actors' APIs, in one scripted fight against the first wolf and then the
## second: click-to-move, combat start by proximity, movement budget trimming,
## melee with the contact delay, the counter window (a simulated perfect press
## while the knight is in control negates the bite), one shift per turn, the
## rogue throw and both mage spells with their rings, enemy turn pacing, a
## loot drop and pickup, the inventory screen and the story book. It also
## keeps WP7's level checks and verifies the imported models (the three soul
## bodies with the knight's shown and its sword hanging from the right hand,
## the wolf body). Prints INTEGRATION OK,
## or the first failing step with its values, then quits.
##
## Inert with a window: it only runs headless, or with the user argument
## `--integration-smoke`, so F6 on the arena plays normally.
##
##   godot --headless --path . res://scenes/3d/arena.tscn --quit-after 1200

const Main3D := preload("res://scripts/3d/main_3d.gd")

const RUN_ARGUMENT := "--integration-smoke"
# Headless paces at about 145 fps; pinning 60 keeps timers and physics on a
# real clock so the contact and turn timings mean something.
const HEADLESS_FPS := 60

const NAVMESH_TIMEOUT_SECONDS := 5.0
const MOVE_TIMEOUT_SECONDS := 4.0
const COMBAT_TIMEOUT_SECONDS := 6.0
const ENEMY_TURN_TIMEOUT_SECONDS := 10.0
const LOOT_TIMEOUT_SECONDS := 3.0
const SPAWN_TOLERANCE_M := 0.5
const PATH_TARGET_DISTANCE_M := 10.0
const PATH_MAX_LENGTH_M := 20.0
const PROP_LAYER := 8
# WP12: the props were re-exported without the stray default scene; the level
# must see the same 22 props and 48 blocked cells as before.
const EXPECTED_PROP_COUNT := 22
const EXPECTED_BLOCKED_CELLS := 48
# The sword hangs from the hand: its lowest point well below the hand, its top
# not far above it, its centre near the hand on the ground plane.
const SWORD_MIN_DROP_M := 0.4
const SWORD_MAX_RISE_M := 0.3
const SWORD_MAX_LATERAL_M := 0.5
# WP9: the anchor follows the active body; the knight's glb OverheadAnchor is
# 0.25 m over its 1.995 m head.
const PLAYER_ANCHOR_HEIGHT_M := 2.245
const PLAYER_ANCHOR_TOLERANCE_M := 0.01
const WOLF_ANCHOR_HEIGHT_M := 0.95
const EXPLORATION_STEP_M := 1.5
# The second and third wolf wait here, outside the 9 m engagement radius, so
# the scripted fight has one opponent and one enemy turn per beat.
const PARK_B := Vector3(10.0, 0.0, -10.0)
const PARK_C := Vector3(10.0, 0.0, 10.0)
const TRIM_REQUEST_M := 10.0
const MELEE_SNAP_M := 1.0
const SPELL_WOLF_DISTANCE_M := 3.0
const LOOT_RADIUS_M := 1.0
const LOOT_STAND_OFF_M := 0.8
# A SceneTreeTimer counts the frame it was created in and the health watcher
# looks once per frame, so a contact can read up to about a frame early.
const TIMING_TOLERANCE_MS := 25
const PACING_TOLERANCE_SECONDS := 0.05

var _main: Main3D
var _player: Player3D
var _camera_rig: CameraRig3D
var _spawn: Node3D
var _wolves: Array[Enemy3D] = []
var _loot_pickup: ItemPickup3D = null
var _death_position := Vector3.ZERO

var _step := "boot"
var _active := false
var _done := false

# The knight block: while armed, `_process` records the prompt showing and
# presses on the first frame of the strike window.
var _press_armed := false
var _press_done := false
var _prompt_seen := false
var _press_wolf: Enemy3D = null

# The melee contact watcher.
var _hit_msec := -1
var _watch_id := 0


func _ready() -> void:
	if not _should_run():
		return
	_active = true
	# The story book pauses the tree; this node keeps driving.
	process_mode = Node.PROCESS_MODE_ALWAYS
	if DisplayServer.get_name() == "headless":
		Engine.max_fps = HEADLESS_FPS
	# The parent's _ready runs after this one; start once the tree has settled.
	call_deferred("_run")


func _should_run() -> bool:
	if DisplayServer.get_name() == "headless":
		return true
	return OS.get_cmdline_user_args().has(RUN_ARGUMENT)


func _exit_tree() -> void:
	if _active and not _done:
		print("INTEGRATION FAIL: quit during step '%s'" % _step)


func _process(_delta: float) -> void:
	if not _press_armed or _player == null:
		return
	if _press_wolf != null and is_instance_valid(_press_wolf):
		var prompt := _press_wolf.get_counter_prompt()
		if prompt != null and prompt.visible:
			_prompt_seen = true
	if not _press_done and _player._counter_phase == Player3D.COUNTER_PHASE_STRIKE:
		_player._register_counter_press()
		_press_done = true


func _run() -> void:
	await get_tree().process_frame
	var steps: Array = [
		["boot", _step_boot],
		["navmesh", _step_navmesh],
		["level", _step_level],
		["models", _step_models],
		["level_loader", _step_level_loader],
		["click_to_move", _step_click_to_move],
		["combat_start", _step_combat_start],
		["budget_trim", _step_budget_trim],
		["melee", _step_melee],
		["counter_block", _step_counter_block],
		["shift_once", _step_shift_once],
		["throw", _step_throw],
		["loot_drop", _step_loot_drop],
		["spells", _step_spells],
		["loot_pickup", _step_loot_pickup],
		["inventory", _step_inventory],
		["story_book", _step_story_book],
	]
	for entry in steps:
		_step = String(entry[0])
		var step: Callable = entry[1]
		var result: Variant = await step.call()
		var failure := str(result)
		if not failure.is_empty():
			_fail(failure)
			return
		print("[integration] %s ok" % _step)
	_done = true
	print("INTEGRATION OK")
	get_tree().quit(0)


func _fail(reason: String) -> void:
	_done = true
	print("INTEGRATION FAIL: %s: %s" % [_step, reason])
	get_tree().quit(1)


# --- Steps -----------------------------------------------------------------------

func _step_boot() -> String:
	_main = get_parent() as Main3D
	if _main == null:
		return "main_3d.gd is not on the parent node"
	_player = _main.player as Player3D
	if _player == null:
		return "Player is not a Player3D (expected an instance of scenes/3d/player_3d.tscn)"
	_camera_rig = _main.get_node_or_null("CameraRig") as CameraRig3D
	if _camera_rig == null:
		return "no CameraRig3D under the arena root"
	_spawn = _main.find_child("Spawn_default", true, false) as Node3D
	if _spawn == null:
		return "no Spawn_default under the arena root"
	_wolves.clear()
	for node in get_tree().get_nodes_in_group("enemies"):
		var wolf := node as Enemy3D
		if wolf != null and _main.is_ancestor_of(wolf):
			_wolves.append(wolf)
	_wolves.sort_custom(func(a: Enemy3D, b: Enemy3D) -> bool: return String(a.name) < String(b.name))
	if _wolves.size() != 3:
		return "expected 3 Enemy3D wolves in group 'enemies', found %d" % _wolves.size()
	var scene_path := _main.enemy_scene.resource_path if _main.enemy_scene != null else "null"
	if scene_path != "res://scenes/3d/wolf_3d.tscn":
		return "enemy_scene is %s, expected res://scenes/3d/wolf_3d.tscn" % scene_path
	return ""


func _step_navmesh() -> String:
	if not await _wait_until(func() -> bool: return _main.is_navmesh_ready(), NAVMESH_TIMEOUT_SECONDS):
		return "navmesh did not become ready within %.1f s" % NAVMESH_TIMEOUT_SECONDS
	return ""


## WP7's level checks: spawn, a path across the clearing, prop colliders, the
## rig's camera, plus the coordinator's prop blocker cache.
func _step_level() -> String:
	var spawn_gap := GroundMath.ground_distance(_player.global_position, _spawn.global_position)
	if spawn_gap > SPAWN_TOLERANCE_M:
		return "player is %.2f m from Spawn_default, expected within %.2f m" % [spawn_gap, SPAWN_TOLERANCE_M]

	var nav_map: RID = _main.get_world_3d().navigation_map
	var target := _spawn.global_position + Vector3(PATH_TARGET_DISTANCE_M, 0.0, 0.0)
	var from_point := NavigationServer3D.map_get_closest_point(nav_map, _spawn.global_position)
	var to_point := NavigationServer3D.map_get_closest_point(nav_map, target)
	var path := NavigationServer3D.map_get_path(nav_map, from_point, to_point, true)
	if path.size() < 2:
		return "navmesh path from the spawn has %d point(s), expected at least 2" % path.size()
	var path_length := 0.0
	for i in range(1, path.size()):
		path_length += GroundMath.ground_distance(path[i - 1], path[i])
	if path_length >= PATH_MAX_LENGTH_M:
		return "navmesh path across the clearing is %.2f m, expected under %.2f m" % [path_length, PATH_MAX_LENGTH_M]

	var props := get_tree().get_nodes_in_group("navmesh_source")
	if props.is_empty():
		return "no props in group 'navmesh_source'"
	for prop: Node in props:
		if not (prop is Node3D) or not _main.is_ancestor_of(prop):
			continue
		if not _has_layer_collider(prop, PROP_LAYER):
			return "%s has no StaticBody3D on layer %d" % [prop.name, PROP_LAYER]

	var camera := _camera_rig.get_camera()
	if camera == null or not camera.current:
		return "the CameraRig's camera is not current"

	# The crate at (3, 0, 3) and the chest at (3, 0, -3) must block their
	# cells through the descendant trimesh colliders; the spawn cell must not.
	if not _main.blocked_cells.has(Vector2i(3, 3)):
		return "blocked_cells misses the crate's cell (3, 3); %d cells blocked" % _main.blocked_cells.size()
	if not _main.blocked_cells.has(Vector2i(3, -3)):
		return "blocked_cells misses the chest's cell (3, -3); %d cells blocked" % _main.blocked_cells.size()
	if _main.blocked_cells.has(GroundMath.to_cell(_spawn.global_position)):
		return "blocked_cells marks the spawn cell solid"
	if props.size() != EXPECTED_PROP_COUNT:
		return "%d props in group 'navmesh_source', expected %d" % [props.size(), EXPECTED_PROP_COUNT]
	if _main.blocked_cells.size() != EXPECTED_BLOCKED_CELLS:
		return "%d blocked cells, expected %d" % [_main.blocked_cells.size(), EXPECTED_BLOCKED_CELLS]
	print("[integration] path %.2f m, %d props on layer %d, %d blocked cells" % [path_length, props.size(), PROP_LAYER, _main.blocked_cells.size()])
	return ""


## The imported models: the three soul bodies under Player/Model with only the
## knight's visible (WP9), the active soul's weapon handed to the weapon holder
## and hanging point-down from the right hand; the wolf body under each enemy's
## Model; the overhead anchors at their new heights.
func _step_models() -> String:
	if _player.model == null:
		return "the player has no Model node"
	if _player.model.get_node_or_null("Body") != null:
		return "the placeholder Model/Body capsule is still in the player scene"
	if _player.soul_bodies == null:
		return "Player/Model is not a SoulBodies3D"
	for body_mesh_name in ["Knight_Body", "Rogue_Body", "Mage_Body"]:
		if _player.model.find_child(body_mesh_name, true, false) as MeshInstance3D == null:
			return "no %s mesh under Player/Model" % body_mesh_name
	if _player.get_active_soul().kind != Soul.Kind.KNIGHT:
		return "expected the knight in control at the start, got %s" % _player.get_active_soul().title
	var active_body := _player.soul_bodies.get_active_body()
	if active_body == null or active_body.name != &"Knight" or not active_body.visible:
		return "the visible body is %s, expected the Knight" % (active_body.name if active_body != null else "none")
	var clips := _player.soul_bodies.get_animation_player()
	if clips == null or not clips.has_animation(&"idle") or not clips.has_animation(&"walk"):
		return "the active body has no AnimationPlayer with 'idle' and 'walk' (WP11)"
	var held := _player.soul_bodies.get_held_weapon_mesh()
	if held == null:
		return "the active soul's model has no held weapon mesh"
	if held.visible:
		return "the %s glb's own %s is still visible" % [active_body.name, held.name]
	var weapon := _player.equipped_weapon_mesh
	if weapon == null or weapon.mesh == null:
		return "EquippedWeaponMesh has no mesh"
	if weapon.mesh != held.mesh:
		return "EquippedWeaponMesh does not carry the %s's %s mesh" % [active_body.name, held.name]
	if not weapon.visible:
		return "EquippedWeaponMesh is hidden; is the starter sword equipped?"
	if _player.hand_point == null:
		return "the player has no HandPoint"
	var hand := _player.hand_point.global_position
	var bounds: AABB = weapon.global_transform * weapon.get_aabb()
	if bounds.position.y > hand.y - SWORD_MIN_DROP_M:
		return "the sword does not hang down: lowest point y=%.2f, hand y=%.2f" % [bounds.position.y, hand.y]
	if bounds.end.y > hand.y + SWORD_MAX_RISE_M:
		return "the sword rises above the hand: top y=%.2f, hand y=%.2f" % [bounds.end.y, hand.y]
	var centre := bounds.get_center()
	var lateral := Vector2(centre.x - hand.x, centre.z - hand.z).length()
	if lateral > SWORD_MAX_LATERAL_M:
		return "the sword's centre is %.2f m from the hand on the ground plane" % lateral
	if _player.overhead_anchor == null or absf(_player.overhead_anchor.position.y - PLAYER_ANCHOR_HEIGHT_M) > PLAYER_ANCHOR_TOLERANCE_M:
		return "player OverheadAnchor at y=%.2f, expected %.2f" % [_player.overhead_anchor.position.y if _player.overhead_anchor != null else -1.0, PLAYER_ANCHOR_HEIGHT_M]

	for wolf in _wolves:
		var model := wolf.get_node_or_null("Model") as Node3D
		if model == null:
			return "%s has no Model node" % wolf.name
		if model.find_child("Wolf_Body", true, false) as MeshInstance3D == null:
			return "%s has no Wolf_Body mesh under Model" % wolf.name
		if model.get_node_or_null("MeshInstance3D") != null:
			return "%s still carries the placeholder box under Model" % wolf.name
		var wolf_clips := wolf.get_animation_player()
		if wolf_clips == null or not wolf_clips.has_animation(&"idle") or not wolf_clips.has_animation(&"trot"):
			return "%s has no AnimationPlayer with 'idle' and 'trot' (WP12)" % wolf.name
		if wolf.overhead_anchor == null or not is_equal_approx(wolf.overhead_anchor.position.y, WOLF_ANCHOR_HEIGHT_M):
			return "%s OverheadAnchor at y=%.2f, expected %.2f" % [wolf.name, wolf.overhead_anchor.position.y if wolf.overhead_anchor != null else -1.0, WOLF_ANCHOR_HEIGHT_M]
	print("[integration] sword spans y %.2f..%.2f m from a hand at %.2f m" % [bounds.position.y, bounds.end.y, hand.y])
	return ""


## LevelLoader.apply_spawn with a Node3D spawn and a Node3D player.
func _step_level_loader() -> String:
	_player.snap_to(_spawn.global_position + Vector3(2.0, 0.0, 2.0))
	LevelLoader.pending_spawn_name = &"default"
	LevelLoader.apply_spawn(_main)
	if LevelLoader.pending_spawn_name != &"":
		return "apply_spawn left pending_spawn_name set"
	var gap := GroundMath.ground_distance(_player.global_position, _spawn.global_position)
	if gap > 0.05:
		return "apply_spawn left the player %.2f m from Spawn_default" % gap
	return ""


## A ground request (what a ground click resolves to) moves the player.
func _step_click_to_move() -> String:
	var start := _player.global_position
	_main._request_player_move(start + Vector3(EXPLORATION_STEP_M, 0.0, 0.0))
	if not _player.is_moving():
		return "the player did not start moving after _request_player_move"
	# WP11: the body plays its walk clip on the way.
	var walk_seen: Array[bool] = [false]
	var arrived := func() -> bool:
		if _player.get_locomotion_state() == &"walk":
			walk_seen[0] = true
		return not _player.is_moving()
	if not await _wait_until(arrived, MOVE_TIMEOUT_SECONDS):
		return "the player is still moving after %.1f s" % MOVE_TIMEOUT_SECONDS
	var moved := GroundMath.ground_distance(start, _player.global_position)
	if moved < EXPLORATION_STEP_M - 0.6:
		return "the player moved %.2f m toward a point %.1f m away" % [moved, EXPLORATION_STEP_M]
	if not walk_seen[0]:
		return "the player moved %.2f m without the walk clip playing" % moved
	await get_tree().physics_frame
	await get_tree().physics_frame
	if _player.get_locomotion_state() != &"idle":
		return "the body plays '%s' after the move, expected 'idle'" % _player.get_locomotion_state()
	if _main.combat_state != Main3D.CombatState.EXPLORATION:
		return "combat started during the exploration move (state %d)" % _main.combat_state
	return ""


## Walking toward the first wolf starts turn combat when the Manhattan cell
## distance drops to COMBAT_TRIGGER_DISTANCE_CELLS; the other two wolves are
## parked beyond the engagement radius first.
func _step_combat_start() -> String:
	_wolves[1].snap_to(PARK_B)
	_wolves[2].snap_to(PARK_C)
	var wolf := _wolves[0]
	_main._request_player_move(wolf.global_position)
	if not await _wait_until(func() -> bool: return _main.combat_state == Main3D.CombatState.PLAYER_TURN, COMBAT_TIMEOUT_SECONDS):
		return "combat did not start within %.1f s (state %d)" % [COMBAT_TIMEOUT_SECONDS, _main.combat_state]
	var budget := _player.get_turn_remaining_move_meters()
	if absf(budget - Main3D.TURN_MOVE_METERS) > 0.001:
		return "turn budget is %.2f m, expected %.2f m" % [budget, Main3D.TURN_MOVE_METERS]
	if _main.engaged_enemies.size() != 1:
		return "%d wolves engaged, expected only the first (the others are parked %.0f m away)" % [_main.engaged_enemies.size(), GroundMath.ground_distance(_player.global_position, PARK_B)]
	var cells := GroundMath.manhattan(GroundMath.to_cell(_player.global_position), GroundMath.to_cell(wolf.global_position))
	if cells > Main3D.COMBAT_TRIGGER_DISTANCE_CELLS:
		return "combat started at %d cells, beyond the %d cell trigger" % [cells, Main3D.COMBAT_TRIGGER_DISTANCE_CELLS]
	print("[integration] combat started at %d cells from %s" % [cells, wolf.name])
	return ""


## A 10 m turn move is trimmed to the 6 m budget.
func _step_budget_trim() -> String:
	var start := _player.global_position
	_main._request_player_turn_move(start + Vector3(0.0, 0.0, -TRIM_REQUEST_M))
	var remaining := _player.get_turn_remaining_move_meters()
	if remaining > 0.01:
		return "a %.0f m request left %.2f m of budget, expected the whole %.1f m spent" % [TRIM_REQUEST_M, remaining, Main3D.TURN_MOVE_METERS]
	if not _player.is_moving():
		return "the trimmed move did not start"
	if not await _wait_until(func() -> bool: return not _player.is_moving(), MOVE_TIMEOUT_SECONDS):
		return "the player is still moving after %.1f s" % MOVE_TIMEOUT_SECONDS
	var travelled := GroundMath.ground_distance(start, _player.global_position)
	if travelled > Main3D.TURN_MOVE_METERS + 0.5:
		return "the player walked %.2f m on a %.1f m budget" % [travelled, Main3D.TURN_MOVE_METERS]
	if travelled < Main3D.TURN_MOVE_METERS - 1.0:
		return "the player walked only %.2f m of the %.1f m budget" % [travelled, Main3D.TURN_MOVE_METERS]
	print("[integration] %.0f m request trimmed: walked %.2f m" % [TRIM_REQUEST_M, travelled])
	return ""


## Melee as the knight: the wolf loses the weapon damage after the contact
## delay and the turn's attack is spent.
func _step_melee() -> String:
	var wolf := _wolves[0]
	_player.snap_to(wolf.global_position + Vector3(MELEE_SNAP_M, 0.0, 0.0))
	await _pause(0.1)
	if _player.get_active_soul().kind != Soul.Kind.KNIGHT:
		return "expected the knight in control, got %s" % _player.get_active_soul().title
	var before := wolf.health
	var expected := _player.get_melee_damage()
	var start_msec := Time.get_ticks_msec()
	_watch_health(wolf, before)
	await _main._request_player_turn_attack(wolf)
	await _let_watcher_catch_up()
	if wolf.health != before - expected:
		return "wolf health %d -> %d, expected a drop of %d" % [before, wolf.health, expected]
	if _hit_msec < 0:
		return "the watcher never saw the hit land"
	var contact_ms := _hit_msec - start_msec
	var delay_ms := int(round(_player.melee_hit_delay * 1000.0))
	if contact_ms < delay_ms - TIMING_TOLERANCE_MS:
		return "damage landed %d ms after the swing, before the %d ms contact delay" % [contact_ms, delay_ms]
	if _player.can_turn_attack():
		return "can_turn_attack() still true after the swing"
	print("[integration] melee %d damage, contact after %d ms (delay %d ms)" % [expected, contact_ms, delay_ms])
	return ""


## End Turn: the wolf's turn attack shows the counter prompt; a perfect press
## in the strike window makes the knight block the whole hit. Control comes
## back after the pacing constants and the perfect reaction earns Resonance.
func _step_counter_block() -> String:
	var wolf := _wolves[0]
	var health_before := _player.health
	_press_wolf = wolf
	_press_done = false
	_prompt_seen = false
	_press_armed = true
	var started_msec := Time.get_ticks_msec()
	_main._request_end_player_turn()
	if _main.combat_state != Main3D.CombatState.ENEMY_TURN:
		_press_armed = false
		return "End Turn did not hand over to the enemy (state %d)" % _main.combat_state
	var handed_back := await _wait_until(func() -> bool: return _main.combat_state == Main3D.CombatState.PLAYER_TURN, ENEMY_TURN_TIMEOUT_SECONDS)
	_press_armed = false
	if not handed_back:
		return "the enemy turn did not hand back within %.1f s (state %d)" % [ENEMY_TURN_TIMEOUT_SECONDS, _main.combat_state]
	var elapsed := float(Time.get_ticks_msec() - started_msec) / 1000.0
	var min_expected := Main3D.ENEMY_TURN_DELAY_SECONDS + Main3D.ENEMY_TURN_HANDBACK_SECONDS \
		+ wolf.turn_attack_wind_up_duration + wolf.turn_attack_strike_duration + wolf.attack_recovery_duration
	if elapsed < min_expected - PACING_TOLERANCE_SECONDS:
		return "control came back after %.2f s, before the %.2f s of delay, swing and handback" % [elapsed, min_expected]
	if not _prompt_seen:
		return "the counter prompt never showed during the wolf's turn attack"
	if not wolf.has_shown_counter_prompt():
		return "the wolf reports it never showed its counter prompt"
	if not _press_done:
		return "the strike window never opened, so no press was simulated"
	if _player.health != health_before:
		return "the knight block did not negate the bite: health %d -> %d" % [health_before, _player.health]
	var expected_shifts := Player3D.SHIFTS_PER_TURN + (1 if Player3D.PERFECT_REACTION_GRANTS_EXTRA_SHIFT else 0)
	if _player.get_shifts_left() != expected_shifts:
		return "%d shifts after the perfect block, expected %d (Resonance)" % [_player.get_shifts_left(), expected_shifts]
	print("[integration] enemy turn %.2f s (at least %.2f s), block negated the bite, %d shifts" % [elapsed, min_expected, expected_shifts])
	return ""


## Shifts are limited per turn: every shift the turn grants succeeds, the next
## one is refused and the body stays with the last soul (the rogue, for the
## throw that follows).
func _step_shift_once() -> String:
	var shifts := _player.get_shifts_left()
	if shifts < 1 or shifts > 2:
		return "%d shifts available at the start of the turn, expected 1 or 2" % shifts
	var order: Array[Soul.Kind] = []
	if shifts == 2:
		order.append(Soul.Kind.MAGE)
	order.append(Soul.Kind.ROGUE)
	for kind in order:
		_main._request_shift(int(kind))
		if _player.get_active_soul().kind != kind:
			return "shift to %s was refused with %d shift(s) left" % [Soul.kind_title(kind), _player.get_shifts_left()]
	if _player.get_shifts_left() != 0:
		return "%d shifts left after spending %d" % [_player.get_shifts_left(), order.size()]
	_main._request_shift(int(Soul.Kind.KNIGHT))
	if _player.get_active_soul().kind != Soul.Kind.ROGUE:
		return "a shift beyond the turn's allowance changed the soul to %s" % _player.get_active_soul().title
	if _player.can_shift():
		return "can_shift() still true with no shift left"
	return ""


## The rogue's throw with its dashed range ring; the wolf is given loot first
## because the throw may finish it.
func _step_throw() -> String:
	var wolf := _wolves[0]
	var drops: Array[Item] = [ItemFactory.create_sword()]
	wolf.loot_items = drops
	wolf.loot_drop_chance = 1.0
	_death_position = wolf.global_position
	_main._set_player_turn_action(Main3D.PlayerTurnAction.RANGED)
	_main._update_range_rings()
	if not _main.ranged_range_ring.visible:
		return "the throw range ring is not visible while aiming"
	if _main.melee_range_ring.visible:
		return "the melee ring is visible while aiming the throw"
	var before := wolf.health
	await _main._request_player_turn_ranged_attack(wolf)
	var expected := maxi(0, before - Soul.ROGUE_RANGED_DAMAGE)
	if wolf.health != expected:
		return "wolf health %d -> %d after the throw, expected %d" % [before, wolf.health, expected]
	if _player.can_turn_attack():
		return "can_turn_attack() still true after the throw"
	print("[integration] throw: wolf %d -> %d" % [before, wolf.health])
	return ""


## The wolf dies and its loot lands on the arena root beside the corpse; the
## fight ends with it.
func _step_loot_drop() -> String:
	var wolf := _wolves[0]
	if is_instance_valid(wolf) and wolf.is_alive():
		# The throw left it standing; finish it so the drop can be tested.
		wolf.receive_damage(1000)
	if not await _wait_until(func() -> bool: return _find_pickup_near(_death_position) != null, LOOT_TIMEOUT_SECONDS):
		return "no ItemPickup3D within %.1f m of the death position %s after %.1f s" % [LOOT_RADIUS_M, str(_death_position), LOOT_TIMEOUT_SECONDS]
	_loot_pickup = _find_pickup_near(_death_position)
	var item := _loot_pickup.get_item()
	if item == null or item.id != &"iron_sword":
		return "the dropped item is %s, expected iron_sword" % (item.id if item != null else "null")
	if not await _wait_until(func() -> bool: return _main.combat_state == Main3D.CombatState.EXPLORATION, LOOT_TIMEOUT_SECONDS):
		return "combat did not end after the last engaged wolf died (state %d)" % _main.combat_state
	return ""


## The second wolf closes in and restarts combat; the mage casts Arcane Burst
## (range ring plus blast ring on the hovered wolf), the wolf takes its turn,
## then Frost Snare damages, roots and starts its cooldown.
func _step_spells() -> String:
	var wolf := _wolves[1]
	wolf.snap_to(_player.global_position + Vector3(SPELL_WOLF_DISTANCE_M, 0.0, 0.0))
	if not await _wait_until(func() -> bool: return _main.combat_state == Main3D.CombatState.PLAYER_TURN, COMBAT_TIMEOUT_SECONDS):
		return "combat did not restart with a wolf %.1f m away (state %d)" % [SPELL_WOLF_DISTANCE_M, _main.combat_state]
	if not _main.engaged_enemies.has(wolf.get_instance_id()):
		return "the wolf that restarted combat is not engaged"
	_main._request_shift(int(Soul.Kind.MAGE))
	if _player.get_active_soul().kind != Soul.Kind.MAGE:
		return "could not shift to the mage on a fresh turn"

	_main._on_turn_spell_button_pressed(Soul.SPELL_ARCANE_BURST)
	if _main.selected_player_turn_action != Main3D.PlayerTurnAction.SPELL or _main.selected_spell_id != Soul.SPELL_ARCANE_BURST:
		return "the Arcane Burst button did not arm the spell"
	_main._set_hovered_enemy(wolf)
	_main._update_range_rings()
	if not _main.ranged_range_ring.visible:
		return "the Arcane Burst range ring is not visible"
	if not _main.spell_area_ring.visible:
		return "the Arcane Burst blast ring is not visible on the hovered wolf"
	var before := wolf.health
	await _main._request_player_turn_spell(wolf)
	if wolf.health != before - Soul.ARCANE_BURST_DAMAGE:
		return "wolf health %d -> %d after Arcane Burst, expected a drop of %d" % [before, wolf.health, Soul.ARCANE_BURST_DAMAGE]

	var started_msec := Time.get_ticks_msec()
	_main._request_end_player_turn()
	if _main.combat_state != Main3D.CombatState.ENEMY_TURN:
		return "End Turn did not hand over to the enemy (state %d)" % _main.combat_state
	if not await _wait_until(func() -> bool: return _main.combat_state == Main3D.CombatState.PLAYER_TURN, ENEMY_TURN_TIMEOUT_SECONDS):
		return "the second enemy turn did not hand back within %.1f s (state %d)" % [ENEMY_TURN_TIMEOUT_SECONDS, _main.combat_state]
	var elapsed := float(Time.get_ticks_msec() - started_msec) / 1000.0
	var min_expected := Main3D.ENEMY_TURN_DELAY_SECONDS + Main3D.ENEMY_TURN_HANDBACK_SECONDS
	if elapsed < min_expected - PACING_TOLERANCE_SECONDS:
		return "control came back after %.2f s, before the %.2f s of delay and handback" % [elapsed, min_expected]

	_main._on_turn_spell_button_pressed(Soul.SPELL_FROST_SNARE)
	if _main.selected_spell_id != Soul.SPELL_FROST_SNARE:
		return "the Frost Snare button did not arm the spell"
	_main._update_range_rings()
	if not _main.ranged_range_ring.visible:
		return "the Frost Snare range ring is not visible"
	before = wolf.health
	await _main._request_player_turn_spell(wolf)
	if wolf.health != before - Soul.FROST_SNARE_DAMAGE:
		return "wolf health %d -> %d after Frost Snare, expected a drop of %d" % [before, wolf.health, Soul.FROST_SNARE_DAMAGE]
	if not wolf.is_rooted():
		return "the Frost Snare target is not rooted"
	if _player.get_spell_cooldown(Soul.SPELL_FROST_SNARE) != Soul.FROST_SNARE_COOLDOWN_TURNS:
		return "Frost Snare cooldown %d, expected %d" % [_player.get_spell_cooldown(Soul.SPELL_FROST_SNARE), Soul.FROST_SNARE_COOLDOWN_TURNS]
	print("[integration] second enemy turn %.2f s; burst and snare landed, wolf rooted" % elapsed)
	return ""


## The coordinator's pickup click: a screen point over the dropped sword goes
## through WorldPicker.pick_pickup and LootMenu.request_loot; the item is
## taken into the inventory.
func _step_loot_pickup() -> String:
	if _loot_pickup == null or not is_instance_valid(_loot_pickup):
		return "the dropped pickup is gone"
	_player.snap_to(_loot_pickup.global_position + Vector3(LOOT_STAND_OFF_M, 0.0, 0.0))
	_camera_rig.snap_to_target()
	await get_tree().process_frame
	await get_tree().process_frame
	var camera := _camera_rig.get_camera()
	var screen := WorldPicker.world_to_screen(camera, _loot_pickup.global_position + Vector3(0.0, ItemPickup3D.ICON_REST_HEIGHT_M, 0.0))
	var picked := WorldPicker.pick_pickup(camera, screen)
	if picked != _loot_pickup:
		return "pick_pickup at the pickup's screen point %s returned %s" % [screen, picked.name if picked != null else "null"]
	if not _main._try_click_pickup(screen):
		return "_try_click_pickup returned false at the pickup's screen point"
	if not LootMenu.is_open():
		return "LootMenu did not open for a pickup %.1f m away" % LOOT_STAND_OFF_M
	var item := _loot_pickup.get_item()
	if not _loot_pickup.take(_player.inventory):
		return "pickup.take(inventory) refused"
	if not _player.get_inventory_items().has(item):
		return "the inventory does not hold the taken %s" % item.id
	LootMenu.close()
	if LootMenu.is_open():
		return "LootMenu is still open after close()"
	return ""


func _step_inventory() -> String:
	InventoryScreen.toggle()
	if not InventoryScreen.is_open():
		return "InventoryScreen.toggle() did not open the screen"
	await get_tree().process_frame
	InventoryScreen.toggle()
	if InventoryScreen.is_open():
		return "InventoryScreen.toggle() did not close the screen"
	return ""


## The prologue opens (pausing the tree) and Esc closes it; a second
## show_chapter_once is a no-op.
func _step_story_book() -> String:
	var chapter := StoryLibrary.chapter(StoryLibrary.PROLOGUE)
	if chapter == null:
		return "StoryLibrary has no prologue"
	StoryBook.show_chapter_once(chapter)
	if not StoryBook.is_open():
		return "show_chapter_once did not open the book"
	if not get_tree().paused:
		return "the open book did not pause the tree"
	await _pause(0.1)
	var cancel := InputEventAction.new()
	cancel.action = "ui_cancel"
	cancel.pressed = true
	Input.parse_input_event(cancel)
	await get_tree().process_frame
	await get_tree().process_frame
	if StoryBook.is_open():
		return "ui_cancel did not close the book"
	if get_tree().paused:
		return "the tree is still paused after the book closed"
	StoryBook.show_chapter_once(chapter)
	if StoryBook.is_open():
		return "show_chapter_once reopened a chapter already read this session"
	return ""


# --- Helpers ---------------------------------------------------------------------

func _pause(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


## Polls `condition` once per frame until it holds or `timeout_seconds` pass.
func _wait_until(condition: Callable, timeout_seconds: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if bool(condition.call()):
			return true
		await get_tree().process_frame
	return bool(condition.call())


## Records the moment `target` first loses health, from the next frame on.
## Started without `await` so it runs beside the attack it watches.
func _watch_health(target: Enemy3D, before: int) -> void:
	_watch_id += 1
	var my_id := _watch_id
	_hit_msec = -1
	while is_instance_valid(target) and target.health == before:
		await get_tree().process_frame
	if my_id == _watch_id:
		_hit_msec = Time.get_ticks_msec()


func _let_watcher_catch_up() -> void:
	for _i in range(3):
		if _hit_msec >= 0:
			return
		await get_tree().process_frame


func _find_pickup_near(world_position: Vector3) -> ItemPickup3D:
	for child in _main.get_children():
		var pickup := child as ItemPickup3D
		if pickup == null or not pickup.is_available():
			continue
		if GroundMath.ground_distance(pickup.global_position, world_position) <= LOOT_RADIUS_M:
			return pickup
	return null


func _has_layer_collider(node: Node, layer_bit: int) -> bool:
	if node is StaticBody3D and ((node as StaticBody3D).collision_layer & layer_bit) != 0:
		return true
	for child in node.get_children():
		if _has_layer_collider(child, layer_bit):
			return true
	return false
