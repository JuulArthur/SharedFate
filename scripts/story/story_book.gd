extends Node

# Autoloaded singleton. The story book: a full-screen open book onto which a
# chapter's text is written as if by an unseen quill, read aloud by the system
# voice when one is available.
#
# An autoload for the same reason as `InventoryScreen`: chapters are opened from
# several level scenes, and the "already read" memory has to survive scene
# changes so the prologue doesn't replay every time the player walks back to
# the hub map.
#
# Usage, at the end of a level's _ready():
#   StoryBook.show_chapter_once(StoryLibrary.chapter(&"prologue"))
#
# While a chapter is open the scene tree is paused, so gameplay input, enemy AI
# and the other screens all stand still until the book closes. Click or Space
# hurries the ink and then turns the page; Esc skips the rest of the chapter.

signal chapter_finished(chapter_id: StringName)

# Above the loot panel (7) and the inventory (6): narration interrupts everything.
const LAYER := 8
const BOOK_SIZE := Vector2(1180, 660)
const PAGE_MARGIN := 30
const SPINE_WIDTH := 8
const BODY_FONT_SIZE := 20
const TITLE_FONT_SIZE := 30
const HINT_FONT_SIZE := 15

# Characters written per second, and how many trail behind the quill still
# glowing. Together they set the pace of a page; see StoryLibrary for the
# page-length guideline that goes with them.
const REVEAL_CHARS_PER_SECOND := 38.0
const REVEAL_TRAIL := 10.0
const PAGE_TURN_SECONDS := 0.28
const OPEN_SECONDS := 0.45
const CLOSE_SECONDS := 0.35

# Book palette. Deliberately warmer than UiTheme's panels so the book reads as
# an object in the world rather than another menu.
const LEATHER := Color(0.20, 0.11, 0.06, 1.0)
const LEATHER_EDGE := Color(0.52, 0.34, 0.16, 1.0)
const PARCHMENT := Color(0.86, 0.78, 0.62, 1.0)
const PARCHMENT_EDGE := Color(0.60, 0.50, 0.34, 1.0)
const SPINE := Color(0.30, 0.19, 0.10, 1.0)
const INK := Color(0.20, 0.14, 0.09, 1.0)
const INK_FAINT := Color(0.45, 0.38, 0.29, 1.0)
const MAGIC_GLOW := Color(1.0, 0.86, 0.45, 1.0)
const BACKDROP := Color(0.01, 0.01, 0.02, 0.94)
# Serif faces tried in order for the book; falls back to the engine font when
# none is installed, so this only ever adds polish.
const BOOK_FONT_NAMES := ["Georgia", "Palatino", "Book Antiqua", "Times New Roman"]

# Narration. Uses the operating system's speech voices through DisplayServer,
# which needs `audio/general/text_to_speech` enabled in project.godot (it is).
# When no voice matches, the book simply stays silent.
const VOICE_ENABLED := true
const VOICE_LANGUAGE_PREFIX := "en"
const VOICE_RATE := 0.95
const VOICE_VOLUME := 60

const HINT_REVEALING := "Click or press Space to hurry the ink"
const HINT_TURN := "Click or press Space to turn the page   ·   Esc skips the chapter"
const HINT_LAST := "Click or press Space to begin"

enum State { CLOSED, REVEALING, WAITING, TURNING }

var _layer: CanvasLayer
var _backdrop: ColorRect
var _pages: HBoxContainer
var _title_label: Label
var _title_rule: Control
var _left_body: RichTextLabel
var _right_body: RichTextLabel
var _left_number: Label
var _right_number: Label
var _left_effect: MagicInkEffect
var _right_effect: MagicInkEffect
var _hint_label: Label
var _book_font: Font

var _chapter: StoryChapter
var _page_index := 0
var _state := State.CLOSED
var _active_tween: Tween
# chapter id -> true, for every chapter shown this session.
var _seen: Dictionary = {}
var _voice_id := ""
var _was_paused := false


func _ready() -> void:
	# Keep writing, and keep listening for input, while the rest of the tree is
	# paused underneath the book.
	process_mode = Node.PROCESS_MODE_ALWAYS
	_book_font = _make_book_font()
	_build_ui()
	_resolve_voice()


func is_open() -> bool:
	return _state != State.CLOSED


# --- Public API ------------------------------------------------------------

# Show the chapter unless it has already been read this session. This is what
# levels should call from _ready(), so revisiting a map doesn't replay its intro.
func show_chapter_once(chapter: StoryChapter) -> void:
	if chapter == null or _seen.has(chapter.id):
		return
	_seen[chapter.id] = true
	show_chapter(chapter)


func show_chapter(chapter: StoryChapter) -> void:
	if chapter == null or chapter.pages.is_empty():
		return
	if is_open():
		push_warning("StoryBook: chapter %s requested while %s is still open; ignoring." % [chapter.id, _chapter.id])
		return

	_chapter = chapter
	_was_paused = get_tree().paused
	get_tree().paused = true

	_show_spread(0)
	_backdrop.modulate.a = 0.0
	_backdrop.visible = true
	_pages.modulate.a = 1.0

	_kill_tween()
	_active_tween = create_tween()
	_active_tween.tween_property(_backdrop, "modulate:a", 1.0, OPEN_SECONDS)
	_active_tween.tween_callback(_begin_page.bind(0))
	# Nothing to advance until the cover has faded in.
	_state = State.TURNING


func _input(event: InputEvent) -> void:
	if not is_open():
		return

	if event.is_action_pressed("ui_cancel"):
		_close()
		get_viewport().set_input_as_handled()
		return

	var clicked: bool = event is InputEventMouseButton \
			and event.button_index == MOUSE_BUTTON_LEFT and event.pressed
	if clicked or event.is_action_pressed("ui_accept"):
		_advance()
		get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	if _state != State.REVEALING:
		return

	var effect := _active_effect()
	var body := _active_body()
	effect.reveal_head += delta * REVEAL_CHARS_PER_SECOND
	if effect.reveal_head >= float(body.get_total_character_count()) + REVEAL_TRAIL:
		_state = State.WAITING
		_hint_label.text = HINT_LAST if _is_last_page() else HINT_TURN


# --- Flow ------------------------------------------------------------------

func _advance() -> void:
	match _state:
		State.REVEALING:
			_finish_reveal()
		State.WAITING:
			_next_page()
		_:
			pass


func _finish_reveal() -> void:
	var effect := _active_effect()
	effect.reveal_head = float(_active_body().get_total_character_count()) + REVEAL_TRAIL
	_state = State.WAITING
	_hint_label.text = HINT_LAST if _is_last_page() else HINT_TURN


func _next_page() -> void:
	var next := _page_index + 1
	if next >= _chapter.pages.size():
		_close()
	elif next % 2 == 1:
		# The right-hand leaf of the spread already on show.
		_begin_page(next)
	else:
		_turn_to_spread(next)


func _begin_page(index: int) -> void:
	_page_index = index
	_active_effect().reveal_head = 0.0
	_state = State.REVEALING
	_hint_label.text = HINT_REVEALING
	_speak(_chapter.pages[index])


func _turn_to_spread(first_page: int) -> void:
	_state = State.TURNING
	DisplayServer.tts_stop()

	_kill_tween()
	_active_tween = create_tween()
	_active_tween.tween_property(_pages, "modulate:a", 0.0, PAGE_TURN_SECONDS)
	_active_tween.tween_callback(_show_spread.bind(first_page))
	_active_tween.tween_property(_pages, "modulate:a", 1.0, PAGE_TURN_SECONDS)
	_active_tween.tween_callback(_begin_page.bind(first_page))


# Lay the two leaves of a spread out: `first_page` on the left, the one after it
# (if any) on the right. Neither is written yet; `_begin_page` starts the ink.
func _show_spread(first_page: int) -> void:
	var has_title := first_page == 0
	_title_label.visible = has_title
	_title_rule.visible = has_title
	_title_label.text = _chapter.title

	_set_page(_left_body, _left_effect, _left_number, first_page)
	_set_page(_right_body, _right_effect, _right_number, first_page + 1)


func _set_page(body: RichTextLabel, effect: MagicInkEffect, number: Label, page: int) -> void:
	effect.reveal_head = 0.0
	if page >= _chapter.pages.size():
		body.text = ""
		number.visible = false
		return
	body.text = "[magic_ink]%s[/magic_ink]" % _chapter.pages[page]
	number.text = "— %d —" % (page + 1)
	number.visible = true


func _close() -> void:
	if not is_open():
		return
	DisplayServer.tts_stop()
	var finished_id := _chapter.id
	_state = State.CLOSED

	# Hand the world back straight away; the backdrop keeps blocking the mouse
	# while it fades so no stray click lands on the map beneath.
	get_tree().paused = _was_paused

	_kill_tween()
	_active_tween = create_tween()
	_active_tween.tween_property(_backdrop, "modulate:a", 0.0, CLOSE_SECONDS)
	_active_tween.tween_callback(func() -> void: _backdrop.visible = false)

	chapter_finished.emit(finished_id)


func _kill_tween() -> void:
	if _active_tween != null and _active_tween.is_valid():
		_active_tween.kill()
	_active_tween = null


func _is_last_page() -> bool:
	return _page_index >= _chapter.pages.size() - 1


func _active_effect() -> MagicInkEffect:
	return _left_effect if _page_index % 2 == 0 else _right_effect


func _active_body() -> RichTextLabel:
	return _left_body if _page_index % 2 == 0 else _right_body


# --- Voice -----------------------------------------------------------------

func _resolve_voice() -> void:
	if not VOICE_ENABLED:
		return
	if not bool(ProjectSettings.get_setting("audio/general/text_to_speech", false)):
		return

	var voices := DisplayServer.tts_get_voices()
	for voice in voices:
		if String(voice.get("language", "")).begins_with(VOICE_LANGUAGE_PREFIX):
			_voice_id = String(voice.get("id", ""))
			return
	if not voices.is_empty():
		_voice_id = String(voices[0].get("id", ""))


func _speak(text: String) -> void:
	if _voice_id == "":
		return
	DisplayServer.tts_stop()
	DisplayServer.tts_speak(text, _voice_id, VOICE_VOLUME, 1.0, VOICE_RATE, 0, true)


# --- UI --------------------------------------------------------------------

func _build_ui() -> void:
	_layer = CanvasLayer.new()
	_layer.name = "StoryBookLayer"
	_layer.layer = LAYER
	add_child(_layer)

	# Darkens the world and swallows every click; the book sits on top of it.
	_backdrop = ColorRect.new()
	_backdrop.name = "StoryBook"
	_backdrop.visible = false
	_backdrop.color = BACKDROP
	_backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	_backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	_layer.add_child(_backdrop)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_backdrop.add_child(center)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 14)
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.add_child(column)

	column.add_child(_build_book())

	_hint_label = UiTheme.label(HINT_REVEALING, UiTheme.MUTED, HINT_FONT_SIZE)
	_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_child(_hint_label)


func _build_book() -> Control:
	var cover := PanelContainer.new()
	cover.custom_minimum_size = BOOK_SIZE
	cover.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cover.add_theme_stylebox_override("panel", UiTheme.box(LEATHER, LEATHER_EDGE, 3))

	var inset := MarginContainer.new()
	inset.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for side in ["margin_left", "margin_top", "margin_right", "margin_bottom"]:
		inset.add_theme_constant_override(side, 16)
	cover.add_child(inset)

	_pages = HBoxContainer.new()
	_pages.add_theme_constant_override("separation", 0)
	_pages.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inset.add_child(_pages)

	_left_effect = _make_effect()
	_left_body = _make_body(_left_effect)
	_left_number = _make_page_number()
	_title_label = UiTheme.label("", INK, TITLE_FONT_SIZE)
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if _book_font != null:
		_title_label.add_theme_font_override("font", _book_font)
	_title_rule = ColorRect.new()
	_title_rule.color = INK_FAINT
	_title_rule.custom_minimum_size = Vector2(0, 1)
	_title_rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_pages.add_child(_make_leaf([_title_label, _title_rule, _left_body, _left_number]))

	var spine := ColorRect.new()
	spine.color = SPINE
	spine.custom_minimum_size = Vector2(SPINE_WIDTH, 0)
	spine.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_pages.add_child(spine)

	_right_effect = _make_effect()
	_right_body = _make_body(_right_effect)
	_right_number = _make_page_number()
	_pages.add_child(_make_leaf([_right_body, _right_number]))

	return cover


# One parchment leaf holding the given controls top to bottom. The body label
# should carry SIZE_EXPAND_FILL so the page number sits at the foot of the leaf.
func _make_leaf(contents: Array) -> Control:
	var leaf := PanelContainer.new()
	leaf.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	leaf.size_flags_vertical = Control.SIZE_EXPAND_FILL
	leaf.mouse_filter = Control.MOUSE_FILTER_IGNORE
	leaf.add_theme_stylebox_override("panel", UiTheme.box(PARCHMENT, PARCHMENT_EDGE, 1))

	var margin := MarginContainer.new()
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for side in ["margin_left", "margin_top", "margin_right", "margin_bottom"]:
		margin.add_theme_constant_override(side, PAGE_MARGIN)
	leaf.add_child(margin)

	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", 12)
	stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
	margin.add_child(stack)

	for control in contents:
		stack.add_child(control)
	return leaf


func _make_effect() -> MagicInkEffect:
	var effect := MagicInkEffect.new()
	effect.trail = REVEAL_TRAIL
	effect.ink = INK
	effect.glow = MAGIC_GLOW
	return effect


func _make_body(effect: MagicInkEffect) -> RichTextLabel:
	var body := RichTextLabel.new()
	body.bbcode_enabled = true
	body.scroll_active = false
	body.fit_content = false
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	body.custom_effects = [effect]
	body.add_theme_color_override("default_color", INK)
	body.add_theme_font_size_override("normal_font_size", BODY_FONT_SIZE)
	body.add_theme_constant_override("line_separation", 5)
	if _book_font != null:
		body.add_theme_font_override("normal_font", _book_font)
	return body


func _make_page_number() -> Label:
	var number := UiTheme.label("", INK_FAINT, 14)
	number.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	number.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if _book_font != null:
		number.add_theme_font_override("font", _book_font)
	return number


func _make_book_font() -> Font:
	var font := SystemFont.new()
	font.font_names = PackedStringArray(BOOK_FONT_NAMES)
	return font
