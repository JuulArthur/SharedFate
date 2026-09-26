extends Node3D

## Style study check for the pixel-textured mage (docs/style-study/mage_pixel.md).
## Instances assets/3d/models/styles/mage_pixel.glb, prints its node tree, bones,
## clips, triangle count and atlas texture, plays `walk` for WALK_FRAMES frames
## and prints MAGE_PIXEL OK when `idle`, `walk` and `cast` exist and every
## textured surface samples the atlas with a nearest filter.
##
## Run headless:
##   godot --headless --path . res://scenes/3d/tests/styles/mage_pixel_view.tscn --quit-after 600
## Opened in the editor it shows the model through the game's camera angle.

const MODEL_PATH := "res://assets/3d/models/styles/mage_pixel.glb"
const REQUIRED_CLIPS: Array[StringName] = [&"idle", &"walk", &"cast"]
const WALK_FRAMES := 60
## The game camera (CameraRig3D): yaw 45, pitch -35, orthographic.
const CAMERA_YAW_DEGREES := 45.0
const CAMERA_PITCH_DEGREES := -35.0
const CAMERA_SIZE_METERS := 3.5

var _model: Node3D = null
var _player: AnimationPlayer = null
var _skeleton: Skeleton3D = null
var _leg_bone := -1
var _frames := -1
var _errors := PackedStringArray()


func _ready() -> void:
	Engine.max_fps = 60
	_add_view()
	var packed := load(MODEL_PATH) as PackedScene
	if packed == null:
		_errors.append("cannot load %s" % MODEL_PATH)
		_finish()
		return
	_model = packed.instantiate() as Node3D
	add_child(_model)
	print("MAGE_PIXEL tree:")
	_print_tree(_model, 1)
	_skeleton = _first_of_class(_model, "Skeleton3D") as Skeleton3D
	_player = _first_of_class(_model, "AnimationPlayer") as AnimationPlayer
	_report_skeleton()
	_report_clips()
	_report_meshes()
	for node_name in ["HandPoint", "OverheadAnchor", "Staff"]:
		var found := _model.find_child(node_name, true, false) as Node3D
		if found == null:
			_errors.append("no %s" % node_name)
		else:
			print("MAGE_PIXEL %s under %s at %s" % [node_name, found.get_parent().name, _fmt(found.global_position)])
	_check_drop_in(packed)
	if _player == null or not _player.has_animation(&"walk"):
		_finish()
		return
	_player.play(&"walk")
	_frames = 0


## The player's SoulBodies3D reads a body by node names only; a second instance
## under one proves this model would replace mage.glb as it is.
func _check_drop_in(packed: PackedScene) -> void:
	var bodies := SoulBodies3D.new()
	bodies.name = "Model"
	bodies.position = Vector3(2.0, 0.0, 0.0)
	var copy := packed.instantiate() as Node3D
	copy.name = "Mage"
	bodies.add_child(copy)
	bodies.body_paths = [^"Mage"]
	bodies.held_weapon_names = PackedStringArray(["Staff"])
	bodies.extra_weapon_names = PackedStringArray([""])
	bodies.grip_tilt_degrees = PackedFloat32Array([0.0])
	bodies.grip_offsets = PackedVector3Array([Vector3.ZERO])
	add_child(bodies)
	var weapon := bodies.get_held_weapon_mesh()
	var anims := bodies.get_animation_player()
	print("MAGE_PIXEL drop-in: body=%s hand=%s overhead=%.3f m weapon=%s fit_origin=%s clips=%s"
		% [bodies.get_active_body(), _fmt(bodies.get_hand_transform().origin), bodies.get_overhead_height(),
			weapon.name if weapon != null else "none", _fmt(bodies.get_weapon_fit().origin),
			anims.get_animation_list() if anims != null else PackedStringArray()])
	if bodies.get_active_body() == null or bodies.get_hand_point() == null:
		_errors.append("SoulBodies3D did not take the model")
	if weapon == null or weapon.name != "Staff":
		_errors.append("SoulBodies3D found no Staff")
	if anims == null or not anims.has_animation(&"idle") or not anims.has_animation(&"walk"):
		_errors.append("SoulBodies3D found no idle / walk")


func _process(_delta: float) -> void:
	if _frames < 0:
		return
	_frames += 1
	if _frames < WALK_FRAMES:
		return
	_frames = -1
	var swing := 0.0
	if _skeleton != null and _leg_bone >= 0:
		var pose := _skeleton.get_bone_pose_rotation(_leg_bone)
		var rest := _skeleton.get_bone_rest(_leg_bone).basis.get_rotation_quaternion()
		swing = rad_to_deg(pose.angle_to(rest))
	print("MAGE_PIXEL walk played %d frames: %s at %.3f s of %.3f s, Leg_R %.1f deg off rest"
		% [WALK_FRAMES, _player.current_animation, _player.current_animation_position,
			_player.current_animation_length, swing])
	if _player.current_animation != "walk":
		_errors.append("walk stopped playing")
	_finish()


func _report_skeleton() -> void:
	if _skeleton == null:
		_errors.append("no Skeleton3D")
		return
	var names := PackedStringArray()
	for i in range(_skeleton.get_bone_count()):
		names.append(_skeleton.get_bone_name(i))
	print("MAGE_PIXEL bones=%d %s" % [_skeleton.get_bone_count(), ", ".join(names)])
	_leg_bone = _skeleton.find_bone("Leg_R")


func _report_clips() -> void:
	if _player == null:
		_errors.append("no AnimationPlayer")
		return
	for clip_name in _player.get_animation_list():
		var anim := _player.get_animation(clip_name)
		print("MAGE_PIXEL clip %-5s %.3f s loop=%d tracks=%d"
			% [clip_name, anim.length, anim.loop_mode, anim.get_track_count()])
	for clip in REQUIRED_CLIPS:
		if not _player.has_animation(clip):
			_errors.append("missing clip %s" % clip)


func _report_meshes() -> void:
	var triangles := 0
	var textured := 0
	for node in _model.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		var mesh := mi.mesh as ArrayMesh
		if mesh == null:
			continue
		var mesh_tris := 0
		for surface in range(mesh.get_surface_count()):
			var count := mesh.surface_get_array_index_len(surface)
			if count <= 0:
				count = mesh.surface_get_array_len(surface)
			mesh_tris += int(count / 3.0)
			var material := mi.get_active_material(surface) as BaseMaterial3D
			if material == null:
				continue
			var texture := material.albedo_texture
			if texture == null:
				print("MAGE_PIXEL   %s surface %d material %s untextured" % [mi.name, surface, material.resource_name])
				continue
			textured += 1
			var image := texture.get_image()
			var format := "n/a"
			if image != null:
				format = "%d%s" % [image.get_format(), " compressed" if image.is_compressed() else " uncompressed"]
			print("MAGE_PIXEL   %s surface %d material %s texture %dx%d %s filter=%s image_format=%s"
				% [mi.name, surface, material.resource_name, texture.get_width(), texture.get_height(),
					texture.get_class(), _filter_name(material.texture_filter), format])
			if not _is_nearest(material.texture_filter):
				_errors.append("%s surface %d filters its texture with %s"
					% [mi.name, surface, _filter_name(material.texture_filter)])
		print("MAGE_PIXEL mesh %s triangles=%d surfaces=%d skinned=%s"
			% [mi.name, mesh_tris, mesh.get_surface_count(), mi.skin != null])
		triangles += mesh_tris
	print("MAGE_PIXEL triangles=%d" % triangles)
	if textured == 0:
		_errors.append("no textured surface")


func _finish() -> void:
	for error in _errors:
		print("MAGE_PIXEL FAIL %s" % error)
	if _errors.is_empty():
		print("MAGE_PIXEL OK")
	get_tree().quit(0 if _errors.is_empty() else 1)


func _add_view() -> void:
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = CAMERA_SIZE_METERS
	var view_basis := Basis.from_euler(Vector3(deg_to_rad(CAMERA_PITCH_DEGREES), deg_to_rad(CAMERA_YAW_DEGREES), 0.0))
	camera.transform = Transform3D(view_basis, Vector3(0.0, 1.0, 0.0) + view_basis.z * 30.0)
	add_child(camera)
	camera.current = true
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55.0, 30.0, 0.0)
	sun.light_energy = 1.3
	add_child(sun)


func _print_tree(node: Node, depth: int) -> void:
	var extra := ""
	var attachment := node as BoneAttachment3D
	if attachment != null:
		extra = " bone=%s" % attachment.bone_name
	print("MAGE_PIXEL %s%s (%s)%s" % ["  ".repeat(depth), node.name, node.get_class(), extra])
	for child in node.get_children():
		_print_tree(child, depth + 1)


static func _first_of_class(root: Node, type_name: String) -> Node:
	var found := root.find_children("*", type_name, true, false)
	return found[0] if not found.is_empty() else null


static func _is_nearest(filter: BaseMaterial3D.TextureFilter) -> bool:
	return filter in [BaseMaterial3D.TEXTURE_FILTER_NEAREST,
		BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS,
		BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS_ANISOTROPIC]


static func _filter_name(filter: BaseMaterial3D.TextureFilter) -> String:
	match filter:
		BaseMaterial3D.TEXTURE_FILTER_NEAREST:
			return "NEAREST"
		BaseMaterial3D.TEXTURE_FILTER_LINEAR:
			return "LINEAR"
		BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS:
			return "NEAREST_WITH_MIPMAPS"
		BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS:
			return "LINEAR_WITH_MIPMAPS"
		BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS_ANISOTROPIC:
			return "NEAREST_WITH_MIPMAPS_ANISOTROPIC"
		BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC:
			return "LINEAR_WITH_MIPMAPS_ANISOTROPIC"
	return str(filter)


static func _fmt(v: Vector3) -> String:
	return "(%.3f, %.3f, %.3f)" % [v.x, v.y, v.z]
