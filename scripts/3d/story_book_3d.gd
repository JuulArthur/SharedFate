class_name StoryBook3D
extends CanvasLayer

## The story book for the 3D game: the flow of the 2D `StoryBook` (a chapter
## written onto an open book by an unseen quill, read aloud, the tree paused
## underneath) in a dark-fantasy dress. The paused 3D world stays visible behind
## the book, blurred, drained of colour and sunk into a vignette; embers drift up
## past a black leather cover with iron corners; the pages are scorched, stained
## parchment under a guttering candle; the words burn in ember-red and cool to
## ink (`EmberInkEffect`); the narrator reads lower and slower than in 2D.
##
## Narration: a recorded page wins over the system voice. Page N of chapter
## `<id>` plays `assets/3d/audio/narration/<id>_NN.ogg` (or .wav / .mp3) when
## the file exists, e.g. `prologue_01.ogg`; pages without one are read by the
## system voice. `voice_enabled` off silences both.
##
## A node the coordinator creates (`main_3d.gd`, `_setup_story_book`), not an
## autoload, so the 2D `StoryBook` autoload stays as it is. Chapters come from the
## shared `StoryLibrary`, so the text is the 2D text. Which chapters were read is
## kept in a static, so it survives a scene reload within one session.
##
## Click or Space hurries the ink, then turns the page; Esc closes the book.

signal chapter_finished(chapter_id: StringName)

# Above the loot panel (7) and the inventory (6), as the 2D book.
const LAYER := 8
const BOOK_SIZE := Vector2(1180, 660)
const COVER_INSET := 18
const PAGE_MARGIN := 38
const SPINE_WIDTH := 10
const BODY_FONT_SIZE := 20
const TITLE_FONT_SIZE := 27
const TITLE_LETTER_SPACING := 4
const NUMBER_FONT_SIZE := 14
const HINT_FONT_SIZE := 15

# Same pace as the 2D book (StoryLibrary's page-length guideline assumes it);
# the trail is longer so the embers are seen cooling.
const REVEAL_CHARS_PER_SECOND := 38.0
const REVEAL_TRAIL := 14.0
const PAGE_TURN_SECONDS := 0.32
const OPEN_SECONDS := 0.7
const CLOSE_SECONDS := 0.45
const OPEN_START_SCALE := 0.93

const LEATHER := Color(0.055, 0.040, 0.038, 1.0)
const LEATHER_EDGE := Color(0.20, 0.17, 0.15, 1.0)
const IRON := Color(0.24, 0.23, 0.22, 1.0)
const IRON_SHADE := Color(0.08, 0.075, 0.07, 1.0)
const IRON_RIVET := Color(0.46, 0.43, 0.39, 1.0)
const SPINE := Color(0.025, 0.018, 0.016, 1.0)
const INK := Color(0.10, 0.06, 0.05, 1.0)
const EMBER := Color(0.78, 0.16, 0.06, 1.0)
const HEAT := Color(1.0, 0.80, 0.42, 1.0)
const BLOOD := Color(0.40, 0.05, 0.04, 1.0)
const INK_FAINT := Color(0.30, 0.20, 0.15, 1.0)
const HINT := Color(0.60, 0.54, 0.47, 0.85)
const COVER_SHADOW := Color(0.0, 0.0, 0.0, 0.85)

# Serif faces tried in order; the engine font takes over when none is installed.
const BOOK_FONT_NAMES := ["Palatino Linotype", "Palatino", "Constantia", "Book Antiqua", "Georgia"]

# The system voice, as in 2D (`audio/general/text_to_speech` is on), pitched and
# paced down for a graver narrator.
const VOICE_LANGUAGE_PREFIX := "en"
const VOICE_RATE := 0.88
const VOICE_PITCH := 0.8
const VOICE_VOLUME := 60

# Recorded narration, one file per page (see the header). Formats Godot imports.
const NARRATION_DIR := "res://assets/3d/audio/narration/"
const NARRATION_EXTENSIONS: Array[String] = ["ogg", "wav", "mp3"]
const NARRATION_VOLUME_DB := 0.0

const HINT_REVEALING := "Click or Space: hasten the ink"
const HINT_TURN := "Click or Space: turn the page   ·   Esc: close the book"
const HINT_LAST := "Click or Space: begin"

# The world behind the book: blurred through the screen texture's mipmaps,
# drained of colour, darkened toward an ember-brown and sunk into a vignette.
const BACKDROP_SHADER := """
shader_type canvas_item;

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform float blur_lod = 3.0;
uniform float saturation = 0.35;
uniform float brightness = 0.5;
uniform vec4 tint : source_color = vec4(0.09, 0.035, 0.02, 1.0);

void fragment() {
	float alpha = COLOR.a;
	vec3 scene = textureLod(screen_tex, SCREEN_UV, blur_lod).rgb;
	float lum = dot(scene, vec3(0.299, 0.587, 0.114));
	scene = mix(vec3(lum), scene, saturation) * brightness + tint.rgb * 0.35;
	float vignette = smoothstep(0.95, 0.25, length((UV - 0.5) * vec2(1.25, 1.5)));
	COLOR = vec4(scene * mix(0.08, 1.0, vignette), alpha);
}
"""

# One parchment leaf: aged paper with grain and stains, scorched ragged edges,
# the shadow of the gutter toward the spine, and a candle pooled at the top of
# the spread that flickers on the render clock (it keeps going while paused).
const PARCHMENT_SHADER := """
shader_type canvas_item;

uniform vec4 paper : source_color = vec4(0.71, 0.62, 0.47, 1.0);
uniform vec4 stain : source_color = vec4(0.44, 0.32, 0.20, 1.0);
uniform vec4 scorch : source_color = vec4(0.07, 0.04, 0.03, 1.0);
// 1.0 when the spine is on the leaf's right edge (left leaf), -1.0 otherwise.
uniform float gutter_side = 1.0;
uniform float seed = 0.0;

// Sine-free hash (Hoskins): a sin() hash goes blocky on the GPU at large p.
float hash(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x),
			mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x), u.y);
}

float fbm(vec2 p) {
	float value = 0.0;
	float amplitude = 0.5;
	for (int i = 0; i < 5; i++) {
		value += amplitude * noise(p);
		p *= 2.03;
		amplitude *= 0.5;
	}
	return value;
}

void fragment() {
	float alpha = COLOR.a;
	vec2 uv = UV;
	vec2 p = uv * vec2(6.0, 7.0) + vec2(seed, seed * 0.37);

	float grain = fbm(p * 3.0);
	float blot = smoothstep(0.55, 0.82, fbm(p * 0.6 + 3.1));
	vec3 col = mix(paper.rgb, stain.rgb, blot * 0.5);
	col *= 0.88 + grain * 0.2;

	float edge = min(min(uv.x, 1.0 - uv.x), min(uv.y, 1.0 - uv.y));
	edge += (fbm(p * 1.6 + 7.0) - 0.5) * 0.04;
	col = mix(col, scorch.rgb, (1.0 - smoothstep(0.0, 0.05, edge)) * 0.9);

	float from_spine = gutter_side > 0.0 ? 1.0 - uv.x : uv.x;
	col *= mix(0.5, 1.0, smoothstep(0.0, 0.16, from_spine));

	vec2 candle = vec2(gutter_side > 0.0 ? 1.0 : 0.0, 0.2);
	float pool = smoothstep(1.2, 0.1, distance(uv * vec2(1.0, 1.2), candle * vec2(1.0, 1.2)));
	float flicker = 1.0 + 0.025 * sin(TIME * 7.3) + 0.018 * sin(TIME * 12.9 + 1.3) + 0.012 * sin(TIME * 2.1 + 0.4);
	col *= mix(0.7, 1.08, pool) * flicker * vec3(1.0, 0.95, 0.86);

	COLOR = vec4(col, alpha);
}
"""

enum State { CLOSED, REVEALING, WAITING, TURNING }

# chapter id -> true, for every chapter shown this session.
static var _read_this_session: Dictionary = {}

## Read the chapter aloud (recordings, else the system voice). Off gives a silent book.
var voice_enabled := true:
	set(value):
		voice_enabled = value
		if is_inside_tree():
			_resolve_voice()

var _backdrop: ColorRect
var _embers: CPUParticles2D
var _book: PanelContainer
var _pages: HBoxContainer
var _left_paper: ColorRect
var _right_paper: ColorRect
var _title_label: Label
var _title_ornament: Control
var _left_body: RichTextLabel
var _right_body: RichTextLabel
var _left_number: Label
var _right_number: Label
var _left_effect: EmberInkEffect
var _right_effect: EmberInkEffect
var _hint_label: Label
var _book_font: Font
var _narration_player: AudioStreamPlayer

var _chapter: StoryChapter
var _page_index := 0
var _state := State.CLOSED
var _active_tween: Tween
var _voice_id := ""
var _was_paused := false


func _ready() -> void:
	# Keep writing and listening while the tree is paused under the book.
	process_mode = Node.PROCESS_MODE_ALWAYS
	layer = LAYER
	_book_font = _make_book_font()
	_build_ui()
	_narration_player = AudioStreamPlayer.new()
	_narration_player.name = "Narration"
	_narration_player.volume_db = NARRATION_VOLUME_DB
	add_child(_narration_player)
	_resolve_voice()
	get_viewport().size_changed.connect(_place_embers)
	_place_embers()


static func has_read(chapter_id: StringName) -> bool:
	return _read_this_session.has(chapter_id)


func is_open() -> bool:
	return _state != State.CLOSED


# --- Public API ------------------------------------------------------------

## Show the chapter unless it was already read this session.
func show_chapter_once(chapter: StoryChapter) -> void:
	if chapter == null or has_read(chapter.id):
		return
	_read_this_session[chapter.id] = true
	show_chapter(chapter)


func show_chapter(chapter: StoryChapter) -> void:
	if chapter == null or chapter.pages.is_empty():
		return
	if is_open():
		push_warning("StoryBook3D: chapter %s requested while %s is still open; ignoring." % [chapter.id, _chapter.id])
		return

	_chapter = chapter
	_was_paused = get_tree().paused
	get_tree().paused = true

	_show_spread(0)
	_backdrop.modulate.a = 0.0
	_backdrop.visible = true
	_pages.modulate.a = 1.0
	_book.modulate.a = 0.0
	_book.scale = Vector2.ONE * OPEN_START_SCALE
	_embers.emitting = true

	_kill_tween()
	_active_tween = create_tween().set_parallel(true)
	_active_tween.tween_property(_backdrop, "modulate:a", 1.0, OPEN_SECONDS)
	_active_tween.tween_property(_book, "modulate:a", 1.0, OPEN_SECONDS) \
			.set_delay(OPEN_SECONDS * 0.3)
	_active_tween.tween_property(_book, "scale", Vector2.ONE, OPEN_SECONDS) \
			.set_delay(OPEN_SECONDS * 0.3).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_active_tween.chain().tween_callback(_begin_page.bind(0))
	# Nothing to advance until the book has risen out of the dark.
	_state = State.TURNING


## Close the book at once, as Esc does.
func close() -> void:
	_close()


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
	# Swallow everything else too, so no screen toggles beneath the book.
	if event is InputEventKey or event is InputEventMouseButton or event is InputEventAction:
		get_viewport().set_input_as_handled()


func _process(delta: float) -> void:
	if _state != State.REVEALING:
		return

	var effect := _active_effect()
	effect.reveal_head += delta * REVEAL_CHARS_PER_SECOND
	if effect.reveal_head >= float(_active_body().get_total_character_count()) + REVEAL_TRAIL:
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
	_active_effect().reveal_head = float(_active_body().get_total_character_count()) + REVEAL_TRAIL
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
	_narrate(index)


func _turn_to_spread(first_page: int) -> void:
	_state = State.TURNING
	_stop_voice()

	_kill_tween()
	_active_tween = create_tween()
	_active_tween.tween_property(_pages, "modulate:a", 0.0, PAGE_TURN_SECONDS)
	_active_tween.tween_callback(_show_spread.bind(first_page))
	_active_tween.tween_property(_pages, "modulate:a", 1.0, PAGE_TURN_SECONDS)
	_active_tween.tween_callback(_begin_page.bind(first_page))


# Lay out a spread: `first_page` on the left, the next (if any) on the right.
# Each spread gets its own stains; the ink starts in `_begin_page`.
func _show_spread(first_page: int) -> void:
	var has_title := first_page == 0
	_title_label.visible = has_title
	_title_ornament.visible = has_title
	_title_label.text = _chapter.title

	(_left_paper.material as ShaderMaterial).set_shader_parameter("seed", float(first_page) * 7.31)
	(_right_paper.material as ShaderMaterial).set_shader_parameter("seed", float(first_page) * 7.31 + 19.7)
	_set_page(_left_body, _left_effect, _left_number, first_page)
	_set_page(_right_body, _right_effect, _right_number, first_page + 1)


func _set_page(body: RichTextLabel, effect: EmberInkEffect, number: Label, page: int) -> void:
	effect.reveal_head = 0.0
	if page >= _chapter.pages.size():
		body.text = ""
		number.visible = false
		return
	body.text = "[ember_ink]%s[/ember_ink]" % _chapter.pages[page]
	number.text = "·  %s  ·" % _roman(page + 1)
	number.visible = true


func _close() -> void:
	if not is_open():
		return
	_stop_voice()
	var finished_id := _chapter.id
	_state = State.CLOSED

	# Hand the world back at once; the backdrop keeps swallowing clicks while it
	# fades so no stray click lands on the map beneath.
	get_tree().paused = _was_paused

	_kill_tween()
	_active_tween = create_tween().set_parallel(true)
	_active_tween.tween_property(_backdrop, "modulate:a", 0.0, CLOSE_SECONDS)
	_active_tween.tween_property(_book, "scale", Vector2.ONE * OPEN_START_SCALE, CLOSE_SECONDS) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	_active_tween.chain().tween_callback(_on_close_faded)

	chapter_finished.emit(finished_id)


func _on_close_faded() -> void:
	_backdrop.visible = false
	_embers.emitting = false


func _kill_tween() -> void:
	if _active_tween != null and _active_tween.is_valid():
		_active_tween.kill()
	_active_tween = null


func _is_last_page() -> bool:
	return _page_index >= _chapter.pages.size() - 1


func _active_effect() -> EmberInkEffect:
	return _left_effect if _page_index % 2 == 0 else _right_effect


func _active_body() -> RichTextLabel:
	return _left_body if _page_index % 2 == 0 else _right_body


static func _roman(value: int) -> String:
	var numerals := [[50, "L"], [40, "XL"], [10, "X"], [9, "IX"], [5, "V"], [4, "IV"], [1, "I"]]
	var text := ""
	for pair in numerals:
		while value >= int(pair[0]):
			text += String(pair[1])
			value -= int(pair[0])
	return text


# --- Voice -----------------------------------------------------------------

func _resolve_voice() -> void:
	_stop_voice()
	_voice_id = ""
	if not voice_enabled:
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


## Read page `index` aloud: its recording when there is one, else the system voice.
func _narrate(index: int) -> void:
	_stop_voice()
	if not voice_enabled:
		return
	var recording := narration_stream(_chapter.id, index)
	if recording != null:
		_narration_player.stream = recording
		_narration_player.play()
		return
	if _voice_id != "":
		DisplayServer.tts_speak(_chapter.pages[index], _voice_id, VOICE_VOLUME, VOICE_PITCH, VOICE_RATE, 0, true)


## The recorded narration for page `index` (0-based) of a chapter, or null.
static func narration_stream(chapter_id: StringName, index: int) -> AudioStream:
	for extension in NARRATION_EXTENSIONS:
		var path := "%s%s_%02d.%s" % [NARRATION_DIR, chapter_id, index + 1, extension]
		if ResourceLoader.exists(path):
			return load(path) as AudioStream
	return null


func _stop_voice() -> void:
	if _narration_player != null and _narration_player.playing:
		_narration_player.stop()
	if _voice_id != "":
		DisplayServer.tts_stop()


# --- UI --------------------------------------------------------------------

func _build_ui() -> void:
	# The world, dimmed and blurred; swallows every click. Everything else sits
	# on top of it, so fading it fades the whole book.
	_backdrop = ColorRect.new()
	_backdrop.name = "StoryBook3D"
	_backdrop.visible = false
	_backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	_backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	_backdrop.material = _make_shader_material(BACKDROP_SHADER)
	add_child(_backdrop)

	_embers = _make_embers()
	_backdrop.add_child(_embers)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_backdrop.add_child(center)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 18)
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	center.add_child(column)

	column.add_child(_build_book())

	_hint_label = UiTheme.label(HINT_REVEALING, HINT, HINT_FONT_SIZE)
	_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if _book_font != null:
		_hint_label.add_theme_font_override("font", _book_font)
	column.add_child(_hint_label)


func _build_book() -> Control:
	_book = PanelContainer.new()
	_book.custom_minimum_size = BOOK_SIZE
	_book.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var cover := UiTheme.box(LEATHER, LEATHER_EDGE, 3)
	cover.shadow_color = COVER_SHADOW
	cover.shadow_size = 36
	cover.shadow_offset = Vector2(0, 10)
	_book.add_theme_stylebox_override("panel", cover)
	_book.resized.connect(func() -> void: _book.pivot_offset = _book.size / 2.0)

	var inset := MarginContainer.new()
	inset.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for side in ["margin_left", "margin_top", "margin_right", "margin_bottom"]:
		inset.add_theme_constant_override(side, COVER_INSET)
	_book.add_child(inset)

	_pages = HBoxContainer.new()
	_pages.add_theme_constant_override("separation", 0)
	_pages.mouse_filter = Control.MOUSE_FILTER_IGNORE
	inset.add_child(_pages)

	_left_effect = _make_effect()
	_left_body = _make_body(_left_effect)
	_left_number = _make_page_number()
	_title_label = _make_title()
	_title_ornament = _Ornament.new()
	_title_ornament.color = BLOOD
	_title_ornament.custom_minimum_size = Vector2(0, 12)
	_title_ornament.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_left_paper = _make_paper(1.0)
	_pages.add_child(_make_leaf(_left_paper, [_title_label, _title_ornament, _left_body, _left_number]))

	var spine := ColorRect.new()
	spine.color = SPINE
	spine.custom_minimum_size = Vector2(SPINE_WIDTH, 0)
	spine.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_pages.add_child(spine)

	_right_effect = _make_effect()
	_right_body = _make_body(_right_effect)
	_right_number = _make_page_number()
	_right_paper = _make_paper(-1.0)
	_pages.add_child(_make_leaf(_right_paper, [_right_body, _right_number]))

	# Iron corner guards over the leather, drawn last so they sit on top.
	var iron := _CoverIron.new()
	iron.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_book.add_child(iron)

	return _book


# One leaf: the parchment shader behind a margin holding the given controls top
# to bottom. The body label carries SIZE_EXPAND_FILL so the number sits at the foot.
func _make_leaf(paper: ColorRect, contents: Array) -> Control:
	var leaf := PanelContainer.new()
	leaf.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	leaf.size_flags_vertical = Control.SIZE_EXPAND_FILL
	leaf.mouse_filter = Control.MOUSE_FILTER_IGNORE
	leaf.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	leaf.add_child(paper)

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


func _make_paper(gutter_side: float) -> ColorRect:
	var paper := ColorRect.new()
	paper.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var material := _make_shader_material(PARCHMENT_SHADER)
	material.set_shader_parameter("gutter_side", gutter_side)
	paper.material = material
	return paper


func _make_shader_material(code: String) -> ShaderMaterial:
	var shader := Shader.new()
	shader.code = code
	var material := ShaderMaterial.new()
	material.shader = shader
	return material


func _make_effect() -> EmberInkEffect:
	var effect := EmberInkEffect.new()
	effect.trail = REVEAL_TRAIL
	effect.ink = INK
	effect.ember = EMBER
	effect.heat = HEAT
	return effect


func _make_title() -> Label:
	var title := UiTheme.label("", BLOOD, TITLE_FONT_SIZE)
	title.uppercase = true
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if _book_font != null:
		var engraved := FontVariation.new()
		engraved.base_font = _book_font
		engraved.spacing_glyph = TITLE_LETTER_SPACING
		title.add_theme_font_override("font", engraved)
	return title


func _make_body(effect: EmberInkEffect) -> RichTextLabel:
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
	var number := UiTheme.label("", INK_FAINT, NUMBER_FONT_SIZE)
	number.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	number.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if _book_font != null:
		number.add_theme_font_override("font", _book_font)
	return number


func _make_book_font() -> Font:
	var font := SystemFont.new()
	font.font_names = PackedStringArray(BOOK_FONT_NAMES)
	return font


# Embers rising from below the screen behind the book, additive so they glow.
func _make_embers() -> CPUParticles2D:
	var embers := CPUParticles2D.new()
	embers.emitting = false
	embers.amount = 70
	embers.lifetime = 7.0
	embers.preprocess = 7.0
	embers.emission_shape = CPUParticles2D.EMISSION_SHAPE_RECTANGLE
	embers.direction = Vector2(0, -1)
	embers.spread = 20.0
	embers.gravity = Vector2(0, -10)
	embers.initial_velocity_min = 25.0
	embers.initial_velocity_max = 75.0
	embers.tangential_accel_min = -10.0
	embers.tangential_accel_max = 10.0
	embers.scale_amount_min = 0.15
	embers.scale_amount_max = 0.45

	var glow := Gradient.new()
	glow.set_color(0, Color(1.0, 1.0, 1.0, 1.0))
	glow.set_color(1, Color(1.0, 1.0, 1.0, 0.0))
	var dot := GradientTexture2D.new()
	dot.gradient = glow
	dot.fill = GradientTexture2D.FILL_RADIAL
	dot.fill_from = Vector2(0.5, 0.5)
	dot.fill_to = Vector2(1.0, 0.5)
	dot.width = 24
	dot.height = 24
	embers.texture = dot

	var ramp := Gradient.new()
	ramp.offsets = PackedFloat32Array([0.0, 0.12, 0.65, 1.0])
	ramp.colors = PackedColorArray([
		Color(1.0, 0.75, 0.35, 0.0),
		Color(1.0, 0.55, 0.20, 0.95),
		Color(0.80, 0.16, 0.05, 0.6),
		Color(0.35, 0.04, 0.02, 0.0),
	])
	embers.color_ramp = ramp

	var additive := CanvasItemMaterial.new()
	additive.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	embers.material = additive
	return embers


func _place_embers() -> void:
	var view := get_viewport().get_visible_rect().size
	_embers.position = Vector2(view.x * 0.5, view.y + 12.0)
	_embers.emission_rect_extents = Vector2(view.x * 0.5, 12.0)


# A rule broken by a diamond, under the chapter title.
class _Ornament extends Control:
	var color := Color.BLACK

	func _draw() -> void:
		var mid := size / 2.0
		var r := 4.0
		draw_line(Vector2(size.x * 0.2, mid.y), Vector2(mid.x - r * 2.5, mid.y), color, 1.0, true)
		draw_line(Vector2(mid.x + r * 2.5, mid.y), Vector2(size.x * 0.8, mid.y), color, 1.0, true)
		draw_colored_polygon(PackedVector2Array([
			mid + Vector2(0, -r), mid + Vector2(r, 0), mid + Vector2(0, r), mid + Vector2(-r, 0),
		]), color)


# Riveted iron brackets on the four corners of the cover.
class _CoverIron extends Control:
	const ARM := 54.0
	const WIDTH := 9.0
	const OUTSET := 7.0

	func _draw() -> void:
		var rivets: Array[Vector2] = [
			Vector2(WIDTH, WIDTH) * 0.5, Vector2(ARM - WIDTH * 0.7, WIDTH * 0.5), Vector2(WIDTH * 0.5, ARM - WIDTH * 0.7),
		]
		var corners: Array[Vector2] = [Vector2(0, 0), Vector2(1, 0), Vector2(0, 1), Vector2(1, 1)]
		for corner in corners:
			# Points from the corner into the cover.
			var inward := Vector2(1.0 - corner.x * 2.0, 1.0 - corner.y * 2.0)
			var origin := corner * size - inward * OUTSET
			_bar(origin, Vector2(inward.x * ARM, inward.y * WIDTH))
			_bar(origin, Vector2(inward.x * WIDTH, inward.y * ARM))
			for rivet in rivets:
				draw_circle(origin + inward * rivet, 2.2, StoryBook3D.IRON_RIVET)

	func _bar(origin: Vector2, extent: Vector2) -> void:
		var rect := Rect2(origin, extent).abs()
		draw_rect(rect.grow(1.0), StoryBook3D.IRON_SHADE)
		draw_rect(rect, StoryBook3D.IRON)
