class_name CounterPrompt
extends Node2D

# Timing cue for the counter mechanic. An enemy shows one of these over its
# body while it attacks: a large ring shrinks onto a fixed target ring during
# the wind-up, and the moment they meet is the strike window - press the
# counter key then. The ring turns gold for the window, then flashes green
# (perfect) or red (early / missed) before hiding.
#
# Purely visual: enemy.gd drives the phases, player.gd owns the input.

const TARGET_RADIUS := 13.0
const START_RADIUS := 30.0
const RING_WIDTH := 2.0
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
var _key_label: Label


func _ready() -> void:
	visible = false
	_key_label = Label.new()
	_key_label.text = "F"
	_key_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_key_label.add_theme_font_size_override("font_size", 9)
	_key_label.add_theme_color_override("font_color", Color(1.0, 0.95, 0.8, 1.0))
	_key_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	_key_label.add_theme_constant_override("shadow_offset_x", 1)
	_key_label.add_theme_constant_override("shadow_offset_y", 1)
	_key_label.position = Vector2(-5.0, -TARGET_RADIUS - 16.0)
	add_child(_key_label)


func _process(delta: float) -> void:
	if _phase == Phase.HIDDEN:
		return
	_phase_time += delta
	if _phase == Phase.RESULT and _phase_time >= _phase_duration:
		hide_prompt()
		return
	queue_redraw()


func start_windup(duration: float) -> void:
	_phase = Phase.WINDUP
	_phase_duration = maxf(duration, 0.01)
	_phase_time = 0.0
	visible = true
	_key_label.visible = true
	queue_redraw()


func start_strike(duration: float) -> void:
	_phase = Phase.STRIKE
	_phase_duration = maxf(duration, 0.01)
	_phase_time = 0.0
	visible = true
	queue_redraw()


func show_result(perfect: bool) -> void:
	_phase = Phase.RESULT
	_phase_duration = RESULT_SECONDS
	_phase_time = 0.0
	_result_color = COLOR_PERFECT if perfect else COLOR_FAIL
	_key_label.visible = false
	visible = true
	queue_redraw()


func hide_prompt() -> void:
	_phase = Phase.HIDDEN
	visible = false
	queue_redraw()


func _draw() -> void:
	match _phase:
		Phase.WINDUP:
			var t := clampf(_phase_time / _phase_duration, 0.0, 1.0)
			var radius := lerpf(START_RADIUS, TARGET_RADIUS, t)
			draw_arc(Vector2.ZERO, TARGET_RADIUS, 0.0, TAU, 32, COLOR_TARGET, RING_WIDTH, true)
			draw_arc(Vector2.ZERO, radius, 0.0, TAU, 40, COLOR_WINDUP, RING_WIDTH, true)
		Phase.STRIKE:
			var pulse := 1.0 + 0.12 * sin(_phase_time * 40.0)
			draw_arc(Vector2.ZERO, TARGET_RADIUS * pulse, 0.0, TAU, 32, COLOR_STRIKE, RING_WIDTH + 1.5, true)
		Phase.RESULT:
			var t := clampf(_phase_time / _phase_duration, 0.0, 1.0)
			var color := _result_color
			color.a = 1.0 - t
			draw_arc(Vector2.ZERO, TARGET_RADIUS + 10.0 * t, 0.0, TAU, 32, color, RING_WIDTH + 1.0, true)
