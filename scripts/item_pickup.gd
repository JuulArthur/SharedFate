extends Node2D

# A single item lying in the world, dropped by a crate, a chest or a dead
# enemy. Click it to loot it: standing close enough opens the loot menu
# (`scripts/inventory/loot_menu.gd`) right away, and from further off the
# player walks over first and the menu opens on arrival. Walking over an item
# without clicking does nothing — picking things up is always deliberate.
#
# Use `setup(item)` after instancing to assign the item to display. The
# pickup auto-tweens a gentle bobbing motion so it reads as collectible.

const PICKUP_GROUP: StringName = &"item_pickup"
# Pickups this close to the clicked one are shown as one pile. `LootDropper`
# spreads a drop in a ring of radius ~18-22, so this comfortably covers a whole
# drop plus anything dropped on top of it.
const PILE_RADIUS := 52.0
# Where the icon rests before bobbing, and how far outside it a click counts.
const SPRITE_REST_Y := -8.0
const CLICK_PADDING := 4.0
const FALLBACK_CLICK_RADIUS := 12.0
const COLLECT_ANIM_SECONDS := 0.18
const HOVER_TINT := Color(1.35, 1.30, 1.05, 1.0)

@export var item: Item:
	set(value):
		item = value
		_refresh_icon()

@export var bob_amount: float = 2.0
@export var bob_speed: float = 2.2

@onready var sprite: Sprite2D = $Sprite2D

var _time := 0.0
var _claimed := false
var _hovered := false


func _ready() -> void:
	add_to_group(PICKUP_GROUP)
	_refresh_icon()


func setup(new_item: Item) -> void:
	item = new_item


# True while this pickup still holds an item nobody has taken.
func is_available() -> bool:
	return not _claimed and item != null


# Move this pickup's item into `inventory`. Returns false if it was already
# taken. Called by the loot menu, never directly by the player.
func take(inventory: Inventory) -> bool:
	if not is_available() or inventory == null:
		return false

	_claimed = true
	inventory.add_item(item)
	_play_collect_animation()
	return true


func _process(delta: float) -> void:
	_time += delta
	if sprite == null:
		return
	sprite.position.y = sin(_time * bob_speed) * bob_amount + SPRITE_REST_Y
	_update_hover()


func _unhandled_input(event: InputEvent) -> void:
	if not is_available():
		return
	if not (event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed):
		return

	# Read the click from the event itself rather than the cached mouse
	# position, so the hit test matches the exact event being handled.
	var local_event := make_input_local(event) as InputEventMouseButton
	if local_event == null or not _contains_local_point(local_event.position):
		return

	var looter := _find_player()
	if looter == null:
		return

	# In reach: loot now and swallow the click, so looting never doubles as a
	# move order. Out of reach: leave the click alone so the level's own
	# click-to-move walks the player here (respecting the turn movement budget
	# in combat), and LootMenu opens the pile once they arrive.
	#
	# Pickups sit below the level root and unhandled input travels upwards, so
	# we always get first refusal on the click before the level script.
	if LootMenu.request_loot(self, looter):
		get_viewport().set_input_as_handled()


func _refresh_icon() -> void:
	if sprite == null:
		return
	if item != null and item.icon != null:
		sprite.texture = item.icon
	else:
		sprite.texture = null


# Clickable area: the icon's own footprint at rest (so the bob doesn't make it
# a moving target), padded a little to stay comfortable at small icon sizes.
func _contains_local_point(local_point: Vector2) -> bool:
	if sprite == null or sprite.texture == null:
		return local_point.distance_to(Vector2(0, SPRITE_REST_Y)) <= FALLBACK_CLICK_RADIUS

	var half_size := sprite.texture.get_size() * sprite.scale.abs() * 0.5
	var rect := Rect2(Vector2(0, SPRITE_REST_Y) - half_size, half_size * 2.0)
	return rect.grow(CLICK_PADDING).has_point(local_point)


func _update_hover() -> void:
	var hovered := _contains_local_point(get_local_mouse_position())
	if hovered == _hovered:
		return
	_hovered = hovered
	modulate = HOVER_TINT if _hovered else Color(1, 1, 1, 1)


func _find_player() -> Node:
	var players := get_tree().get_nodes_in_group("player")
	if players.is_empty():
		return null
	return players[0]


# Every un-taken pickup lying within PILE_RADIUS of this one, this one first.
func gather_pile() -> Array[Node2D]:
	var pile: Array[Node2D] = [self]
	for node in get_tree().get_nodes_in_group(PICKUP_GROUP):
		var other := node as Node2D
		if other == null or other == self:
			continue
		if not other.has_method("is_available") or not other.call("is_available"):
			continue
		if other.global_position.distance_to(global_position) <= PILE_RADIUS:
			pile.append(other)
	return pile


func _play_collect_animation() -> void:
	set_process(false)
	set_process_unhandled_input(false)

	var tween := create_tween()
	tween.tween_property(self, "scale", scale * 1.3, COLLECT_ANIM_SECONDS)
	tween.parallel().tween_property(self, "modulate:a", 0.0, COLLECT_ANIM_SECONDS)
	tween.tween_callback(queue_free)
