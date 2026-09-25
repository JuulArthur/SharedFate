extends Node3D

## WP7 arena floor: tiles the clearing with ground_tile.glb in a checkerboard.
##
## Not named in the WP7 file list; added because ground_tile.glb has no way to
## place a single visual-only tile without also bringing an imported collider
## (see docs/deviations/wp7.md). Kept small and arena-specific.
##
## ground_tile.glb holds both colour variants, GroundTile_A and GroundTile_B,
## 2 m apart (docs/deviations/wp1.md); each variant also imports its own
## StaticBody3D collider on layer 1, confirmed empirically in this project's
## Godot 4.7.2 (every "-colonly" collider imports on layer 1 regardless of the
## model, docs/3d-port-contracts.md section 10). The level's only walkable
## surface is the flat "Ground" box under NavigationRegion3D (contracts,
## section 9); this node sits outside that region so its meshes never reach
## the navmesh bake, and it frees every imported tile collider at _ready() so
## a tile contributes a MeshInstance3D only, never a second floor collider
## sitting a few centimetres off from "Ground" (which would give the navmesh
## stairs if it were ever picked up).
##
## One glb instance is a 4 x 2 m pair: GroundTile_A at local x = -1,
## GroundTile_B at local x = +1. Repeating that pair every 4 m along x
## reproduces the correct A/B/A/B alternation on its own; flipping alternate
## rows 180 degrees about Y swaps which side holds which colour, completing a
## true two-axis checkerboard with one instance per pair.

const TILE_SCENE := preload("res://assets/3d/models/ground_tile.glb")
const GRID_ROWS := 14      # 14 x 14 tiles of 2 m = 28 x 28 m: covers the
                            # 24 x 24 m clearing plus the tree ring around it.
const TILE_SIZE := 2.0
const SLOT_WIDTH := 4.0    # one glb instance = one A/B pair, 2 tiles wide


func _ready() -> void:
	var half_extent := TILE_SIZE * float(GRID_ROWS) * 0.5
	var slots_per_row := GRID_ROWS / 2
	for row in range(GRID_ROWS):
		var z := -half_extent + TILE_SIZE * float(row) + TILE_SIZE * 0.5
		var flipped := row % 2 == 1
		for slot in range(slots_per_row):
			var x := -half_extent + SLOT_WIDTH * float(slot) + SLOT_WIDTH * 0.5
			_place_pair(Vector3(x, 0.0, z), flipped)


func _place_pair(local_position: Vector3, flipped: bool) -> void:
	var pair := TILE_SCENE.instantiate() as Node3D
	add_child(pair)
	pair.position = local_position
	if flipped:
		pair.rotation_degrees.y = 180.0
	_strip_colliders(pair)


## Tiles are visual only: strip every imported StaticBody3D so the arena's
## flat "Ground" box stays the single walkable collider in the level.
func _strip_colliders(node: Node) -> void:
	for child in node.get_children():
		if child is StaticBody3D:
			child.queue_free()
		else:
			_strip_colliders(child)
