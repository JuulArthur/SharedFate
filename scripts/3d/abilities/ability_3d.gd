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


func is_melee() -> bool:
	return range_m <= 0.0


func is_area() -> bool:
	return radius_m > 0.0


func cost_label() -> String:
	return "Bonus" if cost == Cost.BONUS else "Action"


## One line for tooltips and the skill tree.
func summary() -> String:
	var parts: Array[String] = [cost_label()]
	if target != Target.SELF:
		parts.append("melee reach" if is_melee() else "%d m" % int(round(range_m)))
	if cooldown_turns > 0:
		parts.append("recharge %d" % cooldown_turns)
	if exploration_only:
		parts.append("exploration only")
	return "  |  ".join(parts)
