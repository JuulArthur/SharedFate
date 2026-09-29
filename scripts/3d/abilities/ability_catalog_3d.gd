class_name AbilityCatalog3D
extends RefCounted

## The hand-made abilities that are not built from cards. Since the card
## system (docs/cards-and-attributes.md) every soul skill is forged from skill
## cards by CardSkillCompiler3D; what stays here is the utility every soul
## has from the start: Toss Pebble, the exploration distraction.
##
## Soul colours stay here for the runner's popups.

const DISTRACT := &"distract"

const DISTRACT_RANGE_M := 12.0
const DISTRACT_RADIUS_M := 7.0

const COLOR_KNIGHT := Color(0.58, 0.74, 1.0, 1.0)
const COLOR_ROGUE := Color(0.55, 0.93, 0.60, 1.0)
const COLOR_MAGE := Color(0.80, 0.62, 1.0, 1.0)

static var _cache: Array[Ability3D] = []


static func all() -> Array[Ability3D]:
	if _cache.is_empty():
		_cache = _build()
	return _cache


static func get_ability(ability_id: StringName) -> Ability3D:
	for ability in all():
		if ability.id == ability_id:
			return ability
	return null


## The catalog abilities a soul has from the start, bar order: its own, then
## the ones any soul has.
static func for_soul(soul_kind: int) -> Array[Ability3D]:
	var result: Array[Ability3D] = []
	for ability in all():
		if ability.soul_kind == soul_kind and ability.starts_unlocked:
			result.append(ability)
	for ability in all():
		if ability.soul_kind == Ability3D.ANY_SOUL and ability.starts_unlocked:
			result.append(ability)
	return result


static func _build() -> Array[Ability3D]:
	var list: Array[Ability3D] = []
	var pebble := _make(DISTRACT, Ability3D.ANY_SOUL, "Toss Pebble", Color(0.85, 0.8, 0.65, 1.0),
		"Throw a pebble up to 12 m. Unaware enemies within 7 m of where it lands walk over to look. Exploration only.")
	pebble.target = Ability3D.Target.GROUND
	pebble.cost = Ability3D.Cost.BONUS
	pebble.range_m = DISTRACT_RANGE_M
	pebble.radius_m = DISTRACT_RADIUS_M
	pebble.cooldown_turns = 1
	pebble.exploration_only = true
	pebble.starts_unlocked = true
	list.append(pebble)
	return list


static func _make(ability_id: StringName, soul_kind: int, display_name: String, color: Color, description: String) -> Ability3D:
	var ability := Ability3D.new()
	ability.id = ability_id
	ability.soul_kind = soul_kind
	ability.display_name = display_name
	ability.color = color
	ability.description = description
	return ability
