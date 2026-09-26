class_name AbilityRunner3D
extends Node

## Carries out the abilities in AbilityCatalog3D for the player, and owns their
## cooldowns. Created by the coordinator (main_3d.gd) as a child named
## "AbilityRunner"; the coordinator picks the target and awaits `execute`.
##
## Everything reaches actors duck-typed, per docs/gameplay-expansion.md: enemies
## through `receive_damage`, `apply_status` (fallback `apply_root`),
## `knockback`, `is_back_turned_to`, `is_unaware`, `investigate`; hittables
## (barrels) through `receive_damage`; the rogue's snare through the `Trap3D`
## class that track A provides, looked up by class name so this file loads
## without it.

signal ability_used(ability: Ability3D)

const EXPLORATION_SECONDS_PER_TURN := Player3D.EXPLORATION_SECONDS_PER_TURN
const RANGE_TOLERANCE_M := 0.05
const FX_SCREEN_SCALE := 3.35
const HIT_HEIGHT_M := 1.0
## Charge: the rush is this fast, and a prop in the way stops it.
const CHARGE_SECONDS := 0.2
const CHARGE_BLOCK_MASK := 8
## Shadowstep lands this far behind the target's collision surface.
const SHADOWSTEP_GAP_M := 0.35
## Blink refuses a point this far off the navmesh (a wall, a tree).
const BLINK_MAX_OFFMESH_M := 0.8
const COLOR_REFUSE := CombatFx.COLOR_WARNING

var player: Player3D = null
var _cooldowns: Dictionary = {}
var _exploration_tick_left := EXPLORATION_SECONDS_PER_TURN


func setup(the_player: Player3D) -> void:
	player = the_player


func _physics_process(delta: float) -> void:
	if player == null or player.is_in_turn_based_combat():
		return
	if _cooldowns.is_empty():
		_exploration_tick_left = EXPLORATION_SECONDS_PER_TURN
		return
	_exploration_tick_left -= delta
	if _exploration_tick_left > 0.0:
		return
	_exploration_tick_left = EXPLORATION_SECONDS_PER_TURN
	_tick_cooldowns()


# --- Cooldowns ---------------------------------------------------------------------

func get_cooldown(ability_id: StringName) -> int:
	return int(_cooldowns.get(ability_id, 0))


## The player's turn starts: every cooldown melts one turn.
func on_player_turn_started() -> void:
	_tick_cooldowns()


## Abilities start every fight fresh, like the spells.
func on_combat_started() -> void:
	_cooldowns.clear()


func _tick_cooldowns() -> void:
	for ability_id in _cooldowns.keys():
		var left := int(_cooldowns[ability_id]) - 1
		if left <= 0:
			_cooldowns.erase(ability_id)
		else:
			_cooldowns[ability_id] = left


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
	var cooldown := get_cooldown(ability.id)
	if cooldown > 0:
		return "Recharging (%d)" % cooldown
	if ability.cost == Ability3D.Cost.BONUS:
		if not player.has_bonus_action():
			return "Bonus action used"
	elif not player.has_action():
		return "No action left" if in_fight else "Not ready"
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
	match ability.id:
		AbilityCatalog3D.SHIELD_BASH, AbilityCatalog3D.POISON_BLADE, AbilityCatalog3D.BACKSTAB:
			_pay(ability)
			await _melee_strike(ability, target)
		AbilityCatalog3D.CLEAVE:
			_pay(ability)
			await _cleave(ability)
		AbilityCatalog3D.SECOND_WIND:
			_pay(ability)
			_second_wind()
		AbilityCatalog3D.CHARGE:
			ok = _charge_path_clear(target)
			if ok:
				_pay(ability)
				await _charge(ability, target)
		AbilityCatalog3D.SHADOWSTEP:
			_pay(ability)
			_shadowstep(target)
		AbilityCatalog3D.SET_SNARE:
			ok = _set_snare(point)
			if ok:
				_pay(ability)
		AbilityCatalog3D.SMOKE_BOMB:
			_pay(ability)
			_smoke_bomb(ability)
		AbilityCatalog3D.BLINK:
			ok = _blink_point_valid(point)
			if ok:
				_pay(ability)
				player.teleport_to(point)
		AbilityCatalog3D.FIREBALL:
			_pay(ability)
			await _fireball(ability, target)
		AbilityCatalog3D.CHAIN_LIGHTNING:
			_pay(ability)
			await _chain_lightning(ability, target)
		AbilityCatalog3D.FROST_NOVA:
			_pay(ability)
			_frost_nova(ability)
		AbilityCatalog3D.DISTRACT:
			_pay(ability)
			await _distract(ability, point)
		_:
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
	CombatFx.popup_text(_anchor(player) + Vector3(0.0, 0.35, 0.0), ability.display_name, ability.color, 16)


# --- Effects ------------------------------------------------------------------------------

## Shield Bash, Poison Blade, Backstab: one swing with the contact delay.
func _melee_strike(ability: Ability3D, target: Node3D) -> void:
	player.face_toward(target.global_position)
	var damage := _ability_damage(ability)
	var bonus_text := ""
	if ability.id == AbilityCatalog3D.BACKSTAB and _is_exposed(target):
		damage = maxi(1, int(round(float(damage) * AbilityCatalog3D.BACKSTAB_MULT)))
		bonus_text = "BACKSTAB!"
	damage = player.apply_stealth_bonus(target, damage)
	var victim := target
	await player._swing_melee(func() -> void:
		if not is_instance_valid(victim):
			return
		if not bonus_text.is_empty():
			CombatFx.popup_text(_anchor(victim) + Vector3(0.0, 0.3, 0.0), bonus_text, ability.color, 22)
		_hit(victim, damage)
		_apply_ability_status(ability, victim)
		if ability.knockback_m > 0.0 and victim.has_method("knockback"):
			victim.call("knockback", player.global_position, ability.knockback_m)
		CombatFx.hit_stop(0.07, 0.2)
	)
	_after_hits([victim])


func _cleave(ability: Ability3D) -> void:
	var victims := _targets_within(player.global_position, ability.radius_m)
	var damage := _ability_damage(ability)
	CombatFx.ring_burst(player, player.global_position + Vector3(0.0, 0.05, 0.0), ability.color,
		6.0 * FX_SCREEN_SCALE, player._screen_radius_px(player.global_position, ability.radius_m), 0.3)
	await player._swing_melee(func() -> void:
		for victim in victims:
			if is_instance_valid(victim):
				_hit(victim, player.apply_stealth_bonus(victim, damage))
		if not victims.is_empty():
			CombatFx.hit_stop(0.06, 0.2)
			CombatFx.shake(4.0, 0.15)
	)
	if victims.is_empty():
		CombatFx.popup_text(_anchor(player), "Nothing in reach", COLOR_REFUSE, 14)
	_after_hits(victims)


func _second_wind() -> void:
	var amount := int(round(player.max_health * AbilityCatalog3D.SECOND_WIND_HEAL_RATIO))
	player.heal(amount)
	CombatFx.ring_burst(player, player.global_position + Vector3(0.0, 0.05, 0.0), CombatFx.COLOR_HEAL,
		8.0 * FX_SCREEN_SCALE, 26.0 * FX_SCREEN_SCALE, 0.35)


func _charge_path_clear(target: Node3D) -> bool:
	var destination := _charge_destination(target)
	var world := player.get_world_3d()
	if world == null:
		return true
	var from := player.global_position + Vector3(0.0, 0.6, 0.0)
	var to := destination + Vector3(0.0, 0.6, 0.0)
	var query := PhysicsRayQueryParameters3D.create(from, to, CHARGE_BLOCK_MASK)
	query.exclude = [player.get_rid()]
	var hit: Dictionary = world.direct_space_state.intersect_ray(query)
	if not hit.is_empty():
		_refuse("Path blocked", target)
		return false
	return true


func _charge_destination(target: Node3D) -> Vector3:
	var stop := player.get_attack_approach_distance(target, player.get_melee_range())
	var away := GroundMath.ground_direction(target.global_position, player.global_position)
	if away == Vector3.ZERO:
		away = Vector3.BACK
	return GroundMath.flatten(target.global_position) + away * stop


func _charge(ability: Ability3D, target: Node3D) -> void:
	var destination := _charge_destination(target)
	player.stop_movement_immediately()
	player.face_toward(target.global_position)
	var tween := player.create_tween()
	tween.tween_property(player, "global_position", destination, CHARGE_SECONDS) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	await tween.finished
	if not is_instance_valid(player):
		return
	player.snap_to(destination)
	CombatFx.shake(5.0, 0.16)
	if is_instance_valid(target) and _is_alive(target):
		await _melee_strike(ability, target)


func _shadowstep(target: Node3D) -> void:
	var back := target.global_transform.basis.z
	back.y = 0.0
	if back.length() < 0.01:
		back = GroundMath.ground_direction(player.global_position, target.global_position)
	back = back.normalized()
	var gap := ActorBase3D.collision_radius_of(target) + player.get_collision_radius() + SHADOWSTEP_GAP_M
	var spot := GroundMath.flatten(target.global_position) + back * gap
	player.teleport_to(spot)
	player.face_toward(target.global_position)


func _set_snare(point: Variant) -> bool:
	var trap_script := _global_class_script(&"Trap3D")
	if trap_script == null or not trap_script.has_method("place_player_trap"):
		_refuse("No snares in this build")
		return false
	var parent := player.get_parent()
	trap_script.call("place_player_trap", parent, GroundMath.flatten(point as Vector3))
	return true


func _smoke_bomb(ability: Ability3D) -> void:
	player.apply_smoke_cover()
	CombatFx.ring_burst(player, player.global_position + Vector3(0.0, 0.3, 0.0), ability.color,
		10.0 * FX_SCREEN_SCALE, player._screen_radius_px(player.global_position, ability.radius_m), 0.5, 1.0)
	CombatFx.popup_text(_anchor(player) + Vector3(0.0, 0.6, 0.0), "VANISHED", ability.color, 22)


func _blink_point_valid(point: Variant) -> bool:
	var target_point := GroundMath.flatten(point as Vector3)
	var world := player.get_world_3d()
	if world != null and world.navigation_map.is_valid():
		var on_mesh := NavigationServer3D.map_get_closest_point(world.navigation_map, target_point)
		if GroundMath.ground_distance(on_mesh, target_point) > BLINK_MAX_OFFMESH_M:
			_refuse("Can't blink there")
			return false
	return true


func _fireball(ability: Ability3D, target: Node3D) -> void:
	player.face_toward(target.global_position)
	player._flash_ranged_feedback(target, true)
	var impact := GroundMath.flatten(target.global_position)
	var primary := target
	await player._launch_bolt(target, ability.color)
	if is_instance_valid(primary):
		impact = GroundMath.flatten(primary.global_position)
	var victims := _targets_within(impact, ability.radius_m)
	var damage := _ability_damage(ability)
	CombatFx.ring_burst(player.get_parent(), impact + Vector3(0.0, 0.05, 0.0), ability.color,
		6.0 * FX_SCREEN_SCALE, player._screen_radius_px(impact, ability.radius_m), 0.45)
	CombatFx.shake(5.0, 0.18)
	for victim in victims:
		if not is_instance_valid(victim):
			continue
		_hit(victim, player.apply_stealth_bonus(victim, damage) if victim == primary else damage)
		_apply_ability_status(ability, victim)
	if not victims.is_empty():
		CombatFx.hit_stop(0.05, 0.25)
	_after_hits(victims)


func _chain_lightning(ability: Ability3D, target: Node3D) -> void:
	player.face_toward(target.global_position)
	player._flash_ranged_feedback(target, true)
	await player._launch_bolt(target, ability.color)
	var damage := float(_ability_damage(ability))
	var hit_list: Array[Node3D] = []
	var current := target
	var from_point := player._bolt_start_position()
	for jump in range(AbilityCatalog3D.CHAIN_LIGHTNING_JUMPS + 1):
		if current == null or not is_instance_valid(current) or not _is_alive(current):
			break
		var strike_point := current.global_position + Vector3(0.0, HIT_HEIGHT_M, 0.0)
		if jump > 0:
			_zap(from_point, strike_point, ability.color)
			await get_tree().create_timer(0.08).timeout
			if not is_instance_valid(current):
				break
		var dealt := maxi(1, int(round(damage)))
		if jump == 0:
			dealt = player.apply_stealth_bonus(current, dealt)
		_hit(current, dealt)
		hit_list.append(current)
		from_point = strike_point
		damage *= 0.8
		current = _nearest_target(current.global_position, AbilityCatalog3D.CHAIN_LIGHTNING_JUMP_M, hit_list)
	CombatFx.hit_stop(0.05, 0.25)
	_after_hits(hit_list)


func _frost_nova(ability: Ability3D) -> void:
	var victims := _targets_within(player.global_position, ability.radius_m)
	var damage := _ability_damage(ability)
	CombatFx.ring_burst(player, player.global_position + Vector3(0.0, 0.05, 0.0), ability.color,
		6.0 * FX_SCREEN_SCALE, player._screen_radius_px(player.global_position, ability.radius_m), 0.45)
	CombatFx.shake(4.0, 0.16)
	for victim in victims:
		if is_instance_valid(victim):
			_hit(victim, player.apply_stealth_bonus(victim, damage))
			_apply_ability_status(ability, victim)
	_after_hits(victims)


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

func _ability_damage(ability: Ability3D) -> int:
	var damage := 0
	if ability.damage_mult > 0.0:
		damage += int(round(float(player.get_melee_damage()) * ability.damage_mult))
	if ability.flat_damage > 0:
		damage += player.scale_damage(ability.flat_damage)
	return damage


## Stunned, rooted, unaware or turned away: a backstab doubles up.
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


func _apply_ability_status(ability: Ability3D, target: Node3D) -> void:
	if ability.status_id == &"" or not is_instance_valid(target) or not _is_alive(target):
		return
	apply_status_to(target, ability.status_id, ability.status_turns, ability.status_power)


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


## A short bright streak between two points (the lightning's jumps).
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


static func _global_class_script(class_id: StringName) -> Script:
	for entry in ProjectSettings.get_global_class_list():
		if StringName(entry.get("class", "")) == class_id:
			return load(String(entry.get("path", ""))) as Script
	return null
