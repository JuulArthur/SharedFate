class_name SkillCards3D
extends RefCounted

## The skill cards: data only. Three kinds of card go into a skill
## (docs/cards-and-attributes.md):
##
## - a TYPE card says what the skill does (damage, affliction, control, buff,
##   heal, summon); a skill has exactly one type, in one to three copies;
## - ELEMENT cards colour it (fire burns, frost binds, lightning jumps, poison
##   festers) and add power;
## - MODIFIER cards shape it (ranged, close, area).
##
## Copies stack: every extra copy of a card raises what that card does. The
## soul the skill is forged for decides how it is delivered
## (`CardSkillCompiler3D`). Cards drop from enemies and chests (`roll_drop`).

enum Category { TYPE, ELEMENT, MODIFIER }

const TYPE_DAMAGE := &"type_damage"
const TYPE_AFFLICTION := &"type_affliction"
const TYPE_CONTROL := &"type_control"
const TYPE_BUFF := &"type_buff"
const TYPE_HEAL := &"type_heal"
const TYPE_SUMMON := &"type_summon"

const ELEMENT_FIRE := &"element_fire"
const ELEMENT_FROST := &"element_frost"
const ELEMENT_LIGHTNING := &"element_lightning"
const ELEMENT_POISON := &"element_poison"

const MOD_RANGED := &"mod_ranged"
const MOD_CLOSE := &"mod_close"
const MOD_AREA := &"mod_area"

## Cards a skill can hold, and how many skills each soul can carry.
const MAX_CARDS_PER_SKILL := 5
const SKILLS_PER_SOUL := 3

## Mana or stamina a skill costs: the sum of its cards' costs.
const COST_TYPE := 6
const COST_ELEMENT := 4
const COST_MODIFIER := 3

const COLOR_TYPE := Color(0.95, 0.80, 0.45, 1.0)
const COLOR_MODIFIER := Color(0.72, 0.76, 0.82, 1.0)
const COLOR_FIRE := Color(1.0, 0.55, 0.2, 1.0)
const COLOR_FROST := Color(0.62, 0.88, 1.0, 1.0)
const COLOR_LIGHTNING := Color(0.80, 0.86, 1.0, 1.0)
const COLOR_POISON := Color(0.55, 0.95, 0.35, 1.0)

## Every card, in collection order. `weight` is its share of random drops
## within the whole table; `icon` names an ActionIcons3D glyph.
const CARDS: Array[Dictionary] = [
	{"id": TYPE_DAMAGE, "category": Category.TYPE, "name": "Damage", "weight": 14, "icon": &"melee",
		"text": "The skill hurts. Each copy adds damage."},
	{"id": TYPE_AFFLICTION, "category": Category.TYPE, "name": "Affliction", "weight": 8, "icon": &"poison_blade",
		"text": "Damage over time: burns, or poisons with a Poison card. Each copy lasts longer and hurts more."},
	{"id": TYPE_CONTROL, "category": Category.TYPE, "name": "Control", "weight": 8, "icon": &"set_snare",
		"text": "Holds the enemy: roots, stuns, weakens or exposes by element. Each copy adds a turn."},
	{"id": TYPE_BUFF, "category": Category.TYPE, "name": "Buff", "weight": 7, "icon": &"skill_tree",
		"text": "Strengthens the soul who casts it, by element. A bonus action. Each copy adds a turn."},
	{"id": TYPE_HEAL, "category": Category.TYPE, "name": "Heal", "weight": 6, "icon": &"second_wind",
		"text": "Mends the body. A bonus action. Each copy heals more."},
	{"id": TYPE_SUMMON, "category": Category.TYPE, "name": "Summon", "weight": 4, "icon": &"shadowstep",
		"text": "Raises a spirit that strikes at the start of your turns. Each copy makes it last and hit harder."},
	{"id": ELEMENT_FIRE, "category": Category.ELEMENT, "name": "Fire", "weight": 10, "icon": &"fireball",
		"text": "Burns. Each copy adds damage and a stronger burn."},
	{"id": ELEMENT_FROST, "category": Category.ELEMENT, "name": "Frost", "weight": 10, "icon": &"frost_snare",
		"text": "Binds. Each copy adds damage; frost roots and wards."},
	{"id": ELEMENT_LIGHTNING, "category": Category.ELEMENT, "name": "Lightning", "weight": 10, "icon": &"chain_lightning",
		"text": "Jumps and stuns. Each copy adds damage and, for a bolt, one more jump."},
	{"id": ELEMENT_POISON, "category": Category.ELEMENT, "name": "Poison", "weight": 10, "icon": &"poison_blade",
		"text": "Festers and weakens. Each copy adds damage and a stronger poison."},
	{"id": MOD_RANGED, "category": Category.MODIFIER, "name": "Ranged", "weight": 9, "icon": &"throw",
		"text": "Reach far: a throw for the rogue, a leap for the knight. Every copy the delivery does not need adds 2 m of range."},
	{"id": MOD_CLOSE, "category": Category.MODIFIER, "name": "Close", "weight": 9, "icon": &"melee",
		"text": "Up close: a weapon strike, or a burst around you. Adds half your weapon's damage."},
	{"id": MOD_AREA, "category": Category.MODIFIER, "name": "Area", "weight": 9, "icon": &"cleave",
		"text": "Hits everyone in a radius. Each extra copy adds 1 m of radius."},
]


static func get_card(card_id: StringName) -> Dictionary:
	for card in CARDS:
		if card["id"] == card_id:
			return card
	return {}


static func is_card(card_id: StringName) -> bool:
	return not get_card(card_id).is_empty()


static func category_of(card_id: StringName) -> int:
	var card := get_card(card_id)
	return int(card.get("category", -1))


static func display_name(card_id: StringName) -> String:
	return String(get_card(card_id).get("name", String(card_id)))


static func icon_of(card_id: StringName) -> StringName:
	return get_card(card_id).get("icon", &"") as StringName


static func color_of(card_id: StringName) -> Color:
	match card_id:
		ELEMENT_FIRE:
			return COLOR_FIRE
		ELEMENT_FROST:
			return COLOR_FROST
		ELEMENT_LIGHTNING:
			return COLOR_LIGHTNING
		ELEMENT_POISON:
			return COLOR_POISON
	return COLOR_TYPE if category_of(card_id) == Category.TYPE else COLOR_MODIFIER


static func category_name(category: int) -> String:
	match category:
		Category.TYPE:
			return "Types"
		Category.ELEMENT:
			return "Elements"
		Category.MODIFIER:
			return "Modifiers"
	return ""


static func cost_of(card_id: StringName) -> int:
	match category_of(card_id):
		Category.TYPE:
			return COST_TYPE
		Category.ELEMENT:
			return COST_ELEMENT
		Category.MODIFIER:
			return COST_MODIFIER
	return 0


static func ids_in(category: int) -> Array[StringName]:
	var result: Array[StringName] = []
	for card in CARDS:
		if int(card["category"]) == category:
			result.append(card["id"])
	return result


## A random card by drop weight. `only_category` >= 0 limits the roll to one
## category (the first drop is always a type, see Progression3D.roll_drop).
static func roll(rng: RandomNumberGenerator, only_category: int = -1) -> StringName:
	var total := 0
	for card in CARDS:
		if only_category < 0 or int(card["category"]) == only_category:
			total += int(card["weight"])
	var pick := rng.randi_range(1, maxi(1, total))
	for card in CARDS:
		if only_category >= 0 and int(card["category"]) != only_category:
			continue
		pick -= int(card["weight"])
		if pick <= 0:
			return card["id"]
	return TYPE_DAMAGE
