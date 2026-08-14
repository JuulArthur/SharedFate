@tool
extends Node2D

# Drop instances of this scene to mark a goblin camp. Each tent contains a
# Marker2D named "GoblinSpawn" which you can later read to spawn enemies.
# Tents do not block movement on purpose, so the player can approach them.

@onready var sprite: Sprite2D = $Sprite2D


func _ready() -> void:
	if sprite != null:
		sprite.texture = ForestArt.tent_texture()
	if not Engine.is_editor_hint():
		add_to_group("goblin_tent")


func get_goblin_spawn_position() -> Vector2:
	var marker := get_node_or_null("GoblinSpawn") as Marker2D
	if marker == null:
		return global_position
	return marker.global_position
