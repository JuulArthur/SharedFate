class_name Main3DPlaceholders
extends RefCounted

## Stand-ins for the WP5 overlay nodes (docs/3d-port-contracts.md, section 7).
##
## Each inner class implements exactly the API of the node it stands in for and
## draws at most a trivial ImmediateMesh line, so main_3d.gd runs before WP5
## lands. main_3d.gd instantiates them through one factory (`_create_overlay`);
## WP8 points that factory at the real RangeRing3D / PathPreview3D /
## CounterPrompt3D / OverheadBars3D and deletes this file.

const KIND_RANGE_RING: StringName = &"range_ring"
const KIND_PATH_PREVIEW: StringName = &"path_preview"
const KIND_COUNTER_PROMPT: StringName = &"counter_prompt"
const KIND_OVERHEAD_BARS: StringName = &"overhead_bars"

# Overlays sit just above the ground so they never z-fight with it.
const OVERLAY_Y := 0.02
const RING_SEGMENTS := 48
const DASH_COUNT := 24
const DASH_FILL := 0.55
const LABEL_HEIGHT_M := 0.4


static func create(kind: StringName) -> Node3D:
	match kind:
		KIND_RANGE_RING:
			return RangeRingStub.new()
		KIND_PATH_PREVIEW:
			return PathPreviewStub.new()
		KIND_COUNTER_PROMPT:
			return CounterPromptStub.new()
		KIND_OVERHEAD_BARS:
			return OverheadBarsStub.new()
	push_warning("Main3DPlaceholders: unknown overlay kind '%s'" % kind)
	return null


static func unlit_line_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.vertex_color_use_as_albedo = true
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.no_depth_test = true
	return material


## RangeRing3D stand-in: `show_ring(radius_m, color, use_dashes)` / `hide_ring()`.
## A line loop in local space at y = OVERLAY_Y; the coordinator moves the node
## to the actor's feet every frame, exactly as it moved the 2D RangeRing.
## (Named *Stub so it cannot hide the 2D global classes RangeRing and
## CounterPrompt, which share the project.)
class RangeRingStub extends MeshInstance3D:
	var _mesh := ImmediateMesh.new()

	func _init() -> void:
		name = "RangeRingPlaceholder"
		mesh = _mesh
		material_override = Main3DPlaceholders.unlit_line_material()
		visible = false

	func show_ring(radius_m: float, color: Color, use_dashes: bool = false) -> void:
		_mesh.clear_surfaces()
		if radius_m <= 0.0:
			visible = false
			return
		if use_dashes:
			_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
			var span := TAU / float(Main3DPlaceholders.DASH_COUNT)
			for i in range(Main3DPlaceholders.DASH_COUNT):
				var start := float(i) * span
				_add_arc(radius_m, start, start + span * Main3DPlaceholders.DASH_FILL, 3, color, true)
			_mesh.surface_end()
		else:
			_mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
			_add_arc(radius_m, 0.0, TAU, Main3DPlaceholders.RING_SEGMENTS, color, false)
			_mesh.surface_end()
		visible = true

	func hide_ring() -> void:
		visible = false

	func _add_arc(radius_m: float, from_angle: float, to_angle: float, segments: int,
			color: Color, as_line_pairs: bool) -> void:
		var previous := Vector3.ZERO
		for i in range(segments + 1):
			var angle := lerpf(from_angle, to_angle, float(i) / float(segments))
			var point := Vector3(cos(angle) * radius_m, Main3DPlaceholders.OVERLAY_Y, sin(angle) * radius_m)
			if as_line_pairs:
				if i > 0:
					_mesh.surface_set_color(color)
					_mesh.surface_add_vertex(previous)
					_mesh.surface_set_color(color)
					_mesh.surface_add_vertex(point)
				previous = point
			else:
				_mesh.surface_set_color(color)
				_mesh.surface_add_vertex(point)


## PathPreview3D stand-in: `show_path(points, used_m, remaining_m)` / `hide_path()`.
## A line strip along the trimmed path plus a Label3D with "used / remaining"
## at its end. Turns red when the whole budget is spent, as the 2D preview did.
class PathPreviewStub extends Node3D:
	var _mesh := ImmediateMesh.new()
	var _line := MeshInstance3D.new()
	var _label := Label3D.new()

	func _init() -> void:
		name = "PathPreviewPlaceholder"
		_line.mesh = _mesh
		_line.material_override = Main3DPlaceholders.unlit_line_material()
		add_child(_line)
		_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		_label.no_depth_test = true
		_label.pixel_size = 0.004
		_label.font_size = 40
		_label.outline_size = 8
		_label.modulate = Color(1.0, 0.95, 0.7, 0.95)
		add_child(_label)
		visible = false

	func show_path(points: Array[Vector3], used_m: float, remaining_m: float) -> void:
		_mesh.clear_surfaces()
		if points.size() < 2 or not is_inside_tree():
			visible = false
			return
		var over_budget := used_m >= remaining_m - 0.001
		var color := Color(1.0, 0.75, 0.75, 0.9) if over_budget else Color(1.0, 1.0, 1.0, 0.9)
		_mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP)
		for p in points:
			_mesh.surface_set_color(color)
			_mesh.surface_add_vertex(to_local(GroundMath.flatten(p, Main3DPlaceholders.OVERLAY_Y)))
		_mesh.surface_end()
		_label.text = "%.1fm / %.1fm" % [used_m, remaining_m]
		_label.position = to_local(GroundMath.flatten(points[points.size() - 1], Main3DPlaceholders.LABEL_HEIGHT_M))
		visible = true

	func hide_path() -> void:
		visible = false


## CounterPrompt3D stand-in: same phases as the 2D CounterPrompt, drawn as
## nothing. The enemy drives it; the coordinator only hands it out through
## `main_3d.acquire_counter_prompt`.
class CounterPromptStub extends Node3D:
	enum Phase { HIDDEN, WINDUP, STRIKE, RESULT }

	var phase: int = Phase.HIDDEN
	var hint_text := ""
	var hint_color := Color.WHITE
	var phase_duration := 0.0
	var last_result_perfect := false

	func _init() -> void:
		name = "CounterPromptPlaceholder"
		visible = false

	func set_hint(text: String, color: Color) -> void:
		hint_text = text
		hint_color = color

	func start_windup(duration: float) -> void:
		phase = Phase.WINDUP
		phase_duration = maxf(duration, 0.01)

	func start_strike(duration: float) -> void:
		phase = Phase.STRIKE
		phase_duration = maxf(duration, 0.01)

	func show_result(perfect: bool) -> void:
		phase = Phase.RESULT
		last_result_perfect = perfect

	func hide_prompt() -> void:
		phase = Phase.HIDDEN


## OverheadBars3D stand-in: `set_ratio(health_ratio)` / `set_visible_bars(v)`.
class OverheadBarsStub extends Node3D:
	var ratio := 1.0
	var bars_visible := true

	func _init() -> void:
		name = "OverheadBarsPlaceholder"

	func set_ratio(health_ratio: float) -> void:
		ratio = clampf(health_ratio, 0.0, 1.0)

	func set_visible_bars(v: bool) -> void:
		bars_visible = v
		visible = v
