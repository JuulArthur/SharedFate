class_name AbilityRunner3D
extends Node

## Carries out the player's skills and owns their cooldowns. Created by the
## coordinator (main_3d.gd) as a child named "AbilityRunner"; the coordinator
## picks the target and awaits `execute`.
##
## Card skills (docs/cards-and-attributes.md) are run from their compiled
## fields, by delivery: a bolt, a chain, a nova, a throw, a strike, a trap
## field, a leap, a sweep, a buff or heal on the body, or a summoned spirit.
## They cost the soul's mana or stamina on top of the action or bonus action.
## The only catalog ability left is Toss Pebble (AbilityCatalog3D).
##
## Everything reaches actors duck-typed, per docs/gameplay-expansion.md: enemies
## through `receive_damage`, `take_environment_damage` (trap fields),
## `apply_status` (fallback `apply_root`), `knockback`, `is_back_turned_to`,
## `is_unaware`, `investigate`; hittables (barrels) through `receive_damage`.

signal ability_used(ability: Ability3D)

const EXPLORATION_SECONDS_PER_TURN := Player3D.EXPLORATION_SECONDS_PER_TURN
const RANGE_TOLERANCE_M := 0.05
const FX_SCREEN_SCALE := 3.35
const HIT_HEIGHT_M := 1.0
## A leap is this fast, and a prop in the way stops it.
const LEAP_SECONDS := 0.2
const LEAP_BLOCK_MASK := 8
## A spirit refuses a point this far off the navmesh (a wall, a tree).
const MAX_OFFMESH_M := 0.8
const CHAIN_FALLOFF := 0.8
const COLOR_REFUSE := CombatFx.COLOR_WARNING

var player: Player3D = null
var _cooldowns: Dictionary = {}
var _exploration_tick_left := EXPLORATION_SECONDS_PER_TURN
var _fields: Array[SkillField3D] = []
var _totems: Array[SkillTotem3D] = []


func setup(the_player: Player3D) -> void:
	player = the_player


func _physics_process(delta: float) -> void:
	if player == null or player.is_in_turn_based_combat():
		return
	_prune()
	if _cooldowns.is_empty() and _fields.is_empty() and _totems.is_empty():
		_exploration_tick_left = EXPLORATION_SECONDS_PER_TURN
		return
	_exploration_tick_left -= delta
	if _exploration_tick_left > 0.0:
		return
	_exploration_tick_left = EXPLORATION_SECONDS_PER_TURN
	_tick_cooldowns()
	_tick_persistent()


# --- Cooldowns ---------------------------------------------------------------------

func get_cooldown(ability_id: StringName) -> int:
	return int(_cooldowns.get(ability_id, 0))


## The player's turn starts: every cooldown melts one turn, trap fields strike
## whoever stands in them and spirits strike.
func on_player_turn_started() -> void:
	_tick_cooldowns()
	_tick_persistent()


## Skills start every fight fresh, like the spells.
func on_combat_started() -> void:
	_cooldowns.clear()


func _tick_cooldowns() -> void:
	for ability_id in _cooldowns.keys():
		var left := int(_cooldowns[ability_id]) - 1
		if left <= 0:
			_cooldowns.erase(ability_id)
		else:
			_cooldowns[ability_id] = left


func get_fields() -> Array[SkillField3D]:
	_prune()
	return _fields


func get_totems() -> Array[SkillTotem3D]:
	_prune()
	return _totems


func _tick_persistent() -> void:
	_prune()
	for field in _fields.duplicate():
		field.tick()
	for totem in _totems.duplicate():
		totem.tick()
	_prune()


func _prune() -> void:
	var fields: Array[SkillField3D] = []
	for field in _fields:
		if is_instance_valid(field) and field.turns_left > 0:
			fields.append(field)
	_fields = fields
	var totems: Array[SkillTotem3D] = []
	for totem in _totems:
		if is_instance_valid(totem) and totem.turns_left > 0:
			totems.append(totem)
	_totems = totems


# --- Availability -------------------------------------------------------------------

## Why `ability` cannot be used right now, "" when it can. Range and target are
## checked by `execute`.
func block_reason(ability: Ability3D) -> String:
	if player == null or not player.is_alive():
		return "No body"
	var in_fight := player.is_in_turn_based_combat()
	if in_fight and ability.exploration_only:
		return "Not in a fight"
	if not in_fight and not ability.usable_in_exploration:
		return "Only in a fight"
	if in_fight and not player.is_turn_active():
		return "Not your turn"
	if ability.card_skill:
		var soul := player.get_active_soul()
		if soul == null or int(soul.kind) != ability.soul_kind:
			return "Another soul's skill"
	var cooldown := get_cooldown(ability.id)
	if cooldown > 0:
		return "Recharging (%d)" % cooldown
	if ability.cost == Ability3D.Cost.BONUS:
		if not player.has_bonus_action():
			return "Bonus action used"
	elif not player.has_action():
		return "No action left" if in_fight else "Not ready"
	if ability.resource_cost > 0:
		var progression := player.get_progression()
		if progression != null and not progression.can_afford(ability.soul_kind, ability.resource_cost):
			return "Not enough %s" % Progression3D.resource_name(ability.soul_kind).to_lower()
	return ""


func get_range(ability: Ability3D) -> float:
	if ability.is_melee():
		return player.get_melee_range() if player != null else 1.2
	return ability.range_m


# --- Execution -----------------------------------------------------------------------

## Carries out `ability` against `target` (ENEMY) or at `point` (GROUND; a
## Vector3). Coroutine; returns true when the ability was used (cost spent,
## cooldown started), false when it was refused with a popup.
func execute(ability: Ability3D, target: Node3D = null, point: Variant = null) -> bool:
	var reason := block_reason(ability)
	if not reason.is_empty():
		_refuse(reason)
		return false
	match ability.target:
		Ability3D.Target.ENEMY:
			if target == null or not is_instance_valid(target) or not _is_alive(target):
				_refuse("No target")
				return false
			if GroundMath.ground_distance(player.global_position, target.global_position) > get_range(ability) + RANGE_TOLERANCE_M:
				_refuse("Out of reach" if ability.is_melee() else "Out of range", target)
				return false
		Ability3D.Target.GROUND:
			if not (point is Vector3):
				_refuse("No target point")
				return false
			if GroundMath.ground_distance(player.global_position, point) > ability.range_m + RANGE_TOLERANCE_M:
				_refuse("Out of range")
				return false

	var ok := true
	if ability.card_skill:
		ok = await _execute_card_skill(ability, target, point)
	elif ability.id == AbilityCatalog3D.DISTRACT:
		_pay(ability)
		await _distract(ability, point)
	else:
		push_warning("AbilityRunner3D: no effect for %s" % ability.id)
		ok = false
	if ok:
		ability_used.emit(ability)
	return ok


func _pay(ability: Ability3D) -> void:
	if ability.cost == Ability3D.Cost.BONUS:
		player.spend_bonus_action()
	else:
		player.spend_action()
	if ability.cooldown_turns > 0:
		_cooldowns[ability.id] = ability.cooldown_turns
	if ability.resource_cost > 0 and player.get_progression() != null:
		player.get_progression().spend_pool(ability.soul_kind, ability.resource_cost)
	CombatFx.popup_text(_anchor(player) + Vector3(0.0, 0.35, 0.0), ability.display_name, ability.color, 16)


func _execute_card_skill(ability: Ability3D, target: Node3D, point: Variant) -> bool:
	match ability.delivery:
		Ability3D.Delivery.BOLT:
			_pay(ability)
			await _card_bolt(ability, target)
		Ability3D.Delivery.CHAIN:
			_pay(ability)
			await _card_chain(ability, target)
		Ability3D.Delivery.NOVA:
			_pay(ability)
			_card_nova(ability)
		Ability3D.Delivery.THROW:
			_pay(ability)
			await _card_throw(ability, target)
		Ability3D.Delivery.STRIKE:
			_pay(ability)
			await _card_strike(ability, target)
		Ability3D.Delivery.FIELD:
			var center: Vector3 = point if point is Vector3 else player.global_position
			_pay(ability)
			_card_field(ability, center)
		Ability3D.Delivery.LEAP:
			if not _leap_path_clear(target):
				return false
			_pay(ability)
			await _card_leap(ability, target)
		Ability3D.Delivery.SWEEP:
			_pay(ability)
			await _card_sweep(ability)
		Ability3D.Delivery.SELF:
			_pay(ability)
			_card_self(ability)
		Ability3D.Delivery.TOTEM:
			if not _ground_point_valid(point, "Can't raise a spirit there"):
				return false
			_pay(ability)
			_card_totem(ability, point as Vector3)
		_:
			push_warning("AbilityRunner3D: card skill %s has no delivery" % ability.id)
			return false
	return true


# --- Card skill deliveries --------------------------------------------------------------

func _card_bolt(ability: Ability3D, target: Node3D) -> void:
	player.face_toward(target.global_position)
	player._flash_ranged_feedback(target, true)
	var primary := target
	var impact := GroundMath.flatten(target.global_position)
	await player._launch_bolt(target, ability.color)
	if is_instance_valid(primary):
		impact = GroundMath.flatten(primary.global_position)
	var victims: Array[Node3D] = []
	if ability.radius_m > 0.0:
		victims = _targets_within(impact, ability.radius_m)
		if is_instance_valid(primary) and _is_alive(primary) and not victims.has(primary):
			victims.append(primary)
		_burst_fx(impact, ability)
	elif is_instance_valid(primary) and _is_alive(primary):
		victims.append(primary)
	for victim in victims:
		_card_hit(ability, victim, victim == primary)
	if not victims.is_empty():
		CombatFx.hit_stop(0.05, 0.25)
	_after_hits(victims)


func _card_chain(ability: Ability3D, target: Node3D) -> void:
	player.face_toward(target.global_position)
	player._flash_ranged_feedback(target, true)
	await player._launch_bolt(target, ability.color)
	var scale := 1.0
	var hit_list: Array[Node3D] = []
	var current := target
	var from_point := player._bolt_start_position()
	for jump in range(ability.chain_jumps + 1):
		if current == null or not is_instance_valid(current) or not _is_alive(current):
			break
		var strike_point := current.global_position + Vector3(0.0, HIT_HEIGHT_M, 0.0)
		if jump > 0:
			_zap(from_point, strike_point, ability.color)
			await get_tree().create_timer(0.08).timeout
			if not is_instance_valid(current):
				break
		_card_hit(ability, current, jump == 0, false, scale)
		hit_list.append(current)
		from_point = strike_point
		scale *= CHAIN_FALLOFF
		current = _nearest_target(current.global_position, ability.radius_m, hit_list)
	CombatFx.hit_stop(0.05, 0.25)
	_after_hits(hit_list)


func _card_nova(ability: Ability3D) -> void:
	var victims := _targets_within(player.global_position, ability.radius_m)
	_burst_fx(player.global_position, ability, player)
	CombatFx.shake(4.0, 0.16)
	for victim in victims:
		_card_hit(ability, victim, true)
	_after_hits(victims)


func _card_throw(ability: Ability3D, target: Node3D) -> void:
	player.face_toward(target.global_position)
	player._flash_ranged_feedback(target)
	var victim := target
	await player._launch_bolt(target, ability.color)
	if is_instance_valid(victim) and _is_alive(victim):
		_card_hit(ability, victim, true)
		CombatFx.hit_stop(0.04, 0.3)
		_after_hits([victim])


func _card_strike(ability: Ability3D, target: Node3D) -> void:
	player.face_toward(target.global_position)
	var victim := target
	await player._swing_melee(func() -> void:
		if not is_instance_valid(victim):
			return
		_card_hit(ability, victim, true)
		CombatFx.hit_stop(0.07, 0.2)
	)
	_after_hits([victim])


func _card_field(ability: Ability3D, center: Vector3) -> void:
	var holder := player.get_parent()
	if holder == null:
		return
	var field := SkillField3D.new()
	field.name = "SkillField"
	field.setup(ability)
	holder.add_child(field)
	field.global_position = GroundMath.flatten(center)
	field.strike_requested.connect(_on_field_strike)
	_fields.append(field)
	_burst_fx(field.global_position, ability)
	field.strike_everyone_inside()


func _card_leap(ability: Ability3D, target: Node3D) -> void:
	var destination := _leap_destination(target)
	player.stop_movement_immediately()
	player.face_toward(target.global_position)
	var tween := player.create_tween()
	tween.tween_property(player, "global_position", destination, LEAP_SECONDS) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	await tween.finished
	if not is_instance_valid(player):
		return
	player.snap_to(destination)
	CombatFx.shake(5.0, 0.16)
	if ability.radius_m <= 0.0:
		if is_instance_valid(target) and _is_alive(target):
			await _card_strike(ability, target)
		return
	var primary := target
	var victims := _targets_within(player.global_position, ability.radius_m)
	_burst_fx(player.global_position, ability, player)
	await player._swing_melee(func() -> void:
		for victim in victims:
			if is_instance_valid(victim):
				_card_hit(ability, victim, victim == primary)
		if not victims.is_empty():
			CombatFx.hit_stop(0.06, 0.2)
	)
	_after_hits(victims)


func _card_sweep(ability: Ability3D) -> void:
	var victims := _targets_within(player.global_position, ability.radius_m)
	_burst_fx(player.global_position, ability, player)
	await player._swing_melee(func() -> void:
		for victim in victims:
			if is_instance_valid(victim):
				_card_hit(ability, victim, true)
		if not victims.is_empty():
			CombatFx.hit_stop(0.06, 0.2)
			CombatFx.shake(4.0, 0.15)
	)
	if victims.is_empty():
		CombatFx.popup_text(_anchor(player), "Nothing in reach", COLOR_REFUSE, 14)
	_after_hits(victims)


func _card_self(ability: Ability3D) -> void:
	var color := CombatFx.COLOR_HEAL if ability.heal_ratio > 0.0 else ability.color
	CombatFx.ring_burst(player, player.global_position + Vector3(0.0, 0.05, 0.0), color,
		8.0 * FX_SCREEN_SCALE, 26.0 * FX_SCREEN_SCALE, 0.35)
	if ability.heal_ratio > 0.0:
		player.heal(int(round(player.max_health * ability.heal_ratio)))
	var offset := 0.6
	for buff in ability.buffs:
		player.apply_buff(buff["id"], int(buff["turns"]), int(buff["power"]))
		if buff["id"] != &"vanish":
			CombatFx.popup_text(_anchor(player) + Vector3(0.0, offset, 0.0),
				String(buff["id"]).to_upper(), ability.color, 16)
			offset += 0.3
		else:
			CombatFx.popup_text(_anchor(player) + Vector3(0.0, offset, 0.0), "VANISHED", ability.color, 22)


func _card_totem(ability: Ability3D, point: Vector3) -> void:
	var holder := player.get_parent()
	if holder == null:
		return
	var totem := SkillTotem3D.new()
	totem.name = "SkillTotem"
	totem.setup(ability)
	holder.add_child(totem)
	totem.global_position = GroundMath.flatten(point)
	totem.strike_requested.connect(_on_totem_strike)
	_totems.append(totem)
	CombatFx.ring_burst(holder, totem.global_position + Vector3(0.0, 0.05, 0.0), ability.color,
		6.0 * FX_SCREEN_SCALE, player._screen_radius_px(totem.global_position, 1.2), 0.4)


func _on_field_strike(field: SkillField3D, enemy: Node3D) -> void:
	if not is_instance_valid(field) or field.ability == null or not _is_alive(enemy):
		return
	# A trap, not a blow: it does not start an ambush on an unaware enemy.
	_card_hit(field.ability, enemy, false, true)


## A spirit strikes at the start of a player turn in a fight: the nearest enemy
## in reach, or everyone in reach when its skill has an Area card.
func _on_totem_strike(totem: SkillTotem3D) -> void:
	if player == null or not player.is_in_turn_based_combat():
		return
	if not is_instance_valid(totem) or totem.ability == null:
		return
	var ability := totem.ability
	var victims: Array[Node3D] = []
	if ability.radius_m > 0.0:
		victims = _targets_within(totem.global_position, totem.reach_m)
	else:
		var nearest := _nearest_target(totem.global_position, totem.reach_m, [])
		if nearest != null:
			victims.append(nearest)
	for victim in victims:
		_zap(totem.get_strike_origin(), victim.global_position + Vector3(0.0, HIT_HEIGHT_M, 0.0), ability.color)
		_card_hit(ability, victim, false)


# --- Card skill effects -------------------------------------------------------------------

## Damage before stealth and exposure: the flat part through Power (and any
## Empower), plus the weapon share of a strike.
func card_damage(ability: Ability3D) -> int:
	var damage := 0
	if ability.flat_damage > 0:
		damage += player.scale_damage(ability.flat_damage)
	if ability.damage_mult > 0.0:
		damage += int(round(float(player.get_melee_damage()) * ability.damage_mult))
	return damage


func _card_hit(ability: Ability3D, victim: Node3D, primary: bool, environment: bool = false,
		scale: float = 1.0) -> void:
	if victim == null or not is_instance_valid(victim) or not _is_alive(victim):
		return
	var damage := int(round(float(card_damage(ability)) * scale))
	if primary and ability.exposed_mult > 1.0 and _is_exposed(victim):
		damage = int(round(float(damage) * ability.exposed_mult))
		CombatFx.popup_text(_anchor(victim) + Vector3(0.0, 0.3, 0.0), "EXPOSED!", ability.color, 20)
	if primary and not environment:
		damage = player.apply_stealth_bonus(victim, damage)
	if damage > 0:
		if environment and victim.has_method("take_environment_damage"):
			victim.call("take_environment_damage", damage)
		else:
			_hit(victim, damage)
	if not _is_alive(victim):
		return
	for status in ability.statuses:
		apply_status_to(victim, status["id"], int(status["turns"]), int(status["power"]))
	if ability.knockback_m > 0.0 and victim.has_method("knockback"):
		victim.call("knockback", player.global_position, ability.knockback_m)
	if not environment:
		player.apply_on_hit_effects(victim)


func _burst_fx(center: Vector3, ability: Ability3D, on_node: Node3D = null) -> void:
	var holder: Node = on_node if on_node != null else player.get_parent()
	CombatFx.ring_burst(holder, center + Vector3(0.0, 0.05, 0.0), ability.color,
		6.0 * FX_SCREEN_SCALE, player._screen_radius_px(center, maxf(0.5, ability.radius_m)), 0.45)
	CombatFx.shake(4.0, 0.16)


func _leap_path_clear(target: Node3D) -> bool:
	var destination := _leap_destination(target)
	var world := player.get_world_3d()
	if world == null:
		return true
	var from := player.global_position + Vector3(0.0, 0.6, 0.0)
	var to := destination + Vector3(0.0, 0.6, 0.0)
	var query := PhysicsRayQueryParameters3D.create(from, to, LEAP_BLOCK_MASK)
	query.exclude = [player.get_rid()]
	var hit: Dictionary = world.direct_space_state.intersect_ray(query)
	if not hit.is_empty():
		_refuse("Path blocked", target)
		return false
	return true


func _leap_destination(target: Node3D) -> Vector3:
	var stop := player.get_attack_approach_distance(target, player.get_melee_range())
	var away := GroundMath.ground_direction(target.global_position, player.global_position)
	if away == Vector3.ZERO:
		away = Vector3.BACK
	return GroundMath.flatten(target.global_position) + away * stop


func _ground_point_valid(point: Variant, refusal: String) -> bool:
	if not (point is Vector3):
		_refuse("No target point")
		return false
	var target_point := GroundMath.flatten(point as Vector3)
	var world := player.get_world_3d()
	if world != null and world.navigation_map.is_valid():
		var on_mesh := NavigationServer3D.map_get_closest_point(world.navigation_map, target_point)
		if GroundMath.ground_distance(on_mesh, target_point) > MAX_OFFMESH_M:
			_refuse(refusal)
			return false
	return true


# --- Toss Pebble ------------------------------------------------------------------------------

func _distract(ability: Ability3D, point: Variant) -> void:
	var landing := GroundMath.flatten(point as Vector3)
	player.face_toward(landing)
	player._flash_ranged_feedback(null)
	await get_tree().create_timer(0.25).timeout
	CombatFx.popup_text(landing + Vector3(0.0, 0.6, 0.0), "*clack*", ability.color, 16)
	CombatFx.ring_burst(player.get_parent(), landing + Vector3(0.0, 0.05, 0.0), ability.color,
		4.0 * FX_SCREEN_SCALE, player._screen_radius_px(landing, ability.radius_m), 0.5)
	var drawn := 0
	for node in get_tree().get_nodes_in_group("enemies"):
		var enemy_actor := node as Node3D
		if enemy_actor == null or not _is_alive(enemy_actor):
			continue
		if GroundMath.ground_distance(enemy_actor.global_position, landing) > ability.radius_m:
			continue
		if enemy_actor.has_method("is_unaware") and not bool(enemy_actor.call("is_unaware")):
			continue
		if enemy_actor.has_method("investigate"):
			enemy_actor.call("investigate", landing)
			CombatFx.popup_text(_anchor(enemy_actor) + Vector3(0.0, 0.2, 0.0), "?", CombatFx.COLOR_WARNING, 22)
			drawn += 1
	if drawn == 0:
		CombatFx.popup_text(_anchor(player), "Nobody heard it", CombatFx.COLOR_WARNING, 14)


# --- Helpers -------------------------------------------------------------------------------

## Stunned, rooted, unaware or turned away: a rogue's strike bites deeper.
func _is_exposed(target: Node3D) -> bool:
	if target.has_method("is_unaware") and bool(target.call("is_unaware")):
		return true
	if target.has_method("has_status"):
		if bool(target.call("has_status", &"stun")) or bool(target.call("has_status", &"root")):
			return true
	if target.has_method("is_rooted") and bool(target.call("is_rooted")):
		return true
	if target.has_method("is_back_turned_to") and bool(target.call("is_back_turned_to", player.global_position)):
		return true
	return false


func _hit(target: Node3D, amount: int) -> void:
	if target == null or not is_instance_valid(target) or amount <= 0:
		return
	if target.has_method("receive_damage"):
		target.call("receive_damage", amount)
	elif target.has_method("take_damage"):
		target.call("take_damage", amount)


## `apply_status` when the target has it; a root falls back to `apply_root`.
static func apply_status_to(target: Node3D, status_id: StringName, turns: int, power: int = 0) -> void:
	if target.has_method("apply_status"):
		target.call("apply_status", status_id, turns, power)
	elif status_id == &"root" and target.has_method("apply_root"):
		target.call("apply_root", turns)


## The rogue's Killing Spree: a kill in the rogue's hands gives the action back
## once per turn.
func _after_hits(victims: Array) -> void:
	if player == null or player.get_active_soul() == null:
		return
	if player.get_active_soul().kind != Soul.Kind.ROGUE:
		return
	for victim in victims:
		if victim is Node3D and (not is_instance_valid(victim) or not _is_alive(victim as Node3D)):
			if player.refund_action_once():
				CombatFx.popup_text(_anchor(player) + Vector3(0.0, 0.6, 0.0), "KILLING SPREE  +action",
					AbilityCatalog3D.COLOR_ROGUE, 18)
			return


## Enemies and hittables within `radius` of `center` on the ground plane.
func _targets_within(center: Vector3, radius: float) -> Array[Node3D]:
	var found: Array[Node3D] = []
	for group_name in ["enemies", "hittable"]:
		for node in get_tree().get_nodes_in_group(group_name):
			var actor := node as Node3D
			if actor == null or not is_instance_valid(actor) or not _is_alive(actor):
				continue
			if found.has(actor):
				continue
			if GroundMath.ground_distance(actor.global_position, center) <= radius:
				found.append(actor)
	return found


func _nearest_target(center: Vector3, radius: float, excluded: Array[Node3D]) -> Node3D:
	var best: Node3D = null
	var best_distance := INF
	for node in get_tree().get_nodes_in_group("enemies"):
		var actor := node as Node3D
		if actor == null or excluded.has(actor) or not _is_alive(actor):
			continue
		var distance := GroundMath.ground_distance(actor.global_position, center)
		if distance <= radius and distance < best_distance:
			best = actor
			best_distance = distance
	return best


static func _is_alive(node: Node3D) -> bool:
	if node == null or not is_instance_valid(node):
		return false
	if node.has_method("is_alive"):
		return bool(node.call("is_alive"))
	return true


## A short bright streak between two points (lightning jumps, spirit strikes).
func _zap(from: Vector3, to: Vector3, color: Color) -> void:
	var holder := player.get_parent()
	if holder == null:
		return
	var mesh := ImmediateMesh.new()
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = color.lightened(0.3)
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mesh.surface_begin(Mesh.PRIMITIVE_LINE_STRIP, material)
	var steps := 6
	for i in range(steps + 1):
		var t := float(i) / float(steps)
		var p := from.lerp(to, t)
		if i > 0 and i < steps:
			p += Vector3(randf_range(-0.15, 0.15), randf_range(-0.15, 0.15), randf_range(-0.15, 0.15))
		mesh.surface_add_vertex(p)
	mesh.surface_end()
	var instance := MeshInstance3D.new()
	instance.mesh = mesh
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	holder.add_child(instance)
	var tween := instance.create_tween()
	tween.tween_property(material, "albedo_color:a", 0.0, 0.25)
	tween.tween_callback(instance.queue_free)


func _refuse(reason: String, at: Node3D = null) -> void:
	var anchor_node: Node3D = at if at != null and is_instance_valid(at) else player
	if anchor_node == null:
		return
	CombatFx.popup_text(_anchor(anchor_node), reason, COLOR_REFUSE, 16)


static func _anchor(actor: Node3D) -> Vector3:
	if actor == null or not is_instance_valid(actor):
		return Vector3.ZERO
	var anchor := actor.get_node_or_null("OverheadAnchor") as Node3D
	if anchor != null:
		return anchor.global_position
	return actor.global_position + Vector3.UP * 1.8
