class_name EnemyStatusLine3D
extends Node3D

## The short status line under an enemy's health bar (`STUN 1  POISON 2`,
## docs/gameplay-expansion.md section 2). Built like OverheadBars3D: parent it to
## the enemy's `OverheadAnchor` and it draws a Label on a CanvasLayer at the
## projection of that anchor, just below the bar. Empty text hides it.

## Same layer as the bars, under the CombatFx popups.
const CANVAS_LAYER := 3
## The bar is 28 x 4 px at the 2D zoom (OverheadBars3D.BAR_SIZE); the line sits
## this many screen pixels below the anchor's projection.
const OFFSET_BELOW_ANCHOR_PX := 10.0
const FONT_SIZE := 15
const OUTLINE_SIZE := 5
const COLOR_TEXT := Color(1.0, 0.92, 0.7, 1.0)
const COLOR_OUTLINE := Color(0.05, 0.04, 0.04, 0.95)

var _layer: CanvasLayer
var _label: Label
var _text := ""


func _ready() -> void:
	_layer = CanvasLayer.new()
	_layer.name = "StatusLineLayer"
	_layer.layer = CANVAS_LAYER
	add_child(_layer)

	_label = Label.new()
	_label.name = "StatusLineLabel"
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.add_theme_font_size_override("font_size", FONT_SIZE)
	_label.add_theme_color_override("font_color", COLOR_TEXT)
	_label.add_theme_color_override("font_outline_color", COLOR_OUTLINE)
	_label.add_theme_constant_override("outline_size", OUTLINE_SIZE)
	_label.visible = false
	_layer.add_child(_label)
	set_text(_text)


func _process(_delta: float) -> void:
	_update_screen_position()


## Shows `text` under the bar; an empty string hides the line.
func set_text(text: String) -> void:
	_text = text
	if _label == null:
		return
	_label.text = text
	_label.reset_size()
	_update_screen_position()


func get_text() -> String:
	return _text


func _update_screen_position() -> void:
	if _label == null or not is_inside_tree():
		return
	if _text.is_empty() or not is_visible_in_tree():
		_label.visible = false
		return
	var viewport := get_viewport()
	if viewport == null:
		return
	var camera := viewport.get_camera_3d()
	if camera == null or camera.is_position_behind(global_position):
		_label.visible = false
		return
	_label.visible = true
	var screen := camera.unproject_position(global_position)
	_label.position = screen + Vector2(-_label.size.x * 0.5, OFFSET_BELOW_ANCHOR_PX)
