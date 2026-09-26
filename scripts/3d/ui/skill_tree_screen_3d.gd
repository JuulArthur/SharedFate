class_name SkillTreeScreen3D
extends CanvasLayer

## The skill tree (K): four columns - the knight's, the rogue's and the mage's
## abilities and the body's passives - where skill points from levelling are
## spent. Reads and writes the player's Progression3D; rebuilt whenever it
## changes. Created by the coordinator; a full-screen modal that swallows clicks
## while open, like the inventory screen.

signal visibility_changed_to(open: bool)

const COLUMN_WIDTH := 300.0

var _progression: Progression3D = null
var _root: Control = null
var _columns: HBoxContainer = null
var _points_label: Label = null
var _open := false


func setup(progression: Progression3D) -> void:
	_progression = progression
	if _progression != null and not _progression.changed.is_connected(_rebuild):
		_progression.changed.connect(_rebuild)


func _ready() -> void:
	layer = 12
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_frame()
	_root.visible = false


func is_open() -> bool:
	return _open


func toggle() -> void:
	set_open(not _open)


func set_open(open: bool) -> void:
	_open = open
	if _root == null:
		return
	_root.visible = open
	if open:
		_rebuild()
	visibility_changed_to.emit(open)


func _unhandled_input(event: InputEvent) -> void:
	if not _open:
		return
	var key := event as InputEventKey
	var close_key := key != null and key.pressed and not key.echo and key.physical_keycode == KEY_K
	if event.is_action_pressed("ui_cancel") or close_key:
		set_open(false)
		get_viewport().set_input_as_handled()


func _build_frame() -> void:
	_root = Control.new()
	_root.name = "SkillTree"
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
	header.add_child(UiTheme.title_plate("The Bound Three - Skills"))
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)
	_points_label = UiTheme.label("", UiTheme.TITLE, 18)
	header.add_child(_points_label)
	var close := Button.new()
	close.text = "Close (K)"
	UiTheme.style_button(close, 14)
	close.focus_mode = Control.FOCUS_NONE
	close.pressed.connect(set_open.bind(false))
	header.add_child(close)

	vbox.add_child(UiTheme.rule())
	var hint := UiTheme.label("Level up to earn skill points. Every soul starts with one ability; learn the rest here. The ability bar shows the learned abilities of the soul in control (keys 4-9).", UiTheme.MUTED, 13)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size = Vector2(COLUMN_WIDTH * 4.0, 0.0)
	vbox.add_child(hint)

	_columns = HBoxContainer.new()
	_columns.add_theme_constant_override("separation", 14)
	vbox.add_child(_columns)


func _rebuild() -> void:
	if _columns == null or not _open:
		return
	for child in _columns.get_children():
		child.queue_free()
	if _progression == null:
		return
	_points_label.text = "Level %d   |   Skill points: %d" % [_progression.get_level(), _progression.skill_points]
	for kind in [Soul.Kind.KNIGHT, Soul.Kind.ROGUE, Soul.Kind.MAGE]:
		_columns.add_child(_build_soul_column(kind))
	_columns.add_child(_build_passive_column())


func _build_soul_column(kind: int) -> Control:
	var soul: Soul = Soul.all()[kind]
	var column := _column_box()
	var title := UiTheme.label("%s  -  %s" % [soul.display_name, soul.title], soul.color, 17)
	column.add_child(title)
	var passive_text := ""
	match kind:
		Soul.Kind.KNIGHT:
			passive_text = "Moves 6 m. Takes 30 % less damage. A perfect Block ripostes."
		Soul.Kind.ROGUE:
			passive_text = "Moves 8 m. Sneak attacks deal triple. A kill refunds the action once a turn."
		Soul.Kind.MAGE:
			passive_text = "Moves 5 m. Frail, but hits groups and bends space."
	var passive_label := UiTheme.label(passive_text, UiTheme.MUTED, 12)
	passive_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(passive_label)
	for ability in AbilityCatalog3D.for_soul(kind):
		if ability.soul_kind != kind:
			continue
		column.add_child(_ability_card(ability))
	return column


func _build_passive_column() -> Control:
	var column := _column_box()
	column.add_child(UiTheme.label("The Body", UiTheme.TITLE, 17))
	var note := UiTheme.label("Shared by all three souls.", UiTheme.MUTED, 12)
	column.add_child(note)
	for def in Progression3D.PASSIVES:
		column.add_child(_passive_card(def))
	return column


func _column_box() -> VBoxContainer:
	var column := VBoxContainer.new()
	column.custom_minimum_size = Vector2(COLUMN_WIDTH, 0.0)
	column.add_theme_constant_override("separation", 8)
	return column


func _ability_card(ability: Ability3D) -> Control:
	var learned := _progression.is_learned(ability.id)
	var reason := _progression.learn_block_reason(ability.id)
	var card := PanelContainer.new()
	var border := ability.color if learned else UiTheme.SLOT_BORDER
	card.add_theme_stylebox_override("panel", UiTheme.box(UiTheme.SLOT_BG if learned else UiTheme.SLOT_EMPTY_BG, border, 1, 8, 6))
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 3)
	card.add_child(vbox)
	var name_row := HBoxContainer.new()
	vbox.add_child(name_row)
	name_row.add_child(UiTheme.label(ability.display_name, ability.color if learned else UiTheme.TEXT, 15))
	var fill := Control.new()
	fill.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_row.add_child(fill)
	name_row.add_child(UiTheme.label("Lv %d" % ability.unlock_level, UiTheme.MUTED, 12))
	vbox.add_child(UiTheme.label(ability.summary(), UiTheme.MUTED, 11))
	var description := UiTheme.label(ability.description, UiTheme.TEXT, 12)
	description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(description)
	if learned:
		vbox.add_child(UiTheme.label("Learned", UiTheme.WORN_BORDER, 12))
	else:
		var learn := Button.new()
		learn.focus_mode = Control.FOCUS_NONE
		learn.text = "Learn (1 point)" if reason.is_empty() else reason
		learn.disabled = not reason.is_empty()
		UiTheme.style_button(learn, 13)
		learn.pressed.connect(_on_learn_pressed.bind(ability.id))
		vbox.add_child(learn)
	return card


func _passive_card(def: Dictionary) -> Control:
	var passive_id: StringName = def["id"]
	var rank := _progression.get_passive_rank(passive_id)
	var max_rank := int(def["max_rank"])
	var reason := _progression.passive_block_reason(passive_id)
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", UiTheme.box(UiTheme.SLOT_BG if rank > 0 else UiTheme.SLOT_EMPTY_BG,
		UiTheme.WORN_BORDER if rank > 0 else UiTheme.SLOT_BORDER, 1, 8, 6))
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 3)
	card.add_child(vbox)
	var name_row := HBoxContainer.new()
	vbox.add_child(name_row)
	name_row.add_child(UiTheme.label(String(def["name"]), UiTheme.TEXT, 15))
	var fill := Control.new()
	fill.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_row.add_child(fill)
	name_row.add_child(UiTheme.label("%d / %d" % [rank, max_rank], UiTheme.TITLE, 13))
	var description := UiTheme.label("%s  (from level %d)" % [String(def["description"]), int(def["level"])], UiTheme.TEXT, 12)
	description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(description)
	if rank < max_rank:
		var raise := Button.new()
		raise.focus_mode = Control.FOCUS_NONE
		raise.text = "Raise (1 point)" if reason.is_empty() else reason
		raise.disabled = not reason.is_empty()
		UiTheme.style_button(raise, 13)
		raise.pressed.connect(_on_raise_pressed.bind(passive_id))
		vbox.add_child(raise)
	return card


func _on_learn_pressed(ability_id: StringName) -> void:
	if _progression != null and _progression.learn(ability_id):
		var ability := AbilityCatalog3D.get_ability(ability_id)
		CombatFx.announce("LEARNED: %s" % ability.display_name.to_upper(), ability.color, 0.8)


func _on_raise_pressed(passive_id: StringName) -> void:
	if _progression != null:
		_progression.raise_passive(passive_id)
