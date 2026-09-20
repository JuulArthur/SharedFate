class_name PathPreview3D
extends Node3D

## 3D twin of the turn-movement path preview that `main.gd` builds from two
## `Line2D`s and a label (`_setup_path_preview` / `_update_path_preview`).
##
## The line is a thin quad strip just above the floor, in two colours: white for
## the part the remaining movement pays for and red for the part beyond it, which
## is the same meaning the 2D preview carries by turning the whole line red when
## the destination is out of budget. The distance label keeps the 2D wording,
## "used / remaining" in metres, and is drawn on a CanvasLayer at the projection
## of the last path point.
##
## Parent it anywhere in the level (the coordinator owns it); the points passed to
## `show_path` are global. Contract: docs/3d-port-contracts.md, section 7.

## Under the CombatFx popups (4) so a damage number is never hidden by the label.
const CANVAS_LAYER := 3
## Matches main.gd CAMERA_ZOOM, so the label reads at its 2D size. See
## counter_prompt_3d.gd for the same reasoning.
const SCREEN_SCALE := 3.35

const PATH_Y := 0.03
const LINE_WIDTH_M := 0.09
const COLOR_IN_BUDGET := Color(1.0, 1.0, 1.0, 0.9)
const COLOR_OVER_BUDGET := Color(1.0, 0.75, 0.75, 0.9)
const LABEL_FONT_SIZE := 11
const LABEL_OFFSET := Vector2(6.0, -14.0) * SCREEN_SCALE

var _mesh: ImmediateMesh
var _mesh_instance: MeshInstance3D
var _material_in_budget: StandardMaterial3D
var _material_over_budget: StandardMaterial3D
var _layer: CanvasLayer
var _label: Label
var _label_anchor := Vector3.ZERO
var _shown := false


func _ready() -> void:
	_material_in_budget = _make_material(COLOR_IN_BUDGET)
	_material_over_budget = _make_material(COLOR_OVER_BUDGET)

	_mesh = ImmediateMesh.new()
	_mesh_instance = MeshInstance3D.new()
	_mesh_instance.name = "PathMesh"
	_mesh_instance.mesh = _mesh
	_mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_mesh_instance)

	_layer = CanvasLayer.new()
	_layer.name = "PathPreviewLayer"
	_layer.layer = CANVAS_LAYER
	add_child(_layer)

	_label = Label.new()
	_label.name = "PathPreviewLabel"
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.visible = false
	_label.add_theme_font_size_override("font_size", int(round(float(LABEL_FONT_SIZE) * SCREEN_SCALE)))
	_label.add_theme_color_override("font_color", Color(1.0, 0.95, 0.7, 0.95))
	_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	_label.add_theme_constant_override("shadow_offset_x", 2)
	_label.add_theme_constant_override("shadow_offset_y", 2)
	_layer.add_child(_label)

	visible = _shown


func _process(_delta: float) -> void:
	if not _shown:
		return
	_update_label_position()


func show_path(points: Array[Vector3], used_m: float, remaining_m: float) -> void:
	if points.size() < 2:
		hide_path()
		return
	_shown = true
	visible = true
	_label_anchor = points[points.size() - 1]

	var affordable := GroundMath.trim_path(points, maxf(remaining_m, 0.0))
	var beyond := _suffix_after(points, affordable)

	if _mesh != null:
		_mesh.clear_surfaces()
		_add_strip(affordable, _material_in_budget)
		_add_strip(beyond, _material_over_budget)

	if _label != null:
		_label.text = "%.1fm / %.1fm" % [used_m, remaining_m]
		_label.visible = true
		_update_label_position()


func hide_path() -> void:
	_shown = false
	visible = false
	if _mesh != null:
		_mesh.clear_surfaces()
	if _label != null:
		_label.visible = false


func _make_material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	material.no_depth_test = true
	material.albedo_color = color
	return material


## The rest of `points` once `affordable` has been walked off it, starting at the
## exact point where the budget ran out so the two colours meet without a gap.
func _suffix_after(points: Array[Vector3], affordable: Array[Vector3]) -> Array[Vector3]:
	var rest: Array[Vector3] = []
	if affordable.is_empty():
		return points.duplicate()
	# trim_path either ends on one of the original points or on an interpolated
	# one between it and the next; only the first case consumes that point.
	var last_index := affordable.size() - 1
	var split := affordable[last_index]
	var start_index := last_index
	if last_index < points.size() and split.distance_squared_to(points[last_index]) <= 0.000001:
		start_index = last_index + 1
	rest.append(split)
	for i in range(start_index, points.size()):
		rest.append(points[i])
	if rest.size() < 2:
		rest.clear()
	return rest


## A flat quad strip of constant width along the polyline, at PATH_Y above the
## ground. Points are global; the strip is stored in local space so it follows
## this node.
func _add_strip(points: Array[Vector3], material: StandardMaterial3D) -> void:
	if points.size() < 2 or _mesh == null:
		return
	var half_width := LINE_WIDTH_M * 0.5
	_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP, material)
	for i in range(points.size()):
		var direction := _direction_at(points, i)
		var side := Vector3(-direction.z, 0.0, direction.x) * half_width
		var center := Vector3(points[i].x, PATH_Y, points[i].z)
		_mesh.surface_set_normal(Vector3.UP)
		_mesh.surface_add_vertex(to_local(center - side))
		_mesh.surface_set_normal(Vector3.UP)
		_mesh.surface_add_vertex(to_local(center + side))
	_mesh.surface_end()


## Average of the segment directions meeting at `index`, so corners stay joined.
func _direction_at(points: Array[Vector3], index: int) -> Vector3:
	var incoming := Vector3.ZERO
	var outgoing := Vector3.ZERO
	if index > 0:
		incoming = GroundMath.ground_direction(points[index - 1], points[index])
	if index < points.size() - 1:
		outgoing = GroundMath.ground_direction(points[index], points[index + 1])
	var direction := incoming + outgoing
	if direction.length_squared() <= 0.000001:
		if outgoing != Vector3.ZERO:
			return outgoing
		if incoming != Vector3.ZERO:
			return incoming
		return Vector3.FORWARD
	return direction.normalized()


func _update_label_position() -> void:
	if _label == null or not is_inside_tree():
		return
	var viewport := get_viewport()
	if viewport == null:
		return
	var camera := viewport.get_camera_3d()
	if camera == null:
		return
	if camera.is_position_behind(_label_anchor):
		_label.visible = false
		return
	_label.visible = _shown
	_label.position = camera.unproject_position(_label_anchor) + LABEL_OFFSET
