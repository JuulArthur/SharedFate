class_name LootChest3D
extends StaticBody3D

## Track A: a treasure chest (docs/gameplay-expansion.md section 3,
## "Interactables").
##
## The WP1 chest model (`chest.glb`) on a StaticBody3D on the prop layer (8),
## in group `interactable`. `interact(player)` opens it once: a gold flash and
## a hop, the lid tints to a spent grey, and `item_count` items spill out
## through `LootDropper.drop_items(self, items, loot_spread)` (the 3D branch
## rings `ItemPickup3D`s on the ground around the chest, on the chest's
## parent). `guaranteed_gear` makes the first item a random piece of gear; a
## `include_potion` chest adds a health potion; the rest come from the shared
## random table (`ItemFactory.create_random_loot`).

const INTERACTABLE_GROUP := &"interactable"
const PROP_LAYER := 8
const MODEL_SCENE_PATH := "res://assets/3d/models/chest.glb"
## chest.glb is 0.94 x 0.62 x 0.75 m (contracts section 10).
const COLLIDER_SIZE := Vector3(0.94, 0.75, 0.62)
const COLOR_OPEN_FLASH := Color(2.4, 1.9, 0.8, 1.0)
const COLOR_SPENT_TINT := Color(0.22, 0.22, 0.22, 0.4)
const COLOR_LOOT := Color(1.0, 0.84, 0.35, 1.0)
const POPUP_OFFSET := Vector3(0.0, 1.3, 0.0)

## Emitted once, after the loot has been dropped.
signal opened(items: Array[Item])

@export var item_count := 2
@export var guaranteed_gear := false
@export var include_potion := false
## Metres from the chest's origin to the ring of dropped items.
@export var loot_spread := 0.8
@export var interact_range := 1.8

var _opened := false
var _hover_highlighted := false
var _model: Node3D = null


func _ready() -> void:
	collision_layer = PROP_LAYER
	collision_mask = 0
	add_to_group(INTERACTABLE_GROUP)
	var shape := BoxShape3D.new()
	shape.size = COLLIDER_SIZE
	WorldFx3D.add_shape(self, shape, Vector3(0.0, COLLIDER_SIZE.y * 0.5, 0.0))
	_build_model()


# --- Interactable contract (gameplay expansion section 3) ---------------------

func interact(_player: Node3D) -> void:
	if _opened:
		return
	_opened = true
	var items := _roll_items()
	_play_open_fx()
	LootDropper.drop_items(self, items, loot_spread)
	opened.emit(items)


func get_interact_range() -> float:
	return interact_range


func get_interact_label() -> String:
	return "Chest (empty)" if _opened else "Open chest"


func can_interact() -> bool:
	return not _opened


func set_hover_highlighted(enabled: bool) -> void:
	if _hover_highlighted == enabled:
		return
	_hover_highlighted = enabled
	if _opened:
		WorldFx3D.set_highlight(_model, true, COLOR_SPENT_TINT)
		return
	WorldFx3D.set_highlight(_model, enabled)


func is_opened() -> bool:
	return _opened


func _roll_items() -> Array[Item]:
	var items: Array[Item] = []
	if guaranteed_gear:
		items.append(ItemFactory.create_random_gear())
	if include_potion:
		items.append(ItemFactory.create_health_potion())
	while items.size() < item_count:
		items.append(ItemFactory.create_random_loot())
	return items


func _play_open_fx() -> void:
	CombatFx.popup_text(global_position + POPUP_OFFSET, "Opened", COLOR_LOOT, 18)
	CombatFx.ring_burst(self, global_position + Vector3(0.0, 0.4, 0.0), COLOR_LOOT,
		6.0 * WorldFx3D.FX_SCREEN_SCALE, 22.0 * WorldFx3D.FX_SCREEN_SCALE, 0.35, 1.0)
	if _model == null:
		return
	HitFlash3D.flash_node(_model, COLOR_OPEN_FLASH, 0.3)
	var rest_scale := _model.scale
	var tween := create_tween()
	tween.tween_property(_model, "scale", rest_scale * Vector3(1.08, 0.86, 1.08), 0.07)
	tween.tween_property(_model, "scale", rest_scale * Vector3(0.95, 1.12, 0.95), 0.09)
	tween.tween_property(_model, "scale", rest_scale, 0.12)
	tween.tween_interval(0.25)
	# A washed-out tint marks the chest as spent (an overlay can only add light).
	tween.tween_callback(func() -> void: WorldFx3D.set_highlight(_model, true, COLOR_SPENT_TINT))


func _build_model() -> void:
	var scene := load(MODEL_SCENE_PATH) as PackedScene
	if scene == null:
		push_warning("LootChest3D: missing %s; the chest is a plain box" % MODEL_SCENE_PATH)
		var box := BoxMesh.new()
		box.size = COLLIDER_SIZE
		_model = Node3D.new()
		_model.name = "Model"
		add_child(_model)
		WorldFx3D.add_mesh(_model, "Box", box, WorldFx3D.flat_material(Color(0.48, 0.32, 0.19)),
			Vector3(0.0, COLLIDER_SIZE.y * 0.5, 0.0))
		return
	_model = scene.instantiate() as Node3D
	_model.name = "Model"
	add_child(_model)
	# The glb brings its own collider on layer 1; this body owns the collision.
	_strip_colliders(_model)


func _strip_colliders(node: Node) -> void:
	for child in node.get_children():
		if child is CollisionObject3D:
			node.remove_child(child)
			child.queue_free()
		else:
			_strip_colliders(child)
