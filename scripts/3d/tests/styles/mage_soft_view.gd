extends Node3D

## Style study check for the soft sculpted mage (docs/style-study/mage_soft.md).
## Instances `mage_soft.glb`, prints its node tree, rig, clips, triangle count
## and vertex colour setup, plays `walk` for 60 frames and prints
## `MAGE_SOFT OK` when all three clips exist and the body is skinned. Headless
## it quits after the check; in a window it keeps cycling the clips under the
## game's camera angle so the model can be looked at.

const GLB_PATH := "res://assets/3d/models/styles/mage_soft.glb"
const CLIPS: Array[StringName] = [&"idle", &"walk", &"cast"]
const WALK_CHECK_FRAMES := 60

var _model: Node3D = null
var _skeleton: Skeleton3D = null
var _player: AnimationPlayer = null
var _frames := 0
var _checked := false
var _failures: PackedStringArray = PackedStringArray()
var _skinned := false
var _rest_foot := Vector3.ZERO


func _ready() -> void:
	var scene := load(GLB_PATH) as PackedScene
	if scene == null:
		_fail("cannot load %s" % GLB_PATH)
		_finish()
		return
	_model = scene.instantiate() as Node3D
	add_child(_model)
	_add_viewing_rig()

	print("MAGE_SOFT tree:")
	_print_tree(_model, 1)

	_skeleton = _first_of_class(_model, "Skeleton3D") as Skeleton3D
	_player = _first_of_class(_model, "AnimationPlayer") as AnimationPlayer
	if _skeleton == null:
		_fail("no Skeleton3D")
	else:
		var names := PackedStringArray()
		for i in range(_skeleton.get_bone_count()):
			names.append(_skeleton.get_bone_name(i))
		print("MAGE_SOFT bones=%d %s" % [_skeleton.get_bone_count(), ", ".join(names)])
	if _player == null:
		_fail("no AnimationPlayer")
	else:
		var listing := PackedStringArray()
		for clip in _player.get_animation_list():
			var anim := _player.get_animation(clip)
			listing.append("%s %.2f s loop=%d tracks=%d" % [clip, anim.length, anim.loop_mode, anim.get_track_count()])
		print("MAGE_SOFT clips: %s" % " | ".join(listing))
		for clip in CLIPS:
			if not _player.has_animation(clip):
				_fail("missing clip '%s'" % clip)

	_report_meshes()
	for want in ["HandPoint", "OverheadAnchor", "Staff"]:
		var node := _model.find_child(want, true, false) as Node3D
		if node == null:
			_fail("no %s" % want)
		else:
			print("MAGE_SOFT %s at %s under %s" % [want, node.global_position, node.get_parent().name])

	if _player != null and _player.has_animation(&"walk") and _skeleton != null:
		var foot := _skeleton.find_bone("Foot_R")
		if foot >= 0:
			_rest_foot = _skeleton.get_bone_global_rest(foot).origin
		_player.play(&"walk")


func _process(_delta: float) -> void:
	_frames += 1
	if _checked:
		_cycle_for_viewing()
		return
	if _frames < WALK_CHECK_FRAMES:
		return
	_checked = true
	if _player != null and _skeleton != null:
		var foot := _skeleton.find_bone("Foot_R")
		var moved := 0.0
		if foot >= 0:
			moved = (_skeleton.get_bone_global_pose(foot).origin - _rest_foot).length()
		print("MAGE_SOFT walk played %d frames: current=%s position=%.2f s Foot_R off rest by %.3f m"
			% [_frames, _player.current_animation, _player.current_animation_position, moved])
		if _player.current_animation != "walk":
			_fail("walk is not playing")
	if not _skinned:
		_fail("body mesh is not skinned")
	_finish()


func _report_meshes() -> void:
	var total := 0
	for node in _model.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.mesh == null:
			continue
		var tris := 0
		var colours := false
		var bones := false
		var albedo_from_colour := PackedStringArray()
		var mean := Color(0, 0, 0, 0)
		var count := 0
		for s in range(mi.mesh.get_surface_count()):
			var arrays: Array = mi.mesh.surface_get_arrays(s)
			var idx: Variant = arrays[Mesh.ARRAY_INDEX]
			var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var corners := (idx as PackedInt32Array).size() if idx is PackedInt32Array else verts.size()
			tris += int(corners / 3.0)
			var col_v: Variant = arrays[Mesh.ARRAY_COLOR]
			if col_v is PackedColorArray and not (col_v as PackedColorArray).is_empty():
				colours = true
				for c in (col_v as PackedColorArray):
					mean += c
					count += 1
			var bones_v: Variant = arrays[Mesh.ARRAY_BONES]
			if bones_v != null and (bones_v is PackedInt32Array or bones_v is PackedFloat32Array):
				bones = true
			var mat := mi.mesh.surface_get_material(s) as BaseMaterial3D
			if mat != null:
				albedo_from_colour.append("%s:%s%s" % [mat.resource_name, mat.vertex_color_use_as_albedo,
					" (external %s)" % mat.resource_path.get_file() if mat.resource_path.ends_with(".tres") else ""])
				# The body's look is its vertex colours: every surface must use them.
				if col_v is PackedColorArray and not mat.vertex_color_use_as_albedo:
					_fail("%s surface %d (%s) ignores its vertex colours" % [mi.name, s, mat.resource_name])
		total += tris
		var skinned := bones and mi.skin != null
		if mi.name.ends_with("_Body") and skinned:
			_skinned = true
		if count > 0:
			mean = Color(mean.r / count, mean.g / count, mean.b / count, 1.0)
		print("MAGE_SOFT mesh %s: surfaces=%d tris=%d skinned=%s vertex_colours=%s mean_colour=%s albedo_from_vertex_colour=[%s]"
			% [mi.name, mi.mesh.get_surface_count(), tris, skinned, colours, str(mean) if colours else "-",
				", ".join(albedo_from_colour)])
	print("MAGE_SOFT triangles total=%d" % total)


func _print_tree(node: Node, depth: int) -> void:
	if depth > 6:
		return
	var extra := ""
	if node is BoneAttachment3D:
		extra = " bone=%s" % (node as BoneAttachment3D).bone_name
	print("%s%s (%s)%s" % ["  ".repeat(depth), node.name, node.get_class(), extra])
	for child in node.get_children():
		_print_tree(child, depth + 1)


func _add_viewing_rig() -> void:
	# The game's camera angle (CameraRig3D: yaw 45, pitch -35, orthographic).
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 3.5
	var cam_basis := Basis.from_euler(Vector3(deg_to_rad(-35.0), deg_to_rad(45.0), 0.0))
	cam.transform = Transform3D(cam_basis, Vector3(0.0, 1.0, 0.0) + cam_basis.z * 30.0)
	cam.far = 100.0
	add_child(cam)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55.0, 30.0, 0.0)
	sun.light_energy = 1.3
	sun.shadow_enabled = true
	add_child(sun)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.09, 0.10, 0.15)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.5, 0.55, 0.65)
	env.ambient_light_energy = 0.9
	var world := WorldEnvironment.new()
	world.environment = env
	add_child(world)


func _cycle_for_viewing() -> void:
	if _player == null or _frames % 240 != 0:
		return
	var next: StringName = CLIPS[int(_frames / 240.0) % CLIPS.size()]
	_player.play(next)


func _fail(message: String) -> void:
	_failures.append(message)
	push_error("MAGE_SOFT: " + message)


func _finish() -> void:
	if _failures.is_empty():
		print("MAGE_SOFT OK")
	else:
		print("MAGE_SOFT FAILED: %s" % "; ".join(_failures))
	if DisplayServer.get_name() == "headless":
		get_tree().quit(0 if _failures.is_empty() else 1)


static func _first_of_class(root: Node, type_name: String) -> Node:
	var found := root.find_children("*", type_name, true, false)
	return found[0] if not found.is_empty() else null
