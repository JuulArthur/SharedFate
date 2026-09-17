class_name Soul
extends RefCounted

# One of the three people bound into the player's single body: the knight, the
# rogue and the mage. The body is shared - position, health, inventory and XP
# all belong to it - and a soul is the set of rules that applies while it is
# the one in control.
#
# Everything a soul changes about combat is data here, read by `player.gd`
# (damage taken and dealt, the reaction to an enemy swing, spells) and by
# `main.gd` (which action buttons to show, ranges, the HUD). Balance lives in
# the constants at the top so tuning never means hunting through the actors.
#
# See CODEBASE_GUIDE.md > "The Bound Three".

enum Kind { KNIGHT, ROGUE, MAGE }

# What pressing the counter key inside an enemy's strike window does.
enum Reaction {
	BLOCK,  # Knight: the hit is negated. Forgiving - an early press costs nothing extra.
	PARRY,  # Rogue: the hit is negated and answered with a riposte. An early press leaves you open.
	WARD,   # Mage: the hit is halved. The mage is not built for melee.
}

# --- Balance ------------------------------------------------------------------
# Defence is a multiplier on incoming damage; melee is a multiplier on the
# equipped weapon's damage. Both sit on top of gear, so the inventory still
# matters for every soul.
const KNIGHT_DEFENCE := 0.70
const KNIGHT_MELEE := 1.00

const ROGUE_DEFENCE := 1.00
const ROGUE_MELEE := 1.35
const ROGUE_RANGED_DAMAGE := 16
const ROGUE_RANGED_RANGE_METERS := 12.0
# Pressing the parry during the wind-up is the rogue overcommitting.
const ROGUE_EARLY_PARRY_MULT := 2.0

const MAGE_DEFENCE := 1.30
const MAGE_MELEE := 0.60
const MAGE_WARD_MULT := 0.5
const MAGE_SPELL_RANGE_METERS := 10.0

# Spells (mage). A spell spends the turn's attack like any other attack and
# then recharges over `cooldown_turns` of the player's own turns; 0 means it is
# always ready.
const SPELL_ARCANE_BURST := &"arcane_burst"
const SPELL_FROST_SNARE := &"frost_snare"
const ARCANE_BURST_DAMAGE := 14
const ARCANE_BURST_RADIUS_METERS := 2.5
const FROST_SNARE_DAMAGE := 6
const FROST_SNARE_ROOT_TURNS := 1
const FROST_SNARE_COOLDOWN_TURNS := 2

# Placeholder names. The knight keeps the name the prototype already used.
const KNIGHT_NAME := "Sir Arthur"
const ROGUE_NAME := "Vesper"
const MAGE_NAME := "Maelis"

const COLOR_KNIGHT := Color(0.58, 0.74, 1.0, 1.0)
const COLOR_ROGUE := Color(0.55, 0.93, 0.60, 1.0)
const COLOR_MAGE := Color(0.80, 0.62, 1.0, 1.0)


class Spell:
	var id: StringName = &""
	var display_name: String = ""
	var description: String = ""
	var damage: int = 0
	var range_meters: float = 0.0
	# > 0: every enemy within this distance of the impact point is hit.
	var radius_meters: float = 0.0
	# > 0: the primary target loses its movement for this many of its turns.
	var root_turns: int = 0
	var cooldown_turns: int = 0
	var color: Color = Color.WHITE

	func is_area() -> bool:
		return radius_meters > 0.0


var kind: Kind = Kind.KNIGHT
var id: StringName = &"knight"
# The person's name and what they are: "Sir Arthur", the "Knight".
var display_name: String = ""
var title: String = ""
var description: String = ""
var color: Color = Color.WHITE
# Tint of the player's vision light while this soul is in control.
var light_color: Color = Color.WHITE
var defence_mult: float = 1.0
var melee_mult: float = 1.0
# Ranged attack; 0 damage means the soul has none.
var ranged_damage: int = 0
var ranged_range_meters: float = 0.0
var ranged_name: String = "Ranged"
var reaction: Reaction = Reaction.BLOCK
# The Block stance - spend the turn to halve every hit until your next one -
# is the knight's alone.
var can_block_stance: bool = false
var spells: Array[Spell] = []
# Shortcut shown in the HUD. The input actions themselves are registered by
# player.gd (`shift_soul_1` ... `shift_soul_3`, `shift_soul_cycle`).
var hotkey_label: String = "1"


static func all() -> Array[Soul]:
	return [knight(), rogue(), mage()]


static func knight() -> Soul:
	var soul := Soul.new()
	soul.kind = Kind.KNIGHT
	soul.id = &"knight"
	soul.display_name = KNIGHT_NAME
	soul.title = "Knight"
	soul.description = "Heavy armour and a steady shield. Takes less from every hit and can hold a Block for the whole enemy turn."
	soul.color = COLOR_KNIGHT
	soul.light_color = Color(1.0, 0.96, 0.88, 1.0)
	soul.defence_mult = KNIGHT_DEFENCE
	soul.melee_mult = KNIGHT_MELEE
	soul.reaction = Reaction.BLOCK
	soul.can_block_stance = true
	soul.hotkey_label = "1"
	return soul


static func rogue() -> Soul:
	var soul := Soul.new()
	soul.kind = Kind.ROGUE
	soul.id = &"rogue"
	soul.display_name = ROGUE_NAME
	soul.title = "Rogue"
	soul.description = "Fast and vicious. Hits hardest up close, throws knives at range, and turns a well-timed parry into a riposte - but a parry thrown too early leaves the body wide open."
	soul.color = COLOR_ROGUE
	soul.light_color = Color(0.82, 1.0, 0.86, 1.0)
	soul.defence_mult = ROGUE_DEFENCE
	soul.melee_mult = ROGUE_MELEE
	soul.ranged_damage = ROGUE_RANGED_DAMAGE
	soul.ranged_range_meters = ROGUE_RANGED_RANGE_METERS
	soul.ranged_name = "Throw"
	soul.reaction = Reaction.PARRY
	soul.hotkey_label = "2"
	return soul


static func mage() -> Soul:
	var soul := Soul.new()
	soul.kind = Kind.MAGE
	soul.id = &"mage"
	soul.display_name = MAGE_NAME
	soul.title = "Mage"
	soul.description = "Frail, but the only one of the three who can hit a whole group or pin an enemy in place. A ward softens blows; it does not stop them."
	soul.color = COLOR_MAGE
	soul.light_color = Color(0.86, 0.76, 1.0, 1.0)
	soul.defence_mult = MAGE_DEFENCE
	soul.melee_mult = MAGE_MELEE
	soul.reaction = Reaction.WARD
	soul.hotkey_label = "3"

	var burst := Spell.new()
	burst.id = SPELL_ARCANE_BURST
	burst.display_name = "Arcane Burst"
	burst.description = "A bolt that bursts on impact, hitting every enemy near the target."
	burst.damage = ARCANE_BURST_DAMAGE
	burst.range_meters = MAGE_SPELL_RANGE_METERS
	burst.radius_meters = ARCANE_BURST_RADIUS_METERS
	burst.color = Color(0.86, 0.62, 1.0, 1.0)
	soul.spells.append(burst)

	var snare := Spell.new()
	snare.id = SPELL_FROST_SNARE
	snare.display_name = "Frost Snare"
	snare.description = "Ice grips the target's legs: a little damage, and it cannot move on its next turn."
	snare.damage = FROST_SNARE_DAMAGE
	snare.range_meters = MAGE_SPELL_RANGE_METERS
	snare.root_turns = FROST_SNARE_ROOT_TURNS
	snare.cooldown_turns = FROST_SNARE_COOLDOWN_TURNS
	snare.color = Color(0.62, 0.88, 1.0, 1.0)
	soul.spells.append(snare)
	return soul


func has_ranged() -> bool:
	return ranged_damage > 0


func has_spells() -> bool:
	return not spells.is_empty()


func get_spell(spell_id: StringName) -> Spell:
	for spell in spells:
		if spell.id == spell_id:
			return spell
	return null


func reaction_name() -> String:
	match reaction:
		Reaction.BLOCK: return "Block"
		Reaction.PARRY: return "Parry"
		Reaction.WARD: return "Ward"
	return "React"


static func kind_title(soul_kind: Kind) -> String:
	match soul_kind:
		Kind.KNIGHT: return "Knight"
		Kind.ROGUE: return "Rogue"
		Kind.MAGE: return "Mage"
	return "Soul"
