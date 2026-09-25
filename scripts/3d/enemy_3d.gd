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
## Contract: docs/3d-port-contracts.md, sections 5.1, 5.3, 7, 8.
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
## hit always provokes.
@export var detection_range := 4.0
@export var attack_wind_up_duration := 0.2
@export var attack_strike_duration := 0.12
@export var attack_recovery_duration := 0.2
## Turn mode uses a slower, clearly telegraphed swing: the wind-up is long enough
## to read and the strike (= the counter window) is wide enough to hit on purpose.
## Realtime keeps the snappier values above.
@export var turn_attack_wind_up_duration := 0.55
@export var turn_attack_strike_duration := 0.18

## Emitted once per hit that lands while this enemy is not in turn mode (WP13).
## The coordinator answers by starting combat as an ambush: the hit has already
## resolved (health changed, and `_die` follows this signal when it was lethal),
## then the enemies get the first turn.
signal provoked_by_hit

## Detection (WP13). The ring is a RangeRing3D child at `detection_range`,
## shown while the enemy is alive, calm and out of turn mode: a faint dashed
## circle that turns warning red once the player is within
## DETECTION_WARNING_MARGIN_M of its edge.
const DETECTION_RING_COLOR_CALM := Color(0.55, 0.75, 0.95, 0.30)
const DETECTION_RING_COLOR_WARNING := Color(1.0, 0.30, 0.25, 0.75)
const DETECTION_WARNING_MARGIN_M := 1.5
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

var current_health: int:
	get:
		return health

var _model: Node3D = null
var _model_meshes: Array[MeshInstance3D] = []
var _model_idle_position := Vector3.ZERO
var _model_idle_scale := Vector3.ONE
var _counter_prompt: CounterPrompt3D = null
var _bars: OverheadBars3D = null
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
## Turns of its own this enemy still spends unable to move (the mage's Frost
## Snare). It keeps its attack; it just goes nowhere.
var _rooted_turns := 0


func _ready() -> void:
	super()
	add_to_group("enemies")
	_setup_model()
	_setup_overhead_bars()
	_setup_counter_prompt()
	_setup_root_ring()
	_setup_detection_ring()
	_update_health_bar()


func _process(_delta: float) -> void:
	_update_detection_ring()


# --- Realtime AI ------------------------------------------------------------------

## The 2D `_physics_process`, in the same order: turn mode just walks its path,
## realtime ticks the timers, gates on detection, refreshes the approach point
## and swings once the target is inside `attack_range`.
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
	if not is_alive():
		velocity = Vector3.ZERO
		return

	if is_in_turn_based_combat():
		super(delta)
		return

	_attack_cooldown_left = maxf(0.0, _attack_cooldown_left - delta)
	_target_refresh_left -= delta

	var target := _live_target()
	if target == null:
		_halt()
		return

	# Watchers hold still until the player is spotted: inside the detection
	# ring and in view. A hit sets `_aggroed` directly.
	if not _aggroed:
		if not can_spot(target):
			_halt()
			return
		_aggroed = true

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


func set_target(target: Node3D) -> void:
	_target = target
	_refresh_target_position()


# --- Detection (WP13) ---------------------------------------------------------------

## The one rule for "spotted": alive on both sides, `target` on the ground
## within `detection_range` and nothing on the prop layer between the enemy's
## eyes and the target's chest. The coordinator asks this every frame in
## exploration to start combat; the realtime chase gates on it too, so the
## visible ring is exactly the rule.
func can_spot(target: Node3D) -> bool:
	if not is_alive() or _dying or detection_range <= 0.0:
		return false
	if target == null or not is_instance_valid(target):
		return false
	if target.has_method("is_alive") and not bool(target.call("is_alive")):
		return false
	if GroundMath.ground_distance(global_position, target.global_position) > detection_range:
		return false
	return has_line_of_sight_to(target)


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
## mode, once alerted, while dying and for an unaware enemy (range 0). Calm blue
## far from the player, warning red once the player is within
## DETECTION_WARNING_MARGIN_M of the edge. The ring mesh is only rebuilt when
## its state or radius changes.
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
	var wanted_state := DetectionRingState.CALM
	var target := _live_target()
	if target != null and GroundMath.ground_distance(global_position, target.global_position) \
			<= detection_range + DETECTION_WARNING_MARGIN_M:
		wanted_state = DetectionRingState.WARNING
	if wanted_state == _detection_ring_state and is_equal_approx(_detection_ring_radius, detection_range):
		return
	var ring_color := DETECTION_RING_COLOR_WARNING if wanted_state == DetectionRingState.WARNING \
		else DETECTION_RING_COLOR_CALM
	_detection_ring.show_ring(detection_range, ring_color, true)
	_detection_ring_state = wanted_state
	_detection_ring_radius = detection_range


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
## The lunge is a tween on `Model`'s local position along the facing (-Z); the
## tint rides on HitFlash3D so it composes with the hit flash and the hover rim.
func _run_attack_sequence_full() -> void:
	var target := _target
	if target == null or not is_instance_valid(target):
		return

	_attack_sequence_active = true
	var wind_up := turn_attack_wind_up_duration if is_in_turn_based_combat() else attack_wind_up_duration
	var strike := turn_attack_strike_duration if is_in_turn_based_combat() else attack_strike_duration
	var can_be_countered := target.has_method("begin_enemy_counter_windup")
	if can_be_countered:
		target.call("begin_enemy_counter_windup", self, attack_damage)
		if _counter_prompt != null:
			# Tell the player what the press will do as whoever is in control.
			if target.has_method("get_reaction_hint"):
				var hint: Dictionary = target.call("get_reaction_hint")
				var hint_color: Color = hint.get("color", CounterPrompt3D.COLOR_TARGET)
				_counter_prompt.set_hint(String(hint.get("text", "")), hint_color)
			_counter_prompt.start_windup(wind_up)
			_counter_prompt_shown = true

	face_toward(target.global_position)

	# 1) Wind-up - telegraph only, no damage.
	_flash_model(WIND_UP_TINT, wind_up)
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(_model, "position", _model_idle_position + Vector3(0.0, 0.0, WIND_UP_PULL_M), wind_up) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(_model, "scale", _model_idle_scale * WIND_UP_SCALE, wind_up)
	await tween.finished

	if not is_instance_valid(self) or not is_alive():
		_cancel_counter_on_target(target)
		_hide_counter_prompt()
		_attack_sequence_active = false
		return
	if not is_instance_valid(target) or GroundMath.ground_distance(global_position, target.global_position) \
			> attack_range * ATTACK_BREAK_FACTOR:
		_cancel_counter_on_target(target)
		_hide_counter_prompt()
		_reset_attack_model_pose()
		_attack_sequence_active = false
		if not is_in_turn_based_combat():
			_attack_cooldown_left = attack_cooldown * 0.35
		return

	# 2) Strike - the counter window; damage resolves after the lunge.
	if target.has_method("begin_enemy_counter_strike"):
		target.call("begin_enemy_counter_strike")
	if can_be_countered and _counter_prompt != null:
		_counter_prompt.start_strike(strike)

	_flash_model(STRIKE_TINT, maxf(strike * 0.45, 0.01))
	tween = create_tween()
	tween.set_parallel(true)
	tween.tween_property(_model, "position", _model_idle_position + Vector3(0.0, 0.0, -LUNGE_M), strike) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.tween_property(_model, "scale", _model_idle_scale * STRIKE_SCALE, strike)
	await tween.finished

	if not is_instance_valid(self):
		_cancel_counter_on_target(target)
		_attack_sequence_active = false
		return

	if is_instance_valid(target):
		if target.has_method("resolve_enemy_attack"):
			var countered := bool(target.call("resolve_enemy_attack", self, attack_damage))
			if _counter_prompt != null:
				_counter_prompt.show_result(countered)
		elif target.has_method("receive_damage"):
			target.call("receive_damage", attack_damage)
			_hide_counter_prompt()
	else:
		_hide_counter_prompt()

	# 3) Recovery - after damage, return to neutral.
	tween = create_tween()
	tween.set_parallel(true)
	tween.tween_property(_model, "position", _model_idle_position, attack_recovery_duration) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(_model, "scale", _model_idle_scale, attack_recovery_duration)
	await tween.finished

	_attack_sequence_active = false
	if not is_in_turn_based_combat():
		_attack_cooldown_left = attack_cooldown


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

## A hit always provokes, exactly as in 2D. The base subtracts what this returns.
func _apply_damage(amount: int) -> int:
	var applied := maxi(0, amount)
	_last_applied_damage = applied
	if applied > 0:
		_aggroed = true
	return applied


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
		if not is_in_turn_based_combat():
			provoked_by_hit.emit()


func _play_hit_feedback(amount: int) -> void:
	CombatFx.popup_damage(global_position + POPUP_DAMAGE_OFFSET, amount, CombatFx.COLOR_DAMAGE_DEALT)
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
	if _root_ring != null:
		_root_ring.hide_ring()
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
	var tween := create_tween()
	tween.set_parallel(true)
	tween.tween_property(_model, "rotation:x", _model.rotation.x + PI * 0.5, DEATH_SECONDS) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.tween_property(_model, "scale", _model_idle_scale * Vector3(1.05, 0.8, 1.05), DEATH_SECONDS)
	# A mesh cannot be faded through material_overlay (an overlay only adds), so
	# the 2D alpha fade is a collapse to nothing instead.
	tween.chain().tween_property(_model, "scale", Vector3(0.001, 0.001, 0.001), DEATH_FADE_SECONDS)
	tween.chain().tween_callback(_finish_death)


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


# --- Root (Frost Snare) -------------------------------------------------------------

## Pins the enemy for `turns` of its own turns: it keeps its attack but loses its
## movement. Rooting an already rooted enemy keeps the longer of the two.
func apply_root(turns: int) -> void:
	if turns <= 0 or not is_alive():
		return
	_rooted_turns = maxi(_rooted_turns, turns)
	_update_root_visual()
	CombatFx.popup_text(global_position + POPUP_ROOT_OFFSET, "ROOTED", ROOT_COLOR, 16)
	_flash_model(ROOT_FLASH_COLOR, 0.25)
	CombatFx.ring_burst(self, global_position + Vector3(0.0, 0.03, 0.0), ROOT_COLOR,
		ROOT_BURST_START_PX, ROOT_BURST_END_PX, 0.3)


func is_rooted() -> bool:
	return _rooted_turns > 0


func _update_root_visual() -> void:
	if _root_ring == null:
		return
	if _rooted_turns > 0:
		_root_ring.show_ring(ROOT_RING_RADIUS_M, ROOT_COLOR)
		return
	_root_ring.hide_ring()


# --- Turn resources ------------------------------------------------------------------

func set_turn_based_combat(enabled: bool) -> void:
	super(enabled)
	if not enabled:
		_rooted_turns = 0
		_update_root_visual()
		# The fight is over; whoever is left goes back to watching (WP13). Under
		# the coordinator that is only ever an enemy that was never engaged.
		_aggroed = false
	_update_detection_ring()


## A rooted enemy keeps its attack but goes nowhere this turn.
func start_turn(max_move_meters: float = 6.0) -> void:
	super(0.0 if _rooted_turns > 0 else max_move_meters)
	if _rooted_turns > 0:
		CombatFx.popup_text(global_position + POPUP_ROOTED_TURN_OFFSET, "Rooted", ROOT_COLOR, 14)


func end_turn() -> void:
	super()
	# The root is spent by the turn it cost; the ice melts once that turn ends.
	if _rooted_turns > 0:
		_rooted_turns -= 1
		_update_root_visual()


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
# every physics frame the model plays `trot` while the enemy moves faster than
# TROT_MIN_SPEED, its playback scaled by ground speed so the planted paws keep
# pace with the ground, and `idle` otherwise. The clips drive bones only; the
# attack lunge, the recoil and the topple tween `Model` and the tints ride on
# material overlays, so they all play on top. A model without an
# AnimationPlayer (the generic `enemy_3d.tscn` box) is left alone.

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
## the wolf's 3.6 m/s chase plays it at about 1.92x.
const TROT_REFERENCE_SPEED := TROT_STRIDE_PER_CYCLE_M / TROT_CLIP_SECONDS
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


## The locomotion clip the model is playing (`idle`, `trot`), or empty without
## a rig, before the first physics frame and from the moment of death.
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
	for clip in [LOCOMOTION_IDLE, LOCOMOTION_TROT]:
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
	var wanted := LOCOMOTION_IDLE
	var speed_scale := 1.0
	if is_moving() and ground_speed > TROT_MIN_SPEED:
		wanted = LOCOMOTION_TROT
		_trot_grace_left = TROT_GRACE_SECONDS
		speed_scale = clampf(ground_speed / TROT_REFERENCE_SPEED, TROT_SPEED_SCALE_MIN, TROT_SPEED_SCALE_MAX)
	elif _locomotion_state == LOCOMOTION_TROT and _trot_grace_left > 0.0:
		wanted = LOCOMOTION_TROT
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
