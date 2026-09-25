class_name SoulBodies3D
extends Node3D

## WP9: one body per soul. Attached to `Player/Model`, whose children are the
## three imported characters (`assets/3d/models/knight.glb`, `rogue.glb`,
## `mage.glb`), authored in `scenes/3d/player_3d.tscn` as `Knight`, `Rogue` and
## `Mage`. All three are instanced with the scene, so a shift only flips
## visibility and never loads anything; exactly one body is visible and the
## others are hidden with their processing disabled.
##
## Player3D owns the held weapon through
## `HandPoint/EquippedWeaponHolder/EquippedWeaponMesh` (the archetype animations
## key the holder, docs/3d-port-contracts.md, section 5.2). This node only
## describes the active body: where its `HandPoint` and `OverheadAnchor` empties
## sit, which of its meshes is the weapon in the right hand and how that weapon
## hangs from the hand. The player copies the weapon mesh onto
## `EquippedWeaponMesh` with `transfer_weapon` and moves its own `HandPoint` and
## `OverheadAnchor` to the body's empties on every shift. The glb's own copy of
## the held weapon stays hidden; an off-hand weapon (the rogue's `Dagger_L`)
## stays visible in the model.
##
## The imported trees nest the empties and the weapons under `<Name>_Body`
## (docs/deviations/wp8.md, deviation 1), so every lookup is recursive. All
## transforms are measured through the local transform chain at `_ready`, when
## nothing is tweened yet, so a scale punch or an attack lunge running at the
## moment of a shift never leaks into the hand or anchor positions.

const HAND_POINT_NAME := "HandPoint"
const OVERHEAD_ANCHOR_NAME := "OverheadAnchor"
## The shift effect: the new body grows from this scale back to its rest scale.
const SHIFT_PUNCH_FROM_SCALE := 0.85
const SHIFT_PUNCH_SECONDS := 0.15

## Child body per soul, in `Soul.Kind` order (knight, rogue, mage).
@export var body_paths: Array[NodePath] = [^"Knight", ^"Rogue", ^"Mage"]
## Name of the mesh each body holds in its right hand; it is handed to the
## player's `EquippedWeaponMesh`.
@export var held_weapon_names: PackedStringArray = PackedStringArray(["Sword", "Dagger_R", "Staff"])
## Further weapon meshes that stay visible in the model (the rogue's left
## dagger), comma separated per body.
@export var extra_weapon_names: PackedStringArray = PackedStringArray(["", "Dagger_L", ""])
## Per-soul fit of the held weapon on top of the glb's hang (degrees about the
## hand's local X, then an offset in metres). The knight and the rogue keep the
## grip the Iron Sword and the Dagger items author in 2D (-25 / -20 degrees,
## 2 / 1 px up at Player3D.WEAPON_RANGE_METERS_PER_PIXEL); the staff stands as
## modelled.
@export var grip_tilt_degrees: PackedFloat32Array = PackedFloat32Array([-25.0, -20.0, 0.0])
@export var grip_offsets: PackedVector3Array = PackedVector3Array([
	Vector3(0.0, 0.06, 0.0), Vector3(0.0, 0.03, 0.0), Vector3.ZERO])
## Soul shown before the player picks one.
@export var initial_kind := 0


class Body:
	var kind := 0
	var root: Node3D = null
	var rest_transform := Transform3D.IDENTITY
	var hand: Node3D = null
	var overhead: Node3D = null
	var held_weapon: MeshInstance3D = null
	var weapons: Array[MeshInstance3D] = []
	## The HandPoint empty in the parent's (the player's) space, at rest.
	var hand_transform := Transform3D.IDENTITY
	## The held weapon relative to the HandPoint as modelled, plus the soul's fit.
	var weapon_fit := Transform3D.IDENTITY
	var overhead_height := 0.0


var _bodies: Array[Body] = []
var _active: Body = null
var _punch: Tween = null


func _ready() -> void:
	_bodies.clear()
	for i in range(body_paths.size()):
		var body := _describe_body(i)
		if body != null:
			_bodies.append(body)
	if _bodies.is_empty():
		push_warning("%s: no soul bodies found under %s" % [name, get_path()])
		return
	show_soul(initial_kind)


## Makes the body of soul `kind` (a `Soul.Kind` value) the only visible one.
## Returns false, and leaves the current body up, for an unknown kind.
func show_soul(kind: int) -> bool:
	var wanted := _body_of_kind(kind)
	if wanted == null:
		push_warning("%s: no body for soul kind %d" % [name, kind])
		return false
	_stop_punch()
	for body in _bodies:
		var active := body == wanted
		body.root.visible = active
		body.root.process_mode = Node.PROCESS_MODE_INHERIT if active else Node.PROCESS_MODE_DISABLED
		body.root.transform = body.rest_transform
	_active = wanted
	return true


## The shift effect: the active body grows from SHIFT_PUNCH_FROM_SCALE to its
## rest scale. Kept on the body, not on `Model`, because the archetype
## animations and the attack tweens own `Model:scale`.
func punch_active_body() -> void:
	if _active == null:
		return
	_stop_punch()
	var rest_scale := _active.rest_transform.basis.get_scale()
	_active.root.scale = rest_scale * SHIFT_PUNCH_FROM_SCALE
	_punch = create_tween()
	_punch.tween_property(_active.root, "scale", rest_scale, SHIFT_PUNCH_SECONDS) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func get_active_kind() -> int:
	return _active.kind if _active != null else -1


func get_active_body() -> Node3D:
	return _active.root if _active != null else null


func get_body(kind: int) -> Node3D:
	var body := _body_of_kind(kind)
	return body.root if body != null else null


## The active body's `HandPoint` empty.
func get_hand_point() -> Node3D:
	return _active.hand if _active != null else null


## The active body's `HandPoint` in the parent's space at rest; Player3D puts
## its own `HandPoint` here.
func get_hand_transform() -> Transform3D:
	return _active.hand_transform if _active != null else Transform3D.IDENTITY


## Height of the active body's `OverheadAnchor` above the parent's origin (the
## feet): 0.25 m above the head as WP1 modelled it.
func get_overhead_height() -> float:
	return _active.overhead_height if _active != null else 0.0


## The active body's weapon meshes: the one in the right hand first (hidden in
## the model, shown on the player's `EquippedWeaponMesh`), then any off-hand
## weapon that stays visible in the model.
func get_weapon_meshes() -> Array[MeshInstance3D]:
	var meshes: Array[MeshInstance3D] = []
	if _active != null:
		meshes.append_array(_active.weapons)
	return meshes


## The active body's right-hand weapon (hidden in the model), or null.
func get_held_weapon_mesh() -> MeshInstance3D:
	return _active.held_weapon if _active != null else null


## Where the held weapon sits under `EquippedWeaponHolder`: the glb's own hang
## (a 180 degree turn about X for the blades, upright for the staff) plus the
## soul's grip fit.
func get_weapon_fit() -> Transform3D:
	return _active.weapon_fit if _active != null else Transform3D.IDENTITY


## Copies the mesh and the material overrides of `source` onto `target`. The
## transform is not copied: `target` sits in the player's hand and gets
## `get_weapon_fit()`. `material_overlay` is left alone, because HitFlash3D
## owns it.
static func transfer_weapon(source: MeshInstance3D, target: MeshInstance3D) -> void:
	if source == null or target == null:
		return
	target.mesh = source.mesh
	if source.mesh != null:
		for surface in range(source.mesh.get_surface_count()):
			target.set_surface_override_material(surface, source.get_surface_override_material(surface))
	target.material_override = source.material_override


# --- Internals -------------------------------------------------------------------

func _describe_body(index: int) -> Body:
	var root := get_node_or_null(body_paths[index]) as Node3D
	if root == null:
		push_warning("%s: no body at %s" % [name, body_paths[index]])
		return null
	var body := Body.new()
	body.kind = index
	body.root = root
	body.rest_transform = root.transform
	body.hand = root.find_child(HAND_POINT_NAME, true, false) as Node3D
	body.overhead = root.find_child(OVERHEAD_ANCHOR_NAME, true, false) as Node3D

	var to_parent := transform * body.rest_transform
	var hand_in_root := _chain_to(body.hand, root) if body.hand != null else Transform3D.IDENTITY
	if body.hand == null:
		push_warning("%s: %s has no %s; the hand stays where the scene put it" % [name, root.name, HAND_POINT_NAME])
	body.hand_transform = to_parent * hand_in_root
	if body.overhead != null:
		body.overhead_height = (to_parent * _chain_to(body.overhead, root)).origin.y
	else:
		push_warning("%s: %s has no %s" % [name, root.name, OVERHEAD_ANCHOR_NAME])
		body.overhead_height = (to_parent * hand_in_root).origin.y

	var held_name := held_weapon_names[index] if index < held_weapon_names.size() else ""
	if not held_name.is_empty():
		body.held_weapon = root.find_child(held_name, true, false) as MeshInstance3D
		if body.held_weapon == null:
			push_warning("%s: %s has no MeshInstance3D named '%s'" % [name, root.name, held_name])
	if body.held_weapon != null:
		body.weapons.append(body.held_weapon)
		var hang := hand_in_root.affine_inverse() * _chain_to(body.held_weapon, root)
		var tilt := grip_tilt_degrees[index] if index < grip_tilt_degrees.size() else 0.0
		var offset := grip_offsets[index] if index < grip_offsets.size() else Vector3.ZERO
		body.weapon_fit = Transform3D(Basis(Vector3.RIGHT, deg_to_rad(tilt)), offset) * hang
		body.held_weapon.visible = false
	var extra := extra_weapon_names[index] if index < extra_weapon_names.size() else ""
	for extra_name in extra.split(",", false):
		var mesh := root.find_child(extra_name.strip_edges(), true, false) as MeshInstance3D
		if mesh != null:
			body.weapons.append(mesh)
	return body


## `node`'s transform in `root`'s space, from the local transforms, so it works
## before the node is in the tree and ignores `root`'s own transform.
static func _chain_to(node: Node3D, root: Node3D) -> Transform3D:
	var result := Transform3D.IDENTITY
	var current: Node = node
	while current != null and current != root:
		var spatial := current as Node3D
		if spatial != null:
			result = spatial.transform * result
		current = current.get_parent()
	return result


func _body_of_kind(kind: int) -> Body:
	for body in _bodies:
		if body.kind == kind:
			return body
	return null


func _stop_punch() -> void:
	if _punch != null and _punch.is_valid():
		_punch.kill()
	_punch = null
	if _active != null and is_instance_valid(_active.root):
		_active.root.transform = _active.rest_transform
