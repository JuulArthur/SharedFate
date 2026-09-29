class_name Ability3D
extends RefCounted

## One active ability: data only. `AbilityCatalog3D` authors every ability and
## `AbilityRunner3D` carries them out; the coordinator shows the active soul's
## unlocked ones on the ability bar. See docs/gameplay-expansion.md, section 1.
##
## Costs: an ACTION ability spends the turn's one action (the same slot as a
## melee swing, a throw or a spell); a BONUS ability spends the turn's bonus
## action, so a turn can be "Shadowstep, then Backstab". Cooldowns count the
## player's own turns; in exploration one turn melts every 3 s, as the spells do.

enum Target {
	ENEMY,   # click an enemy (or a hittable, for damage abilities)
	GROUND,  # click a point on the ground
	SELF,    # fires on the button press
}

enum Cost {
	ACTION,
	BONUS,
}

## How a card-built skill reaches its targets (CardSkillCompiler3D picks it
## from the soul and the modifier cards).
enum Delivery {
	NONE,       # a catalog ability with its own code (Toss Pebble)
	BOLT,       # the mage: a bolt at an enemy, bursting when it has an area
	CHAIN,      # the mage: a lightning bolt that jumps between enemies
	NOVA,       # the mage, close: a burst around the caster
	THROW,      # the rogue: a thrown blade at an enemy
	STRIKE,     # the knight or rogue: a weapon strike on an enemy in reach
	FIELD,      # the rogue, area: a trap field on the ground for a few turns
	LEAP,       # the knight, ranged: leap to an enemy and strike, slam with an area
	SWEEP,      # the knight, close area: a sweep around the body
	SELF,       # buffs and heals on the body
	TOTEM,      # summons: a spirit placed on the ground
}

## Any soul may use an ability with this kind (the exploration distraction).
const ANY_SOUL := -1

var id: StringName = &""
## Soul.Kind, or ANY_SOUL.
var soul_kind: int = ANY_SOUL
var display_name := ""
var description := ""
var target: Target = Target.ENEMY
var cost: Cost = Cost.ACTION
## Metres from the player to the target or point. 0 means the melee reach of
## the equipped weapon.
var range_m := 0.0
## Area radius in metres around the impact (or the player, for SELF).
var radius_m := 0.0
## Damage as a multiple of the player's melee damage (0: no weapon part).
var damage_mult := 0.0
## Flat damage added on top (spells and bombs use only this).
var flat_damage := 0
var cooldown_turns := 0
## Character level at which it can be learned in the skill tree.
var unlock_level := 1
## Learned from the start (every soul begins with one ability).
var starts_unlocked := false
var usable_in_exploration := true
## Only outside turn combat (the pebble toss).
var exploration_only := false
var color := Color.WHITE
## Status applied to the target(s): id, own turns, power (DoT damage).
var status_id: StringName = &""
var status_turns := 0
var status_power := 0
var knockback_m := 0.0

# --- Card-built skills (docs/cards-and-attributes.md) --------------------------
## Built from cards by CardSkillCompiler3D; the runner reads the fields below
## instead of matching on `id`.
var card_skill := false
## ActionIcons3D glyph; empty means the glyph named like `id`.
var icon: StringName = &""
var cards: Array[StringName] = []
var type_card: StringName = &""
var delivery: Delivery = Delivery.NONE
## Mana (mage) or stamina (knight, rogue) the skill costs.
var resource_cost := 0
## Every status the skill lays on what it hits: {id, turns, power}.
var statuses: Array[Dictionary] = []
## Buffs on the body (SELF): {id, turns, power}; see Player3D.apply_buff.
var buffs: Array[Dictionary] = []
## Share of maximum health a heal restores.
var heal_ratio := 0.0
## Extra enemies a CHAIN bolt jumps to.
var chain_jumps := 0
## FIELD and TOTEM: how many of the player's turns the thing lasts.
var lasting_turns := 0
## TOTEM: how far the spirit reaches from where it stands.
var totem_reach_m := 0.0
## Damage a STRIKE deals on top when the target is exposed (the rogue).
var exposed_mult := 1.0
## Cards that do nothing in this combination, for the forge preview.
var wasted_cards: Array[StringName] = []


func is_melee() -> bool:
	return range_m <= 0.0 and (delivery == Delivery.NONE or delivery == Delivery.STRIKE)


func is_area() -> bool:
	return radius_m > 0.0


func cost_label() -> String:
	return "Bonus" if cost == Cost.BONUS else "Action"


## One line for tooltips and the skill tree.
func summary() -> String:
	var parts: Array[String] = [cost_label()]
	if target != Target.SELF:
		parts.append("melee reach" if is_melee() else "%d m" % int(round(range_m)))
	if resource_cost > 0:
		parts.append("%d %s" % [resource_cost, "mana" if soul_kind == Soul.Kind.MAGE else "stamina"])
	if cooldown_turns > 0:
		parts.append("recharge %d" % cooldown_turns)
	if exploration_only:
		parts.append("exploration only")
	return "  |  ".join(parts)
