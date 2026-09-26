extends Node

## Track A acceptance test for the Wilds (docs/wilds-map.md).
##
## Instances scenes/3d/wilds.tscn under this node (the level itself carries no
## test node), waits for the coordinator's navmesh, then checks the map and
## every hazard:
##   camps     enemy count per camp, packs within 7 m, camps over 25 m apart
##   paths     a navmesh path from the spawn to every clearing, no wall tops
##   trap_enemy     a spike trap damages and roots an enemy in turn mode,
##                  ignores one in exploration; a player-set trap catches it
##   trap_player    an unrevealed trap hurts the player, a revealed one not
##   barrel    a barrel explodes on receive_damage, hurts an enemy within 3 m,
##             spares one outside, and chains to its neighbour
##   cover     a hide zone sees the player enter and leave and calls
##             set_in_cover (checked once the lead's player has it)
##   waystone  a waystone refuses an unattuned stone and moves the player to an
##             attuned one (teleport_to, or the snap fallback)
##   chest     a chest drops loot once
##
## The coordinator's `_process` is paused after boot so no fight starts while
## the steps move actors around by hand.
##
## Prints WILDS OK, or WILDS FAIL: <step>: <reason>.
##
##   godot --headless --path . res://scenes/3d/tests/wilds_test.tscn --quit-after 4000

const WILDS_SCENE_PATH := "res://scenes/3d/wilds.tscn"
const WOLF_SCENE_PATH := "res://scenes/3d/wolf_3d.tscn"
const HEADLESS_FPS := 60
const NAVMESH_TIMEOUT_SECONDS := 10.0
## Farthest two enemies of one camp may stand apart (the brief asks ~6 m).
const PACK_SPREAD_MAX_M := 7.0
## The start glade's two wolves are lone warm-up wolves, not a pack.
const LONE_CAMPS: Array[StringName] = [&"start"]
const CAMP_SEPARATION_M := 25.0
const PATH_END_TOLERANCE_M := 0.3
const NAVMESH_FLOOR_MAX_Y := 1.0

const EXPECTED_ENEMIES := {
	&"start": 2,
	&"den": 4,
	&"camp": 4,
	&"ruins": 4,
	&"boss": 1,
}
const PATH_TARGETS: Array[StringName] = [&"start", &"den", &"camp", &"ruins", &"approach", &"boss"]

var _level: Node3D
var _main: Node
var _player: Node3D
var _spawn := Vector3.ZERO
var _step := "boot"
var _done := false
var _spawned: Array[Node] = []


func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		Engine.max_fps = HEADLESS_FPS
	process_mode = Node.PROCESS_MODE_ALWAYS
	var scene := load(WILDS_SCENE_PATH) as PackedScene
	if scene == null:
		_fail("cannot load %s" % WILDS_SCENE_PATH)
		return
	_level = scene.instantiate() as Node3D
	add_child(_level)
	call_deferred("_run")


func _exit_tree() -> void:
	if not _done:
		print("WILDS FAIL: quit during step '%s'" % _step)


func _run() -> void:
	var steps: Array = [
		["boot", _step_boot],
		["camps", _step_camps],
		["paths", _step_paths],
		["trap_enemy", _step_trap_enemy],
		["trap_player", _step_trap_player],
		["barrel", _step_barrel],
		["cover", _step_cover],
		["waystone", _step_waystone],
		["chest", _step_chest],
	]
	for entry in steps:
		_step = String(entry[0])
		var step: Callable = entry[1]
		var result: Variant = await step.call()
		var failure := str(result)
		if not failure.is_empty():
			_fail(failure)
			return
		print("[wilds] %s ok" % _step)
	_done = true
	print("WILDS OK")
	get_tree().quit(0)


func _fail(reason: String) -> void:
	_done = true
	print("WILDS FAIL: %s: %s" % [_step, reason])
	get_tree().quit(1)


# --- Steps ----------------------------------------------------------------------------

func _step_boot() -> String:
	_main = _level
	_player = _level.get_node_or_null("Player") as Node3D
	if _player == null:
		return "no Player node"
	var spawn := _level.get_node_or_null("Spawn_default") as Node3D
	if spawn == null:
		return "no Spawn_default node"
	_spawn = GroundMath.flatten(spawn.global_position)
	if _level.get_node_or_null("IntegrationSmoke") != null:
		return "the level must not carry an IntegrationSmoke node"
	var elapsed := 0.0
	while not bool(_main.call("is_navmesh_ready")):
		await get_tree().physics_frame
		elapsed += 1.0 / float(Engine.physics_ticks_per_second)
		if elapsed > NAVMESH_TIMEOUT_SECONDS:
			return "navmesh not ready after %.1f s" % NAVMESH_TIMEOUT_SECONDS
	# is_navmesh_ready() waits for the map's first sync, but with async map
	# iterations the region's polygons can land a sync later; wait until the
	# map really answers near the spawn.
	var map := _level.get_world_3d().navigation_map
	while GroundMath.ground_distance(NavigationServer3D.map_get_closest_point(map, _spawn), _spawn) > 2.0:
		await get_tree().physics_frame
		elapsed += 1.0 / float(Engine.physics_ticks_per_second)
		if elapsed > NAVMESH_TIMEOUT_SECONDS:
			return "the navigation map never answered near the spawn"
	# Nothing may start a fight while the steps move actors by hand.
	_main.set_process(false)
	await _physics_frames(2)
	if GroundMath.ground_distance(_player.global_position, _spawn) > 0.5:
		return "player at %s, not at the spawn %s" % [_player.global_position, _spawn]
	return ""


func _step_camps() -> String:
	var centers: Dictionary = {}
	var positions: Dictionary = {}
	for camp: StringName in EXPECTED_ENEMIES:
		var container := _level.get_node_or_null("Enemies_%s" % String(camp).capitalize()) as Node3D
		if container == null:
			return "no container for camp %s" % camp
		var enemies: Array[Node3D] = []
		for child in container.get_children():
			if child.is_in_group(&"enemies"):
				enemies.append(child as Node3D)
		var expected: int = EXPECTED_ENEMIES[camp]
		if enemies.size() != expected:
			return "camp %s has %d enemies, expected %d" % [camp, enemies.size(), expected]
		var points: Array[Vector3] = []
		for enemy in enemies:
			points.append(enemy.global_position)
		for a in points:
			for b in points:
				if not LONE_CAMPS.has(camp) and GroundMath.ground_distance(a, b) > PACK_SPREAD_MAX_M:
					return "camp %s pack spread: %.1f m" % [camp, GroundMath.ground_distance(a, b)]
		positions[camp] = points
		centers[camp] = container.get_meta(&"camp_center", Vector3.ZERO)
		var kinds: Array[String] = []
		for enemy in enemies:
			kinds.append("%s(%s)" % [enemy.get_meta(&"enemy_kind", &"?"), enemy.scene_file_path.get_file()])
		print("[wilds]   %s: %s" % [camp, ", ".join(kinds)])
	var camps: Array = positions.keys()
	for i in range(camps.size()):
		for j in range(i + 1, camps.size()):
			for a: Vector3 in positions[camps[i]]:
				for b: Vector3 in positions[camps[j]]:
					var d := GroundMath.ground_distance(a, b)
					if d <= CAMP_SEPARATION_M:
						return "camps %s and %s only %.1f m apart" % [camps[i], camps[j], d]
	return ""


func _step_paths() -> String:
	var map := _level.get_world_3d().navigation_map
	var region := _level.get_node("NavigationRegion3D") as NavigationRegion3D
	var mesh := region.navigation_mesh
	for vertex in mesh.get_vertices():
		if vertex.y > NAVMESH_FLOOR_MAX_Y:
			return "navmesh vertex at %s is above the floor (a wall top)" % vertex
	var start := NavigationServer3D.map_get_closest_point(map, _spawn)
	for target_id in PATH_TARGETS:
		var center := WildsLayout.clearing_center(target_id)
		var goal := NavigationServer3D.map_get_closest_point(map, center)
		if GroundMath.ground_distance(goal, center) > 2.0:
			return "no navmesh near the %s centre (closest %s)" % [target_id, goal]
		var path := NavigationServer3D.map_get_path(map, start, goal, true)
		if path.size() < 2 and GroundMath.ground_distance(start, goal) > 1.0:
			return "no path to %s" % target_id
		var end := path[path.size() - 1]
		if GroundMath.ground_distance(end, goal) > PATH_END_TOLERANCE_M:
			return "path to %s ends at %s, %.2f m short of %s" % [target_id, end,
				GroundMath.ground_distance(end, goal), goal]
		var points: Array[Vector3] = []
		points.assign(path)
		print("[wilds]   path to %s: %.1f m" % [target_id, GroundMath.path_length(points)])
	return ""


func _step_trap_enemy() -> String:
	var wolf_scene := load(WOLF_SCENE_PATH) as PackedScene
	var base := _spawn + Vector3(3.0, 0.0, 0.0)

	# In turn mode: damaged and rooted.
	var trap := _new_trap(base + Vector3(0.0, 0.0, -1.5), true)
	var wolf := _new_actor(wolf_scene, base + Vector3(1.5, 0.0, -1.5))
	await _physics_frames(3)
	wolf.call("set_turn_based_combat", true)
	var before := int(wolf.get("health"))
	wolf.call("snap_to", trap.global_position)
	await _physics_frames(4)
	if not bool(trap.call("is_spent")):
		return "the trap did not fire on a turn-mode enemy"
	var after := int(wolf.get("health"))
	var damage := int(trap.get("damage"))
	if before - after != damage:
		return "turn-mode enemy lost %d health, expected %d" % [before - after, damage]
	var rooted := false
	if wolf.has_method("has_status"):
		rooted = bool(wolf.call("has_status", &"root"))
	elif wolf.has_method("is_rooted"):
		rooted = bool(wolf.call("is_rooted"))
	if not rooted:
		return "turn-mode enemy is not rooted"

	# In exploration: ignored.
	var trap_b := _new_trap(base + Vector3(0.0, 0.0, 1.5), true)
	var wolf_b := _new_actor(wolf_scene, base + Vector3(1.5, 0.0, 1.5))
	await _physics_frames(3)
	var before_b := int(wolf_b.get("health"))
	wolf_b.call("snap_to", trap_b.global_position)
	await _physics_frames(4)
	if bool(trap_b.call("is_spent")) or int(wolf_b.get("health")) != before_b:
		return "an exploration enemy set off a level trap"

	# A player-set trap catches it anyway.
	wolf_b.call("snap_to", base + Vector3(1.5, 0.0, 3.0))
	await _physics_frames(2)
	var placed: Node3D = Trap3D.place_player_trap(_level, base + Vector3(0.0, 0.0, 3.0))
	_spawned.append(placed)
	if not bool(placed.get("placed_by_player")) or not bool(placed.call("is_revealed")):
		return "place_player_trap did not make a visible player trap"
	await _physics_frames(2)
	wolf_b.call("snap_to", placed.global_position)
	await _physics_frames(4)
	if not bool(placed.call("is_spent")):
		return "a player-set trap ignored an exploration enemy"
	if int(wolf_b.get("health")) != before_b - int(placed.get("damage")):
		return "player-set trap dealt %d, expected %d" % [before_b - int(wolf_b.get("health")),
			int(placed.get("damage"))]
	_cleanup()
	await _physics_frames(2)
	return ""


func _step_trap_player() -> String:
	_restore_player()
	await _physics_frames(2)
	# Unrevealed: the default notice time means a snap straight onto it springs it.
	var hidden_trap := _new_trap(_spawn + Vector3(0.0, 0.0, 3.0), false)
	await _physics_frames(2)
	if bool(hidden_trap.call("is_revealed")):
		return "a hidden trap 3 m away was revealed before the notice time"
	var before := int(_player.get("health"))
	_player.call("snap_to", hidden_trap.global_position)
	await _physics_frames(4)
	if not bool(hidden_trap.call("is_spent")):
		return "an unrevealed trap did not fire on the player"
	if int(_player.get("health")) >= before:
		return "an unrevealed trap did not hurt the player (%d -> %d)" % [before, int(_player.get("health"))]

	# Revealed: harmless.
	_player.call("snap_to", _spawn)
	await _physics_frames(2)
	var shown_trap := _new_trap(_spawn + Vector3(-3.0, 0.0, 0.0), false)
	shown_trap.call("reveal")
	await _physics_frames(2)
	var before_shown := int(_player.get("health"))
	_player.call("snap_to", shown_trap.global_position)
	await _physics_frames(4)
	if bool(shown_trap.call("is_spent")) or int(_player.get("health")) != before_shown:
		return "a revealed trap hurt the player"

	# Noticing: standing within the reveal radius for the notice time reveals it.
	_player.call("snap_to", _spawn)
	var noticed := _new_trap(_spawn + Vector3(0.0, 0.0, -2.5), false)
	await _seconds(float(noticed.get("notice_seconds")) + 0.3)
	if not bool(noticed.call("is_revealed")):
		return "a trap 2.5 m from the player was not noticed"
	_cleanup()
	_restore_player()
	await _physics_frames(2)
	return ""


func _step_barrel() -> String:
	var wolf_scene := load(WOLF_SCENE_PATH) as PackedScene
	var base := _spawn + Vector3(0.0, 0.0, -4.0)
	_player.call("snap_to", _spawn + Vector3(0.0, 0.0, 3.5))
	var barrel_a := _new_barrel(base)
	var barrel_b := _new_barrel(base + Vector3(2.2, 0.0, 0.0))
	var near_wolf := _new_actor(wolf_scene, base + Vector3(-2.0, 0.0, 0.0))
	var far_wolf := _new_actor(wolf_scene, base + Vector3(-5.5, 0.0, 0.0))
	await _physics_frames(3)
	var near_before := int(near_wolf.get("health"))
	var far_before := int(far_wolf.get("health"))
	var player_before := int(_player.get("health"))
	barrel_a.call("receive_damage", 100)
	if bool(barrel_a.call("is_alive")):
		return "the barrel survived 100 damage"
	var near_after := int(near_wolf.get("health"))
	var blast := int(barrel_a.get("blast_damage"))
	if near_before - near_after != blast and bool(near_wolf.call("is_alive")):
		return "enemy 2 m away lost %d health, expected %d" % [near_before - near_after, blast]
	if int(far_wolf.get("health")) != far_before:
		return "enemy 5.5 m away was hurt"
	if int(_player.get("health")) != player_before:
		return "the player 7.5 m away was hurt"
	# The neighbour 2.2 m away goes off 0.15 s later.
	if not bool(barrel_b.call("is_alive")):
		return "the neighbour barrel went off at once, not after the chain delay"
	await _seconds(0.4)
	if is_instance_valid(barrel_b) and bool(barrel_b.call("is_alive")):
		return "the neighbour barrel did not chain"
	await _seconds(0.5)
	if is_instance_valid(barrel_a):
		return "the exploded barrel was not freed"
	_cleanup()
	_restore_player()
	await _physics_frames(2)
	return ""


func _step_cover() -> String:
	if not _player.has_method("set_in_cover"):
		print("[wilds]   note: the player has no set_in_cover yet (lead); only the zone's own detection is checked")
	var zone: Node3D = HideZone3D.new()
	zone.set("size", Vector3(3.0, 1.4, 3.0))
	_level.add_child(zone)
	_spawned.append(zone)
	zone.global_position = _spawn + Vector3(0.0, 0.0, -5.0)
	await _physics_frames(2)
	_player.call("snap_to", zone.global_position)
	await _physics_frames(4)
	if _player.has_method("is_in_cover") and not bool(_player.call("is_in_cover")):
		return "the player is not in cover inside the zone"
	if not bool(zone.call("has_player_inside")):
		return "the zone did not see the player"
	_player.call("snap_to", _spawn)
	await _physics_frames(4)
	if bool(zone.call("has_player_inside")):
		return "the zone still sees the player after it left"
	if _player.has_method("is_in_cover") and bool(_player.call("is_in_cover")):
		return "the player stayed in cover after leaving the zone"
	_cleanup()
	await _physics_frames(2)
	return ""


func _step_waystone() -> String:
	var start := _level.get_node_or_null("NavigationRegion3D/Waystones/WaystoneStart") as Waystone3D
	var camp := _level.get_node_or_null("NavigationRegion3D/Waystones/WaystoneCamp") as Waystone3D
	if start == null or camp == null:
		return "the start and camp waystones are missing"
	if not _player.has_method("teleport_to"):
		print("[wilds]   note: the player has no teleport_to yet (lead); testing the snap fallback")
	if start.get_destination() != camp:
		return "the start stone does not lead to the camp stone"
	if camp.attuned:
		return "the camp stone starts attuned"
	var from := _player.global_position
	start.interact(_player)
	await _physics_frames(2)
	if GroundMath.ground_distance(_player.global_position, from) > 0.2:
		return "the stone sent the player to an unattuned destination"
	camp.attune()
	start.interact(_player)
	await _physics_frames(3)
	var arrival := camp.get_arrival_point()
	var landed := GroundMath.ground_distance(_player.global_position, arrival)
	if landed > 1.0:
		return "the player landed %.2f m from the camp arrival point %s (at %s)" % [landed, arrival,
			_player.global_position]
	if GroundMath.ground_distance(_player.global_position, camp.global_position) > float(camp.get_interact_range()) + 0.6:
		return "the arrival point is out of the camp stone's reach"
	if not start.get_interact_label().contains("Bandit Camp"):
		return "unexpected label '%s'" % start.get_interact_label()
	# Refused in a fight. Without the coordinator's is_in_combat the player's
	# turn mode stands in.
	var gate := camp.get_destination()
	if gate == null:
		return "the camp stone has no destination"
	gate.attune()
	var coordinator := get_tree().get_first_node_in_group(&"level_coordinator")
	if coordinator == null or not coordinator.has_method("is_in_combat"):
		_player.call("set_turn_based_combat", true)
		var before := _player.global_position
		camp.interact(_player)
		await _physics_frames(2)
		_player.call("set_turn_based_combat", false)
		if GroundMath.ground_distance(_player.global_position, before) > 0.2:
			return "the stone worked during a fight"
	else:
		print("[wilds]   note: coordinator has is_in_combat; fight refusal not forced here")
	_player.call("snap_to", _spawn)
	await _physics_frames(2)
	return ""


func _step_chest() -> String:
	var chest := _level.get_node_or_null("NavigationRegion3D/Chests/ChestStart") as LootChest3D
	if chest == null:
		return "no start chest"
	var parent := chest.get_parent()
	var before := _count_pickups(parent)
	chest.interact(_player)
	await _physics_frames(3)
	var dropped := _count_pickups(parent) - before
	if dropped < int(chest.get("item_count")):
		return "the chest dropped %d items, expected %d" % [dropped, int(chest.get("item_count"))]
	if not chest.is_opened() or chest.can_interact():
		return "the chest is not marked open"
	chest.interact(_player)
	await _physics_frames(3)
	if _count_pickups(parent) - before != dropped:
		return "the chest dropped loot twice"
	return ""


# --- Helpers ---------------------------------------------------------------------------

func _new_trap(at: Vector3, revealed: bool) -> Node3D:
	var trap := Trap3D.new()
	trap.start_revealed = revealed
	_level.add_child(trap)
	trap.global_position = GroundMath.flatten(at)
	_spawned.append(trap)
	return trap


func _new_barrel(at: Vector3) -> Node3D:
	var barrel := ExplosiveBarrel3D.new()
	_level.add_child(barrel)
	barrel.global_position = GroundMath.flatten(at)
	_spawned.append(barrel)
	return barrel


func _new_actor(scene: PackedScene, at: Vector3) -> Node3D:
	var actor := scene.instantiate() as Node3D
	_level.add_child(actor)
	actor.call("snap_to", at)
	_spawned.append(actor)
	return actor


func _cleanup() -> void:
	for node in _spawned:
		if is_instance_valid(node):
			node.queue_free()
	_spawned.clear()


func _restore_player() -> void:
	_player.set("health", int(_player.get("max_health")))
	_player.call("snap_to", _spawn)


func _count_pickups(parent: Node) -> int:
	var count := 0
	for child in parent.get_children():
		if child is ItemPickup3D:
			count += 1
	return count


func _physics_frames(count: int) -> void:
	for _i in range(count):
		await get_tree().physics_frame


func _seconds(duration: float) -> void:
	await get_tree().create_timer(duration).timeout
