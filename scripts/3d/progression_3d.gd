class_name Progression3D
extends Node

## The body's growth: skill points, learned abilities and passive ranks. A child
## of the player named "Progression". The player reads the passives (health,
## damage, movement, shifts) and the coordinator reads what is learned for the
## ability bar; the skill tree screen spends the points.
##
## Every level up grants one skill point and a little health. The body starts
## with one point so the tree can be tried from the first minute. Levels come
## from XP (Player3D.add_experience); this node only hears about them.

signal changed

const STARTING_SKILL_POINTS := 1
const POINTS_PER_LEVEL := 1
## Every level up raises the body's maximum health by this much by itself.
const HEALTH_PER_LEVEL := 8

const PASSIVE_VITALITY := &"vitality"
const PASSIVE_MIGHT := &"might"
const PASSIVE_FLEET_FOOT := &"fleet_foot"
const PASSIVE_SOUL_BOND := &"soul_bond"

const VITALITY_HEALTH_PER_RANK := 15
const MIGHT_DAMAGE_PER_RANK := 0.10
const FLEET_FOOT_METERS_PER_RANK := 1.0

## Passive definitions, in skill-tree order.
const PASSIVES: Array[Dictionary] = [
	{"id": PASSIVE_VITALITY, "name": "Vitality", "max_rank": 3, "level": 1,
		"description": "+15 maximum health per rank."},
	{"id": PASSIVE_MIGHT, "name": "Might", "max_rank": 3, "level": 2,
		"description": "+10 % damage from every soul per rank."},
	{"id": PASSIVE_FLEET_FOOT, "name": "Fleet Foot", "max_rank": 2, "level": 3,
		"description": "+1 m of movement every turn per rank."},
	{"id": PASSIVE_SOUL_BOND, "name": "Soul Bond", "max_rank": 1, "level": 5,
		"description": "The three souls trade places more easily: one more shift every turn."},
]

var skill_points := STARTING_SKILL_POINTS
var _learned: Dictionary = {}
var _passive_ranks: Dictionary = {}
var _level := 1


func _ready() -> void:
	for ability in AbilityCatalog3D.all():
		if ability.starts_unlocked:
			_learned[ability.id] = true


func get_level() -> int:
	return _level


## Called by the player on every level gained.
func on_level_up(new_level: int) -> void:
	_level = maxi(_level, new_level)
	skill_points += POINTS_PER_LEVEL
	changed.emit()


func set_level(level: int) -> void:
	_level = maxi(1, level)


# --- Abilities -----------------------------------------------------------------

func is_learned(ability_id: StringName) -> bool:
	return _learned.has(ability_id)


func learned_for_soul(soul_kind: int) -> Array[Ability3D]:
	var result: Array[Ability3D] = []
	for ability in AbilityCatalog3D.for_soul(soul_kind):
		if is_learned(ability.id):
			result.append(ability)
	return result


## Why an ability cannot be learned now ("" when it can).
func learn_block_reason(ability_id: StringName) -> String:
	var ability := AbilityCatalog3D.get_ability(ability_id)
	if ability == null:
		return "Unknown ability"
	if is_learned(ability_id):
		return "Learned"
	if _level < ability.unlock_level:
		return "Requires level %d" % ability.unlock_level
	if skill_points <= 0:
		return "No skill points"
	return ""


func learn(ability_id: StringName) -> bool:
	if not learn_block_reason(ability_id).is_empty():
		return false
	_learned[ability_id] = true
	skill_points -= 1
	changed.emit()
	return true


# --- Passives --------------------------------------------------------------------

func get_passive_rank(passive_id: StringName) -> int:
	return int(_passive_ranks.get(passive_id, 0))


static func passive_def(passive_id: StringName) -> Dictionary:
	for def in PASSIVES:
		if def["id"] == passive_id:
			return def
	return {}


func passive_block_reason(passive_id: StringName) -> String:
	var def := passive_def(passive_id)
	if def.is_empty():
		return "Unknown passive"
	if get_passive_rank(passive_id) >= int(def["max_rank"]):
		return "Mastered"
	if _level < int(def["level"]):
		return "Requires level %d" % int(def["level"])
	if skill_points <= 0:
		return "No skill points"
	return ""


func raise_passive(passive_id: StringName) -> bool:
	if not passive_block_reason(passive_id).is_empty():
		return false
	_passive_ranks[passive_id] = get_passive_rank(passive_id) + 1
	skill_points -= 1
	changed.emit()
	return true


## Maximum health the passives add (levels add their own on top, see the player).
func bonus_max_health() -> int:
	return get_passive_rank(PASSIVE_VITALITY) * VITALITY_HEALTH_PER_RANK


func damage_multiplier() -> float:
	return 1.0 + get_passive_rank(PASSIVE_MIGHT) * MIGHT_DAMAGE_PER_RANK


func bonus_move_meters() -> float:
	return get_passive_rank(PASSIVE_FLEET_FOOT) * FLEET_FOOT_METERS_PER_RANK


func bonus_shifts() -> int:
	return get_passive_rank(PASSIVE_SOUL_BOND)
