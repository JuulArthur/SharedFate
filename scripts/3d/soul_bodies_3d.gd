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
## Every lookup is by name and recursive, so it does not depend on where the
## glTF importer puts things. Since WP11 the bodies are rigged
## (docs/deviations/wp11.md): the tree is `<Name>/<Name>_Armature/Skeleton3D`
## with the skinned `<Name>_Body` (and `Knight_Cape`) under the skeleton,
## `HandPoint` and the right-hand weapon under a `BoneAttachment3D` named
## `LowerArm_R`, the rogue's `Dagger_L` under `LowerArm_L`, `OverheadAnchor`
## under the armature node, and an `AnimationPlayer` with looping `idle` and
## `walk` at the root. The rest transforms are measured through the local
## transform chain at `_ready`, substituting the skeleton's bone rest for a
## bone attachment, so a scale punch, an attack lunge or a half-played walk at
## the moment of a shift never leaks into the fit.
##
## The hand moves with the arm now: `get_live_hand_transform()` is the active
## body's `HandPoint` as the skeleton currently poses it, and
## `active_pose_updated` fires whenever the active skeleton has a new pose, so
## the player can move its own `HandPoint` (and the weapon under it) along.

## Emitted after the active body's skeleton computed a new pose.
signal active_pose_updated

const HAND_POINT_NAME := "HandPoint"
const OVERHEAD_ANCHOR_NAME := "OverheadAnchor"
## The imported clips every body must loop (WP11). The import settings set
## their loop mode; `_ready` enforces it again for a file imported without.
const LOCOMOTION_CLIPS: Array[StringName] = [&"idle", &"walk"]
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
	## The rig (WP11); either may be null for an unrigged body.
	var skeleton: Skeleton3D = null
	var animation_player: AnimationPlayer = null


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
	# The attack lunge, recoil and squash tween this node after the skeleton
	# has updated for the frame; a local transform notification re-announces
	# the pose so a follower of the hand does not trail those by a frame.
	set_notify_local_transform(true)
	show_soul(initial_kind)


func _notification(what: int) -> void:
	if what == NOTIFICATION_LOCAL_TRANSFORM_CHANGED and _active != null:
		active_pose_updated.emit()


## Makes the body of soul `kind` (a `Soul.Kind` value) the only visible one.
## Returns false, and leaves the current body up, for an unknown kind.
func show_soul(kind: int) -> bool:
	var wanted := _body_of_kind(kind)
	if wanted == null:
		push_warning("%s: no body for soul kind %d" % [name, kind])
		return false
	_stop_punch()
	var previous := _active
	for body in _bodies:
		var active := body == wanted
		body.root.visible = active
		body.root.process_mode = Node.PROCESS_MODE_INHERIT if active else Node.PROCESS_MODE_DISABLED
		body.root.transform = body.rest_transform
	_active = wanted
	if previous != null and previous != wanted:
		_carry_animation_state(previous, wanted)
	return true


## The shift effect: the active body grows from SHIFT_PUNCH_FROM_SCALE to its
## rest scale. Kept on the body, not on `Model`, because the archetype
## animations and the attack tweens own `Model:scale`.
func punch_active_body() -> void:
	if _active == null:
		return
	_stop_punch()
	var rest_scale := _active.rest_transform.basis.get_scale()
	_set_punch_scale(rest_scale * SHIFT_PUNCH_FROM_SCALE)
	# A method tween, so every step also re-announces the pose: the tween runs
	# after the skeleton's update for the frame and the hand would trail it.
	_punch = create_tween()
	_punch.tween_method(_set_punch_scale, rest_scale * SHIFT_PUNCH_FROM_SCALE, rest_scale, SHIFT_PUNCH_SECONDS) \
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


## The active body's `HandPoint` in the parent's space at rest.
func get_hand_transform() -> Transform3D:
	return _active.hand_transform if _active != null else Transform3D.IDENTITY


## The active body's `HandPoint` in the parent's space as the skeleton poses it
## right now, through this node's and the body's current transforms (so it
## follows the walk, the attack lunge and the shift punch). The basis is
## orthonormalised: the `Model:scale` squash of an attack must not squash the
## weapon. Falls back to the rest transform for an unrigged body.
func get_live_hand_transform() -> Transform3D:
	if _active == null or _active.hand == null:
		return get_hand_transform()
	var live := transform * _active.root.transform * _chain_to(_active.hand, _active.root, true)
	return live.orthonormalized()


## The active body's AnimationPlayer with the `idle` and `walk` clips, or null.
func get_animation_player() -> AnimationPlayer:
	return _active.animation_player if _active != null else null


## The active body's Skeleton3D, or null.
func get_skeleton() -> Skeleton3D:
	return _active.skeleton if _active != null else null


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
	body.skeleton = _first_of_class(root, "Skeleton3D") as Skeleton3D
	body.animation_player = _first_of_class(root, "AnimationPlayer") as AnimationPlayer
	if body.animation_player != null:
		for clip in LOCOMOTION_CLIPS:
			if not body.animation_player.has_animation(clip):
				push_warning("%s: %s has no '%s' animation" % [name, root.name, clip])
				continue
			var anim := body.animation_player.get_animation(clip)
			if anim.loop_mode == Animation.LOOP_NONE:
				anim.loop_mode = Animation.LOOP_LINEAR
	if body.skeleton != null:
		body.skeleton.skeleton_updated.connect(_on_skeleton_updated.bind(index))

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
## before the node is in the tree and ignores `root`'s own transform. A
## `BoneAttachment3D` under a skeleton stands for its bone: at rest
## (`live` false) the bone's global rest, else the bone's current global pose,
## read from the skeleton rather than from the attachment, which only catches
## up when the skeleton next updates.
static func _chain_to(node: Node3D, root: Node3D, live: bool = false) -> Transform3D:
	var result := Transform3D.IDENTITY
	var current: Node = node
	while current != null and current != root:
		var attachment := current as BoneAttachment3D
		var skeleton := current.get_parent() as Skeleton3D
		if attachment != null and skeleton != null:
			var bone := skeleton.find_bone(attachment.bone_name)
			if bone >= 0:
				var bone_pose := skeleton.get_bone_global_pose(bone) if live else skeleton.get_bone_global_rest(bone)
				result = bone_pose * result
				current = skeleton
				continue
		var spatial := current as Node3D
		if spatial != null:
			result = spatial.transform * result
		current = current.get_parent()
	return result


static func _first_of_class(root: Node, type_name: String) -> Node:
	var found := root.find_children("*", type_name, true, false)
	return found[0] if not found.is_empty() else null


## A shift hands the locomotion over: the new body plays what the old one was
## playing, from the same point and at the same speed, so a shift mid-stride
## keeps the stride instead of snapping to the start of a clip.
func _carry_animation_state(from: Body, to: Body) -> void:
	var source := from.animation_player
	var target := to.animation_player
	if source == null or target == null:
		return
	var clip := StringName(source.current_animation)
	if clip == &"" or not target.has_animation(clip):
		return
	target.speed_scale = source.speed_scale
	target.play(clip, 0.0)
	target.seek(fmod(source.current_animation_position, target.current_animation_length), true)


func _set_punch_scale(value: Vector3) -> void:
	if _active == null or not is_instance_valid(_active.root):
		return
	_active.root.scale = value
	active_pose_updated.emit()


func _on_skeleton_updated(kind: int) -> void:
	if _active != null and _active.kind == kind:
		active_pose_updated.emit()


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
