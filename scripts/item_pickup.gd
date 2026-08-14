extends Area2D

# A small world pickup that represents an Item dropped by a destroyed crate
# (or other source). When the player walks onto it, the item is added to
# the player's inventory and the pickup is freed.
#
# Use `setup(item)` after instancing to assign the item to display. The
# pickup auto-tweens a gentle bobbing motion so it reads as collectible.

@export var item: Item:
	set(value):
		item = value
		_refresh_icon()

@export var bob_amount: float = 2.0
@export var bob_speed: float = 2.2

@onready var sprite: Sprite2D = $Sprite2D

var _time := 0.0
var _base_position := Vector2.ZERO
var _claimed := false


func _ready() -> void:
	collision_layer = 0
	collision_mask = 2
	monitoring = true
	_base_position = position
	body_entered.connect(_on_body_entered)
	_refresh_icon()


func setup(new_item: Item) -> void:
	item = new_item


func _process(delta: float) -> void:
	_time += delta
	if sprite == null:
		return
	sprite.position.y = sin(_time * bob_speed) * bob_amount - 8.0


func _refresh_icon() -> void:
	if sprite == null:
		return
	if item != null and item.icon != null:
		sprite.texture = item.icon
	else:
		sprite.texture = null


func _on_body_entered(body: Node) -> void:
	if _claimed:
		return
	if not body.is_in_group("player"):
		return
	if item == null:
		_claimed = true
		queue_free()
		return

	var inventory := body.get("inventory") as Inventory
	if inventory == null:
		inventory = body.get_node_or_null("Inventory") as Inventory
	if inventory == null:
		return

	_claimed = true
	inventory.add_item(item)
	queue_free()
