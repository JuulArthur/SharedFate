@tool
extends StaticBody2D

# Dense cluster of trees that blocks movement and navigation. Drop instances
# into the forest level (under Trees or ForestWalls) to carve corridors and
# choke points. Rotate the instance in the editor for vertical barriers.

@export_enum("Block:0", "Row:1", "Column:2") var layout: int = 0:
	set(value):
		layout = value
		if is_inside_tree():
			_apply_layout()


const LAYOUT_BLOCK := 0
const LAYOUT_ROW := 1
const LAYOUT_COLUMN := 2

const TREE_OFFSET_Y := -26.0
const COLLISION_RADIUS := 12.0

var _sprites: Array[Sprite2D] = []
var _collisions: Array[CollisionShape2D] = []


func _enter_tree() -> void:
	if Engine.is_editor_hint():
		_cache_nodes()
		_apply_layout()


func _ready() -> void:
	_cache_nodes()
	_apply_layout()
	if not Engine.is_editor_hint():
		add_to_group("forest_tree_wall")


func _cache_nodes() -> void:
	_sprites.clear()
	_collisions.clear()
	for child in get_children():
		if child is Sprite2D:
			_sprites.append(child)
		elif child is CollisionShape2D:
			_collisions.append(child)


func _apply_layout() -> void:
	if _sprites.is_empty():
		_cache_nodes()

	var footprint := _layout_footprint()
	var texture := ForestArt.tree_texture()

	for i in _sprites.size():
		var sprite := _sprites[i]
		if i < footprint.size():
			sprite.visible = true
			sprite.texture = texture
			sprite.position = footprint[i] + Vector2(0, TREE_OFFSET_Y)
		else:
			sprite.visible = false

	for i in _collisions.size():
		var collision := _collisions[i]
		if i < footprint.size():
			collision.disabled = false
			collision.position = footprint[i]
			var shape := collision.shape as CircleShape2D
			if shape == null:
				shape = CircleShape2D.new()
				collision.shape = shape
			shape.radius = COLLISION_RADIUS
		else:
			collision.disabled = true


func _layout_footprint() -> Array[Vector2]:
	match layout:
		LAYOUT_ROW:
			return [
				Vector2(-104, 0),
				Vector2(-52, 0),
				Vector2(0, 0),
				Vector2(52, 0),
				Vector2(104, 0),
			]
		LAYOUT_COLUMN:
			return [
				Vector2(0, -104),
				Vector2(0, -52),
				Vector2(0, 0),
				Vector2(0, 52),
				Vector2(0, 104),
			]
		_:
			return [
				Vector2(-56, -12),
				Vector2(0, -12),
				Vector2(56, -12),
				Vector2(-28, 28),
				Vector2(28, 28),
				Vector2(0, 48),
			]
