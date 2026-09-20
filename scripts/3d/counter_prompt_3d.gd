class_name CounterPrompt3D
extends Node3D

## 3D twin of `CounterPrompt` (scripts/counter_prompt.gd). Timing cue for the
## counter mechanic: a large ring shrinks onto a fixed target ring during the
## wind-up, the moment they meet is the strike window, then the ring flashes green
## (perfect) or red (early / missed) before hiding.
##
## The drawing is the same as 2D but happens on a Control on a CanvasLayer, which
## is placed every frame at the projection of this node. Parent it to the enemy's
## `OverheadAnchor`; it needs no other wiring. Phases, durations and colours are
## the 2D ones. Purely visual: the enemy drives the phases, the player owns the
## input. Contract: docs/3d-port-contracts.md, section 7.

## Above the world, together with the turn HUD, as section 7 asks.
const CANVAS_LAYER := 5
## The 2D prompt is a Node2D drawn through a camera at zoom 3.35 (main.gd
## CAMERA_ZOOM), so every 2D pixel size is multiplied by that to read the same on
## screen here.
const SCREEN_SCALE := 3.35

const TARGET_RADIUS := 13.0 * SCREEN_SCALE
const START_RADIUS := 30.0 * SCREEN_SCALE
const RING_WIDTH := 2.0 * SCREEN_SCALE
const RESULT_SECONDS := 0.3

const COLOR_WINDUP := Color(1.0, 0.86, 0.55, 0.9)
const COLOR_TARGET := Color(1.0, 1.0, 1.0, 0.55)
const COLOR_STRIKE := Color(1.0, 0.84, 0.25, 1.0)
const COLOR_PERFECT := Color(0.45, 1.0, 0.55, 1.0)
const COLOR_FAIL := Color(1.0, 0.35, 0.35, 1.0)

enum Phase { HIDDEN, WINDUP, STRIKE, RESULT }

var _phase: int = Phase.HIDDEN
var _phase_duration := 0.0
var _phase_time := 0.0
var _result_color := COLOR_FAIL
var _accent := COLOR_TARGET

var _layer: CanvasLayer
var _control: Control
var _key_label: Label
var _hint_label: Label
var _pending_hint := ""
var _pending_hint_color := COLOR_TARGET


func _ready() -> void:
	visible = false
	_layer = CanvasLayer.new()
	_layer.name = "CounterPromptLayer"
	_layer.layer = CANVAS_LAYER
	add_child(_layer)

	_control = Control.new()
	_control.name = "CounterPromptControl"
	_control.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_control.visible = false
	_control.draw.connect(_on_control_draw)
	_layer.add_child(_control)

	_key_label = _make_label(9.0 * SCREEN_SCALE, Color(1.0, 0.95, 0.8, 1.0))
	_key_label.text = "F"
	_key_label.position = Vector2(-20.0 * SCREEN_SCALE, -TARGET_RADIUS - 16.0 * SCREEN_SCALE)
	_control.add_child(_key_label)

	# The reaction the press will perform, written under the ring.
	_hint_label = _make_label(8.0 * SCREEN_SCALE, _accent)
	_hint_label.position = Vector2(-20.0 * SCREEN_SCALE, TARGET_RADIUS + 3.0 * SCREEN_SCALE)
	_control.add_child(_hint_label)

	if not _pending_hint.is_empty():
		set_hint(_pending_hint, _pending_hint_color)


func _make_label(font_size: float, font_color: Color) -> Label:
	var label := Label.new()
	label.text = ""
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.custom_minimum_size = Vector2(40.0 * SCREEN_SCALE, 0.0)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override("font_size", int(round(font_size)))
	label.add_theme_color_override("font_color", font_color)
	label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	label.add_theme_constant_override("shadow_offset_x", 2)
	label.add_theme_constant_override("shadow_offset_y", 2)
	return label


## Names the reaction the active soul will perform and tints the target ring to
## match. Call before `start_windup`.
func set_hint(text: String, color: Color) -> void:
	_accent = Color(color.r, color.g, color.b, 0.8)
	_pending_hint = text
	_pending_hint_color = color
	if _hint_label != null:
		_hint_label.text = text
		_hint_label.add_theme_color_override("font_color", Color(color.r, color.g, color.b, 1.0))
	_queue_redraw()


func _process(delta: float) -> void:
	if _phase == Phase.HIDDEN:
		return
	_phase_time += delta
	if _phase == Phase.RESULT and _phase_time >= _phase_duration:
		hide_prompt()
		return
	_update_screen_position()
	_queue_redraw()


func start_windup(duration: float) -> void:
	_phase = Phase.WINDUP
	_phase_duration = maxf(duration, 0.01)
	_phase_time = 0.0
	visible = true
	if _key_label != null:
		_key_label.visible = true
	if _hint_label != null:
		_hint_label.visible = true
	_update_screen_position()
	_queue_redraw()


func start_strike(duration: float) -> void:
	_phase = Phase.STRIKE
	_phase_duration = maxf(duration, 0.01)
	_phase_time = 0.0
	visible = true
	_update_screen_position()
	_queue_redraw()


func show_result(perfect: bool) -> void:
	_phase = Phase.RESULT
	_phase_duration = RESULT_SECONDS
	_phase_time = 0.0
	_result_color = COLOR_PERFECT if perfect else COLOR_FAIL
	if _key_label != null:
		_key_label.visible = false
	if _hint_label != null:
		_hint_label.visible = false
	visible = true
	_update_screen_position()
	_queue_redraw()


func hide_prompt() -> void:
	_phase = Phase.HIDDEN
	visible = false
	if _control != null:
		_control.visible = false
	_queue_redraw()


## Places the Control at the projection of this node. Without a current Camera3D
## (a scene that has not finished setting one up) the frame is skipped.
func _update_screen_position() -> void:
	if _control == null or not is_inside_tree():
		return
	var viewport := get_viewport()
	if viewport == null:
		return
	var camera := viewport.get_camera_3d()
	if camera == null:
		return
	var origin := global_position
	if camera.is_position_behind(origin):
		_control.visible = false
		return
	_control.visible = visible
	_control.position = camera.unproject_position(origin)


func _queue_redraw() -> void:
	if _control != null:
		_control.queue_redraw()


func _on_control_draw() -> void:
	match _phase:
		Phase.WINDUP:
			var t := clampf(_phase_time / _phase_duration, 0.0, 1.0)
			var radius := lerpf(START_RADIUS, TARGET_RADIUS, t)
			_control.draw_arc(Vector2.ZERO, TARGET_RADIUS, 0.0, TAU, 32, _accent, RING_WIDTH, true)
			_control.draw_arc(Vector2.ZERO, radius, 0.0, TAU, 40, COLOR_WINDUP, RING_WIDTH, true)
		Phase.STRIKE:
			var pulse := 1.0 + 0.12 * sin(_phase_time * 40.0)
			_control.draw_arc(Vector2.ZERO, TARGET_RADIUS * pulse, 0.0, TAU, 32, COLOR_STRIKE,
				RING_WIDTH + 1.5 * SCREEN_SCALE, true)
		Phase.RESULT:
			var t := clampf(_phase_time / _phase_duration, 0.0, 1.0)
			var color := _result_color
			color.a = 1.0 - t
			_control.draw_arc(Vector2.ZERO, TARGET_RADIUS + 10.0 * SCREEN_SCALE * t, 0.0, TAU, 32,
				color, RING_WIDTH + 1.0 * SCREEN_SCALE, true)
