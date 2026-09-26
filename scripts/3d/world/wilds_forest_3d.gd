class_name WildsForest3D
extends MultiMeshInstance3D

## Track A: the deep forest of the Wilds, drawn as one MultiMesh of the WP1
## tree (`tree.glb`'s `Tree_Body` mesh) built at load from WildsLayout.
##
## The builder plants real `tree.glb` instances (with colliders, under the
## navigation region) only along the edge of the open ground, where the player
## walks past them; everything deeper is scenery and would cost a node and a
## collider per tree. Movement and line of sight in the forest are blocked by
## the builder's invisible `ForestWalls` boxes, not by these trees.

const TREE_SCENE_PATH := "res://assets/3d/models/tree.glb"

## Metres from the open ground where the filler starts (the builder's edge
## band ends at 2.8 m).
@export var min_distance_m := 3.3
## Grid spacing of the jittered scatter.
@export var spacing_m := 2.4
## Extra margin outside the map square so the rim looks filled.
@export var outer_margin_m := 6.0
@export var scatter_seed := 17


func _ready() -> void:
	var tree_mesh := _load_tree_mesh()
	if tree_mesh == null:
		push_warning("WildsForest3D: no tree mesh in %s" % TREE_SCENE_PATH)
		return
	var transforms := _scatter()
	var multi := MultiMesh.new()
	multi.transform_format = MultiMesh.TRANSFORM_3D
	multi.mesh = tree_mesh
	multi.instance_count = transforms.size()
	for i in range(transforms.size()):
		multi.set_instance_transform(i, transforms[i])
	multimesh = multi


## Number of trees drawn (for tests and the docs).
func get_tree_count() -> int:
	return multimesh.instance_count if multimesh != null else 0


func _scatter() -> Array[Transform3D]:
	var rng := RandomNumberGenerator.new()
	rng.seed = scatter_seed
	var out: Array[Transform3D] = []
	var extent := WildsLayout.MAP_HALF_M + outer_margin_m
	var steps := int(ceil(extent * 2.0 / spacing_m))
	for row in range(steps):
		for col in range(steps):
			var ground := Vector2(-extent + (float(col) + rng.randf_range(0.15, 0.85)) * spacing_m,
				-extent + (float(row) + rng.randf_range(0.15, 0.85)) * spacing_m)
			if WildsLayout.distance_to_open(ground) < min_distance_m:
				continue
			var tree_scale := rng.randf_range(0.85, 1.3)
			var basis := Basis(Vector3.UP, rng.randf_range(0.0, TAU)).scaled(Vector3(tree_scale, tree_scale * rng.randf_range(0.9, 1.15), tree_scale))
			out.append(Transform3D(basis, GroundMath.from_ground(ground)))
	return out


func _load_tree_mesh() -> Mesh:
	var scene := load(TREE_SCENE_PATH) as PackedScene
	if scene == null:
		return null
	var root := scene.instantiate()
	var found := _find_mesh(root)
	var result: Mesh = found.mesh if found != null else null
	root.free()
	return result


func _find_mesh(node: Node) -> MeshInstance3D:
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		return node as MeshInstance3D
	for child in node.get_children():
		var found := _find_mesh(child)
		if found != null:
			return found
	return null
