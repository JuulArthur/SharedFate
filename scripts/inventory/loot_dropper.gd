class_name LootDropper
extends RefCounted

# Shared helper for turning a list of Items into world pickups.
#
# Every loot source funnels through here — breakable crates, dead enemies and
# treasure chests — so drop behaviour (which scene, ring spread, deferred
# spawning) stays identical no matter what dropped the loot.
#
# Pickups are added to the *source's parent*, never to the source itself, so a
# node that frees itself on death (see `enemy.gd`) still leaves its loot behind.

const PICKUP_SCENE_PATH := "res://scenes/item_pickup.tscn"
const PICKUP_SCENE_3D := preload("res://scenes/3d/item_pickup_3d.tscn")
const DEFAULT_SPREAD := 18.0

static var _pickup_scene: PackedScene


static func drop_items(source: Node, items: Array[Item], spread: float = DEFAULT_SPREAD) -> void:
	if source == null or items.is_empty():
		return

	if source is Node3D:
		_drop_items_3d(source as Node3D, items, spread)
		return

	var parent := source.get_parent()
	if parent == null:
		return

	var scene := _get_pickup_scene()
	if scene == null:
		return

	# Read the origin now: `source` may queue_free() itself immediately after
	# calling us, and the deferred spawns below run after it is gone.
	var origin := (source as Node2D).global_position

	for i in items.size():
		var item := items[i]
		if item == null:
			continue

		var pickup := scene.instantiate()
		parent.call_deferred("add_child", pickup)

		var offset_angle := TAU * float(i) / float(items.size())
		var offset := Vector2.RIGHT.rotated(offset_angle) * spread
		pickup.set_deferred("global_position", origin + offset)
		pickup.call_deferred("setup", item)


# 3D twin of the block above: same ring-spread, deferred-spawn behaviour, but
# on the ground plane (XZ) and instancing `ItemPickup3D` instead. `spread` is
# interpreted in metres, matching every other 3D range in the port.
static func _drop_items_3d(source: Node3D, items: Array[Item], spread: float) -> void:
	var parent := source.get_parent()
	if parent == null:
		return

	# Read the origin now: `source` may queue_free() itself immediately after
	# calling us, and the deferred spawns below run after it is gone.
	var origin := source.global_position

	for i in items.size():
		var item := items[i]
		if item == null:
			continue

		var pickup := PICKUP_SCENE_3D.instantiate()
		parent.call_deferred("add_child", pickup)

		var offset_angle := TAU * float(i) / float(items.size())
		var ring_offset := GroundMath.from_ground(Vector2.RIGHT.rotated(offset_angle) * spread)
		pickup.set_deferred("global_position", origin + ring_offset)
		pickup.call_deferred("setup", item)


static func _get_pickup_scene() -> PackedScene:
	if _pickup_scene == null:
		_pickup_scene = load(PICKUP_SCENE_PATH) as PackedScene
		if _pickup_scene == null:
			push_warning("LootDropper: missing item pickup scene at %s" % PICKUP_SCENE_PATH)
	return _pickup_scene
