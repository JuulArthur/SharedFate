class_name CharacterScreen3D
extends CanvasLayer

## The character screen (K), which replaced the skill tree
## (docs/cards-and-attributes.md). One soul at a time, picked by the tabs at the
## top, in three columns:
##
## - Attributes: the soul's mana or stamina and its Power, Energy and Finesse,
##   raised with the body's shared attribute points (anywhere, any time).
## - Skills: the soul's skill slots; pick one to edit it, or take it apart.
## - Forge: the card collection and a workbench. Cards clicked in the
##   collection go on the bench, the preview shows what they make for this
##   soul, and Forge puts them in the picked slot. Forging and taking apart
##   only work at a rest point: the coordinator's gate (`set_forge_gate`)
##   answers why not, or "" when the body stands by a campfire or waystone.
##
## Reads and writes the player's Progression3D. A full-screen modal that
## swallows clicks while open, like the inventory screen.

signal visibility_changed_to(open: bool)

const COLUMN_ATTRIBUTES := 300.0
const COLUMN_SKILLS := 330.0
const COLUMN_FORGE := 470.0
const BODY_HEIGHT := 630.0
const SOUL_KINDS: Array[int] = [Soul.Kind.KNIGHT, Soul.Kind.ROGUE, Soul.Kind.MAGE]

var _progression: Progression3D = null
var _forge_gate: Callable = Callable()
var _root: Control = null
var _points_label: Label = null
var _tabs: HBoxContainer = null
var _body: HBoxContainer = null
var _open := false
var _soul_kind: int = Soul.Kind.KNIGHT
var _edit_slot := 0
var _bench: Array[StringName] = []


func setup(progression: Progression3D) -> void:
	_progression = progression
	if _progression == null:
		return
	if not _progression.changed.is_connected(_rebuild):
		_progression.changed.connect(_rebuild)
	if not _progression.pools_changed.is_connected(_rebuild):
		_progression.pools_changed.connect(_rebuild)


## `gate` returns why forging is refused here, or "" when it is allowed.
func set_forge_gate(gate: Callable) -> void:
	_forge_gate = gate


func _ready() -> void:
	layer = 12
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_frame()
	_root.visible = false


func is_open() -> bool:
	return _open


func toggle() -> void:
	set_open(not _open)


## Opens on `soul_kind` when it is given (the soul in control).
func set_open(open: bool, soul_kind: int = -1) -> void:
	_open = open
	if _root == null:
		return
	if open and soul_kind >= 0:
		select_soul(soul_kind)
	_root.visible = open
	if open:
		_rebuild()
	visibility_changed_to.emit(open)


func select_soul(soul_kind: int) -> void:
	if _soul_kind != soul_kind:
		_soul_kind = soul_kind
		_bench.clear()
		_edit_slot = _first_free_slot()
	_rebuild()


func get_selected_soul() -> int:
	return _soul_kind


func get_bench() -> Array[StringName]:
	return _bench.duplicate()


## Why forging is refused right now ("" when it is allowed).
func forge_gate_reason() -> String:
	if not _forge_gate.is_valid():
		return ""
	return String(_forge_gate.call())


func _unhandled_input(event: InputEvent) -> void:
	if not _open:
		return
	var key := event as InputEventKey
	var close_key := key != null and key.pressed and not key.echo and key.physical_keycode == KEY_K
	if event.is_action_pressed("ui_cancel") or close_key:
		set_open(false)
		get_viewport().set_input_as_handled()


# --- Frame ---------------------------------------------------------------------

func _build_frame() -> void:
	_root = Control.new()
	_root.name = "CharacterScreen"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)

	var dim := ColorRect.new()
	dim.color = UiTheme.SCREEN_DIM
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_child(center)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", UiTheme.box(UiTheme.PANEL_BG, UiTheme.PANEL_BORDER, 2, 16, 12))
	center.add_child(panel)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	panel.add_child(vbox)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 16)
	vbox.add_child(header)
	header.add_child(UiTheme.title_plate("The Bound Three"))
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)
	_points_label = UiTheme.label("", UiTheme.TITLE, 17)
	header.add_child(_points_label)
	var close := Button.new()
	close.text = "Close (K)"
	UiTheme.style_button(close, 14)
	close.pressed.connect(set_open.bind(false))
	header.add_child(close)

	_tabs = HBoxContainer.new()
	_tabs.add_theme_constant_override("separation", 8)
	vbox.add_child(_tabs)
	vbox.add_child(UiTheme.rule())

	_body = HBoxContainer.new()
	_body.add_theme_constant_override("separation", 18)
	_body.custom_minimum_size = Vector2(0.0, BODY_HEIGHT)
	vbox.add_child(_body)


func _rebuild() -> void:
	if _body == null or not _open or _progression == null:
		return
	_points_label.text = "Level %d   |   Attribute points: %d   |   Cards: %d" \
		% [_progression.get_level(), _progression.attribute_points, _progression.total_cards()]
	for child in _tabs.get_children():
		child.queue_free()
	for kind in SOUL_KINDS:
		_tabs.add_child(_soul_tab(kind))
	for child in _body.get_children():
		child.queue_free()
	_body.add_child(_attributes_column())
	_body.add_child(_skills_column())
	_body.add_child(_forge_column())


func _soul_tab(kind: int) -> Control:
	var soul: Soul = Soul.all()[kind]
	var tab := Button.new()
	tab.text = "%s  -  %s" % [soul.title, soul.display_name]
	tab.toggle_mode = true
	tab.button_pressed = kind == _soul_kind
	tab.custom_minimum_size = Vector2(200, 34)
	UiTheme.style_button(tab, 14)
	tab.add_theme_color_override("font_color", soul.color)
	tab.add_theme_color_override("font_pressed_color", soul.color.lightened(0.3))
	tab.pressed.connect(select_soul.bind(kind))
	return tab


# --- Attributes -------------------------------------------------------------------

func _attributes_column() -> Control:
	var column := _column(COLUMN_ATTRIBUTES, "Attributes")
	var soul: Soul = Soul.all()[_soul_kind]
	var pool_name := Progression3D.resource_name(_soul_kind)
	var pool := UiTheme.label("%s  %d / %d   (+%d a turn)" % [pool_name, _progression.get_pool(_soul_kind),
		_progression.pool_max(_soul_kind), _progression.pool_regen(_soul_kind)], soul.color, 15)
	column.add_child(pool)
	var note := UiTheme.label("Points are shared by the three souls: what one soul gets, the others do without.",
		UiTheme.MUTED, 12)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(note)
	for attribute in Progression3D.ATTRIBUTES:
		column.add_child(_attribute_card(attribute))
	return column


func _attribute_card(attribute: StringName) -> Control:
	var value := _progression.get_attribute(_soul_kind, attribute)
	var reason := _progression.attribute_block_reason(_soul_kind, attribute)
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", UiTheme.box(UiTheme.SLOT_BG if value > 0 else UiTheme.SLOT_EMPTY_BG,
		UiTheme.WORN_BORDER if value > 0 else UiTheme.SLOT_BORDER, 1, 8, 6))
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 3)
	card.add_child(vbox)
	var row := HBoxContainer.new()
	vbox.add_child(row)
	row.add_child(UiTheme.label(Progression3D.attribute_name(attribute), UiTheme.TEXT, 15))
	var fill := Control.new()
	fill.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(fill)
	row.add_child(UiTheme.label("%d / %d" % [value, Progression3D.MAX_ATTRIBUTE], UiTheme.TITLE, 13))
	var raise := Button.new()
	raise.text = "+"
	raise.custom_minimum_size = Vector2(30, 26)
	raise.disabled = not reason.is_empty()
	raise.tooltip_text = "Raise (1 point)" if reason.is_empty() else reason
	UiTheme.style_button(raise, 15)
	raise.pressed.connect(_on_raise_pressed.bind(attribute))
	row.add_child(raise)
	var text := UiTheme.label(Progression3D.attribute_text(_soul_kind, attribute), UiTheme.MUTED, 12)
	text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(text)
	return card


# --- Skills -------------------------------------------------------------------------

func _skills_column() -> Control:
	var column := _column(COLUMN_SKILLS, "Skills")
	var hint := UiTheme.label("Pick a slot, then build it in the forge. Keys 4-%d use them." \
		% (3 + SkillCards3D.SKILLS_PER_SOUL), UiTheme.MUTED, 12)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(hint)
	for slot in range(SkillCards3D.SKILLS_PER_SOUL):
		column.add_child(_skill_card(slot))
	return column


func _skill_card(slot: int) -> Control:
	var ability := _progression.skill_ability(_soul_kind, slot)
	var picked := slot == _edit_slot
	var card := PanelContainer.new()
	var border := ActionSlot3D.COLOR_AIM if picked else (ability.color if ability != null else UiTheme.SLOT_EMPTY_BORDER)
	card.add_theme_stylebox_override("panel", UiTheme.box(UiTheme.SLOT_SELECTED if picked else UiTheme.SLOT_BG,
		border, 2 if picked else 1, 8, 6))
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 3)
	card.add_child(vbox)
	var title := "%d  %s" % [slot + 4, ability.display_name if ability != null else "Empty slot"]
	vbox.add_child(UiTheme.label(title, ability.color if ability != null else UiTheme.MUTED, 15))
	if ability != null:
		vbox.add_child(UiTheme.label(ability.summary(), UiTheme.MUTED, 11))
		var description := UiTheme.label(ability.description, UiTheme.TEXT, 12)
		description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		vbox.add_child(description)
		vbox.add_child(UiTheme.label(_cards_line(ability.cards), UiTheme.MUTED, 11))
	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 6)
	vbox.add_child(buttons)
	var pick := Button.new()
	pick.text = "Editing" if picked else ("Edit" if ability != null else "Build here")
	pick.disabled = picked
	UiTheme.style_button(pick, 12)
	pick.pressed.connect(_on_pick_slot.bind(slot))
	buttons.add_child(pick)
	if ability != null:
		var gate := forge_gate_reason()
		var dismantle := Button.new()
		dismantle.text = "Take apart"
		dismantle.disabled = not gate.is_empty()
		dismantle.tooltip_text = "Return the cards to your collection" if gate.is_empty() else gate
		UiTheme.style_button(dismantle, 12)
		dismantle.pressed.connect(_on_dismantle.bind(slot))
		buttons.add_child(dismantle)
	return card


# --- Forge ------------------------------------------------------------------------------

func _forge_column() -> Control:
	var column := _column(COLUMN_FORGE, "Forge")
	var gate := forge_gate_reason()
	var status := UiTheme.label("By the fire: forge away." if gate.is_empty() else gate,
		UiTheme.WORN_BORDER if gate.is_empty() else CombatFx.COLOR_WARNING, 13)
	column.add_child(status)

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.custom_minimum_size = Vector2(COLUMN_FORGE, 345.0)
	column.add_child(scroll)
	var collection := VBoxContainer.new()
	collection.add_theme_constant_override("separation", 4)
	# The scroll gives its child no width of its own; the flows need one to wrap.
	collection.custom_minimum_size = Vector2(COLUMN_FORGE - 16.0, 0.0)
	collection.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(collection)
	for category in [SkillCards3D.Category.TYPE, SkillCards3D.Category.ELEMENT, SkillCards3D.Category.MODIFIER]:
		collection.add_child(UiTheme.label(SkillCards3D.category_name(category).to_upper(), UiTheme.MUTED, 11))
		var row := HFlowContainer.new()
		row.add_theme_constant_override("h_separation", 5)
		row.add_theme_constant_override("v_separation", 5)
		collection.add_child(row)
		for card_id in SkillCards3D.ids_in(category):
			var free := free_copies(card_id)
			var tile := CardTile3D.new()
			tile.setup(card_id, free)
			tile.disabled = free <= 0 or _bench.size() >= SkillCards3D.MAX_CARDS_PER_SKILL
			tile.pressed.connect(_on_collection_card.bind(card_id))
			row.add_child(tile)

	column.add_child(UiTheme.rule())
	column.add_child(UiTheme.label("WORKBENCH  (slot %d, click a card to take it off)" % (_edit_slot + 4), UiTheme.MUTED, 11))
	var bench := HBoxContainer.new()
	bench.add_theme_constant_override("separation", 5)
	column.add_child(bench)
	for i in range(SkillCards3D.MAX_CARDS_PER_SKILL):
		var tile := CardTile3D.new()
		if i < _bench.size():
			tile.setup(_bench[i])
			tile.pressed.connect(_on_bench_card.bind(i))
		else:
			tile.setup(&"")
			tile.disabled = true
		bench.add_child(tile)

	var preview := _progression.preview_skill(_soul_kind, _bench)
	var problem := CardSkillCompiler3D.validate(_bench)
	if preview != null:
		column.add_child(UiTheme.label(preview.display_name, preview.color, 16))
		column.add_child(UiTheme.label(preview.summary(), UiTheme.MUTED, 11))
		var description := UiTheme.label(preview.description, UiTheme.TEXT, 12)
		description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		description.custom_minimum_size = Vector2(COLUMN_FORGE, 0.0)
		column.add_child(description)
	else:
		column.add_child(UiTheme.label(problem if not _bench.is_empty() else "Pick cards: one type, then elements and modifiers.",
			UiTheme.MUTED, 13))

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 8)
	column.add_child(buttons)
	var forge := Button.new()
	var reason := _progression.forge_block_reason(_soul_kind, _edit_slot, _bench) if not _bench.is_empty() else "Empty bench"
	if reason.is_empty():
		reason = gate
	forge.text = "Forge into slot %d" % (_edit_slot + 4)
	forge.disabled = not reason.is_empty()
	forge.tooltip_text = reason
	UiTheme.style_button(forge, 14)
	forge.pressed.connect(_on_forge)
	buttons.add_child(forge)
	var clear := Button.new()
	clear.text = "Clear"
	clear.disabled = _bench.is_empty()
	UiTheme.style_button(clear, 14)
	clear.pressed.connect(_on_clear)
	buttons.add_child(clear)
	return column


## Copies of `card_id` still free for the bench: the collection's, plus the
## ones in the slot being edited (forging over it returns them), minus the ones
## already on the bench.
func free_copies(card_id: StringName) -> int:
	var free := _progression.card_count(card_id)
	for slot_card in _progression.get_skill_cards(_soul_kind, _edit_slot):
		if slot_card == card_id:
			free += 1
	for bench_card in _bench:
		if bench_card == card_id:
			free -= 1
	return free


# --- Actions ------------------------------------------------------------------------------

func _on_raise_pressed(attribute: StringName) -> void:
	_progression.raise_attribute(_soul_kind, attribute)


func _on_pick_slot(slot: int) -> void:
	_edit_slot = slot
	_bench = _progression.get_skill_cards(_soul_kind, slot)
	_rebuild()


## Puts a card from the collection on the bench.
func add_to_bench(card_id: StringName) -> bool:
	if _bench.size() >= SkillCards3D.MAX_CARDS_PER_SKILL or free_copies(card_id) <= 0:
		return false
	_bench.append(card_id)
	_rebuild()
	return true


func _on_collection_card(card_id: StringName) -> void:
	add_to_bench(card_id)


func _on_bench_card(index: int) -> void:
	if index >= 0 and index < _bench.size():
		_bench.remove_at(index)
		_rebuild()


func _on_clear() -> void:
	_bench.clear()
	_rebuild()


## Forges the bench into the slot being edited. True when it did.
func forge_bench() -> bool:
	if not forge_gate_reason().is_empty():
		return false
	if not _progression.forge_skill(_soul_kind, _edit_slot, _bench):
		return false
	var ability := _progression.skill_ability(_soul_kind, _edit_slot)
	if ability != null:
		CombatFx.announce("FORGED: %s" % ability.display_name.to_upper(), ability.color, 0.8)
	_bench = _progression.get_skill_cards(_soul_kind, _edit_slot)
	_rebuild()
	return true


func _on_forge() -> void:
	forge_bench()


func _on_dismantle(slot: int) -> void:
	if not forge_gate_reason().is_empty():
		return
	if _progression.dismantle_skill(_soul_kind, slot) and slot == _edit_slot:
		_bench.clear()
		_rebuild()


# --- Helpers ------------------------------------------------------------------------------

func _column(width: float, title: String) -> VBoxContainer:
	var column := VBoxContainer.new()
	column.custom_minimum_size = Vector2(width, 0.0)
	column.add_theme_constant_override("separation", 8)
	column.add_child(UiTheme.label(title, UiTheme.TITLE, 17))
	return column


func _cards_line(cards: Array[StringName]) -> String:
	var names: Array[String] = []
	for card_id in cards:
		names.append(SkillCards3D.display_name(card_id))
	return "Cards: " + ", ".join(names)


func _first_free_slot() -> int:
	if _progression == null:
		return 0
	for slot in range(SkillCards3D.SKILLS_PER_SOUL):
		if _progression.get_skill_cards(_soul_kind, slot).is_empty():
			return slot
	return 0
