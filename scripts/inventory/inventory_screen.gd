extends Node

# Autoloaded singleton. The full-screen inventory: everything the character
# carries on the left, everything they are wearing on the right.
#
# An autoload for the same reason as `LootMenu` — the inventory belongs to the
# player, not to any one level, and each level scene has its own root script.
# It also owns the `toggle_inventory` action so the key binding lives next to
# the screen it opens.
#
# Layout mirrors the reference mockup: title plate, category tabs and a scrolling
# item grid on the left; a character figure ringed by equipment slots on the
# right, with a stat strip beneath it; Back to Game along the bottom.

const FIGURE_TEXTURE_PATH := "res://assets/player/knight_south.png"

# Fallback grid shape, used until the bag well has been laid out and its real
# size is known. After that the grid fills whatever room it has.
const GRID_COLUMNS := 8
const GRID_ROWS := 7
const GRID_SEPARATION := 6
const GRID_MIN_HEIGHT := 260.0
const SLOT_SIZE := Vector2(52, 52)
const SLOT_ICON_SIZE := Vector2(38, 38)
const EQUIP_SLOT_SIZE := Vector2(60, 60)
const EQUIP_ICON_SIZE := Vector2(44, 44)
const FIGURE_SIZE := Vector2(200, 300)

const TAB_ALL: StringName = &"all"
const TAB_OTHER: StringName = &"other"
const TABS := [
	{"label": "ALL", "filter": TAB_ALL},
	{"label": "WEAPONS", "filter": Item.CATEGORY_WEAPON},
	{"label": "ARMOR", "filter": Item.CATEGORY_ARMOR},
	{"label": "POTIONS", "filter": Item.CATEGORY_CONSUMABLE},
	{"label": "OTHER", "filter": TAB_OTHER},
]
# Categories the OTHER tab excludes; anything else lands there.
const KNOWN_CATEGORIES := [Item.CATEGORY_WEAPON, Item.CATEGORY_ARMOR, Item.CATEGORY_CONSUMABLE]

# Where each equipment slot sits around the figure.
const LEFT_COLUMN_SLOTS := [Item.SLOT_NECK, Item.SLOT_MAIN_HAND, Item.SLOT_TRINKET]
const RIGHT_COLUMN_SLOTS := [Item.SLOT_CHEST, Item.SLOT_OFF_HAND]
const BOTTOM_ROW_SLOTS := [Item.SLOT_LEGS, Item.SLOT_FEET, Item.SLOT_BACK]

var _layer: CanvasLayer
var _backdrop: ColorRect
var _tab_buttons: Array[Button] = []
var _scroll: ScrollContainer
var _grid: GridContainer
var _refreshing := false
var _detail_name: Label
var _detail_body: Label
var _action_button: Button
var _stats_label: Label
var _figure: TextureRect
# slot id -> the Button showing what is worn there.
var _equipment_slots: Dictionary = {}

var _player: Node = null
var _inventory: Inventory = null
var _selected: Item = null
var _active_filter: StringName = TAB_ALL


func _ready() -> void:
	_ensure_input_action()
	_build_ui()


func is_open() -> bool:
	return _backdrop != null and _backdrop.visible


# --- Public API ------------------------------------------------------------

func toggle() -> void:
	if is_open():
		close()
	else:
		open()


func open() -> void:
	if not _resolve_player():
		return
	_active_filter = TAB_ALL
	_selected = null
	_backdrop.visible = true
	_refresh()


func close() -> void:
	if _backdrop != null:
		_backdrop.visible = false


func _input(event: InputEvent) -> void:
	# The loot panel sits above this one; let it have the keys while it is up.
	if LootMenu.is_open():
		return

	if event.is_action_pressed("toggle_inventory"):
		toggle()
		get_viewport().set_input_as_handled()
		return

	if not is_open():
		return

	if event.is_action_pressed("ui_cancel"):
		close()
		get_viewport().set_input_as_handled()
		return

	# While the screen is up it owns the keyboard, so gameplay keys (attack,
	# block, end turn) don't fire behind it. The backdrop already blocks the
	# mouse.
	if event is InputEventKey:
		get_viewport().set_input_as_handled()


func _ensure_input_action() -> void:
	if not InputMap.has_action("toggle_inventory"):
		InputMap.add_action("toggle_inventory")

	for e in InputMap.action_get_events("toggle_inventory"):
		if e is InputEventKey and e.physical_keycode == KEY_I:
			return

	var key_event := InputEventKey.new()
	key_event.physical_keycode = KEY_I
	InputMap.action_add_event("toggle_inventory", key_event)


# --- Model -----------------------------------------------------------------

func _resolve_player() -> bool:
	var players := get_tree().get_nodes_in_group("player")
	if players.is_empty():
		return false

	var player: Node = players[0]
	if player == _player and _inventory != null and is_instance_valid(_inventory):
		return true

	_player = player
	_inventory = player.get("inventory") as Inventory
	if _inventory == null:
		_inventory = player.get_node_or_null("Inventory") as Inventory
	if _inventory == null:
		return false

	# Keep the screen honest if loot arrives or gear changes while it is open.
	for signal_name in ["item_added", "item_removed", "equipment_changed"]:
		if not _inventory.is_connected(signal_name, _on_inventory_changed):
			_inventory.connect(signal_name, _on_inventory_changed)
	return true


func _on_inventory_changed(_a: Variant = null, _b: Variant = null) -> void:
	if is_open():
		_refresh()


func _visible_items() -> Array[Item]:
	var result: Array[Item] = []
	if _inventory == null:
		return result

	for item in _inventory.items:
		if item == null:
			continue
		if _active_filter == TAB_ALL:
			result.append(item)
			continue
		var category := item.get_category()
		if _active_filter == TAB_OTHER:
			if not KNOWN_CATEGORIES.has(category):
				result.append(item)
		elif category == _active_filter:
			result.append(item)
	return result


# --- UI --------------------------------------------------------------------

func _build_ui() -> void:
	_layer = CanvasLayer.new()
	_layer.name = "InventoryScreenLayer"
	# Below the loot panel (layer 7) — loot is a transient interruption and
	# should sit on top when both are somehow up.
	_layer.layer = 6
	add_child(_layer)

	# Dims the world and swallows clicks so nothing reaches the level beneath.
	_backdrop = ColorRect.new()
	_backdrop.name = "InventoryScreen"
	_backdrop.visible = false
	_backdrop.color = UiTheme.SCREEN_DIM
	_backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	_backdrop.mouse_filter = Control.MOUSE_FILTER_STOP
	_layer.add_child(_backdrop)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 28)
	margin.add_theme_constant_override("margin_top", 24)
	margin.add_theme_constant_override("margin_right", 28)
	margin.add_theme_constant_override("margin_bottom", 20)
	_backdrop.add_child(margin)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 12)
	margin.add_child(root)

	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 16)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root.add_child(body)

	body.add_child(_build_bag_panel())
	body.add_child(_build_action_column())
	body.add_child(_build_character_panel())

	var footer := CenterContainer.new()
	root.add_child(footer)

	var back_button := Button.new()
	back_button.text = "BACK TO GAME"
	back_button.custom_minimum_size = Vector2(240, 40)
	UiTheme.style_button(back_button, 16)
	back_button.pressed.connect(close)
	footer.add_child(back_button)


func _build_bag_panel() -> Control:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override("panel", UiTheme.box(UiTheme.PANEL_BG, UiTheme.PANEL_BORDER, 2))

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_top", 14)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_bottom", 14)
	panel.add_child(margin)

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	margin.add_child(column)

	column.add_child(UiTheme.title_plate("INVENTORY"))
	column.add_child(_build_tabs())
	column.add_child(UiTheme.rule())

	var well := PanelContainer.new()
	well.size_flags_vertical = Control.SIZE_EXPAND_FILL
	well.add_theme_stylebox_override("panel", UiTheme.box(UiTheme.WELL_BG, UiTheme.SLOT_BORDER, 1, 8, 8))
	column.add_child(well)

	_scroll = ScrollContainer.new()
	_scroll.custom_minimum_size = Vector2(0, GRID_MIN_HEIGHT)
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	# The bag fills whatever room the window gives it, so re-shape the grid
	# whenever that room changes.
	_scroll.resized.connect(_on_grid_area_resized)
	well.add_child(_scroll)

	_grid = GridContainer.new()
	_grid.columns = GRID_COLUMNS
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_grid.add_theme_constant_override("h_separation", GRID_SEPARATION)
	_grid.add_theme_constant_override("v_separation", GRID_SEPARATION)
	_scroll.add_child(_grid)
	return panel


func _build_tabs() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	_tab_buttons.clear()

	for i in TABS.size():
		if i > 0:
			row.add_child(UiTheme.label("|", UiTheme.RULE, 15))

		var tab := Button.new()
		tab.text = String(TABS[i]["label"])
		tab.flat = true
		tab.focus_mode = Control.FOCUS_NONE
		tab.add_theme_font_size_override("font_size", 15)
		tab.pressed.connect(_on_tab_pressed.bind(StringName(TABS[i]["filter"])))
		row.add_child(tab)
		_tab_buttons.append(tab)
	return row


# The narrow middle column: item details and the equip/unequip action, sitting
# between the bag and the character exactly as in the mockup.
func _build_action_column() -> Control:
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	column.custom_minimum_size = Vector2(210, 0)
	column.alignment = BoxContainer.ALIGNMENT_CENTER

	var detail_panel := PanelContainer.new()
	detail_panel.add_theme_stylebox_override("panel", UiTheme.box(UiTheme.PANEL_BG, UiTheme.PANEL_BORDER, 2, 12, 10))
	column.add_child(detail_panel)

	var detail_box := VBoxContainer.new()
	detail_box.add_theme_constant_override("separation", 6)
	detail_panel.add_child(detail_box)

	_detail_name = UiTheme.label("", UiTheme.TITLE, 16)
	_detail_name.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	detail_box.add_child(_detail_name)

	_detail_body = UiTheme.label("", UiTheme.MUTED, 13)
	_detail_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	detail_box.add_child(_detail_body)

	_action_button = Button.new()
	_action_button.text = "EQUIP ITEM  →"
	_action_button.custom_minimum_size = Vector2(0, 48)
	UiTheme.style_button(_action_button, 16)
	_action_button.pressed.connect(_on_action_pressed)
	column.add_child(_action_button)
	return column


func _build_character_panel() -> Control:
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 10)
	column.alignment = BoxContainer.ALIGNMENT_CENTER

	var head_row := CenterContainer.new()
	head_row.add_child(_build_equipment_slot(Item.SLOT_HEAD))
	column.add_child(head_row)

	var middle := HBoxContainer.new()
	middle.add_theme_constant_override("separation", 14)
	middle.alignment = BoxContainer.ALIGNMENT_CENTER
	column.add_child(middle)

	var left := VBoxContainer.new()
	left.add_theme_constant_override("separation", 10)
	left.alignment = BoxContainer.ALIGNMENT_CENTER
	for slot in LEFT_COLUMN_SLOTS:
		left.add_child(_build_equipment_slot(slot))
	middle.add_child(left)

	_figure = UiTheme.icon_rect(_load_figure_texture(), FIGURE_SIZE)
	_figure.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	middle.add_child(_figure)

	var right := VBoxContainer.new()
	right.add_theme_constant_override("separation", 10)
	right.alignment = BoxContainer.ALIGNMENT_CENTER
	for slot in RIGHT_COLUMN_SLOTS:
		right.add_child(_build_equipment_slot(slot))
	var rings := HBoxContainer.new()
	rings.add_theme_constant_override("separation", 8)
	rings.add_child(_build_equipment_slot(Item.SLOT_RING_LEFT))
	rings.add_child(_build_equipment_slot(Item.SLOT_RING_RIGHT))
	right.add_child(rings)
	middle.add_child(right)

	var bottom := HBoxContainer.new()
	bottom.add_theme_constant_override("separation", 12)
	bottom.alignment = BoxContainer.ALIGNMENT_CENTER
	for slot in BOTTOM_ROW_SLOTS:
		bottom.add_child(_build_equipment_slot(slot))
	column.add_child(bottom)

	var stats_panel := PanelContainer.new()
	stats_panel.add_theme_stylebox_override("panel", UiTheme.box(UiTheme.PANEL_BG, UiTheme.PANEL_BORDER, 2, 14, 8))
	_stats_label = UiTheme.label("", UiTheme.TEXT, 15)
	stats_panel.add_child(_stats_label)
	column.add_child(stats_panel)
	return column


# One equipment slot: the plate itself with its name on a small tab below.
func _build_equipment_slot(slot: StringName) -> Control:
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 2)
	column.alignment = BoxContainer.ALIGNMENT_CENTER

	var button := Button.new()
	button.custom_minimum_size = EQUIP_SLOT_SIZE
	button.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	UiTheme.style_slot(button, false)
	button.pressed.connect(_on_equipment_slot_pressed.bind(slot))
	column.add_child(button)
	_equipment_slots[slot] = button

	var name_plate := PanelContainer.new()
	name_plate.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	name_plate.add_theme_stylebox_override("panel", UiTheme.box(UiTheme.WELL_BG, UiTheme.SLOT_EMPTY_BORDER, 1, 6, 1))
	name_plate.add_child(UiTheme.label(Item.slot_display_name(slot), UiTheme.MUTED, 12))
	column.add_child(name_plate)
	return column


func _load_figure_texture() -> Texture2D:
	if not ResourceLoader.exists(FIGURE_TEXTURE_PATH):
		push_warning("InventoryScreen: character art not found at %s" % FIGURE_TEXTURE_PATH)
		return null

	var texture := load(FIGURE_TEXTURE_PATH) as Texture2D
	if texture == null:
		return null

	# The world sprite is mostly transparent padding, which would scale down to
	# a tiny knight in the middle of the figure box. Show only the drawn pixels.
	var used := texture.get_image().get_used_rect()
	if used.size == Vector2i.ZERO or used.size == Vector2i(texture.get_size()):
		return texture

	var atlas := AtlasTexture.new()
	atlas.atlas = texture
	atlas.region = Rect2(used)
	return atlas


# --- Refresh ---------------------------------------------------------------

func _refresh() -> void:
	if _inventory == null or _refreshing:
		return
	_refreshing = true

	var shown := _visible_items()
	if _selected != null and not _inventory.items.has(_selected):
		_selected = null

	_refresh_tabs()
	_refresh_grid(shown)
	_refresh_equipment()
	_refresh_detail()
	_refresh_stats()
	_refreshing = false


func _refresh_tabs() -> void:
	for i in _tab_buttons.size():
		var is_active: bool = StringName(TABS[i]["filter"]) == _active_filter
		_tab_buttons[i].add_theme_color_override("font_color", UiTheme.TITLE if is_active else UiTheme.MUTED)
		_tab_buttons[i].add_theme_color_override("font_hover_color", UiTheme.TITLE)


func _refresh_grid(shown: Array[Item]) -> void:
	for child in _grid.get_children():
		child.queue_free()

	var columns := _grid_columns()
	_grid.columns = columns

	for item in shown:
		_grid.add_child(_build_item_slot(item))

	# Pad with empty slots so the bag fills its panel rather than trailing off
	# into dead space, and always ends on a complete row.
	var padded := maxi(_grid_rows() * columns, _ceil_to_row(shown.size(), columns))
	for i in range(shown.size(), padded):
		_grid.add_child(_build_empty_slot(SLOT_SIZE))


func _grid_columns() -> int:
	var cell := SLOT_SIZE.x + float(GRID_SEPARATION)
	if _scroll == null or _scroll.size.x < cell:
		return GRID_COLUMNS
	return clampi(int(_scroll.size.x / cell), 4, 14)


func _grid_rows() -> int:
	var cell := SLOT_SIZE.y + float(GRID_SEPARATION)
	if _scroll == null or _scroll.size.y < cell:
		return GRID_ROWS
	return maxi(1, int(_scroll.size.y / cell))


func _ceil_to_row(count: int, columns: int) -> int:
	if count <= 0:
		return 0
	return int(ceil(float(count) / float(columns))) * columns


func _on_grid_area_resized() -> void:
	# Re-shaping the grid can't change the well's own size, but guard anyway so
	# a layout quirk can never turn into a refresh loop.
	if is_open() and not _refreshing:
		_refresh()


func _build_item_slot(item: Item) -> Control:
	var slot := Button.new()
	slot.custom_minimum_size = SLOT_SIZE
	slot.tooltip_text = _tooltip_for(item)
	# Worn items keep their place in the bag; a green edge is what says the item
	# is also sitting in a slot on the right.
	UiTheme.style_slot(slot, item == _selected, _inventory != null and _inventory.is_equipped(item))
	slot.pressed.connect(_on_item_pressed.bind(item))
	# Double-click equips, for players who don't want the two-step.
	slot.gui_input.connect(_on_item_gui_input.bind(item))
	slot.add_child(UiTheme.icon_rect(item.icon, SLOT_ICON_SIZE))
	return slot


func _build_empty_slot(size: Vector2) -> Control:
	var slot := Panel.new()
	slot.custom_minimum_size = size
	slot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	slot.add_theme_stylebox_override("panel", UiTheme.box(UiTheme.SLOT_EMPTY_BG, UiTheme.SLOT_EMPTY_BORDER, 1))
	return slot


func _refresh_equipment() -> void:
	for slot in _equipment_slots:
		var button: Button = _equipment_slots[slot]
		for child in button.get_children():
			child.queue_free()

		var item := _inventory.get_equipped(slot)
		UiTheme.style_slot(button, item != null and item == _selected, item != null)
		button.disabled = item == null
		button.tooltip_text = _tooltip_for(item) if item != null else Item.slot_display_name(slot)
		if item != null:
			button.add_child(UiTheme.icon_rect(item.icon, EQUIP_ICON_SIZE))


func _refresh_detail() -> void:
	if _selected == null:
		_detail_name.text = "Nothing Selected"
		_detail_name.add_theme_color_override("font_color", UiTheme.MUTED)
		_detail_body.text = "Pick something from the bag or a worn slot."
		_action_button.text = "EQUIP ITEM  →"
		_action_button.disabled = true
		return

	_detail_name.text = _selected.display_name.to_upper()
	_detail_name.add_theme_color_override("font_color", UiTheme.TITLE)

	var lines: Array[String] = [_stat_line(_selected)]
	if _inventory.is_equipped(_selected):
		lines.append("Worn: %s" % Item.slot_display_name(_inventory.get_slot_of(_selected)))
	if _selected.description != "":
		lines.append(_selected.description)
	_detail_body.text = "\n\n".join(lines)

	if _inventory.is_equipped(_selected):
		_action_button.text = "←  UNEQUIP"
		_action_button.disabled = false
	else:
		_action_button.text = "EQUIP ITEM  →"
		_action_button.disabled = not _selected.is_equippable()


func _refresh_stats() -> void:
	var character_name := "Adventurer"
	if _player.get("character_name") != null:
		character_name = String(_player.get("character_name"))

	var level := 1
	if _player.has_method("get_player_level"):
		level = int(_player.call("get_player_level"))

	var damage := 0
	if _player.has_method("get_melee_damage"):
		damage = int(_player.call("get_melee_damage"))

	var current_hp := 0
	var max_hp := 0
	if _player.get("current_health") != null:
		current_hp = int(_player.get("current_health"))
	if _player.get("max_health") != null:
		max_hp = int(_player.get("max_health"))

	var gold := 0
	if _player.get("gold") != null:
		gold = int(_player.get("gold"))

	_stats_label.text = "CHARACTER: %s (Lvl %d)  |  DMG: %d  |  DEF: %d  |  HP: %d/%d  |  Gold: %d" % [
		character_name.to_upper(), level, damage, _inventory.get_total_armor(),
		current_hp, max_hp, gold,
	]


func _stat_line(item: Item) -> String:
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
		return "NO STATS"
	return "  ·  ".join(parts)


func _tooltip_for(item: Item) -> String:
	var worn := "  (Worn)" if _inventory != null and _inventory.is_equipped(item) else ""
	return "%s%s\n%s" % [item.display_name, worn, _stat_line(item)]


# --- Signal handlers -------------------------------------------------------

func _on_tab_pressed(filter: StringName) -> void:
	_active_filter = filter
	_refresh()


func _on_item_pressed(item: Item) -> void:
	_selected = item
	_refresh()


func _on_item_gui_input(event: InputEvent, item: Item) -> void:
	if event is InputEventMouseButton \
			and event.button_index == MOUSE_BUTTON_LEFT \
			and event.double_click:
		_selected = item
		_toggle_equipped(item)


func _on_equipment_slot_pressed(slot: StringName) -> void:
	_selected = _inventory.get_equipped(slot)
	_refresh()


func _on_action_pressed() -> void:
	if _selected != null:
		_toggle_equipped(_selected)


func _toggle_equipped(item: Item) -> void:
	if _inventory.is_equipped(item):
		_inventory.unequip(_inventory.get_slot_of(item))
	elif item.is_equippable():
		_inventory.equip(item)
	_refresh()
