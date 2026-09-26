class_name WorldFx3D
extends RefCounted

## Track A: small static helpers shared by the world objects under
## scripts/3d/world/ (traps, barrels, waystones, chests): persistent hover
## highlights, simple procedural meshes and materials, and the lookups every
## object needs (the player, the level coordinator).
##
## Nothing here touches an autoload, so the file passes `--check-only`.

## Faint additive rim for a hovered interactable, the same idea as the
## enemy's hover overlay (Enemy3D.HOVER_TINT) in a neutral warm colour.
const HOVER_TINT := Color(1.0, 0.85, 0.45, 0.22)
## CombatFx draws projected bursts on its CanvasLayer in screen pixels; 2D
## radii scale by the 2D camera zoom to read the same (contracts section 7).
const FX_SCREEN_SCALE := 3.35
const FALLBACK_SCREEN_PX_PER_METER := 40.0


## Puts (or clears) a persistent additive overlay on every mesh under `node`.
## HitFlash3D saves and restores whatever overlay it finds, so a hit flash on
## a highlighted object comes back highlighted.
static func set_highlight(node: Node, enabled: bool, color: Color = HOVER_TINT) -> void:
	if node == null or not is_instance_valid(node):
		return
	var overlay: Material = null
	if enabled:
		var material := StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
		material.albedo_color = color
		overlay = material
	var meshes: Array[MeshInstance3D] = []
	gather_meshes(node, meshes)
	for mesh in meshes:
		mesh.material_overlay = overlay


static func gather_meshes(node: Node, out: Array[MeshInstance3D]) -> void:
	for child in node.get_children():
		if child is MeshInstance3D:
			out.append(child as MeshInstance3D)
		gather_meshes(child, out)


## A lit, rough, flat-coloured material (the low-poly look of the glb props).
static func flat_material(color: Color, roughness: float = 0.9, metallic: float = 0.0) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = roughness
	material.metallic = metallic
	return material


## An unshaded glowing material, optionally additive (fire, runes, glints).
static func glow_material(color: Color, additive: bool = false) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = color
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	if additive:
		material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	return material


## Adds a MeshInstance3D child with `mesh` and `material` at `position`.
static func add_mesh(parent: Node3D, mesh_name: String, mesh: Mesh, material: Material,
		position: Vector3 = Vector3.ZERO, rotation_degrees: Vector3 = Vector3.ZERO) -> MeshInstance3D:
	var instance := MeshInstance3D.new()
	instance.name = mesh_name
	instance.mesh = mesh
	instance.material_override = material
	instance.position = position
	instance.rotation_degrees = rotation_degrees
	parent.add_child(instance)
	return instance


## Adds a CollisionShape3D child with `shape` at `position`.
static func add_shape(parent: Node3D, shape: Shape3D, position: Vector3 = Vector3.ZERO) -> CollisionShape3D:
	var node := CollisionShape3D.new()
	node.name = "CollisionShape3D"
	node.shape = shape
	node.position = position
	parent.add_child(node)
	return node


## The player body (group `player`), or null.
static func find_player(tree: SceneTree) -> Node3D:
	if tree == null:
		return null
	return tree.get_first_node_in_group("player") as Node3D


## Whether a fight is running: the coordinator's `is_in_combat()` (gameplay
## expansion section 5) when it has one, else the player's own turn mode.
static func is_combat_running(tree: SceneTree) -> bool:
	if tree == null:
		return false
	var coordinator := tree.get_first_node_in_group("level_coordinator")
	if coordinator != null and coordinator.has_method("is_in_combat"):
		return bool(coordinator.call("is_in_combat"))
	var player := find_player(tree)
	if player != null and player.has_method("is_in_turn_based_combat"):
		return bool(player.call("is_in_turn_based_combat"))
	return false


## Calls `method` on every coordinator in group `level_coordinator` that has
## it (SceneTree.call_group would error on one that does not).
static func notify_coordinator(tree: SceneTree, method: StringName) -> void:
	if tree == null:
		return
	for node in tree.get_nodes_in_group("level_coordinator"):
		if node.has_method(method):
			node.call(method)


## Screen radius in pixels of a `radius_m` circle around `world_point`, for
## CombatFx.ring_burst (the player's `_screen_radius_px`, as a helper).
static func screen_radius_px(viewport_node: Node, world_point: Vector3, radius_m: float) -> float:
	if viewport_node == null or not viewport_node.is_inside_tree():
		return radius_m * FALLBACK_SCREEN_PX_PER_METER
	var camera := viewport_node.get_viewport().get_camera_3d()
	if camera == null:
		return radius_m * FALLBACK_SCREEN_PX_PER_METER
	var centre := camera.unproject_position(world_point)
	var edge := camera.unproject_position(world_point + camera.global_transform.basis.x * radius_m)
	return maxf(centre.distance_to(edge), 1.0)
