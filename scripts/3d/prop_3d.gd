extends Node3D

## WP7 prop: relabels an imported prop's collider(s) for the level contract
## (docs/3d-port-contracts.md, section 3: props on collision layer 4 / bit
## value 8, mask 0) and marks the instance as navmesh source geometry.
##
## tree.glb, crate.glb and chest.glb (docs/3d-port-contracts.md section 10)
## each import their "<Name>_Col-colonly" collider as a StaticBody3D on
## Godot's default import layer (1), nested two levels under the prop's own
## root (confirmed empirically: Tree/Tree_Body/Tree_Col, Crate/Crate_Body/
## Crate_Col, Chest/Chest_Body/Chest_Col) with a ConcavePolygonShape3D rather
## than a box. This script assumes neither a fixed depth nor a shape type: it
## walks every descendant and relabels every StaticBody3D it finds.
##
## Attach to the prop instance's root, i.e. the node created by instancing
## tree.glb / crate.glb / chest.glb (see scenes/3d/arena.tscn).

const PROP_LAYER := 8


func _ready() -> void:
	_relabel_colliders(self)
	add_to_group("navmesh_source")


func _relabel_colliders(node: Node) -> void:
	for child in node.get_children():
		if child is StaticBody3D:
			var body := child as StaticBody3D
			body.collision_layer = PROP_LAYER
			body.collision_mask = 0
		_relabel_colliders(child)
