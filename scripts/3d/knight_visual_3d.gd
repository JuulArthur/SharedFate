class_name KnightVisual3D
extends Node3D

## WP8: the imported knight (assets/3d/models/knight.glb) as the player's body.
##
## Attached to the glb instance root under `Player/Model`. The glb carries its
## own `Sword` mesh at the right hand (origin at the grip, blade along local +Y,
## hung point-down by a 180 degree X rotation; docs/3d-port-contracts.md,
## section 10). The player script owns the held weapon through
## `HandPoint/EquippedWeaponHolder/EquippedWeaponMesh`: the archetype animations
## key the holder and the item's grip tuning goes on the mesh node. So this
## script hands the sword mesh over to that node in `_ready` and hides the glb's
## own copy. Player3D keeps a scene-authored mesh on `EquippedWeaponMesh`
## (docs/deviations/wp3b.md, D4), and Godot readies children before their
## parent, so the hand-over is in place before `Player3D._ready` runs.
##
## The imported tree nests the empties and the sword under the body mesh
## (`Knight/Knight_Body/{HandPoint, OverheadAnchor, Sword, ...}`), so the lookup
## is recursive.

const SWORD_NODE_NAME := "Sword"

## The player's held-weapon mesh, relative to this node.
@export var equipped_weapon_mesh_path: NodePath = ^"../../HandPoint/EquippedWeaponHolder/EquippedWeaponMesh"

var _sword: MeshInstance3D = null


func _ready() -> void:
	_sword = find_child(SWORD_NODE_NAME, true, false) as MeshInstance3D
	if _sword == null:
		push_warning("%s: no MeshInstance3D named '%s' in the knight model; the player keeps its placeholder blade" % [name, SWORD_NODE_NAME])
		return
	var weapon_mesh := get_node_or_null(equipped_weapon_mesh_path) as MeshInstance3D
	if weapon_mesh == null:
		push_warning("%s: no MeshInstance3D at %s; the knight keeps its own sword" % [name, equipped_weapon_mesh_path])
		return
	transfer_sword(_sword, weapon_mesh)


## Copies the mesh and the surface material overrides of `source` onto `target`
## and hides `source`. The transform is deliberately not copied: `target` sits
## in the hand already and Player3D applies the item's grip offset and hang
## rotation to it.
static func transfer_sword(source: MeshInstance3D, target: MeshInstance3D) -> void:
	if source == null or target == null:
		return
	target.mesh = source.mesh
	if source.mesh != null:
		for surface in range(source.mesh.get_surface_count()):
			target.set_surface_override_material(surface, source.get_surface_override_material(surface))
	target.material_override = source.material_override
	source.visible = false


## The glb's own sword mesh (hidden after `_ready`), for tests.
func get_sword() -> MeshInstance3D:
	return _sword
