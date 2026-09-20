extends Node3D

## Headless verification for WP6 (world items). Drops three items from the
## stub player via LootDropper's 3D branch, opens LootMenu on the resulting
## pile, takes one item, then checks that an out-of-range pickup only starts
## an approach instead of opening. See docs/3d-port-contracts.md, section 8.
##
## Run with:
##   godot --headless --path . res://scenes/3d/tests/pickup_test.tscn --quit-after 150

const DROP_SPREAD_M := 0.6
const DISTANCE_TOLERANCE_M := 0.05
const MOVE_AWAY_OFFSET := Vector3(4.0, 0.0, 0.0)
const COLLECT_WAIT_FRAMES := 30
const TIMEOUT_FRAMES := 120

@onready var player: Node3D = $Player
@onready var inventory: Inventory = $Player/Inventory

var _frame_count := 0
var _finished := false


func _ready() -> void:
	call_deferred("_run_test")


func _process(_delta: float) -> void:
	_frame_count += 1
	if not _finished and _frame_count >= TIMEOUT_FRAMES:
		_fail("timed out after %d frames" % TIMEOUT_FRAMES)


func _run_test() -> void:
	var items: Array[Item] = [
		ItemFactory.create_sword(),
		ItemFactory.create_health_potion(),
		ItemFactory.create_dagger(),
	]

	LootDropper.drop_items(player, items, DROP_SPREAD_M)
	await get_tree().process_frame
	await get_tree().process_frame

	var pickups := _find_pickups()
	if pickups.size() != 3:
		_fail("expected 3 ItemPickup3D nodes, found %d" % pickups.size())
		return

	for pickup in pickups:
		var dist := GroundMath.ground_distance(pickup.global_position, player.global_position)
		if absf(dist - DROP_SPREAD_M) > DISTANCE_TOLERANCE_M:
			_fail("pickup %s at %.3f m from the player, expected about %.3f m" % [pickup.name, dist, DROP_SPREAD_M])
			return

	LootMenu.request_loot(pickups[0], player)
	if not LootMenu.is_open():
		_fail("LootMenu did not open for a pile within LOOT_RANGE_M")
		return

	var taken_pickup: ItemPickup3D = pickups[0]
	var taken_item: Item = taken_pickup.get_item()
	if not taken_pickup.take(inventory):
		_fail("pickup.take(inventory) returned false")
		return
	if not inventory.items.has(taken_item):
		_fail("inventory does not contain the taken item")
		return

	var wait_frames := 0
	while is_instance_valid(taken_pickup) and wait_frames < COLLECT_WAIT_FRAMES:
		await get_tree().process_frame
		wait_frames += 1
	if is_instance_valid(taken_pickup):
		_fail("taken pickup did not free itself after the collect animation")
		return

	LootMenu.close()
	player.snap_to(player.global_position + MOVE_AWAY_OFFSET)
	await get_tree().process_frame

	var remaining: Array[ItemPickup3D] = []
	for p in _find_pickups():
		if p.is_available():
			remaining.append(p)
	if remaining.is_empty():
		_fail("expected at least one remaining pickup to test the approach path")
		return

	LootMenu.request_loot(remaining[0], player)
	if LootMenu.is_open():
		_fail("LootMenu opened even though the player is far from the pile")
		return
	if not LootMenu.is_approaching():
		_fail("LootMenu.is_approaching() is false after an out-of-range request_loot")
		return

	print("PICKUP OK")
	_finished = true
	get_tree().quit()


func _find_pickups() -> Array[ItemPickup3D]:
	var result: Array[ItemPickup3D] = []
	for child in get_children():
		if child is ItemPickup3D:
			result.append(child)
	return result


func _fail(message: String) -> void:
	print("PICKUP FAIL: %s" % message)
	_finished = true
	get_tree().quit()
