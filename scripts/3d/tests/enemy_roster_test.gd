extends Node3D

## Track B test: the enemy roster, statuses and the boss, against a stub player
## on a flat floor with one prop wall and a runtime navmesh bake. No
## coordinator runs; a stub node in group `level_coordinator` records the
## boss's `register_spawned_enemy` calls.
##
## Steps: every roster scene instances with its exports, a mesh and its clips;
## statuses (stun skips move and attack, weaken halves, refresh keeps the
## larger, poison ticks, expose multiplies, root pins, the status line, all
## cleared when turn combat ends, poison can kill); the dire wolf's third bite
## is heavy and the brute shrugs off 20 %; knockback slides away and stops at
## the wall; `is_back_turned_to`; the detection multiplier shrinks `can_spot`
## and the ring (with the 2 cm rebuild rule); environment damage never
## provokes and a root applied in exploration melts; wandering stays inside its radius at the calm pace, investigate
## walks, looks and returns, and a survivor walks home after a fight; the
## cultist fires a bolt from range and backs off a close player first; the
## boss's slam hits a player still inside and misses one who left, phase 2
## raises two wolves registered with the coordinator, the boss bar shows and
## the boss dies with its loot.
##
## Prints ROSTER OK, or ROSTER FAIL: <step>: <reason>.
##
##   godot --headless --path . res://scenes/3d/tests/enemy_roster_test.tscn --quit-after 3000

class RosterPlayer extends "res://scripts/3d/stubs/stub_player_3d.gd":
	## What `get_detection_multiplier` answers (docs/gameplay-expansion.md 4).
	var detection_multiplier := 1.0

	func get_detection_multiplier() -> float:
		return detection_multiplier


class StubCoordinator extends Node:
	var registered: Array[Node] = []

	func register_spawned_enemy(enemy: CharacterBody3D) -> void:
		registered.append(enemy)


const WOLF_SCENE := "res://scenes/3d/wolf_3d.tscn"
const DIRE_WOLF_SCENE := "res://scenes/3d/enemies/dire_wolf_3d.tscn"
const BANDIT_SCENE := "res://scenes/3d/enemies/bandit_3d.tscn"
const CULTIST_SCENE := "res://scenes/3d/enemies/cultist_3d.tscn"
const BRUTE_SCENE := "res://scenes/3d/enemies/brute_3d.tscn"
const WARDEN_SCENE := "res://scenes/3d/enemies/grave_warden_3d.tscn"

## scene, display name, health, XP, boss, move clip, turn budget from 6 m
const ROSTER: Array = [
	[WOLF_SCENE, "Wolf", 36, 35, false, &"trot", 6.0],
	[DIRE_WOLF_SCENE, "Dire Wolf", 70, 70, false, &"trot", 6.0],
	[BANDIT_SCENE, "Bandit", 45, 50, false, &"walk", 7.0],
	[CULTIST_SCENE, "Cultist", 32, 55, false, &"walk", 6.0],
	[BRUTE_SCENE, "Brute", 95, 90, false, &"walk", 5.0],
	[WARDEN_SCENE, "Grave Warden", 320, 400, true, &"walk", 6.0],
]

const NAV_MAP_FRAMES := 90
const NAV_PROBE := Vector3(0.0, 0.0, 5.0)
const HEADLESS_FPS := 60

const STATUS_AREA := Vector3(-10.0, 0.0, 10.0)
const HEAVY_AREA := Vector3(10.0, 0.0, 10.0)
const KNOCKBACK_START := Vector3(0.0, 0.0, -10.0)
## The wall's face toward the knockback wolf (box at x = 4, 0.6 m thick).
const WALL_FACE_X := 3.7
const DETECTION_AREA := Vector3(-10.0, 0.0, -10.0)
const ENVIRONMENT_AREA := Vector3(-20.0, 0.0, -20.0)
const WANDER_AREA := Vector3(0.0, 0.0, 20.0)
const CULTIST_AREA := Vector3(20.0, 0.0, -10.0)
const WARDEN_AREA := Vector3(18.0, 0.0, 18.0)
const PARK_PLAYER := Vector3(-25.0, 0.0, 25.0)

@onready var camera: Camera3D = $Camera3D
@onready var nav_region: NavigationRegion3D = $NavigationRegion3D

var _player: RosterPlayer = null
var _coordinator: StubCoordinator = null
var _step := "boot"
var _done := false


func _ready() -> void:
	Engine.max_fps = HEADLESS_FPS
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 40.0
	camera.current = true
	var back := Vector3(0.0, 0.0, 40.0).rotated(Vector3.RIGHT, deg_to_rad(-35.0)).rotated(Vector3.UP, deg_to_rad(45.0))
	camera.global_position = back
	camera.look_at(Vector3.ZERO, Vector3.UP)
	_build_player()
	_coordinator = StubCoordinator.new()
	_coordinator.name = "StubCoordinator"
	_coordinator.add_to_group("level_coordinator")
	add_child(_coordinator)
	nav_region.bake_finished.connect(_on_bake_finished)
	nav_region.bake_navigation_mesh()


func _exit_tree() -> void:
	if not _done:
		print("ROSTER FAIL: %s: quit before the test finished" % _step)


func _build_player() -> void:
	_player = RosterPlayer.new()
	_player.name = "Player"
	_player.collision_layer = 2
	_player.collision_mask = 9
	_player.max_health = 5000
	var shape_node := CollisionShape3D.new()
	shape_node.name = "CollisionShape3D"
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.35
	capsule.height = 1.8
	shape_node.shape = capsule
	shape_node.position = Vector3(0.0, 0.9, 0.0)
	_player.add_child(shape_node)
	var anchor := Node3D.new()
	anchor.name = "OverheadAnchor"
	anchor.position = Vector3(0.0, 2.15, 0.0)
	_player.add_child(anchor)
	_player.add_to_group("player")
	add_child(_player)
	_player.snap_to(PARK_PLAYER)


func _on_bake_finished() -> void:
	var map := get_world_3d().navigation_map
	for _i in range(NAV_MAP_FRAMES):
		await get_tree().physics_frame
		var closest := NavigationServer3D.map_get_closest_point(map, NAV_PROBE)
		if GroundMath.ground_distance(closest, NAV_PROBE) < 0.5:
			break
	_run()


func _run() -> void:
	# The rogue's defence multiplier is 1.0, so what lands on the stub is exact.
	if not _player.shift_to(int(Soul.Kind.ROGUE)):
		_fail("could not put the stub player in the rogue soul")
		return
	var steps: Array = [
		["instances", _step_instances],
		["statuses", _step_statuses],
		["poison_kills", _step_poison_kills],
		["heavy_and_armour", _step_heavy_and_armour],
		["knockback", _step_knockback],
		["back_turned", _step_back_turned],
		["detection_multiplier", _step_detection_multiplier],
		["environment_damage", _step_environment_damage],
		["wander", _step_wander],
		["cultist", _step_cultist],
		["boss", _step_boss],
	]
	for entry: Array in steps:
		_step = String(entry[0])
		var step: Callable = entry[1]
		var result: Variant = await step.call()
		var failure := str(result)
		if not failure.is_empty():
			_fail(failure)
			return
		print("[roster] %s ok" % _step)
	_done = true
	print("ROSTER OK")
	get_tree().quit(0)


func _fail(reason: String) -> void:
	if _done:
		return
	_done = true
	print("ROSTER FAIL: %s: %s" % [_step, reason])
	get_tree().quit(1)


# --- Steps -----------------------------------------------------------------------

## Every roster scene: script class, exports, layers, children, a mesh under
## Model, the idle and move clips, the turn budget, the tint.
func _step_instances() -> String:
	var spawned: Array[Enemy3D] = []
	var x := -20.0
	for row: Array in ROSTER:
		var path := String(row[0])
		var enemy := _spawn(path, Vector3(x, 0.0, 0.0))
		x += 4.0
		if enemy == null:
			return "%s does not instance as an Enemy3D" % path
		spawned.append(enemy)
		var label := "%s (%s)" % [path.get_file(), enemy.name]
		if enemy.get_display_name() != String(row[1]):
			return "%s display name '%s', expected '%s'" % [label, enemy.get_display_name(), row[1]]
		if enemy.max_health != int(row[2]) or enemy.health != int(row[2]):
			return "%s health %d / %d, expected %d" % [label, enemy.health, enemy.max_health, row[2]]
		if enemy.experience_reward != int(row[3]):
			return "%s XP %d, expected %d" % [label, enemy.experience_reward, row[3]]
		if enemy.is_boss() != bool(row[4]):
			return "%s is_boss() is %s" % [label, str(enemy.is_boss())]
		if enemy.get_portrait_color().a <= 0.0:
			return "%s has a transparent portrait colour" % label
		if enemy.collision_layer != 2 or enemy.collision_mask != 9:
			return "%s layer %d mask %d, expected 2 and 9" % [label, enemy.collision_layer, enemy.collision_mask]
		for child_name in ["CollisionShape3D", "NavigationAgent3D", "OverheadAnchor", "Model"]:
			if enemy.get_node_or_null(child_name) == null:
				return "%s has no %s child" % [label, child_name]
		if not enemy.is_in_group("enemies"):
			return "%s is not in group enemies" % label
		var model := enemy.get_node("Model")
		if model.find_children("*", "MeshInstance3D", true, false).is_empty():
			return "%s has no MeshInstance3D under Model" % label
		var anim := enemy.get_animation_player()
		if anim == null or not anim.has_animation(&"idle") or not anim.has_animation(StringName(row[5])):
			return "%s has no AnimationPlayer with idle and %s" % [label, row[5]]
		if enemy.move_clip != StringName(row[5]):
			return "%s move_clip '%s', expected '%s'" % [label, enemy.move_clip, row[5]]
		enemy.set_turn_based_combat(true)
		enemy.start_turn(6.0)
		if absf(enemy.get_turn_remaining_move_meters() - float(row[6])) > 0.001:
			return "%s starts a turn with %.2f m, expected %.2f m" % [label, enemy.get_turn_remaining_move_meters(), row[6]]
		enemy.end_turn()
		enemy.set_turn_based_combat(false)
	if not (spawned[1] is DireWolf3D):
		return "the dire wolf is not a DireWolf3D"
	if not (spawned[3] is RangedEnemy3D):
		return "the cultist is not a RangedEnemy3D"
	if not (spawned[5] is BossEnemy3D):
		return "the grave warden is not a BossEnemy3D"
	# The wolf keeps the imported materials; a tinted body gets overrides.
	if _count_surface_overrides(spawned[0]) != 0:
		return "the wolf carries %d material overrides, expected none (untinted)" % _count_surface_overrides(spawned[0])
	if _count_surface_overrides(spawned[2]) == 0:
		return "the bandit's model_tint left no material overrides"
	for enemy in spawned:
		enemy.queue_free()
	await get_tree().process_frame
	return ""


## Statuses on a wolf in turn mode, the stub player 1.2 m away.
func _step_statuses() -> String:
	var wolf := _spawn(WOLF_SCENE, STATUS_AREA)
	_player.snap_to(STATUS_AREA + Vector3(1.2, 0.0, 0.0))
	await _frames(2)
	wolf.set_target(_player)
	wolf.set_turn_based_combat(true)

	# Stun: no movement, no attack, and it is gone after the turn.
	wolf.apply_status(Enemy3D.STATUS_STUN, 1)
	if not wolf.has_status(Enemy3D.STATUS_STUN) or wolf.get_status_turns(Enemy3D.STATUS_STUN) != 1:
		return "apply_status(stun, 1) left %d turns" % wolf.get_status_turns(Enemy3D.STATUS_STUN)
	wolf.start_turn(6.0)
	if wolf.get_turn_remaining_move_meters() != 0.0 or wolf.can_turn_attack() or not wolf.is_skipping_turn():
		return "a stunned wolf has %.2f m, attack %s, skipping %s" % [wolf.get_turn_remaining_move_meters(), str(wolf.can_turn_attack()), str(wolf.is_skipping_turn())]
	var before := _player.health
	var started: bool = await wolf.try_attack(_player)
	if started or _player.health != before:
		return "a stunned wolf attacked (started %s, player %d -> %d)" % [str(started), before, _player.health]
	wolf.end_turn()
	if wolf.has_status(Enemy3D.STATUS_STUN):
		return "the stun outlived the turn it skipped"

	# Weaken: the bite, and the damage handed to the counter handshake, halve.
	wolf.apply_status(Enemy3D.STATUS_WEAKEN, 2)
	wolf.start_turn(6.0)
	before = _player.health
	started = await wolf.try_attack(_player)
	var dealt := before - _player.health
	if not started or dealt != 5:
		return "a weakened wolf (10 damage) dealt %d (started %s), expected 5" % [dealt, str(started)]
	wolf.end_turn()
	if wolf.get_status_turns(Enemy3D.STATUS_WEAKEN) != 1:
		return "weaken has %d turns after one turn, expected 1" % wolf.get_status_turns(Enemy3D.STATUS_WEAKEN)

	# Refresh keeps the longer duration and the higher power.
	wolf.apply_status(Enemy3D.STATUS_POISON, 1, 2)
	wolf.apply_status(Enemy3D.STATUS_POISON, 3, 1)
	var poison: Dictionary = wolf.get_statuses().get(Enemy3D.STATUS_POISON, {})
	if int(poison.get("turns", 0)) != 3 or int(poison.get("power", 0)) != 2:
		return "poison refreshed to %s, expected 3 turns at power 2" % str(poison)

	# Poison ticks at the start of the turn.
	var wolf_before := wolf.health
	wolf.start_turn(6.0)
	if wolf_before - wolf.health != 2:
		return "poison power 2 took %d health at the start of the turn" % (wolf_before - wolf.health)
	wolf.end_turn()
	if wolf.get_status_turns(Enemy3D.STATUS_POISON) != 2 or wolf.has_status(Enemy3D.STATUS_WEAKEN):
		return "after the turn: poison %d turns (expected 2), weaken %s (expected gone)" % [wolf.get_status_turns(Enemy3D.STATUS_POISON), str(wolf.has_status(Enemy3D.STATUS_WEAKEN))]

	# Expose: 50 % more damage taken.
	wolf.apply_status(Enemy3D.STATUS_EXPOSE, 1)
	wolf_before = wolf.health
	wolf.receive_damage(10)
	if wolf_before - wolf.health != 15:
		return "an exposed wolf took %d from a 10 hit, expected 15" % (wolf_before - wolf.health)

	# Root: no movement, attack kept, ring shown.
	wolf.apply_root(1)
	wolf.start_turn(6.0)
	if wolf.get_turn_remaining_move_meters() != 0.0 or not wolf.can_turn_attack() or not wolf.is_rooted():
		return "a rooted wolf has %.2f m and attack %s" % [wolf.get_turn_remaining_move_meters(), str(wolf.can_turn_attack())]
	if wolf.get_root_ring() == null or not wolf.get_root_ring().visible:
		return "the root ring is not shown while rooted"
	var expected_text := wolf.get_status_text()
	if not expected_text.contains("ROOT 1") or not expected_text.contains("POISON"):
		return "status text '%s' lacks ROOT 1 and POISON" % expected_text
	await _frames(1)
	if wolf.get_status_line() == null or wolf.get_status_line().get_text() != expected_text:
		return "the status line reads '%s', expected '%s'" % [wolf.get_status_line().get_text() if wolf.get_status_line() != null else "<none>", expected_text]
	wolf.end_turn()

	# Everything clears when turn combat ends.
	wolf.apply_status(Enemy3D.STATUS_STUN, 2)
	wolf.apply_status(Enemy3D.STATUS_BURN, 2, 4)
	wolf.apply_root(2)
	wolf.set_turn_based_combat(false)
	if not wolf.get_statuses().is_empty():
		return "statuses left after turn combat ended: %s" % str(wolf.get_statuses())
	if wolf.get_root_ring().visible or not wolf.get_status_line().get_text().is_empty():
		return "the root ring or the status line survived the end of combat"
	wolf.queue_free()
	await get_tree().process_frame
	return ""


func _step_poison_kills() -> String:
	var wolf := _spawn(WOLF_SCENE, STATUS_AREA + Vector3(0.0, 0.0, 4.0))
	await _frames(2)
	wolf.set_turn_based_combat(true)
	wolf.health = 2
	wolf.apply_status(Enemy3D.STATUS_POISON, 2, 5)
	wolf.start_turn(6.0)
	if wolf.is_alive():
		return "poison 5 did not kill a wolf on 2 health"
	if wolf.get_turn_remaining_move_meters() != 0.0 or wolf.can_turn_attack():
		return "a wolf killed by poison still has %.2f m / attack %s" % [wolf.get_turn_remaining_move_meters(), str(wolf.can_turn_attack())]
	await _pause(0.8)
	if is_instance_valid(wolf):
		return "the poisoned wolf was not freed after its death beat"
	return ""


## The dire wolf's 3rd bite is heavy (x1.5), the brute takes 20 % less.
func _step_heavy_and_armour() -> String:
	var dire := _spawn(DIRE_WOLF_SCENE, HEAVY_AREA) as DireWolf3D
	_player.snap_to(HEAVY_AREA + Vector3(1.4, 0.0, 0.0))
	await _frames(2)
	dire.set_turn_based_combat(true)
	var dealt: Array[int] = []
	var heavy_flags: Array[bool] = []
	for _i in range(3):
		heavy_flags.append(dire.is_next_bite_heavy())
		dire.start_turn(6.0)
		var before := _player.health
		var started: bool = await dire.try_attack(_player)
		if not started:
			return "the dire wolf refused to bite at %.2f m" % GroundMath.ground_distance(dire.global_position, _player.global_position)
		dealt.append(before - _player.health)
		dire.end_turn()
	if dealt != [14, 14, 21] or heavy_flags != [false, false, true]:
		return "dire wolf bites dealt %s (heavy %s), expected [14, 14, 21] with the third heavy" % [str(dealt), str(heavy_flags)]
	dire.queue_free()

	var brute := _spawn(BRUTE_SCENE, HEAVY_AREA + Vector3(0.0, 0.0, 5.0))
	await _frames(1)
	var brute_before := brute.health
	brute.receive_damage(10)
	if brute_before - brute.health != 8:
		return "the brute took %d from a 10 hit, expected 8" % (brute_before - brute.health)
	brute.set_turn_based_combat(true)
	brute.apply_status(Enemy3D.STATUS_EXPOSE, 1)
	brute_before = brute.health
	brute.receive_damage(10)
	if brute_before - brute.health != 12:
		return "the exposed brute took %d from a 10 hit, expected 12" % (brute_before - brute.health)
	brute.queue_free()
	await get_tree().process_frame
	return ""


## A shove slides the wolf away from the source, and a long one stops at the wall.
func _step_knockback() -> String:
	var wolf := _spawn(WOLF_SCENE, KNOCKBACK_START)
	_player.snap_to(PARK_PLAYER)
	await _frames(2)
	var start := wolf.global_position
	wolf.knockback(start + Vector3(-1.0, 0.0, 0.0), 1.0)
	if not wolf.is_knocked_back():
		return "knockback(1 m) did not start a slide"
	await _pause(0.3)
	var moved := wolf.global_position - start
	if moved.x < 0.8 or moved.x > 1.05 or absf(moved.z) > 0.1:
		return "a 1 m shove along +X moved the wolf by %s" % str(moved)
	if wolf.is_knocked_back():
		return "the slide is still running 0.3 s later"
	var second_start := wolf.global_position
	wolf.knockback(second_start + Vector3(-1.0, 0.0, 0.0), 6.0)
	await _pause(0.3)
	var half_width := ActorBase3D.collision_radius_of(wolf)
	var end_x := wolf.global_position.x
	if end_x < second_start.x + 1.0:
		return "a 6 m shove toward the wall only moved the wolf from x=%.2f to x=%.2f" % [second_start.x, end_x]
	if end_x > WALL_FACE_X - 0.3:
		return "the wolf slid to x=%.2f, into the wall whose face is at x=%.2f (footprint radius %.2f)" % [end_x, WALL_FACE_X, half_width]
	print("[roster] knockback: 1 m shove moved %.2f m, 6 m shove stopped at x=%.2f (wall face %.2f)" % [moved.x, end_x, WALL_FACE_X])
	return ""


func _step_back_turned() -> String:
	var wolf := _find_enemy_near(KNOCKBACK_START, 5.0)
	if wolf == null:
		return "the knockback wolf is gone"
	wolf.rotation.y = GroundMath.yaw_facing(Vector3(0.0, 0.0, -1.0))
	var at := wolf.global_position
	var cases: Array = [
		[Vector3(0.0, 0.0, -3.0), false, "in front"],
		[Vector3(3.0, 0.0, 0.0), false, "at its side (90 degrees)"],
		[Vector3(0.0, 0.0, 3.0), true, "behind"],
		[Vector3(1.0, 0.0, 3.0), true, "behind and to the side (162 degrees)"],
		[Vector3(3.0, 0.0, -1.0), false, "ahead and to the side (72 degrees)"],
	]
	for case: Array in cases:
		var offset: Vector3 = case[0]
		if wolf.is_back_turned_to(at + offset) != bool(case[1]):
			return "is_back_turned_to a point %s answered %s" % [case[2], str(not bool(case[1]))]
	wolf.queue_free()
	await get_tree().process_frame
	return ""


## `can_spot` and the ring follow the target's detection multiplier.
func _step_detection_multiplier() -> String:
	var wolf := _spawn(WOLF_SCENE, DETECTION_AREA)
	_player.snap_to(DETECTION_AREA + Vector3(4.0, 0.0, 0.0))
	_player.detection_multiplier = 0.5
	wolf.set_target(_player)
	await _frames(3)
	if wolf.can_spot(_player):
		return "the wolf spots the player at 4 m with a 0.5 multiplier (effective %.2f m)" % wolf.get_effective_detection_range()
	if absf(wolf.get_effective_detection_range() - 2.5) > 0.001:
		return "effective detection %.2f m, expected 2.5 m" % wolf.get_effective_detection_range()
	var ring := wolf.get_detection_ring()
	if ring == null or not ring.visible or absf(ring.radius - 2.5) > 0.001:
		return "the ring is %s at %.2f m, expected visible at 2.5 m" % [str(ring.visible) if ring != null else "missing", ring.radius if ring != null else -1.0]
	# Less than 2 cm of change: no rebuild.
	_player.detection_multiplier = 0.502
	await _frames(2)
	if absf(ring.radius - 2.5) > 0.001:
		return "the ring rebuilt to %.3f m for a 1 cm change" % ring.radius
	_player.detection_multiplier = 0.0
	await _frames(2)
	if wolf.can_spot(_player) or wolf.get_effective_detection_range() != 0.0:
		return "a multiplier of 0 still lets the wolf see (effective %.2f m)" % wolf.get_effective_detection_range()
	if not ring.visible or absf(ring.radius - Enemy3D.DETECTION_RING_MIN_RADIUS_M) > 0.001:
		return "the ring is %.2f m with multiplier 0, expected the %.2f m minimum" % [ring.radius, Enemy3D.DETECTION_RING_MIN_RADIUS_M]
	# Multiplier 1 at 4 m inside the 5 m range: spotted (checked before any
	# physics frame can start the realtime chase).
	_player.detection_multiplier = 1.0
	var spotted := wolf.can_spot(_player)
	_player.detection_multiplier = 0.0
	if not spotted:
		return "the wolf does not spot the player at 4 m with multiplier 1"
	wolf.set_target(null)
	_player.detection_multiplier = 1.0
	_player.snap_to(PARK_PLAYER)
	wolf.queue_free()
	await get_tree().process_frame
	return ""


func _step_environment_damage() -> String:
	var wolf := _spawn(WOLF_SCENE, ENVIRONMENT_AREA)
	await _frames(2)
	var provoked: Array[int] = [0]
	wolf.provoked_by_hit.connect(func() -> void: provoked[0] += 1)
	var before := wolf.health
	wolf.take_environment_damage(5)
	if before - wolf.health != 5:
		return "environment damage 5 took %d" % (before - wolf.health)
	if provoked[0] != 0:
		return "environment damage emitted provoked_by_hit"
	if not wolf.is_unaware() or wolf.is_alerted():
		return "environment damage alerted the wolf (unaware %s)" % str(wolf.is_unaware())
	# A trap's root on an unaware enemy melts in exploration (one turn per 3 s).
	wolf.apply_status(Enemy3D.STATUS_ROOT, 1)
	if not wolf.is_rooted():
		return "apply_status(root, 1) in exploration did not root the wolf"
	var melted := await _wait_until(func() -> bool: return not wolf.is_rooted(),
		Enemy3D.EXPLORATION_STATUS_TURN_SECONDS + 1.0)
	if not melted:
		return "a 1-turn root applied in exploration still holds after %.1f s" % (Enemy3D.EXPLORATION_STATUS_TURN_SECONDS + 1.0)
	wolf.receive_damage(1)
	if provoked[0] != 1 or wolf.is_unaware():
		return "a normal hit did not provoke (%d signals, unaware %s)" % [provoked[0], str(wolf.is_unaware())]
	wolf.queue_free()
	await get_tree().process_frame
	return ""


## Wander inside the radius at the calm pace; investigate and come back; walk
## home after a fight.
func _step_wander() -> String:
	var wolf := _spawn(WOLF_SCENE, WANDER_AREA, {"wander_radius": 3.0, "wander_pause": Vector2(0.1, 0.3)})
	await _frames(2)
	var home := wolf.get_home_position()
	if GroundMath.ground_distance(home, WANDER_AREA) > 0.05:
		return "home is %s, expected the spawn %s" % [str(home), str(WANDER_AREA)]
	var full_speed := 3.6
	var farthest := 0.0
	var fastest := 0.0
	var saw_wander := false
	var deadline := Time.get_ticks_msec() + 5000
	while Time.get_ticks_msec() < deadline:
		await get_tree().physics_frame
		farthest = maxf(farthest, GroundMath.ground_distance(wolf.global_position, home))
		fastest = maxf(fastest, Vector2(wolf.velocity.x, wolf.velocity.z).length())
		if wolf.get_calm_state() == &"wander":
			saw_wander = true
	if not saw_wander or farthest < 0.5:
		return "the wolf did not wander (farthest %.2f m from home, saw wander %s)" % [farthest, str(saw_wander)]
	if farthest > wolf.wander_radius + 0.3:
		return "the wolf wandered %.2f m from home, radius %.1f m" % [farthest, wolf.wander_radius]
	if fastest > full_speed * Enemy3D.CALM_SPEED_FACTOR + 0.1:
		return "the wolf wandered at %.2f m/s, expected at most %.2f" % [fastest, full_speed * Enemy3D.CALM_SPEED_FACTOR]
	print("[roster] wander: farthest %.2f m from home, top speed %.2f m/s" % [farthest, fastest])

	# Investigate: walk there, look around, walk home.
	wolf.wander_radius = 0.0
	var point := home + Vector3(2.5, 0.0, 0.0)
	wolf.investigate(point)
	if wolf.get_calm_state() != &"investigate":
		return "investigate() left the calm state at '%s'" % wolf.get_calm_state()
	if not await _wait_until(func() -> bool: return wolf.get_calm_state() == &"look_around", 6.0):
		return "the wolf never reached the investigated point (state '%s', %.2f m away)" % [wolf.get_calm_state(), GroundMath.ground_distance(wolf.global_position, point)]
	if GroundMath.ground_distance(wolf.global_position, point) > 0.5:
		return "the wolf looks around %.2f m from the point" % GroundMath.ground_distance(wolf.global_position, point)
	if not await _wait_until(func() -> bool: return wolf.get_calm_state() == &"idle", 10.0):
		return "the wolf never came home after investigating (state '%s')" % wolf.get_calm_state()
	if GroundMath.ground_distance(wolf.global_position, home) > 0.5:
		return "after investigating the wolf rests %.2f m from home" % GroundMath.ground_distance(wolf.global_position, home)

	# A survivor walks home when the fight ends.
	wolf.set_turn_based_combat(true)
	wolf.snap_to(home + Vector3(-3.0, 0.0, 0.0))
	wolf.set_turn_based_combat(false)
	if wolf.get_calm_state() != &"home":
		return "after the fight the wolf is '%s', expected 'home'" % wolf.get_calm_state()
	if not await _wait_until(func() -> bool: return GroundMath.ground_distance(wolf.global_position, home) < 0.5 and wolf.get_calm_state() == &"idle", 12.0):
		return "the wolf did not walk home after the fight (%.2f m away, state '%s')" % [GroundMath.ground_distance(wolf.global_position, home), wolf.get_calm_state()]
	if not is_equal_approx(wolf.move_speed, full_speed):
		return "move_speed is %.2f after the calm walk, expected it restored to %.2f" % [wolf.move_speed, full_speed]
	wolf.queue_free()
	await get_tree().process_frame
	return ""


## The cultist fires its bolt from 6 m through the counter handshake, and
## backs off a player who stands at 1.5 m before firing.
func _step_cultist() -> String:
	var cultist := _spawn(CULTIST_SCENE, CULTIST_AREA) as RangedEnemy3D
	_player.snap_to(CULTIST_AREA + Vector3(6.0, 0.0, 0.0))
	await _frames(2)
	cultist.set_turn_based_combat(true)
	cultist.set_target(_player)
	cultist.start_turn(6.0)
	if cultist.wants_retreat():
		return "the cultist wants to retreat from a player 6 m away"
	var before := _player.health
	var started: bool = await cultist.try_attack(_player)
	if not started or before - _player.health != 11:
		return "the cultist's bolt from 6 m: started %s, dealt %d, expected 11" % [str(started), before - _player.health]
	if cultist.get_bolts_fired() != 1:
		return "%d bolts fired, expected 1" % cultist.get_bolts_fired()
	if not cultist.has_shown_counter_prompt():
		return "the bolt did not drive the counter prompt"
	cultist.end_turn()

	_player.snap_to(cultist.global_position + Vector3(1.5, 0.0, 0.0))
	await _frames(1)
	cultist.start_turn(6.0)
	if not cultist.wants_retreat():
		return "the cultist does not want to retreat from a player 1.5 m away"
	var close := GroundMath.ground_distance(cultist.global_position, _player.global_position)
	before = _player.health
	started = await cultist.try_attack(_player)
	var after := GroundMath.ground_distance(cultist.global_position, _player.global_position)
	if after < close + 2.0:
		return "the cultist only backed off from %.2f m to %.2f m" % [close, after]
	if not started or before - _player.health != 11:
		return "after backing off the cultist dealt %d (started %s), expected 11" % [before - _player.health, str(started)]
	if cultist.get_turn_remaining_move_meters() > 6.0 - 2.0:
		return "the step back spent no movement (%.2f m left)" % cultist.get_turn_remaining_move_meters()
	cultist.end_turn()
	print("[roster] cultist: bolt from 6 m, backed off %.2f -> %.2f m and fired" % [close, after])
	cultist.queue_free()
	await get_tree().process_frame
	return ""


## The warden's Grave Slam, phase 2 and its death.
func _step_boss() -> String:
	var warden := _spawn(WARDEN_SCENE, WARDEN_AREA) as BossEnemy3D
	_player.snap_to(WARDEN_AREA + Vector3(4.0, 0.0, 0.0))
	await _frames(2)
	warden.set_turn_based_combat(true)
	warden.set_target(_player)
	await _frames(2)
	if not warden.is_boss_bar_visible():
		return "the boss bar is hidden in turn mode with the player 4 m away"

	# Turn 1: out of reach, so it marks a slam at the player's feet.
	warden.start_turn(6.0)
	var acted: bool = await warden.try_attack(_player)
	if not acted or not warden.has_pending_slam():
		return "the warden did not mark a slam (acted %s)" % str(acted)
	if GroundMath.ground_distance(warden.get_slam_center(), _player.global_position) > 0.05:
		return "the slam ring is at %s, the player at %s" % [str(warden.get_slam_center()), str(_player.global_position)]
	warden.end_turn()

	# The player stays inside: the next turn starts with 26 damage.
	var before := _player.health
	warden.start_turn(6.0)
	if before - _player.health != 26:
		return "a player inside the ring took %d at the warden's next turn, expected 26" % (before - _player.health)
	if warden.get_slams_landed() != 1:
		return "slams landed %d, expected 1" % warden.get_slams_landed()
	acted = await warden.try_attack(_player)
	if not warden.has_pending_slam():
		return "on its second turn, with the player out of reach, the warden marked no slam"
	warden.end_turn()

	# The player walks out: the slam misses.
	_player.snap_to(warden.get_slam_center() + Vector3(0.0, 0.0, 4.0))
	before = _player.health
	warden.start_turn(6.0)
	if _player.health != before:
		return "a player 4 m outside the ring took %d from the slam" % (before - _player.health)
	if warden.has_pending_slam():
		return "the slam is still pending after it resolved"
	warden.end_turn()

	# Phase 2 at half health: two wolves, registered with the coordinator.
	var registered_before := _coordinator.registered.size()
	warden.receive_damage(warden.health - int(warden.max_health * 0.5))
	await _frames(1)
	if warden.get_phase() != 2:
		return "the warden at %d / %d health is in phase %d" % [warden.health, warden.max_health, warden.get_phase()]
	var summons := warden.get_summons()
	if summons.size() != 2:
		return "phase 2 raised %d wolves, expected 2" % summons.size()
	if _coordinator.registered.size() - registered_before != 2:
		return "register_spawned_enemy was called %d times, expected 2" % (_coordinator.registered.size() - registered_before)
	for summon in summons:
		var wolf := summon as Enemy3D
		if wolf == null or not wolf.is_in_group("enemies") or wolf.get_parent() != warden.get_parent():
			return "a summon is not an Enemy3D sibling in group enemies"
		if not _coordinator.registered.has(wolf):
			return "%s was not registered with the coordinator" % wolf.name
		if not wolf.is_in_turn_based_combat() or wolf.get_target() != _player:
			return "%s is not in turn mode with the player as target" % wolf.name
		if GroundMath.ground_distance(wolf.global_position, warden.global_position) > 4.0:
			return "%s rose %.2f m from the warden" % [wolf.name, GroundMath.ground_distance(wolf.global_position, warden.global_position)]
	# A second threshold crossing raises nobody.
	warden.receive_damage(5)
	if warden.get_summons().size() != 2:
		return "a later hit raised more wolves (%d)" % warden.get_summons().size()

	# Phase 2 turn in reach: slam and bite together.
	_player.snap_to(warden.global_position + Vector3(1.5, 0.0, 0.0))
	await _frames(1)
	warden.start_turn(6.0)
	before = _player.health
	acted = await warden.try_attack(_player)
	if not acted or not warden.has_pending_slam() or before - _player.health != 20:
		return "the phase 2 turn: acted %s, slam %s, bite dealt %d (expected a slam and 20)" % [str(acted), str(warden.has_pending_slam()), before - _player.health]
	warden.end_turn()

	# Death: the bar hides, loot spills.
	for summon in warden.get_summons():
		summon.queue_free()
	var death_at := warden.global_position
	warden.receive_damage(100000)
	await _frames(1)
	if warden.is_alive() or warden.is_boss_bar_visible():
		return "the dead warden is alive %s / bar visible %s" % [str(warden.is_alive()), str(warden.is_boss_bar_visible())]
	await _pause(2.0)
	if is_instance_valid(warden):
		return "the warden was not freed 2 s after dying"
	var pickups := 0
	for child in get_children():
		if child is ItemPickup3D and GroundMath.ground_distance((child as Node3D).global_position, death_at) <= 2.0:
			pickups += 1
	if pickups < 4:
		return "the warden dropped %d items, expected its 4 guaranteed ones" % pickups
	return ""


# --- Helpers ---------------------------------------------------------------------

## Instances `path` under the test root at `at`; `properties` are set before
## the enemy enters the tree (so `_ready` sees them).
func _spawn(path: String, at: Vector3, properties: Dictionary = {}) -> Enemy3D:
	var scene := load(path) as PackedScene
	if scene == null:
		return null
	var enemy := scene.instantiate() as Enemy3D
	if enemy == null:
		return null
	for key: String in properties.keys():
		enemy.set(key, properties[key])
	add_child(enemy)
	enemy.snap_to(at)
	return enemy


func _find_enemy_near(at: Vector3, radius: float) -> Enemy3D:
	for node in get_tree().get_nodes_in_group("enemies"):
		var enemy := node as Enemy3D
		if enemy != null and enemy.is_alive() and GroundMath.ground_distance(enemy.global_position, at) <= radius:
			return enemy
	return null


func _count_surface_overrides(enemy: Enemy3D) -> int:
	var count := 0
	for mesh in enemy.get_model_meshes():
		if mesh.mesh == null:
			continue
		for surface in range(mesh.mesh.get_surface_count()):
			if mesh.get_surface_override_material(surface) != null:
				count += 1
	return count


func _frames(count: int) -> void:
	for _i in range(count):
		await get_tree().physics_frame


func _pause(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _wait_until(predicate: Callable, timeout: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if bool(predicate.call()):
			return true
		await get_tree().physics_frame
	return bool(predicate.call())
