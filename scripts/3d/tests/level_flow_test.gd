extends Node

## Headless test of the level flow (docs/level-flow.md): start in the Hollow
## Road placeholder, change the body (level, attributes, a forged skill, spent
## mana, a wound, the rogue in control, worn gear), walk into the exit, arrive
## in the Wilds at `Entry_from_road` with all of it, walk back through the
## Wilds' exit to `Entry_from_wilds`, and check that no exit works in a fight.
##
##   godot --headless --path . res://scenes/3d/tests/level_flow_test.tscn --quit-after 3000
##
## Prints LEVEL FLOW OK or LEVEL FLOW FAIL: <step>: <reason>. The test node
## leaves the current scene at start, so it survives the scene changes it
## drives.

const HOLLOW_ROAD := "res://scenes/3d/levels/hollow_road.tscn"
const HEADLESS_FPS := 60
const LOAD_TIMEOUT_SECONDS := 20.0
const ARRIVAL_SLACK_M := 1.0

var _step := "boot"
var _done := false
var _expected := {}


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	Engine.max_fps = HEADLESS_FPS
	RunState3D.clear()
	call_deferred("_detach_and_run")


func _exit_tree() -> void:
	if not _done:
		print("LEVEL FLOW FAIL: quit during step '%s'" % _step)


func _detach_and_run() -> void:
	# Out of the current scene, so change_scene_to_file leaves this node alone.
	get_tree().current_scene = null
	_run()


func _run() -> void:
	var steps: Array = [
		["load_first_level", _step_load_first_level],
		["change_the_body", _step_change_the_body],
		["walk_out", _step_walk_out],
		["arrive_in_wilds", _step_arrive_in_wilds],
		["walk_back", _step_walk_back],
		["no_exit_in_a_fight", _step_no_exit_in_a_fight],
	]
	for entry in steps:
		_step = String(entry[0])
		var step: Callable = entry[1]
		var result: Variant = await step.call()
		var failure := str(result)
		if not failure.is_empty():
			_done = true
			print("LEVEL FLOW FAIL: %s: %s" % [_step, failure])
			get_tree().quit(1)
			return
		print("[level_flow] %s ok" % _step)
	_done = true
	print("LEVEL FLOW OK")
	get_tree().quit(0)


# --- Steps ---------------------------------------------------------------------------

func _step_load_first_level() -> String:
	get_tree().change_scene_to_file(HOLLOW_ROAD)
	var main := await _wait_for_level("HollowRoad")
	if main == null:
		return "the Hollow Road did not load"
	if main.call("get_arrival_entry") != &"":
		return "a fresh start has arrival entry '%s'" % main.call("get_arrival_entry")
	var exit_node := main.get_node_or_null("ExitToWilds")
	if exit_node == null:
		return "no ExitToWilds in the Hollow Road"
	return ""


func _step_change_the_body() -> String:
	var main := get_tree().current_scene
	var player: Node = main.get("player")
	var progression: Node = player.call("get_progression")
	player.call("add_experience", int(player.call("get_xp_required_for_next_level")))
	progression.call("raise_attribute", 2, &"power")
	var cards: Array[StringName] = [&"type_damage", &"element_fire", &"mod_ranged", &"mod_area"]
	if not bool(progression.call("forge_skill", 2, 0, cards)):
		return "forging a Fireball was refused"
	progression.call("spend_pool", 2, 11)
	player.call("take_damage", 9)
	main.call("_request_shift", 1)
	var gear: Resource = ItemFactory.gear_builders()[0].call()
	var inventory: Node = player.get("inventory")
	inventory.call("add_item", gear)
	inventory.call("equip", gear)
	_expected = {
		"level": int(player.call("get_player_level")),
		"health": int(player.get("health")),
		"power": int(progression.call("get_attribute", 2, &"power")),
		"points": int(progression.get("attribute_points")),
		"mana": int(progression.call("get_pool", 2)),
		"damage_cards": int(progression.call("card_count", &"type_damage")),
		"skill": (progression.call("skill_ability", 2, 0) as Object).get("display_name"),
		"soul": 1,
		"gear": gear,
		"items": int(inventory.call("size")),
	}
	print("[level_flow] body before leaving: %s" % str(_expected))
	return ""


func _step_walk_out() -> String:
	var main := get_tree().current_scene
	var exit_node: Node3D = main.get_node("ExitToWilds")
	# The exit ignores the player for a moment after the level starts.
	await get_tree().create_timer(1.2).timeout
	(main.get("player") as Node).call("snap_to", exit_node.global_position)
	if not await _wait_until(func() -> bool: return bool(main.call("is_traveling")), 3.0):
		return "walking into the exit did not start the travel"
	return ""


func _step_arrive_in_wilds() -> String:
	var main := await _wait_for_level("Wilds")
	if main == null:
		return "the Wilds did not load"
	if main.call("get_arrival_entry") != &"from_road":
		return "arrived at entry '%s'" % main.call("get_arrival_entry")
	var entry: Node3D = main.find_child("Entry_from_road", true, false)
	var player: Node3D = main.get("player")
	var gap := GroundMath.ground_distance(player.global_position, entry.global_position)
	if gap > ARRIVAL_SLACK_M:
		return "the body stands %.2f m from Entry_from_road" % gap
	return _check_body(main, "the Wilds")


func _step_walk_back() -> String:
	var main := get_tree().current_scene
	var exit_node: Node3D = main.find_child("ExitToHollowRoad", true, false)
	if exit_node == null:
		return "no ExitToHollowRoad in the Wilds"
	await get_tree().create_timer(1.2).timeout
	(main.get("player") as Node).call("snap_to", exit_node.global_position)
	if not await _wait_until(func() -> bool: return bool(main.call("is_traveling")), 3.0):
		return "walking into the Wilds exit did not start the travel"
	var back := await _wait_for_level("HollowRoad")
	if back == null:
		return "the Hollow Road did not load again"
	if back.call("get_arrival_entry") != &"from_wilds":
		return "arrived back at entry '%s'" % back.call("get_arrival_entry")
	var entry: Node3D = back.get_node("Entry_from_wilds")
	var player: Node3D = back.get("player")
	if GroundMath.ground_distance(player.global_position, entry.global_position) > ARRIVAL_SLACK_M:
		return "the body is not at Entry_from_wilds"
	return _check_body(back, "the Hollow Road, back")


func _step_no_exit_in_a_fight() -> String:
	var main := get_tree().current_scene
	main.call("_start_turn_based_combat")
	await get_tree().physics_frame
	var ok: bool = await main.call("travel_to", "res://scenes/3d/wilds.tscn", &"from_road")
	if ok or bool(main.call("is_traveling")):
		return "travel was allowed in a fight"
	await get_tree().create_timer(0.5).timeout
	if get_tree().current_scene != main:
		return "the scene changed during a fight"
	return ""


# --- Helpers ---------------------------------------------------------------------------

func _check_body(main: Node, where: String) -> String:
	var player: Node = main.get("player")
	var progression: Node = player.call("get_progression")
	var inventory: Node = player.get("inventory")
	var found := {
		"level": int(player.call("get_player_level")),
		"health": int(player.get("health")),
		"power": int(progression.call("get_attribute", 2, &"power")),
		"points": int(progression.get("attribute_points")),
		"mana": int(progression.call("get_pool", 2)),
		"damage_cards": int(progression.call("card_count", &"type_damage")),
		"soul": int((player.call("get_active_soul") as Object).get("kind")),
		"items": int(inventory.call("size")),
	}
	var skill: Object = progression.call("skill_ability", 2, 0)
	found["skill"] = skill.get("display_name") if skill != null else "none"
	for key in found:
		# Mana refills while exploring, so it may only have grown.
		if key == "mana":
			if int(found[key]) < int(_expected[key]):
				return "in %s mana is %d, less than the %d carried" % [where, found[key], _expected[key]]
			continue
		if found[key] != _expected[key]:
			return "in %s %s is %s, expected %s" % [where, key, str(found[key]), str(_expected[key])]
	if not bool(inventory.call("is_equipped", _expected["gear"])):
		return "in %s the carried gear is no longer worn" % where
	return ""


## The new current scene once it is the level named `level_name` and its
## navmesh is ready, or null after LOAD_TIMEOUT_SECONDS.
func _wait_for_level(level_name: String) -> Node:
	var ready := await _wait_until(func() -> bool:
		var scene := get_tree().current_scene
		return scene != null and String(scene.name) == level_name and scene.has_method("is_navmesh_ready") \
			and bool(scene.call("is_navmesh_ready")),
		LOAD_TIMEOUT_SECONDS)
	return get_tree().current_scene if ready else null


func _wait_until(condition: Callable, timeout_seconds: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if bool(condition.call()):
			return true
		await get_tree().process_frame
	return bool(condition.call())
