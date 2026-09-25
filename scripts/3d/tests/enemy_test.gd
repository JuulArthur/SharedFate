extends Node3D

## WP3c test: the ported `Enemy3D` (as `wolf_3d.tscn`) against the WP0 stub player
## on the arena skeleton's layout, with a runtime navmesh bake.
##
## Scripted steps, in order: the wolf's rig carries looping `idle` and `trot`
## (WP12); the aggro gate holds the wolf still at 8 m; at 3 m it chases on the
## trot, reaches its attack range, idles and bites through the player's
## `resolve_enemy_attack` while the counter prompt is up; a long straight chase
## keeps the planted front paw from sliding (WP12); in turn mode the swing
## lands after `turn_attack_wind_up_duration + turn_attack_strike_duration` and
## spends the turn's attack; a root costs the next turn's movement and melts on
## `end_turn`; and death stops the clip, pays out XP and loot before the body
## disappears.
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
## Checked this long into the 0.42 s topple.
const DEATH_CLIP_CHECK_SECONDS := 0.2

## WP12: the rig and the foot-slide chase. The player steps 11 m away along -X,
## the open side of the test floor; the samples start once the trot has
## blended in and stop before the wolf slows for its approach.
const WOLF_BONES: Array[StringName] = [&"Hips", &"Spine", &"Neck", &"Head", &"Tail",
	&"FrontLeg_L", &"FrontLeg_R", &"HindLeg_L", &"HindLeg_R"]
const FOOT_BONE := &"FrontLeg_L"
const FOOT_SLIDE_PLAYER_POSITION := Vector3(-10.0, 0.0, 0.0)
const FOOT_SLIDE_WARMUP_SECONDS := 0.4
const FOOT_SLIDE_SAMPLE_SECONDS := 1.2
const FOOT_SLIDE_STOP_DISTANCE_M := 3.5
const FOOT_SLIDE_MIN_TRAVEL_M := 2.5
const FOOT_SLIDE_MIN_LIFT_M := 0.03
## The planted paw may drift at most this share of the body's travel per cycle.
const FOOT_SLIDE_MAX_SHARE := 0.2
const FOOT_SLIDE_ARRIVE_SECONDS := 5.0

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
var _foot_report := ""


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

	if not _step_rig():
		return
	if not await _step_aggro_gate():
		return
	if not await _step_chase_and_bite():
		return
	if not await _step_foot_slide():
		return
	if not await _step_turn_attack():
		return
	if not _step_root():
		return
	if not await _step_death():
		return

	print("[enemy_test] closed to %.2f m, realtime bite %d, turn hit after %.2f s (expected %.2f s)"
		% [_closed_in_to, _realtime_damage, _turn_hit_delay, _turn_hit_expected])
	print("[enemy_test] %s" % _foot_report)
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
	# WP12: the model trots while it chases.
	var trot_seen: Array[bool] = [false]
	var closed_in := await _wait_until(func() -> bool:
		if wolf.is_moving() and wolf.get_locomotion_state() == &"trot":
			trot_seen[0] = true
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
	if not trot_seen[0]:
		_fail("the wolf chased %.1f m without its trot clip playing"
			% GroundMath.ground_distance(Vector3.ZERO, wolf.global_position))
		return false
	return _expect_idle_in_reach("after the first bite")


## The wolf stands in reach and its model plays `idle` (WP12).
func _expect_idle_in_reach(when: String) -> bool:
	var distance := GroundMath.ground_distance(wolf.global_position, player.global_position)
	if distance > wolf.attack_range + ActorBase3D.ATTACK_RANGE_TOLERANCE:
		_fail("%s the wolf is %.2f m from the player, outside its %.2f m reach" % [when, distance, wolf.attack_range])
		return false
	var anim := wolf.get_animation_player()
	if wolf.get_locomotion_state() != &"idle" or StringName(anim.current_animation) != &"idle":
		_fail("%s the wolf holds position in reach but plays '%s' (state '%s'), expected 'idle'"
			% [when, anim.current_animation, wolf.get_locomotion_state()])
		return false
	return true


# --- 0) The rig (WP12) ---------------------------------------------------------------

func _step_rig() -> bool:
	var anim := wolf.get_animation_player()
	if anim == null:
		_fail("the wolf's Model has no AnimationPlayer")
		return false
	for clip in [&"idle", &"trot"]:
		if not anim.has_animation(clip):
			_fail("the wolf's AnimationPlayer has no '%s' clip (has %s)" % [clip, str(anim.get_animation_list())])
			return false
		if anim.get_animation(clip).loop_mode == Animation.LOOP_NONE:
			_fail("the wolf's '%s' clip does not loop" % clip)
			return false
	var skeleton := _wolf_skeleton()
	if skeleton == null:
		_fail("the wolf's Model has no Skeleton3D")
		return false
	for bone in WOLF_BONES:
		if skeleton.find_bone(bone) < 0:
			_fail("the wolf's skeleton has no bone %s" % bone)
			return false
	return true


func _wolf_skeleton() -> Skeleton3D:
	var model := wolf.get_node_or_null("Model")
	if model == null:
		return null
	var found := model.find_children("*", "Skeleton3D", true, false)
	return found[0] as Skeleton3D if not found.is_empty() else null


# --- 2b) Foot slide on a straight chase (WP12) ------------------------------------------

## The player steps far away along -X and the wolf trots after it in a straight
## line at its full 3.6 m/s. Every physics frame the front-left paw (the tail
## of the FrontLeg_L bone, i.e. the sole) and the body are sampled. While the
## paw is in the lowest third of its height range it is planted, and whatever
## it moves over the ground then is slide. The slide per cycle must stay under
## 20 percent of the body's travel per cycle.
func _step_foot_slide() -> bool:
	var settled := await _wait_until(func() -> bool: return not wolf.is_attacking(), SETTLE_SECONDS)
	if not settled:
		_fail("the realtime attack sequence never finished within %.1f s" % SETTLE_SECONDS)
		return false
	var skeleton := _wolf_skeleton()
	var bone := skeleton.find_bone(FOOT_BONE)
	# The paw in the bone's own frame: at rest it stands on the ground right
	# below the shoulder, whatever axes the importer gave the bone.
	var rest_world := skeleton.global_transform * skeleton.get_bone_global_rest(bone)
	var paw_rest := Vector3(rest_world.origin.x, wolf.global_position.y, rest_world.origin.z)
	var paw_local := rest_world.affine_inverse() * paw_rest

	player.snap_to(FOOT_SLIDE_PLAYER_POSITION)
	await _wait(FOOT_SLIDE_WARMUP_SECONDS)
	if wolf.get_locomotion_state() != &"trot":
		_fail("%.1f s into a chase the wolf plays '%s', expected 'trot'" % [FOOT_SLIDE_WARMUP_SECONDS, wolf.get_locomotion_state()])
		return false

	var paws: Array[Vector3] = []
	var bodies: Array[Vector3] = []
	var deadline := Time.get_ticks_msec() + int(FOOT_SLIDE_SAMPLE_SECONDS * 1000.0)
	while Time.get_ticks_msec() < deadline:
		await get_tree().physics_frame
		if GroundMath.ground_distance(wolf.global_position, player.global_position) < FOOT_SLIDE_STOP_DISTANCE_M:
			break
		paws.append(skeleton.global_transform * skeleton.get_bone_global_pose(bone) * paw_local)
		bodies.append(wolf.global_position)

	if paws.size() < 10:
		_fail("only %d foot samples on the straight chase" % paws.size())
		return false
	var low := INF
	var high := -INF
	for paw in paws:
		low = minf(low, paw.y)
		high = maxf(high, paw.y)
	if high - low < FOOT_SLIDE_MIN_LIFT_M:
		_fail("the front paw only rises %.3f m on the trot, expected at least %.2f m" % [high - low, FOOT_SLIDE_MIN_LIFT_M])
		return false
	var planted_below := low + (high - low) / 3.0
	var slide := 0.0
	var planted := 0
	for i in range(1, paws.size()):
		if paws[i - 1].y <= planted_below and paws[i].y <= planted_below:
			slide += GroundMath.ground_distance(paws[i - 1], paws[i])
			planted += 1
	var travel := GroundMath.ground_distance(bodies[0], bodies[bodies.size() - 1])
	if travel < FOOT_SLIDE_MIN_TRAVEL_M:
		_fail("the wolf only travelled %.2f m while its paw was sampled" % travel)
		return false
	var cycles := travel / Enemy3D.TROT_STRIDE_PER_CYCLE_M
	var share := slide / travel
	var seconds := float(paws.size()) / float(Engine.physics_ticks_per_second)
	_foot_report = ("foot slide: %d samples over %.2f s, body %.2f m (%.2f m/s, %.1f cycles, speed_scale %.2f), paw rises %.3f m, "
		+ "%d planted steps slid %.3f m = %.3f m per cycle, %.1f %% of the %.3f m travel per cycle") \
		% [paws.size(), seconds, travel, travel / seconds, cycles, wolf.get_animation_player().speed_scale, high - low,
			planted, slide, slide / cycles, share * 100.0, travel / cycles]
	if share >= FOOT_SLIDE_MAX_SHARE:
		_fail("the planted front paw slid %.3f m while the body travelled %.2f m (%.1f %% per cycle, limit %.0f %%)"
			% [slide, travel, share * 100.0, FOOT_SLIDE_MAX_SHARE * 100.0])
		return false

	# Let the chase end in reach, standing on idle, so the turn-mode steps start
	# from a wolf that can bite.
	var arrived := await _wait_until(func() -> bool:
		return GroundMath.ground_distance(wolf.global_position, player.global_position) <= wolf.attack_range \
			and not wolf.is_moving() and wolf.get_locomotion_state() == &"idle",
		FOOT_SLIDE_ARRIVE_SECONDS)
	if not arrived:
		_fail("after the long chase the wolf is %.2f m from the player and plays '%s'"
			% [GroundMath.ground_distance(wolf.global_position, player.global_position), wolf.get_locomotion_state()])
		return false
	return _expect_idle_in_reach("after the long chase")


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

	var anim := wolf.get_animation_player()
	wolf.receive_damage(1000)
	if wolf.is_alive():
		_fail("is_alive() is still true on the frame a lethal hit landed")
		return false

	# WP12: no locomotion clip under the topple.
	if anim.is_playing() or wolf.get_locomotion_state() != &"":
		_fail("the wolf's clip '%s' still plays on the frame it died (state '%s')"
			% [anim.current_animation, wolf.get_locomotion_state()])
		return false
	await _wait(DEATH_CLIP_CHECK_SECONDS)
	if not is_instance_valid(wolf) or not is_instance_valid(anim):
		_fail("the wolf was freed %.1f s into its topple" % DEATH_CLIP_CHECK_SECONDS)
		return false
	if anim.is_playing() or wolf.get_locomotion_state() != &"":
		_fail("the wolf's clip '%s' plays %.1f s into the death topple" % [anim.current_animation, DEATH_CLIP_CHECK_SECONDS])
		return false

	await _wait(DEATH_WAIT_SECONDS - DEATH_CLIP_CHECK_SECONDS)
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
