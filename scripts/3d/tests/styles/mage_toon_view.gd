extends Node3D

## Style study view (docs/style-study/mage_toon.md): the toon mage glb on a
## ground plane under the arena's sun, seen through the game's camera rig, with
## ToonMaterials3D applied. Prints the imported tree, the rig, the clips, the
## triangle count and the material swap, plays `walk` for WALK_FRAMES frames and
## prints `MAGE_TOON OK` when all three clips exist and every surface is toon
## shaded with an outline. Then it holds `idle` for the screenshot
## (scripts/3d/tests/styles/mage_toon_capture.gd).
##
##     godot --headless --path . res://scenes/3d/tests/styles/mage_toon_view.tscn --quit-after 120

## Loaded at run time: a preloaded glb whose materials are then replaced makes
## the headless (dummy) renderer print "Parameter material is null" errors.
const MODEL_PATH := "res://assets/3d/models/styles/mage_toon.glb"
const CAMERA_RIG_SCENE: PackedScene = preload("res://scenes/3d/camera_rig_3d.tscn")
const REQUIRED_CLIPS: Array[StringName] = [&"idle", &"walk", &"cast"]
const LOOPING_CLIPS: Array[StringName] = [&"idle", &"walk"]
const WALK_FRAMES := 60
## Orthographic height in metres: the 1.9 m mage fills about a quarter of the
## frame (the arena plays at 14 m).
@export var zoom_size_m := 8.0
## Model yaw: the glb faces -Z; 200 degrees turns it three-quarter toward the
## camera, which looks from +X/+Z.
@export var model_yaw_degrees := 200.0

var _model: Node3D = null
var _player: AnimationPlayer = null
var _skeleton: Skeleton3D = null
var _stats := {}
var _frames := 0
var _checked := false


func _ready() -> void:
	var holder := Node3D.new()
	holder.name = "MageHolder"
	add_child(holder)
	_model = (load(MODEL_PATH) as PackedScene).instantiate() as Node3D
	_model.rotation_degrees.y = model_yaw_degrees
	holder.add_child(_model)
	_stats = ToonMaterials3D.apply(_model)

	var rig := CAMERA_RIG_SCENE.instantiate() as CameraRig3D
	add_child(rig)
	rig.set_zoom_size(zoom_size_m)
	rig.set_follow_target(holder)
	rig.snap_to_target()
	var camera := rig.get_camera()
	if camera != null:
		camera.current = true

	_skeleton = _first_of_class(_model, "Skeleton3D") as Skeleton3D
	_player = _first_of_class(_model, "AnimationPlayer") as AnimationPlayer
	if _player != null:
		for clip in LOOPING_CLIPS:
			if _player.has_animation(clip):
				_player.get_animation(clip).loop_mode = Animation.LOOP_LINEAR
		if _player.has_animation(&"walk"):
			_player.play(&"walk")
	_print_summary()


func _process(_delta: float) -> void:
	_frames += 1
	if _frames == WALK_FRAMES and not _checked:
		_checked = true
		_check()
		if _player != null and _player.has_animation(&"idle"):
			_player.play(&"idle", 0.0)
			_player.seek(0.0, true)


func _print_summary() -> void:
	print("MAGE_TOON tree:")
	_print_tree(_model, 1)
	var bones := _skeleton.get_bone_count() if _skeleton != null else 0
	print("MAGE_TOON bones=%d %s" % [bones, _bone_names()])
	if _player != null:
		for clip in _player.get_animation_list():
			var anim := _player.get_animation(clip)
			print("MAGE_TOON clip %s %.2f s loop=%d tracks=%d" % [clip, anim.length, anim.loop_mode, anim.get_track_count()])
	print("MAGE_TOON triangles=%d" % _triangle_count())
	print("MAGE_TOON materials meshes=%d surfaces=%d toon=%d outlined=%d distinct=%d" % [
		int(_stats.get("meshes", 0)), int(_stats.get("surfaces", 0)), int(_stats.get("toon", 0)),
		int(_stats.get("outlined", 0)), int(_stats.get("materials", 0))])


func _check() -> void:
	var failures: PackedStringArray = []
	if _player == null:
		failures.append("no AnimationPlayer")
	else:
		for clip in REQUIRED_CLIPS:
			if not _player.has_animation(clip):
				failures.append("no '%s' clip" % clip)
		if _player.current_animation != "walk" or not _player.is_playing():
			failures.append("walk is not playing after %d frames" % WALK_FRAMES)
	if _skeleton == null:
		failures.append("no Skeleton3D")
	var surfaces := 0
	for mesh_instance in _meshes():
		if mesh_instance.mesh == null:
			continue
		for surface in range(mesh_instance.mesh.get_surface_count()):
			surfaces += 1
			if not ToonMaterials3D.is_toon_surface(mesh_instance, surface):
				failures.append("%s surface %d is not toon" % [mesh_instance.name, surface])
			elif not ToonMaterials3D.has_outline(mesh_instance, surface):
				failures.append("%s surface %d has no outline" % [mesh_instance.name, surface])
	if surfaces == 0:
		failures.append("no surfaces")
	for node_name in ["Mage_Body", "Staff", "HandPoint", "OverheadAnchor"]:
		if _model.find_child(node_name, true, false) == null:
			failures.append("no %s" % node_name)
	var hand := _model.find_child("HandPoint", true, false)
	if hand != null and String(hand.get_parent().name) != "LowerArm_R":
		failures.append("HandPoint is under %s, not LowerArm_R" % hand.get_parent().name)
	if failures.is_empty():
		print("MAGE_TOON walk played %d frames, position %.2f s" % [WALK_FRAMES, _player.current_animation_position])
		print("MAGE_TOON OK")
	else:
		for failure in failures:
			push_error("MAGE_TOON FAIL: %s" % failure)
		print("MAGE_TOON FAIL (%d)" % failures.size())


func _print_tree(node: Node, depth: int) -> void:
	if depth > 6:
		return
	var extra := ""
	var mesh_instance := node as MeshInstance3D
	if mesh_instance != null and mesh_instance.mesh != null:
		extra = " surfaces=%d" % mesh_instance.mesh.get_surface_count()
	var attachment := node as BoneAttachment3D
	if attachment != null:
		extra = " bone=%s" % attachment.bone_name
	print("%s%s (%s)%s" % ["  ".repeat(depth), node.name, node.get_class(), extra])
	for child in node.get_children():
		_print_tree(child, depth + 1)


func _bone_names() -> PackedStringArray:
	var names: PackedStringArray = []
	if _skeleton != null:
		for i in range(_skeleton.get_bone_count()):
			names.append(_skeleton.get_bone_name(i))
	return names


func _triangle_count() -> int:
	var total := 0
	for mesh_instance in _meshes():
		var mesh := mesh_instance.mesh
		if mesh == null:
			continue
		for surface in range(mesh.get_surface_count()):
			var arrays := mesh.surface_get_arrays(surface)
			var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			if indices.is_empty():
				var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
				total += floori(positions.size() / 3.0)
			else:
				total += floori(indices.size() / 3.0)
	return total


func _meshes() -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	for node in _model.find_children("*", "MeshInstance3D", true, false):
		out.append(node as MeshInstance3D)
	return out


static func _first_of_class(root: Node, type_name: String) -> Node:
	var found := root.find_children("*", type_name, true, false)
	return found[0] if not found.is_empty() else null
