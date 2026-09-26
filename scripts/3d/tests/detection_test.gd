extends Node

## WP13 "Detection and ambush": the coordinator (main_3d.gd on the scene root)
## with the real player and three wolves on an arena-style floor with a runtime
## navmesh. Headless has no clicks, so the steps drive the coordinator's request
## methods, which is what a click resolves to.
##
## Steps: (a) every wolf shows its detection ring at its detection radius in
## exploration; (b) walking to 0.5 m outside WolfA's ring starts nothing (the
## ring has turned warning red), stepping inside starts combat with the player's
## turn and COMBAT!, and the rings go; (c) WolfB at 11 m joins, WolfC at 13 m
## does not; (d) after a reset, a rogue throw from 9 m (outside the ring) lands
## and starts combat with the enemy turn and AMBUSH!, the struck wolf and the
## one within 12 m engaged, and the player's turn follows; (e) a mage spell at
## 11 m is refused as out of range and starts nothing; (g) a wolf inside its
## ring but behind a prop does not spot the player until the walk clears the
## line of sight; (f) an unaware wolf (detection 0) is ambushed by the knight's
## click-to-attack melee, enemy turn first.
##
## Prints DETECTION OK, or the first failing step with its values.
##
##   godot --headless --path . res://scenes/3d/tests/detection_test.tscn --quit-after 1200

const Main3D := preload("res://scripts/3d/main_3d.gd")

const HEADLESS_FPS := 60
const NAVMESH_TIMEOUT_SECONDS := 6.0
const MOVE_TIMEOUT_SECONDS := 6.0
const COMBAT_TIMEOUT_SECONDS := 6.0
const AMBUSH_TIMEOUT_SECONDS := 3.0
const ENEMY_TURN_TIMEOUT_SECONDS := 12.0
const SETTLE_SECONDS := 0.2

const PLAYER_START := Vector3(-10.0, 0.0, 0.0)
const WOLF_A_START := Vector3(0.0, 0.0, 0.0)
# From the point where WolfA spots the player, (-5, 0, 0): 11 m joins the
# 12 m engagement radius, 13 m does not.
const WOLF_B_START := Vector3(-5.0, 0.0, 11.0)
const WOLF_C_START := Vector3(-5.0, 0.0, -13.0)
const RING_EDGE_STANDOFF_M := 0.5
# Combat starts on the frame the player crosses the ring; at 3.5 m/s that is
# within one physics step of the edge.
const DETECTION_TOLERANCE_M := 0.05
const DETECTION_STEP_SLACK_M := 0.5
const JOIN_TOLERANCE_M := 0.3

# (d) The throw: WolfA 9 m from the player, outside its 5 m ring and inside the
# rogue's 12 m throw; WolfB 11 m from the player joins, WolfC at 13 m does not.
const THROW_WOLF_A := Vector3(-1.0, 0.0, 0.0)
const THROW_WOLF_B := Vector3(-10.0, 0.0, 11.0)
const THROW_WOLF_C := Vector3(-10.0, 0.0, -13.0)
# (e) Beyond the mage's 10 m spell range.
const SPELL_WOLF_A := Vector3(1.0, 0.0, 0.0)
# (g) The obstacle is a 2 m box centred at (4, 1, -3): the wolf 4 m from the
# player with the box between them; walking to the clear point opens the line.
const LOS_PLAYER := Vector3(4.0, 0.0, -1.0)
const LOS_WOLF := Vector3(4.0, 0.0, -5.0)
const LOS_CLEAR_POINT := Vector3(7.5, 0.0, -3.0)
const LOS_HOLD_SECONDS := 1.0
# (f) The unaware wolf 6 m from the player; the knight walks up and swings from
# about (-5.1, 0, 0), so WolfB and WolfC keep their 11 m and 13 m from there.
const MELEE_WOLF_A := Vector3(-4.0, 0.0, 0.0)
const MELEE_WOLF_B := WOLF_B_START
const MELEE_WOLF_C := WOLF_C_START

var _main: Main3D
var _player: Player3D
var _wolf_a: Enemy3D
var _wolf_b: Enemy3D
var _wolf_c: Enemy3D

var _step := "boot"
var _done := false


func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		Engine.max_fps = HEADLESS_FPS
	process_mode = Node.PROCESS_MODE_ALWAYS
	call_deferred("_run")


func _exit_tree() -> void:
	if not _done:
		print("DETECTION FAIL: quit during step '%s'" % _step)


func _run() -> void:
	await get_tree().process_frame
	var steps: Array = [
		["boot", _step_boot],
		["navmesh", _step_navmesh],
		["rings", _step_rings],
		["ring_edge", _step_ring_edge],
		["spotted", _step_spotted],
		["joining", _step_joining],
		["throw_ambush", _step_throw_ambush],
		["spell_out_of_range", _step_spell_out_of_range],
		["line_of_sight", _step_line_of_sight],
		["melee_ambush", _step_melee_ambush],
	]
	for entry in steps:
		_step = String(entry[0])
		var step: Callable = entry[1]
		var result: Variant = await step.call()
		var failure := str(result)
		if not failure.is_empty():
			_fail(failure)
			return
		print("[detection] %s ok" % _step)
	_done = true
	print("DETECTION OK")
	get_tree().quit(0)


func _fail(reason: String) -> void:
	_done = true
	print("DETECTION FAIL: %s: %s" % [_step, reason])
	get_tree().quit(1)


# --- Steps -----------------------------------------------------------------------

func _step_boot() -> String:
	_main = get_parent() as Main3D
	if _main == null:
		return "main_3d.gd is not on the parent node"
	_player = _main.player as Player3D
	if _player == null:
		return "Player is not a Player3D"
	_wolf_a = _main.get_node_or_null("WolfA") as Enemy3D
	_wolf_b = _main.get_node_or_null("WolfB") as Enemy3D
	_wolf_c = _main.get_node_or_null("WolfC") as Enemy3D
	if _wolf_a == null or _wolf_b == null or _wolf_c == null:
		return "the scene needs WolfA, WolfB and WolfC as Enemy3D"
	if absf(Main3D.ENGAGE_RADIUS_METERS - 12.0) > 0.001:
		return "ENGAGE_RADIUS_METERS is %.1f, expected 12.0" % Main3D.ENGAGE_RADIUS_METERS
	return ""


func _step_navmesh() -> String:
	if not await _wait_until(func() -> bool: return _main.is_navmesh_ready(), NAVMESH_TIMEOUT_SECONDS):
		return "navmesh did not become ready within %.1f s" % NAVMESH_TIMEOUT_SECONDS
	# Two frames so the rings have read the wired target.
	await get_tree().process_frame
	await get_tree().process_frame
	return ""


## (a) Rings in exploration, at the detection radius, calm with the player far.
func _step_rings() -> String:
	if _main.combat_state != Main3D.CombatState.EXPLORATION:
		return "expected EXPLORATION at the start, got %d" % _main.combat_state
	for wolf in [_wolf_a, _wolf_b, _wolf_c]:
		var check := _expect_ring(wolf, true, Enemy3D.DETECTION_RING_COLOR_CALM)
		if not check.is_empty():
			return check
		if absf(wolf.detection_range - 5.0) > 0.001:
			return "%s's detection_range is %.2f m, expected the wolf's 5.0 m" % [wolf.name, wolf.detection_range]
	return ""


## (b1) Standing 0.5 m outside WolfA's ring: nothing starts, the ring warns.
func _step_ring_edge() -> String:
	var wolf := _wolf_a
	var standoff := wolf.global_position + Vector3(-(wolf.detection_range + RING_EDGE_STANDOFF_M), 0.0, 0.0)
	_main._request_player_move(standoff)
	if not _player.is_moving():
		return "the player did not start moving toward the ring edge"
	if not await _wait_until(func() -> bool: return not _player.is_moving() or _main.combat_state != Main3D.CombatState.EXPLORATION, MOVE_TIMEOUT_SECONDS):
		return "the player is still walking to the ring edge after %.1f s" % MOVE_TIMEOUT_SECONDS
	var distance := GroundMath.ground_distance(_player.global_position, wolf.global_position)
	if _main.combat_state != Main3D.CombatState.EXPLORATION:
		return "combat started with the player %.2f m from %s, outside its %.2f m ring" % [distance, wolf.name, wolf.detection_range]
	if distance <= wolf.detection_range:
		return "the player stopped %.2f m from %s, inside the %.2f m ring (aimed %.2f m outside)" % [distance, wolf.name, wolf.detection_range, RING_EDGE_STANDOFF_M]
	await _pause(SETTLE_SECONDS)
	if _main.combat_state != Main3D.CombatState.EXPLORATION:
		return "combat started while standing %.2f m from %s" % [distance, wolf.name]
	if _main._find_spotting_enemy() != null:
		return "%s reports the player spotted at %.2f m" % [_main._find_spotting_enemy().name, distance]
	var check := _expect_ring(wolf, true, Enemy3D.DETECTION_RING_COLOR_WARNING)
	if not check.is_empty():
		return check + " (player %.2f m from the wolf, warning margin %.1f m)" % [distance, Enemy3D.DETECTION_WARNING_MARGIN_M]
	print("[detection] standing %.2f m from %s: no combat, ring warning" % [distance, wolf.name])
	return ""


## (b2) Stepping inside: combat, player's turn first, COMBAT!, rings gone.
func _step_spotted() -> String:
	var wolf := _wolf_a
	_main._request_player_move(wolf.global_position)
	if not await _wait_until(func() -> bool: return _main.combat_state != Main3D.CombatState.EXPLORATION, COMBAT_TIMEOUT_SECONDS):
		return "combat did not start within %.1f s of walking at %s" % [COMBAT_TIMEOUT_SECONDS, wolf.name]
	if _main.combat_state != Main3D.CombatState.PLAYER_TURN:
		return "combat started in state %d, expected the player's turn first" % _main.combat_state
	var distance := GroundMath.ground_distance(_player.global_position, wolf.global_position)
	if distance > wolf.detection_range + DETECTION_TOLERANCE_M:
		return "combat started at %.2f m, outside the %.2f m ring" % [distance, wolf.detection_range]
	if distance < wolf.detection_range - DETECTION_STEP_SLACK_M:
		return "combat started at %.2f m, well inside the %.2f m ring" % [distance, wolf.detection_range]
	if not _banner_reads(Main3D.ANNOUNCE_COMBAT):
		return "the banner reads '%s', expected %s" % [_banner_text(), Main3D.ANNOUNCE_COMBAT]
	if absf(_player.get_turn_remaining_move_meters() - Main3D.TURN_MOVE_METERS) > 0.001:
		return "the player's turn budget is %.2f m, expected %.2f m" % [_player.get_turn_remaining_move_meters(), Main3D.TURN_MOVE_METERS]
	if not _player.can_turn_attack():
		return "the player has no attack on the first turn"
	await get_tree().process_frame
	for other in [_wolf_a, _wolf_b, _wolf_c]:
		var check := _expect_ring(other, false, Color.BLACK)
		if not check.is_empty():
			return check
	print("[detection] spotted at %.2f m from %s, player's turn, %s" % [distance, wolf.name, _banner_text()])
	return ""


## (c) Joining radius: 11 m joins, 13 m does not.
func _step_joining() -> String:
	var distance_b := GroundMath.ground_distance(_player.global_position, _wolf_b.global_position)
	var distance_c := GroundMath.ground_distance(_player.global_position, _wolf_c.global_position)
	if absf(distance_b - 11.0) > JOIN_TOLERANCE_M or absf(distance_c - 13.0) > JOIN_TOLERANCE_M:
		return "WolfB is %.2f m and WolfC %.2f m from the player at combat start, expected about 11 and 13 m" % [distance_b, distance_c]
	if not _main.engaged_enemies.has(_wolf_a.get_instance_id()):
		return "the spotter WolfA is not engaged"
	if not _main.engaged_enemies.has(_wolf_b.get_instance_id()):
		return "WolfB at %.2f m did not join (radius %.1f m)" % [distance_b, Main3D.ENGAGE_RADIUS_METERS]
	if _main.engaged_enemies.has(_wolf_c.get_instance_id()):
		return "WolfC at %.2f m joined (radius %.1f m)" % [distance_c, Main3D.ENGAGE_RADIUS_METERS]
	if _main.engaged_enemies.size() != 2:
		return "%d enemies engaged, expected 2" % _main.engaged_enemies.size()
	print("[detection] WolfB at %.2f m joined, WolfC at %.2f m did not" % [distance_b, distance_c])
	return ""


## (d) The rogue's throw from outside the ring: the hit lands, then combat
## starts with the enemy turn and AMBUSH!; the player's turn follows.
func _step_throw_ambush() -> String:
	_reset_to_exploration(PLAYER_START, THROW_WOLF_A, THROW_WOLF_B, THROW_WOLF_C)
	await get_tree().process_frame
	await get_tree().process_frame
	if _main.combat_state != Main3D.CombatState.EXPLORATION:
		return "not back in exploration after the reset (state %d)" % _main.combat_state
	var check := _expect_ring(_wolf_a, true, Enemy3D.DETECTION_RING_COLOR_CALM)
	if not check.is_empty():
		return "after the reset: " + check
	_main._request_shift(int(Soul.Kind.ROGUE))
	if _player.get_active_soul().kind != Soul.Kind.ROGUE:
		return "could not shift to the rogue in exploration"
	_main._on_turn_ranged_button_pressed()
	if _main.selected_player_turn_action != Main3D.PlayerTurnAction.RANGED:
		return "the Throw button did not arm the throw in exploration"
	_main._update_range_rings()
	if not _main.ranged_range_ring.visible:
		return "the throw range ring is not visible while aiming in exploration"
	if not is_equal_approx(_main.ranged_range_ring.radius, Soul.ROGUE_RANGED_RANGE_METERS):
		return "the throw ring is %.2f m, expected %.2f m" % [_main.ranged_range_ring.radius, Soul.ROGUE_RANGED_RANGE_METERS]
	var distance := GroundMath.ground_distance(_player.global_position, _wolf_a.global_position)
	if distance <= _wolf_a.detection_range or distance > Soul.ROGUE_RANGED_RANGE_METERS:
		return "WolfA is %.2f m away; the throw must come from outside the %.1f m ring and inside %.1f m" % [distance, _wolf_a.detection_range, Soul.ROGUE_RANGED_RANGE_METERS]
	var before := _wolf_a.health
	await _main._request_exploration_ranged_attack(_wolf_a)
	if _wolf_a.health != before - Soul.ROGUE_RANGED_DAMAGE:
		return "WolfA health %d -> %d after the throw, expected a drop of %d" % [before, _wolf_a.health, Soul.ROGUE_RANGED_DAMAGE]
	if not await _wait_until(func() -> bool: return _main.combat_state != Main3D.CombatState.EXPLORATION, AMBUSH_TIMEOUT_SECONDS):
		return "the landed throw did not start combat within %.1f s" % AMBUSH_TIMEOUT_SECONDS
	if _main.combat_state != Main3D.CombatState.ENEMY_TURN:
		return "the ambush started in state %d, expected the enemy turn first" % _main.combat_state
	if not _banner_reads(Main3D.ANNOUNCE_AMBUSH):
		return "the banner reads '%s', expected %s" % [_banner_text(), Main3D.ANNOUNCE_AMBUSH]
	if not _main.engaged_enemies.has(_wolf_a.get_instance_id()):
		return "the struck WolfA is not engaged"
	if not _main.engaged_enemies.has(_wolf_b.get_instance_id()):
		return "WolfB at %.2f m did not join the ambush" % GroundMath.ground_distance(_player.global_position, _wolf_b.global_position)
	if _main.engaged_enemies.has(_wolf_c.get_instance_id()):
		return "WolfC at %.2f m joined the ambush" % GroundMath.ground_distance(_player.global_position, _wolf_c.global_position)
	if _main.selected_player_turn_action != Main3D.PlayerTurnAction.MOVE:
		return "the throw aim is still selected after the ambush started"
	if not await _wait_until(func() -> bool: return _main.combat_state == Main3D.CombatState.PLAYER_TURN, ENEMY_TURN_TIMEOUT_SECONDS):
		return "the ambush enemy turn did not hand back within %.1f s (state %d)" % [ENEMY_TURN_TIMEOUT_SECONDS, _main.combat_state]
	# Gameplay expansion: the budget is per soul (the rogue who threw moves 8 m).
	var expected_budget := Main3D.TURN_MOVE_METERS + float(Player3D.SOUL_MOVE_DELTA_M.get(_player.get_active_soul().kind, 0.0))
	if absf(_player.get_turn_remaining_move_meters() - expected_budget) > 0.001:
		return "the player's first turn after the ambush has %.2f m, expected %.2f m" % [_player.get_turn_remaining_move_meters(), expected_budget]
	print("[detection] throw from %.2f m: WolfA %d -> %d, enemy turn first, then the player's" % [distance, before, _wolf_a.health])
	return ""


## (e) A mage spell beyond its range is refused and starts nothing.
func _step_spell_out_of_range() -> String:
	_reset_to_exploration(PLAYER_START, SPELL_WOLF_A, THROW_WOLF_B, THROW_WOLF_C)
	await get_tree().process_frame
	_main._request_shift(int(Soul.Kind.MAGE))
	if _player.get_active_soul().kind != Soul.Kind.MAGE:
		return "could not shift to the mage in exploration"
	_main._on_turn_spell_button_pressed(Soul.SPELL_ARCANE_BURST)
	if _main.selected_player_turn_action != Main3D.PlayerTurnAction.SPELL or _main.selected_spell_id != Soul.SPELL_ARCANE_BURST:
		return "the Arcane Burst button did not arm the spell in exploration"
	_main._update_range_rings()
	if not _main.ranged_range_ring.visible:
		return "the Arcane Burst range ring is not visible while aiming in exploration"
	var spell := _player.get_active_soul().get_spell(Soul.SPELL_ARCANE_BURST)
	var distance := GroundMath.ground_distance(_player.global_position, _wolf_a.global_position)
	if distance <= spell.range_meters:
		return "WolfA is %.2f m away, inside the %.1f m spell range" % [distance, spell.range_meters]
	var before := _wolf_a.health
	await _main._request_exploration_spell(_wolf_a)
	await _pause(SETTLE_SECONDS)
	if _wolf_a.health != before:
		return "the refused spell still hurt WolfA (%d -> %d)" % [before, _wolf_a.health]
	if _main.combat_state != Main3D.CombatState.EXPLORATION:
		return "a refused spell started combat (state %d)" % _main.combat_state
	if _player.get_spell_cooldown(Soul.SPELL_ARCANE_BURST) != 0:
		return "the refused spell went on cooldown (%d)" % _player.get_spell_cooldown(Soul.SPELL_ARCANE_BURST)
	if _main.selected_player_turn_action != Main3D.PlayerTurnAction.SPELL:
		return "the refusal dropped the spell aim"
	_main._set_player_turn_action(Main3D.PlayerTurnAction.MOVE)
	print("[detection] Arcane Burst at %.2f m refused, no combat" % distance)
	return ""


## (g) Line of sight: inside the ring but behind a prop the player is unseen;
## walking clear of it gets spotted.
func _step_line_of_sight() -> String:
	_reset_to_exploration(LOS_PLAYER, LOS_WOLF, THROW_WOLF_B, THROW_WOLF_C)
	await get_tree().process_frame
	var distance := GroundMath.ground_distance(_player.global_position, _wolf_a.global_position)
	if distance > _wolf_a.detection_range:
		return "WolfA is %.2f m away, outside its %.2f m ring; the obstacle test needs it inside" % [distance, _wolf_a.detection_range]
	if _wolf_a.has_line_of_sight_to(_player):
		return "WolfA reports a clear line of sight through the obstacle at %.2f m" % distance
	if _wolf_a.can_spot(_player):
		return "WolfA spots the player through the obstacle"
	await _pause(LOS_HOLD_SECONDS)
	if _main.combat_state != Main3D.CombatState.EXPLORATION:
		return "combat started with the obstacle between the player and WolfA (%.2f m apart)" % distance
	_main._request_player_move(LOS_CLEAR_POINT)
	if not await _wait_until(func() -> bool: return _main.combat_state != Main3D.CombatState.EXPLORATION, COMBAT_TIMEOUT_SECONDS):
		return "walking clear of the obstacle did not get the player spotted within %.1f s (player at %s, wolf at %s)" % [COMBAT_TIMEOUT_SECONDS, str(_player.global_position), str(_wolf_a.global_position)]
	if _main.combat_state != Main3D.CombatState.PLAYER_TURN:
		return "spotted past the obstacle in state %d, expected the player's turn" % _main.combat_state
	var seen_at := GroundMath.ground_distance(_player.global_position, _wolf_a.global_position)
	if not _wolf_a.has_line_of_sight_to(_player):
		return "combat started at %.2f m with no line of sight" % seen_at
	print("[detection] unseen behind the obstacle at %.2f m, spotted at %.2f m once clear" % [distance, seen_at])
	return ""


## (f) The knight's click-to-attack on an unaware wolf: the swing lands first,
## then combat starts with the enemy turn and AMBUSH!.
func _step_melee_ambush() -> String:
	_reset_to_exploration(PLAYER_START, MELEE_WOLF_A, MELEE_WOLF_B, MELEE_WOLF_C)
	_wolf_a.detection_range = 0.0
	await get_tree().process_frame
	await get_tree().process_frame
	var check := _expect_ring(_wolf_a, false, Color.BLACK)
	if not check.is_empty():
		return "an unaware wolf (detection 0): " + check
	_main._request_shift(int(Soul.Kind.KNIGHT))
	if _player.get_active_soul().kind != Soul.Kind.KNIGHT:
		return "could not shift to the knight in exploration"
	var before := _wolf_a.health
	var expected := _player.get_melee_damage()
	# What a click on the wolf does in exploration.
	_player.set_attack_target(_wolf_a)
	if not await _wait_until(func() -> bool: return _main.combat_state != Main3D.CombatState.EXPLORATION, COMBAT_TIMEOUT_SECONDS):
		return "the melee pursuit did not start combat within %.1f s (wolf health %d -> %d, player %.2f m away)" % [COMBAT_TIMEOUT_SECONDS, before, _wolf_a.health, GroundMath.ground_distance(_player.global_position, _wolf_a.global_position)]
	if _wolf_a.health != before - expected:
		return "WolfA health %d -> %d when combat started, expected the %d melee hit first" % [before, _wolf_a.health, expected]
	if _main.combat_state != Main3D.CombatState.ENEMY_TURN:
		return "the melee ambush started in state %d, expected the enemy turn first" % _main.combat_state
	if not _banner_reads(Main3D.ANNOUNCE_AMBUSH):
		return "the banner reads '%s', expected %s" % [_banner_text(), Main3D.ANNOUNCE_AMBUSH]
	if not _main.engaged_enemies.has(_wolf_a.get_instance_id()):
		return "the struck WolfA is not engaged"
	var distance_b := GroundMath.ground_distance(_player.global_position, _wolf_b.global_position)
	var distance_c := GroundMath.ground_distance(_player.global_position, _wolf_c.global_position)
	if not _main.engaged_enemies.has(_wolf_b.get_instance_id()):
		return "WolfB at %.2f m did not join the melee ambush" % distance_b
	if _main.engaged_enemies.has(_wolf_c.get_instance_id()):
		return "WolfC at %.2f m joined the melee ambush" % distance_c
	print("[detection] knight melee ambush: WolfA %d -> %d, enemy turn first; WolfB at %.2f m joined, WolfC at %.2f m did not" % [before, _wolf_a.health, distance_b, distance_c])
	return ""


# --- Helpers ---------------------------------------------------------------------

## Back to exploration with everyone placed and healed, in one call so no frame
## can start combat in between.
func _reset_to_exploration(player_at: Vector3, a_at: Vector3, b_at: Vector3, c_at: Vector3) -> void:
	if _main.combat_state != Main3D.CombatState.EXPLORATION:
		_main._end_turn_based_combat()
	_main._set_player_turn_action(Main3D.PlayerTurnAction.MOVE)
	_player.stop_movement_immediately()
	_player.snap_to(player_at)
	_player.health = _player.max_health
	for pair: Array in [[_wolf_a, a_at], [_wolf_b, b_at], [_wolf_c, c_at]]:
		var wolf: Enemy3D = pair[0]
		var at: Vector3 = pair[1]
		wolf.stop_movement_immediately()
		wolf.snap_to(at)
		wolf.health = wolf.max_health


func _expect_ring(wolf: Enemy3D, shown: bool, color: Color) -> String:
	var ring := wolf.get_detection_ring()
	if ring == null:
		return "%s has no detection ring" % wolf.name
	if ring.visible != shown:
		return "%s's detection ring is %s, expected %s" % [wolf.name, "visible" if ring.visible else "hidden", "visible" if shown else "hidden"]
	if not shown:
		return ""
	if not is_equal_approx(ring.radius, wolf.detection_range):
		return "%s's detection ring is %.2f m, expected its %.2f m detection range" % [wolf.name, ring.radius, wolf.detection_range]
	if not ring.dashed:
		return "%s's detection ring is not dashed" % wolf.name
	if ring.color != color:
		return "%s's detection ring is %s, expected %s" % [wolf.name, str(ring.color), str(color)]
	return ""


func _banner_text() -> String:
	if CombatFx._banner == null or not is_instance_valid(CombatFx._banner):
		return ""
	return CombatFx._banner.text


func _banner_reads(text: String) -> bool:
	return _banner_text() == text


func _pause(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _wait_until(condition: Callable, timeout_seconds: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if bool(condition.call()):
			return true
		await get_tree().process_frame
	return bool(condition.call())
