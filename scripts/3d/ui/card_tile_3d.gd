class_name CardTile3D
extends Button

## One skill card as a small upright tile: a frame in its category's colour, the
## card's glyph, its name and, in the collection, how many copies are free.
## A Button, so the forge wires `pressed` to add or remove it.

const TILE_SIZE := Vector2(66, 88)
const ICON_BOX := Rect2(13, 10, 40, 40)
const CATEGORY_TINT := {
	SkillCards3D.Category.TYPE: Color(0.95, 0.80, 0.45, 1.0),
	SkillCards3D.Category.ELEMENT: Color(0.62, 0.80, 1.0, 1.0),
	SkillCards3D.Category.MODIFIER: Color(0.72, 0.76, 0.82, 1.0),
}

var card_id: StringName = &""
## Free copies to show in the corner; -1 hides the count.
var count := -1:
	set(value):
		count = value
		queue_redraw()
## An empty workbench slot: a dim outline and no card.
var empty := false:
	set(value):
		empty = value
		queue_redraw()


func _init() -> void:
	custom_minimum_size = TILE_SIZE
	focus_mode = Control.FOCUS_NONE
	flat = true
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND


func setup(the_card_id: StringName, the_count: int = -1) -> void:
	card_id = the_card_id
	count = the_count
	empty = card_id == &""
	if not empty:
		tooltip_text = "%s (%s)\n%s\nCost %d" % [SkillCards3D.display_name(card_id),
			SkillCards3D.category_name(SkillCards3D.category_of(card_id)).trim_suffix("s"),
			String(SkillCards3D.get_card(card_id).get("text", "")), SkillCards3D.cost_of(card_id)]
	queue_redraw()


func _draw() -> void:
	var area := Rect2(Vector2.ZERO, size)
	if empty:
		draw_style_box(UiTheme.box(UiTheme.SLOT_EMPTY_BG, UiTheme.SLOT_EMPTY_BORDER, 1), area)
		return
	var tint: Color = CATEGORY_TINT.get(SkillCards3D.category_of(card_id), UiTheme.TEXT)
	var dimmed := disabled or count == 0
	var border := tint if not dimmed else UiTheme.SLOT_EMPTY_BORDER
	var bg := UiTheme.SLOT_HOVER if is_hovered() and not dimmed else UiTheme.SLOT_BG
	draw_style_box(UiTheme.box(bg, border, 2 if is_hovered() and not dimmed else 1), area)
	# A band at the top names the category by colour.
	draw_rect(Rect2(3, 3, size.x - 6, 4), Color(tint, 0.8 if not dimmed else 0.3))
	var glyph_color := SkillCards3D.color_of(card_id)
	if dimmed:
		glyph_color = Color(glyph_color.lerp(UiTheme.DISABLED_TEXT, 0.6), 0.5)
	ActionIcons3D.draw_icon(self, ICON_BOX, SkillCards3D.icon_of(card_id), glyph_color, SkillCards3D.display_name(card_id))
	var font := get_theme_default_font()
	var name_text := SkillCards3D.display_name(card_id)
	var font_size := 11
	var width := font.get_string_size(name_text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	draw_string(font, Vector2((size.x - width) * 0.5, size.y - 18), name_text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size,
		UiTheme.TEXT if not dimmed else UiTheme.DISABLED_TEXT)
	var cost_text := "%d" % SkillCards3D.cost_of(card_id)
	draw_string(font, Vector2(6, size.y - 5), cost_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, UiTheme.MUTED)
	if count >= 0:
		var count_text := "x%d" % count
		var count_width := font.get_string_size(count_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x
		draw_string(font, Vector2(size.x - count_width - 6, size.y - 5), count_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 12,
			UiTheme.TITLE if count > 0 else UiTheme.DISABLED_TEXT)


func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_ENTER or what == NOTIFICATION_MOUSE_EXIT:
		queue_redraw()
