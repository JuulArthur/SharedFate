class_name Inventory
extends Node

# Simple inventory container. Owns a list of items and tracks which item
# (if any) is currently equipped as a weapon. Emits signals so UI or the
# owning actor can react without polling.

signal item_added(item: Item)
signal item_removed(item: Item)
signal equipped_weapon_changed(weapon: Item)

@export var items: Array[Item] = []

var equipped_weapon: Item = null


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
	if equipped_weapon == item:
		equip_weapon(null)
	item_removed.emit(item)


func equip_weapon(item: Item) -> void:
	# Allow equipping null to unequip. Allow equipping items that aren't yet
	# in the inventory by auto-adding them; this keeps starter-weapon setup
	# trivial for callers.
	if item != null and not items.has(item):
		items.append(item)
		item_added.emit(item)
	equipped_weapon = item
	equipped_weapon_changed.emit(item)


func get_equipped_weapon() -> Item:
	return equipped_weapon


func find_item_by_id(id: StringName) -> Item:
	for candidate in items:
		if candidate != null and candidate.id == id:
			return candidate
	return null


func size() -> int:
	return items.size()
