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
# script. The UI is built in code to match the rest of the project's panels
# (see `main.gd::_setup_inventory_ui`).

# How close the player must be to loot. Comfortably beyond melee reach (an
# iron sword swings at 40) so arriving at an item always counts as arriving.
const LOOT_RANGE := 56.0
# An approach that stalls this long without getting in reach is abandoned —
# the path was blocked, or a turn's movement budget ran out short of the item.
const APPROACH_GIVE_UP_SECONDS := 1.2

const PANEL_MIN_WIDTH := 320.0
const ICON_SIZE := Vector2(28, 28)

const COLOR_TITLE := Color(0.88, 0.78, 0.53, 1.0)
const COLOR_TEXT := Color(0.86, 0.86, 0.84, 1.0)
const COLOR_MUTED := Color(0.62, 0.60, 0.56, 1.0)

var _layer: CanvasLayer
var _backdrop: Control
var _panel: PanelContainer
var _rows: VBoxContainer
var _take_all_button: Button

# Pickups currently listed in the panel, and who is doing the looting.
var _pile: Array[Node2D] = []
var _looter: Node = null

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
	# Merge rather than replace: the player can stroll into a second pickup
	# while the panel is already up.
	for pickup in pickups:
		var node := pickup as Node2D
		if node == null or _pile.has(node):
			continue
		_pile.append(node)

	_prune_pile()
	if _pile.is_empty():
		return

	_panel.visible = true
	_backdrop.visible = true
	_refresh()


func close() -> void:
	_pile.clear()
	_looter = null
	if _panel != null:
		_panel.visible = false
	if _backdrop != null:
		_backdrop.visible = false


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

	if pickup.call("take", inventory):
		_pile.erase(pickup)

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
	_panel.custom_minimum_size = Vector2(PANEL_MIN_WIDTH, 0)
	_panel.add_theme_stylebox_override("panel", _make_panel_style())
	center.add_child(_panel)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 14)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_right", 14)
	margin.add_theme_constant_override("margin_bottom", 12)
	_panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	margin.add_child(vbox)

	var title := Label.new()
	title.text = "LOOT"
	title.add_theme_color_override("font_color", COLOR_TITLE)
	vbox.add_child(title)

	var separator := ColorRect.new()
	separator.color = Color(0.52, 0.44, 0.28, 0.85)
	separator.custom_minimum_size = Vector2(0, 1)
	vbox.add_child(separator)

	_rows = VBoxContainer.new()
	_rows.add_theme_constant_override("separation", 6)
	vbox.add_child(_rows)

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 4)
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vbox.add_child(spacer)

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 6)
	vbox.add_child(buttons)

	_take_all_button = Button.new()
	_take_all_button.text = "Take All"
	_take_all_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_take_all_button.focus_mode = Control.FOCUS_NONE
	_take_all_button.pressed.connect(_take_all)
	buttons.add_child(_take_all_button)

	var close_button := Button.new()
	close_button.text = "Close"
	close_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	close_button.focus_mode = Control.FOCUS_NONE
	close_button.pressed.connect(close)
	buttons.add_child(close_button)

	var hint := Label.new()
	hint.text = "Esc or click away to leave the rest"
	hint.add_theme_color_override("font_color", COLOR_MUTED)
	hint.add_theme_font_size_override("font_size", 12)
	vbox.add_child(hint)


func _make_panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.07, 0.05, 0.92)
	style.border_color = Color(0.66, 0.56, 0.33, 0.95)
	style.border_width_left = 2
	style.border_width_top = 2
	style.border_width_right = 2
	style.border_width_bottom = 2
	style.corner_radius_top_left = 4
	style.corner_radius_top_right = 4
	style.corner_radius_bottom_left = 4
	style.corner_radius_bottom_right = 4
	return style


func _refresh() -> void:
	if _rows == null:
		return

	for child in _rows.get_children():
		child.queue_free()

	for pickup in _pile:
		var item := pickup.get("item") as Item
		if item == null:
			continue
		_rows.add_child(_build_item_row(item, pickup))

	_take_all_button.disabled = _pile.is_empty()


func _build_item_row(item: Item, pickup: Node2D) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.tooltip_text = item.description

	var icon := TextureRect.new()
	icon.texture = item.icon
	icon.custom_minimum_size = ICON_SIZE
	icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	# Item art is hand-made pixel art; keep it crisp when scaled in the panel.
	icon.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	row.add_child(icon)

	var text_column := VBoxContainer.new()
	text_column.add_theme_constant_override("separation", 0)
	text_column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(text_column)

	var name_label := Label.new()
	name_label.text = item.display_name
	name_label.add_theme_color_override("font_color", COLOR_TEXT)
	text_column.add_child(name_label)

	var detail_label := Label.new()
	detail_label.text = _item_detail_text(item)
	detail_label.add_theme_color_override("font_color", COLOR_MUTED)
	detail_label.add_theme_font_size_override("font_size", 12)
	text_column.add_child(detail_label)

	var take_button := Button.new()
	take_button.text = "Take"
	take_button.focus_mode = Control.FOCUS_NONE
	take_button.pressed.connect(_take.bind(pickup))
	row.add_child(take_button)

	return row


func _item_detail_text(item: Item) -> String:
	if item.is_weapon() and item.damage > 0:
		return "%s  ·  %d dmg" % [Item.weapon_type_name(item.weapon_type), item.damage]

	var heal := int(item.get_property(&"heal_amount", 0))
	if heal > 0:
		return "Restores %d HP" % heal

	return item.description


func _on_backdrop_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		close()
		_backdrop.accept_event()
