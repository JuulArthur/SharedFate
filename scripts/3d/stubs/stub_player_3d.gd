extends "res://scripts/3d/stubs/stub_actor_3d.gd"

## WP0 stub player: answers every player-only method in the actor contract
## (docs/3d-port-contracts.md, section 5.2) with the smallest honest behaviour.
## Souls come from the real Soul class so the coordinator's HUD code has data.

signal soul_changed(soul: Soul)

const SHIFTS_PER_TURN := 1
const XP_BASE := 100.0
const XP_PER_LEVEL_MULT := 1.5

@export var attack_approach_buffer := 0.4
@export var character_name := "Sir Arthur"
@export var gold := 0

var souls: Array[Soul] = []
var active_soul: Soul = null
var _shifts_left := SHIFTS_PER_TURN
var _blocking := false
var _attack_target: Node3D = null
var _meter_world_units := GroundMath.METER_WORLD_UNITS
var _level := 1
var _experience := 0.0


func _ready() -> void:
	super()
	souls = Soul.all()
	active_soul = souls[0]


# --- Exploration targeting -----------------------------------------------------

func set_attack_target(target: Node3D) -> void:
	_attack_target = target


func clear_attack_target() -> void:
	_attack_target = null


func set_turn_meter_world_units(units: float) -> void:
	_meter_world_units = units


# --- Weapon and ranges ---------------------------------------------------------

func get_melee_range() -> float:
	return attack_range


func get_melee_damage() -> int:
	var mult := active_soul.melee_mult if active_soul != null else 1.0
	return int(round(float(attack_damage) * mult))


func _outgoing_damage() -> int:
	return get_melee_damage()


func get_preferred_attack_approach_distance() -> float:
	return maxf(0.2, attack_range - attack_approach_buffer)


func get_ranged_range_meters() -> float:
	return active_soul.ranged_range_meters if active_soul != null else 0.0


func try_ranged_attack(target: Node3D = null) -> bool:
	if active_soul == null or not active_soul.has_ranged():
		return false
	if target == null or not is_instance_valid(target) or not can_turn_attack():
		return false
	if GroundMath.ground_distance(global_position, target.global_position) > get_ranged_range_meters():
		return false
	if target.has_method("receive_damage"):
		target.call("receive_damage", active_soul.ranged_damage)
	_turn_attack_available = false
	return true


func try_cast_spell(spell_id: StringName, target: Node3D = null) -> bool:
	if active_soul == null:
		return false
	var spell := active_soul.get_spell(spell_id)
	if spell == null or target == null or not is_instance_valid(target) or not can_turn_attack():
		return false
	if GroundMath.ground_distance(global_position, target.global_position) > spell.range_meters:
		return false
	if target.has_method("receive_damage"):
		target.call("receive_damage", spell.damage)
	if spell.root_turns > 0 and target.has_method("apply_root"):
		target.call("apply_root", spell.root_turns)
	_turn_attack_available = false
	return true


func get_spell_cooldown(_spell_id: StringName) -> int:
	return 0


# --- Block stance --------------------------------------------------------------

func set_blocking(enabled: bool) -> void:
	_blocking = enabled and active_soul != null and active_soul.can_block_stance


func is_blocking() -> bool:
	return _blocking


func take_damage(amount: int) -> void:
	var scaled := float(amount) * (active_soul.defence_mult if active_soul != null else 1.0)
	if _blocking:
		scaled *= 0.5
	super(int(round(scaled)))


# --- Souls ---------------------------------------------------------------------

func get_active_soul() -> Soul:
	return active_soul


func get_souls() -> Array[Soul]:
	return souls


func get_shifts_left() -> int:
	return _shifts_left if _turn_mode else 99


func can_shift() -> bool:
	return get_shifts_left() > 0


func shift_to(kind: int) -> bool:
	if not can_shift():
		return false
	for soul in souls:
		if int(soul.kind) == kind:
			if soul == active_soul:
				return false
			active_soul = soul
			_blocking = false
			if _turn_mode:
				_shifts_left -= 1
			soul_changed.emit(soul)
			return true
	return false


## Keys 1, 2, 3 pick a soul. Returns the Soul.Kind value, or -1 for any other event.
func shift_kind_from_event(event: InputEvent) -> int:
	if not (event is InputEventKey):
		return -1
	var key := event as InputEventKey
	if not key.pressed or key.echo:
		return -1
	match key.keycode:
		KEY_1: return int(Soul.Kind.KNIGHT)
		KEY_2: return int(Soul.Kind.ROGUE)
		KEY_3: return int(Soul.Kind.MAGE)
	return -1


func start_turn(max_move_meters: float = 6.0) -> void:
	super(max_move_meters)
	_shifts_left = SHIFTS_PER_TURN
	_blocking = false


# --- Counter window (driven by the enemy) --------------------------------------

func get_reaction_hint() -> Dictionary:
	if active_soul == null:
		return {"text": "Counter", "color": Color.WHITE}
	return {"text": active_soul.reaction_name(), "color": active_soul.color}


func begin_enemy_counter_windup(_attacker: Node3D, _base_damage: int) -> void:
	pass


func begin_enemy_counter_strike() -> void:
	pass


func cancel_enemy_counter() -> void:
	pass


## Stub: the hit always lands (no timing window yet). Returns whether the press was perfect.
func resolve_enemy_attack(_attacker: Node3D, base_damage: int) -> bool:
	take_damage(base_damage)
	return false


# --- Progression ---------------------------------------------------------------

func heal(amount: int) -> void:
	health = mini(max_health, health + amount)


func add_experience(amount: int) -> void:
	_experience += float(amount)
	while _experience >= get_xp_required_for_next_level():
		_experience -= get_xp_required_for_next_level()
		_level += 1


func get_player_level() -> int:
	return _level


func get_experience_toward_next() -> float:
	return _experience


func get_xp_required_for_next_level() -> float:
	return XP_BASE * pow(XP_PER_LEVEL_MULT, float(_level - 1))


func set_overhead_ui_visible(_is_visible: bool) -> void:
	pass


# --- Inventory (none on the stub) ----------------------------------------------

func get_equipped_weapon() -> Item:
	return null


func get_inventory_items() -> Array[Item]:
	var empty: Array[Item] = []
	return empty
