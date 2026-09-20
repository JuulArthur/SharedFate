class_name OverheadBars3D
extends Node3D

## 3D twin of the overhead health bar that `player.gd` and `enemy.gd` build from
## three `Sprite2D`s (`_setup_health_bar`) and animate through
## `CombatFx.animate_bar`: a dark background, the real fill, and a pale ghost fill
## underneath that trails on damage so the chunk just lost stays readable.
##
## Parent it to the actor's `OverheadAnchor`; the bar is drawn on a CanvasLayer at
## the projection of that anchor. The fill and ghost colours are exported so an
## enemy scene can use the 2D enemy palette (red fill) without a second script.
## Contract: docs/3d-port-contracts.md, section 7.

## Under the CombatFx popups (4) so a damage number is never hidden by a bar.
const CANVAS_LAYER := 3
## Matches main.gd CAMERA_ZOOM so the bar keeps its 2D on-screen size. See
## counter_prompt_3d.gd for the same reasoning.
const SCREEN_SCALE := 3.35
## The 2D bar is 28x4 px at that zoom.
const BAR_SIZE := Vector2(28.0, 4.0) * SCREEN_SCALE

const COLOR_BACKGROUND := Color(0.16, 0.16, 0.16, 0.95)
const COLOR_FILL_PLAYER := Color(0.15, 0.82, 0.22, 1.0)
const COLOR_GHOST_PLAYER := Color(1.0, 0.85, 0.6, 0.9)
const COLOR_FILL_ENEMY := Color(0.88, 0.2, 0.2, 1.0)
const COLOR_GHOST_ENEMY := Color(1.0, 0.78, 0.6, 0.9)

## Timings copied from CombatFx.animate_bar so both games read the same.
const FILL_SECONDS := 0.12
const GHOST_DELAY_SECONDS := 0.28
const GHOST_SECONDS := 0.32

@export var fill_color: Color = COLOR_FILL_PLAYER
@export var ghost_color: Color = COLOR_GHOST_PLAYER

var _layer: CanvasLayer
var _control: Control
var _background: ColorRect
var _ghost: ColorRect
var _fill: ColorRect
var _ratio := 1.0
var _bars_visible := true


func _ready() -> void:
	_layer = CanvasLayer.new()
	_layer.name = "OverheadBarsLayer"
	_layer.layer = CANVAS_LAYER
	add_child(_layer)

	_control = Control.new()
	_control.name = "OverheadBarsControl"
	_control.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_control.custom_minimum_size = BAR_SIZE
	_control.size = BAR_SIZE
	_control.visible = false
	_layer.add_child(_control)

	_background = _make_rect("Background", COLOR_BACKGROUND)
	_ghost = _make_rect("Ghost", ghost_color)
	_fill = _make_rect("Fill", fill_color)
	_ghost.scale = Vector2(_ratio, 1.0)
	_fill.scale = Vector2(_ratio, 1.0)

	visible = _bars_visible
	_update_screen_position()


func _process(_delta: float) -> void:
	_update_screen_position()


func _make_rect(rect_name: String, color: Color) -> ColorRect:
	var rect := ColorRect.new()
	rect.name = rect_name
	rect.color = color
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.size = BAR_SIZE
	rect.pivot_offset = Vector2.ZERO
	_control.add_child(rect)
	return rect


## Same two-speed animation as CombatFx.animate_bar: the fill snaps to the new
## ratio while the ghost waits, then catches up. Heals move both at once.
func set_ratio(health_ratio: float) -> void:
	_ratio = clampf(health_ratio, 0.0, 1.0)
	if _fill == null or not is_inside_tree():
		if _fill != null:
			_fill.scale = Vector2(_ratio, 1.0)
		if _ghost != null:
			_ghost.scale = Vector2(_ratio, 1.0)
		return
	var fill_tween := create_tween()
	fill_tween.tween_property(_fill, "scale:x", _ratio, FILL_SECONDS) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	if _ghost == null:
		return
	if _ratio >= _ghost.scale.x:
		_ghost.scale.x = _ratio
		return
	var ghost_tween := create_tween()
	ghost_tween.tween_interval(GHOST_DELAY_SECONDS)
	ghost_tween.tween_property(_ghost, "scale:x", _ratio, GHOST_SECONDS) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN_OUT)


func set_visible_bars(v: bool) -> void:
	_bars_visible = v
	visible = v
	if _control != null:
		_control.visible = v


## Places the bar centred on the projection of this node (the OverheadAnchor).
## Without a current Camera3D the frame is skipped.
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
	_control.visible = visible and _bars_visible
	_control.position = camera.unproject_position(origin) - BAR_SIZE * 0.5
