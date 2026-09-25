class_name Player3D
extends ActorBase3D

## The player, ported method by method from scripts/player.gd (WP3b). The rules
## are the 2D rules: three souls in one body, one shift per turn, the block
## stance, the counter window with its three reactions, melee with the contact
## delay, the rogue's travelling bolt, the two mage spells, XP and levels, and
## the inventory with its auto-equipped Iron Sword.
##
## What ActorBase3D already owns is not repeated here: navmesh movement, the
## turn budget, `health` and death. Incoming hits are scaled in `_apply_damage`
## (soul defence, then the block stance); outgoing melee damage comes from
## `_outgoing_damage`. Contract: docs/3d-port-contracts.md, sections 5.1 and 5.2.
##
## Units are metres and every world position is a Vector3 on the ground plane.
## Item ranges and grip offsets are still authored in 2D pixels on `Item`; they
## are converted with WEAPON_RANGE_METERS_PER_PIXEL so the iron sword reaches the
## contract's 1.2 m. The body never flips: facing is `rotation.y`.
##
## Scene children (scenes/3d/player_3d.tscn): CollisionShape3D, NavigationAgent3D,
## OverheadAnchor, Model (SoulBodies3D with the knight, rogue and mage bodies;
## WP9), HandPoint with EquippedWeaponHolder and EquippedWeaponMesh, VisionLight,
## Inventory. The attack AnimationPlayer, the overhead bars and the block ring
## are built in code.

# Base class exports keep their 2D names: move_speed (3.5 m/s), max_health,
# attack_damage, attack_range (1.2 m).
# How far inside the melee reach the walk-up aims (the 2D value was 20 px). The
# base class's approach rule floors this at the two collision surfaces plus a
# gap, so against a wolf the floor wins (WP10).
@export var attack_approach_buffer := 0.4
@export var attack_cooldown := 0.35
@export var attack_animation_speed_scale := 1.6
@export var target_refresh_interval := 0.2
@export var attack_action_name := "attack"
@export var counter_action_name := "counter"
# Seconds between the swing starting and the blade connecting. Lines damage up
# with the contact frame of the attack instead of frame zero, so the enemy
# reacts when the sword arrives rather than when the arm starts.
@export var melee_hit_delay := 0.10
# Metres per second for the ranged bolt; the shot lands when it arrives. The 2D
# value was 900 px/s at 64 px to the metre.
@export var ranged_bolt_speed := 14.0
# Shown on the inventory screen's character strip. Follows the active soul.
@export var character_name := "Sir Arthur"
# Carried coin. Nothing grants gold yet - the field exists so the inventory
# screen reads a real value rather than a hardcoded one.
@export var gold := 0

const XP_BASE_TO_LEVEL_2 := 100.0
const XP_PER_LEVEL_MULT := 1.5

# --- The Bound Three ---------------------------------------------------------
# Three souls share this one body (see soul.gd). Shifting between them is free
# while exploring; in turn combat it is one shift per turn, refreshed when the
# player's turn starts. A perfect reaction - block, parry or ward pressed on the
# beat - builds Resonance: one extra shift on the next turn.
signal soul_changed(soul: Soul)

const SHIFT_ACTIONS: Array[String] = ["shift_soul_1", "shift_soul_2", "shift_soul_3"]
const SHIFT_CYCLE_ACTION := "shift_soul_cycle"
const SHIFT_KEYS: Array[int] = [KEY_1, KEY_2, KEY_3]
const SHIFT_CYCLE_KEY := KEY_Q
const SHIFTS_PER_TURN := 1
const PERFECT_REACTION_GRANTS_EXTRA_SHIFT := true
const SHIFT_LIGHT_BLEND_SECONDS := 0.35
# Used for spell radii until the coordinator reports the map's meter scale. In
# 3D one world unit is one metre, so the coordinator sends 1.0.
const DEFAULT_METER_WORLD_UNITS := GroundMath.METER_WORLD_UNITS

# --- Pixel to metre conversions ----------------------------------------------
# Items are authored in 2D pixels (Item.weapon_range, grip_offset). One
# constant converts every weapon-related pixel value so the iron sword's 40 px
# reach is the contract's 1.2 m and a dagger stays proportionally shorter. The
# same scale is used for the hand offsets in the archetype animations and for
# the small body lunges, so the whole "weapon and arm" layer is one scale.
const WEAPON_RANGE_METERS_PER_PIXEL := 1.2 / 40.0
# Fallback for a Model that is not a SoulBodies3D: the held weapon mesh hangs
# point-down from the hand (WP1 sword convention: a 180 degree X rotation on
# the object whose blade runs along local +Y) and the item's grip_rotation_deg
# is added on the same axis. With the soul bodies the hang and the grip come
# from the active soul's model instead (SoulBodies3D.get_weapon_fit).
const WEAPON_HANG_ROTATION_DEG := 180.0
# The holder rests at the hand point's origin; archetype animations move it
# around this. The 2D WEAPON_HAND_POINT became the HandPoint node's transform.
const HOLDER_REST_POSITION := Vector3.ZERO
const WEAPON_MESH_SIZE := Vector3(0.06, 0.8, 0.02)
const WEAPON_MESH_COLOR := Color(0.78, 0.8, 0.84, 1.0)
# Where the placeholder hand sits when the scene has no HandPoint of its own.
const DEFAULT_HAND_POINT := Vector3(0.34, 0.85, -0.08)
const MANUAL_PATH_ARRIVE_M := 0.1
# Height of the exploration sweep sphere and of the bolt endpoints.
const SWEEP_HEIGHT_M := 0.9
const BOLT_TARGET_HEIGHT_M := 0.9
const BOLT_FLIGHT_MIN_SECONDS := 0.08
const BOLT_FLIGHT_MAX_SECONDS := 0.4
const BOLT_MAX_TAIL_M := 0.66
const BOLT_THICKNESS_M := 0.05
# Popup anchors: the 2D offsets were -44 px (damage), -62 to -70 px (reaction
# words, shift title, level up) and -84 px (resonance) above the feet. Here they
# sit above the 2.15 m OverheadAnchor.
const POPUP_HEIGHT_M := 2.1
const POPUP_HEIGHT_HIGH_M := 2.4
const POPUP_HEIGHT_TOP_M := 2.7
# Block ring at the feet: just outside the 0.35 m capsule. The 2D aura was a
# flattened ellipse; the camera pitch flattens the 3D circle the same way.
const BLOCK_RING_RADIUS_M := 0.55
const BLOCK_RING_COLOR := Color(0.62, 0.82, 1.0, 0.85)
# CombatFx.ring_burst draws on the FX CanvasLayer in screen pixels in 3D, while
# the 2D radii were world pixels seen through a 3.35x camera. Same knob as the
# WP5 overlays' SCREEN_SCALE.
const FX_SCREEN_SCALE := 3.35
const FALLBACK_SCREEN_PX_PER_METER := 64.0
const XP_BAR_OFFSET_M := 0.28
const LEVEL_LABEL_OFFSET_M := 0.6
const XP_BAR_COLOR := Color(0.55, 0.45, 0.95, 1.0)
const LEVEL_LABEL_COLOR := Color(0.95, 0.88, 0.65, 1.0)

const COUNTER_PHASE_NONE := 0
const COUNTER_PHASE_WINDUP := 1
const COUNTER_PHASE_STRIKE := 2

var attack_cooldown_left := 0.0
var attack_target: Node3D = null
var target_refresh_left := 0.0
var blocking_active := false
var inventory: Inventory = null
var model: Node3D = null
# `Model` when it carries the three soul bodies (WP9); null for a placeholder.
var soul_bodies: SoulBodies3D = null
var model_idle_position := Vector3.ZERO
var hand_point: Node3D = null
var vision_light: OmniLight3D = null
var equipped_weapon_holder: Node3D = null
var equipped_weapon_mesh: MeshInstance3D = null
var attack_animation_player: AnimationPlayer = null
var health_bars: OverheadBars3D = null
var xp_bars: OverheadBars3D = null
var level_label: Label3D = null
var block_ring: RangeRing3D = null
var player_level := 1
var experience_points := 0.0
var souls: Array[Soul] = []
var active_soul: Soul = null
var shifts_left_this_turn := 0
var _resonance_pending := false
# Spell id -> player turns until that spell is ready again.
var spell_cooldowns: Dictionary = {}
var _meter_world_units := DEFAULT_METER_WORLD_UNITS
var manual_path_points: Array[Vector3] = []
var manual_path_index := 0
var _counter_phase := COUNTER_PHASE_NONE
var _counter_early_pressed := false
var _counter_perfect_pressed := false
# Set by `_apply_damage` once it has flashed the body in the hit's own colour,
# so the base class's plain `flash_hit()` that follows does not flash twice.
var _hit_flash_handled := false
var _bar_health := -1


func _ready() -> void:
	super()
	_ensure_collision_shape()
	add_to_group("player")

	_ensure_attack_input()
	_ensure_counter_input()
	_ensure_shift_inputs()
	_setup_souls()

	model = get_node_or_null("Model") as Node3D
	if model != null:
		model_idle_position = model.position
	hand_point = get_node_or_null("HandPoint") as Node3D
	vision_light = get_node_or_null("VisionLight") as OmniLight3D

	_setup_health_bar()
	_setup_level_and_xp_ui()
	_update_health_bar()
	_update_xp_bar()
	_update_level_label()

	_setup_body_visuals()
	_setup_block_aura()
	_setup_inventory()


func _process(_delta: float) -> void:
	# The base class writes `health` directly, so the bar follows it from here.
	if health != _bar_health:
		_update_health_bar()


func _unhandled_input(event: InputEvent) -> void:
	if _counter_phase != COUNTER_PHASE_NONE and event.is_action_pressed(counter_action_name):
		_register_counter_press()
		get_viewport().set_input_as_handled()
		return
	if _turn_mode:
		return
	# Shifting is free while exploring. In turn combat the same keys go through
	# the coordinator, which knows whether an action is mid-flight.
	var wanted_kind := shift_kind_from_event(event)
	if wanted_kind >= 0:
		shift_to(wanted_kind)
		get_viewport().set_input_as_handled()
		return
	if event.is_action_pressed(attack_action_name):
		_try_attack()


## Replaces the base step with the 2D order: stuck check, manual path, then in
## exploration the click-to-attack pursuit, else the navmesh step from the base.
func _physics_process(delta: float) -> void:
	_update_locomotion_animation(delta)
	if navigation_agent == null:
		return
	if not _alive:
		velocity = Vector3.ZERO
		return
	_check_stuck(delta)

	if _process_manual_path_movement():
		return

	if not _turn_mode:
		attack_cooldown_left = maxf(attack_cooldown_left - delta, 0.0)
		target_refresh_left -= delta
		if _pursue_attack_target():
			return

	_step_navigation()


## Exploration click-to-attack: walk to the approach point and swing once in
## reach. Returns true when it handled this frame (standing in range); false
## lets the navmesh step move the body toward the approach point.
func _pursue_attack_target() -> bool:
	if attack_target == null or not is_instance_valid(attack_target):
		return false
	if attack_target.has_method("is_alive") and not bool(attack_target.call("is_alive")):
		clear_attack_target()
		return false

	# In reach: stand and swing. The walk is parked, not re-aimed every refresh,
	# so nothing keeps nudging the body toward a point inside the enemy (WP10).
	if GroundMath.ground_distance(global_position, attack_target.global_position) <= get_melee_range():
		hold_position()
		_try_attack_target(attack_target)
		return true

	# Out of reach: re-aim on the refresh interval, or at once when the walk was
	# parked in reach and the enemy has since stepped away.
	if target_refresh_left <= 0.0 or navigation_agent.is_navigation_finished():
		_refresh_attack_target_position()
		target_refresh_left = target_refresh_interval
	return false


func set_navigation_target(world_position: Vector3) -> void:
	clear_attack_target()
	manual_path_points.clear()
	manual_path_index = 0
	super(world_position)


func set_navigation_path(points: Array[Vector3]) -> void:
	manual_path_points = points.duplicate()
	manual_path_index = 0
	if navigation_agent != null:
		navigation_agent.target_position = global_position


func set_attack_target(target: Node3D) -> void:
	if target == null:
		clear_attack_target()
		return
	attack_target = target
	_refresh_attack_target_position()
	target_refresh_left = target_refresh_interval


func clear_attack_target() -> void:
	attack_target = null


# --- Damage in ----------------------------------------------------------------

## The 2D `take_damage` maths, in the base class's mitigation hook: the soul in
## control decides how much of a hit the shared body feels, then the block
## stance halves what remains. Owns the feedback that depends on the result.
func _apply_damage(amount: int) -> int:
	_hit_flash_handled = false
	var final_amount := maxi(amount, 0)
	if final_amount > 0 and active_soul != null:
		final_amount = maxi(1, int(ceil(float(final_amount) * active_soul.defence_mult)))
	var blocked := blocking_active and final_amount > 0
	if blocked:
		final_amount = maxi(1, int(ceil(float(final_amount) * 0.5)))
	if final_amount <= 0:
		return 0

	var popup_anchor := global_position + Vector3(0.0, POPUP_HEIGHT_M, 0.0)
	if blocked:
		_flash_body(Color(1.6, 2.0, 2.6, 1.0), 0.2)
		CombatFx.popup_text(popup_anchor + Vector3(0.0, 0.3, 0.0), "BLOCKED", CombatFx.COLOR_BLOCK, 18)
		CombatFx.popup_damage(popup_anchor, final_amount, CombatFx.COLOR_BLOCK)
		CombatFx.shake(2.5, 0.12)
		_punch_block_aura()
	else:
		_flash_body(Color(2.6, 1.2, 1.2, 1.0), 0.18)
		CombatFx.popup_damage(popup_anchor, final_amount, CombatFx.COLOR_DAMAGE_TAKEN)
		CombatFx.shake(6.0, 0.18)
		# Knock the body back a touch (local +Z is behind); the swing tween owns
		# the model position too, but taking a hit mid-swing is rare enough to
		# accept the overlap.
		if model != null:
			var tween := create_tween()
			tween.tween_property(model, "position",
				model_idle_position + Vector3(0.0, 0.0, 4.0 * WEAPON_RANGE_METERS_PER_PIXEL), 0.05)
			tween.tween_property(model, "position", model_idle_position, 0.14) \
				.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_hit_flash_handled = true
	return final_amount


## The actor-contract hit tint. `_apply_damage` has usually flashed already in
## the hit's own colour; anything else (CombatFx.flash on this node) gets the
## default white flash.
func flash_hit() -> void:
	if _hit_flash_handled:
		_hit_flash_handled = false
	else:
		_flash_body(HitFlash3D.DEFAULT_COLOR, HitFlash3D.DEFAULT_DURATION)
	super()


func _flash_body(color: Color, duration: float) -> void:
	HitFlash3D.flash_node(self, color, duration)


# --- Counter window (driven by the enemy) -------------------------------------

func begin_enemy_counter_windup(_attacker: Node3D, _base_damage: int) -> void:
	_counter_phase = COUNTER_PHASE_WINDUP
	_counter_early_pressed = false
	_counter_perfect_pressed = false


func begin_enemy_counter_strike() -> void:
	if _counter_phase == COUNTER_PHASE_WINDUP:
		_counter_phase = COUNTER_PHASE_STRIKE


func cancel_enemy_counter() -> void:
	_counter_phase = COUNTER_PHASE_NONE
	_counter_early_pressed = false
	_counter_perfect_pressed = false


# Resolves an enemy hit against the active soul's reaction. Returns true when
# the press landed on the beat (the prompt shows green), whether that negated
# the hit outright or, for the mage, only softened it.
func resolve_enemy_attack(attacker: Node3D, base_damage: int) -> bool:
	if _counter_phase == COUNTER_PHASE_NONE:
		take_damage(base_damage)
		return false
	var early := _counter_early_pressed
	var perfect := _counter_perfect_pressed
	cancel_enemy_counter()
	var reaction := active_soul.reaction if active_soul != null else Soul.Reaction.BLOCK

	if early:
		# Pressing in the wind-up. The rogue overcommits and eats a doubled hit
		# (the "TOO EARLY" popup fired on the press itself); the knight's shield
		# and the mage's ward simply aren't up yet, so the hit lands as normal.
		if reaction == Soul.Reaction.PARRY:
			take_damage(int(round(float(base_damage) * Soul.ROGUE_EARLY_PARRY_MULT)))
		else:
			take_damage(base_damage)
		return false

	if not perfect:
		take_damage(base_damage)
		return false

	_on_perfect_reaction()
	var anchor := global_position + Vector3(0.0, POPUP_HEIGHT_HIGH_M, 0.0)
	match reaction:
		Soul.Reaction.BLOCK:
			# The knight turns the blow aside. No riposte: the knight's edge is
			# that Block also works without timing, through the stance.
			CombatFx.popup_text(anchor, "BLOCKED!", CombatFx.COLOR_BLOCK, 26)
			_flash_body(Color(1.6, 2.0, 2.6, 1.0), 0.22)
			CombatFx.ring_burst(self, global_position + Vector3(0.0, 0.05, 0.0), CombatFx.COLOR_BLOCK,
				10.0 * FX_SCREEN_SCALE, 28.0 * FX_SCREEN_SCALE, 0.3)
			CombatFx.hit_stop(0.06, 0.2)
			CombatFx.shake(2.0, 0.1)
		Soul.Reaction.PARRY:
			CombatFx.popup_text(anchor, "PARRY!", CombatFx.COLOR_COUNTER, 26)
			CombatFx.hit_stop(0.08, 0.15)
			_counter_strike(attacker)
		Soul.Reaction.WARD:
			# The ward takes the edge off; the mage's poor defence still applies
			# to what gets through (inside _apply_damage).
			CombatFx.popup_text(anchor, "WARDED", Soul.COLOR_MAGE, 24)
			CombatFx.ring_burst(self, global_position + Vector3(0.0, 1.0, 0.0), Soul.COLOR_MAGE,
				6.0 * FX_SCREEN_SCALE, 26.0 * FX_SCREEN_SCALE, 0.32, 1.0)
			CombatFx.hit_stop(0.05, 0.25)
			take_damage(maxi(1, int(ceil(float(base_damage) * Soul.MAGE_WARD_MULT))))
	return true


# A perfect reaction builds Resonance: the souls align and grant one extra
# shift on the next turn. Once per enemy turn, so a crowd can't stack it.
func _on_perfect_reaction() -> void:
	if not PERFECT_REACTION_GRANTS_EXTRA_SHIFT:
		return
	if _resonance_pending:
		return
	_resonance_pending = true
	CombatFx.popup_text(global_position + Vector3(0.0, POPUP_HEIGHT_TOP_M, 0.0),
		"RESONANCE  +1 shift", CombatFx.COLOR_COUNTER, 16)


# What the counter prompt writes under its ring: the reaction this soul will
# perform if the key is pressed on the beat.
func get_reaction_hint() -> Dictionary:
	if active_soul == null:
		return {"text": "Counter", "color": Color.WHITE}
	return {"text": active_soul.reaction_name(), "color": active_soul.color}


# The riposte: face the attacker and run the normal melee swing at them.
func _counter_strike(attacker: Node3D) -> void:
	if attacker == null or not is_instance_valid(attacker):
		return
	_face_toward_world(attacker.global_position)
	var damage := get_melee_damage()
	_swing_melee(func() -> void:
		if is_instance_valid(attacker) and attacker.has_method("receive_damage"):
			attacker.call("receive_damage", damage)
			CombatFx.hit_stop()
	)


func _register_counter_press() -> void:
	if _counter_phase == COUNTER_PHASE_WINDUP:
		if not _counter_early_pressed:
			CombatFx.popup_text(global_position + Vector3(0.0, POPUP_HEIGHT_HIGH_M, 0.0),
				"TOO EARLY", CombatFx.COLOR_WARNING, 16)
			_flash_body(Color(1.8, 1.3, 1.0, 1.0), 0.12)
		_counter_early_pressed = true
	elif _counter_phase == COUNTER_PHASE_STRIKE:
		if not _counter_perfect_pressed:
			var accent := active_soul.color if active_soul != null else CombatFx.COLOR_COUNTER
			_flash_body(Color(accent.r * 2.2, accent.g * 2.2, accent.b * 2.2, 1.0), 0.2)
		_counter_perfect_pressed = true


func heal(amount: int) -> void:
	var healed := mini(max_health - health, maxi(amount, 0))
	health = mini(max_health, health + maxi(amount, 0))
	_update_health_bar()
	if healed > 0:
		CombatFx.popup_text(global_position + Vector3(0.0, POPUP_HEIGHT_M, 0.0), "+%d" % healed, CombatFx.COLOR_HEAL)
		_flash_body(Color(1.3, 2.2, 1.4, 1.0), 0.2)


# --- Attacks ------------------------------------------------------------------

func _try_attack() -> void:
	if attack_cooldown_left > 0.0:
		return

	attack_cooldown_left = attack_cooldown
	_swing_melee(_apply_attack_damage)


# Starts the melee swing now and runs `on_contact` when the blade lands. Every
# melee path (turn attack, click target, spacebar sweep, counter) funnels
# through here so contact timing is identical everywhere.
func _swing_melee(on_contact: Callable) -> void:
	_flash_attack_feedback()
	await get_tree().create_timer(melee_hit_delay).timeout
	if not is_instance_valid(self):
		return
	on_contact.call()


# Turn-mode melee. Coroutine: resolves once the hit has landed (or been
# refused), so the coordinator can hold the turn until the swing is over.
# Returns true when a swing actually happened.
func try_attack(target: Node3D = null) -> bool:
	if _turn_mode:
		if not _alive:
			return false
		if not _turn_active:
			return false
		if not _turn_attack_available:
			return false
		if target == null or not is_instance_valid(target):
			return false
		if not target.has_method("receive_damage"):
			return false
		if GroundMath.ground_distance(global_position, target.global_position) > get_melee_range() + ATTACK_RANGE_TOLERANCE:
			return false

		_turn_attack_available = false
		_face_toward_world(target.global_position)
		var damage := get_melee_damage()
		var victim := target
		await _swing_melee(func() -> void:
			if is_instance_valid(victim) and victim.has_method("receive_damage"):
				victim.call("receive_damage", damage)
				CombatFx.hit_stop()
		)
		return true

	_try_attack()
	return true


# Turn-mode ranged attack (the rogue's throw). Coroutine like `try_attack`: the
# bolt travels and damage lands on arrival, so a 12 m shot visibly takes longer
# than a 3 m one. Refused for souls with no ranged attack, and (unlike 2D, where
# only the coordinator checked) for a target beyond the soul's range.
func try_ranged_attack(target: Node3D = null) -> bool:
	if _turn_mode:
		if not _alive:
			return false
		if active_soul == null or not active_soul.has_ranged():
			return false
		if not _turn_active:
			return false
		if not _turn_attack_available:
			return false
		if target == null or not is_instance_valid(target):
			return false
		if not target.has_method("receive_damage"):
			return false
		if GroundMath.ground_distance(global_position, target.global_position) > get_ranged_range_meters() + ATTACK_RANGE_TOLERANCE:
			return false

		_turn_attack_available = false
		_face_toward_world(target.global_position)
		_flash_ranged_feedback(target)
		var damage := active_soul.ranged_damage
		await _launch_bolt(target)
		if is_instance_valid(target) and target.has_method("receive_damage"):
			target.call("receive_damage", damage)
			CombatFx.hit_stop(0.04, 0.3)
		return true
	return false


func get_ranged_range_meters() -> float:
	if active_soul == null:
		return 0.0
	return active_soul.ranged_range_meters


# Turn-mode spell (the mage). Spends the turn's attack like a throw does, then
# recharges over the player's own turns. Coroutine: the bolt flies, and on
# impact the spell hits the one target or, for an area spell, everyone near
# the impact point. Frost Snare also roots its primary target.
func try_cast_spell(spell_id: StringName, target: Node3D = null) -> bool:
	if not _turn_mode or active_soul == null or not _alive:
		return false
	var spell := active_soul.get_spell(spell_id)
	if spell == null:
		return false
	if not _turn_active or not _turn_attack_available:
		return false
	if get_spell_cooldown(spell_id) > 0:
		return false
	if target == null or not is_instance_valid(target):
		return false
	if not target.has_method("receive_damage"):
		return false
	if GroundMath.ground_distance(global_position, target.global_position) > spell.range_meters + ATTACK_RANGE_TOLERANCE:
		return false

	_turn_attack_available = false
	if spell.cooldown_turns > 0:
		spell_cooldowns[spell_id] = spell.cooldown_turns
	_face_toward_world(target.global_position)
	_flash_ranged_feedback(target, true)
	var victim := target
	await _launch_bolt(victim, spell.color)
	if not is_instance_valid(self):
		return true

	var impact := victim.global_position if is_instance_valid(victim) else global_position
	impact = GroundMath.flatten(impact, GroundMath.GROUND_Y)
	var victims: Array[Node3D] = []
	if spell.is_area():
		var radius_world := spell.radius_meters * _meter_world_units
		victims = _enemies_within(impact, radius_world)
		CombatFx.ring_burst(get_parent(), impact + Vector3(0.0, 0.05, 0.0), spell.color,
			6.0 * FX_SCREEN_SCALE, _screen_radius_px(impact, radius_world), 0.4)
		CombatFx.shake(4.0, 0.16)
	elif is_instance_valid(victim):
		victims.append(victim)

	for hit_victim in victims:
		if is_instance_valid(hit_victim) and hit_victim.has_method("receive_damage"):
			hit_victim.call("receive_damage", spell.damage)
	if spell.root_turns > 0 and is_instance_valid(victim) and victim.has_method("apply_root"):
		victim.call("apply_root", spell.root_turns)
	if not victims.is_empty():
		CombatFx.hit_stop(0.05, 0.25)
	return true


func get_spell_cooldown(spell_id: StringName) -> int:
	return int(spell_cooldowns.get(spell_id, 0))


# The coordinator tells us how many world units one turn-mode meter is, so
# spell radii can be authored in meters like every other range. In 3D that is
# GroundMath.METER_WORLD_UNITS, 1.0.
func set_turn_meter_world_units(units: float) -> void:
	_meter_world_units = maxf(1.0, units)


func _enemies_within(world_point: Vector3, radius_world: float) -> Array[Node3D]:
	var found: Array[Node3D] = []
	for node in get_tree().get_nodes_in_group("enemies"):
		var actor := node as Node3D
		if actor == null or not is_instance_valid(actor):
			continue
		if actor.has_method("is_alive") and not bool(actor.call("is_alive")):
			continue
		if not actor.has_method("receive_damage"):
			continue
		if GroundMath.ground_distance(actor.global_position, world_point) <= radius_world:
			found.append(actor)
	return found


## How many screen pixels a ground radius spans at `world_point`, so a world
## burst drawn on the FX layer matches the circle the rules test.
func _screen_radius_px(world_point: Vector3, radius_m: float) -> float:
	if not is_inside_tree():
		return radius_m * FALLBACK_SCREEN_PX_PER_METER
	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return radius_m * FALLBACK_SCREEN_PX_PER_METER
	var centre := camera.unproject_position(world_point)
	var edge := camera.unproject_position(world_point + camera.global_transform.basis.x * radius_m)
	return maxf(centre.distance_to(edge), 1.0)


# A short glowing streak that flies from the hand to the target. Parented to
# the level (not the player) so it keeps its own path if the player moves.
func _launch_bolt(target: Node3D, color: Color = Color(0.5, 0.88, 1.0, 0.95)) -> void:
	var start := _bolt_start_position()
	var destination := target.global_position + Vector3(0.0, BOLT_TARGET_HEIGHT_M, 0.0)
	var distance := start.distance_to(destination)
	var flight_time := clampf(distance / maxf(ranged_bolt_speed, 0.01), BOLT_FLIGHT_MIN_SECONDS, BOLT_FLIGHT_MAX_SECONDS)

	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = color.lightened(0.2)

	# The streak points along local -Z (toward the destination) and its tail
	# trails behind along +Z, the way the 2D Line2D trailed its head.
	var tail_length := maxf(minf(BOLT_MAX_TAIL_M, distance * 0.5), BOLT_THICKNESS_M)
	var bolt := MeshInstance3D.new()
	bolt.name = "Bolt"
	bolt.mesh = _make_offset_box(Vector3(BOLT_THICKNESS_M, BOLT_THICKNESS_M, tail_length),
		Vector3(0.0, 0.0, tail_length * 0.5), material)
	bolt.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var holder := get_parent()
	if holder == null:
		holder = self
	holder.add_child(bolt)
	bolt.global_position = start
	var direction := destination - start
	if direction.length() > 0.01 and absf(direction.normalized().dot(Vector3.UP)) < 0.999:
		bolt.look_at(destination, Vector3.UP)

	var tween := bolt.create_tween()
	tween.tween_property(bolt, "global_position", destination, flight_time) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	await tween.finished

	if is_instance_valid(bolt):
		var fade := bolt.create_tween()
		fade.tween_property(material, "albedo_color:a", 0.0, 0.1)
		fade.tween_callback(bolt.queue_free)


## A box whose origin is not its centre: BoxMesh has no centre offset, so the
## primitive is baked into an ArrayMesh with its vertices moved by `offset`.
## Used for the blade (origin at the grip) and the bolt (origin at the head).
static func _make_offset_box(size: Vector3, offset: Vector3, material: Material) -> ArrayMesh:
	var box := BoxMesh.new()
	box.size = size
	var arrays := box.get_mesh_arrays()
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	for i in range(vertices.size()):
		vertices[i] += offset
	arrays[Mesh.ARRAY_VERTEX] = vertices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, material)
	return mesh


func _bolt_start_position() -> Vector3:
	if hand_point != null and is_instance_valid(hand_point):
		return hand_point.global_position
	return global_position + _facing_direction() * (8.0 * WEAPON_RANGE_METERS_PER_PIXEL) \
		+ Vector3(0.0, DEFAULT_HAND_POINT.y, 0.0)


## Unit ground vector the body faces (local -Z), the 3D twin of the 2D
## `facing_direction`. Forward when the body has not turned yet.
func _facing_direction() -> Vector3:
	var forward := GroundMath.ground_direction(Vector3.ZERO, -global_transform.basis.z)
	if forward == Vector3.ZERO:
		return Vector3.FORWARD
	return forward


func _face_toward_world(world_position: Vector3) -> void:
	face_toward(world_position)


func _flash_ranged_feedback(_target: Node3D, cast: bool = false) -> void:
	# Weapon motion comes from the archetype stub - bow pull + release for
	# throws, raised staff for spells (the mage casts with whatever is in the
	# hand). The recoil below is the ranged-specific VFX common to both. The 2D
	# cast stub keyed the body's modulate glow; a 3D body has no modulate, so
	# the glow is a HitFlash3D tint here instead.
	var ranged_archetype := _resolve_attack_archetype()
	if cast or ranged_archetype == Item.ARCHETYPE_CAST_STAFF:
		ranged_archetype = Item.ARCHETYPE_CAST_STAFF
	else:
		ranged_archetype = Item.ARCHETYPE_RANGED_BOW
	_play_attack_animation(ranged_archetype)

	var speed_scale := maxf(attack_animation_speed_scale, 0.1)
	var t_col := 0.1 * speed_scale
	var t_reset := 0.18 * speed_scale

	if ranged_archetype == Item.ARCHETYPE_CAST_STAFF:
		_flash_body(Color(0.2, 0.15, 0.5, 1.0), 0.55)
	else:
		_flash_body(Color(0.1, 0.25, 0.4, 1.0), t_reset)
	if model == null:
		return
	# Small recoil on release (local +Z is behind); the projectile itself is
	# `_launch_bolt`.
	var tween := create_tween()
	tween.tween_property(model, "position",
		model_idle_position + Vector3(0.0, 0.0, 2.5 * WEAPON_RANGE_METERS_PER_PIXEL), t_col)
	tween.tween_property(model, "position", model_idle_position, t_reset)


func _try_attack_target(target: Node3D) -> void:
	if attack_cooldown_left > 0.0:
		return
	if target == null or not is_instance_valid(target):
		return
	if GroundMath.ground_distance(global_position, target.global_position) > get_melee_range():
		return
	if not target.has_method("receive_damage"):
		return

	attack_cooldown_left = attack_cooldown
	_face_toward_world(target.global_position)
	var damage := get_melee_damage()
	_swing_melee(func() -> void:
		if is_instance_valid(target) and target.has_method("receive_damage"):
			target.call("receive_damage", damage)
			CombatFx.hit_stop()
	)


func _refresh_attack_target_position() -> void:
	if attack_target == null or not is_instance_valid(attack_target):
		return
	var approach_point := _compute_approach_point(attack_target.global_position, get_preferred_attack_approach_distance())
	# The base version: closest navmesh point and the path height offset. This
	# class's own override would clear the attack target.
	super.set_navigation_target(approach_point)


func _compute_approach_point(target_world_position: Vector3, stop_distance: float) -> Vector3:
	var here := GroundMath.flatten(global_position, GroundMath.GROUND_Y)
	var there := GroundMath.flatten(target_world_position, GroundMath.GROUND_Y)
	var to_mover := here - there
	var distance := to_mover.length()
	if distance <= stop_distance:
		return here
	if distance <= 0.001:
		return there
	return there + (to_mover / distance) * stop_distance


## Where the walk-up to `target` (the current attack target when omitted) stops:
## the base class's spacing rule with the weapon's reach and this player's
## buffer (WP10). With no target at all only the reach and the buffer apply.
func get_preferred_attack_approach_distance(target: Node3D = null) -> float:
	if target == null:
		target = attack_target
	return get_attack_approach_distance(target, get_melee_range(), attack_approach_buffer)


## The exploration sweep (spacebar): everything within melee range takes a hit.
## Props (layer 8, crates) and actors (layer 2); the body's own mask is world-only
## so it can walk through enemies, which is not what a sword sweep should do.
func _apply_attack_damage() -> void:
	var world := get_world_3d()
	if world == null:
		return
	var shape := SphereShape3D.new()
	shape.radius = get_melee_range()

	var params := PhysicsShapeQueryParameters3D.new()
	params.shape = shape
	params.transform = Transform3D(Basis.IDENTITY, global_position + Vector3(0.0, SWEEP_HEIGHT_M, 0.0))
	params.collision_mask = 2 | 8
	params.exclude = [get_rid()]

	var damage := get_melee_damage()
	var hits := world.direct_space_state.intersect_shape(params, 16)
	var landed := false
	for hit in hits:
		var collider := hit.get("collider") as Object
		if collider == null:
			continue
		if collider.has_method("take_damage"):
			collider.call("take_damage", damage)
			landed = true
		elif collider.has_method("receive_damage"):
			collider.call("receive_damage", damage)
			landed = true
	if landed:
		CombatFx.hit_stop()


func _flash_attack_feedback() -> void:
	# Drive the weapon holder from the shared archetype animation. For melee
	# archetypes this just swings the weapon; the body tween below still does
	# the lunge and the tint. For non-melee archetypes we stop here - callers
	# like `_flash_ranged_feedback` handle their own body + projectile.
	_play_attack_animation()
	var archetype := _resolve_attack_archetype()
	if archetype != Item.ARCHETYPE_MELEE_SLASH \
			and archetype != Item.ARCHETYPE_MELEE_THRUST \
			and archetype != Item.ARCHETYPE_MELEE_CHOP \
			and archetype != Item.ARCHETYPE_UNARMED:
		return

	var speed_scale := maxf(attack_animation_speed_scale, 0.1)
	var t_fast := 0.06 * speed_scale
	var t_med := 0.08 * speed_scale
	var t_reset := 0.12 * speed_scale

	# The 2D sprite tint (modulate 1.0, 0.72, 0.72) becomes an additive red
	# overlay; the 2D slash sprite has no 3D twin yet.
	_flash_body(Color(0.45, 0.12, 0.12, 1.0), t_reset)
	if model == null:
		return

	var lunge := Vector3(0.0, 0.0, -5.5 * WEAPON_RANGE_METERS_PER_PIXEL)
	model.position = model_idle_position
	model.scale = Vector3.ONE

	var tween := create_tween()
	tween.tween_property(model, "position", model_idle_position + lunge, t_fast)
	tween.parallel().tween_property(model, "scale", Vector3(1.08, 0.94, 1.08), t_fast)

	var return_tween := create_tween()
	return_tween.tween_interval(t_fast)
	return_tween.tween_property(model, "position", model_idle_position, t_med)
	return_tween.parallel().tween_property(model, "scale", Vector3.ONE, t_med)


# --- Overhead UI ----------------------------------------------------------------

func _setup_health_bar() -> void:
	if overhead_anchor == null:
		return
	health_bars = overhead_anchor.get_node_or_null("HealthBars") as OverheadBars3D
	if health_bars == null:
		health_bars = OverheadBars3D.new()
		health_bars.name = "HealthBars"
		overhead_anchor.add_child(health_bars)


func _setup_level_and_xp_ui() -> void:
	if overhead_anchor == null:
		return
	var xp_anchor := Node3D.new()
	xp_anchor.name = "XpAnchor"
	xp_anchor.position = Vector3(0.0, XP_BAR_OFFSET_M, 0.0)
	overhead_anchor.add_child(xp_anchor)

	xp_bars = OverheadBars3D.new()
	xp_bars.name = "XpBars"
	xp_bars.fill_color = XP_BAR_COLOR
	# No trailing ghost on the XP bar: it only ever drops on a level up.
	xp_bars.ghost_color = Color(0.0, 0.0, 0.0, 0.0)
	xp_anchor.add_child(xp_bars)

	level_label = Label3D.new()
	level_label.name = "LevelLabel"
	level_label.text = "Lv 1"
	level_label.position = Vector3(0.0, LEVEL_LABEL_OFFSET_M, 0.0)
	level_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	level_label.no_depth_test = true
	level_label.font_size = 40
	level_label.pixel_size = 0.005
	level_label.outline_size = 10
	level_label.modulate = LEVEL_LABEL_COLOR
	level_label.outline_modulate = Color(0.0, 0.0, 0.0, 0.85)
	overhead_anchor.add_child(level_label)


func xp_required_for_next_level() -> float:
	return XP_BASE_TO_LEVEL_2 * pow(XP_PER_LEVEL_MULT, float(player_level - 1))


func add_experience(amount: int) -> void:
	if amount <= 0:
		return
	experience_points += float(amount)
	while experience_points + 0.0001 >= xp_required_for_next_level():
		experience_points -= xp_required_for_next_level()
		player_level += 1
		_on_level_up()
	_update_xp_bar()
	_update_level_label()


func _on_level_up() -> void:
	CombatFx.popup_text(global_position + Vector3(0.0, POPUP_HEIGHT_HIGH_M, 0.0), "LEVEL UP!", CombatFx.COLOR_COUNTER, 26)
	_flash_body(Color(2.4, 2.2, 1.4, 1.0), 0.35)
	CombatFx.shake(4.0, 0.2)


func get_player_level() -> int:
	return player_level


func get_experience_toward_next() -> float:
	return experience_points


func get_xp_required_for_next_level() -> float:
	return xp_required_for_next_level()


func _update_level_label() -> void:
	if level_label != null:
		level_label.text = "Lv %d" % player_level


func _update_xp_bar() -> void:
	if xp_bars == null:
		return
	var need := xp_required_for_next_level()
	var ratio := 0.0
	if need > 0.0:
		ratio = clampf(experience_points / need, 0.0, 1.0)
	xp_bars.set_ratio(ratio)


func _update_health_bar() -> void:
	_bar_health = health
	if health_bars == null:
		return
	var ratio := 0.0
	if max_health > 0:
		ratio = clampf(float(health) / float(max_health), 0.0, 1.0)
	health_bars.set_ratio(ratio)


# Show or hide the bars and level tag floating above the player. Full-screen
# UI (the inventory screen) hides them so they don't sit on top of the panel.
func set_overhead_ui_visible(is_visible: bool) -> void:
	if health_bars != null:
		health_bars.set_visible_bars(is_visible)
	if xp_bars != null:
		xp_bars.set_visible_bars(is_visible)
	if level_label != null:
		level_label.visible = is_visible


# --- Input and scene plumbing ----------------------------------------------------

func _ensure_attack_input() -> void:
	if not InputMap.has_action(attack_action_name):
		InputMap.add_action(attack_action_name)

	var has_space_key := false
	var events := InputMap.action_get_events(attack_action_name)
	for e in events:
		if e is InputEventKey and e.physical_keycode == KEY_SPACE:
			has_space_key = true
			break

	if not has_space_key:
		var key_event := InputEventKey.new()
		key_event.physical_keycode = KEY_SPACE
		InputMap.action_add_event(attack_action_name, key_event)


func _ensure_counter_input() -> void:
	if not InputMap.has_action(counter_action_name):
		InputMap.add_action(counter_action_name)

	var has_f_key := false
	for e in InputMap.action_get_events(counter_action_name):
		if e is InputEventKey and e.physical_keycode == KEY_F:
			has_f_key = true
			break

	if not has_f_key:
		var key_event := InputEventKey.new()
		key_event.physical_keycode = KEY_F
		InputMap.action_add_event(counter_action_name, key_event)


## The 2D player forced its circle (radius 7 px); the 3D body is the contract's
## capsule, radius 0.35 m, height 1.8 m, standing on the feet.
func _ensure_collision_shape() -> void:
	if collision_shape == null:
		return
	var capsule := collision_shape.shape as CapsuleShape3D
	if capsule == null:
		capsule = CapsuleShape3D.new()
		collision_shape.shape = capsule
	capsule.radius = 0.35
	capsule.height = 1.8
	collision_shape.position = Vector3(0.0, 0.9, 0.0)


# --- Body visuals -------------------------------------------------------------
# The 2D player swapped SpriteFrames per soul. In 3D `Model` is a SoulBodies3D
# holding the knight, rogue and mage models (WP9): a shift shows the soul's own
# body, moves `HandPoint` and `OverheadAnchor` to that body's empties and puts
# the soul's own weapon on `EquippedWeaponMesh`. The equipped Item still decides
# damage, range and the attack archetype; the soul decides the mesh in the hand.
# The vision light blends to the soul's light colour exactly as in 2D.

func _setup_body_visuals() -> void:
	soul_bodies = model as SoulBodies3D
	if soul_bodies != null:
		soul_bodies.active_pose_updated.connect(_follow_body_hand)
	_apply_soul_visual(active_soul, false)


func _apply_soul_visual(soul: Soul, animate: bool = true) -> void:
	if soul == null:
		return
	_apply_soul_body(soul)
	if vision_light == null:
		return
	if not animate:
		vision_light.light_color = soul.light_color
		return
	var tween := create_tween()
	tween.tween_property(vision_light, "light_color", soul.light_color, SHIFT_LIGHT_BLEND_SECONDS)


## Shows `soul`'s body and fits the hand, the overhead anchor and the held
## weapon to it. The hand and the anchor stay children of the player so the
## archetype animations' `HandPoint/EquippedWeaponHolder` paths and the bars
## under the anchor keep working; they are moved, not re-parented. The new
## body carries on with the old one's idle or walk (SoulBodies3D.show_soul).
func _apply_soul_body(soul: Soul) -> void:
	if soul_bodies == null or not soul_bodies.show_soul(int(soul.kind)):
		return
	_follow_body_hand()
	if overhead_anchor != null:
		overhead_anchor.position.y = soul_bodies.get_overhead_height()
	_refresh_weapon_visual(get_equipped_weapon())
	if _locomotion_state != &"":
		_play_locomotion(_locomotion_state, _locomotion_speed_scale)


## Puts the player's `HandPoint` (and the held weapon under it) on the active
## body's `HandPoint` as the skeleton poses it: the weapon swings with the arm
## in the idle and walk cycles (WP11). Runs whenever the active skeleton has a
## new pose. The archetype animations still key `EquippedWeaponHolder` under
## it, so an attack swing adds to the arm pose instead of fighting it.
func _follow_body_hand() -> void:
	if hand_point == null or soul_bodies == null or soul_bodies.get_hand_point() == null:
		return
	hand_point.transform = soul_bodies.get_live_hand_transform()


# --- Locomotion clips (WP11) ------------------------------------------------------
# Each soul's glb carries a skeleton and two looping clips, `idle` (2.0 s) and
# `walk` (1.0 s, one stride authored for WALK_REFERENCE_SPEED). Every physics
# frame the active body plays `walk` while the actor moves faster than
# WALK_MIN_SPEED, with its playback scaled by ground speed so the stride keeps
# pace with the movement, and `idle` otherwise. The attack lunge and squash
# tween `Model` and the swing keys the weapon holder, so both play on top of
# either clip; the walk is not paused for `melee_hit_delay`.

const LOCOMOTION_IDLE := &"idle"
const LOCOMOTION_WALK := &"walk"
## Ground speed (m/s) at which the 1.0 s walk clip plays at 1.0x without the feet
## sliding: the authored stride covers about 0.96 m per step, 1.92 m per cycle
## (docs/deviations/wp11.md), so at the 3.5 m/s walk the clip runs at 1.82x.
const WALK_REFERENCE_SPEED := 1.92
## Below this ground speed the body idles.
const WALK_MIN_SPEED := 0.2
## A walk survives this long without speed while the actor still reports
## moving (a frame where avoidance has not answered yet), so it never flickers.
const WALK_GRACE_SECONDS := 0.12
const WALK_SPEED_SCALE_MIN := 0.25
const WALK_SPEED_SCALE_MAX := 2.5
## Cross-fade between idle and walk.
const LOCOMOTION_BLEND_SECONDS := 0.15

var _locomotion_state: StringName = &""
var _locomotion_speed_scale := 1.0
var _walk_grace_left := 0.0


## The locomotion clip the active body is playing (`idle`, `walk`, or empty
## before the first physics frame or without a rig).
func get_locomotion_state() -> StringName:
	return _locomotion_state


func _update_locomotion_animation(delta: float) -> void:
	if soul_bodies == null:
		return
	var ground_speed := Vector2(velocity.x, velocity.z).length()
	var wanted := LOCOMOTION_IDLE
	var speed_scale := 1.0
	if _alive and is_moving():
		if ground_speed > WALK_MIN_SPEED:
			wanted = LOCOMOTION_WALK
			_walk_grace_left = WALK_GRACE_SECONDS
			speed_scale = clampf(ground_speed / WALK_REFERENCE_SPEED, WALK_SPEED_SCALE_MIN, WALK_SPEED_SCALE_MAX)
		elif _locomotion_state == LOCOMOTION_WALK and _walk_grace_left > 0.0:
			wanted = LOCOMOTION_WALK
			_walk_grace_left -= delta
			speed_scale = _locomotion_speed_scale
	_play_locomotion(wanted, speed_scale)


## Plays `clip` looping on the active body at `speed_scale`, cross-fading from
## the other clip; a clip that is already playing only takes the new speed.
func _play_locomotion(clip: StringName, speed_scale: float) -> void:
	_locomotion_state = clip
	_locomotion_speed_scale = speed_scale
	if soul_bodies == null:
		return
	var anim_player := soul_bodies.get_animation_player()
	if anim_player == null or not anim_player.has_animation(clip):
		return
	anim_player.speed_scale = speed_scale
	if StringName(anim_player.current_animation) != clip or not anim_player.is_playing():
		anim_player.play(clip, LOCOMOTION_BLEND_SECONDS)


# --- Manual paths and stuck detection -------------------------------------------

## The 2D stuck check also counted a manual path as "trying to move".
func _check_stuck(delta: float) -> void:
	var following_path := manual_path_index < manual_path_points.size()
	var is_trying_to_move := following_path or (navigation_agent != null and not navigation_agent.is_navigation_finished())
	if not is_trying_to_move:
		_stuck_timer = 0.0
		_last_position = global_position
		return

	if GroundMath.ground_distance(global_position, _last_position) > STUCK_MOVE_EPSILON:
		_stuck_timer = 0.0
		_last_position = global_position
		return

	_stuck_timer += delta
	if _stuck_timer >= STUCK_THRESHOLD:
		stop_movement_immediately()
		_stuck_timer = 0.0


func stop_movement_immediately() -> void:
	manual_path_points.clear()
	manual_path_index = 0
	clear_attack_target()
	super()


func is_moving() -> bool:
	if manual_path_index < manual_path_points.size():
		return _alive
	return super()


func _process_manual_path_movement() -> bool:
	if manual_path_index >= manual_path_points.size():
		return false

	var next_point := manual_path_points[manual_path_index]
	if GroundMath.ground_distance(global_position, next_point) <= MANUAL_PATH_ARRIVE_M:
		manual_path_index += 1
		if manual_path_index >= manual_path_points.size():
			velocity = Vector3.ZERO
			move_and_slide()
			_settle_on_ground()
			return true
		next_point = manual_path_points[manual_path_index]

	var direction := GroundMath.ground_direction(global_position, next_point)
	if direction != Vector3.ZERO:
		rotation.y = GroundMath.yaw_facing(direction)
	velocity = direction * move_speed
	move_and_slide()
	_settle_on_ground()
	return true


# --- Turn resources -------------------------------------------------------------

func set_turn_based_combat(enabled: bool) -> void:
	set_blocking(false)
	shifts_left_this_turn = 0
	_resonance_pending = false
	# Spells start every fight fresh.
	spell_cooldowns.clear()
	super(enabled)
	if not enabled:
		clear_attack_target()


func start_turn(max_move_meters: float = 6.0) -> void:
	super(max_move_meters)
	set_blocking(false)
	# One shift a turn, plus the one Resonance earned during the enemy turn.
	shifts_left_this_turn = SHIFTS_PER_TURN + (1 if _resonance_pending else 0)
	_resonance_pending = false
	_tick_spell_cooldowns()


func end_turn() -> void:
	super()
	shifts_left_this_turn = 0


func consume_turn_movement(used_cells: int) -> void:
	# Backward-compatible alias (1 cell == 1 meter in turn mode).
	consume_turn_movement_meters(float(maxi(0, used_cells)))


# --- Block stance ---------------------------------------------------------------

func set_blocking(enabled: bool) -> void:
	# The stance is the knight's; the button is hidden for the others, this is
	# the belt to that pair of braces.
	if enabled and active_soul != null and not active_soul.can_block_stance:
		return
	var was_blocking := blocking_active
	blocking_active = enabled
	if block_ring == null:
		return
	if enabled and not was_blocking:
		_set_block_ring_alpha(0.0)
		block_ring.scale = Vector3(0.6, 1.0, 0.6)
		var tween := create_tween()
		tween.set_parallel(true)
		tween.tween_method(_set_block_ring_alpha, 0.0, BLOCK_RING_COLOR.a, 0.16)
		tween.tween_property(block_ring, "scale", Vector3.ONE, 0.22) \
			.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
		CombatFx.popup_text(global_position + Vector3(0.0, POPUP_HEIGHT_M, 0.0), "BLOCKING", CombatFx.COLOR_BLOCK, 18)
	elif not enabled and was_blocking:
		var tween := create_tween()
		tween.tween_method(_set_block_ring_alpha, BLOCK_RING_COLOR.a, 0.0, 0.14)
		tween.tween_callback(func() -> void:
			if block_ring != null and not blocking_active:
				block_ring.hide_ring()
		)


func _setup_block_aura() -> void:
	# Flattened ring at the feet while Block is active. It's what tells you the
	# stance carried over into the enemy turn; damage popups say "BLOCKED".
	block_ring = get_node_or_null("BlockRing") as RangeRing3D
	if block_ring == null:
		block_ring = RangeRing3D.new()
		block_ring.name = "BlockRing"
		add_child(block_ring)
	block_ring.hide_ring()


## RangeRing3D has no alpha of its own; rebuilding the ring with the colour at
## the wanted alpha is the fade.
func _set_block_ring_alpha(alpha: float) -> void:
	if block_ring == null:
		return
	block_ring.show_ring(BLOCK_RING_RADIUS_M, Color(BLOCK_RING_COLOR, clampf(alpha, 0.0, 1.0)))


func _punch_block_aura() -> void:
	if block_ring == null or not block_ring.visible:
		return
	var tween := create_tween()
	tween.tween_property(block_ring, "scale", Vector3(1.25, 1.0, 1.25), 0.05)
	tween.tween_property(block_ring, "scale", Vector3.ONE, 0.18) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func is_blocking() -> bool:
	return blocking_active


# --- The Bound Three ---------------------------------------------------------

func _setup_souls() -> void:
	souls = Soul.all()
	active_soul = souls[0]
	character_name = active_soul.display_name


func _ensure_shift_inputs() -> void:
	for i in range(SHIFT_ACTIONS.size()):
		_ensure_key_action(SHIFT_ACTIONS[i], SHIFT_KEYS[i])
	_ensure_key_action(SHIFT_CYCLE_ACTION, SHIFT_CYCLE_KEY)


func _ensure_key_action(action_name: String, keycode: int) -> void:
	if not InputMap.has_action(action_name):
		InputMap.add_action(action_name)
	for e in InputMap.action_get_events(action_name):
		if e is InputEventKey and e.physical_keycode == keycode:
			return
	var key_event := InputEventKey.new()
	key_event.physical_keycode = keycode as Key
	InputMap.action_add_event(action_name, key_event)


func get_active_soul() -> Soul:
	return active_soul


func get_souls() -> Array[Soul]:
	return souls


func get_shifts_left() -> int:
	if not _turn_mode:
		return 1
	return shifts_left_this_turn


func can_shift() -> bool:
	if not _turn_mode:
		return true
	return _turn_active and shifts_left_this_turn > 0


# The soul a shift key selects, or -1 when `event` isn't one. Shared with the
# coordinator so both input paths read the same bindings.
func shift_kind_from_event(event: InputEvent) -> int:
	for i in range(SHIFT_ACTIONS.size()):
		if event.is_action_pressed(SHIFT_ACTIONS[i]):
			return i
	if event.is_action_pressed(SHIFT_CYCLE_ACTION):
		if active_soul == null or souls.is_empty():
			return -1
		return (souls.find(active_soul) + 1) % souls.size()
	return -1


# Hands the body to another soul. Returns false when nothing changed. In turn
# combat this spends one of the turn's shifts and says so when there are none.
func shift_to(kind: int) -> bool:
	var soul := _soul_of_kind(kind)
	if soul == null or soul == active_soul:
		return false
	if _turn_mode:
		if not _turn_active:
			return false
		if shifts_left_this_turn <= 0:
			CombatFx.popup_text(global_position + Vector3(0.0, POPUP_HEIGHT_M, 0.0), "No shift left", CombatFx.COLOR_WARNING, 16)
			return false
		shifts_left_this_turn -= 1
		# The shield is the knight's; whoever takes over drops the stance.
		set_blocking(false)

	var previous := active_soul
	active_soul = soul
	character_name = soul.display_name
	_apply_soul_visual(soul)
	_play_shift_fx(previous, soul)
	soul_changed.emit(soul)
	return true


func _soul_of_kind(kind: int) -> Soul:
	for soul in souls:
		if int(soul.kind) == kind:
			return soul
	return null


# The shift reads as one body changing hands: a burst in the new soul's colour
# at the feet, a flash, the new body punching up from 0.85 to full size (on the
# body itself, so `Model:scale` stays free for the attack animations), and the
# name.
func _play_shift_fx(_previous: Soul, soul: Soul) -> void:
	CombatFx.ring_burst(self, global_position + Vector3(0.0, 0.05, 0.0), soul.color,
		6.0 * FX_SCREEN_SCALE, 30.0 * FX_SCREEN_SCALE, 0.38)
	_flash_body(Color(soul.color.r * 2.2, soul.color.g * 2.2, soul.color.b * 2.2, 1.0), 0.3)
	CombatFx.popup_text(global_position + Vector3(0.0, POPUP_HEIGHT_HIGH_M, 0.0), soul.title.to_upper(), soul.color, 20)
	if soul_bodies != null:
		soul_bodies.punch_active_body()


func _tick_spell_cooldowns() -> void:
	for spell_id in spell_cooldowns.keys():
		var left := int(spell_cooldowns[spell_id]) - 1
		if left <= 0:
			spell_cooldowns.erase(spell_id)
		else:
			spell_cooldowns[spell_id] = left


# --- Inventory and the held weapon ------------------------------------------------

func _setup_inventory() -> void:
	inventory = get_node_or_null("Inventory") as Inventory
	if inventory == null:
		inventory = Inventory.new()
		inventory.name = "Inventory"
		add_child(inventory)
	inventory.equipped_weapon_changed.connect(_on_equipped_weapon_changed)

	_setup_equipped_weapon_mesh()
	_setup_attack_animations()

	# Give the player a starter sword so melee combat has a concrete weapon.
	var starter_sword := ItemFactory.create_sword()
	inventory.equip_weapon(starter_sword)


func _setup_equipped_weapon_mesh() -> void:
	# Node layering for the held weapon, the 3D twin of the 2D one:
	#   HandPoint              - the right hand (from the model's HandPoint empty).
	#   └─ EquippedWeaponHolder - position/rotation driven by archetype anims.
	#      └─ EquippedWeaponMesh - blade mesh + per-item grip tuning.
	# There is no flip root: facing is the body's rotation.y, so the same keys
	# read correctly whichever way the body turns.
	if hand_point == null:
		hand_point = Node3D.new()
		hand_point.name = "HandPoint"
		hand_point.position = DEFAULT_HAND_POINT
		add_child(hand_point)

	equipped_weapon_holder = hand_point.get_node_or_null("EquippedWeaponHolder") as Node3D
	if equipped_weapon_holder == null:
		equipped_weapon_holder = Node3D.new()
		equipped_weapon_holder.name = "EquippedWeaponHolder"
		hand_point.add_child(equipped_weapon_holder)
	equipped_weapon_holder.position = HOLDER_REST_POSITION

	equipped_weapon_mesh = equipped_weapon_holder.get_node_or_null("EquippedWeaponMesh") as MeshInstance3D
	if equipped_weapon_mesh == null:
		equipped_weapon_mesh = MeshInstance3D.new()
		equipped_weapon_mesh.name = "EquippedWeaponMesh"
		equipped_weapon_holder.add_child(equipped_weapon_mesh)
	if soul_bodies != null and soul_bodies.get_held_weapon_mesh() != null:
		# The active soul's own weapon (WP9); refreshed on every shift.
		SoulBodies3D.transfer_weapon(soul_bodies.get_held_weapon_mesh(), equipped_weapon_mesh)
		equipped_weapon_mesh.transform = soul_bodies.get_weapon_fit()
	if equipped_weapon_mesh.mesh == null:
		# Placeholder blade: origin at the grip end, blade along local +Y (the
		# WP1 sword convention). A scene that authors its own mesh keeps it.
		var material := StandardMaterial3D.new()
		material.albedo_color = WEAPON_MESH_COLOR
		material.metallic = 0.6
		material.roughness = 0.35
		equipped_weapon_mesh.mesh = _make_offset_box(WEAPON_MESH_SIZE,
			Vector3(0.0, WEAPON_MESH_SIZE.y * 0.5, 0.0), material)
	equipped_weapon_mesh.visible = false


func _on_equipped_weapon_changed(weapon: Item) -> void:
	_refresh_weapon_visual(weapon)


## Shows `weapon` in the hand. With the soul bodies the mesh and its fit are the
## active soul's (the knight's sword, the rogue's right dagger, the mage's
## staff), whatever the item is; only "armed or not" comes from the item.
## Without them the item's own 2D grip tuning goes on the mesh, as in WP3b.
func _refresh_weapon_visual(weapon: Item) -> void:
	if equipped_weapon_mesh == null:
		return
	if weapon == null:
		equipped_weapon_mesh.visible = false
		return
	if soul_bodies != null and soul_bodies.get_held_weapon_mesh() != null:
		SoulBodies3D.transfer_weapon(soul_bodies.get_held_weapon_mesh(), equipped_weapon_mesh)
		equipped_weapon_mesh.transform = soul_bodies.get_weapon_fit()
	else:
		equipped_weapon_mesh.position = _weapon_pixels_to_local(weapon.grip_offset)
		equipped_weapon_mesh.rotation_degrees = Vector3(WEAPON_HANG_ROTATION_DEG + weapon.grip_rotation_deg, 0.0, 0.0)
	equipped_weapon_mesh.visible = true


## A 2D hand-space pixel offset (x along the facing, y down the screen) as a
## local metre offset (forward is -Z, up is +Y).
func _weapon_pixels_to_local(pixels: Vector2) -> Vector3:
	return Vector3(0.0, -pixels.y * WEAPON_RANGE_METERS_PER_PIXEL, -pixels.x * WEAPON_RANGE_METERS_PER_PIXEL)


## A 2D holder rotation (radians about the screen normal) as a rotation about
## the hand's local X axis, which is the same swing plane: forward and up.
func _holder_rotation(radians_2d: float) -> Vector3:
	return Vector3(radians_2d, 0.0, 0.0)


func _holder_offset(pixels: Vector2) -> Vector3:
	return HOLDER_REST_POSITION + _weapon_pixels_to_local(pixels)


func get_equipped_weapon() -> Item:
	if inventory == null:
		return null
	return inventory.get_equipped_weapon()


func get_inventory_items() -> Array[Item]:
	if inventory == null:
		return []
	return inventory.items


func get_melee_damage() -> int:
	var weapon := get_equipped_weapon()
	var base := attack_damage
	if weapon != null and weapon.weapon_type == Item.WeaponType.MELEE:
		base = weapon.damage
	# The soul in control decides how hard the shared body swings what it holds.
	if active_soul != null:
		return maxi(1, int(round(float(base) * active_soul.melee_mult)))
	return base


## Metres. Item ranges are authored in 2D pixels; `attack_range` already is a
## metre value (the base class export).
func get_melee_range() -> float:
	var weapon := get_equipped_weapon()
	if weapon != null and weapon.weapon_type == Item.WeaponType.MELEE:
		return weapon.weapon_range * WEAPON_RANGE_METERS_PER_PIXEL
	return attack_range


func _outgoing_damage() -> int:
	return get_melee_damage()


# --- Attack animations (archetype-based) -------------------------------------
# Weapons declare an `animation_archetype` (e.g. "melee_slash", "ranged_bow").
# All weapons that share an archetype play the same animation here - authors
# only add new archetypes when the *motion* genuinely changes, not per skin.
# See CODEBASE_GUIDE.md > "Weapon animations" for the full pattern.
#
# 3D differences: the holder's rotation and position are Vector3 (the 2D
# radians go on the hand's local X axis, the 2D pixel offsets become metres
# along up and forward), the body accent keys `Model:scale`, and the 2D
# `modulate` tracks are gone because a 3D body has no modulate (the cast glow
# is a HitFlash3D tint in `_flash_ranged_feedback`).

func _setup_attack_animations() -> void:
	attack_animation_player = get_node_or_null("AttackAnimations") as AnimationPlayer
	if attack_animation_player == null:
		attack_animation_player = AnimationPlayer.new()
		attack_animation_player.name = "AttackAnimations"
		add_child(attack_animation_player)

	var lib := AnimationLibrary.new()
	lib.add_animation(Item.ARCHETYPE_MELEE_SLASH, _build_melee_slash_animation())
	lib.add_animation(Item.ARCHETYPE_MELEE_THRUST, _build_melee_thrust_animation())
	lib.add_animation(Item.ARCHETYPE_MELEE_CHOP, _build_melee_chop_animation())
	lib.add_animation(Item.ARCHETYPE_RANGED_BOW, _build_ranged_bow_animation())
	lib.add_animation(Item.ARCHETYPE_CAST_STAFF, _build_cast_staff_animation())
	lib.add_animation(Item.ARCHETYPE_UNARMED, _build_unarmed_animation())
	attack_animation_player.add_animation_library("", lib)


func _resolve_attack_archetype() -> StringName:
	var weapon := get_equipped_weapon()
	if weapon == null:
		return Item.ARCHETYPE_MELEE_SLASH
	if weapon.animation_override != &"":
		return weapon.animation_override
	return weapon.animation_archetype


func _play_attack_animation(archetype_override: StringName = &"") -> void:
	if attack_animation_player == null:
		return
	var archetype := archetype_override if archetype_override != &"" else _resolve_attack_archetype()
	var anim_name := str(archetype)
	if not attack_animation_player.has_animation(anim_name):
		return
	attack_animation_player.stop()
	attack_animation_player.play(anim_name)


const _HOLDER_ROT_PATH := "HandPoint/EquippedWeaponHolder:rotation"
const _HOLDER_POS_PATH := "HandPoint/EquippedWeaponHolder:position"
const _BODY_SCALE_PATH := "Model:scale"


func _add_value_track(anim: Animation, path: String, keys: Array) -> void:
	# `keys` is an array of [time, value] pairs. Keeps each animation builder
	# short and readable.
	var idx := anim.add_track(Animation.TYPE_VALUE)
	anim.track_set_path(idx, NodePath(path))
	for pair in keys:
		anim.track_insert_key(idx, float(pair[0]), pair[1])


func _build_melee_slash_animation() -> Animation:
	# One-handed swing: wind back, swing forward, settle. Stubs animate ONLY
	# the weapon holder - body lunge and tint stay in `_flash_attack_feedback`.
	var anim := Animation.new()
	anim.length = 0.32
	_add_value_track(anim, _HOLDER_ROT_PATH, [
		[0.00, _holder_rotation(0.0)],
		[0.06, _holder_rotation(-0.7)],
		[0.18, _holder_rotation(0.9)],
		[0.32, _holder_rotation(0.0)],
	])
	return anim


func _build_melee_thrust_animation() -> Animation:
	# Straight forward stab: push the holder forward, snap back.
	var anim := Animation.new()
	anim.length = 0.28
	_add_value_track(anim, _HOLDER_POS_PATH, [
		[0.00, _holder_offset(Vector2.ZERO)],
		[0.10, _holder_offset(Vector2(8.0, 0.0))],
		[0.20, _holder_offset(Vector2.ZERO)],
		[0.28, _holder_offset(Vector2.ZERO)],
	])
	_add_value_track(anim, _HOLDER_ROT_PATH, [
		[0.00, _holder_rotation(0.0)],
		[0.10, _holder_rotation(0.15)],
		[0.28, _holder_rotation(0.0)],
	])
	return anim


func _build_melee_chop_animation() -> Animation:
	# Two-handed overhead chop: raise up, slam down, settle. Slower arc than
	# the one-handed slash so heavy weapons read as heavy.
	var anim := Animation.new()
	anim.length = 0.45
	_add_value_track(anim, _HOLDER_ROT_PATH, [
		[0.00, _holder_rotation(0.0)],
		[0.12, _holder_rotation(-1.5)],
		[0.28, _holder_rotation(1.3)],
		[0.45, _holder_rotation(0.0)],
	])
	_add_value_track(anim, _HOLDER_POS_PATH, [
		[0.00, _holder_offset(Vector2.ZERO)],
		[0.12, _holder_offset(Vector2(-2.0, -4.0))],
		[0.28, _holder_offset(Vector2(2.0, 3.0))],
		[0.45, _holder_offset(Vector2.ZERO)],
	])
	return anim


func _build_ranged_bow_animation() -> Animation:
	# Draw (pull arm back via small body squash), release (quick forward flick
	# on the holder), settle. Projectile VFX lives in `_launch_bolt`.
	var anim := Animation.new()
	anim.length = 0.45
	_add_value_track(anim, _BODY_SCALE_PATH, [
		[0.00, Vector3.ONE],
		[0.18, Vector3(0.96, 1.04, 0.96)],
		[0.30, Vector3.ONE],
		[0.45, Vector3.ONE],
	])
	_add_value_track(anim, _HOLDER_ROT_PATH, [
		[0.00, _holder_rotation(0.0)],
		[0.18, _holder_rotation(-0.25)],
		[0.26, _holder_rotation(0.35)],
		[0.45, _holder_rotation(0.0)],
	])
	return anim


func _build_cast_staff_animation() -> Animation:
	# Raise the staff, hold briefly, then settle. The 2D body glow (a modulate
	# track) is a HitFlash3D tint fired by `_flash_ranged_feedback`.
	var anim := Animation.new()
	anim.length = 0.55
	_add_value_track(anim, _HOLDER_ROT_PATH, [
		[0.00, _holder_rotation(0.0)],
		[0.15, _holder_rotation(-0.5)],
		[0.40, _holder_rotation(-0.5)],
		[0.55, _holder_rotation(0.0)],
	])
	_add_value_track(anim, _HOLDER_POS_PATH, [
		[0.00, _holder_offset(Vector2.ZERO)],
		[0.15, _holder_offset(Vector2(-2.0, -6.0))],
		[0.40, _holder_offset(Vector2(-2.0, -6.0))],
		[0.55, _holder_offset(Vector2.ZERO)],
	])
	return anim


func _build_unarmed_animation() -> Animation:
	# Punch: quick jab forward. Reused when no weapon is equipped.
	var anim := Animation.new()
	anim.length = 0.22
	_add_value_track(anim, _HOLDER_POS_PATH, [
		[0.00, _holder_offset(Vector2.ZERO)],
		[0.08, _holder_offset(Vector2(6.0, 0.0))],
		[0.22, _holder_offset(Vector2.ZERO)],
	])
	return anim
