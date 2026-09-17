class_name RangeRing
extends Node2D

# World-space ring showing how far an attack reaches. Combat range checks are
# plain `distance_to` circles, so the ring is a true circle rather than an
# isometric ellipse - what you see is exactly what the rules test.

const SEGMENTS := 64
const DASH_SEGMENTS := 6

var radius := 40.0
var color := Color(1.0, 1.0, 1.0, 0.35)
var line_width := 1.5
var dashed := false
var _spin := 0.0


func _process(delta: float) -> void:
	if not visible or not dashed:
		return
	_spin += delta * 0.6
	queue_redraw()


func show_ring(new_radius: float, new_color: Color, use_dashes: bool = false) -> void:
	radius = new_radius
	color = new_color
	dashed = use_dashes
	visible = true
	queue_redraw()


func hide_ring() -> void:
	visible = false


func _draw() -> void:
	if radius <= 0.0:
		return
	if not dashed:
		draw_arc(Vector2.ZERO, radius, 0.0, TAU, SEGMENTS, color, line_width, true)
		return
	# Slowly turning dashes so a large ring still reads as "active" while the
	# player picks a target.
	var dash_count := 24
	var dash_span := TAU / float(dash_count)
	for i in range(dash_count):
		var start := _spin + float(i) * dash_span
		draw_arc(Vector2.ZERO, radius, start, start + dash_span * 0.55, DASH_SEGMENTS, color, line_width, true)
