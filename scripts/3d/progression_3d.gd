class_name Progression3D
extends Node

## The body's growth (docs/cards-and-attributes.md). A child of the player named
## "Progression". It holds two things:
##
## 1. Attributes, per soul. Every level up grants attribute points; each point
##    goes to one soul's Power, Energy or Finesse, so the three souls compete for
##    them. Each soul reads an attribute its own way (see `attribute_text`).
## 2. Skill cards and the skills forged from them. Cards drop from enemies and
##    chests into the collection; up to SkillCards3D.SKILLS_PER_SOUL skills per
##    soul are forged from them (at a campfire or waystone, which the
##    coordinator checks) and compiled by CardSkillCompiler3D.
##
## It also keeps each soul's mana or stamina pool, which card skills spend and
## which refills a little every turn.

signal changed
## Mana or stamina moved; separate from `changed` so a spend does not recompile.
signal pools_changed
signal card_added(card_id: StringName)

const STARTING_ATTRIBUTE_POINTS := 3
const ATTRIBUTE_POINTS_PER_LEVEL := 3
const MAX_ATTRIBUTE := 10
## Every level up raises the body's maximum health by this much by itself.
const HEALTH_PER_LEVEL := 8

const ATTR_POWER := &"power"
const ATTR_ENERGY := &"energy"
const ATTR_FINESSE := &"finesse"
const ATTRIBUTES: Array[StringName] = [ATTR_POWER, ATTR_ENERGY, ATTR_FINESSE]

const POWER_DAMAGE_PER_POINT := 0.10
const ENERGY_POOL_PER_POINT := 8
## Every this many Energy points add one to the pool's refill per turn.
const ENERGY_POINTS_PER_REGEN := 2
const KNIGHT_FINESSE_DEFENCE_PER_POINT := 0.05
const ROGUE_FINESSE_MOVE_PER_POINT := 0.5
const MAGE_FINESSE_RANGE_PER_POINT := 0.5
const MAGE_FINESSE_RADIUS_PER_POINT := 0.25

const POOL_BASE := {Soul.Kind.KNIGHT: 30, Soul.Kind.ROGUE: 30, Soul.Kind.MAGE: 40}
const REGEN_BASE := {Soul.Kind.KNIGHT: 6, Soul.Kind.ROGUE: 8, Soul.Kind.MAGE: 8}
const SOUL_KINDS: Array[int] = [Soul.Kind.KNIGHT, Soul.Kind.ROGUE, Soul.Kind.MAGE]

var attribute_points := STARTING_ATTRIBUTE_POINTS
var _level := 1
var _attributes: Dictionary = {}   # kind -> {attr: points}
var _pools: Dictionary = {}        # kind -> current mana / stamina
var _cards: Dictionary = {}        # card id -> unused copies
var _skills: Dictionary = {}       # kind -> Array of card lists (empty list: free slot)
var _compiled: Dictionary = {}     # kind -> Array[Ability3D], rebuilt on a change


func _init() -> void:
	for kind in SOUL_KINDS:
		_attributes[kind] = {ATTR_POWER: 0, ATTR_ENERGY: 0, ATTR_FINESSE: 0}
		var slots: Array = []
		for i in range(SkillCards3D.SKILLS_PER_SOUL):
			slots.append(_empty_cards())
		_skills[kind] = slots
		_pools[kind] = pool_max(kind)
	changed.connect(_invalidate)


func get_level() -> int:
	return _level


## Called by the player on every level gained.
func on_level_up(new_level: int) -> void:
	_level = maxi(_level, new_level)
	attribute_points += ATTRIBUTE_POINTS_PER_LEVEL
	changed.emit()


func set_level(level: int) -> void:
	_level = maxi(1, level)


# --- Attributes ------------------------------------------------------------------

func get_attribute(kind: int, attribute: StringName) -> int:
	var soul_attributes: Dictionary = _attributes.get(kind, {})
	return int(soul_attributes.get(attribute, 0))


## Why `attribute` cannot be raised for `kind` now ("" when it can).
func attribute_block_reason(kind: int, attribute: StringName) -> String:
	if not _attributes.has(kind) or not ATTRIBUTES.has(attribute):
		return "Unknown attribute"
	if get_attribute(kind, attribute) >= MAX_ATTRIBUTE:
		return "Mastered"
	if attribute_points <= 0:
		return "No attribute points"
	return ""


func raise_attribute(kind: int, attribute: StringName) -> bool:
	if not attribute_block_reason(kind, attribute).is_empty():
		return false
	var soul_attributes: Dictionary = _attributes[kind]
	soul_attributes[attribute] = int(soul_attributes[attribute]) + 1
	attribute_points -= 1
	if attribute == ATTR_ENERGY:
		# The new capacity arrives filled.
		_pools[kind] = int(_pools.get(kind, 0)) + ENERGY_POOL_PER_POINT
		pools_changed.emit()
	changed.emit()
	return true


static func attribute_name(attribute: StringName) -> String:
	match attribute:
		ATTR_POWER:
			return "Power"
		ATTR_ENERGY:
			return "Energy"
		ATTR_FINESSE:
			return "Finesse"
	return String(attribute)


## What one point of `attribute` does for `kind`.
static func attribute_text(kind: int, attribute: StringName) -> String:
	match attribute:
		ATTR_POWER:
			match kind:
				Soul.Kind.MAGE:
					return "+10% damage from the mage's spells and skills."
				Soul.Kind.ROGUE:
					return "+10% damage from the rogue's blades, throws and skills."
			return "+10% damage from the knight's weapon and skills."
		ATTR_ENERGY:
			return "+%d %s, and +1 refill a turn for every %d points." \
				% [ENERGY_POOL_PER_POINT, resource_name(kind).to_lower(), ENERGY_POINTS_PER_REGEN]
		ATTR_FINESSE:
			match kind:
				Soul.Kind.MAGE:
					return "+0.5 m range and +0.25 m area on the mage's skills."
				Soul.Kind.ROGUE:
					return "+0.5 m movement a turn while the rogue is in control."
			return "5% less damage taken while the knight is in control."
	return ""


## Outgoing damage multiplier while `kind` is in control (Power).
func damage_multiplier(kind: int) -> float:
	return 1.0 + POWER_DAMAGE_PER_POINT * get_attribute(kind, ATTR_POWER)


## Incoming damage multiplier while `kind` is in control (the knight's Finesse).
func defence_multiplier(kind: int) -> float:
	if kind != Soul.Kind.KNIGHT:
		return 1.0
	return maxf(0.5, 1.0 - KNIGHT_FINESSE_DEFENCE_PER_POINT * get_attribute(kind, ATTR_FINESSE))


## Extra movement a turn while `kind` is in control (the rogue's Finesse).
func bonus_move_meters(kind: int) -> float:
	if kind != Soul.Kind.ROGUE:
		return 0.0
	return ROGUE_FINESSE_MOVE_PER_POINT * get_attribute(kind, ATTR_FINESSE)


func skill_range_bonus(kind: int) -> float:
	if kind != Soul.Kind.MAGE:
		return 0.0
	return MAGE_FINESSE_RANGE_PER_POINT * get_attribute(kind, ATTR_FINESSE)


func skill_radius_bonus(kind: int) -> float:
	if kind != Soul.Kind.MAGE:
		return 0.0
	return MAGE_FINESSE_RADIUS_PER_POINT * get_attribute(kind, ATTR_FINESSE)


# --- Mana and stamina --------------------------------------------------------------

static func resource_name(kind: int) -> String:
	return "Mana" if kind == Soul.Kind.MAGE else "Stamina"


func pool_max(kind: int) -> int:
	return int(POOL_BASE.get(kind, 30)) + ENERGY_POOL_PER_POINT * get_attribute(kind, ATTR_ENERGY)


func pool_regen(kind: int) -> int:
	return int(REGEN_BASE.get(kind, 6)) + floori(float(get_attribute(kind, ATTR_ENERGY)) / ENERGY_POINTS_PER_REGEN)


func get_pool(kind: int) -> int:
	return int(_pools.get(kind, 0))


func can_afford(kind: int, cost: int) -> bool:
	return get_pool(kind) >= cost


func spend_pool(kind: int, cost: int) -> bool:
	if cost <= 0:
		return true
	if not can_afford(kind, cost):
		return false
	_pools[kind] = get_pool(kind) - cost
	pools_changed.emit()
	return true


## One turn's refill for every soul (the three share the body and all rest).
func regen_pools() -> void:
	var moved := false
	for kind in SOUL_KINDS:
		var full := pool_max(kind)
		var now := get_pool(kind)
		if now < full:
			_pools[kind] = mini(full, now + pool_regen(kind))
			moved = true
	if moved:
		pools_changed.emit()


func pools_full() -> bool:
	for kind in SOUL_KINDS:
		if get_pool(kind) < pool_max(kind):
			return false
	return true


func refill_pools() -> void:
	for kind in SOUL_KINDS:
		_pools[kind] = pool_max(kind)
	pools_changed.emit()


# --- Cards ---------------------------------------------------------------------------

func add_card(card_id: StringName, copies: int = 1) -> void:
	if not SkillCards3D.is_card(card_id) or copies <= 0:
		return
	_cards[card_id] = card_count(card_id) + copies
	card_added.emit(card_id)
	changed.emit()


## Unused copies in the collection (cards in forged skills do not count).
func card_count(card_id: StringName) -> int:
	return int(_cards.get(card_id, 0))


func total_cards() -> int:
	var total := 0
	for card_id in _cards:
		total += int(_cards[card_id])
	return total


## Whether a type card exists anywhere: in the collection or in a skill.
func owns_type_card() -> bool:
	for card_id in SkillCards3D.ids_in(SkillCards3D.Category.TYPE):
		if card_count(card_id) > 0:
			return true
	for kind in SOUL_KINDS:
		for slot_cards in _skills[kind]:
			if not (slot_cards as Array).is_empty():
				return true
	return false


## The card a drop gives: a type card while the body owns none, so the first
## card found can always become a skill; otherwise a weighted random card.
func roll_drop(rng: RandomNumberGenerator) -> StringName:
	if not owns_type_card():
		return SkillCards3D.roll(rng, SkillCards3D.Category.TYPE)
	return SkillCards3D.roll(rng)


# --- Skills ---------------------------------------------------------------------------

func get_skill_cards(kind: int, slot: int) -> Array[StringName]:
	var result: Array[StringName] = []
	if not _skills.has(kind) or slot < 0 or slot >= SkillCards3D.SKILLS_PER_SOUL:
		return result
	for card_id in _skills[kind][slot]:
		result.append(card_id)
	return result


## Why `cards` cannot be forged into `kind`'s `slot` ("" when they can). The
## slot's current cards count as available: forging over a skill returns them.
func forge_block_reason(kind: int, slot: int, cards: Array[StringName]) -> String:
	if not _skills.has(kind) or slot < 0 or slot >= SkillCards3D.SKILLS_PER_SOUL:
		return "No such slot"
	var invalid := CardSkillCompiler3D.validate(cards)
	if not invalid.is_empty():
		return invalid
	var needed := {}
	for card_id in cards:
		needed[card_id] = int(needed.get(card_id, 0)) + 1
	var returned := {}
	for card_id in get_skill_cards(kind, slot):
		returned[card_id] = int(returned.get(card_id, 0)) + 1
	for card_id in needed:
		if int(needed[card_id]) > card_count(card_id) + int(returned.get(card_id, 0)):
			return "Not enough %s cards" % SkillCards3D.display_name(card_id)
	return ""


func forge_skill(kind: int, slot: int, cards: Array[StringName]) -> bool:
	if not forge_block_reason(kind, slot, cards).is_empty():
		return false
	_return_cards(kind, slot)
	var stored: Array[StringName] = []
	for card_id in cards:
		_cards[card_id] = card_count(card_id) - 1
		stored.append(card_id)
	_skills[kind][slot] = stored
	changed.emit()
	return true


## Takes the skill apart; its cards go back to the collection.
func dismantle_skill(kind: int, slot: int) -> bool:
	if get_skill_cards(kind, slot).is_empty():
		return false
	_return_cards(kind, slot)
	changed.emit()
	return true


func _return_cards(kind: int, slot: int) -> void:
	for card_id in get_skill_cards(kind, slot):
		_cards[card_id] = card_count(card_id) + 1
	_skills[kind][slot] = _empty_cards()


## The skill in `kind`'s `slot`, or null for a free slot.
func skill_ability(kind: int, slot: int) -> Ability3D:
	for ability in skills_for_soul(kind):
		if ability.id == StringName("card_%d_%d" % [kind, slot]):
			return ability
	return null


## The forged skills of `kind`, in slot order, compiled with its attributes.
func skills_for_soul(kind: int) -> Array[Ability3D]:
	if _compiled.has(kind):
		return _compiled[kind]
	var result: Array[Ability3D] = []
	for slot in range(SkillCards3D.SKILLS_PER_SOUL):
		var cards := get_skill_cards(kind, slot)
		if cards.is_empty():
			continue
		var ability := CardSkillCompiler3D.compile(kind, cards, slot, skill_range_bonus(kind), skill_radius_bonus(kind))
		if ability != null:
			result.append(ability)
	_compiled[kind] = result
	return result


## What `cards` would make for `kind` (the forge preview); null when invalid.
func preview_skill(kind: int, cards: Array[StringName]) -> Ability3D:
	return CardSkillCompiler3D.compile(kind, cards, -1, skill_range_bonus(kind), skill_radius_bonus(kind))


# --- Carrying it between levels (docs/level-flow.md) ------------------------------

## Everything this node holds, as plain data (a deep copy), for RunState3D.
func to_state() -> Dictionary:
	var skills := {}
	for kind in SOUL_KINDS:
		var slots: Array = []
		for slot in range(SkillCards3D.SKILLS_PER_SOUL):
			slots.append(Array(get_skill_cards(kind, slot)))
		skills[kind] = slots
	return {
		"attribute_points": attribute_points,
		"level": _level,
		"attributes": _attributes.duplicate(true),
		"pools": _pools.duplicate(),
		"cards": _cards.duplicate(),
		"skills": skills,
	}


## Puts back what `to_state` returned. Missing keys keep the current values.
func from_state(state: Dictionary) -> void:
	if state.is_empty():
		return
	attribute_points = int(state.get("attribute_points", attribute_points))
	_level = maxi(1, int(state.get("level", _level)))
	var attributes: Dictionary = state.get("attributes", {})
	for kind in SOUL_KINDS:
		if attributes.has(kind):
			_attributes[kind] = (attributes[kind] as Dictionary).duplicate(true)
	var pools: Dictionary = state.get("pools", {})
	for kind in SOUL_KINDS:
		if pools.has(kind):
			_pools[kind] = int(pools[kind])
	if state.has("cards"):
		_cards = (state["cards"] as Dictionary).duplicate()
	var skills: Dictionary = state.get("skills", {})
	for kind in SOUL_KINDS:
		if not skills.has(kind):
			continue
		var slots: Array = skills[kind]
		for slot in range(mini(slots.size(), SkillCards3D.SKILLS_PER_SOUL)):
			var cards := _empty_cards()
			cards.assign(slots[slot])
			_skills[kind][slot] = cards
	changed.emit()
	pools_changed.emit()


static func _empty_cards() -> Array[StringName]:
	var cards: Array[StringName] = []
	return cards


func _invalidate() -> void:
	_compiled.clear()
