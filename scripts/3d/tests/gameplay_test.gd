extends Node

## Headless test of the gameplay systems the coordinator leads
## (docs/gameplay-expansion.md, docs/cards-and-attributes.md): attributes per
## soul, the card skill compiler, the character screen and the forge at a rest
## point, card skills in a fight (a trap field, a buff then a bolt, a summoned
## spirit) with mana and stamina, per-soul movement, sneaking and the detection
## multiplier, slipping away from a fight (by distance and by smoke), respawn
## after a defeat and the coordinator interface. Instances the arena without
## its IntegrationSmoke node.
##
##   godot --headless --path . res://scenes/3d/tests/gameplay_test.tscn --quit-after 6000
##
## Prints GAMEPLAY OK or GAMEPLAY FAIL: <step>: <reason>.

const Main3D := preload("res://scripts/3d/main_3d.gd")
const ARENA := preload("res://scenes/3d/arena.tscn")
const HEADLESS_FPS := 60
const COMBAT_TIMEOUT_SECONDS := 6.0
const ENEMY_TURN_TIMEOUT_SECONDS := 10.0
const PARK_B := Vector3(10.0, 0.0, -10.0)
const PARK_C := Vector3(10.0, 0.0, 10.0)

const C := preload("res://scripts/3d/cards/skill_cards_3d.gd")

var _main: Main3D
var _player: Player3D
var _progression: Progression3D
var _wolves: Array[Enemy3D] = []
var _step := "boot"
var _done := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	Engine.max_fps = HEADLESS_FPS
	var arena := ARENA.instantiate()
	var smoke := arena.get_node_or_null("IntegrationSmoke")
	if smoke != null:
		arena.remove_child(smoke)
		smoke.free()
	add_child(arena)
	_main = arena as Main3D
	call_deferred("_run")


func _exit_tree() -> void:
	if not _done:
		print("GAMEPLAY FAIL: quit during step '%s'" % _step)


func _run() -> void:
	await get_tree().process_frame
	var steps: Array = [
		["boot", _step_boot],
		["attributes", _step_attributes],
		["compiler", _step_compiler],
		["character_screen", _step_character_screen],
		["forge", _step_forge],
		["sneak", _step_sneak],
		["soul_movement", _step_soul_movement],
		["trap_field", _step_trap_field],
		["turn_upkeep", _step_turn_upkeep],
		["buff_then_bolt", _step_buff_then_bolt],
		["summon", _step_summon],
		["spawned_enemy", _step_spawned_enemy],
		["escape_by_distance", _step_escape_by_distance],
		["escape_by_smoke", _step_escape_by_smoke],
		["exploration_refill", _step_exploration_refill],
		["card_drops", _step_card_drops],
		["respawn", _step_respawn],
	]
	for entry in steps:
		_step = String(entry[0])
		var step: Callable = entry[1]
		var result: Variant = await step.call()
		var failure := str(result)
		if not failure.is_empty():
			_done = true
			print("GAMEPLAY FAIL: %s: %s" % [_step, failure])
			get_tree().quit(1)
			return
		print("[gameplay] %s ok" % _step)
	_done = true
	print("GAMEPLAY OK")
	get_tree().quit(0)


# --- Steps ---------------------------------------------------------------------------

func _step_boot() -> String:
	_player = _main.player as Player3D
	if _player == null:
		return "no Player3D"
	_progression = _player.get_progression()
	if _progression == null:
		return "the player has no Progression3D"
	for node in get_tree().get_nodes_in_group("enemies"):
		var wolf := node as Enemy3D
		if wolf != null and _main.is_ancestor_of(wolf):
			_wolves.append(wolf)
	_wolves.sort_custom(func(a: Enemy3D, b: Enemy3D) -> bool: return String(a.name) < String(b.name))
	if _wolves.size() < 3:
		return "expected 3 wolves, found %d" % _wolves.size()
	if not await _wait_until(func() -> bool: return _main.is_navmesh_ready(), 5.0):
		return "navmesh not ready"
	if _main.ability_runner == null or _main.ability_runner.player != _player:
		return "the coordinator has no AbilityRunner wired to the player"
	if not _main.is_in_group("level_coordinator"):
		return "the coordinator is not in group level_coordinator"
	# Keep the wolves out of the way until a step wants one.
	_wolves[0].snap_to(Vector3(8.0, 0.0, 0.0))
	_wolves[1].snap_to(PARK_B)
	_wolves[2].snap_to(PARK_C)
	return ""


## Points go to one soul at a time; each soul reads them its own way.
func _step_attributes() -> String:
	if _progression.attribute_points != Progression3D.STARTING_ATTRIBUTE_POINTS:
		return "%d attribute points at start, expected %d" % [_progression.attribute_points, Progression3D.STARTING_ATTRIBUTE_POINTS]
	if _progression.total_cards() != 0 or _main._bar_abilities()[0] != null:
		return "the body starts with cards or skills"
	# Knight Power: the knight hits 10 % harder.
	var knight_damage := _player.get_melee_damage()
	if not _progression.raise_attribute(Soul.Kind.KNIGHT, Progression3D.ATTR_POWER):
		return "knight Power refused: %s" % _progression.attribute_block_reason(Soul.Kind.KNIGHT, Progression3D.ATTR_POWER)
	var raised := _player.get_melee_damage()
	if raised != int(round(knight_damage * 1.1)) and raised <= knight_damage:
		return "knight melee %d -> %d after a Power point" % [knight_damage, raised]
	# Mage Energy: a bigger mana pool, arriving filled.
	var mage_max := _progression.pool_max(Soul.Kind.MAGE)
	_progression.raise_attribute(Soul.Kind.MAGE, Progression3D.ATTR_ENERGY)
	if _progression.pool_max(Soul.Kind.MAGE) != mage_max + Progression3D.ENERGY_POOL_PER_POINT:
		return "mage mana max %d -> %d after an Energy point" % [mage_max, _progression.pool_max(Soul.Kind.MAGE)]
	if _progression.get_pool(Soul.Kind.MAGE) != _progression.pool_max(Soul.Kind.MAGE):
		return "the new mana did not arrive filled"
	# Rogue Finesse: movement (checked in soul_movement).
	_progression.raise_attribute(Soul.Kind.ROGUE, Progression3D.ATTR_FINESSE)
	if _progression.attribute_points != 0:
		return "%d points left after spending three" % _progression.attribute_points
	if _progression.raise_attribute(Soul.Kind.KNIGHT, Progression3D.ATTR_POWER):
		return "a point was spent with none left"
	var health_before := _player.max_health
	_player.add_experience(int(_player.get_xp_required_for_next_level()))
	if _player.get_player_level() != 2:
		return "level %d after a level's worth of XP" % _player.get_player_level()
	if _progression.attribute_points != Progression3D.ATTRIBUTE_POINTS_PER_LEVEL:
		return "%d attribute points after the level up" % _progression.attribute_points
	if _player.max_health != health_before + Progression3D.HEALTH_PER_LEVEL:
		return "max health %d -> %d, expected +%d per level" % [health_before, _player.max_health, Progression3D.HEALTH_PER_LEVEL]
	return ""


## The same cards become different skills for different souls; copies stack.
func _step_compiler() -> String:
	var fire_ranged_area: Array[StringName] = [C.TYPE_DAMAGE, C.ELEMENT_FIRE, C.MOD_RANGED, C.MOD_AREA]
	var mage := CardSkillCompiler3D.compile(Soul.Kind.MAGE, fire_ranged_area)
	var rogue := CardSkillCompiler3D.compile(Soul.Kind.ROGUE, fire_ranged_area)
	var knight := CardSkillCompiler3D.compile(Soul.Kind.KNIGHT, fire_ranged_area)
	if mage == null or rogue == null or knight == null:
		return "a valid hand did not compile"
	if mage.delivery != Ability3D.Delivery.BOLT or mage.radius_m <= 0.0 or mage.display_name != "Fireball":
		return "mage got %s (delivery %d, radius %.1f)" % [mage.display_name, mage.delivery, mage.radius_m]
	if rogue.delivery != Ability3D.Delivery.FIELD or rogue.target != Ability3D.Target.GROUND or rogue.display_name != "Fire Trap":
		return "rogue got %s (delivery %d)" % [rogue.display_name, rogue.delivery]
	if knight.delivery != Ability3D.Delivery.LEAP or knight.radius_m <= 0.0:
		return "knight got %s (delivery %d)" % [knight.display_name, knight.delivery]
	if mage.resource_cost != C.COST_TYPE + C.COST_ELEMENT + 2 * C.COST_MODIFIER:
		return "Fireball costs %d" % mage.resource_cost
	if not _has_status(mage, &"burn"):
		return "Fireball does not burn"
	# Stacking: more Fire hits and burns harder, more Area reaches wider.
	var stacked_cards: Array[StringName] = [C.TYPE_DAMAGE, C.ELEMENT_FIRE, C.ELEMENT_FIRE, C.MOD_AREA, C.MOD_AREA]
	var single_cards: Array[StringName] = [C.TYPE_DAMAGE, C.ELEMENT_FIRE, C.MOD_AREA]
	var stacked := CardSkillCompiler3D.compile(Soul.Kind.MAGE, stacked_cards)
	var single := CardSkillCompiler3D.compile(Soul.Kind.MAGE, single_cards)
	if stacked.radius_m <= single.radius_m or stacked.flat_damage <= single.flat_damage:
		return "stacking did not grow the skill (radius %.1f vs %.1f, damage %d vs %d)" \
			% [stacked.radius_m, single.radius_m, stacked.flat_damage, single.flat_damage]
	if _status_power(stacked, &"burn") <= _status_power(single, &"burn"):
		return "two Fire cards burn no harder than one"
	var double_type: Array[StringName] = [C.TYPE_DAMAGE, C.TYPE_DAMAGE, C.ELEMENT_FROST]
	var ranked := CardSkillCompiler3D.compile(Soul.Kind.KNIGHT, double_type)
	if ranked == null or not ranked.display_name.ends_with(" II"):
		return "two Damage cards are not a rank II skill"
	# Buffs and heals are bonus actions on the body.
	var buff_cards: Array[StringName] = [C.TYPE_BUFF, C.ELEMENT_FROST]
	var buff := CardSkillCompiler3D.compile(Soul.Kind.KNIGHT, buff_cards)
	if buff.cost != Ability3D.Cost.BONUS or buff.target != Ability3D.Target.SELF or buff.buffs.is_empty():
		return "a Frost buff is not a bonus self buff"
	# Invalid hands.
	var no_type: Array[StringName] = [C.ELEMENT_FIRE, C.MOD_AREA]
	var two_types: Array[StringName] = [C.TYPE_DAMAGE, C.TYPE_HEAL]
	var ranged_close: Array[StringName] = [C.TYPE_DAMAGE, C.MOD_RANGED, C.MOD_CLOSE]
	var too_many: Array[StringName] = [C.TYPE_DAMAGE, C.ELEMENT_FIRE, C.ELEMENT_FIRE, C.ELEMENT_FIRE, C.MOD_AREA, C.MOD_AREA]
	for hand in [no_type, two_types, ranged_close, too_many]:
		var typed_hand: Array[StringName] = []
		typed_hand.assign(hand)
		if CardSkillCompiler3D.validate(typed_hand).is_empty():
			return "an invalid hand passed: %s" % str(hand)
	# The first card found is always a type card, so it can become a skill.
	var fresh := Progression3D.new()
	var rng := RandomNumberGenerator.new()
	for i in range(20):
		rng.seed = i
		if C.category_of(fresh.roll_drop(rng)) != C.Category.TYPE:
			fresh.free()
			return "a first drop was not a type card"
	fresh.free()
	return ""


func _step_character_screen() -> String:
	var screen := _main.character_screen
	if screen == null:
		return "no character screen"
	_main._request_shift(int(Soul.Kind.MAGE))
	_main._toggle_character_screen()
	if not screen.is_open() or not get_tree().paused:
		return "K did not open the screen and pause the world"
	if screen.get_selected_soul() != Soul.Kind.MAGE:
		return "the screen opened on soul %d, not the mage in control" % screen.get_selected_soul()
	await get_tree().process_frame
	_main._toggle_character_screen()
	if screen.is_open() or get_tree().paused:
		return "the screen did not close and unpause"
	_main._request_shift(int(Soul.Kind.KNIGHT))
	return ""


## Cards are forged into skills only by a campfire or waystone.
func _step_forge() -> String:
	var hand := {C.TYPE_DAMAGE: 2, C.ELEMENT_FIRE: 3, C.MOD_RANGED: 1, C.MOD_AREA: 2,
		C.TYPE_BUFF: 2, C.TYPE_SUMMON: 1, C.ELEMENT_LIGHTNING: 1}
	for card_id in hand:
		_progression.add_card(card_id, int(hand[card_id]))
	var reason := _main.forge_block_reason()
	if reason.is_empty():
		print("[gameplay] note: the arena spawn is already by a rest point; refusal not checked")
	var campfire := Campfire3D.new()
	campfire.name = "TestCampfire"
	_main.add_child(campfire)
	campfire.global_position = _player.global_position + Vector3(0.0, 0.0, 2.5)
	await get_tree().physics_frame
	if not _main.forge_block_reason().is_empty():
		campfire.queue_free()
		return "refused by the campfire: %s" % _main.forge_block_reason()

	var screen := _main.character_screen
	screen.set_open(true, Soul.Kind.MAGE)
	for card_id in [C.TYPE_DAMAGE, C.ELEMENT_FIRE, C.MOD_RANGED, C.MOD_AREA]:
		if not screen.add_to_bench(card_id):
			return "the bench refused %s" % card_id
	if not screen.forge_bench():
		return "Forge refused: %s" % _progression.forge_block_reason(Soul.Kind.MAGE, 0, screen.get_bench())
	screen.set_open(false)
	if _progression.card_count(C.ELEMENT_FIRE) != 2 or _progression.card_count(C.MOD_RANGED) != 0:
		return "forging did not take the cards (fire %d, ranged %d)" % [_progression.card_count(C.ELEMENT_FIRE), _progression.card_count(C.MOD_RANGED)]
	var fireball := _progression.skill_ability(Soul.Kind.MAGE, 0)
	if fireball == null or fireball.display_name != "Fireball":
		return "the mage's slot 1 holds %s" % (fireball.display_name if fireball != null else "nothing")
	var no_lightning: Array[StringName] = [C.TYPE_DAMAGE, C.ELEMENT_LIGHTNING, C.ELEMENT_LIGHTNING]
	if _progression.forge_block_reason(Soul.Kind.MAGE, 2, no_lightning).is_empty():
		return "forging two Lightning cards with one owned was allowed"
	_forge(Soul.Kind.MAGE, 1, [C.TYPE_BUFF, C.ELEMENT_FIRE])
	_forge(Soul.Kind.MAGE, 2, [C.TYPE_SUMMON, C.ELEMENT_LIGHTNING])
	_forge(Soul.Kind.ROGUE, 0, [C.TYPE_DAMAGE, C.ELEMENT_FIRE, C.MOD_AREA])
	_forge(Soul.Kind.ROGUE, 1, [C.TYPE_BUFF])
	if _progression.skills_for_soul(Soul.Kind.ROGUE).size() != 2 or _progression.skills_for_soul(Soul.Kind.MAGE).size() != 3:
		return "skills: rogue %d, mage %d" % [_progression.skills_for_soul(Soul.Kind.ROGUE).size(), _progression.skills_for_soul(Soul.Kind.MAGE).size()]
	# Taking a skill apart returns its cards.
	var buffs_before := _progression.card_count(C.TYPE_BUFF)
	_progression.dismantle_skill(Soul.Kind.ROGUE, 1)
	if _progression.card_count(C.TYPE_BUFF) != buffs_before + 1:
		return "taking Smoke Bomb apart did not return its card"
	_forge(Soul.Kind.ROGUE, 1, [C.TYPE_BUFF])
	# The bar shows the soul in control's slots on keys 4-6.
	_main._request_shift(int(Soul.Kind.MAGE))
	var bar := _main._bar_abilities()
	if bar.size() < 3 or bar[0] == null or bar[0].display_name != "Fireball" or bar[2] == null:
		return "the mage's bar is wrong"
	_main._request_shift(int(Soul.Kind.KNIGHT))
	if _main._bar_abilities()[0] != null:
		return "the knight's bar shows a skill it does not have"
	campfire.queue_free()
	await get_tree().physics_frame
	return ""


func _step_sneak() -> String:
	if not is_equal_approx(_player.get_detection_multiplier(), 1.0):
		return "multiplier %.2f while walking upright" % _player.get_detection_multiplier()
	var speed := _player.move_speed
	_main._toggle_sneak()
	if not _player.is_sneaking():
		return "C did not start sneaking"
	if not is_equal_approx(_player.get_detection_multiplier(), Player3D.DETECTION_MULT_SNEAK):
		return "knight sneak multiplier %.2f" % _player.get_detection_multiplier()
	if _player.move_speed >= speed:
		return "sneaking did not slow the walk"
	_main._request_shift(int(Soul.Kind.ROGUE))
	if not is_equal_approx(_player.get_detection_multiplier(), Player3D.DETECTION_MULT_SNEAK_ROGUE):
		return "rogue sneak multiplier %.2f" % _player.get_detection_multiplier()
	var zone := Node.new()
	add_child(zone)
	_player.set_in_cover(zone, true)
	if not _player.is_hidden() or _player.get_detection_multiplier() != 0.0:
		return "sneaking in cover is not hidden"
	_player.set_in_cover(zone, false)
	zone.queue_free()
	var wolf := _wolves[0]
	var effective := wolf.get_effective_detection_range()
	if effective >= wolf.detection_range:
		return "the wolf's effective detection %.2f m did not shrink while sneaking" % effective
	if _player.stealth_multiplier_against(wolf) != Player3D.SNEAK_ATTACK_MULT_ROGUE:
		return "sneak attack multiplier %.1f against an unaware wolf" % _player.stealth_multiplier_against(wolf)
	_main._toggle_sneak()
	if _player.is_sneaking() or not is_equal_approx(_player.move_speed, speed):
		return "C did not stop sneaking and restore the walk"
	_main._request_shift(int(Soul.Kind.KNIGHT))
	return ""


func _step_soul_movement() -> String:
	await _start_fight_with(_wolves[0], 2.5)
	if _main.combat_state != Main3D.CombatState.PLAYER_TURN:
		return "no player turn (state %d)" % _main.combat_state
	var knight_budget := _player.get_turn_remaining_move_meters()
	if absf(knight_budget - Main3D.TURN_MOVE_METERS) > 0.01:
		return "knight budget %.2f m" % knight_budget
	_main._request_shift(int(Soul.Kind.ROGUE))
	# The rogue darts 2 m further, plus its one Finesse point.
	var expected := knight_budget + 2.0 + Progression3D.ROGUE_FINESSE_MOVE_PER_POINT
	var rogue_budget := _player.get_turn_remaining_move_meters()
	if absf(rogue_budget - expected) > 0.01:
		return "rogue budget %.2f m after the shift, expected %.2f" % [rogue_budget, expected]
	return ""


## The rogue's Fire Trap lays a burning field on the wolf, for stamina.
func _step_trap_field() -> String:
	var wolf := _wolves[0]
	var trap := _progression.skill_ability(Soul.Kind.ROGUE, 0)
	var stamina := _progression.get_pool(Soul.Kind.ROGUE)
	var before := wolf.health
	await _main._execute_ability(trap, null, GroundMath.flatten(wolf.global_position))
	if _main.ability_runner.get_fields().size() != 1:
		return "%d trap fields after Fire Trap" % _main.ability_runner.get_fields().size()
	if wolf.health >= before:
		return "the field did not strike the wolf standing in it (%d -> %d)" % [before, wolf.health]
	if not wolf.has_status(&"burn"):
		return "the wolf does not burn"
	if _progression.get_pool(Soul.Kind.ROGUE) != stamina - trap.resource_cost:
		return "stamina %d -> %d, expected -%d" % [stamina, _progression.get_pool(Soul.Kind.ROGUE), trap.resource_cost]
	if _player.has_action():
		return "Fire Trap did not spend the action"
	if _main.ability_runner.block_reason(trap).is_empty():
		return "a second action skill is allowed in the same turn"
	print("[gameplay] fire trap %d -> %d" % [before, wolf.health])
	return ""


## A new turn: the field strikes again, mana and stamina refill, the field
## counts down.
func _step_turn_upkeep() -> String:
	var wolf := _wolves[0]
	# Rooted, the wolf stays in the field through its turn.
	wolf.apply_status(&"root", 3)
	var field := _main.ability_runner.get_fields()[0]
	var turns := field.turns_left
	var stamina := _progression.get_pool(Soul.Kind.ROGUE)
	var before := wolf.health
	if not await _end_turn_and_wait():
		return "the enemy turn did not hand back"
	if _main.combat_state != Main3D.CombatState.PLAYER_TURN:
		return "the fight ended (state %d)" % _main.combat_state
	if not is_instance_valid(field) or field.turns_left != turns - 1:
		return "the field did not count down"
	if wolf.is_alive() and wolf.health >= before:
		return "the field did not strike at the turn start (%d -> %d)" % [before, wolf.health]
	var expected := mini(_progression.pool_max(Soul.Kind.ROGUE), stamina + _progression.pool_regen(Soul.Kind.ROGUE))
	if _progression.get_pool(Soul.Kind.ROGUE) != expected:
		return "stamina %d -> %d at the turn start, expected %d" % [stamina, _progression.get_pool(Soul.Kind.ROGUE), expected]
	return ""


## The mage's Flame Fury (bonus) empowers the Fireball (action) that follows.
func _step_buff_then_bolt() -> String:
	var wolf := _alive_wolf_near()
	if wolf == null:
		return "no wolf left"
	_main._request_shift(int(Soul.Kind.MAGE))
	var fury := _progression.skill_ability(Soul.Kind.MAGE, 1)
	var fireball := _progression.skill_ability(Soul.Kind.MAGE, 0)
	var plain_damage := _main.ability_runner.card_damage(fireball)
	await _main._execute_ability(fury, null, null)
	if not _player.has_buff(&"empower"):
		return "Flame Fury gave no Empower"
	if _player.has_bonus_action() or not _player.has_action():
		return "Flame Fury did not spend the bonus action alone"
	if _main.ability_runner.card_damage(fireball) <= plain_damage:
		return "Empower did not raise the Fireball (%d)" % plain_damage
	var mana := _progression.get_pool(Soul.Kind.MAGE)
	var before := wolf.health
	await _main._execute_ability(fireball, wolf, null)
	if wolf.health >= before and wolf.is_alive():
		return "Fireball did no damage (%d -> %d)" % [before, wolf.health]
	if _progression.get_pool(Soul.Kind.MAGE) != mana - fireball.resource_cost:
		return "mana %d -> %d, expected -%d" % [mana, _progression.get_pool(Soul.Kind.MAGE), fireball.resource_cost]
	if _main.ability_runner.get_cooldown(fireball.id) != fireball.cooldown_turns or fireball.cooldown_turns != 1:
		return "a four-card Fireball recharges %d turns" % _main.ability_runner.get_cooldown(fireball.id)
	print("[gameplay] fireball %d -> %d" % [before, wolf.health])
	return ""


## The mage's Storm Spirit strikes at the start of the next turn.
func _step_summon() -> String:
	if not await _end_turn_and_wait():
		return "the enemy turn did not hand back"
	# The trap field may kill the burning wolf as the turn starts, ending the
	# fight a frame later; then the next wolf starts a new one.
	await get_tree().process_frame
	await get_tree().process_frame
	var wolf := _alive_wolf_near()
	if wolf == null:
		return "no wolf left"
	if _main.combat_state == Main3D.CombatState.EXPLORATION:
		await _start_fight_with(wolf, 3.0)
	if _main.combat_state != Main3D.CombatState.PLAYER_TURN:
		return "no player turn (state %d)" % _main.combat_state
	if _player.get_active_soul().kind != Soul.Kind.MAGE:
		_main._request_shift(int(Soul.Kind.MAGE))
	var spirit := _progression.skill_ability(Soul.Kind.MAGE, 2)
	# Not enough mana is a refusal of its own.
	_progression.spend_pool(Soul.Kind.MAGE, _progression.get_pool(Soul.Kind.MAGE))
	var reason := _main.ability_runner.block_reason(spirit)
	_progression.refill_pools()
	if reason != "Not enough mana":
		return "empty mana did not block Storm Spirit: '%s'" % reason
	# The first wolf may have burned to death; bring the nearest one in.
	if GroundMath.ground_distance(wolf.global_position, _player.global_position) > 3.5:
		wolf.snap_to(_player.global_position + Vector3(3.0, 0.0, 0.0))
		await get_tree().physics_frame
	if not _main.engaged_enemies.has(wolf.get_instance_id()):
		_main.register_spawned_enemy(wolf)
	var point := GroundMath.flatten(_player.global_position.lerp(wolf.global_position, 0.5))
	var refusal := _main.ability_runner.block_reason(spirit)
	await _main._execute_ability(spirit, null, point)
	if _main.ability_runner.get_totems().size() != 1:
		return "%d spirits after Storm Spirit (refusal '%s', point %.1f m away, range %.1f)" \
			% [_main.ability_runner.get_totems().size(), refusal,
			GroundMath.ground_distance(_player.global_position, point), spirit.range_m]
	wolf.apply_status(&"root", 3)
	var totem := _main.ability_runner.get_totems()[0]
	var before := wolf.health
	if not await _end_turn_and_wait():
		return "the enemy turn did not hand back"
	if wolf.is_alive() and wolf.health >= before:
		return "the spirit did not strike at the turn start (%d -> %d; state %d, spirit %s, %d turns left, wolf %.1f m from it, reach %.1f)" \
			% [before, wolf.health, _main.combat_state, "valid" if is_instance_valid(totem) else "gone",
			totem.turns_left if is_instance_valid(totem) else -1,
			GroundMath.ground_distance(wolf.global_position, totem.global_position) if is_instance_valid(totem) else -1.0,
			totem.reach_m if is_instance_valid(totem) else -1.0]
	return ""


func _step_spawned_enemy() -> String:
	if _main.combat_state == Main3D.CombatState.EXPLORATION:
		await _start_fight_with(_alive_wolf_near(), 2.5)
	var extra := _main.enemy_scene.instantiate() as Enemy3D
	_main.add_child(extra)
	extra.snap_to(_player.global_position + Vector3(0.0, 0.0, 3.0))
	get_tree().call_group("level_coordinator", "register_spawned_enemy", extra)
	if not _main.engaged_enemies.has(extra.get_instance_id()):
		return "register_spawned_enemy did not engage the newcomer"
	if not extra.is_in_turn_based_combat():
		return "the newcomer is not in turn mode"
	extra.receive_damage(1000)
	await get_tree().process_frame
	return ""


func _step_escape_by_distance() -> String:
	if _main.combat_state == Main3D.CombatState.EXPLORATION:
		await _start_fight_with(_alive_wolf_near(), 2.5)
	if _main.combat_state != Main3D.CombatState.PLAYER_TURN:
		if not await _wait_until(func() -> bool: return _main.combat_state == Main3D.CombatState.PLAYER_TURN, ENEMY_TURN_TIMEOUT_SECONDS):
			return "no player turn to escape from (state %d)" % _main.combat_state
	# Out of reach and out of sight: across the clearing.
	var far := Vector3(-9.0, 0.0, 0.0)
	for wolf in _main._get_all_alive_enemies():
		if GroundMath.ground_distance(wolf.global_position, far) <= Main3D.ESCAPE_ANY_SIGHT_M:
			wolf.snap_to(Vector3(9.0, 0.0, 9.0))
	_player.snap_to(far)
	await get_tree().physics_frame
	if not _main._player_escaped():
		return "not escaped at %.1f m from the nearest engaged wolf" % _nearest_engaged_distance()
	_main._request_end_player_turn()
	if _main.combat_state != Main3D.CombatState.EXPLORATION:
		return "ending the turn out of reach did not end the fight (state %d)" % _main.combat_state
	return ""


## The rogue's Smoke Bomb (a Buff card alone) hides the body.
func _step_escape_by_smoke() -> String:
	var wolf := _alive_wolf_near()
	if wolf == null:
		return "no wolf left"
	await _start_fight_with(wolf, 2.5)
	if _main.combat_state != Main3D.CombatState.PLAYER_TURN:
		return "no player turn (state %d)" % _main.combat_state
	if _player.get_active_soul().kind != Soul.Kind.ROGUE:
		_main._request_shift(int(Soul.Kind.ROGUE))
	var smoke := _progression.skill_ability(Soul.Kind.ROGUE, 1)
	if smoke == null or smoke.display_name != "Smoke Bomb":
		return "the rogue's slot 2 is not Smoke Bomb"
	await _main._execute_ability(smoke, null, null)
	if not _player.is_hidden_by_smoke():
		return "Smoke Bomb does not hide the body"
	_player.snap_to(wolf.global_position + Vector3(4.0, 0.0, 0.0))
	await get_tree().physics_frame
	_main._request_end_player_turn()
	if _main.combat_state != Main3D.CombatState.EXPLORATION:
		return "ending the turn in smoke 4 m away did not end the fight (state %d)" % _main.combat_state
	return ""


## Outside a fight, mana and stamina refill every few seconds.
func _step_exploration_refill() -> String:
	_progression.spend_pool(Soul.Kind.MAGE, 20)
	var mana := _progression.get_pool(Soul.Kind.MAGE)
	await get_tree().create_timer(Player3D.EXPLORATION_SECONDS_PER_TURN + 0.5).timeout
	if _progression.get_pool(Soul.Kind.MAGE) <= mana:
		return "mana stayed at %d in exploration" % _progression.get_pool(Soul.Kind.MAGE)
	return ""


## Chests and fallen enemies give cards; a boss always gives three.
func _step_card_drops() -> String:
	var total := _progression.total_cards()
	var granted := _main.grant_cards(2, _player.global_position)
	if granted.size() != 2 or _progression.total_cards() != total + 2:
		return "grant_cards added %d cards (%d -> %d)" % [granted.size(), total, _progression.total_cards()]
	return ""


func _step_respawn() -> String:
	var spawn := _main._respawn_point
	_player.snap_to(Vector3(4.0, 0.0, -6.0))
	_player.take_damage(10000)
	if _player.is_alive():
		return "the player survived 10000 damage"
	if not await _wait_until(func() -> bool: return _player.is_alive(), Main3D.RESPAWN_DELAY_SECONDS + 2.0):
		return "the player was not revived within %.1f s" % (Main3D.RESPAWN_DELAY_SECONDS + 2.0)
	if GroundMath.ground_distance(_player.global_position, spawn) > 0.6:
		return "revived %.2f m from the respawn point" % GroundMath.ground_distance(_player.global_position, spawn)
	if _player.health != _player.max_health:
		return "revived with %d / %d health" % [_player.health, _player.max_health]
	if _player.collision_layer != 2:
		return "revived body is on collision layer %d" % _player.collision_layer
	return ""


# --- Helpers ---------------------------------------------------------------------------

func _forge(kind: int, slot: int, cards: Array) -> void:
	var typed: Array[StringName] = []
	typed.assign(cards)
	if not _progression.forge_skill(kind, slot, typed):
		push_error("forge refused: %s" % _progression.forge_block_reason(kind, slot, typed))


func _has_status(ability: Ability3D, status_id: StringName) -> bool:
	for status in ability.statuses:
		if status["id"] == status_id:
			return true
	return false


func _status_power(ability: Ability3D, status_id: StringName) -> int:
	for status in ability.statuses:
		if status["id"] == status_id:
			return int(status["power"])
	return 0


## Places `wolf` `distance` m from the player and starts the fight (player first).
func _start_fight_with(wolf: Enemy3D, distance: float) -> void:
	if wolf == null:
		return
	wolf.snap_to(_player.global_position + Vector3(distance, 0.0, 0.0))
	if _main.combat_state == Main3D.CombatState.EXPLORATION:
		_main._start_turn_based_combat()
	await get_tree().physics_frame


func _end_turn_and_wait() -> bool:
	_main._request_end_player_turn()
	await get_tree().process_frame
	return await _wait_until(func() -> bool:
		return _main.combat_state == Main3D.CombatState.PLAYER_TURN or _main.combat_state == Main3D.CombatState.EXPLORATION,
		ENEMY_TURN_TIMEOUT_SECONDS)


func _alive_wolf_near() -> Enemy3D:
	var best: Enemy3D = null
	var best_distance := INF
	for wolf in _wolves:
		if not is_instance_valid(wolf) or not wolf.is_alive():
			continue
		var d := GroundMath.ground_distance(wolf.global_position, _player.global_position)
		if d < best_distance:
			best = wolf
			best_distance = d
	return best


func _nearest_engaged_distance() -> float:
	var best := INF
	for wolf in _main._get_all_alive_enemies():
		best = minf(best, GroundMath.ground_distance(wolf.global_position, _player.global_position))
	return best


func _wait_until(condition: Callable, timeout_seconds: float) -> bool:
	var deadline := Time.get_ticks_msec() + int(timeout_seconds * 1000.0)
	while Time.get_ticks_msec() < deadline:
		if bool(condition.call()):
			return true
		await get_tree().process_frame
	return bool(condition.call())
