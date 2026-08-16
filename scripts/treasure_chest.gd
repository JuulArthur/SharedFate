@tool
extends StaticBody2D

# Treasure chest that blocks movement and spills its contents when the player
# walks up to it. Drop instances of `scenes/treasure_chest.tscn` into a level
# and fill `contained_items` in the inspector; leave that list empty and the
# chest rolls `random_loot_count` items off the shared loot table instead, so a
# chest is never boring by default.
#
# Loot goes out through `LootDropper` — the same path breakable crates and dead
# enemies use — so pickups behave identically wherever they came from.

signal opened(chest: Node2D)

@export var contained_items: Array[Item] = []
@export var random_loot_count: int = 2
@export var drop_spread: float = 22.0

@onready var sprite: Sprite2D = $Sprite2D
@onready var open_range: Area2D = $OpenRange

var _is_open := false
var _sprite_idle_position: Vector2 = Vector2.ZERO


func _ready() -> void:
	if Engine.is_editor_hint():
		sprite.texture = ChestArt.closed_texture()
		return

	add_to_group("navmesh_source")

	collision_layer = 1
	collision_mask = 0

	sprite.texture = ChestArt.closed_texture()
	_sprite_idle_position = sprite.position

	# The trigger ring is wider than the chest body so bumping into the chest
	# is enough to open it — the player can never actually stand on it.
	open_range.collision_layer = 0
	open_range.collision_mask = 2
	open_range.monitoring = true
	open_range.body_entered.connect(_on_body_entered)


func is_open() -> bool:
	return _is_open


func open() -> void:
	if _is_open:
		return
	_is_open = true

	sprite.texture = ChestArt.open_texture()
	_play_open_animation()
	_drop_contained_items()
	opened.emit(self)


func _on_body_entered(body: Node) -> void:
	if not body.is_in_group("player"):
		return
	open()


func _play_open_animation() -> void:
	if sprite == null:
		return

	var tween := create_tween()
	tween.tween_property(sprite, "position", _sprite_idle_position + Vector2(0, -3), 0.08)
	tween.parallel().tween_property(sprite, "modulate", Color(1.5, 1.35, 0.9, 1.0), 0.08)
	tween.tween_property(sprite, "position", _sprite_idle_position, 0.14)
	tween.parallel().tween_property(sprite, "modulate", Color(1, 1, 1, 1), 0.25)


func _drop_contained_items() -> void:
	var drops: Array[Item] = []
	for item in contained_items:
		if item != null:
			drops.append(item)

	if drops.is_empty():
		for i in maxi(random_loot_count, 0):
			drops.append(ItemFactory.create_random_loot())

	LootDropper.drop_items(self, drops, drop_spread)
