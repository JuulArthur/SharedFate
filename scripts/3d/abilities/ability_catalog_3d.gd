class_name AbilityCatalog3D
extends RefCounted

## Every active ability in the game, authored in one place so balance is one
## file. Each soul has a distinct kit on top of its old tools (the knight's
## Block stance, the rogue's throw, the mage's two spells):
##
##   Knight - control and protection: stun, knock back, hit everything around,
##            charge across the field, patch the body up.
##   Rogue  - mobility and burst: step behind, stab the exposed, poison, vanish,
##            lay snares. A kill refunds the rogue's action once per turn.
##   Mage   - area and position: blink, burn a group, chain lightning, freeze
##            everything close.
##
## `id` values are what `Progression3D` stores. Order inside a soul is the order
## on the ability bar and in the skill tree.

const SHIELD_BASH := &"shield_bash"
const CLEAVE := &"cleave"
const SECOND_WIND := &"second_wind"
const CHARGE := &"charge"
const BACKSTAB := &"backstab"
const SHADOWSTEP := &"shadowstep"
const POISON_BLADE := &"poison_blade"
const SET_SNARE := &"set_snare"
const SMOKE_BOMB := &"smoke_bomb"
const BLINK := &"blink"
const FIREBALL := &"fireball"
const CHAIN_LIGHTNING := &"chain_lightning"
const FROST_NOVA := &"frost_nova"
const DISTRACT := &"distract"

# --- Balance ------------------------------------------------------------------
const SHIELD_BASH_DAMAGE := 8
const SHIELD_BASH_KNOCKBACK_M := 1.5
const CLEAVE_MULT := 0.8
const CLEAVE_RADIUS_M := 2.0
const SECOND_WIND_HEAL_RATIO := 0.25
const CHARGE_RANGE_M := 7.0
const CHARGE_MULT := 1.25
const BACKSTAB_MULT := 2.2
const SHADOWSTEP_RANGE_M := 8.0
const POISON_BLADE_MULT := 0.8
const POISON_POWER := 5
const SET_SNARE_RANGE_M := 4.0
const SMOKE_BOMB_RADIUS_M := 3.0
const BLINK_RANGE_M := 7.0
const FIREBALL_DAMAGE := 16
const FIREBALL_RADIUS_M := 2.5
const BURN_POWER := 4
const CHAIN_LIGHTNING_DAMAGE := 13
const CHAIN_LIGHTNING_JUMP_M := 4.0
const CHAIN_LIGHTNING_JUMPS := 2
const FROST_NOVA_DAMAGE := 6
const FROST_NOVA_RADIUS_M := 3.5
const DISTRACT_RANGE_M := 12.0
const DISTRACT_RADIUS_M := 7.0

const COLOR_KNIGHT := Color(0.58, 0.74, 1.0, 1.0)
const COLOR_ROGUE := Color(0.55, 0.93, 0.60, 1.0)
const COLOR_MAGE := Color(0.80, 0.62, 1.0, 1.0)
const COLOR_FIRE := Color(1.0, 0.55, 0.2, 1.0)
const COLOR_FROST := Color(0.62, 0.88, 1.0, 1.0)
const COLOR_LIGHTNING := Color(0.75, 0.9, 1.0, 1.0)
const COLOR_POISON := Color(0.55, 0.95, 0.35, 1.0)
const COLOR_SMOKE := Color(0.62, 0.6, 0.7, 1.0)

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


## The abilities a soul can ever have, bar order. Abilities for any soul come
## last.
static func for_soul(soul_kind: int) -> Array[Ability3D]:
	var result: Array[Ability3D] = []
	for ability in all():
		if ability.soul_kind == soul_kind:
			result.append(ability)
	for ability in all():
		if ability.soul_kind == Ability3D.ANY_SOUL:
			result.append(ability)
	return result


static func _build() -> Array[Ability3D]:
	var list: Array[Ability3D] = []

	# --- Knight -----------------------------------------------------------------
	var bash := _make(SHIELD_BASH, Soul.Kind.KNIGHT, "Shield Bash", COLOR_KNIGHT,
		"Slam the shield into an enemy: a little damage, it is stunned through its next turn and knocked back.")
	bash.flat_damage = SHIELD_BASH_DAMAGE
	bash.status_id = &"stun"
	bash.status_turns = 1
	bash.knockback_m = SHIELD_BASH_KNOCKBACK_M
	bash.cooldown_turns = 3
	bash.starts_unlocked = true
	list.append(bash)

	var cleave := _make(CLEAVE, Soul.Kind.KNIGHT, "Cleave", COLOR_KNIGHT,
		"A wide sweep that hits every enemy within 2 m for most of a sword blow.")
	cleave.target = Ability3D.Target.SELF
	cleave.radius_m = CLEAVE_RADIUS_M
	cleave.damage_mult = CLEAVE_MULT
	cleave.cooldown_turns = 2
	cleave.unlock_level = 2
	list.append(cleave)

	var wind := _make(SECOND_WIND, Soul.Kind.KNIGHT, "Second Wind", COLOR_KNIGHT,
		"Catch a breath behind the shield: heal a quarter of the body's health. Bonus action.")
	wind.target = Ability3D.Target.SELF
	wind.cost = Ability3D.Cost.BONUS
	wind.cooldown_turns = 4
	wind.unlock_level = 3
	list.append(wind)

	var charge := _make(CHARGE, Soul.Kind.KNIGHT, "Charge", COLOR_KNIGHT,
		"Rush up to 7 m straight at an enemy without spending movement, hit it hard and knock it back.")
	charge.range_m = CHARGE_RANGE_M
	charge.damage_mult = CHARGE_MULT
	charge.knockback_m = 1.0
	charge.cooldown_turns = 3
	charge.unlock_level = 4
	list.append(charge)

	# --- Rogue ------------------------------------------------------------------
	var backstab := _make(BACKSTAB, Soul.Kind.ROGUE, "Backstab", COLOR_ROGUE,
		"A knife where it hurts: %.1fx damage against an enemy that is stunned, rooted, unaware or turned away, a plain stab otherwise." % BACKSTAB_MULT)
	backstab.damage_mult = 1.0
	backstab.starts_unlocked = true
	list.append(backstab)

	var step := _make(SHADOWSTEP, Soul.Kind.ROGUE, "Shadowstep", COLOR_ROGUE,
		"Vanish and reappear right behind an enemy up to 8 m away, facing its back. Bonus action.")
	step.cost = Ability3D.Cost.BONUS
	step.range_m = SHADOWSTEP_RANGE_M
	step.cooldown_turns = 3
	step.starts_unlocked = true
	list.append(step)

	var poison := _make(POISON_BLADE, Soul.Kind.ROGUE, "Poison Blade", COLOR_POISON,
		"A shallow cut with a coated blade: it takes %d poison damage at the start of each of its next 3 turns." % POISON_POWER)
	poison.damage_mult = POISON_BLADE_MULT
	poison.status_id = &"poison"
	poison.status_turns = 3
	poison.status_power = POISON_POWER
	poison.cooldown_turns = 2
	poison.unlock_level = 2
	list.append(poison)

	var snare := _make(SET_SNARE, Soul.Kind.ROGUE, "Set Snare", COLOR_ROGUE,
		"Hide a spiked snare on the ground within 4 m. The first enemy to step on it is hurt and rooted. Bonus action.")
	snare.target = Ability3D.Target.GROUND
	snare.cost = Ability3D.Cost.BONUS
	snare.range_m = SET_SNARE_RANGE_M
	snare.cooldown_turns = 3
	snare.unlock_level = 3
	list.append(snare)

	var smoke := _make(SMOKE_BOMB, Soul.Kind.ROGUE, "Smoke Bomb", COLOR_SMOKE,
		"Burst of smoke: enemies lose track of the body until your next turn and cannot strike it. End the turn out of their reach to slip away from the fight. Outside a fight: 6 s unseen.")
	smoke.target = Ability3D.Target.SELF
	smoke.radius_m = SMOKE_BOMB_RADIUS_M
	smoke.cooldown_turns = 4
	smoke.unlock_level = 4
	list.append(smoke)

	# --- Mage -------------------------------------------------------------------
	var blink := _make(BLINK, Soul.Kind.MAGE, "Blink", COLOR_MAGE,
		"Fold space: teleport to a point up to 7 m away. Bonus action.")
	blink.target = Ability3D.Target.GROUND
	blink.cost = Ability3D.Cost.BONUS
	blink.range_m = BLINK_RANGE_M
	blink.cooldown_turns = 2
	blink.starts_unlocked = true
	list.append(blink)

	var fireball := _make(FIREBALL, Soul.Kind.MAGE, "Fireball", COLOR_FIRE,
		"A ball of fire that bursts on impact: %d damage to every enemy within %.1f m, and they burn for 2 turns." % [FIREBALL_DAMAGE, FIREBALL_RADIUS_M])
	fireball.range_m = Soul.MAGE_SPELL_RANGE_METERS
	fireball.radius_m = FIREBALL_RADIUS_M
	fireball.flat_damage = FIREBALL_DAMAGE
	fireball.status_id = &"burn"
	fireball.status_turns = 2
	fireball.status_power = BURN_POWER
	fireball.cooldown_turns = 3
	fireball.unlock_level = 2
	list.append(fireball)

	var chain := _make(CHAIN_LIGHTNING, Soul.Kind.MAGE, "Chain Lightning", COLOR_LIGHTNING,
		"Lightning that leaps from the target to up to two more enemies within 4 m of each other, weaker with every jump.")
	chain.range_m = 9.0
	chain.flat_damage = CHAIN_LIGHTNING_DAMAGE
	chain.cooldown_turns = 2
	chain.unlock_level = 3
	list.append(chain)

	var nova := _make(FROST_NOVA, Soul.Kind.MAGE, "Frost Nova", COLOR_FROST,
		"Freeze the air around the body: every enemy within %.1f m takes a little damage and is rooted." % FROST_NOVA_RADIUS_M)
	nova.target = Ability3D.Target.SELF
	nova.radius_m = FROST_NOVA_RADIUS_M
	nova.flat_damage = FROST_NOVA_DAMAGE
	nova.status_id = &"root"
	nova.status_turns = 1
	nova.cooldown_turns = 4
	nova.unlock_level = 4
	list.append(nova)

	# --- Any soul ---------------------------------------------------------------
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
