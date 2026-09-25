extends Node3D

## WP1 asset gallery.
##
## Loads every `res://assets/3d/models/*.glb`, lines the models up on the ground
## 3 m apart and prints what WP3b and WP7 need: the merged AABB of the mesh
## children, the triangle count, whether the `HandPoint` and `OverheadAnchor`
## nodes survived the glTF round trip, and - for the characters - whether the
## model faces Godot's -Z.
##
## A character is any model with a `*_Visor` material: the centroid of that
## material's faces is the front of the head, so comparing it with the centre of
## the merged AABB tells us which way the model looks. Every character must face
## -Z, stand on y = 0 and be between 1.7 m and 2.1 m tall.
##
## Run: godot --headless --path . res://scenes/3d/tests/asset_gallery.tscn --quit-after 60

const MODEL_DIR := "res://assets/3d/models"
const SPACING := 3.0
const MIN_HEIGHT := 1.7
const MAX_HEIGHT := 2.1
const GROUND_TOLERANCE := 0.02
const VISOR_SUFFIX := "_Visor"


func _ready() -> void:
	var paths: PackedStringArray = _model_paths()
	var failures: PackedStringArray = PackedStringArray()
	if paths.is_empty():
		failures.append("%s: no .glb models found" % MODEL_DIR)
	var x := -0.5 * SPACING * float(maxi(paths.size() - 1, 0))
	for path in paths:
		var packed: PackedScene = load(path) as PackedScene
		if packed == null:
			failures.append("%s: load() returned no PackedScene" % path)
			continue
		var model: Node3D = packed.instantiate() as Node3D
		if model == null:
			failures.append("%s: root is not a Node3D" % path)
			continue
		var root_name := String(model.name)
		model.name = path.get_file().get_basename()
		if root_name != String(model.name):
			print("ASSET %-12s glb root node name: %s" % [model.name, root_name])
		add_child(model)
		model.position = Vector3(x, 0.0, 0.0)
		x += SPACING
		failures.append_array(_describe(model))
	_add_rig(paths.size())
	if failures.is_empty():
		print("ASSET_GALLERY OK")
	else:
		for problem in failures:
			print("ASSET_GALLERY FAIL ", problem)


func _model_paths() -> PackedStringArray:
	var found := PackedStringArray()
	var dir := DirAccess.open(MODEL_DIR)
	if dir == null:
		push_error("asset_gallery: cannot open %s" % MODEL_DIR)
		return found
	for entry in dir.get_files():
		var file_name := entry
		if file_name.ends_with(".import"):
			file_name = file_name.trim_suffix(".import")
		if file_name.ends_with(".glb") and not found.has(file_name):
			found.append(file_name)
	found.sort()
	var paths := PackedStringArray()
	for file_name in found:
		paths.append(MODEL_DIR.path_join(file_name))
	return paths


func _describe(model: Node3D) -> PackedStringArray:
	var problems := PackedStringArray()
	var meshes: Array[MeshInstance3D] = []
	_collect_meshes(model, meshes)

	var bounds := AABB()
	var has_bounds := false
	var triangles := 0
	var to_model := model.global_transform.affine_inverse()
	for mesh_instance in meshes:
		var mesh := mesh_instance.mesh
		if mesh == null:
			continue
		var box: AABB = (to_model * mesh_instance.global_transform) * mesh_instance.get_aabb()
		bounds = box if not has_bounds else bounds.merge(box)
		has_bounds = true
		triangles += _triangle_count(mesh)

	var hand := _anchor(model, "HandPoint")
	var overhead := _anchor(model, "OverheadAnchor")
	var has_hand := not hand.is_empty()
	var has_overhead := not overhead.is_empty()
	var centroid: Variant = _visor_centroid(model, meshes, to_model)
	var is_character := centroid != null
	var faces_back := false
	if is_character:
		var visor: Vector3 = centroid
		faces_back = visor.z < bounds.get_center().z

	var mesh_names := PackedStringArray()
	for mesh_instance in meshes:
		mesh_names.append(String(mesh_instance.name))
	print("ASSET %-12s size=(%.3f, %.3f, %.3f) floor_y=%.3f tris=%d HandPoint=%s%s OverheadAnchor=%s%s faces -Z: %s meshes=[%s] bodies=%d"
		% [model.name, bounds.size.x, bounds.size.y, bounds.size.z, bounds.position.y,
			triangles, str(has_hand), hand, str(has_overhead), overhead,
			str(faces_back) if is_character else "n/a",
			", ".join(mesh_names), _count_bodies(model)])
	problems.append_array(_describe_rig(model, is_character))

	if not has_bounds:
		problems.append("%s: no MeshInstance3D children" % model.name)
		return problems
	if is_character:
		if not faces_back:
			problems.append("%s: does not face -Z (visor z=%.3f, centre z=%.3f)"
				% [model.name, (centroid as Vector3).z, bounds.get_center().z])
		if absf(bounds.position.y) > GROUND_TOLERANCE:
			problems.append("%s: lowest point y=%.3f, expected within %.2f of 0"
				% [model.name, bounds.position.y, GROUND_TOLERANCE])
		if bounds.size.y < MIN_HEIGHT or bounds.size.y > MAX_HEIGHT:
			problems.append("%s: height %.3f m outside %.1f-%.1f m"
				% [model.name, bounds.size.y, MIN_HEIGHT, MAX_HEIGHT])
		if not has_hand:
			problems.append("%s: missing HandPoint" % model.name)
		if not has_overhead:
			problems.append("%s: missing OverheadAnchor" % model.name)
	return problems


## WP11: the rig as the glTF importer laid it out. Prints the skeleton and its
## bones, the AnimationPlayer and its clips, and the node path of every empty
## and weapon (bone-parented objects land under a BoneAttachment3D). A
## character must carry a skeleton, an AnimationPlayer with looping `idle` and
## `walk`, and a HandPoint that rides the right forearm.
func _describe_rig(model: Node3D, is_character: bool) -> PackedStringArray:
	var problems := PackedStringArray()
	var skeletons := model.find_children("*", "Skeleton3D", true, false)
	var players := model.find_children("*", "AnimationPlayer", true, false)
	if skeletons.is_empty() and players.is_empty():
		if is_character:
			problems.append("%s: no Skeleton3D and no AnimationPlayer" % model.name)
		return problems

	var skeleton: Skeleton3D = skeletons[0] as Skeleton3D if not skeletons.is_empty() else null
	var bone_names := PackedStringArray()
	if skeleton != null:
		for bone in range(skeleton.get_bone_count()):
			bone_names.append(skeleton.get_bone_name(bone))
	var clips := PackedStringArray()
	var player: AnimationPlayer = players[0] as AnimationPlayer if not players.is_empty() else null
	if player != null:
		for anim_name in player.get_animation_list():
			var anim := player.get_animation(anim_name)
			clips.append("%s %.2f s loop=%d tracks=%d" % [anim_name, anim.length, anim.loop_mode, anim.get_track_count()])
	print("RIG   %-12s skeleton=%s bones=%d [%s] player=%s clips=[%s]"
		% [model.name, model.get_path_to(skeleton) if skeleton != null else "none",
			bone_names.size(), ", ".join(bone_names),
			model.get_path_to(player) if player != null else "none", "; ".join(clips)])
	for node_name in ["HandPoint", "OverheadAnchor", "Sword", "Dagger_R", "Dagger_L", "Staff"]:
		var node := model.find_child(node_name, true, false) as Node3D
		if node == null:
			continue
		var attachment := node.get_parent() as BoneAttachment3D
		print("RIG   %-12s %-14s at %s%s" % [model.name, node_name, model.get_path_to(node),
			(" (bone %s)" % attachment.bone_name) if attachment != null else ""])

	if not is_character:
		return problems
	if skeleton == null or skeleton.get_bone_count() < 8:
		problems.append("%s: expected a Skeleton3D with at least 8 bones" % model.name)
	if player == null:
		problems.append("%s: no AnimationPlayer" % model.name)
	else:
		for clip in [&"idle", &"walk"]:
			if not player.has_animation(clip):
				problems.append("%s: no '%s' animation" % [model.name, clip])
			elif player.get_animation(clip).loop_mode == Animation.LOOP_NONE:
				problems.append("%s: '%s' does not loop (import settings)" % [model.name, clip])
	var hand := model.find_child("HandPoint", true, false) as Node3D
	var hand_attachment: BoneAttachment3D = hand.get_parent() as BoneAttachment3D if hand != null else null
	if hand_attachment == null or hand_attachment.bone_name != "LowerArm_R":
		problems.append("%s: HandPoint does not ride the LowerArm_R bone" % model.name)
	return problems


func _anchor(model: Node3D, anchor_name: String) -> String:
	## " (x, y, z)" in the model's own space, or "" when the node is missing.
	var node := model.find_child(anchor_name, true, false) as Node3D
	if node == null:
		return ""
	var local := model.global_transform.affine_inverse() * node.global_position
	return " (%.3f, %.3f, %.3f)" % [local.x, local.y, local.z]


func _count_bodies(node: Node) -> int:
	var total := 1 if node is StaticBody3D else 0
	for child in node.get_children():
		total += _count_bodies(child)
	return total


func _collect_meshes(node: Node, out: Array[MeshInstance3D]) -> void:
	if node is MeshInstance3D:
		out.append(node as MeshInstance3D)
	for child in node.get_children():
		_collect_meshes(child, out)


func _triangle_count(mesh: Mesh) -> int:
	var total := 0
	for surface in mesh.get_surface_count():
		var arrays: Array = mesh.surface_get_arrays(surface)
		if arrays.is_empty():
			continue
		var index_data: Variant = arrays[Mesh.ARRAY_INDEX]
		if index_data is PackedInt32Array and (index_data as PackedInt32Array).size() > 0:
			total += (index_data as PackedInt32Array).size() / 3
			continue
		var vertex_data: Variant = arrays[Mesh.ARRAY_VERTEX]
		if vertex_data is PackedVector3Array:
			total += (vertex_data as PackedVector3Array).size() / 3
	return total


func _visor_centroid(model: Node3D, meshes: Array[MeshInstance3D],
		to_model: Transform3D) -> Variant:
	var sum := Vector3.ZERO
	var count := 0
	for mesh_instance in meshes:
		var mesh := mesh_instance.mesh
		if mesh == null:
			continue
		var to_local := to_model * mesh_instance.global_transform
		for surface in mesh.get_surface_count():
			if not _surface_tag(mesh_instance, mesh, surface).ends_with(VISOR_SUFFIX):
				continue
			var arrays: Array = mesh.surface_get_arrays(surface)
			if arrays.is_empty():
				continue
			var vertex_data: Variant = arrays[Mesh.ARRAY_VERTEX]
			if not (vertex_data is PackedVector3Array):
				continue
			for vertex in (vertex_data as PackedVector3Array):
				sum += to_local * vertex
				count += 1
	if count == 0:
		return null
	return sum / float(count)


func _surface_tag(mesh_instance: MeshInstance3D, mesh: Mesh, surface: int) -> String:
	var material: Material = mesh_instance.get_active_material(surface)
	if material != null and not material.resource_name.is_empty():
		return material.resource_name
	var array_mesh := mesh as ArrayMesh
	if array_mesh != null:
		return array_mesh.surface_get_name(surface)
	return ""


func _add_rig(count: int) -> void:
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	add_child(sun)
	sun.rotation_degrees = Vector3(-50.0, -35.0, 0.0)
	sun.light_energy = 1.3
	sun.shadow_enabled = true

	var camera := Camera3D.new()
	camera.name = "Camera3D"
	add_child(camera)
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = maxf(SPACING * float(maxi(count, 1)), 8.0)
	camera.position = Vector3(0.0, 2.0, SPACING * float(maxi(count, 2)))
	camera.look_at(Vector3(0.0, 1.0, 0.0), Vector3.UP)
	camera.current = true
