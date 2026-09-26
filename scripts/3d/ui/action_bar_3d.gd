class_name ActionBar3D
extends VBoxContainer

## The one action bar at the bottom of the screen: icon slots in captioned
## groups (Attacks, Spells, Skills, Utility, Turn) with a rule between groups,
## and an info line above the panel naming the hovered slot, or the aimed one.
##
## The bar only lays slots out. The coordinator (`main_3d.gd`) creates the
## slots, wires their presses and sets their state every frame, then calls
## `refresh()`, which hides empty groups and updates the info line.

const GROUP_ATTACKS := &"attacks"
const GROUP_SPELLS := &"spells"
const GROUP_SKILLS := &"skills"
const GROUP_UTILITY := &"utility"
const GROUP_TURN := &"turn"

const GROUPS: Array[Dictionary] = [
	{"key": GROUP_ATTACKS, "caption": "Attacks"},
	{"key": GROUP_SPELLS, "caption": "Spells"},
	{"key": GROUP_SKILLS, "caption": "Skills"},
	{"key": GROUP_UTILITY, "caption": "Utility"},
	{"key": GROUP_TURN, "caption": "Turn"},
]

var panel: PanelContainer
var info_label: Label
var _groups: Dictionary = {}   # key -> {"box": VBoxContainer, "row": HBoxContainer, "rule": Control}
var _group_order: Array[StringName] = []
var _hovered: ActionSlot3D


func _init() -> void:
	name = "ActionBar"
	anchor_left = 0.5
	anchor_right = 0.5
	anchor_top = 1.0
	anchor_bottom = 1.0
	offset_left = 0.0
	offset_right = 0.0
	offset_top = -18.0
	offset_bottom = -18.0
	grow_horizontal = Control.GROW_DIRECTION_BOTH
	grow_vertical = Control.GROW_DIRECTION_BEGIN
	alignment = BoxContainer.ALIGNMENT_END
	add_theme_constant_override("separation", 6)
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	info_label = UiTheme.label("", UiTheme.TITLE, 15)
	info_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	info_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	info_label.add_theme_constant_override("outline_size", 6)
	info_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	info_label.visible = false
	add_child(info_label)

	panel = PanelContainer.new()
	panel.name = "TurnActionsUI"
	panel.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	panel.add_theme_stylebox_override("panel", UiTheme.box(UiTheme.PANEL_BG, UiTheme.PANEL_BORDER, 2, 12, 6))
	add_child(panel)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	panel.add_child(row)

	for spec in GROUPS:
		var key: StringName = spec["key"]
		var rule := ColorRect.new()
		rule.color = UiTheme.RULE
		rule.custom_minimum_size = Vector2(1, 0)
		rule.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(rule)

		var box := VBoxContainer.new()
		box.add_theme_constant_override("separation", 3)
		row.add_child(box)
		var title := UiTheme.label(String(spec["caption"]).to_upper(), UiTheme.MUTED, 10)
		title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		title.mouse_filter = Control.MOUSE_FILTER_IGNORE
		box.add_child(title)
		var slots := HBoxContainer.new()
		slots.alignment = BoxContainer.ALIGNMENT_CENTER
		slots.add_theme_constant_override("separation", 5)
		box.add_child(slots)

		_groups[key] = {"box": box, "row": slots, "rule": rule}
		_group_order.append(key)
	refresh()


## Creates a slot in `group`, at the end or at `index`. `toggle` makes it an
## aim toggle.
func add_slot(group: StringName, icon_key: StringName, caption: String, accent: Color,
		toggle: bool = false, index: int = -1) -> ActionSlot3D:
	var slot := ActionSlot3D.new()
	slot.icon_key = icon_key
	slot.caption = caption
	slot.accent = accent
	slot.toggle_mode = toggle
	slot.aims = toggle
	slot.hover_changed.connect(_on_slot_hover_changed)
	var row := _groups[group]["row"] as HBoxContainer
	row.add_child(slot)
	if index >= 0:
		row.move_child(slot, mini(index, row.get_child_count() - 1))
	return slot


## Takes a slot off the bar and frees it (the learned abilities are rebuilt
## when they change).
func remove_slot(slot: ActionSlot3D) -> void:
	if slot == null or not is_instance_valid(slot):
		return
	if slot == _hovered:
		_hovered = null
	if slot.get_parent() != null:
		slot.get_parent().remove_child(slot)
	slot.queue_free()


func get_slots(group: StringName) -> Array[ActionSlot3D]:
	var result: Array[ActionSlot3D] = []
	for child in (_groups[group]["row"] as HBoxContainer).get_children():
		if child is ActionSlot3D:
			result.append(child)
	return result


func is_group_visible(group: StringName) -> bool:
	return (_groups[group]["box"] as Control).visible


## Hides groups with no visible slot (and their rules), and refreshes the info
## line. Call after setting the slots' state.
func refresh() -> void:
	var any_before := false
	for key in _group_order:
		var entry: Dictionary = _groups[key]
		var shown := false
		for child in (entry["row"] as HBoxContainer).get_children():
			if (child as Control).visible:
				shown = true
				break
		(entry["box"] as Control).visible = shown
		(entry["rule"] as Control).visible = shown and any_before
		any_before = any_before or shown
	_update_info()


func _on_slot_hover_changed(slot: ActionSlot3D, hovered: bool) -> void:
	if hovered:
		_hovered = slot
	elif _hovered == slot:
		_hovered = null
	_update_info()


func _update_info() -> void:
	if info_label == null:
		return
	var slot := _hovered
	var aiming := false
	if slot == null or not is_instance_valid(slot) or not slot.is_visible_in_tree():
		slot = _find_aimed_slot()
		aiming = slot != null
	if slot == null:
		info_label.visible = false
		return
	var text := slot.caption
	if not slot.detail.is_empty():
		text += "  |  " + slot.detail
	if aiming:
		text += "  -  click a target"
	info_label.text = text
	info_label.visible = true


func _find_aimed_slot() -> ActionSlot3D:
	for key in _group_order:
		for slot in get_slots(key):
			if slot.visible and slot.aims and slot.button_pressed:
				return slot
	return null
