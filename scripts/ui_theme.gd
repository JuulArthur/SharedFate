class_name UiTheme
extends RefCounted

# Shared look for the game's code-built panels (loot menu, inventory screen).
#
# Pure helpers over Godot's theme overrides — no state, no nodes owned here.
# Keeping the palette and the box/button recipes in one place is what stops the
# two screens drifting apart as either one grows.

# --- Palette ---
const PANEL_BG := Color(0.066, 0.055, 0.043, 0.97)
const PANEL_BORDER := Color(0.66, 0.53, 0.29, 1.0)
const WELL_BG := Color(0.043, 0.036, 0.028, 1.0)
const SLOT_BG := Color(0.13, 0.11, 0.085, 1.0)
const SLOT_BORDER := Color(0.42, 0.34, 0.20, 1.0)
const SLOT_HOVER := Color(0.22, 0.19, 0.14, 1.0)
const SLOT_SELECTED := Color(0.30, 0.25, 0.17, 1.0)
const SLOT_EMPTY_BG := Color(0.09, 0.077, 0.061, 1.0)
const SLOT_EMPTY_BORDER := Color(0.24, 0.20, 0.13, 1.0)
const TITLE := Color(0.90, 0.79, 0.52, 1.0)
const TEXT := Color(0.88, 0.87, 0.84, 1.0)
const MUTED := Color(0.62, 0.59, 0.54, 1.0)
const RULE := Color(0.52, 0.44, 0.28, 0.85)
# Edge on a slot holding something the character is wearing.
const WORN_BORDER := Color(0.47, 0.66, 0.42, 1.0)
const DISABLED_TEXT := Color(0.42, 0.40, 0.37, 1.0)
# Dim laid over the world behind a full-screen panel.
const SCREEN_DIM := Color(0.02, 0.02, 0.03, 0.90)


static func box(bg: Color, border: Color, border_width: int,
		margin_x: int = 0, margin_y: int = 0) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = bg
	style.border_color = border
	style.border_width_left = border_width
	style.border_width_top = border_width
	style.border_width_right = border_width
	style.border_width_bottom = border_width
	style.corner_radius_top_left = 3
	style.corner_radius_top_right = 3
	style.corner_radius_bottom_left = 3
	style.corner_radius_bottom_right = 3
	style.content_margin_left = margin_x
	style.content_margin_right = margin_x
	style.content_margin_top = margin_y
	style.content_margin_bottom = margin_y
	return style


# Dark plate with a tan edge, rather than Godot's default grey button.
static func style_button(button: Button, font_size: int = 15) -> void:
	button.add_theme_stylebox_override("normal", box(SLOT_BG, SLOT_BORDER, 1, 12, 6))
	button.add_theme_stylebox_override("hover", box(SLOT_HOVER, PANEL_BORDER, 1, 12, 6))
	button.add_theme_stylebox_override("pressed", box(SLOT_SELECTED, PANEL_BORDER, 1, 12, 6))
	button.add_theme_stylebox_override("disabled", box(SLOT_EMPTY_BG, SLOT_EMPTY_BORDER, 1, 12, 6))
	button.add_theme_color_override("font_color", TEXT)
	button.add_theme_color_override("font_hover_color", TITLE)
	button.add_theme_color_override("font_pressed_color", TITLE)
	button.add_theme_color_override("font_disabled_color", DISABLED_TEXT)
	button.add_theme_font_size_override("font_size", font_size)
	button.focus_mode = Control.FOCUS_NONE


# An item slot: bordered plate that lights up on hover and stays lit when it is
# the current selection.
static func style_slot(slot: Button, selected: bool, worn: bool = false) -> void:
	var bg := SLOT_SELECTED if selected else SLOT_BG
	var border := SLOT_BORDER
	if selected:
		border = PANEL_BORDER
	elif worn:
		border = WORN_BORDER
	slot.add_theme_stylebox_override("normal", box(bg, border, 2 if selected or worn else 1))
	slot.add_theme_stylebox_override("hover", box(SLOT_HOVER, PANEL_BORDER, 2))
	slot.add_theme_stylebox_override("pressed", box(SLOT_SELECTED, PANEL_BORDER, 2))
	slot.add_theme_stylebox_override("disabled", box(SLOT_EMPTY_BG, SLOT_EMPTY_BORDER, 1))
	slot.focus_mode = Control.FOCUS_NONE


static func rule() -> Control:
	var line := ColorRect.new()
	line.color = RULE
	line.custom_minimum_size = Vector2(0, 1)
	return line


# Title text on its own recessed plate, as on the loot and inventory screens.
static func title_plate(text: String, font_size: int = 22) -> Control:
	var plate := PanelContainer.new()
	plate.add_theme_stylebox_override("panel", box(WELL_BG, PANEL_BORDER, 1, 10, 6))

	var label := Label.new()
	label.text = text
	label.add_theme_color_override("font_color", TITLE)
	label.add_theme_font_size_override("font_size", font_size)
	plate.add_child(label)
	return plate


# Pixel-art icon, scaled to fit `size` without smearing.
static func icon_rect(texture: Texture2D, size: Vector2) -> TextureRect:
	var icon := TextureRect.new()
	icon.texture = texture
	icon.custom_minimum_size = size
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return icon


static func label(text: String, color: Color, font_size: int) -> Label:
	var node := Label.new()
	node.text = text
	node.add_theme_color_override("font_color", color)
	node.add_theme_font_size_override("font_size", font_size)
	return node
