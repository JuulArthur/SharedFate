extends Node

# Autoloaded singleton. Shows the "what do you want to loot?" panel for a pile
# of `ItemPickup` nodes lying on the ground.
#
# Flow:
#   1. The player clicks a pickup lying on the ground (`scripts/item_pickup.gd`),
#      which calls `LootMenu.request_loot(pickup, player)`.
#   2. Within `LOOT_RANGE` the pile opens immediately. Further off the request
#      is remembered, the level's own click-to-move walks the player over, and
#      the pile opens the moment they are in reach.
#   3. The player takes individual items, takes everything, or closes the panel
#      and leaves the pile where it is.
#
# It lives as an autoload rather than inside `main.gd` because loot exists in
# every level scene (main, forest, castle) and each of those has its own root
# script.
#
# The panel is built in code and styled as a slot grid: category tabs, a grid
# of bordered item slots, a detail column for whatever is selected, and a
# footer strip. Selecting a slot shows the item; the Take button (or a
# double-click on the slot) moves it into the inventory.

# How close the player must be to loot. Comfortably beyond melee reach (an
# iron sword swings at 40) so arriving at an item always counts as arriving.
const LOOT_RANGE := 56.0
# An approach that stalls this long without getting in reach is abandoned —
# the path was blocked, or a turn's movement budget ran out short of the item.
const APPROACH_GIVE_UP_SECONDS := 1.2

# --- Layout ---
const GRID_COLUMNS := 5
# Empty slots are drawn up to this count so the grid keeps its shape whether
# the pile holds one item or a dozen, and so the grid stands about as tall as
# the detail column beside it.
const MIN_GRID_SLOTS := 15
const SLOT_SIZE := Vector2(56, 56)
const SLOT_ICON_SIZE := Vector2(40, 40)
const DETAIL_COLUMN_WIDTH := 196.0


# Category tabs: label plus the `Item` category it keeps (empty keeps all,
# `&"other"` keeps anything that isn't a known category).
const TAB_ALL: StringName = &"all"
const TAB_OTHER: StringName = &"other"
const TABS := [
	{"label": "ALL", "filter": TAB_ALL},
	{"label": "WEAPONS", "filter": Item.CATEGORY_WEAPON},
	{"label": "ARMOR", "filter": Item.CATEGORY_ARMOR},
	{"label": "POTIONS", "filter": Item.CATEGORY_CONSUMABLE},
	{"label": "OTHER", "filter": TAB_OTHER},
]

var _layer: CanvasLayer
var _backdrop: Control
var _panel: PanelContainer
var _grid: GridContainer
var _tab_buttons: Array[Button] = []
var _detail_name: Label
var _detail_body: Label
var _take_button: Button
var _take_all_button: Button
var _status_label: Label

# Pickups currently listed in the panel, and who is doing the looting.
var _pile: Array[Node2D] = []
var _looter: Node = null

# Pickups matching the active tab, in grid order, and which one is selected.
var _shown: Array[Node2D] = []
var _selected: Node2D = null
var _active_filter: StringName = TAB_ALL

# A pickup the player clicked from too far away and is now walking towards.
var _pending_pickup: Node2D = null
var _pending_looter: Node = null
var _pending_idle_time := 0.0


func _ready() -> void:
	_build_ui()


func is_open() -> bool:
	return _panel != null and _panel.visible


# --- Public API ------------------------------------------------------------

# Entry point for a click on a pickup. Returns true when the click was spent
# looting (the panel opened), false when the player is too far away — the
# caller must then leave the click unhandled so the level moves the player.
func request_loot(pickup: Node2D, looter: Node) -> bool:
	if pickup == null or looter == null:
		return false

	if _in_loot_range(looter, pickup):
		_clear_pending()
		open_for(pickup.gather_pile(), looter)
		return true

	_pending_pickup = pickup
	_pending_looter = looter
	_pending_idle_time = 0.0
	return false


func is_approaching() -> bool:
	return _pending_pickup != null


func open_for(pickups: Array, looter: Node) -> void:
	if pickups.is_empty() or looter == null:
		return

	_looter = looter
	# Merge rather than replace: a second pile can be clicked while the panel
	# is already up.
	for pickup in pickups:
		var node := pickup as Node2D
		if node == null or _pile.has(node):
			continue
		_pile.append(node)

	_prune_pile()
	if _pile.is_empty():
		return

	_active_filter = TAB_ALL
	_selected = _pile[0]
	_panel.visible = true
	_backdrop.visible = true
	_refresh()


func close() -> void:
	_pile.clear()
	_shown.clear()
	_looter = null
	_selected = null
	if _panel != null:
		_panel.visible = false
	if _backdrop != null:
		_backdrop.visible = false


# --- Approach --------------------------------------------------------------

func _process(delta: float) -> void:
	if _pending_pickup == null:
		return

	if not _pending_is_live():
		_clear_pending()
		return

	if _in_loot_range(_pending_looter, _pending_pickup):
		var pickup := _pending_pickup
		var looter := _pending_looter
		_clear_pending()
		open_for(pickup.gather_pile(), looter)
		return

	# Still out of reach: keep waiting only while the player is actually on
	# their way. Standing still means the approach isn't going to happen.
	if _is_moving(_pending_looter):
		_pending_idle_time = 0.0
		return
	_pending_idle_time += delta
	if _pending_idle_time >= APPROACH_GIVE_UP_SECONDS:
		_clear_pending()


func _in_loot_range(looter: Node, pickup: Node2D) -> bool:
	var looter_2d := looter as Node2D
	if looter_2d == null or pickup == null or not is_instance_valid(pickup):
		return false
	return looter_2d.global_position.distance_to(pickup.global_position) <= LOOT_RANGE


func _pending_is_live() -> bool:
	if _pending_looter == null or not is_instance_valid(_pending_looter):
		return false
	if not is_instance_valid(_pending_pickup) or not _pending_pickup.is_inside_tree():
		return false
	# Someone else may have taken it while we walked over.
	return _pending_pickup.has_method("is_available") and _pending_pickup.call("is_available")


func _is_moving(looter: Node) -> bool:
	return looter.has_method("is_moving") and bool(looter.call("is_moving"))


func _clear_pending() -> void:
	_pending_pickup = null
	_pending_looter = null
	_pending_idle_time = 0.0


func _input(event: InputEvent) -> void:
	# A new click is a new order, so it cancels any approach in progress. This
	# runs in the input phase, ahead of the unhandled phase where pickups read
	# clicks, so clicking a different item simply registers a fresh approach.
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		_clear_pending()

	if not is_open():
		return

	# Escape closes the pile. The inventory key is swallowed so the inventory
	# panel can't open underneath this one.
	if event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()
		return

	if InputMap.has_action("toggle_inventory") and event.is_action_pressed("toggle_inventory"):
		close()
		get_viewport().set_input_as_handled()


# --- Looting ---------------------------------------------------------------

func _take(pickup: Node2D) -> void:
	var inventory := _resolve_inventory()
	if inventory == null:
		return
	if not is_instance_valid(pickup) or not pickup.has_method("take"):
		_pile.erase(pickup)
		_refresh()
		return

	# Keep the selection where the player's eye is: the next item in the grid.
	var next_selection := _neighbour_of(pickup)
	if pickup.call("take", inventory):
		_pile.erase(pickup)
	_selected = next_selection

	_prune_pile()
	if _pile.is_empty():
		close()
		return
	_refresh()


func _take_all() -> void:
	var inventory := _resolve_inventory()
	if inventory == null:
		return

	for pickup in _pile.duplicate():
		if is_instance_valid(pickup) and pickup.has_method("take"):
			pickup.call("take", inventory)

	close()


func _resolve_inventory() -> Inventory:
	if _looter == null or not is_instance_valid(_looter):
		return null
	var inventory := _looter.get("inventory") as Inventory
	if inventory == null:
		inventory = _looter.get_node_or_null("Inventory") as Inventory
	return inventory


func _prune_pile() -> void:
	var live: Array[Node2D] = []
	for pickup in _pile:
		if not is_instance_valid(pickup) or not pickup.is_inside_tree():
			continue
		if pickup.has_method("is_available") and not pickup.call("is_available"):
			continue
		live.append(pickup)
	_pile = live


# The item that should take over the selection when `pickup` is removed.
func _neighbour_of(pickup: Node2D) -> Node2D:
	var index := _shown.find(pickup)
	if index == -1:
		return null
	if index + 1 < _shown.size():
		return _shown[index + 1]
	if index > 0:
		return _shown[index - 1]
	return null


# --- UI --------------------------------------------------------------------

func _build_ui() -> void:
	_layer = CanvasLayer.new()
	_layer.name = "LootMenuLayer"
	# Above the inventory panel (layer 6) so loot always reads as the topmost
	# thing the player is interacting with.
	_layer.layer = 7
	add_child(_layer)

	# Full-screen catcher: while the panel is up, clicks must not fall through
	# to the level's click-to-move handler. Clicking outside the panel closes.
	_backdrop = Control.new()
	_backdrop.name = "LootBackdrop"
	_backdrop.visible = false
	_backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	_backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	_backdrop.gui_input.connect(_on_backdrop_gui_input)
	_layer.add_child(_backdrop)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_backdrop.add_child(center)

	_panel = PanelContainer.new()
	_panel.name = "LootMenu"
	_panel.visible = false
	_panel.add_theme_stylebox_override("panel", UiTheme.box(UiTheme.PANEL_BG, UiTheme.PANEL_BORDER, 2))
	center.add_child(_panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_top", 14)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_bottom", 14)
	_panel.add_child(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 10)
	margin.add_child(root)

	root.add_child(UiTheme.title_plate("LOOT"))
	root.add_child(_build_tabs())
	root.add_child(UiTheme.rule())

	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 14)
	root.add_child(body)
	body.add_child(_build_grid_well())
	body.add_child(_build_detail_column())

	root.add_child(UiTheme.rule())
	root.add_child(_build_footer())




func _build_tabs() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	_tab_buttons.clear()

	for i in TABS.size():
		if i > 0:
			var divider := Label.new()
			divider.text = "|"
			divider.add_theme_color_override("font_color", UiTheme.RULE)
			row.add_child(divider)

		var tab := Button.new()
		tab.text = String(TABS[i]["label"])
		tab.flat = true
		tab.focus_mode = Control.FOCUS_NONE
		tab.add_theme_font_size_override("font_size", 15)
		tab.pressed.connect(_on_tab_pressed.bind(StringName(TABS[i]["filter"])))
		row.add_child(tab)
		_tab_buttons.append(tab)

	return row


func _build_grid_well() -> Control:
	var well := PanelContainer.new()
	well.add_theme_stylebox_override("panel", UiTheme.box(UiTheme.WELL_BG, UiTheme.SLOT_BORDER, 1, 8, 8))
	# Hug the slots instead of stretching to match the taller detail column.
	well.size_flags_vertical = Control.SIZE_SHRINK_BEGIN

	_grid = GridContainer.new()
	_grid.columns = GRID_COLUMNS
	_grid.add_theme_constant_override("h_separation", 6)
	_grid.add_theme_constant_override("v_separation", 6)
	well.add_child(_grid)
	return well


func _build_detail_column() -> Control:
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 8)
	column.custom_minimum_size = Vector2(DETAIL_COLUMN_WIDTH, 0)

	var detail_panel := PanelContainer.new()
	detail_panel.add_theme_stylebox_override("panel", UiTheme.box(UiTheme.WELL_BG, UiTheme.SLOT_BORDER, 1, 10, 8))
	detail_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(detail_panel)

	var detail_box := VBoxContainer.new()
	detail_box.add_theme_constant_override("separation", 4)
	detail_panel.add_child(detail_box)

	_detail_name = Label.new()
	_detail_name.add_theme_color_override("font_color", UiTheme.TITLE)
	_detail_name.add_theme_font_size_override("font_size", 16)
	_detail_name.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	detail_box.add_child(_detail_name)

	_detail_body = Label.new()
	_detail_body.add_theme_color_override("font_color", UiTheme.MUTED)
	_detail_body.add_theme_font_size_override("font_size", 13)
	_detail_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	detail_box.add_child(_detail_body)

	_take_button = Button.new()
	_take_button.text = "TAKE ITEM  →"
	_take_button.focus_mode = Control.FOCUS_NONE
	_take_button.custom_minimum_size = Vector2(0, 40)
	UiTheme.style_button(_take_button)
	_take_button.pressed.connect(_on_take_pressed)
	column.add_child(_take_button)
	return column


func _build_footer() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	_status_label = Label.new()
	_status_label.add_theme_color_override("font_color", UiTheme.MUTED)
	_status_label.add_theme_font_size_override("font_size", 13)
	_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(_status_label)

	_take_all_button = Button.new()
	_take_all_button.text = "TAKE ALL"
	_take_all_button.focus_mode = Control.FOCUS_NONE
	_take_all_button.custom_minimum_size = Vector2(110, 32)
	UiTheme.style_button(_take_all_button)
	_take_all_button.pressed.connect(_take_all)
	row.add_child(_take_all_button)

	var close_button := Button.new()
	close_button.text = "CLOSE"
	close_button.focus_mode = Control.FOCUS_NONE
	close_button.custom_minimum_size = Vector2(110, 32)
	UiTheme.style_button(close_button)
	close_button.pressed.connect(close)
	row.add_child(close_button)
	return row


func _refresh() -> void:
	_shown = _filtered_pile()
	if _selected != null and not _shown.has(_selected):
		_selected = null
	if _selected == null and not _shown.is_empty():
		_selected = _shown[0]

	_refresh_tabs()
	_refresh_grid()
	_refresh_detail()

	var count := _pile.size()
	_status_label.text = "%d item%s on the ground" % [count, "" if count == 1 else "s"]
	_take_all_button.disabled = _pile.is_empty()


func _filtered_pile() -> Array[Node2D]:
	if _active_filter == TAB_ALL:
		return _pile.duplicate()

	var known := [Item.CATEGORY_WEAPON, Item.CATEGORY_ARMOR, Item.CATEGORY_CONSUMABLE]
	var matching: Array[Node2D] = []
	for pickup in _pile:
		var item := pickup.get("item") as Item
		if item == null:
			continue
		var category := item.get_category()
		if _active_filter == TAB_OTHER:
			if not known.has(category):
				matching.append(pickup)
		elif category == _active_filter:
			matching.append(pickup)
	return matching


func _refresh_tabs() -> void:
	for i in _tab_buttons.size():
		var is_active: bool = StringName(TABS[i]["filter"]) == _active_filter
		_tab_buttons[i].add_theme_color_override("font_color", UiTheme.TITLE if is_active else UiTheme.MUTED)
		_tab_buttons[i].add_theme_color_override("font_hover_color", UiTheme.TITLE)


func _refresh_grid() -> void:
	for child in _grid.get_children():
		child.queue_free()

	for pickup in _shown:
		var item := pickup.get("item") as Item
		if item == null:
			continue
		_grid.add_child(_build_slot(item, pickup))

	# Pad out with empty slots so the grid keeps a steady shape.
	var target_slots: int = maxi(MIN_GRID_SLOTS, _ceil_to_row(_shown.size()))
	for i in range(_shown.size(), target_slots):
		_grid.add_child(_build_empty_slot())


func _ceil_to_row(count: int) -> int:
	if count <= 0:
		return 0
	return int(ceil(float(count) / float(GRID_COLUMNS))) * GRID_COLUMNS


func _build_slot(item: Item, pickup: Node2D) -> Control:
	var slot := Button.new()
	slot.custom_minimum_size = SLOT_SIZE
	slot.tooltip_text = "%s\n%s" % [item.display_name, _item_detail_text(item)]

	UiTheme.style_slot(slot, pickup == _selected)
	slot.pressed.connect(_on_slot_pressed.bind(pickup))
	# Double-click takes straight away, for players who don't want the two-step.
	slot.gui_input.connect(_on_slot_gui_input.bind(pickup))

	var icon := TextureRect.new()
	icon.texture = item.icon
	icon.set_anchors_preset(Control.PRESET_FULL_RECT)
	icon.custom_minimum_size = SLOT_ICON_SIZE
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	# Item art is hand-made pixel art; keep it crisp when scaled in the panel.
	icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	slot.add_child(icon)
	return slot


func _build_empty_slot() -> Control:
	var slot := Panel.new()
	slot.custom_minimum_size = SLOT_SIZE
	slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	slot.add_theme_stylebox_override("panel", UiTheme.box(UiTheme.SLOT_EMPTY_BG, UiTheme.SLOT_EMPTY_BORDER, 1))
	return slot


func _refresh_detail() -> void:
	var item: Item = null
	if _selected != null and is_instance_valid(_selected):
		item = _selected.get("item") as Item

	if item == null:
		_detail_name.text = "No item selected"
		_detail_name.add_theme_color_override("font_color", UiTheme.MUTED)
		_detail_body.text = "Pick a slot to see what it is."
		_take_button.disabled = true
		return

	_detail_name.text = item.display_name.to_upper()
	_detail_name.add_theme_color_override("font_color", UiTheme.TITLE)

	var lines: Array[String] = [_item_detail_text(item)]
	if item.description != "":
		lines.append(item.description)
	_detail_body.text = "\n\n".join(lines)
	_take_button.disabled = false


func _item_detail_text(item: Item) -> String:
	var parts: Array[String] = []
	if item.is_weapon() and item.damage > 0:
		parts.append("%s  ·  +%d DMG" % [Item.weapon_type_name(item.weapon_type).to_upper(), item.damage])
	if item.get_armor() > 0:
		parts.append("+%d DEF" % item.get_armor())
	var heal := int(item.get_property(&"heal_amount", 0))
	if heal > 0:
		parts.append("RESTORES %d HP" % heal)
	if item.is_equippable():
		parts.append(Item.slot_display_name(item.get_equip_slot()).to_upper())
	if parts.is_empty():
		return item.description
	return "  ·  ".join(parts)


# --- Signal handlers -------------------------------------------------------

func _on_tab_pressed(filter: StringName) -> void:
	_active_filter = filter
	_refresh()


func _on_slot_pressed(pickup: Node2D) -> void:
	_selected = pickup
	_refresh()


func _on_slot_gui_input(event: InputEvent, pickup: Node2D) -> void:
	if event is InputEventMouseButton \
			and event.button_index == MOUSE_BUTTON_LEFT \
			and event.double_click:
		_take(pickup)


func _on_take_pressed() -> void:
	if _selected != null:
		_take(_selected)


func _on_backdrop_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		close()
		_backdrop.accept_event()
