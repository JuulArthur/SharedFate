class_name Enemy3D
extends ActorBase3D

## `scripts/enemy.gd` ported to 3D, method by method: the realtime chase, the
## telegraphed swing that drives the counter window, the Frost Snare root and the
## death beat that pays out XP and loot.
##
## What was pixels in 2D is metres here (the 2D game is 64 px to the metre) and
## every ground measurement goes through GroundMath. The visible body is the
## `Model` child - a placeholder box until WP8 drops the imported wolf under it.
## Nothing outside `Model` is posed or tinted, so swapping the mesh is the only
## change that package needs.
##
## Gameplay expansion (track B, docs/gameplay-expansion.md section 2): statuses
## (stun, root, poison, burn, weaken, expose), knockback, sneak-attack queries,
## investigating, environment damage that never provokes, the detection
## multiplier, wandering around a home point, display data for the turn strip,
## humanoid bodies (`move_clip`) and a model tint. Every addition defaults to the
## old behaviour, so the arena wolves play exactly as before.
##
## Contract: docs/3d-port-contracts.md, sections 5.1, 5.3, 7, 8, and
## docs/gameplay-expansion.md section 2. Roster: docs/enemy-roster.md.
## Differences from the 2D script: docs/deviations/wp3c.md.

@export var attack_cooldown := 0.8
@export var target_refresh_interval := 0.25
@export var experience_reward := 50
## Loot dropped on death. Authored items always drop; when the list is empty the
## enemy rolls `loot_drop_chance` against the shared random table instead, so
## runtime-spawned enemies still pay out without per-instance setup.
@export var loot_items: Array[Item] = []
@export var loot_drop_chance := 0.6
## Metres, like every other 3D range. The 2D value was 20 px.
@export var loot_drop_spread := 0.3
## How close the player must come, in metres, before this enemy spots it (WP13:
## replaces `aggro_range`, so the visible ring, the realtime chase gate and the
## coordinator's combat trigger are one rule, `can_spot`). 0 means the enemy
## never spots anyone on its own and only a hit provokes it (an unaware enemy;
## the 2D `aggro_range` 0 meant "chase from anywhere", which would start turn
## combat on the first frame). Wolves use 5 m, the generic enemy 4 m. Taking a
## hit always provokes. Scaled by the target's `get_detection_multiplier()`.
@export var detection_range := 4.0
@export var attack_wind_up_duration := 0.2
@export var attack_strike_duration := 0.12
@export var attack_recovery_duration := 0.2
## Turn mode uses a slower, clearly telegraphed swing: the wind-up is long enough
## to read and the strike (= the counter window) is wide enough to hit on purpose.
## Realtime keeps the snappier values above.
@export var turn_attack_wind_up_duration := 0.55
@export var turn_attack_strike_duration := 0.18

@export_group("Identity")
## Name for the turn-order strip and the boss bar.
@export var display_name := "Enemy"
## Portrait swatch colour for the turn-order strip.
@export var portrait_color := Color(0.78, 0.3, 0.26, 1.0)
## True for a boss: `is_boss()` answers it and the lead's HUD may treat it apart.
@export var boss := false

@export_group("Turn and defence")
## Metres this enemy moves per turn. 0 takes what the coordinator offers
## (TURN_MOVE_METERS, 6 m); a positive value replaces it (the bandit's 7 m, the
## brute's 5 m). A root or a stun still makes it 0.
@export var turn_move_override_m := 0.0
## Incoming hits are multiplied by this before `expose` (the brute's 0.8). 1.0
## keeps hits exact.
@export var damage_taken_multiplier := 1.0

@export_group("Wandering")
## Metres around the home point this enemy strolls while unaware; 0 stands still.
@export var wander_radius := 0.0
## Seconds of rest between two strolls, picked at random in [x, y].
@export var wander_pause := Vector2(2.0, 5.0)

@export_group("Body")
## Locomotion clips on the model's AnimationPlayer. The wolf plays `trot`; the
## humanoid bodies (knight, rogue, mage glbs) play `walk`.
@export var idle_clip: StringName = &"idle"
@export var move_clip: StringName = &"trot"
## Ground speed (m/s) at which `move_clip` plays at 1.0x without foot slide:
## the wolf's trot 1.878 m/s, a humanoid walk 1.92 m/s at scale 1 (multiply by
## the model's scale).
@export var move_clip_reference_speed := 1.878
## Multiplies the albedo of every surface under `Model` (materials are
## duplicated, so the glb stays shared and untouched). White leaves the model
## as imported.
@export var model_tint := Color(1.0, 1.0, 1.0, 1.0)

## Emitted once per hit that lands while this enemy is not in turn mode (WP13).
## The coordinator answers by starting combat as an ambush: the hit has already
## resolved (health changed, and `_die` follows this signal when it was lethal),
## then the enemies get the first turn. `take_environment_damage` never emits it.
signal provoked_by_hit

## Detection (WP13). The ring is a RangeRing3D child at the effective detection
## radius, shown while the enemy is alive, calm and out of turn mode: a faint
## dashed circle that turns warning red once the player is within
## DETECTION_WARNING_MARGIN_M of its edge.
const DETECTION_RING_COLOR_CALM := Color(0.55, 0.75, 0.95, 0.30)
const DETECTION_RING_COLOR_WARNING := Color(1.0, 0.30, 0.25, 0.75)
const DETECTION_WARNING_MARGIN_M := 1.5
## The ring never shrinks below this, so a hidden player (multiplier 0) still
## sees where the enemy stands watch.
const DETECTION_RING_MIN_RADIUS_M := 0.6
## The ring mesh is rebuilt only when the radius moves by more than this.
const DETECTION_RING_REBUILD_M := 0.02
## Line of sight: a ray from the enemy's eyes to the target's chest against
## props (layer 8, docs/3d-port-contracts.md section 3). A tree or a crate
## between the two hides the player even inside the ring.
const DETECTION_LINE_OF_SIGHT_MASK := 8
const DETECTION_EYE_HEIGHT_M := 0.6
const DETECTION_TARGET_HEIGHT_M := 0.9

enum DetectionRingState {
	HIDDEN,
	CALM,
	WARNING
}

## Status ids (docs/gameplay-expansion.md section 2). Durations count this
## enemy's own turns and drop at its `end_turn`; all clear when turn combat ends.
const STATUS_STUN := &"stun"
const STATUS_ROOT := &"root"
const STATUS_POISON := &"poison"
const STATUS_BURN := &"burn"
const STATUS_WEAKEN := &"weaken"
const STATUS_EXPOSE := &"expose"
## Order of the status line under the bar.
const STATUS_ORDER: Array[StringName] = [STATUS_STUN, STATUS_ROOT, STATUS_POISON,
	STATUS_BURN, STATUS_WEAKEN, STATUS_EXPOSE]
const WEAKEN_DAMAGE_MULT := 0.5
const EXPOSE_DAMAGE_MULT := 1.5
const STUN_COLOR := Color(1.0, 0.92, 0.35, 1.0)
const POISON_COLOR := Color(0.45, 0.95, 0.35, 1.0)
const BURN_COLOR := Color(1.0, 0.58, 0.18, 1.0)
const WEAKEN_COLOR := Color(0.75, 0.7, 0.95, 1.0)
const EXPOSE_COLOR := Color(1.0, 0.45, 0.65, 1.0)
const POPUP_STATUS_OFFSET := Vector3(0.0, 1.0, 0.0)
## Burn's tick popup sits above poison's so both read on the same turn.
const POPUP_BURN_TICK_OFFSET := Vector3(0.0, 0.85, 0.0)

const DEATH_SECONDS := 0.42
## The dissolve after the topple, the 2D `modulate:a` fade.
const DEATH_FADE_SECONDS := 0.16
## Frost Snare: the ring at the feet while rooted, and the popups.
const ROOT_COLOR := Color(0.62, 0.88, 1.0, 0.9)
const ROOT_FLASH_COLOR := Color(0.9, 1.5, 2.2, 1.0)
const ROOT_RING_RADIUS_M := 0.7

## 2D pixel offsets over 64 px per metre: 40, 58, 56 and 48 px above the body.
const POPUP_DAMAGE_OFFSET := Vector3(0.0, 0.63, 0.0)
const POPUP_XP_OFFSET := Vector3(0.0, 0.91, 0.0)
const POPUP_ROOT_OFFSET := Vector3(0.0, 0.88, 0.0)
const POPUP_ROOTED_TURN_OFFSET := Vector3(0.0, 0.75, 0.0)
## CombatFx draws a projected ring_burst straight on the FX CanvasLayer, so the
## 2D world radii have to be multiplied by the 2D camera zoom to read the same.
## Same reasoning as CounterPrompt3D.SCREEN_SCALE.
const FX_SCREEN_SCALE := 3.35
const ROOT_BURST_START_PX := 6.0 * FX_SCREEN_SCALE
const ROOT_BURST_END_PX := 22.0 * FX_SCREEN_SCALE

## 7 px of recoil, 6 px of wind-up pull and an 11 px lunge in 2D.
const HIT_NUDGE_M := 0.11
const WIND_UP_PULL_M := 0.09
const LUNGE_M := 0.17
## The 2D sprite squash and stretch, read as (side, up, facing).
const WIND_UP_SCALE := Vector3(0.94, 1.12, 0.86)
const STRIKE_SCALE := Vector3(1.0, 0.9, 1.14)
## An additive overlay can brighten but never darken, so the 2D wind-up dim
## (0.52, 0.22, 0.22) becomes a sullen red glow instead.
const WIND_UP_TINT := Color(0.35, 0.06, 0.06, 1.0)
const STRIKE_TINT := Color(1.0, 0.42, 0.42, 1.0)
const DEATH_FLASH_TINT := Color(2.6, 2.6, 2.6, 1.0)
## The 2D hover outline colour, as a faint additive rim on the model.
const HOVER_TINT := Color(0.95, 0.14, 0.14, 0.28)

## Where the chase aims is the base class's approach rule (WP10,
## `get_attack_approach_distance`): inside `attack_range`, but never closer than
## the two collision surfaces plus a gap. 2D aimed `attack_range - 20 px`.
## The 2D swing aborts when the target has walked out of `attack_range * 1.2`.
const ATTACK_BREAK_FACTOR := 1.2

## Knockback: a short slide on the ground plane, stopped by props (layer 8) and
## clamped to the navmesh.
const KNOCKBACK_SECONDS := 0.15
const KNOCKBACK_BLOCK_MASK := 8
## Kept between the body's shape and the prop it stops against.
const KNOCKBACK_SKIN_M := 0.03

## Calm behaviour: wandering, investigating and walking home happen at this
## share of `move_speed`.
const CALM_SPEED_FACTOR := 0.45
const INVESTIGATE_LOOK_SECONDS := 2.0
## During the look-around the body turns this far, this often.
const LOOK_AROUND_TURN_DEG := 70.0
const LOOK_AROUND_STEP_SECONDS := 0.6
## Farther than this from home when a fight ends: walk back.
const HOME_RETURN_MIN_M := 0.5

enum CalmState {
	IDLE,
	WANDER,
	INVESTIGATE,
	LOOK_AROUND,
	HOME
}

var current_health: int:
	get:
		return health

var _model: Node3D = null
var _model_meshes: Array[MeshInstance3D] = []
var _model_idle_position := Vector3.ZERO
var _model_idle_scale := Vector3.ONE
var _counter_prompt: CounterPrompt3D = null
var _bars: OverheadBars3D = null
var _status_line: EnemyStatusLine3D = null
var _root_ring: RangeRing3D = null
var _detection_ring: RangeRing3D = null
var _detection_ring_state: DetectionRingState = DetectionRingState.HIDDEN
var _detection_ring_radius := 0.0
var _hover_overlay: StandardMaterial3D = null

var _target: Node3D = null
var _attack_sequence_active := false
var _attack_cooldown_left := 0.0
var _target_refresh_left := 0.0
var _aggroed := false
var _dying := false
var _hover_highlighted := false
var _counter_prompt_shown := false
var _last_applied_damage := 0

## status id -> {"turns": int, "power": int}
var _statuses: Dictionary = {}
## True for the turn a stun is skipping.
var _skipping_turn := false
## Set around a hit that must not provoke (traps) or must not be scaled (a
## damage-over-time tick).
var _environment_hit := false
var _status_tick_hit := false
var _hit_popup_color := CombatFx.COLOR_DAMAGE_DEALT

var _knockback_active := false
var _knockback_tween: Tween = null

var _home_position := Vector3.ZERO
var _home_recorded := false
var _calm_state: CalmState = CalmState.IDLE
var _calm_pace := false
var _full_move_speed := 0.0
var _wander_pause_left := 0.0
var _look_left := 0.0
var _look_step_left := 0.0
## The next look-around turn, in units of LOOK_AROUND_TURN_DEG (+1 first,
## then -2, +2, ...).
var _look_turn_sign := 1.0
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	super()
	add_to_group("enemies")
	_rng.randomize()
	_full_move_speed = move_speed
	_wander_pause_left = _random_wander_pause()
	_setup_model()
	_setup_overhead_bars()
	_setup_status_line()
	_setup_counter_prompt()
	_setup_root_ring()
	_setup_detection_ring()
	_update_health_bar()


func _process(_delta: float) -> void:
	_update_detection_ring()


# --- Realtime AI ------------------------------------------------------------------

## The 2D `_physics_process`, in the same order: turn mode just walks its path,
## realtime ticks the timers, gates on detection, refreshes the approach point
## and swings once the target is inside `attack_range`. While unaware and out of
## turn mode the calm behaviour runs instead (wander, investigate, walk home).
##
## WP13: under the coordinator, spotting the player starts turn combat on the
## same frame, so the realtime chase and bite below only ever run in a scene
## without a coordinator (enemy_test, approach_test) or after a hit provoked an
## enemy there. They are kept for those scenes; in the arena an enemy never
## bites in realtime before combat begins.
func _physics_process(delta: float) -> void:
	_update_locomotion_animation(delta)
	if navigation_agent == null:
		return
	if not _home_recorded:
		_home_position = GroundMath.flatten(global_position)
		_home_recorded = true
	if not is_alive():
		velocity = Vector3.ZERO
		return
	if _knockback_active:
		velocity = Vector3.ZERO
		return

	if is_in_turn_based_combat():
		super(delta)
		return

	_attack_cooldown_left = maxf(0.0, _attack_cooldown_left - delta)
	_target_refresh_left -= delta

	var target := _live_target()

	# Watchers hold still (or stroll) until the player is spotted: inside the
	# detection ring and in view. A hit sets `_aggroed` directly.
	if not _aggroed:
		if target != null and can_spot(target):
			_aggroed = true
			_leave_calm()
		else:
			_step_calm(delta)
			return

	if target == null:
		_halt()
		return

	# Within reach: stand and bite. The chase is parked rather than re-aimed
	# every refresh, so nothing keeps nudging the body toward a point inside
	# the player (WP10).
	if GroundMath.ground_distance(global_position, target.global_position) <= attack_range:
		_halt()
		_try_attack_target()
		return

	# Out of reach: re-aim on the refresh interval, or at once when the chase
	# was parked while the player stood in reach and has since stepped away.
	if _target_refresh_left <= 0.0 or navigation_agent.is_navigation_finished():
		_refresh_target_position()
		_target_refresh_left = target_refresh_interval

	super(delta)


## The 2D `velocity = ZERO; move_and_slide()`, plus what 3D needs: the agent is
## parked and the avoidance simulation is told the body is standing (WP10). The
## chase resumes from `_refresh_target_position` the moment the gate opens.
func _halt() -> void:
	hold_position()


func _live_target() -> Node3D:
	if _target == null or not is_instance_valid(_target):
		return null
	if _target.has_method("is_alive") and not bool(_target.call("is_alive")):
		return null
	return _target


## Who to chase and bite. In turn mode only the target changes: the coordinator
## owns every step then, so a target handed over mid-fight (a summon being
## registered) must not start a free walk.
func set_target(target: Node3D) -> void:
	_target = target
	if not is_in_turn_based_combat():
		_refresh_target_position()


## The target set by `set_target` or the last `try_attack`, or null.
func get_target() -> Node3D:
	return _live_target()


## Makes this enemy alerted without a hit (the boss's summons arrive angry).
func alert() -> void:
	if not is_alive():
		return
	_aggroed = true
	_leave_calm()


## Teleport (actor contract 5.1). Out of turn mode the new spot also becomes the
## home point, so a level or a test that places an enemy does not see it walk
## back to where it stood before.
func snap_to(world_position: Vector3) -> void:
	super(world_position)
	if is_in_turn_based_combat() or not is_inside_tree():
		return
	_home_position = GroundMath.flatten(global_position)
	_home_recorded = true
	_leave_calm()


# --- Identity (turn-order strip, boss bar) -------------------------------------------

func get_display_name() -> String:
	return display_name


func get_portrait_color() -> Color:
	return portrait_color


func is_boss() -> bool:
	return boss


# --- Detection (WP13) ---------------------------------------------------------------

## The one rule for "spotted": alive on both sides, `target` on the ground
## within the effective detection range (`detection_range` times the target's
## `get_detection_multiplier()`) and nothing on the prop layer between the
## enemy's eyes and the target's chest. The coordinator asks this every frame in
## exploration to start combat; the realtime chase gates on it too, so the
## visible ring is exactly the rule.
func can_spot(target: Node3D) -> bool:
	if not is_alive() or _dying or detection_range <= 0.0:
		return false
	if target == null or not is_instance_valid(target):
		return false
	if target.has_method("is_alive") and not bool(target.call("is_alive")):
		return false
	var effective := detection_range * _detection_multiplier_of(target)
	if effective <= 0.0:
		return false
	if GroundMath.ground_distance(global_position, target.global_position) > effective:
		return false
	return has_line_of_sight_to(target)


## `detection_range` times the current target's detection multiplier (1.0
## without a target or without `get_detection_multiplier`).
func get_effective_detection_range() -> float:
	return detection_range * _detection_multiplier_of(_live_target())


func _detection_multiplier_of(target: Node3D) -> float:
	if target == null or not is_instance_valid(target):
		return 1.0
	if not target.has_method("get_detection_multiplier"):
		return 1.0
	return maxf(0.0, float(target.call("get_detection_multiplier")))


## True when no prop (layer 8) blocks the ray from this enemy's eyes to the
## target's chest. Actors are not on that layer, so the player never hides
## behind another enemy. Answers true while the world has no physics space yet.
func has_line_of_sight_to(target: Node3D) -> bool:
	if target == null or not is_instance_valid(target):
		return false
	var world := get_world_3d()
	if world == null or world.direct_space_state == null:
		return true
	var from := global_position + Vector3(0.0, DETECTION_EYE_HEIGHT_M, 0.0)
	var to := target.global_position + Vector3(0.0, DETECTION_TARGET_HEIGHT_M, 0.0)
	var query := PhysicsRayQueryParameters3D.create(from, to, DETECTION_LINE_OF_SIGHT_MASK)
	query.collide_with_areas = false
	query.collide_with_bodies = true
	var excluded: Array[RID] = [get_rid()]
	if target is CollisionObject3D:
		excluded.append((target as CollisionObject3D).get_rid())
	query.exclude = excluded
	var hit: Dictionary = world.direct_space_state.intersect_ray(query)
	return hit.is_empty()


## True once this enemy has noticed the player (spotted it, or was hit) and is
## no longer just watching. Reset when turn combat ends.
func is_alerted() -> bool:
	return _aggroed


## Alive, not in turn mode, not alerted: a sneak-attack target.
func is_unaware() -> bool:
	return is_alive() and not _dying and not is_in_turn_based_combat() and not _aggroed


## True when `world_point` lies more than 110 degrees off this enemy's facing
## (local -Z) on the ground plane. A point on the body answers false.
func is_back_turned_to(world_point: Vector3) -> bool:
	var to_point := GroundMath.ground_direction(global_position, world_point)
	if to_point == Vector3.ZERO:
		return false
	var facing := GroundMath.ground_direction(Vector3.ZERO, -global_transform.basis.z)
	if facing == Vector3.ZERO:
		return false
	return facing.angle_to(to_point) > deg_to_rad(110.0)


## The visible detection ring, for a coordinator or a test that wants to read it.
func get_detection_ring() -> RangeRing3D:
	return _detection_ring


func _setup_detection_ring() -> void:
	_detection_ring = RangeRing3D.new()
	_detection_ring.name = "DetectionRing"
	add_child(_detection_ring)
	_detection_ring.hide_ring()
	_detection_ring_state = DetectionRingState.HIDDEN


## Shown while the enemy is alive, calm and in exploration; hidden in turn
## mode, once alerted, while dying and for an unaware enemy (range 0). Its
## radius is the effective detection range, never below
## DETECTION_RING_MIN_RADIUS_M. Calm blue far from the player, warning red once
## the player is within DETECTION_WARNING_MARGIN_M of the edge. The ring mesh is
## only rebuilt when its state changes or its radius moves by more than
## DETECTION_RING_REBUILD_M.
func _update_detection_ring() -> void:
	if _detection_ring == null:
		return
	var wanted_shown := is_alive() and not _dying and not is_in_turn_based_combat() \
		and not _aggroed and detection_range > 0.0
	if not wanted_shown:
		if _detection_ring_state != DetectionRingState.HIDDEN:
			_detection_ring.hide_ring()
			_detection_ring_state = DetectionRingState.HIDDEN
		return
	var effective := get_effective_detection_range()
	var radius := maxf(effective, DETECTION_RING_MIN_RADIUS_M)
	var wanted_state := DetectionRingState.CALM
	var target := _live_target()
	if target != null and effective > 0.0 \
			and GroundMath.ground_distance(global_position, target.global_position) \
			<= effective + DETECTION_WARNING_MARGIN_M:
		wanted_state = DetectionRingState.WARNING
	if wanted_state == _detection_ring_state \
			and absf(radius - _detection_ring_radius) <= DETECTION_RING_REBUILD_M:
		return
	var ring_color := DETECTION_RING_COLOR_WARNING if wanted_state == DetectionRingState.WARNING \
		else DETECTION_RING_COLOR_CALM
	_detection_ring.show_ring(radius, ring_color, true)
	_detection_ring_state = wanted_state
	_detection_ring_radius = radius


func _refresh_target_position() -> void:
	if _target == null or not is_instance_valid(_target):
		return
	set_navigation_target(_compute_approach_point(_target.global_position, _approach_distance()))


## Stop short of the target instead of walking into it, as 2D does; the rule
## that keeps the two bodies apart lives in ActorBase3D.
func _approach_distance() -> float:
	return get_attack_approach_distance(_target)


func _compute_approach_point(target_world_position: Vector3, stop_distance: float) -> Vector3:
	var to_mover := GroundMath.flatten(global_position) - GroundMath.flatten(target_world_position)
	var distance := to_mover.length()
	if distance <= stop_distance:
		return global_position
	if distance <= 0.001:
		return target_world_position
	return GroundMath.flatten(target_world_position) + (to_mover / distance) * stop_distance


# --- Calm behaviour: wander, investigate, walk home ---------------------------------

## One exploration frame of an unaware enemy. Idle at home it holds position
## exactly as before (`_halt`), so an enemy with `wander_radius` 0 behaves as
## the WP13 watcher did.
func _step_calm(delta: float) -> void:
	if is_rooted() or has_status(STATUS_STUN):
		_halt()
		return
	match _calm_state:
		CalmState.IDLE:
			_halt()
			if wander_radius > 0.0:
				_wander_pause_left -= delta
				if _wander_pause_left <= 0.0:
					_start_calm_walk(_pick_wander_point(), CalmState.WANDER)
		CalmState.LOOK_AROUND:
			_halt()
			_look_left -= delta
			_look_step_left -= delta
			if _look_step_left <= 0.0:
				# Left, then right across the middle, then left again.
				_look_step_left = LOOK_AROUND_STEP_SECONDS
				rotation.y += deg_to_rad(LOOK_AROUND_TURN_DEG) * _look_turn_sign
				_look_turn_sign = -2.0 * signf(_look_turn_sign)
			if _look_left <= 0.0:
				_start_calm_walk(_home_position, CalmState.HOME)
		_:
			if navigation_agent.is_navigation_finished():
				_on_calm_walk_arrived()
				return
			super._physics_process(delta)


func _start_calm_walk(destination: Vector3, state: CalmState) -> void:
	_calm_state = state
	_set_calm_pace(true)
	set_navigation_target(destination)


func _on_calm_walk_arrived() -> void:
	_set_calm_pace(false)
	if _calm_state == CalmState.INVESTIGATE:
		_calm_state = CalmState.LOOK_AROUND
		_look_left = INVESTIGATE_LOOK_SECONDS
		_look_step_left = LOOK_AROUND_STEP_SECONDS * 0.5
		_look_turn_sign = 1.0
		_halt()
		return
	_calm_state = CalmState.IDLE
	_wander_pause_left = _random_wander_pause()
	_halt()


## Back to plain idle at full pace: spotted, provoked, alerted or in turn mode.
func _leave_calm() -> void:
	_calm_state = CalmState.IDLE
	_set_calm_pace(false)


func _set_calm_pace(enabled: bool) -> void:
	if enabled == _calm_pace:
		return
	if enabled:
		_full_move_speed = move_speed
		move_speed = _full_move_speed * CALM_SPEED_FACTOR
	else:
		move_speed = _full_move_speed
	_calm_pace = enabled


func _random_wander_pause() -> float:
	var low := minf(wander_pause.x, wander_pause.y)
	var high := maxf(wander_pause.x, wander_pause.y)
	return _rng.randf_range(maxf(0.0, low), maxf(0.0, high))


## A random point on the navmesh within `wander_radius` of home.
func _pick_wander_point() -> Vector3:
	var angle := _rng.randf() * TAU
	var distance := sqrt(_rng.randf()) * wander_radius
	var candidate := _home_position + Vector3(cos(angle), 0.0, sin(angle)) * distance
	var on_mesh := _clamp_to_navmesh(candidate, wander_radius)
	if GroundMath.ground_distance(on_mesh, _home_position) > wander_radius:
		return _home_position
	return on_mesh


## The calm state, for tests and debugging: `idle`, `wander`, `investigate`,
## `look_around` or `home`.
func get_calm_state() -> StringName:
	match _calm_state:
		CalmState.WANDER:
			return &"wander"
		CalmState.INVESTIGATE:
			return &"investigate"
		CalmState.LOOK_AROUND:
			return &"look_around"
		CalmState.HOME:
			return &"home"
	return &"idle"


## Where this enemy returns to: its position on the first physics frame, or
## where it was last placed with `snap_to` outside a fight.
func get_home_position() -> Vector3:
	return _home_position


## An unaware enemy walks to the point at the calm pace, looks around for about
## two seconds, then walks home. Ignored when alerted or in turn mode.
func investigate(world_point: Vector3) -> void:
	if not is_unaware() or is_rooted() or has_status(STATUS_STUN):
		return
	_start_calm_walk(GroundMath.flatten(world_point), CalmState.INVESTIGATE)


# --- Attacks ------------------------------------------------------------------------

## Contract 5.3. The 2D twin returned void; the base class declares `bool`, so this
## reports whether the swing sequence started and the coordinator can await it.
func try_attack(target: Node3D = null) -> bool:
	if target != null:
		_target = target
	if _attack_sequence_active:
		return false
	if not _attack_precheck():
		return false
	if is_in_turn_based_combat():
		_turn_attack_available = false
	await _run_attack_sequence_full()
	return true


func _try_attack_target() -> void:
	if _attack_sequence_active:
		return
	if not _attack_precheck():
		return
	_run_attack_sequence_full()


func _attack_precheck() -> bool:
	if not is_alive():
		return false
	if is_in_turn_based_combat():
		if not is_turn_active() or not can_turn_attack():
			return false
	else:
		if _attack_cooldown_left > 0.0:
			return false
	if _target == null or not is_instance_valid(_target):
		return false
	if _target.has_method("is_alive") and not bool(_target.call("is_alive")):
		return false
	# The base's tolerance (WP10): a turn-mode approach may stop exactly on the
	# reach, and the 2D strict compare refused the bite by a rounding error.
	if GroundMath.ground_distance(global_position, _target.global_position) > attack_range + ATTACK_RANGE_TOLERANCE:
		return false
	return _target.has_method("receive_damage")


## Wind-up, strike, recovery, with the 2D durations and the 2D counter handshake.
## The damage is fixed when the swing starts (`_outgoing_damage`, so `weaken`
## is already in it) and handed to the player's counter methods. Subclasses
## change the look through `_play_wind_up` / `_play_strike` and the numbers
## through the `_attack_*` hooks, never the order of the handshake.
func _run_attack_sequence_full() -> void:
	var target := _target
	if target == null or not is_instance_valid(target):
		return

	_attack_sequence_active = true
	_begin_attack_variant(target)
	var turn_mode := is_in_turn_based_combat()
	var damage := _outgoing_damage()
	var wind_up := _attack_wind_up_seconds(turn_mode)
	var strike := _attack_strike_seconds(turn_mode)
	var can_be_countered := target.has_method("begin_enemy_counter_windup")
	if can_be_countered:
		target.call("begin_enemy_counter_windup", self, damage)
		if _counter_prompt != null:
			# Tell the player what the press will do as whoever is in control.
			if target.has_method("get_reaction_hint"):
				var hint: Dictionary = target.call("get_reaction_hint")
				var hint_color: Color = hint.get("color", CounterPrompt3D.COLOR_TARGET)
				var hint_text := String(hint.get("text", ""))
				var prefix := _attack_hint_prefix()
				if not prefix.is_empty():
					hint_text = prefix if hint_text.is_empty() else "%s  %s" % [prefix, hint_text]
				_counter_prompt.set_hint(hint_text, hint_color)
			_counter_prompt.start_windup(wind_up)
			_counter_prompt_shown = true

	face_toward(target.global_position)

	# 1) Wind-up - telegraph only, no damage.
	await _play_wind_up(target, wind_up)

	if not is_instance_valid(self) or not is_alive():
		_cancel_counter_on_target(target)
		_hide_counter_prompt()
		_attack_sequence_active = false
		_end_attack_variant(false)
		return
	if not is_instance_valid(target) or GroundMath.ground_distance(global_position, target.global_position) \
			> attack_range * ATTACK_BREAK_FACTOR:
		_cancel_counter_on_target(target)
		_hide_counter_prompt()
		_reset_attack_model_pose()
		_attack_sequence_active = false
		if not is_in_turn_based_combat():
			_attack_cooldown_left = attack_cooldown * 0.35
		_end_attack_variant(false)
		return

	# 2) Strike - the counter window; damage resolves after the lunge.
	if target.has_method("begin_enemy_counter_strike"):
		target.call("begin_enemy_counter_strike")
	if can_be_countered and _counter_prompt != null:
		_counter_prompt.start_strike(strike)

	await _play_strike(target, strike)

	if not is_instance_valid(self):
		_cancel_counter_on_target(target)
		_attack_sequence_active = false
		return

	if is_instance_valid(target):
		if target.has_method("resolve_enemy_attack"):
			var countered := bool(target.call("resolve_enemy_attack", self, damage))
			if _counter_prompt != null:
				_counter_prompt.show_result(countered)
		elif target.has_method("receive_damage"):
			target.call("receive_damage", damage)
			_hide_counter_prompt()
	else:
		_hide_counter_prompt()

	# 3) Recovery - after damage, return to neutral.
	await _play_recovery()

	_attack_sequence_active = false
	if not is_in_turn_based_combat():
		_attack_cooldown_left = attack_cooldown
	_end_attack_variant(true)


## Virtual: the wind-up look. The default pulls the model back and squashes it
## under a red glow for `seconds`.
func _play_wind_up(_target_node: Node3D, seconds: float) -> void:
	_flash_model(WIND_UP_TINT, seconds)
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(_model, "position", _model_idle_position + Vector3(0.0, 0.0, WIND_UP_PULL_M), seconds) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(_model, "scale", _model_idle_scale * WIND_UP_SCALE, seconds)
	await tween.finished


## Virtual: the strike look, which lasts exactly the counter window. The default
## lunges along the facing.
func _play_strike(_target_node: Node3D, seconds: float) -> void:
	_flash_model(STRIKE_TINT, maxf(seconds * 0.45, 0.01))
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(_model, "position", _model_idle_position + Vector3(0.0, 0.0, -LUNGE_M), seconds) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.tween_property(_model, "scale", _model_idle_scale * STRIKE_SCALE, seconds)
	await tween.finished


func _play_recovery() -> void:
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(_model, "position", _model_idle_position, attack_recovery_duration) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(_model, "scale", _model_idle_scale, attack_recovery_duration)
	await tween.finished


## Virtual: called when a swing starts, before its damage and timings are read.
func _begin_attack_variant(_target_node: Node3D) -> void:
	pass


## Virtual: called when a swing ends; `resolved` is false when it was aborted
## before the strike landed.
func _end_attack_variant(_resolved: bool) -> void:
	pass


## Virtual: the wind-up length of the swing that is starting.
func _attack_wind_up_seconds(turn_mode: bool) -> float:
	return turn_attack_wind_up_duration if turn_mode else attack_wind_up_duration


## Virtual: the strike (counter window) length of the swing that is starting.
func _attack_strike_seconds(turn_mode: bool) -> float:
	return turn_attack_strike_duration if turn_mode else attack_strike_duration


## Virtual: the swing's damage before statuses (the dire wolf's heavy bite).
func _attack_base_damage() -> int:
	return attack_damage


## Virtual: a word shown in front of the counter hint (the dire wolf's HEAVY).
func _attack_hint_prefix() -> String:
	return ""


## The damage a swing deals: `_attack_base_damage()`, halved while weakened.
func _outgoing_damage() -> int:
	var damage := _attack_base_damage()
	if has_status(STATUS_WEAKEN) and damage > 0:
		damage = maxi(1, roundi(float(damage) * WEAKEN_DAMAGE_MULT))
	return damage


func _cancel_counter_on_target(counter_target: Node3D) -> void:
	if counter_target != null and is_instance_valid(counter_target) \
			and counter_target.has_method("cancel_enemy_counter"):
		counter_target.call("cancel_enemy_counter")


func _hide_counter_prompt() -> void:
	if _counter_prompt != null:
		_counter_prompt.hide_prompt()


func _reset_attack_model_pose() -> void:
	if _model == null:
		return
	_model.position = _model_idle_position
	_model.scale = _model_idle_scale


## True from the first frame of a swing until its recovery ends. The coordinator
## can hold the turn open across the beat instead of guessing at the durations.
func is_attacking() -> bool:
	return _attack_sequence_active


## The prompt this enemy drives, for a coordinator or a test that wants to watch it.
func get_counter_prompt() -> CounterPrompt3D:
	return _counter_prompt


## True once this enemy has put the counter prompt on screen at least once.
func has_shown_counter_prompt() -> bool:
	return _counter_prompt_shown


# --- Damage ----------------------------------------------------------------------

## A hit always provokes, exactly as in 2D, except environment damage (traps).
## `damage_taken_multiplier` and `expose` scale it; a damage-over-time tick
## lands as is. The base subtracts what this returns.
func _apply_damage(amount: int) -> int:
	var applied := maxi(0, amount)
	if applied > 0 and not _status_tick_hit:
		var mult := damage_taken_multiplier
		if has_status(STATUS_EXPOSE):
			mult *= EXPOSE_DAMAGE_MULT
		if not is_equal_approx(mult, 1.0):
			applied = maxi(1, roundi(float(applied) * mult))
	_last_applied_damage = applied
	if applied > 0 and not _environment_hit:
		_aggroed = true
		_leave_calm()
	return applied


## Damage that does not provoke (docs/gameplay-expansion.md section 2): traps.
## The enemy stays unaware and no ambush starts.
func take_environment_damage(amount: int) -> void:
	_environment_hit = true
	_take_hit(amount)
	_environment_hit = false


## The base calls this once per landed hit, right after `health` changed, so the
## bar and the damage popup ride along with the tint. `CombatFx.flash(body)` also
## lands here through the actor contract, which only repeats the tint.
func flash_hit() -> void:
	super()
	_flash_model(HitFlash3D.DEFAULT_COLOR, HitFlash3D.DEFAULT_DURATION)
	_update_health_bar()
	if _last_applied_damage > 0:
		var landed := _last_applied_damage
		_last_applied_damage = 0
		_play_hit_feedback(landed)
		# WP13: a hit outside turn mode is an ambush; the coordinator starts
		# combat from this (deferred, so a lethal hit has finished dying first).
		if not is_in_turn_based_combat() and not _environment_hit:
			provoked_by_hit.emit()


func _play_hit_feedback(amount: int) -> void:
	var popup_at := global_position + POPUP_DAMAGE_OFFSET
	if _status_tick_hit and _hit_popup_color == BURN_COLOR:
		popup_at = global_position + POPUP_BURN_TICK_OFFSET
	CombatFx.popup_damage(popup_at, amount, _hit_popup_color)
	CombatFx.shake(3.0, 0.12)

	# Recoil away from whoever we are fighting. Skipped mid-swing so it never
	# fights the attack tween that owns the model's position at that moment.
	if _attack_sequence_active or _dying or _model == null:
		return
	var away := Vector3.BACK
	if _target != null and is_instance_valid(_target):
		var from_target := GroundMath.ground_direction(_target.global_position, global_position)
		if from_target != Vector3.ZERO:
			away = from_target
	var local_away := global_transform.basis.inverse() * away
	local_away.y = 0.0
	var nudge := _model_idle_position + local_away * HIT_NUDGE_M
	var tween := create_tween()
	tween.tween_property(_model, "position", nudge, 0.05) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(_model, "position", _model_idle_position, 0.16) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


# --- Knockback ------------------------------------------------------------------------

## Slides the body `distance_m` away from `from_point` on the ground plane over
## KNOCKBACK_SECONDS. A shape cast against props (layer 8) stops it short of a
## wall, and the end point is clamped to the navmesh. Movement already planned
## is dropped; nothing else (turn budget, aggro) changes.
func knockback(from_point: Vector3, distance_m: float) -> void:
	if not is_alive() or _dying or distance_m <= 0.0 or not is_inside_tree():
		return
	var direction := GroundMath.ground_direction(from_point, global_position)
	if direction == Vector3.ZERO:
		# Pushed from its own centre: back off along its local +Z.
		direction = GroundMath.ground_direction(Vector3.ZERO, global_transform.basis.z)
		if direction == Vector3.ZERO:
			direction = Vector3.BACK
	var motion := direction * distance_m
	var free_fraction := _knockback_free_fraction(motion)
	var destination := GroundMath.flatten(global_position + motion * free_fraction)
	destination = _clamp_to_navmesh(destination, distance_m + 1.0)
	if GroundMath.ground_distance(destination, global_position) < 0.01:
		return
	stop_movement_immediately()
	if _knockback_tween != null and _knockback_tween.is_valid():
		_knockback_tween.kill()
	_knockback_active = true
	_knockback_tween = create_tween()
	_knockback_tween.tween_property(self, "global_position", destination, KNOCKBACK_SECONDS) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_knockback_tween.tween_callback(_finish_knockback)


## True while a knockback slide is playing.
func is_knocked_back() -> bool:
	return _knockback_active


## The share of `motion` the collision shape can travel before touching a prop.
func _knockback_free_fraction(motion: Vector3) -> float:
	if collision_shape == null or collision_shape.shape == null:
		return 1.0
	var world := get_world_3d()
	if world == null or world.direct_space_state == null:
		return 1.0
	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = collision_shape.shape
	params.transform = collision_shape.global_transform
	params.motion = motion
	params.collision_mask = KNOCKBACK_BLOCK_MASK
	params.collide_with_areas = false
	params.collide_with_bodies = true
	var excluded: Array[RID] = [get_rid()]
	params.exclude = excluded
	var result := world.direct_space_state.cast_motion(params)
	if result.is_empty():
		return 1.0
	var safe := clampf(result[0], 0.0, 1.0)
	if safe >= 1.0:
		return 1.0
	var length := motion.length()
	if length <= 0.0:
		return 0.0
	return maxf(0.0, safe - KNOCKBACK_SKIN_M / length)


func _finish_knockback() -> void:
	_knockback_active = false
	if not is_instance_valid(self):
		return
	# The base teleport resets the agent and the stuck detector without moving
	# the home point (that is `snap_to`'s exploration rule, not a shove's).
	super.snap_to(global_position)


## The navmesh point nearest `point`, or `point` itself while the map is not up
## (map_get_closest_point answers the origin before the first sync) or when the
## nearest point is farther than `max_shift` metres.
func _clamp_to_navmesh(point: Vector3, max_shift: float) -> Vector3:
	var on_mesh := _closest_navigation_point(point)
	if GroundMath.ground_distance(on_mesh, point) > max_shift:
		return GroundMath.flatten(point)
	return GroundMath.flatten(on_mesh)


# --- Death -------------------------------------------------------------------------

## Death is a short beat, not a pop: flash, topple, dissolve, then loot spills out
## of the corpse. `is_alive()` is already false from the first frame (the base sets
## it before calling this), so combat logic stops counting us while it plays.
## Deliberately does not call `super`, which would only hide the body.
func _on_died() -> void:
	if _dying:
		return
	_dying = true
	_stop_locomotion()
	set_hover_highlighted(false)
	_cancel_counter_on_target(_target)
	_hide_counter_prompt()
	_statuses.clear()
	_skipping_turn = false
	_update_status_display()
	if _knockback_tween != null and _knockback_tween.is_valid():
		_knockback_tween.kill()
	_knockback_active = false
	_update_detection_ring()
	if _bars != null:
		_bars.set_visible_bars(false)
	set_deferred("collision_mask", 0)

	get_tree().call_group("player", "add_experience", experience_reward)
	CombatFx.popup_text(global_position + POPUP_XP_OFFSET, "+%d XP" % experience_reward,
		CombatFx.COLOR_XP, 18)
	CombatFx.shake(5.0, 0.18)

	if _model == null:
		_finish_death()
		return

	# Topple about the model's local X: the body faces its target, so tipping the
	# top toward +Z drops it backwards, away from whoever killed it.
	_flash_model(DEATH_FLASH_TINT, DEATH_FADE_SECONDS)
	var topple := _death_topple_seconds()
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(_model, "rotation:x", _model.rotation.x + PI * 0.5, topple) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.tween_property(_model, "scale", _model_idle_scale * Vector3(1.05, 0.8, 1.05), topple)
	# A mesh cannot be faded through material_overlay (an overlay only adds), so
	# the 2D alpha fade is a collapse to nothing instead.
	tween.chain().tween_property(_model, "scale", Vector3(0.001, 0.001, 0.001), DEATH_FADE_SECONDS)
	tween.chain().tween_callback(_finish_death)


## Virtual: how long the death topple lasts (the boss falls slower).
func _death_topple_seconds() -> float:
	return DEATH_SECONDS


func _finish_death() -> void:
	if not is_instance_valid(self):
		return
	# Drop before freeing: LootDropper reads our position and parent, and spawns
	# the pickups as siblings so they outlive us.
	_drop_loot()
	queue_free()


func _drop_loot() -> void:
	var drops: Array[Item] = []
	for item in loot_items:
		if item != null:
			drops.append(item)

	if drops.is_empty() and randf() < loot_drop_chance:
		drops.append(ItemFactory.create_random_loot())

	LootDropper.drop_items(self, drops, loot_drop_spread)


# --- Statuses (docs/gameplay-expansion.md section 2) ------------------------------

## Adds or refreshes a status: keeps the longer duration and the higher power.
## Durations count this enemy's own turns and drop at its `end_turn`, so a
## status applied during its own turn gets one extra turn (the current one does
## not count). A root or a stun landing mid-turn also stops the walk at once.
func apply_status(status: StringName, turns: int, power: int = 0) -> void:
	if turns <= 0 or not is_alive() or _dying:
		return
	var stored_turns := turns + (1 if is_turn_active() else 0)
	var entry: Dictionary = _statuses.get(status, {"turns": 0, "power": 0})
	var was_active := int(entry.get("turns", 0)) > 0
	entry["turns"] = maxi(int(entry.get("turns", 0)), stored_turns)
	entry["power"] = maxi(int(entry.get("power", 0)), power)
	_statuses[status] = entry
	_announce_status(status, was_active)
	if (status == STATUS_ROOT or status == STATUS_STUN) and is_turn_active():
		stop_movement_immediately()
		_turn_move_left = 0.0
		if status == STATUS_STUN:
			_turn_attack_available = false
	if status == STATUS_ROOT:
		_update_root_visual()
	_update_status_display()


func has_status(status: StringName) -> bool:
	return get_status_turns(status) > 0


func get_status_turns(status: StringName) -> int:
	if not _statuses.has(status):
		return 0
	var entry: Dictionary = _statuses[status]
	return int(entry.get("turns", 0))


func get_status_power(status: StringName) -> int:
	if not _statuses.has(status):
		return 0
	var entry: Dictionary = _statuses[status]
	return int(entry.get("power", 0))


## status id -> {turns, power}, a copy.
func get_statuses() -> Dictionary:
	return _statuses.duplicate(true)


## The text of the status line under the bar (`STUN 1  POISON 2`), empty
## without statuses.
func get_status_text() -> String:
	var parts: PackedStringArray = []
	for status in STATUS_ORDER:
		if has_status(status):
			parts.append("%s %d" % [String(status).to_upper(), get_status_turns(status)])
	for status: StringName in _statuses.keys():
		if not STATUS_ORDER.has(status) and has_status(status):
			parts.append("%s %d" % [String(status).to_upper(), get_status_turns(status)])
	return "  ".join(parts)


## True during a turn a stun is skipping.
func is_skipping_turn() -> bool:
	return _skipping_turn


func _announce_status(status: StringName, was_active: bool) -> void:
	var at := global_position + POPUP_STATUS_OFFSET
	match status:
		STATUS_ROOT:
			CombatFx.popup_text(global_position + POPUP_ROOT_OFFSET, "ROOTED", ROOT_COLOR, 16)
			_flash_model(ROOT_FLASH_COLOR, 0.25)
			CombatFx.ring_burst(self, global_position + Vector3(0.0, 0.03, 0.0), ROOT_COLOR,
				ROOT_BURST_START_PX, ROOT_BURST_END_PX, 0.3)
		STATUS_STUN:
			if not was_active:
				CombatFx.popup_text(at, "STUNNED", STUN_COLOR, 16)
				_flash_model(Color(1.6, 1.5, 0.6, 1.0), 0.2)
		STATUS_POISON:
			if not was_active:
				CombatFx.popup_text(at, "POISONED", POISON_COLOR, 15)
		STATUS_BURN:
			if not was_active:
				CombatFx.popup_text(at, "BURNING", BURN_COLOR, 15)
				_flash_model(Color(1.8, 0.9, 0.3, 1.0), 0.2)
		STATUS_WEAKEN:
			if not was_active:
				CombatFx.popup_text(at, "WEAKENED", WEAKEN_COLOR, 15)
		STATUS_EXPOSE:
			if not was_active:
				CombatFx.popup_text(at, "EXPOSED", EXPOSE_COLOR, 15)


## Poison and burn: `power` damage each at the start of this enemy's turn, in
## their own colours. Either can kill.
func _tick_damage_statuses() -> void:
	for pair: Array in [[STATUS_POISON, POISON_COLOR], [STATUS_BURN, BURN_COLOR]]:
		if not is_alive():
			return
		var status: StringName = pair[0]
		var power := get_status_power(status)
		if has_status(status) and power > 0:
			_take_status_tick(power, pair[1])


func _take_status_tick(amount: int, color: Color) -> void:
	_status_tick_hit = true
	_hit_popup_color = color
	_take_hit(amount)
	_status_tick_hit = false
	_hit_popup_color = CombatFx.COLOR_DAMAGE_DEALT


## One turn passes for every status; spent ones are removed.
func _tick_down_statuses() -> void:
	if _statuses.is_empty():
		return
	for status: StringName in _statuses.keys():
		var entry: Dictionary = _statuses[status]
		var turns := int(entry.get("turns", 0)) - 1
		if turns <= 0:
			_statuses.erase(status)
		else:
			entry["turns"] = turns
	_update_root_visual()
	_update_status_display()


func _clear_statuses() -> void:
	_statuses.clear()
	_skipping_turn = false
	_update_root_visual()
	_update_status_display()


func _update_status_display() -> void:
	if _status_line != null:
		_status_line.set_text(get_status_text() if is_alive() and not _dying else "")


# --- Root (Frost Snare) -------------------------------------------------------------

## Pins the enemy for `turns` of its own turns: it keeps its attack but loses its
## movement. Rooting an already rooted enemy keeps the longer of the two. Maps
## onto the `root` status.
func apply_root(turns: int) -> void:
	apply_status(STATUS_ROOT, turns)


func is_rooted() -> bool:
	return has_status(STATUS_ROOT)


func _update_root_visual() -> void:
	if _root_ring == null:
		return
	if is_rooted() and is_alive():
		_root_ring.show_ring(ROOT_RING_RADIUS_M, ROOT_COLOR)
		return
	_root_ring.hide_ring()


# --- Turn resources ------------------------------------------------------------------

func set_turn_based_combat(enabled: bool) -> void:
	super(enabled)
	if enabled:
		_leave_calm()
	else:
		_clear_statuses()
		# The fight is over; whoever is left goes back to watching (WP13), and a
		# survivor that was pulled away from its post walks home.
		_aggroed = false
		_leave_calm()
		if is_alive() and _home_recorded and is_inside_tree() \
				and GroundMath.ground_distance(global_position, _home_position) > HOME_RETURN_MIN_M:
			_start_calm_walk(_home_position, CalmState.HOME)
	_update_detection_ring()


## Poison and burn tick first (and may kill). A stunned enemy skips the turn
## (no movement, no attack); a rooted one keeps its attack but goes nowhere.
## `turn_move_override_m` replaces the coordinator's budget when set.
func start_turn(max_move_meters: float = 6.0) -> void:
	var budget := turn_move_override_m if turn_move_override_m > 0.0 else max_move_meters
	var stunned := has_status(STATUS_STUN)
	var rooted := is_rooted()
	super(0.0 if stunned or rooted else budget)
	_skipping_turn = stunned
	_tick_damage_statuses()
	if not is_alive():
		_turn_move_left = 0.0
		_turn_attack_available = false
		return
	if stunned:
		_turn_attack_available = false
		CombatFx.popup_text(global_position + POPUP_ROOTED_TURN_OFFSET, "STUNNED", STUN_COLOR, 16)
	elif rooted:
		CombatFx.popup_text(global_position + POPUP_ROOTED_TURN_OFFSET, "Rooted", ROOT_COLOR, 14)


## Statuses lose a turn only at the end of this enemy's own turn: the
## coordinator also calls `end_turn` on everyone when a fight starts, and that
## must not eat a status.
func end_turn() -> void:
	var was_own_turn := is_turn_active()
	super()
	_skipping_turn = false
	if was_own_turn:
		_tick_down_statuses()


# --- Hover highlight --------------------------------------------------------------------

## The 2D hover outline, as a faint additive rim over the model's meshes. HitFlash3D
## saves and restores whatever overlay it finds, so the two compose.
func set_hover_highlighted(enabled: bool) -> void:
	if _hover_highlighted == enabled:
		return
	_hover_highlighted = enabled
	var overlay: Material = _hover_overlay if enabled else null
	for mesh in _model_meshes:
		if is_instance_valid(mesh):
			mesh.material_overlay = overlay


func is_hover_highlighted() -> bool:
	return _hover_highlighted


# --- Locomotion clips (WP12) -----------------------------------------------------------
# The wolf's glb carries a skeleton and two looping clips, `idle` (2.0 s) and
# `trot` (0.4 s, one full diagonal-gait cycle). The player's WP11 rule, mirrored:
# every physics frame the model plays `move_clip` (`trot` for the wolf, `walk`
# for a humanoid body) while the enemy moves faster than TROT_MIN_SPEED, its
# playback scaled by ground speed over `move_clip_reference_speed` so the
# planted feet keep pace with the ground, and `idle_clip` otherwise. The clips
# drive bones only; the attack lunge, the recoil and the topple tween `Model`
# and the tints ride on material overlays, so they all play on top. A model
# without an AnimationPlayer (the generic `enemy_3d.tscn` box) is left alone.

const LOCOMOTION_IDLE := &"idle"
const LOCOMOTION_TROT := &"trot"
## Ground distance the body covers in one trot cycle with the planted paws
## standing still: the paw sweeps 2 * 0.40 m * sin(28 deg) = 0.376 m back over
## its half-cycle stance, and the other diagonal pair carries the body the other
## half. Measured on the posed rig by `tools/blender/generate_wolf.py`
## (`SF_TROT stride_per_cycle`, docs/deviations/wp12.md).
const TROT_STRIDE_PER_CYCLE_M := 0.7512
## Length of the `trot` clip (24 frames at 60 fps).
const TROT_CLIP_SECONDS := 0.4
## Ground speed (m/s) at which `trot` plays at 1.0x without the paws sliding;
## the wolf's 3.6 m/s chase plays it at about 1.92x. `move_clip_reference_speed`
## defaults to this value.
const TROT_REFERENCE_SPEED := TROT_STRIDE_PER_CYCLE_M / TROT_CLIP_SECONDS
## A humanoid body's `walk` at scale 1 (Player3D.WALK_REFERENCE_SPEED).
const WALK_REFERENCE_SPEED := 1.92
## Below this ground speed the model idles.
const TROT_MIN_SPEED := 0.2
## A trot survives this long without speed (an avoidance frame that has not
## answered yet, a chase re-aimed at a moved target), so it never flickers.
const TROT_GRACE_SECONDS := 0.12
const TROT_SPEED_SCALE_MIN := 0.25
const TROT_SPEED_SCALE_MAX := 3.0
## Cross-fade between idle and trot.
const LOCOMOTION_BLEND_SECONDS := 0.15

var _anim_player: AnimationPlayer = null
var _locomotion_state: StringName = &""
var _locomotion_speed_scale := 1.0
var _trot_grace_left := 0.0


## The locomotion clip the model is playing (`idle_clip` or `move_clip`), or
## empty without a rig, before the first physics frame and from the moment of
## death.
func get_locomotion_state() -> StringName:
	return _locomotion_state


## The AnimationPlayer found under `Model`, or null for an unrigged model.
func get_animation_player() -> AnimationPlayer:
	return _anim_player


## Finds the AnimationPlayer anywhere under `Model` and makes both clips loop
## (the import settings already do; this covers a re-import without them). The
## clips advance in physics steps, in lockstep with the body's movement, so a
## planted paw does not jitter by a frame of travel (6 cm at 3.6 m/s).
func _setup_locomotion() -> void:
	_anim_player = null
	if _model == null:
		return
	var found := _model.find_children("*", "AnimationPlayer", true, false)
	if found.is_empty():
		return
	_anim_player = found[0] as AnimationPlayer
	_anim_player.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_PHYSICS
	for clip in [idle_clip, move_clip]:
		if not _anim_player.has_animation(clip):
			push_warning("%s: the model's AnimationPlayer has no '%s' animation" % [name, clip])
			continue
		var anim := _anim_player.get_animation(clip)
		if anim.loop_mode == Animation.LOOP_NONE:
			anim.loop_mode = Animation.LOOP_LINEAR


func _update_locomotion_animation(delta: float) -> void:
	if _anim_player == null or _dying or not is_alive():
		return
	var ground_speed := Vector2(velocity.x, velocity.z).length()
	var wanted := idle_clip
	var speed_scale := 1.0
	if is_moving() and ground_speed > TROT_MIN_SPEED:
		wanted = move_clip
		_trot_grace_left = TROT_GRACE_SECONDS
		speed_scale = clampf(ground_speed / maxf(move_clip_reference_speed, 0.01),
			TROT_SPEED_SCALE_MIN, TROT_SPEED_SCALE_MAX)
	elif _locomotion_state == move_clip and _trot_grace_left > 0.0:
		wanted = move_clip
		_trot_grace_left -= delta
		speed_scale = _locomotion_speed_scale
	_play_locomotion(wanted, speed_scale)


## Plays `clip` looping at `speed_scale`, cross-fading from the other clip; a
## clip that is already playing only takes the new speed.
func _play_locomotion(clip: StringName, speed_scale: float) -> void:
	if _anim_player == null or not _anim_player.has_animation(clip):
		return
	_locomotion_state = clip
	_locomotion_speed_scale = speed_scale
	_anim_player.speed_scale = speed_scale
	if StringName(_anim_player.current_animation) != clip or not _anim_player.is_playing():
		_anim_player.play(clip, LOCOMOTION_BLEND_SECONDS)


## Death: the topple owns the body from here, so the clip freezes where it is.
func _stop_locomotion() -> void:
	_locomotion_state = &""
	_trot_grace_left = 0.0
	if _anim_player != null:
		_anim_player.pause()


# --- Children ------------------------------------------------------------------------------

func _setup_model() -> void:
	_model = get_node_or_null("Model") as Node3D
	if _model == null:
		push_error("%s: Enemy3D needs a Node3D child named 'Model' holding the visible body." % name)
		return
	_model_idle_position = _model.position
	_model_idle_scale = _model.scale
	_model_meshes.clear()
	_gather_meshes(_model)
	_apply_model_tint()
	_setup_locomotion()

	_hover_overlay = StandardMaterial3D.new()
	_hover_overlay.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_hover_overlay.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_hover_overlay.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	_hover_overlay.cull_mode = BaseMaterial3D.CULL_BACK
	_hover_overlay.albedo_color = HOVER_TINT


func _gather_meshes(node: Node) -> void:
	for child in node.get_children():
		if child is MeshInstance3D:
			_model_meshes.append(child as MeshInstance3D)
		_gather_meshes(child)


## The meshes under `Model`, for subclasses that dress the body (the boss's
## glowing sword).
func get_model_meshes() -> Array[MeshInstance3D]:
	return _model_meshes


## `model_tint` on every surface under `Model`: each active material is
## duplicated into a surface override with its albedo multiplied, so the
## imported glb and every other enemy sharing it stay untouched. White (the
## default) does nothing.
func _apply_model_tint() -> void:
	if model_tint.is_equal_approx(Color.WHITE):
		return
	for mesh in _model_meshes:
		if mesh == null or mesh.mesh == null:
			continue
		for surface in range(mesh.mesh.get_surface_count()):
			var material := mesh.get_active_material(surface) as BaseMaterial3D
			if material == null:
				continue
			var tinted := material.duplicate() as BaseMaterial3D
			tinted.albedo_color = material.albedo_color * model_tint
			mesh.set_surface_override_material(surface, tinted)


func _flash_model(color: Color, duration: float) -> void:
	if _model == null or not is_inside_tree():
		return
	HitFlash3D.flash_node(_model, color, duration)


func _setup_overhead_bars() -> void:
	if overhead_anchor == null:
		return
	_bars = OverheadBars3D.new()
	_bars.name = "OverheadBars"
	_bars.fill_color = OverheadBars3D.COLOR_FILL_ENEMY
	_bars.ghost_color = OverheadBars3D.COLOR_GHOST_ENEMY
	overhead_anchor.add_child(_bars)


func _setup_status_line() -> void:
	if overhead_anchor == null:
		return
	_status_line = EnemyStatusLine3D.new()
	_status_line.name = "StatusLine"
	overhead_anchor.add_child(_status_line)


## The status line under the bar, for tests.
func get_status_line() -> EnemyStatusLine3D:
	return _status_line


func _update_health_bar() -> void:
	if _bars == null:
		return
	var ratio := 0.0
	if max_health > 0:
		ratio = clampf(float(health) / float(max_health), 0.0, 1.0)
	_bars.set_ratio(ratio)


func _setup_counter_prompt() -> void:
	if overhead_anchor == null:
		return
	_counter_prompt = CounterPrompt3D.new()
	_counter_prompt.name = "CounterPrompt"
	overhead_anchor.add_child(_counter_prompt)


func _setup_root_ring() -> void:
	_root_ring = RangeRing3D.new()
	_root_ring.name = "RootRing"
	add_child(_root_ring)
	_root_ring.hide_ring()


## The Frost Snare ring at the feet, for tests.
func get_root_ring() -> RangeRing3D:
	return _root_ring
