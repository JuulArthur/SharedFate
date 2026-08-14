@tool
extends StaticBody2D

# Drop instances of this scene into a forest level. Each tree is a static
# collider so the player can't walk through it, and is included in the
# `navmesh_source` group via its parent container so the level's
# NavigationRegion2D bakes it as an obstacle.

@onready var sprite: Sprite2D = $Sprite2D


func _ready() -> void:
	if sprite != null:
		sprite.texture = ForestArt.tree_texture()
	if not Engine.is_editor_hint():
		add_to_group("forest_tree")
