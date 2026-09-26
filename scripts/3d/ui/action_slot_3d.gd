class_name ActionSlot3D
extends Button

## One square slot on the action bar: an icon, the hotkey in the top-left
## corner, the cost marker in the bottom-right (a disc for an action, a
## triangle for a bonus action), a badge in the top-right (unspent skill
## points) and a darkened cooldown count over the icon. It stays a Button, so
## toggle, disabled and pressed work as they did on the text buttons.

signal hover_changed(slot: ActionSlot3D, hovered: bool)

enum CostMark { NONE, ACTION, BONUS }

const SLOT_SIZE := Vector2(50, 50)
const ICON_INSET := 5.0
const COLOR_ACTION := Color(0.46, 0.80, 0.44, 1.0)
const COLOR_BONUS := Color(0.96, 0.66, 0.26, 1.0)
const COLOR_BADGE := Color(0.95, 0.78, 0.30, 1.0)
const COLOR_AIM := Color(1.0, 0.86, 0.45, 1.0)

## Shown on the bar's info line while hovered or aimed.
var caption := ""
var detail := ""
var icon_key: StringName = &""
## Pressed means "click a target next" (not so for a stance like Sneak).
var aims := false
var accent := UiTheme.TEXT:
	set(value):
		accent = value
		queue_redraw()
var hotkey := "":
	set(value):
		if hotkey != value:
			hotkey = value
			queue_redraw()
var cost_mark: CostMark = CostMark.NONE:
	set(value):
		if cost_mark != value:
			cost_mark = value
			queue_redraw()
var cooldown := 0:
	set(value):
		if cooldown != value:
			cooldown = value
			queue_redraw()
var badge := "":
	set(value):
		if badge != value:
			badge = value
			queue_redraw()
## Lit like a pressed toggle without being one (Block while the stance holds).
var active := false:
	set(value):
		if active != value:
			active = value
			queue_redraw()


func _init() -> void:
	custom_minimum_size = SLOT_SIZE
	focus_mode = Control.FOCUS_NONE
	add_theme_stylebox_override("normal", UiTheme.box(UiTheme.SLOT_BG, UiTheme.SLOT_BORDER, 1))
	add_theme_stylebox_override("hover", UiTheme.box(UiTheme.SLOT_HOVER, UiTheme.PANEL_BORDER, 1))
	add_theme_stylebox_override("pressed", UiTheme.box(UiTheme.SLOT_SELECTED, COLOR_AIM, 2))
	add_theme_stylebox_override("hover_pressed", UiTheme.box(UiTheme.SLOT_SELECTED, COLOR_AIM, 2))
	add_theme_stylebox_override("disabled", UiTheme.box(UiTheme.SLOT_EMPTY_BG, UiTheme.SLOT_EMPTY_BORDER, 1))
	mouse_entered.connect(func() -> void: hover_changed.emit(self, true))
	mouse_exited.connect(func() -> void: hover_changed.emit(self, false))
	toggled.connect(func(_on: bool) -> void: queue_redraw())


func _draw() -> void:
	var area := Rect2(Vector2.ZERO, size)
	if active and not button_pressed:
		draw_style_box(UiTheme.box(UiTheme.SLOT_SELECTED, COLOR_AIM, 2), area)
	var tint := accent
	if disabled:
		tint = Color(accent.lerp(UiTheme.DISABLED_TEXT, 0.6), 0.55)
	var icon_area := area.grow(-ICON_INSET)
	ActionIcons3D.draw_icon(self, icon_area, icon_key, tint, caption)

	var font := get_theme_default_font()
	if cooldown > 0:
		draw_rect(area.grow(-2.0), Color(0.0, 0.0, 0.0, 0.55))
		_draw_centered(font, str(cooldown), area.get_center(), 20, UiTheme.TEXT)
	if not hotkey.is_empty():
		draw_string_outline(font, Vector2(4, 13), hotkey, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, 3, Color(0, 0, 0, 0.9))
		draw_string(font, Vector2(4, 13), hotkey, HORIZONTAL_ALIGNMENT_LEFT, -1, 11,
				UiTheme.MUTED if disabled else UiTheme.TITLE)
	match cost_mark:
		CostMark.ACTION:
			var c := Vector2(size.x - 8.0, size.y - 8.0)
			draw_circle(c, 4.0, Color(0, 0, 0, 0.8))
			draw_circle(c, 3.0, COLOR_ACTION if not disabled else UiTheme.DISABLED_TEXT)
		CostMark.BONUS:
			var tip := Vector2(size.x - 8.0, size.y - 13.0)
			var tri := PackedVector2Array([tip, tip + Vector2(4.5, 8.0), tip + Vector2(-4.5, 8.0)])
			draw_colored_polygon(tri, COLOR_BONUS if not disabled else UiTheme.DISABLED_TEXT)
	if not badge.is_empty():
		var c := Vector2(size.x - 7.0, 7.0)
		draw_circle(c, 8.0, Color(0, 0, 0, 0.85))
		draw_circle(c, 7.0, COLOR_BADGE)
		_draw_centered(font, badge, c, 11, Color(0.12, 0.08, 0.02, 1.0))


func _draw_centered(font: Font, text: String, center: Vector2, font_size: int, color: Color) -> void:
	var text_size := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
	var baseline := center + Vector2(-text_size.x * 0.5, font.get_ascent(font_size) * 0.5 - 1.0)
	draw_string_outline(font, baseline, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, 3, Color(0, 0, 0, 0.9))
	draw_string(font, baseline, text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)
