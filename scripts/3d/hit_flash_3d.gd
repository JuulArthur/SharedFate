class_name HitFlash3D
extends Node

## 3D twin of `CombatFx.flash`, which tints a 2D sprite through `self_modulate`.
## A 3D body has no modulate, so the flash is an unshaded additive
## `material_overlay` put on every `MeshInstance3D` under the body and faded out.
## The overlay never touches the meshes' own materials, so it composes with the
## archetype animations the same way `self_modulate` did in 2D.
##
## Two ways to use it: add it as a child of the body and call `flash()` from the
## body's `flash_hit()` (the actor-contract hook CombatFx.flash calls), or call
## `HitFlash3D.flash_node(body, ...)` statically without a child node.
## Contract: docs/3d-port-contracts.md, sections 5.1 and 7.

const DEFAULT_COLOR := Color(2.6, 2.6, 2.6, 1.0)
const DEFAULT_DURATION := 0.16


## Flashes every mesh under this node's parent.
func flash(color: Color = Color(2.6, 2.6, 2.6, 1.0), duration := 0.16) -> void:
	var parent := get_parent() as Node3D
	if parent == null:
		return
	flash_node(parent, color, duration)


## Same effect for a caller that has no HitFlash3D child.
static func flash_node(node: Node3D, color: Color = Color(2.6, 2.6, 2.6, 1.0),
		duration := 0.16) -> void:
	if node == null or not is_instance_valid(node) or not node.is_inside_tree():
		return
	var meshes: Array[MeshInstance3D] = []
	_gather_meshes(node, meshes)
	if meshes.is_empty():
		return

	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	material.cull_mode = BaseMaterial3D.CULL_BACK
	material.albedo_color = color

	# Whatever overlay the mesh already had (an outline, say) comes back after.
	var previous: Array = []
	for mesh in meshes:
		previous.append(mesh.material_overlay)
		mesh.material_overlay = material

	var tween := node.create_tween()
	tween.tween_property(material, "albedo_color:a", 0.0, maxf(duration, 0.01)) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_callback(func() -> void: _restore(meshes, previous))


static func _gather_meshes(node: Node, out: Array[MeshInstance3D]) -> void:
	for child in node.get_children():
		if child is MeshInstance3D:
			out.append(child as MeshInstance3D)
		_gather_meshes(child, out)


static func _restore(meshes: Array[MeshInstance3D], previous: Array) -> void:
	for i in range(meshes.size()):
		var mesh := meshes[i]
		if mesh == null or not is_instance_valid(mesh):
			continue
		mesh.material_overlay = previous[i] as Material
