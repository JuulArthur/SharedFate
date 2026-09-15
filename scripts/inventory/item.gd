class_name Item
extends Resource

# Flexible item definition for weapons, consumables, etc.
# Core weapon properties are first-class, and `properties` is a free-form
# dictionary that lets us attach new stats later (crit chance, status effects,
# durability, spell costs, etc.) without changing this class.

enum WeaponType { MELEE, RANGED, MAGIC }

# Animation archetypes — the *motion* a weapon uses, independent of its skin.
# Many weapons share an archetype (all one-handed swords share MELEE_SLASH).
# To add a new motion you author one new archetype animation and every weapon
# that picks it inherits the motion. See CODEBASE_GUIDE.md > "Weapon animations".
const ARCHETYPE_MELEE_SLASH := &"melee_slash"
const ARCHETYPE_MELEE_THRUST := &"melee_thrust"
const ARCHETYPE_MELEE_CHOP := &"melee_chop"
const ARCHETYPE_RANGED_BOW := &"ranged_bow"
const ARCHETYPE_CAST_STAFF := &"cast_staff"
const ARCHETYPE_UNARMED := &"unarmed"

# Item category. Stored inside `properties` rather than as its own field so new
# categories (armour, quest item, ...) never require changing this class. Items
# that don't declare one are treated as weapons, which keeps every pre-existing
# item working unchanged.
const PROPERTY_CATEGORY := &"category"
const CATEGORY_WEAPON := &"weapon"
const CATEGORY_CONSUMABLE := &"consumable"
const CATEGORY_ARMOR := &"armor"
const CATEGORY_ACCESSORY := &"accessory"

# Which equipment slot this item occupies, and how much armour it contributes.
# Both live in `properties` for the same reason as the category: new gear kinds
# never require touching this class. An item with no slot simply can't be worn.
const PROPERTY_EQUIP_SLOT := &"equip_slot"
const PROPERTY_ARMOR := &"armor"

# Equipment slots a character has. `Inventory.SLOTS` lists them in the order the
# UI lays them out; an item names exactly one of them.
const SLOT_HEAD := &"head"
const SLOT_NECK := &"neck"
const SLOT_CHEST := &"chest"
const SLOT_BACK := &"back"
const SLOT_MAIN_HAND := &"main_hand"
const SLOT_OFF_HAND := &"off_hand"
const SLOT_LEGS := &"legs"
const SLOT_FEET := &"feet"
const SLOT_RING_LEFT := &"ring_left"
const SLOT_RING_RIGHT := &"ring_right"
const SLOT_TRINKET := &"trinket"

@export var id: StringName = &""
@export var display_name: String = "Unnamed Item"
@export var description: String = ""
@export var icon: Texture2D
@export var damage: int = 0
@export var weapon_type: WeaponType = WeaponType.MELEE
# Attack range in world units (pixels). Use the same scale as
# Player.attack_range so combat logic can read this directly.
@export var weapon_range: float = 0.0

# Which shared motion this weapon plays (see ARCHETYPE_* constants).
@export var animation_archetype: StringName = ARCHETYPE_MELEE_SLASH
# Optional override — when non-empty, the player plays this animation name
# instead of `animation_archetype`. Use for signature/boss weapons with a
# bespoke animation; leave empty for the common 95% case.
@export var animation_override: StringName = &""
# Where the weapon sprite sits inside the player's hand holder. Lets you
# fine-tune fit per weapon (e.g. daggers sit lower, two-handers offset up)
# without touching the shared animation.
@export var grip_offset: Vector2 = Vector2.ZERO
# Static rotation of the weapon sprite relative to the hand, in degrees.
# Independent of any swing rotation that the animation applies to the holder.
@export var grip_rotation_deg: float = 0.0

@export var properties: Dictionary = {}


func get_property(key: StringName, default_value: Variant = null) -> Variant:
	return properties.get(key, default_value)


func has_property(key: StringName) -> bool:
	return properties.has(key)


func set_property(key: StringName, value: Variant) -> void:
	properties[key] = value


func get_category() -> StringName:
	return properties.get(PROPERTY_CATEGORY, CATEGORY_WEAPON)


func is_weapon() -> bool:
	return get_category() == CATEGORY_WEAPON


# The slot this item is worn in, or &"" when it isn't wearable. Weapons default
# to the main hand so every pre-existing weapon stays equippable unchanged.
func get_equip_slot() -> StringName:
	var slot: StringName = properties.get(PROPERTY_EQUIP_SLOT, &"")
	if slot == &"" and is_weapon():
		return SLOT_MAIN_HAND
	return slot


func is_equippable() -> bool:
	return get_equip_slot() != &""


func get_armor() -> int:
	return int(properties.get(PROPERTY_ARMOR, 0))


# Rings fit either hand, so a ring declares one ring slot and this reports the
# whole set of slots it may go in.
func get_compatible_slots() -> Array[StringName]:
	var slot := get_equip_slot()
	if slot == &"":
		return []
	if slot == SLOT_RING_LEFT or slot == SLOT_RING_RIGHT:
		return [SLOT_RING_LEFT, SLOT_RING_RIGHT]
	return [slot]


static func slot_display_name(slot: StringName) -> String:
	match slot:
		SLOT_HEAD: return "Head"
		SLOT_NECK: return "Neck"
		SLOT_CHEST: return "Chest"
		SLOT_BACK: return "Back"
		SLOT_MAIN_HAND: return "Right Hand (Primary)"
		SLOT_OFF_HAND: return "Left Hand (Secondary)"
		SLOT_LEGS: return "Legs"
		SLOT_FEET: return "Feet"
		SLOT_RING_LEFT, SLOT_RING_RIGHT: return "Ring"
		SLOT_TRINKET: return "Trinket"
	return "Slot"


static func weapon_type_name(t: int) -> String:
	match t:
		WeaponType.MELEE: return "Melee"
		WeaponType.RANGED: return "Ranged"
		WeaponType.MAGIC: return "Magic"
	return "Unknown"
