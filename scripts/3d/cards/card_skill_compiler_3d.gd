class_name CardSkillCompiler3D
extends RefCounted

## Turns a soul and a hand of skill cards into an Ability3D the runner can use
## (docs/cards-and-attributes.md, "How a skill is built").
##
## The type card decides what the skill does, elements add power and statuses,
## modifiers shape it, and the soul decides the delivery:
##
## | Soul   | No modifier | Ranged       | Close        | Area                        |
## | ------ | ----------- | ------------ | ------------ | --------------------------- |
## | Knight | strike      | leap + strike| strike       | sweep (with Ranged: slam)   |
## | Rogue  | strike      | throw        | strike       | trap field on the ground    |
## | Mage   | bolt        | bolt         | nova         | bursting bolt (Close: nova) |
##
## A mage bolt with Lightning and no Area chains instead. Buffs and heals land
## on the body; summons raise a spirit on the ground. Every extra copy of a
## card raises what that card does.

const RANGE_BOLT_M := 8.0
const RANGE_THROW_M := 6.0
const RANGE_LEAP_M := 4.0
const RANGE_FIELD_M := 6.0
const RANGE_TOTEM_M := 5.0
const RANGE_PER_EXTRA_RANGED_M := 2.0
const AREA_BASE_RADIUS_M := 2.0
const AREA_PER_EXTRA_M := 1.0
const NOVA_BASE_RADIUS_M := 2.5
const NOVA_PER_EXTRA_CLOSE_M := 0.5

const DAMAGE_BASE := 8
const DAMAGE_PER_EXTRA_TYPE := 6
const DAMAGE_PER_ELEMENT := 3
## Weapon strikes (strike, leap, sweep) add this share of the melee damage,
## plus CLOSE_WEAPON_SHARE for every Close card.
const WEAPON_SHARE := 0.5
const CLOSE_WEAPON_SHARE := 0.25
const ROGUE_EXPOSED_MULT := 1.5
const CHAIN_JUMP_M := 4.0
## A trap field strikes every turn, so each strike is lighter.
const FIELD_DAMAGE_SHARE := 0.6
const FIELD_TURNS := 3

const AFFLICTION_HIT := 3
const AFFLICTION_POWER := 3
const AFFLICTION_POWER_PER_EXTRA := 2
const AFFLICTION_TURNS := 2
const CONTROL_HIT := 4
const CONTROL_HIT_PER_ELEMENT := 2
const MAX_STUN_TURNS := 2
const KNIGHT_CONTROL_KNOCKBACK_M := 1.5

const BUFF_TURNS := 2
const HEAL_RATIO := 0.15
const HEAL_RATIO_PER_EXTRA := 0.10

const TOTEM_TURNS := 3
const TOTEM_DAMAGE := 5
const TOTEM_DAMAGE_PER_EXTRA := 3
const TOTEM_DAMAGE_PER_ELEMENT := 2
const TOTEM_REACH_M := {Soul.Kind.KNIGHT: 2.5, Soul.Kind.ROGUE: 4.0, Soul.Kind.MAGE: 7.0}

const EMPOWER_PER_FIRE := 25        # % more damage
const WARD_BASE := 25               # % less damage taken
const WARD_PER_EXTRA_FROST := 10
const WARD_MAX := 60
const HASTE_BASE_M := 3
const ENVENOM_POWER := 3
const DEFAULT_BUFF_POWER := {Soul.Kind.KNIGHT: 30, Soul.Kind.ROGUE: 1, Soul.Kind.MAGE: 25}

const ELEMENT_WORD := {
	SkillCards3D.ELEMENT_FIRE: "Flame",
	SkillCards3D.ELEMENT_FROST: "Frost",
	SkillCards3D.ELEMENT_LIGHTNING: "Storm",
	SkillCards3D.ELEMENT_POISON: "Venom",
}
const PLAIN_WORD := {Soul.Kind.KNIGHT: "Iron", Soul.Kind.ROGUE: "Shadow", Soul.Kind.MAGE: "Arcane"}
## Ties between elements go in this order.
const ELEMENT_ORDER: Array[StringName] = [
	SkillCards3D.ELEMENT_FROST, SkillCards3D.ELEMENT_LIGHTNING,
	SkillCards3D.ELEMENT_POISON, SkillCards3D.ELEMENT_FIRE,
]


## Why these cards cannot make a skill ("" when they can).
static func validate(cards: Array[StringName]) -> String:
	if cards.is_empty():
		return "Add a type card"
	if cards.size() > SkillCards3D.MAX_CARDS_PER_SKILL:
		return "At most %d cards in a skill" % SkillCards3D.MAX_CARDS_PER_SKILL
	var types: Array[StringName] = []
	for card_id in cards:
		if not SkillCards3D.is_card(card_id):
			return "Unknown card"
		if SkillCards3D.category_of(card_id) == SkillCards3D.Category.TYPE and not types.has(card_id):
			types.append(card_id)
	if types.is_empty():
		return "Needs a type card"
	if types.size() > 1:
		return "One type per skill"
	if cards.has(SkillCards3D.MOD_RANGED) and cards.has(SkillCards3D.MOD_CLOSE):
		return "Ranged and Close do not mix"
	return ""


## The skill `cards` make for `soul_kind`, or null when they are not valid.
## `slot` names it on the bar; `range_bonus_m` and `radius_bonus_m` come from
## the soul's Finesse (the mage's).
static func compile(soul_kind: int, cards: Array[StringName], slot: int = -1,
		range_bonus_m: float = 0.0, radius_bonus_m: float = 0.0) -> Ability3D:
	if not validate(cards).is_empty():
		return null
	var counts := _count(cards)
	var type_card := StringName()
	for card_id in cards:
		if SkillCards3D.category_of(card_id) == SkillCards3D.Category.TYPE:
			type_card = card_id
			break
	var extra_type := int(counts[type_card]) - 1
	var ranged := int(counts.get(SkillCards3D.MOD_RANGED, 0))
	var close := int(counts.get(SkillCards3D.MOD_CLOSE, 0))
	var area := int(counts.get(SkillCards3D.MOD_AREA, 0))
	var element_count := 0
	for element in SkillCards3D.ids_in(SkillCards3D.Category.ELEMENT):
		element_count += int(counts.get(element, 0))
	var main_element := _main_element(counts)

	var ability := Ability3D.new()
	ability.card_skill = true
	ability.cards = _sorted(cards)
	ability.type_card = type_card
	ability.soul_kind = soul_kind
	ability.id = StringName("card_%d_%d" % [soul_kind, slot]) if slot >= 0 else &"card_preview"
	ability.usable_in_exploration = true
	ability.color = SkillCards3D.color_of(main_element) if main_element != &"" else _soul_color(soul_kind)
	ability.cooldown_turns = maxi(0, cards.size() - 3)
	for card_id in cards:
		ability.resource_cost += SkillCards3D.cost_of(card_id)
	ability.cost = Ability3D.Cost.BONUS if type_card == SkillCards3D.TYPE_BUFF or type_card == SkillCards3D.TYPE_HEAL \
		else Ability3D.Cost.ACTION
	var area_radius := AREA_BASE_RADIUS_M + AREA_PER_EXTRA_M * maxf(0.0, float(area - 1)) + radius_bonus_m

	match type_card:
		SkillCards3D.TYPE_BUFF, SkillCards3D.TYPE_HEAL:
			ability.delivery = Ability3D.Delivery.SELF
			ability.target = Ability3D.Target.SELF
			for modifier in [SkillCards3D.MOD_RANGED, SkillCards3D.MOD_CLOSE, SkillCards3D.MOD_AREA]:
				if counts.has(modifier):
					ability.wasted_cards.append(modifier)
			_self_effects(ability, soul_kind, type_card, extra_type, counts)
		SkillCards3D.TYPE_SUMMON:
			ability.delivery = Ability3D.Delivery.TOTEM
			ability.target = Ability3D.Target.GROUND
			ability.range_m = RANGE_TOTEM_M + RANGE_PER_EXTRA_RANGED_M * ranged + range_bonus_m
			ability.lasting_turns = TOTEM_TURNS + extra_type
			ability.totem_reach_m = float(TOTEM_REACH_M.get(soul_kind, 4.0))
			# Area: the spirit strikes everyone in reach instead of the nearest.
			ability.radius_m = ability.totem_reach_m if area > 0 else 0.0
			if close > 0:
				ability.wasted_cards.append(SkillCards3D.MOD_CLOSE)
			ability.flat_damage = TOTEM_DAMAGE + TOTEM_DAMAGE_PER_EXTRA * extra_type + TOTEM_DAMAGE_PER_ELEMENT * element_count
			ability.statuses = _element_statuses(counts)
		_:
			_offensive_delivery(ability, soul_kind, ranged, close, area, area_radius, counts, range_bonus_m)
			_offensive_effect(ability, soul_kind, type_card, extra_type, close, element_count, main_element, counts)

	ability.display_name = _name_for(ability, soul_kind, main_element, extra_type)
	ability.description = describe(ability)
	ability.icon = icon_for(ability)
	return ability


# --- Delivery -------------------------------------------------------------------

static func _offensive_delivery(ability: Ability3D, soul_kind: int, ranged: int, close: int, area: int,
		area_radius: float, counts: Dictionary, range_bonus_m: float) -> void:
	match soul_kind:
		Soul.Kind.MAGE:
			if close > 0:
				ability.delivery = Ability3D.Delivery.NOVA
				ability.target = Ability3D.Target.SELF
				ability.radius_m = (area_radius + 0.5 if area > 0 else NOVA_BASE_RADIUS_M) \
					+ NOVA_PER_EXTRA_CLOSE_M * float(close - 1)
			elif counts.has(SkillCards3D.ELEMENT_LIGHTNING) and area == 0:
				ability.delivery = Ability3D.Delivery.CHAIN
				ability.target = Ability3D.Target.ENEMY
				ability.range_m = RANGE_BOLT_M + RANGE_PER_EXTRA_RANGED_M * ranged + range_bonus_m
				ability.chain_jumps = int(counts[SkillCards3D.ELEMENT_LIGHTNING])
				ability.radius_m = CHAIN_JUMP_M
			else:
				ability.delivery = Ability3D.Delivery.BOLT
				ability.target = Ability3D.Target.ENEMY
				ability.range_m = RANGE_BOLT_M + RANGE_PER_EXTRA_RANGED_M * ranged + range_bonus_m
				ability.radius_m = area_radius if area > 0 else 0.0
		Soul.Kind.ROGUE:
			if area > 0:
				ability.delivery = Ability3D.Delivery.FIELD
				ability.lasting_turns = FIELD_TURNS
				ability.radius_m = area_radius
				if close > 0:
					# Close: the field springs up around the rogue.
					ability.target = Ability3D.Target.SELF
				else:
					ability.target = Ability3D.Target.GROUND
					ability.range_m = RANGE_FIELD_M + RANGE_PER_EXTRA_RANGED_M * ranged + range_bonus_m
			elif ranged > 0:
				ability.delivery = Ability3D.Delivery.THROW
				ability.target = Ability3D.Target.ENEMY
				ability.range_m = RANGE_THROW_M + RANGE_PER_EXTRA_RANGED_M * (ranged - 1) + range_bonus_m
			else:
				ability.delivery = Ability3D.Delivery.STRIKE
				ability.target = Ability3D.Target.ENEMY
				ability.exposed_mult = ROGUE_EXPOSED_MULT
		_:
			if ranged > 0:
				ability.delivery = Ability3D.Delivery.LEAP
				ability.target = Ability3D.Target.ENEMY
				ability.range_m = RANGE_LEAP_M + RANGE_PER_EXTRA_RANGED_M * (ranged - 1) + range_bonus_m
				ability.radius_m = area_radius if area > 0 else 0.0
			elif area > 0:
				ability.delivery = Ability3D.Delivery.SWEEP
				ability.target = Ability3D.Target.SELF
				ability.radius_m = area_radius
			else:
				ability.delivery = Ability3D.Delivery.STRIKE
				ability.target = Ability3D.Target.ENEMY
	if ability.delivery == Ability3D.Delivery.NOVA and ranged > 0:
		ability.wasted_cards.append(SkillCards3D.MOD_RANGED)


static func _is_weapon_delivery(delivery: Ability3D.Delivery) -> bool:
	return delivery == Ability3D.Delivery.STRIKE or delivery == Ability3D.Delivery.LEAP \
		or delivery == Ability3D.Delivery.SWEEP


# --- Effects --------------------------------------------------------------------

static func _offensive_effect(ability: Ability3D, soul_kind: int, type_card: StringName, extra_type: int,
		close: int, element_count: int, main_element: StringName, counts: Dictionary) -> void:
	var weapon_share := 0.0
	if _is_weapon_delivery(ability.delivery):
		weapon_share = WEAPON_SHARE + CLOSE_WEAPON_SHARE * close
	match type_card:
		SkillCards3D.TYPE_AFFLICTION:
			ability.flat_damage = AFFLICTION_HIT + element_count
			ability.damage_mult = weapon_share * 0.5
			var status := &"poison" if counts.has(SkillCards3D.ELEMENT_POISON) else &"burn"
			ability.statuses.append({"id": status, "turns": AFFLICTION_TURNS + extra_type,
				"power": AFFLICTION_POWER + AFFLICTION_POWER_PER_EXTRA * extra_type + element_count})
		SkillCards3D.TYPE_CONTROL:
			ability.flat_damage = CONTROL_HIT + CONTROL_HIT_PER_ELEMENT * element_count
			ability.damage_mult = weapon_share * 0.5
			var status := _control_status(soul_kind, main_element)
			var turns := 1 + extra_type
			if status == &"stun":
				turns = mini(turns, MAX_STUN_TURNS)
			ability.statuses.append({"id": status, "turns": turns, "power": 0})
			if soul_kind == Soul.Kind.KNIGHT:
				ability.knockback_m = KNIGHT_CONTROL_KNOCKBACK_M
		_:
			ability.flat_damage = DAMAGE_BASE + DAMAGE_PER_EXTRA_TYPE * extra_type + DAMAGE_PER_ELEMENT * element_count
			ability.damage_mult = weapon_share
			ability.statuses = _element_statuses(counts)
	if ability.delivery == Ability3D.Delivery.FIELD:
		ability.flat_damage = maxi(1, int(round(float(ability.flat_damage) * FIELD_DAMAGE_SHARE)))


static func _control_status(soul_kind: int, main_element: StringName) -> StringName:
	match main_element:
		SkillCards3D.ELEMENT_FROST:
			return &"root"
		SkillCards3D.ELEMENT_LIGHTNING:
			return &"stun"
		SkillCards3D.ELEMENT_POISON:
			return &"weaken"
		SkillCards3D.ELEMENT_FIRE:
			return &"expose"
	return &"stun" if soul_kind == Soul.Kind.KNIGHT else &"root"


## The side statuses elements add to a damage skill or a spirit's strikes.
static func _element_statuses(counts: Dictionary) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var fire := int(counts.get(SkillCards3D.ELEMENT_FIRE, 0))
	var frost := int(counts.get(SkillCards3D.ELEMENT_FROST, 0))
	var lightning := int(counts.get(SkillCards3D.ELEMENT_LIGHTNING, 0))
	var poison := int(counts.get(SkillCards3D.ELEMENT_POISON, 0))
	if fire > 0:
		result.append({"id": &"burn", "turns": 2, "power": 2 * fire})
	if frost > 0:
		result.append({"id": &"root", "turns": 1, "power": 0})
	if lightning > 0:
		result.append({"id": &"expose", "turns": 1, "power": 0})
	if poison > 0:
		result.append({"id": &"poison", "turns": 2, "power": 2 * poison})
	return result


static func _self_effects(ability: Ability3D, soul_kind: int, type_card: StringName, extra_type: int,
		counts: Dictionary) -> void:
	var turns := BUFF_TURNS + extra_type
	if type_card == SkillCards3D.TYPE_HEAL:
		ability.heal_ratio = HEAL_RATIO + HEAL_RATIO_PER_EXTRA * extra_type
		turns = 1
	var fire := int(counts.get(SkillCards3D.ELEMENT_FIRE, 0))
	var frost := int(counts.get(SkillCards3D.ELEMENT_FROST, 0))
	var lightning := int(counts.get(SkillCards3D.ELEMENT_LIGHTNING, 0))
	var poison := int(counts.get(SkillCards3D.ELEMENT_POISON, 0))
	if fire > 0:
		ability.buffs.append({"id": &"empower", "turns": turns, "power": EMPOWER_PER_FIRE * fire})
	if frost > 0:
		ability.buffs.append({"id": &"ward", "turns": turns,
			"power": mini(WARD_MAX, WARD_BASE + WARD_PER_EXTRA_FROST * (frost - 1))})
	if lightning > 0:
		ability.buffs.append({"id": &"haste", "turns": turns, "power": HASTE_BASE_M + (lightning - 1)})
	if poison > 0:
		ability.buffs.append({"id": &"envenom", "turns": turns, "power": ENVENOM_POWER + 2 * (poison - 1)})
	if ability.buffs.is_empty() and type_card == SkillCards3D.TYPE_BUFF:
		match soul_kind:
			Soul.Kind.KNIGHT:
				ability.buffs.append({"id": &"ward", "turns": turns, "power": int(DEFAULT_BUFF_POWER[soul_kind])})
			Soul.Kind.ROGUE:
				ability.buffs.append({"id": &"vanish", "turns": 1, "power": 1})
			_:
				ability.buffs.append({"id": &"empower", "turns": turns, "power": int(DEFAULT_BUFF_POWER[soul_kind])})


# --- Names and text ---------------------------------------------------------------

static func _name_for(ability: Ability3D, soul_kind: int, main_element: StringName, extra_type: int) -> String:
	var special := _special_name(ability, soul_kind, main_element)
	var base := special
	if base.is_empty():
		var word: String = ELEMENT_WORD.get(main_element, PLAIN_WORD.get(soul_kind, "")) as String
		base = "%s %s" % [word, _noun(ability, soul_kind)]
	match extra_type:
		1:
			base += " II"
		2:
			base += " III"
	return base


static func _special_name(ability: Ability3D, soul_kind: int, main_element: StringName) -> String:
	var type_card := ability.type_card
	match ability.delivery:
		Ability3D.Delivery.BOLT:
			if type_card == SkillCards3D.TYPE_DAMAGE and main_element == SkillCards3D.ELEMENT_FIRE and ability.radius_m > 0.0:
				return "Fireball"
		Ability3D.Delivery.CHAIN:
			if type_card == SkillCards3D.TYPE_DAMAGE:
				return "Chain Lightning"
		Ability3D.Delivery.NOVA:
			if type_card == SkillCards3D.TYPE_DAMAGE and main_element == SkillCards3D.ELEMENT_FROST:
				return "Frost Nova"
		Ability3D.Delivery.FIELD:
			if type_card == SkillCards3D.TYPE_DAMAGE and main_element == SkillCards3D.ELEMENT_FIRE:
				return "Fire Trap"
		Ability3D.Delivery.STRIKE:
			if soul_kind == Soul.Kind.ROGUE and type_card == SkillCards3D.TYPE_AFFLICTION and main_element == SkillCards3D.ELEMENT_POISON:
				return "Poison Blade"
			if soul_kind == Soul.Kind.KNIGHT and type_card == SkillCards3D.TYPE_CONTROL and main_element == &"":
				return "Shield Bash"
		Ability3D.Delivery.SWEEP:
			if type_card == SkillCards3D.TYPE_DAMAGE and main_element == &"":
				return "Cleave"
		Ability3D.Delivery.LEAP:
			if type_card == SkillCards3D.TYPE_DAMAGE and main_element == &"" and ability.radius_m <= 0.0:
				return "Charge"
		Ability3D.Delivery.SELF:
			if soul_kind == Soul.Kind.KNIGHT and type_card == SkillCards3D.TYPE_HEAL and main_element == &"":
				return "Second Wind"
			if not ability.buffs.is_empty() and ability.buffs[0]["id"] == &"vanish":
				return "Smoke Bomb"
	return ""


static func _noun(ability: Ability3D, soul_kind: int) -> String:
	var t := ability.type_card
	match ability.delivery:
		Ability3D.Delivery.BOLT:
			return _by_type(t, "Burst" if ability.radius_m > 0.0 else "Bolt", "Curse", "Bind")
		Ability3D.Delivery.CHAIN:
			return _by_type(t, "Chain", "Chain Curse", "Chain Bind")
		Ability3D.Delivery.NOVA:
			return _by_type(t, "Nova", "Blight", "Shackles")
		Ability3D.Delivery.THROW:
			return _by_type(t, "Knife", "Dart", "Bola")
		Ability3D.Delivery.STRIKE:
			if soul_kind == Soul.Kind.ROGUE:
				return _by_type(t, "Stab", "Blade", "Hamstring")
			return _by_type(t, "Strike", "Brand", "Bash")
		Ability3D.Delivery.FIELD:
			return _by_type(t, "Trap", "Mire", "Snare")
		Ability3D.Delivery.LEAP:
			return _by_type(t, "Slam" if ability.radius_m > 0.0 else "Leap", "Brand Leap", "Charge")
		Ability3D.Delivery.SWEEP:
			return _by_type(t, "Sweep", "Brand Sweep", "Shove")
		Ability3D.Delivery.SELF:
			if t == SkillCards3D.TYPE_HEAL:
				return "Mend"
			match _first_buff(ability):
				&"ward":
					return "Ward"
				&"haste":
					return "Haste"
				&"envenom":
					return "Coat"
				_:
					return "Fury"
		Ability3D.Delivery.TOTEM:
			match soul_kind:
				Soul.Kind.KNIGHT:
					return "Banner"
				Soul.Kind.ROGUE:
					return "Shade"
			return "Spirit"
	return "Skill"


## One or two plain sentences for the forge and the tooltip.
static func describe(ability: Ability3D) -> String:
	var how := ""
	match ability.delivery:
		Ability3D.Delivery.BOLT:
			how = "A bolt at an enemy within %d m" % int(round(ability.range_m))
			if ability.radius_m > 0.0:
				how += ", bursting over %.1f m" % ability.radius_m
		Ability3D.Delivery.CHAIN:
			how = "A bolt at an enemy within %d m that jumps to %d more" % [int(round(ability.range_m)), ability.chain_jumps]
		Ability3D.Delivery.NOVA:
			how = "A burst of %.1f m around you" % ability.radius_m
		Ability3D.Delivery.THROW:
			how = "A thrown blade at an enemy within %d m" % int(round(ability.range_m))
		Ability3D.Delivery.STRIKE:
			how = "A weapon strike"
			if ability.exposed_mult > 1.0:
				how += " (x%.1f on an unaware, stunned, rooted or turned enemy)" % ability.exposed_mult
		Ability3D.Delivery.FIELD:
			if ability.target == Ability3D.Target.SELF:
				how = "A trap field of %.1f m around you" % ability.radius_m
			else:
				how = "A trap field of %.1f m up to %d m away" % [ability.radius_m, int(round(ability.range_m))]
			how += " for %d turns, striking every enemy inside once a turn" % ability.lasting_turns
		Ability3D.Delivery.LEAP:
			how = "Leap at an enemy within %d m and strike" % int(round(ability.range_m))
			if ability.radius_m > 0.0:
				how += " everyone within %.1f m of the landing" % ability.radius_m
		Ability3D.Delivery.SWEEP:
			how = "A sweep through everyone within %.1f m" % ability.radius_m
		Ability3D.Delivery.SELF:
			how = "On you"
		Ability3D.Delivery.TOTEM:
			how = "A spirit up to %d m away for %d turns; at the start of your turn it strikes %s within %.1f m" \
				% [int(round(ability.range_m)), ability.lasting_turns,
				"every enemy" if ability.radius_m > 0.0 else "the nearest enemy", ability.totem_reach_m]
	var effects: Array[String] = []
	if ability.flat_damage > 0 or ability.damage_mult > 0.0:
		var damage_text := "%d damage" % ability.flat_damage
		if ability.damage_mult > 0.0:
			damage_text += " + %d%% of your weapon" % int(round(ability.damage_mult * 100.0))
		effects.append(damage_text)
	for status in ability.statuses:
		effects.append(_status_text(status))
	if ability.knockback_m > 0.0:
		effects.append("knockback %.1f m" % ability.knockback_m)
	if ability.heal_ratio > 0.0:
		effects.append("heals %d%% of your health" % int(round(ability.heal_ratio * 100.0)))
	for buff in ability.buffs:
		effects.append(buff_text(buff))
	var text := how
	if not effects.is_empty():
		text += ": " + ", ".join(effects)
	text += "."
	if not ability.wasted_cards.is_empty():
		var names: Array[String] = []
		for card_id in ability.wasted_cards:
			names.append(SkillCards3D.display_name(card_id))
		text += " (%s: no effect here)" % ", ".join(names)
	return text


static func _status_text(status: Dictionary) -> String:
	var turns := int(status.get("turns", 1))
	var power := int(status.get("power", 0))
	match status.get("id", &""):
		&"burn":
			return "burn %d a turn for %d turns" % [power, turns]
		&"poison":
			return "poison %d a turn for %d turns" % [power, turns]
		&"root":
			return "root %d turn%s" % [turns, "" if turns == 1 else "s"]
		&"stun":
			return "stun %d turn%s" % [turns, "" if turns == 1 else "s"]
		&"weaken":
			return "weaken (half damage) %d turn%s" % [turns, "" if turns == 1 else "s"]
		&"expose":
			return "expose (+50%% damage taken) %d turn%s" % [turns, "" if turns == 1 else "s"]
	return String(status.get("id", ""))


static func buff_text(buff: Dictionary) -> String:
	var turns := int(buff.get("turns", 1))
	var power := int(buff.get("power", 0))
	var span := "%d turn%s" % [turns, "" if turns == 1 else "s"]
	match buff.get("id", &""):
		&"empower":
			return "+%d%% damage for %s" % [power, span]
		&"ward":
			return "%d%% less damage taken for %s" % [power, span]
		&"haste":
			return "+%d m movement for %s" % [power, span]
		&"envenom":
			return "your hits poison (%d a turn) for %s" % [power, span]
		&"vanish":
			return "vanish in smoke"
	return String(buff.get("id", ""))


# --- Helpers ----------------------------------------------------------------------

static func _by_type(type_card: StringName, damage: String, affliction: String, control: String) -> String:
	if type_card == SkillCards3D.TYPE_AFFLICTION:
		return affliction
	if type_card == SkillCards3D.TYPE_CONTROL:
		return control
	return damage


static func _first_buff(ability: Ability3D) -> StringName:
	if ability.buffs.is_empty():
		return &""
	return ability.buffs[0].get("id", &"") as StringName


static func _count(cards: Array[StringName]) -> Dictionary:
	var counts := {}
	for card_id in cards:
		counts[card_id] = int(counts.get(card_id, 0)) + 1
	return counts


static func _main_element(counts: Dictionary) -> StringName:
	var best := StringName()
	var best_count := 0
	for element in ELEMENT_ORDER:
		var count := int(counts.get(element, 0))
		if count > best_count:
			best = element
			best_count = count
	return best


## Cards in collection order (type, elements, modifiers), for stable display.
static func _sorted(cards: Array[StringName]) -> Array[StringName]:
	var result: Array[StringName] = []
	for card in SkillCards3D.CARDS:
		for card_id in cards:
			if card_id == card["id"]:
				result.append(card_id)
	return result


static func _soul_color(soul_kind: int) -> Color:
	match soul_kind:
		Soul.Kind.KNIGHT:
			return Soul.COLOR_KNIGHT
		Soul.Kind.ROGUE:
			return Soul.COLOR_ROGUE
	return Soul.COLOR_MAGE


## The action bar glyph for a card skill.
static func icon_for(ability: Ability3D) -> StringName:
	match ability.delivery:
		Ability3D.Delivery.BOLT:
			if ability.radius_m > 0.0:
				return &"fireball" if ability.color == SkillCards3D.COLOR_FIRE else &"arcane_burst"
			return &"arcane_burst"
		Ability3D.Delivery.CHAIN:
			return &"chain_lightning"
		Ability3D.Delivery.NOVA:
			return &"frost_nova"
		Ability3D.Delivery.THROW:
			return &"throw"
		Ability3D.Delivery.STRIKE:
			if ability.type_card == SkillCards3D.TYPE_AFFLICTION:
				return &"poison_blade"
			if ability.type_card == SkillCards3D.TYPE_CONTROL:
				return &"shield_bash"
			return &"backstab" if ability.soul_kind == Soul.Kind.ROGUE else &"melee"
		Ability3D.Delivery.FIELD:
			return &"set_snare"
		Ability3D.Delivery.LEAP:
			return &"charge"
		Ability3D.Delivery.SWEEP:
			return &"cleave"
		Ability3D.Delivery.SELF:
			if ability.type_card == SkillCards3D.TYPE_HEAL:
				return &"second_wind"
			match _first_buff(ability):
				&"ward":
					return &"block"
				&"haste":
					return &"charge"
				&"envenom":
					return &"poison_blade"
				&"vanish":
					return &"smoke_bomb"
			return &"arcane_burst"
		Ability3D.Delivery.TOTEM:
			return &"summon"
	return &""
