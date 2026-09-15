class_name Inventory
extends Node

# Inventory container. Owns a list of items and tracks what the character is
# wearing, slot by slot. Emits signals so UI or the owning actor can react
# without polling.
#
# Equipped items stay in `items` — being worn is a property of the item, not a
# separate place it lives. That is what lets the inventory screen show a worn
# item in both the grid and its slot.
#
# The main hand doubles as the weapon slot, so the older weapon-only API
# (`equip_weapon`, `get_equipped_weapon`, `equipped_weapon_changed`) still works
# and stays in sync with `equipment`.

signal item_added(item: Item)
signal item_removed(item: Item)
signal equipped_weapon_changed(weapon: Item)
signal equipment_changed(slot: StringName, item: Item)

# Every slot the character has, in the order the inventory screen lays them out.
const SLOTS: Array[StringName] = [
	Item.SLOT_HEAD,
	Item.SLOT_NECK,
	Item.SLOT_CHEST,
	Item.SLOT_BACK,
	Item.SLOT_MAIN_HAND,
	Item.SLOT_OFF_HAND,
	Item.SLOT_LEGS,
	Item.SLOT_FEET,
	Item.SLOT_RING_LEFT,
	Item.SLOT_RING_RIGHT,
	Item.SLOT_TRINKET,
]

@export var items: Array[Item] = []

# slot (StringName) -> Item. Slots with nothing in them are simply absent.
var equipment: Dictionary = {}


func add_item(item: Item) -> void:
	if item == null:
		return
	items.append(item)
	item_added.emit(item)


func remove_item(item: Item) -> void:
	if item == null:
		return
	if not items.has(item):
		return
	items.erase(item)
	# Something you no longer carry can't still be worn.
	for slot in equipment.keys():
		if equipment[slot] == item:
			unequip(slot)
	item_removed.emit(item)


# --- Equipment -------------------------------------------------------------

# Wear `item` in the slot it declares, replacing whatever is there. Rings pick
# the first free ring slot. Returns the slot used, or &"" if it can't be worn.
func equip(item: Item) -> StringName:
	if item == null:
		return &""

	var slot := _choose_slot_for(item)
	if slot == &"":
		return &""

	# Equipping from outside the inventory is allowed; it just joins the bag.
	if not items.has(item):
		items.append(item)
		item_added.emit(item)

	_set_slot(slot, item)
	return slot


func unequip(slot: StringName) -> Item:
	if not equipment.has(slot):
		return null
	var removed: Item = equipment[slot]
	_set_slot(slot, null)
	return removed


func get_equipped(slot: StringName) -> Item:
	return equipment.get(slot, null)


func get_slot_of(item: Item) -> StringName:
	if item == null:
		return &""
	for slot in equipment:
		if equipment[slot] == item:
			return slot
	return &""


func is_equipped(item: Item) -> bool:
	return get_slot_of(item) != &""


func get_total_armor() -> int:
	var total := 0
	for slot in equipment:
		var item: Item = equipment[slot]
		if item != null:
			total += item.get_armor()
	return total


# --- Weapon API (main hand) ------------------------------------------------

func equip_weapon(item: Item) -> void:
	# Allow equipping null to unequip. Allow equipping items that aren't yet in
	# the inventory by auto-adding them; this keeps starter-weapon setup trivial.
	if item == null:
		unequip(Item.SLOT_MAIN_HAND)
		return

	if not items.has(item):
		items.append(item)
		item_added.emit(item)
	_set_slot(Item.SLOT_MAIN_HAND, item)


func get_equipped_weapon() -> Item:
	return equipment.get(Item.SLOT_MAIN_HAND, null)


func find_item_by_id(id: StringName) -> Item:
	for candidate in items:
		if candidate != null and candidate.id == id:
			return candidate
	return null


func size() -> int:
	return items.size()


# --- Internal --------------------------------------------------------------

func _choose_slot_for(item: Item) -> StringName:
	var candidates := item.get_compatible_slots()
	if candidates.is_empty():
		return &""
	# Prefer an empty slot (so a second ring goes on the other hand) and fall
	# back to the first, replacing what is worn there.
	for slot in candidates:
		if not equipment.has(slot):
			return slot
	return candidates[0]


func _set_slot(slot: StringName, item: Item) -> void:
	if item == null:
		equipment.erase(slot)
	else:
		equipment[slot] = item

	equipment_changed.emit(slot, item)
	if slot == Item.SLOT_MAIN_HAND:
		equipped_weapon_changed.emit(item)
