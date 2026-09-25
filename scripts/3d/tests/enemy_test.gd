extends Node3D

## WP3c test: the ported `Enemy3D` (as `wolf_3d.tscn`) against the WP0 stub player
## on the arena skeleton's layout, with a runtime navmesh bake.
##
## Five scripted steps, in order: the aggro gate holds the wolf still at 8 m; at
## 3 m it chases, reaches its attack range and bites through the player's
## `resolve_enemy_attack` while the counter prompt is up; in turn mode the swing
## lands after `turn_attack_wind_up_duration + turn_attack_strike_duration` and
## spends the turn's attack; a root costs the next turn's movement and melts on
## `end_turn`; and death pays out XP and loot before the body disappears.
##
## Prints the first failing check with its values, or `ENEMY OK`.
##
##   godot --headless --path . res://scenes/3d/tests/enemy_test.tscn --quit-after 900

const StubPlayer3D = preload("res://scripts/3d/stubs/stub_player_3d.gd")

## 1) Held outside aggro range.
const IDLE_SECONDS := 1.0
const IDLE_TOLERANCE_M := 0.1
## 2) Chase and bite.
const PLAYER_NEAR_POSITION := Vector3(3.0, 0.0, 0.0)
const CLOSE_IN_SECONDS := 2.0
const REACH_MARGIN_M := 0.3
const HIT_SECONDS := 1.5
## 3) The turn-mode swing. Generous enough for the physics-frame granularity of
## the watcher, tight enough to tell the turn timing from the realtime one.
const TURN_HIT_TOLERANCE := 0.25
const SETTLE_SECONDS := 2.0
## 5) Death.
const DEATH_WAIT_SECONDS := 0.7
const LOOT_RADIUS_M := 1.0

const NAV_MAP_FRAMES := 60
const NAV_MAP_TOLERANCE_M := 0.5

const CAMERA_SIZE_M := 24.0
const CAMERA_YAW_DEG := 45.0
const CAMERA_PITCH_DEG := -35.0
const CAMERA_DISTANCE := 30.0

@onready var camera: Camera3D = $Camera3D
@onready var sun: DirectionalLight3D = $Sun
@onready var nav_region: NavigationRegion3D = $NavigationRegion3D
@onready var wolf: Enemy3D = $Wolf
@onready var player: StubPlayer3D = $Player

var _finished := false
## Records the moment the player's health first drops below the armed baseline,
## so the turn-mode contact delay can be measured while `try_attack` is awaited.
var _watch_active := false
var _watch_baseline := 0
var _watch_hit_msec := -1
## Measurements, printed on success so a passing run still shows its work.
var _closed_in_to := 0.0
var _realtime_damage := 0
var _turn_hit_delay := 0.0
var _turn_hit_expected := 0.0


func _ready() -> void:
	# Headless runs the main loop as fast as it can, which starves the physics
	# steps and timers this test counts on.
	Engine.max_fps = 60
	_setup_camera()
	sun.rotation_degrees = Vector3(-55.0, 30.0, 0.0)

	var items: Array[Item] = [ItemFactory.create_sword()]
	wolf.loot_items = items
	wolf.loot_drop_chance = 1.0

	nav_region.bake_finished.connect(_on_bake_finished)
	nav_region.bake_navigation_mesh()


func _setup_camera() -> void:
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = CAMERA_SIZE_M
	camera.near = 0.1
	camera.far = 200.0
	camera.current = true
	var back := Vector3(0.0, 0.0, CAMERA_DISTANCE)
	back = back.rotated(Vector3.RIGHT, deg_to_rad(CAMERA_PITCH_DEG))
	back = back.rotated(Vector3.UP, deg_to_rad(CAMERA_YAW_DEG))
	camera.global_position = back
	camera.look_at(Vector3.ZERO, Vector3.UP)


func _physics_process(_delta: float) -> void:
	if _watch_active and player.health < _watch_baseline:
		_watch_hit_msec = Time.get_ticks_msec()
		_watch_active = false


func _on_bake_finished() -> void:
	await _wait_for_navigation_map()
	_run_test()


## WP3a: the baked mesh only reaches the navigation map on a later server sync,
## and until it does every map query answers with the origin.
func _wait_for_navigation_map() -> void:
	var map := get_world_3d().navigation_map
	for _i in range(NAV_MAP_FRAMES):
		await get_tree().physics_frame
		var closest := NavigationServer3D.map_get_closest_point(map, PLAYER_NEAR_POSITION)
		if GroundMath.ground_distance(closest, PLAYER_NEAR_POSITION) < NAV_MAP_TOLERANCE_M:
			return
	push_error("[enemy_test] the navigation map never picked up the baked mesh")


func _run_test() -> void:
	# The stub player scales incoming damage by the active soul's defence. The
	# rogue's multiplier is 1.00, so what lands is exactly `attack_damage`.
	if not player.shift_to(int(Soul.Kind.ROGUE)):
		_fail("could not put the stub player in the rogue soul")
		return

	if not await _step_aggro_gate():
		return
	if not await _step_chase_and_bite():
		return
	if not await _step_turn_attack():
		return
	if not _step_root():
		return
	if not await _step_death():
		return

	print("[enemy_test] closed to %.2f m, realtime bite %d, turn hit after %.2f s (expected %.2f s)"
		% [_closed_in_to, _realtime_damage, _turn_hit_delay, _turn_hit_expected])
	print("ENEMY OK")
	_finished = true
	get_tree().quit()


# --- 1) The aggro gate ---------------------------------------------------------------

func _step_aggro_gate() -> bool:
	wolf.set_target(player)
	var start_position := wolf.global_position
	var start_distance := GroundMath.ground_distance(start_position, player.global_position)
	if start_distance <= wolf.aggro_range:
		_fail("the player starts %.2f m away, inside the wolf's %.2f m aggro range"
			% [start_distance, wolf.aggro_range])
		return false

	await _wait(IDLE_SECONDS)
	var drift := GroundMath.ground_distance(wolf.global_position, start_position)
	if drift > IDLE_TOLERANCE_M:
		_fail("the wolf moved %.2f m in %.1f s with the player %.2f m away, outside its %.2f m aggro range"
			% [drift, IDLE_SECONDS, start_distance, wolf.aggro_range])
		return false
	return true


# --- 2) Chase and bite ----------------------------------------------------------------

func _step_chase_and_bite() -> bool:
	player.snap_to(PLAYER_NEAR_POSITION)
	var reach := wolf.attack_range + REACH_MARGIN_M
	var closed_in := await _wait_until(func() -> bool:
		return GroundMath.ground_distance(wolf.global_position, player.global_position) <= reach,
		CLOSE_IN_SECONDS)
	if not closed_in:
		_fail("after %.1f s the wolf is %.2f m from the player, not inside %.2f m"
			% [CLOSE_IN_SECONDS,
				GroundMath.ground_distance(wolf.global_position, player.global_position), reach])
		return false

	_arm_hit_watch()
	var health_before := player.health
	var hit := await _wait_until(func() -> bool: return player.health < health_before, HIT_SECONDS)
	if not hit:
		_fail("the player's health stayed at %d for %.1f s after the wolf came within %.2f m"
			% [health_before, HIT_SECONDS,
				GroundMath.ground_distance(wolf.global_position, player.global_position)])
		return false

	_closed_in_to = GroundMath.ground_distance(wolf.global_position, player.global_position)
	var dealt := health_before - player.health
	_realtime_damage = dealt
	if dealt != wolf.attack_damage:
		_fail("the realtime bite took %d health, expected the wolf's attack_damage of %d"
			% [dealt, wolf.attack_damage])
		return false
	if not wolf.has_shown_counter_prompt():
		_fail("the wolf resolved a hit without ever showing its counter prompt")
		return false
	return true


# --- 3) The turn-mode swing -------------------------------------------------------------

func _step_turn_attack() -> bool:
	# Let the realtime swing finish its recovery before the mode flips.
	var settled := await _wait_until(func() -> bool: return not wolf.is_attacking(), SETTLE_SECONDS)
	if not settled:
		_fail("the realtime attack sequence never finished within %.1f s" % SETTLE_SECONDS)
		return false

	wolf.set_turn_based_combat(true)
	player.set_turn_based_combat(true)
	wolf.start_turn(6.0)

	_arm_hit_watch()
	var started_msec := Time.get_ticks_msec()
	var started: bool = await wolf.try_attack(player)
	if not started:
		_fail("try_attack(player) returned false at %.2f m with %.1f m of attack range"
			% [GroundMath.ground_distance(wolf.global_position, player.global_position),
				wolf.attack_range])
		return false
	if _watch_hit_msec < 0:
		_fail("the turn-mode swing finished without the player taking damage")
		return false

	var expected := wolf.turn_attack_wind_up_duration + wolf.turn_attack_strike_duration
	var delay := float(_watch_hit_msec - started_msec) / 1000.0
	_turn_hit_expected = expected
	_turn_hit_delay = delay
	if absf(delay - expected) > TURN_HIT_TOLERANCE:
		_fail("the turn-mode hit landed after %.2f s, expected %.2f s (wind-up %.2f + strike %.2f)"
			% [delay, expected, wolf.turn_attack_wind_up_duration, wolf.turn_attack_strike_duration])
		return false
	if wolf.can_turn_attack():
		_fail("can_turn_attack() is still true after the wolf spent its turn attack")
		return false

	wolf.end_turn()
	return true


# --- 4) The root ---------------------------------------------------------------------------

func _step_root() -> bool:
	wolf.apply_root(1)
	wolf.start_turn(6.0)
	if wolf.get_turn_remaining_move_meters() != 0.0:
		_fail("a rooted wolf started its turn with %.2f m of movement, expected 0"
			% wolf.get_turn_remaining_move_meters())
		return false
	if not wolf.is_rooted():
		_fail("is_rooted() is false during the turn the root costs")
		return false

	wolf.end_turn()
	if wolf.is_rooted():
		_fail("is_rooted() is still true after the turn that spent the root ended")
		return false
	return true


# --- 5) Death, XP and loot --------------------------------------------------------------------

func _step_death() -> bool:
	var death_position := wolf.global_position
	var reward := wolf.experience_reward
	var xp_before := player.get_experience_toward_next()
	var level_before := player.get_player_level()

	wolf.receive_damage(1000)
	if wolf.is_alive():
		_fail("is_alive() is still true on the frame a lethal hit landed")
		return false

	await _wait(DEATH_WAIT_SECONDS)
	if is_instance_valid(wolf):
		_fail("the wolf node is still in the tree %.1f s after dying" % DEATH_WAIT_SECONDS)
		return false

	var xp_gained := player.get_experience_toward_next() - xp_before
	var levels_gained := player.get_player_level() - level_before
	if levels_gained == 0 and absf(xp_gained - float(reward)) > 0.01:
		_fail("the player gained %.1f XP and %d levels, expected the wolf's %d XP reward"
			% [xp_gained, levels_gained, reward])
		return false

	var pickups := _pickups_near(death_position)
	if pickups != 1:
		_fail("found %d ItemPickup3D nodes within %.1f m of the death position %s, expected 1"
			% [pickups, LOOT_RADIUS_M, str(death_position)])
		return false
	return true


func _pickups_near(world_position: Vector3) -> int:
	var found := 0
	for child in get_children():
		if not (child is ItemPickup3D):
			continue
		var pickup := child as ItemPickup3D
		if GroundMath.ground_distance(pickup.global_position, world_position) <= LOOT_RADIUS_M:
			found += 1
	return found


# --- Helpers -------------------------------------------------------------------------------------

func _arm_hit_watch() -> void:
	_watch_baseline = player.health
	_watch_hit_msec = -1
	_watch_active = true


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


## Polls `predicate` once per physics frame until it holds or `timeout` passes.
func _wait_until(predicate: Callable, timeout: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if bool(predicate.call()):
			return true
		await get_tree().physics_frame
	return bool(predicate.call())


func _fail(message: String) -> void:
	if _finished:
		return
	print("ENEMY FAIL: %s" % message)
	_finished = true
	get_tree().quit()
