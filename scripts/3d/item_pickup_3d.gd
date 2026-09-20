class_name ItemPickup3D
extends Node3D

## A single item lying in the 3D world, dropped by a crate, a chest or a dead
## enemy. Mirrors `scripts/item_pickup.gd`'s API, but never handles clicks
## itself: the coordinator ray-picks pickups on collision layer 3
## (`WorldPicker.pick_pickup`) and calls `LootMenu.request_loot(pickup, player)`.
## See docs/3d-port-contracts.md, sections 6 and 8.
##
## Use `setup(item)` after instancing to assign the item to display. The icon
## auto-tweens a gentle bobbing motion so it reads as collectible; the click
## hit test lives on `ClickArea`, a fixed `Area3D` that never moves, so the
## bob can never shift the clickable footprint.

# Comfortably beyond melee reach, matching LootMenu's own metre-based twin so
# a coordinator can show a reach hint without reaching into LootMenu itself.
const LOOT_RANGE_M := 1.5
# Other available pickups within this ground distance of this one are treated
# as one pile by `gather_pile()`. `LootDropper` spreads a drop in a ring on
# the order of tens of centimetres, so this comfortably covers a whole drop.
const GATHER_RADIUS_M := 1.0
# Where the icon rests before bobbing.
const ICON_REST_HEIGHT_M := 0.3
const COLLECT_ANIM_SECONDS := 0.18
const HOVER_TINT := Color(1.35, 1.30, 1.05, 1.0)
const DEFAULT_TINT := Color(1.0, 1.0, 1.0, 1.0)

@export var item: Item:
	set(value):
		item = value
		_refresh_icon()

@export var bob_amount_m: float = 0.05
@export var bob_speed: float = 2.2

@onready var icon: Sprite3D = $Icon

var _time := 0.0
var _claimed := false
var _hovered := false


func _ready() -> void:
	_refresh_icon()


func setup(new_item: Item) -> void:
	item = new_item


## True while this pickup still holds an item nobody has taken.
func is_available() -> bool:
	return not _claimed and item != null


func get_item() -> Item:
	return item


## Move this pickup's item into `inventory`. Returns false if it was already
## taken. Called by the loot menu (or a coordinator standing in for it),
## never directly by whatever ray-picked this pickup.
func take(inventory: Inventory) -> bool:
	if not is_available() or inventory == null:
		return false

	_claimed = true
	inventory.add_item(item)
	_play_collect_animation()
	return true


## Hover tint for whoever is ray-picking pickups. The 2D pickup tints itself
## on mouse-over from inside `_process`; in 3D the coordinator owns hit
## testing (section 6), so it drives this instead.
func set_hover_highlighted(enabled: bool) -> void:
	if enabled == _hovered:
		return
	_hovered = enabled
	if icon != null:
		icon.modulate = HOVER_TINT if _hovered else DEFAULT_TINT


## This pickup plus every other available ItemPickup3D sharing its parent,
## within GATHER_RADIUS_M ground distance.
func gather_pile() -> Array:
	var pile: Array = [self]
	var parent := get_parent()
	if parent == null:
		return pile

	for child in parent.get_children():
		if child == self:
			continue
		var other := child as ItemPickup3D
		if other == null or not other.is_available():
			continue
		if GroundMath.ground_distance(global_position, other.global_position) <= GATHER_RADIUS_M:
			pile.append(other)
	return pile


func _process(delta: float) -> void:
	_time += delta
	if icon == null:
		return
	icon.position.y = ICON_REST_HEIGHT_M + sin(_time * bob_speed) * bob_amount_m


func _refresh_icon() -> void:
	if icon == null:
		return
	if item != null and item.icon != null:
		icon.texture = item.icon
	else:
		icon.texture = null


func _play_collect_animation() -> void:
	set_process(false)

	var tween := create_tween()
	tween.tween_property(self, "scale", scale * 1.3, COLLECT_ANIM_SECONDS)
	if icon != null:
		tween.parallel().tween_property(icon, "modulate:a", 0.0, COLLECT_ANIM_SECONDS)
	tween.tween_callback(queue_free)
